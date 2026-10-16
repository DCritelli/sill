import Foundation
import Network
// In the app StreamProtocol is its own module; the client-session check compiles this file together
// with Sources/StreamProtocol as one module, where there is nothing to import.
#if canImport(StreamProtocol)
import StreamProtocol
#endif

/// The Mac Client's session with one Host (docs/adr/0002): one connection, the hello first, then
/// the Host's messages through the iOS app's MessageReader. The tracer's whole conversation: on the
/// first Window list it picks the Source (the first Window, or the Desktop when asked for, or when
/// the Host lists no Window) and sends it with the Viewport; it pings once a second; it hands the
/// video and the Host's cursor shape to its owner. Input goes out as the owner's input translator makes it
/// (`sendInput`, DCritelli/sill#3). A plain door (`plainParameters`) or a TLS one pinned to the
/// Host's key (`pinnedParameters`, after ClientPairing, DCritelli/sill#2). The redial is ClientConnection's (#9).
///
/// Every callback runs on `queue`, one at a time; `start()` and `stop()` may be called from any
/// thread. Foundation, Network and StreamProtocol only: checked with swiftc against a stand-in Host
/// on loopback (Tests/checks/client-session).
final class ClientSession {
    /// What the session picks on the Host's first Window list.
    enum Pick: Equatable {
        case firstWindow
        case desktop
        /// A redial (#9): the Source the dropped session had, when this Host still lists it (a
        /// Window that is gone, or no Source at all, is the Desktop).
        case resume(StreamSource)
    }

    var onWindowList: ((WindowList) -> Void)?
    var onParameterSets: ((ParameterSets) -> Void)?
    var onFrame: ((Data, Bool) -> Void)?
    /// The Host's cursor shape (kind 14), a `CursorShapeBlob`, whenever it changes.
    var onCursorShape: ((Data) -> Void)?
    /// The Host's frame rate limit (kind 16's `maxFPS`), whenever its settings arrive (#6).
    var onHostMaxFPS: ((Int) -> Void)?
    /// The Source the session picked, once, right after it sent the pick (#6).
    var onPicked: ((StreamSource) -> Void)?
    /// A Window's thumbnail (kind 3, an `ImageBlob`) and an app's icon (kind 4), as they arrive (#7).
    var onThumbnail: ((Data) -> Void)?
    var onIcon: ((Data) -> Void)?
    /// The Host's menus (kind 24): the app's top level, and the answers to fetches and presses (#8).
    var onMacMenu: ((MacMenu) -> Void)?
    /// The Host's goodbye (kind 22), before it closes the connection (#9).
    var onGoodbye: ((Goodbye) -> Void)?
    /// Once, when the session ends by itself (never after `stop()`), with a line for the log.
    var onEnd: ((String) -> Void)?

    let queue: DispatchQueue
    private let connection: NWConnection
    private let hello: Hello
    private let pick: Pick
    private let viewport: Viewport
    /// On `queue`.
    private var picked: StreamSource?
    private var running = false
    private var subscribed = false
    private var pingTimer: DispatchSourceTimer?

    /// - `viewport`: sent right after the pick. The tracer's leaves the remote Window alone
    ///   (`scale` nil) and carries the rate the display wants.
    init(endpoint: NWEndpoint, parameters: NWParameters, hello: Hello, pick: Pick, viewport: Viewport,
         queue: DispatchQueue = DispatchQueue(label: "sill.client.session", qos: .userInteractive)) {
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.hello = hello
        self.pick = pick
        self.viewport = viewport
        self.queue = queue
    }

    /// A plain home door's parameters, as the iOS app dials one: TCP without Nagle and the
    /// interactive video class.
    static func plainParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        return params
    }

    /// A TLS home door's parameters (DCritelli/sill#2), as the iOS app dials a saved Mac: mutual
    /// TLS 1.3 with this Mac's key (RemoteTLS), ALPN `sill/1`, the Host's key checked against
    /// `pin`, or any P-256 key where there is none (an open door, Require pairing off); TCP without
    /// Nagle and the interactive video class.
    static func pinnedParameters(identity: RemoteIdentity, pin: Data?) -> NWParameters {
        let tls = RemoteTLS.options(identity: identity.tls, role: .client(alpn: RemoteTLS.sessionALPN), verify: { fp in
            guard let pin else { return fp != nil }
            return fp == pin
        }, queue: verifyQueue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return RemoteTLS.parameters(tls: tls, tcp: tcp, peerToPeer: false)
    }

    /// Parameters that never connect (TLS trusting no key): for a pinned dial should this Mac's own
    /// key be unreadable, so nothing ever goes out in plain.
    static func refusingParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(false) }, verifyQueue)
        return RemoteTLS.parameters(tls: tls, tcp: NWProtocolTCP.Options(), peerToPeer: false)
    }

    /// Where every session's pin is checked: it answers at once, never waiting on anything.
    private static let verifyQueue = DispatchQueue(label: "sill.client.verify")

    func start() {
        queue.async { [self] in
            running = true
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, running else { return }
                switch state {
                case .ready:
                    startPinging()
                    MessageReader(connection: connection, stillReads: { [weak self] in self?.running ?? false },
                                  onBytes: { _ in }, onMessage: { [weak self] in self?.received($0, $1) },
                                  onEnd: { [weak self] end in
                                      switch end {
                                      case .closed(let error): self?.end("closed" + (error.map { ": \($0)" } ?? ""))
                                      case .tooBig(let header): self?.end("message too big: kind \(header.kind), \(header.payloadLength) bytes")
                                      }
                                  }).start()
                case .failed(let error):
                    end("failed: \(error)")
                case .waiting(let error):
                    end("unreachable: \(error)")
                default:
                    break
                }
            }
            // A send made before `.ready` waits for it, in order: the hello is the first message.
            send(.hello, Wire.encode(hello))
            connection.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            pingTimer?.cancel()
            connection.cancel()
        }
    }

    /// Sends a Viewport (a resize, a rate change; #6). From any thread.
    func sendViewport(_ viewport: Viewport) {
        queue.async { [self] in
            guard running else { return }
            send(.viewport, Wire.encode(viewport))
        }
    }

    /// Makes a Window or the Desktop the Source (a click in the Bar; #7). From any thread.
    func sendSource(_ source: StreamSource) {
        queue.async { [self] in
            guard running else { return }
            send(.selectSource, Wire.encode(source))
        }
    }

    /// Asks the Host to close, minimize or full-screen one of its Windows (#7). From any thread.
    func sendWindowCommand(_ command: WindowCommand) {
        queue.async { [self] in
            guard running else { return }
            send(.windowCommand, Wire.encode(command))
        }
    }

    /// Asks for one menu's items (kind 27 with an id; #8). From any thread.
    func sendFetchMenu(_ fetch: FetchMenu) {
        queue.async { [self] in
            guard running else { return }
            send(.fetchMenu, Wire.encode(fetch))
        }
    }

    /// Chooses a menu item on the Host (kind 25; #8). From any thread.
    func sendPressMenuItem(_ press: PressMenuItem) {
        queue.async { [self] in
            guard running else { return }
            send(.pressMenuItem, Wire.encode(press))
        }
    }

    /// Sends what the input translator made, each event one kind 8, in order. From any thread.
    func sendInput(_ events: [InputEvent]) {
        guard !events.isEmpty else { return }
        queue.async { [self] in
            guard running else { return }
            for event in events { send(.input, Wire.encode(event)) }
        }
    }

    private func end(_ why: String) {
        guard running else { return }
        running = false
        pingTimer?.cancel()
        connection.cancel()
        onEnd?(why)
    }

    private func received(_ header: StreamHeader, _ payload: Data) {
        switch header.kind {
        case .windowList:
            guard let list = Wire.decode(WindowList.self, from: payload) else { return }
            onWindowList?(list)
            if picked == nil { choose(from: list) }
            if !subscribed {
                // The subscription to the menus (a kind 27 without an id): only a subscriber is served.
                subscribed = true
                send(.fetchMenu, Wire.encode(FetchMenu()))
            }
        case .parameterSets:
            if let sets = ParameterSets(encoded: payload) { onParameterSets?(sets) }
        case .frame:
            onFrame?(payload, header.isKeyframe)
        case .cursorShape:
            onCursorShape?(payload)
        case .thumbnail:
            onThumbnail?(payload)
        case .appIcon:
            onIcon?(payload)
        case .macMenu:
            if let menu = Wire.decode(MacMenu.self, from: payload) { onMacMenu?(menu) }
        case .goodbye:
            if let goodbye = Wire.decode(Goodbye.self, from: payload) { onGoodbye?(goodbye) }
        case .hostSettings:
            if let state = Wire.decode(HostSettingsState.self, from: payload) { onHostMaxFPS?(state.settings.maxFPS) }
        default:
            break   // pongs, ticks, thumbnails, icons, settings: later tickets
        }
    }

    private func choose(from list: WindowList) {
        let source: StreamSource
        switch pick {
        case .desktop: source = .desktop
        case .firstWindow: source = list.windows.first.map { .window($0.id) } ?? .desktop
        case .resume(.window(let id)) where list.windows.contains { $0.id == id }: source = .window(id)
        case .resume: source = .desktop
        }
        picked = source
        send(.selectSource, Wire.encode(source))
        send(.viewport, Wire.encode(viewport))
        onPicked?(source)
    }

    private func startPinging() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            var clock = Date().timeIntervalSince1970.bitPattern.bigEndian
            self?.send(.ping, Data(bytes: &clock, count: 8))
        }
        timer.resume()
        pingTimer = timer
    }

    private func send(_ kind: StreamMessageKind, _ payload: Data) {
        let message = StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload)
        connection.send(content: message.serialized(), completion: .contentProcessed { _ in })
    }
}
