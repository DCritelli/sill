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
/// video to its owner. No pairing, no reconnect, no input yet (DCritelli/sill#2, #3, #9).
///
/// Every callback runs on `queue`, one at a time; `start()` and `stop()` may be called from any
/// thread. Foundation, Network and StreamProtocol only: checked with swiftc against a stand-in Host
/// on loopback (Tests/checks/client-session).
final class ClientSession {
    /// What the session picks on the Host's first Window list.
    enum Pick: Equatable {
        case firstWindow
        case desktop
    }

    var onWindowList: ((WindowList) -> Void)?
    var onParameterSets: ((ParameterSets) -> Void)?
    var onFrame: ((Data, Bool) -> Void)?
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
        case .parameterSets:
            if let sets = ParameterSets(encoded: payload) { onParameterSets?(sets) }
        case .frame:
            onFrame?(payload, header.isKeyframe)
        default:
            break   // pongs, ticks, thumbnails, icons, cursor shapes, settings: later tickets
        }
    }

    private func choose(from list: WindowList) {
        let source: StreamSource
        switch pick {
        case .desktop: source = .desktop
        case .firstWindow: source = list.windows.first.map { .window($0.id) } ?? .desktop
        }
        picked = source
        send(.selectSource, Wire.encode(source))
        send(.viewport, Wire.encode(viewport))
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
