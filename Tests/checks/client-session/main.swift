// The client-session check (DCritelli/sill#10): the Mac Client's ClientSession
// (Sources/SillClient/ClientSession.swift) with the iOS app's MessageReader and StreamProtocol,
// against a stand-in Host on loopback. Each case has a fresh listener; the stand-in records every
// message the session sends, in order, and writes what the case says.
//
//   swiftc Sources/SillClient/ClientSession.swift iOSClient/MessageReader.swift Sources/StreamProtocol/*.swift \
//     Tests/checks/client-session/main.swift -o .build/checks/client-session/check
//   .build/checks/client-session/check [CASE...]
//
// Cases: first (the hello is the first message, with its version and device; on a list of two
// Windows the first is picked; the Viewport follows the pick, as given), eager (the Host's list sent
// the moment the connection is up, as a real Host sends it: the hello still goes first), desktop (asked for the
// Desktop: picked whatever the list), empty (a list with no Window: the Desktop), once (a second
// list picks nothing more), video (parameter sets and frames reach the owner, keyframe flag and
// bytes intact, in order), ping (a ping of 8 bytes within 1.5 s), hostclose (the Host closes:
// onEnd once), input (sendInput(_:): each InputEvent one kind 8, in order), cursor (a cursor shape handed
// on intact), stop (stop(): no onEnd, and the connection closes). Prints "ok" or "FAIL" per check;
// exits 1 on any failure.
import Foundation
import Network

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { failures += 1 }
}

/// Waits up to `seconds` for `condition`, polling.
@discardableResult
func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

/// A stand-in Host: one listener on loopback, one connection, every message it reads kept in order.
final class StandIn {
    private let queue = DispatchQueue(label: "standin")
    private let listener: NWListener
    private var connection: NWConnection?
    private let lock = NSLock()
    private var _received: [(StreamMessageKind, Data)] = []
    private var _closed = false
    var received: [(StreamMessageKind, Data)] { lock.lock(); defer { lock.unlock() }; return _received }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    var port: NWEndpoint.Port { listener.port! }

    /// - `eager`: a message to send the moment the connection is up, before reading anything, as a
    ///   real Host sends its Window list on connect.
    init(eager: Data? = nil) {
        listener = try! NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [self] c in
            connection = c
            c.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    if let eager { c.send(content: eager, completion: .contentProcessed { _ in }) }
                    readHeader(c)
                case .failed, .cancelled: lock.lock(); _closed = true; lock.unlock()
                default: break
                }
            }
            c.start(queue: queue)
        }
        listener.start(queue: queue)
        ready.wait()
    }

    private func readHeader(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [self] data, _, done, error in
            guard let data, let header = StreamMessage.parseHeader(data) else {
                if done || error != nil { lock.lock(); _closed = true; lock.unlock() }
                return
            }
            guard header.payloadLength > 0 else { keep(header.kind, Data()); readHeader(c); return }
            c.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { [self] body, _, _, _ in
                keep(header.kind, body ?? Data())
                readHeader(c)
            }
        }
    }

    private func keep(_ kind: StreamMessageKind, _ payload: Data) {
        lock.lock(); _received.append((kind, payload)); lock.unlock()
    }

    func send(_ kind: StreamMessageKind, _ payload: Data, keyframe: Bool = false) {
        let m = StreamMessage(kind: kind, timestamp: 1, isKeyframe: keyframe, payload: payload)
        connection?.send(content: m.serialized(), completion: .contentProcessed { _ in })
    }

    func close() { connection?.cancel() }
    func stop() { connection?.cancel(); listener.cancel() }
}

/// What the session handed its owner, on its queue.
final class Owner {
    private let lock = NSLock()
    private var _lists = 0, _ends: [String] = [], _video: [String] = [], _cursors: [Data] = []
    var lists: Int { lock.lock(); defer { lock.unlock() }; return _lists }
    var ends: [String] { lock.lock(); defer { lock.unlock() }; return _ends }
    var video: [String] { lock.lock(); defer { lock.unlock() }; return _video }
    var cursors: [Data] { lock.lock(); defer { lock.unlock() }; return _cursors }

    func attach(_ s: ClientSession) {
        s.onWindowList = { [self] _ in lock.lock(); _lists += 1; lock.unlock() }
        s.onParameterSets = { [self] ps in lock.lock(); _video.append("ps \(ps.nalUnitHeaderLength) \(ps.sets.count)"); lock.unlock() }
        s.onFrame = { [self] d, key in lock.lock(); _video.append("frame \(d.count) \(key) \(d.first ?? 0)"); lock.unlock() }
        s.onCursorShape = { [self] d in lock.lock(); _cursors.append(d); lock.unlock() }
        s.onEnd = { [self] why in lock.lock(); _ends.append(why); lock.unlock() }
    }
}

let hello = Hello(appVersion: "9.8", build: "7", protocol: SillProtocol.current, device: "Check Mac (Mac0,0)")
let viewport = Viewport(width: 960, height: 600, scale: nil, fps: 120)
let twoWindows = WindowList(macName: "Stand-in", windows: [
    WindowInfo(id: 41, title: "First", appName: "A", bundleID: "a", width: 800, height: 600),
    WindowInfo(id: 42, title: "Second", appName: "B", bundleID: "b", width: 400, height: 300),
], active: .none)

/// A session to a fresh stand-in, connected; the case runs, then both are torn down.
func withSession(pick: ClientSession.Pick, eager: Data? = nil, _ body: (StandIn, ClientSession, Owner) -> Void) {
    let host = StandIn(eager: eager)
    let session = ClientSession(endpoint: .hostPort(host: "127.0.0.1", port: host.port),
                                parameters: ClientSession.plainParameters(), hello: hello, pick: pick, viewport: viewport)
    let owner = Owner()
    owner.attach(session)
    session.start()
    // The stand-in's connection exists once it has read something: the hello, first of all.
    if !wait(2, { !host.received.isEmpty }) { check(false, "the session reaches the stand-in") }
    body(host, session, owner)
    session.stop()
    host.stop()
}

func kinds(_ host: StandIn) -> [StreamMessageKind] { host.received.map(\.0).filter { $0 != .ping } }

let cases: [(String, () -> Void)] = [
    ("first", {
        withSession(pick: .firstWindow) { host, _, owner in
            check(wait(2) { !host.received.isEmpty }, "first: the stand-in hears from the session")
            check(host.received.first?.0 == .hello, "first: the hello is the first message")
            check(Wire.decode(Hello.self, from: host.received.first?.1 ?? Data()) == hello, "first: the hello carries the version, build, protocol and device")
            host.send(.windowList, Wire.encode(twoWindows))
            check(wait(2) { kinds(host).count >= 3 }, "first: two more messages after the list")
            check(kinds(host) == [.hello, .selectSource, .viewport], "first: hello, then the pick, then the Viewport")
            let picked = host.received.first { $0.0 == .selectSource }.flatMap { Wire.decode(StreamSource.self, from: $0.1) }
            check(picked == .window(41), "first: the first Window is picked")
            let sent = host.received.first { $0.0 == .viewport }.flatMap { Wire.decode(Viewport.self, from: $0.1) }
            check(sent == viewport, "first: the Viewport is sent as given")
            check(owner.lists == 1, "first: the owner gets the list")
        }
    }),
    ("eager", {
        let list = StreamMessage(kind: .windowList, timestamp: 1, isKeyframe: false, payload: Wire.encode(twoWindows)).serialized()
        withSession(pick: .firstWindow, eager: list) { host, _, _ in
            check(wait(2) { kinds(host).count >= 3 }, "eager: the session answers a list sent on connect")
            check(kinds(host) == [.hello, .selectSource, .viewport], "eager: still the hello first, then the pick and the Viewport")
        }
    }),
    ("desktop", {
        withSession(pick: .desktop) { host, _, _ in
            host.send(.windowList, Wire.encode(twoWindows))
            check(wait(2) { kinds(host).contains(.selectSource) }, "desktop: a pick is sent")
            let picked = host.received.first { $0.0 == .selectSource }.flatMap { Wire.decode(StreamSource.self, from: $0.1) }
            check(picked == .desktop, "desktop: the Desktop is picked")
        }
    }),
    ("empty", {
        withSession(pick: .firstWindow) { host, _, _ in
            host.send(.windowList, Wire.encode(WindowList(macName: "Stand-in", windows: [], active: .none)))
            check(wait(2) { kinds(host).contains(.selectSource) }, "empty: a pick is sent")
            let picked = host.received.first { $0.0 == .selectSource }.flatMap { Wire.decode(StreamSource.self, from: $0.1) }
            check(picked == .desktop, "empty: no Window, so the Desktop")
        }
    }),
    ("once", {
        withSession(pick: .firstWindow) { host, _, owner in
            host.send(.windowList, Wire.encode(twoWindows))
            wait(2) { kinds(host).contains(.viewport) }
            var later = twoWindows
            later.windows.reverse()
            later.active = .window(41)
            host.send(.windowList, Wire.encode(later))
            check(wait(2) { owner.lists == 2 }, "once: the owner gets the second list")
            Thread.sleep(forTimeInterval: 0.2)
            check(kinds(host).filter { $0 == .selectSource }.count == 1, "once: only the first list picks")
        }
    }),
    ("video", {
        withSession(pick: .firstWindow) { host, _, owner in
            host.send(.windowList, Wire.encode(twoWindows))
            host.send(.parameterSets, ParameterSets(nalUnitHeaderLength: 4, sets: [Data([1]), Data([2, 2]), Data([3])]).encoded())
            host.send(.frame, Data([9, 1, 2, 3]), keyframe: true)
            host.send(.frame, Data([8, 1]), keyframe: false)
            host.send(.unknown, Data([0]))   // a kind this build does not know: skipped
            host.send(.frame, Data([7]), keyframe: false)
            check(wait(2) { owner.video.count == 4 }, "video: everything reaches the owner")
            check(owner.video == ["ps 4 3", "frame 4 true 9", "frame 2 false 8", "frame 1 false 7"], "video: in order, intact, keyframe flag kept")
        }
    }),
    ("input", {
        withSession(pick: .firstWindow) { host, session, _ in
            host.send(.windowList, Wire.encode(twoWindows))
            wait(2) { kinds(host).contains(.viewport) }
            let events: [InputEvent] = [.pointer(.leftDown, x: 0.25, y: 0.5), .pointer(.move, x: 0, y: 0.5), .pointer(.leftUp, x: 0, y: 0.5)]
            session.sendInput(events)
            check(wait(2) { kinds(host).count >= 6 }, "input: three input messages reach the stand-in")
            let sent = host.received.filter { $0.0 == .input }.compactMap { Wire.decode(InputEvent.self, from: $0.1) }
            check(sent == events, "input: each event as one kind 8, in order")
        }
    }),
    ("cursor", {
        withSession(pick: .firstWindow) { host, _, owner in
            let blob = CursorShapeBlob.encode(hotspot: CGPoint(x: 4, y: 9), size: CGSize(width: 9, height: 18), png: Data([0x89, 1, 2]))
            host.send(.cursorShape, blob)
            check(wait(2) { !owner.cursors.isEmpty }, "cursor: the Host's cursor shape reaches the owner")
            check(owner.cursors == [blob], "cursor: intact, once")
        }
    }),
    ("ping", {
        withSession(pick: .firstWindow) { host, _, _ in
            check(wait(1.5) { host.received.contains { $0.0 == .ping } }, "ping: one within 1.5 s")
            check(host.received.first { $0.0 == .ping }?.1.count == 8, "ping: 8 bytes")
        }
    }),
    ("hostclose", {
        withSession(pick: .firstWindow) { host, _, owner in
            host.send(.windowList, Wire.encode(twoWindows))
            wait(2) { kinds(host).contains(.viewport) }
            host.close()
            check(wait(2) { !owner.ends.isEmpty }, "hostclose: the session ends")
            Thread.sleep(forTimeInterval: 0.2)
            check(owner.ends.count == 1, "hostclose: onEnd once")
        }
    }),
    ("stop", {
        withSession(pick: .firstWindow) { host, session, owner in
            host.send(.windowList, Wire.encode(twoWindows))
            wait(2) { kinds(host).contains(.viewport) }
            session.stop()
            check(wait(2) { host.closed }, "stop: the connection closes")
            Thread.sleep(forTimeInterval: 0.2)
            check(owner.ends.isEmpty, "stop: no onEnd")
        }
    }),
]

let wanted = Set(CommandLine.arguments.dropFirst())
for (name, run) in cases where wanted.isEmpty || wanted.contains(name) { run() }
print(failures == 0 ? "client-session: all ok" : "client-session: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
