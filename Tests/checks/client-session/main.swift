// The client-session check (DCritelli/sill#10, #2): the Mac Client's ClientSession and ClientPairing
// (Sources/SillClient) with the iOS app's MessageReader and SavedMacs and StreamProtocol, against a
// stand-in Host on loopback: plain, or a TLS 1.3 home door with Require pairing on (`Door`). Each case
// has a fresh listener; the stand-in records every message the session sends, in order, and writes
// what the case says. run.sh compiles it (SavedMacs.swift without its `import StreamProtocol`):
//   Tests/checks/client-session/run.sh [CASE...]
//
// Pairing cases: paircode (the right code pairs over sill-pair/1 with TLS 1.3: one kind 19 with this
// Mac's name and model, proof_D bound to the keys of that TLS session; the Host's Mac ID, key, name and
// recognition key; the saved record in SavedMacs' format, `homeTLS`, the address it paired at; then a
// session pinned to the Host's key, mutual TLS 1.3 on sill/1, the hello first), bonjour (a Host paired
// on its row is saved and dialed by its service name), busy (a busy Host is tried again, silently,
// a bounded number of times), wrongcode (the tries left, nothing paired), expired, refusals (closed,
// stopped, a reason this build does not know: the Host's own words), typo (caught here: the Host never
// hears of it), proofs (a Host that can't prove the code, or names another key's Mac ID, is not saved),
// pins (a session pinned to another key, or from an unpaired key, ends with nothing said; a link for
// another key sends no proof), link (a sill://pair link pairs, method qr), targets (a dead target is
// passed by), ask (method ask, no proof; the answer and the key to pin the code to).
//
// Session cases: first (the hello is the first message, with its version and device; on a list of two
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
import CryptoKit

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
    /// - `door`: a TLS home door with Require pairing on (`sill/1` for paired keys, `sill-pair/1`
    ///   for pairing) instead of plain TCP.
    let door: Door?
    init(eager: Data? = nil, door: Door? = nil) {
        self.door = door
        let tlsQueue = DispatchQueue(label: "standin.tls")
        let params: NWParameters = door.map { d in
            RemoteTLS.parameters(tls: RemoteTLS.options(identity: d.identity.tls, role: .server, queue: tlsQueue) { fp, alpn in
                guard let fp else { return false }
                return alpn == RemoteTLS.pairingALPN ? d.pairingOpen : (alpn == RemoteTLS.sessionALPN && d.isPaired(fp))
            }, dialing: false)
        } ?? .tcp
        listener = try! NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [self] c in
            c.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    if let door { door.connected(c) }
                    if RemoteTLS.negotiatedALPN(c) == RemoteTLS.pairingALPN { door?.pair(c); return }
                    connection = c
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

/// A stand-in Host's TLS door at home with Require pairing on: its own key, the keys it paired, and
/// how it answers a kind 19 (as a Host does, docs/home-pairing-plan.md §3.1): a proof made with the
/// window's key pairs that device (proof_M, the Mac ID, the name, the recognition key) and anything
/// else is refused with `code` and the tries left; `answer` overrides that.
final class Door {
    enum Answer { case honest, refuse(PairResult), badProof, wrongMacID, shown, busyOnce }
    let identity = RemoteIdentity(privateKey: RemoteKey.generate()!)!
    let name = "Stand-in Mac"
    let recognitionKey = Data(repeating: 7, count: 32)
    var macID: String { MacID.make(fingerprint: identity.fingerprint) }
    /// The window's key: the typed code's PBKDF2 key, or a link's secret.
    var windowKey: SymmetricKey?
    var answer: Answer = .honest
    var pairingOpen = true
    private let lock = NSLock()
    private var _paired: Set<Data> = []
    private var _requests: [(PairRequest, Data?)] = []
    private var _versions: [tls_protocol_version_t] = []
    /// Each kind 19 read, with the device's key as the TLS session showed it.
    var requests: [(PairRequest, Data?)] { lock.lock(); defer { lock.unlock() }; return _requests }
    /// The TLS version of every connection that came up.
    var versions: [tls_protocol_version_t] { lock.lock(); defer { lock.unlock() }; return _versions }
    func isPaired(_ fp: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return _paired.contains(fp) }
    func addPaired(_ fp: Data) { lock.lock(); _paired.insert(fp); lock.unlock() }

    init(code: String? = nil, secret: Data? = nil) {
        if let code { windowKey = PairingProof.codeKey(code: code, macFingerprint: identity.fingerprint) }
        if let secret { windowKey = PairingProof.qrKey(secret: secret) }
    }

    func connected(_ c: NWConnection) {
        guard let m = c.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return }
        let v = sec_protocol_metadata_get_negotiated_tls_protocol_version(m.securityProtocolMetadata)
        lock.lock(); _versions.append(v); lock.unlock()
    }

    /// One pairing connection: one kind 19 in, one kind 20 out, then closed.
    func pair(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [self] data, _, _, _ in
            guard let data, let header = StreamMessage.parseHeader(data), header.kind == .pairRequest, header.payloadLength > 0 else { c.cancel(); return }
            c.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { [self] body, _, _, _ in
                guard let body, let request = Wire.decode(PairRequest.self, from: body) else { c.cancel(); return }
                let device = RemoteTLS.peerFingerprint(c)
                lock.lock(); _requests.append((request, device)); lock.unlock()
                let result = answer(to: request, device: device)
                let m = StreamMessage(kind: .pairResult, timestamp: 1, isKeyframe: false, payload: Wire.encode(result))
                c.send(content: m.serialized(), completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }

    private func answer(to request: PairRequest, device: Data?) -> PairResult {
        let mine = identity.fingerprint
        if case .refuse(let r) = answer { return r }
        if case .shown = answer { return PairResult(ok: false, reason: PairResult.shown) }
        if case .busyOnce = answer {
            // As a Host right after a wrong code: busy for a moment, then it takes a proof again.
            answer = .honest
            return PairResult(ok: false, reason: PairResult.busy, retryAfter: 0.3)
        }
        guard request.method != PairRequest.ask else { return PairResult(ok: false, reason: PairResult.openOnMac) }
        guard let device, let key = windowKey, let proof = Base64URL.decode(request.proof),
              PairingProof.isValidDeviceProof(proof, key: key, deviceFingerprint: device, macFingerprint: mine) else {
            return PairResult(ok: false, reason: PairResult.code, triesLeft: 4)
        }
        addPaired(device)
        var proofM = PairingProof.macProof(key: key, macFingerprint: mine, deviceFingerprint: device)
        if case .badProof = answer { proofM[0] ^= 1 }
        let id: String = { if case .wrongMacID = answer { return MacID.make(fingerprint: Data(repeating: 1, count: 32)) }; return macID }()
        return PairResult(ok: true, proof: Base64URL.encode(proofM), macID: id, name: name, recognitionKey: Base64URL.encode(recognitionKey))
    }
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
    withSession(to: host, parameters: ClientSession.plainParameters(), pick: pick, body)
}

func withSession(to host: StandIn, parameters: NWParameters, pick: ClientSession.Pick = .firstWindow,
                 expectReach: Bool = true, _ body: (StandIn, ClientSession, Owner) -> Void) {
    let session = ClientSession(endpoint: .hostPort(host: "127.0.0.1", port: host.port),
                                parameters: parameters, hello: hello, pick: pick, viewport: viewport)
    let owner = Owner()
    owner.attach(session)
    session.start()
    // The stand-in's connection exists once it has read something: the hello, first of all.
    if expectReach, !wait(2, { !host.received.isEmpty }) { check(false, "the session reaches the stand-in") }
    body(host, session, owner)
    session.stop()
    host.stop()
}

func kinds(_ host: StandIn) -> [StreamMessageKind] { host.received.map(\.0).filter { $0 != .ping } }

// MARK: Pairing (DCritelli/sill#2)

/// This Mac's key, as the Mac Client's identity store would give it: in memory here.
let device = RemoteIdentity(privateKey: RemoteKey.generate()!)!

/// A fresh valid code (its check digit right).
func freshCode() -> String { PairingCode.generate()! }

/// One pairing against `host`, waited for (PBKDF2 takes a moment): its outcome, or nil after 20 s.
func pair(_ host: StandIn, _ request: ClientPairing.Request, pin: Data? = nil, targets: [NWEndpoint]? = nil) -> ClientPairing.Outcome? {
    let p = ClientPairing(targets: targets ?? [.hostPort(host: "127.0.0.1", port: host.port)], pin: pin, request: request,
                          macName: "Stand-in Mac", identity: device, deviceName: "Check Mac", model: "Mac0,0", dialWait: 2)
    let lock = NSLock()
    var outcome: ClientPairing.Outcome?
    p.onDone = { o in lock.lock(); outcome = o; lock.unlock() }
    p.start()
    wait(20) { lock.lock(); defer { lock.unlock() }; return outcome != nil }
    lock.lock(); defer { lock.unlock() }
    return outcome
}

func paired(_ o: ClientPairing.Outcome?) -> ClientPairing.PairedHost? { if case .paired(let h)? = o { return h }; return nil }
func words(_ o: ClientPairing.Outcome?) -> String? { if case .failed(let w)? = o { return w }; return nil }

let cases: [(String, () -> Void)] = [
    ("paircode", {
        let code = freshCode()
        let door = Door(code: code)
        let host = StandIn(door: door)
        let o = pair(host, .code(PairingCode.grouped(code)))
        let h = paired(o)
        check(h != nil, "paircode: the right code pairs (\(String(describing: o)))")
        check(door.requests.count == 1, "paircode: one kind 19")
        let r = door.requests.first
        check(r?.0.method == PairRequest.code && r?.0.name == "Check Mac" && r?.0.model == "Mac0,0",
              "paircode: method code, with this Mac's name and model")
        check(r?.1 == device.fingerprint, "paircode: the Host saw this Mac's own key in the TLS session")
        check(door.isPaired(device.fingerprint), "paircode: the stand-in took the proof")
        check(!door.versions.isEmpty && door.versions.allSatisfy { $0 == .TLSv13 }, "paircode: TLS 1.3")
        check(h?.macID == door.macID && h?.fingerprint == door.identity.fingerprint, "paircode: the Host's Mac ID and key, from the TLS session")
        check(h?.name == "Stand-in Mac" && h?.recognitionKey == Base64URL.encode(door.recognitionKey), "paircode: its name and recognition key")
        guard let h else { host.stop(); return }
        // The record, in the format the iOS app saves (SavedMacs), survives its own storage.
        let saved = SavedMacs.decode(SavedMacs.encode([h.savedMac(method: PairRequest.code)]))
        check(saved.count == 1 && saved.first?.macID == door.macID && saved.first?.fingerprintData == door.identity.fingerprint,
              "paircode: the saved record decodes, pinned to the Host's key")
        check(saved.first?.homeTLS == true && saved.first?.method == "code", "paircode: saved as paired by code at a TLS door")
        check(saved.first?.typedAddresses?.first?.host == "127.0.0.1" && saved.first?.typedAddresses?.first?.port == Int(host.port.rawValue),
              "paircode: an address it was paired at is kept to dial it again")
        check(saved.first.flatMap(ClientPairing.endpoint(of:)) == .hostPort(host: "127.0.0.1", port: host.port),
              "paircode: a saved Host is dialed where it paired")
        // Later connections: mutual TLS 1.3 pinned to the Host's key, sill/1, the hello first.
        withSession(to: host, parameters: ClientSession.pinnedParameters(identity: device, pin: h.fingerprint)) { host, _, _ in
            check(host.received.first?.0 == .hello, "paircode: pinned session: the hello is the first message")
            host.send(.windowList, Wire.encode(twoWindows))
            check(wait(2) { kinds(host).contains(.viewport) }, "paircode: pinned session: the pick and the Viewport")
        }
        check(door.versions.count >= 2 && door.versions.allSatisfy { $0 == .TLSv13 }, "paircode: the session is TLS 1.3 too")
        host.stop()
    }),
    ("bonjour", {
        // A Host paired on its Bonjour row is dialed by that service name again.
        let code = freshCode()
        let door = Door(code: code)
        let host = StandIn(door: door)
        let row = NWEndpoint.service(name: "Stand-in Mac", type: "_sill._tcp", domain: "local.", interface: nil)
        let h = paired(pair(host, .code(code)))
        let mac = h.map { var h = $0; h.endpoint = row; return h.savedMac(method: PairRequest.code) }
        check(mac?.bonjourName == "Stand-in Mac" && mac?.typedAddresses == nil, "bonjour: the row's service name is saved, no address")
        check(mac.flatMap(ClientPairing.endpoint(of:)) == row, "bonjour: dialed by that name")
        host.stop()
    }),
    ("wrongcode", {
        let door = Door(code: freshCode())
        let host = StandIn(door: door)
        var other = freshCode()
        while PairingProof.codeKey(code: other, macFingerprint: door.identity.fingerprint) == door.windowKey { other = freshCode() }
        let o = pair(host, .code(other))
        check(paired(o) == nil, "wrongcode: not paired")
        check(words(o)?.contains("4\u{00A0}tries left") == true && words(o)?.contains("didn’t work") == true,
              "wrongcode: says the code didn't work and the tries left (\(words(o) ?? "nil"))")
        check(!door.isPaired(device.fingerprint), "wrongcode: the stand-in paired nothing")
        host.stop()
    }),
    ("busy", {
        // A Host busy for a moment (right after a wrong code: its back-off, then its 5 s between one
        // source's proofs) is tried again, silently, a few times.
        let code = freshCode()
        let door = Door(code: code)
        door.answer = .busyOnce
        let host = StandIn(door: door)
        let o = pair(host, .code(code))
        check(paired(o)?.macID == door.macID, "busy: paired on the second try (\(String(describing: o)))")
        check(door.requests.count == 2, "busy: two kinds 19, one connection each")
        door.answer = .refuse(PairResult(ok: false, reason: PairResult.busy, retryAfter: 0.1))
        check(words(pair(host, .code(code)))?.contains("busy") == true, "busy: busy every time: said, not retried for ever")
        check(door.requests.count == 2 + 1 + ClientPairing.busyRetries, "busy: \(ClientPairing.busyRetries) retries, no more (\(door.requests.count - 2))")
        check(ClientPairing.busyRetries >= 2, "busy: at least two retries (a real Host's back-off, then its spacing)")
        host.stop()
    }),
    ("expired", {
        let door = Door(code: freshCode())
        door.answer = .refuse(PairResult(ok: false, reason: PairResult.expired))
        let host = StandIn(door: door)
        let o = pair(host, .code(freshCode()))
        check(words(o)?.contains("expired") == true && words(o)?.contains("Stand-in Mac") == true,
              "expired: says the code expired, naming the Host (\(words(o) ?? "nil"))")
        host.stop()
    }),
    ("refusals", {
        let door = Door(code: freshCode())
        let host = StandIn(door: door)
        door.answer = .refuse(PairResult(ok: false, reason: PairResult.closed))
        check(words(pair(host, .code(freshCode())))?.contains("Pair iPhone or iPad") == true, "refusals: closed: open a pairing window on the Host")
        door.answer = .refuse(PairResult(ok: false, reason: PairResult.stopped))
        check(words(pair(host, .code(freshCode())))?.contains("too many wrong codes") == true, "refusals: stopped: too many wrong codes")
        door.answer = .refuse(PairResult(ok: false, reason: "later", message: "Ask the cat."))
        check(words(pair(host, .code(freshCode()))) == "Ask the cat.", "refusals: a reason this build does not know: the Host's own words")
        host.stop()
    }),
    ("typo", {
        let door = Door(code: freshCode())
        let host = StandIn(door: door)
        var code = Array(freshCode())
        code[11] = code[11] == "0" ? "1" : "0"
        let o = pair(host, .code(String(code)))
        check(words(o)?.contains("typo") == true, "typo: a bad check digit is caught here (\(words(o) ?? "nil"))")
        check(words(pair(host, .code("1234")))?.contains("12 digits") == true, "typo: too short")
        Thread.sleep(forTimeInterval: 0.2)
        check(door.requests.isEmpty && door.versions.isEmpty, "typo: the Host never hears of it")
        host.stop()
    }),
    ("proofs", {
        let code = freshCode()
        let door = Door(code: code)
        let host = StandIn(door: door)
        door.answer = .badProof
        check(paired(pair(host, .code(code))) == nil, "proofs: a Host that can't prove the code is not saved")
        door.answer = .wrongMacID
        check(paired(pair(host, .code(code))) == nil, "proofs: a Host naming another key's Mac ID is not saved")
        host.stop()
    }),
    ("pins", {
        let code = freshCode()
        let door = Door(code: code)
        let host = StandIn(door: door)
        let stranger = RemoteIdentity(privateKey: RemoteKey.generate()!)!
        // A link pinned to another key: never sends its proof.
        let link = PairLink(fingerprint: stranger.fingerprint, secret: Data(repeating: 3, count: 16), name: "Stand-in Mac", port: 7455, addresses: [])
        check(paired(pair(host, .link(link), pin: link.fingerprint)) == nil, "pins: a link for another key does not pair")
        check(door.requests.isEmpty, "pins: and sends no kind 19")
        // This Mac not paired: the Host refuses it in the handshake.
        withSession(to: host, parameters: ClientSession.pinnedParameters(identity: device, pin: door.identity.fingerprint), expectReach: false) { host, _, owner in
            check(wait(4) { !owner.ends.isEmpty }, "pins: an unpaired key's session ends")
            check(host.received.isEmpty, "pins: the Host read nothing from an unpaired key")
        }
        host.stop()
        // Paired, but pinned to another key: the handshake ends on this side, nothing is said. A
        // fresh stand-in (one that refused a handshake may serve no more), which would take this Mac.
        let door2 = Door(code: code)
        door2.addPaired(device.fingerprint)
        let host2 = StandIn(door: door2)
        withSession(to: host2, parameters: ClientSession.pinnedParameters(identity: device, pin: stranger.fingerprint), expectReach: false) { host, _, owner in
            check(wait(4) { !owner.ends.isEmpty }, "pins: a session pinned to another key ends")
            check(host.received.isEmpty, "pins: and the Host hears nothing from it")
        }
        host2.stop()
    }),
    ("link", {
        let secret = Data((0..<16).map { UInt8($0) })
        let door = Door(secret: secret)
        let host = StandIn(door: door)
        let link = PairLink(fingerprint: door.identity.fingerprint, secret: secret, name: "Stand-in Mac", port: 7455, addresses: [])
        let h = paired(pair(host, .link(link), pin: link.fingerprint))
        check(h?.macID == door.macID, "link: a sill://pair link pairs with its Host")
        check(door.requests.first?.0.method == PairRequest.qr, "link: method qr, the link's secret as the key")
        check(h.map { $0.savedMac(method: PairRequest.qr).method } == "qr", "link: saved as paired by link")
        host.stop()
    }),
    ("targets", {
        // The first target answers nothing (a closed port); the next one pairs.
        let code = freshCode()
        let door = Door(code: code)
        let host = StandIn(door: door)
        let dead = try! NWListener(using: .tcp, on: .any)
        let q = DispatchQueue(label: "dead")
        let ready = DispatchSemaphore(value: 0)
        dead.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        dead.newConnectionHandler = { $0.cancel() }
        dead.start(queue: q); ready.wait()
        let deadPort = dead.port!
        dead.cancel()
        Thread.sleep(forTimeInterval: 0.1)
        let o = pair(host, .code(code), targets: [.hostPort(host: "127.0.0.1", port: deadPort), .hostPort(host: "127.0.0.1", port: host.port)])
        check(paired(o)?.endpoint == .hostPort(host: "127.0.0.1", port: host.port), "targets: the one that answered pairs, and is the endpoint kept")
        host.stop()
    }),
    ("ask", {
        let door = Door(code: freshCode())
        door.answer = .shown
        let host = StandIn(door: door)
        let o = pair(host, .ask)
        if case .asked(let reason, let fp, _)? = o {
            check(reason == PairResult.shown && fp == door.identity.fingerprint, "ask: the Host's answer and its key, to pin the code to")
        } else { check(false, "ask: answered (\(String(describing: o)))") }
        check(door.requests.first?.0.method == PairRequest.ask && door.requests.first?.0.proof == "", "ask: method ask, no proof")
        host.stop()
    }),

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
