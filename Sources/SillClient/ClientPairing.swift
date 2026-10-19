import Foundation
import Network
import CryptoKit
// In the app StreamProtocol is its own module; the client-session check compiles this file together
// with Sources/StreamProtocol as one module, where there is nothing to import.
#if canImport(StreamProtocol)
import StreamProtocol
#endif

/// One pairing exchange of the Mac Client with a Host (DCritelli/sill#2), as the iOS app pairs at
/// a home door (docs/home-pairing-plan.md §3.1, §7.5): `sill-pair/1` over mutual TLS 1.3 with this
/// Mac's key, to each target in turn until one is ready, then exactly one kind 19 and one kind 20.
///
/// - `.code`: the 12 typed digits, checked here first (a typo never uses up one of the Host's five
///   tries), then proof_D from the PBKDF2 key over the Host's key as this TLS session saw it. With
///   no `pin` any P-256 key answers: the proof binds the key that did, so a relay in the middle
///   fails it.
/// - `.link`: a `sill://pair` link's secret, pinned to the link's key.
/// - `.ask`: "pair me, else show me your code" (the home door only): the Host's answer and the key
///   it answered with, which the code typed next is pinned to.
///
/// Nothing is reported paired unless the Host proved it knows the same key (proof_M, for the keys
/// of this very connection) and names itself by that key. Callbacks on `queue`. Foundation,
/// Network, CryptoKit and StreamProtocol only: checked against a stand-in Host on loopback
/// (Tests/checks/client-session).
final class ClientPairing {
    enum Request {
        case code(String)
        case link(PairLink)
        case ask
    }

    /// A Host this Mac just paired with, proof_M checked.
    struct PairedHost: Equatable {
        var macID: String
        var name: String
        /// The Host's key as the TLS session showed it: the pin for every later connection.
        var fingerprint: Data
        /// base64url, 32 bytes: resolves the Host's Bonjour TXT tag.
        var recognitionKey: String
        /// The target that answered.
        var endpoint: NWEndpoint
    }

    enum Outcome {
        case paired(PairedHost)
        /// The answer to `.ask` ("shown", "openOnMac", "locked", …) and the key that gave it.
        case asked(reason: String, fingerprint: Data, endpoint: NWEndpoint)
        /// Not paired: the words for the person.
        case failed(String)
    }

    var onDone: ((Outcome) -> Void)?

    let queue: DispatchQueue
    private let targets: [NWEndpoint]
    private let pin: Data?
    private let request: Request
    private let macName: String
    private let identity: RemoteIdentity
    private let deviceName: String
    private let model: String?
    private let dialWait: Double
    /// On `queue`.
    private var connection: NWConnection?
    private var index = 0
    private var finished = false
    private var dialID = 0
    /// Each exchange's own, so a deadline set for one never ends the next.
    private var exchangeID = 0
    private var busyTries = 0
    /// How often a busy Host is tried again: a Host turns a proof away first for its back-off after
    /// a wrong one (1 s, then 2, 4, 8), then for its 5 s between one source's proofs.
    static let busyRetries = 3

    /// - `macName`: what the words call the Host.
    /// - `dialWait`: how long one target may take to be ready before the next is tried.
    init(targets: [NWEndpoint], pin: Data?, request: Request, macName: String, identity: RemoteIdentity,
         deviceName: String, model: String?, dialWait: Double = Double(RemoteTLS.dialTimeout),
         queue: DispatchQueue = DispatchQueue(label: "sill.client.pairing", qos: .userInitiated)) {
        self.targets = targets
        self.pin = pin
        self.request = request
        self.macName = macName
        self.identity = identity
        self.deviceName = deviceName
        self.model = model
        self.dialWait = dialWait
        self.queue = queue
    }

    func start() {
        queue.async { [self] in
            if case .code(let text) = request, case .failure(let problem) = PairingCode.check(text) {
                finish(.failed(problem == .typo ? Words.typo : Words.length))
                return
            }
            dialNext()
        }
    }

    func cancel() {
        queue.async { [self] in
            finished = true
            connection?.cancel()
        }
    }

    // MARK: Dialing

    private func dialNext() {
        guard !finished else { return }
        guard index < targets.count else { finish(.failed(Words.noAnswer(macName))); return }
        let endpoint = targets[index]
        index += 1
        dialID += 1
        let id = dialID
        let tls = RemoteTLS.options(identity: identity.tls, role: .client(alpn: RemoteTLS.pairingALPN), verify: { [pin] fp in
            guard let pin else { return fp != nil }
            return fp == pin
        }, queue: queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(dialWait.rounded(.up)))
        let c = NWConnection(to: endpoint, using: RemoteTLS.parameters(tls: tls, tcp: tcp, peerToPeer: false))
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self, !finished, dialID == id else { return }
            switch state {
            case .ready:
                guard let fp = RemoteTLS.peerFingerprint(c) else { c.cancel(); return giveUp(id) }
                exchange(c, macFingerprint: fp, endpoint: endpoint)
            case .waiting, .failed:
                giveUp(id)
            default:
                break
            }
        }
        c.start(queue: queue)
        // A pin refused over Bonjour never reports a state; a target not ready in time is passed by.
        queue.asyncAfter(deadline: .now() + dialWait) { [weak self, weak c] in
            guard let self, dialID == id, c?.state != .ready else { return }
            giveUp(id)
        }
    }

    private func giveUp(_ id: Int) {
        guard dialID == id, !finished else { return }
        connection?.cancel()
        connection = nil
        dialNext()
    }

    // MARK: The exchange

    private func exchange(_ c: NWConnection, macFingerprint fpMac: Data, endpoint: NWEndpoint) {
        dialID += 1                                      // this connection is the one: no timeout passes it by
        exchangeID += 1
        let id = exchangeID
        let fpDevice = identity.fingerprint
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, exchangeID == id else { return }
            finish(.failed(Words.noAnswer(macName)))
        }
        c.stateUpdateHandler = { [weak self] state in
            guard let self, exchangeID == id else { return }
            if case .failed = state { finish(.failed(Words.noAnswer(macName))) }
        }
        let method: String
        let makeKey: ((Data) -> SymmetricKey?)?
        switch request {
        case .code(let text):
            method = PairRequest.code
            let code = (try? PairingCode.check(text).get()) ?? ""
            makeKey = { PairingProof.codeKey(code: code, macFingerprint: $0) }
        case .link(let link):
            method = PairRequest.qr
            makeKey = { _ in PairingProof.qrKey(secret: link.secret) }
        case .ask:
            method = PairRequest.ask
            makeKey = nil
        }
        let send: (SymmetricKey?) -> Void = { [self] key in
            guard !finished else { return }
            let proof = key.map { Base64URL.encode(PairingProof.deviceProof(key: $0, deviceFingerprint: fpDevice, macFingerprint: fpMac)) } ?? ""
            let request = PairRequest(method: method, proof: proof, name: deviceName, model: model)
            let message = StreamMessage(kind: .pairRequest, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                        payload: Wire.encode(request))
            c.send(content: message.serialized(), completion: .contentProcessed { _ in })
            c.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [self] data, _, _, _ in
                guard let data, let header = StreamMessage.parseHeader(data), header.kind == .pairResult,
                      header.payloadLength > 0, header.payloadLength <= StreamMessage.maxPairingPayload else {
                    return finish(.failed(Words.noAnswer(macName)))
                }
                c.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { [self] data, _, _, _ in
                    guard let data, let result = Wire.decode(PairResult.self, from: data) else {
                        return finish(.failed(Words.noAnswer(macName)))
                    }
                    // Busy (a Host takes no proof for a moment after a wrong one): again, silently, at
                    // the same target, as the iOS app does, a few times (a real Host can say busy
                    // twice in a row: measured against SillHost --pairing).
                    if !result.ok, result.reason == PairResult.busy, busyTries < Self.busyRetries, !finished {
                        busyTries += 1
                        exchangeID += 1
                        c.cancel()
                        connection = nil
                        queue.asyncAfter(deadline: .now() + max(0.2, min(result.retryAfter ?? 1, 10))) { [self] in
                            index -= 1
                            dialNext()
                        }
                        return
                    }
                    finish(judge(result, key: key, macFingerprint: fpMac, endpoint: endpoint))
                }
            }
        }
        guard let makeKey else { return send(nil) }
        // The typed path's PBKDF2 takes 90–160 ms: off this queue.
        DispatchQueue.global(qos: .userInitiated).async { [queue] in
            let key = makeKey(fpMac)
            queue.async { [self] in
                guard let key else { return finish(.failed(Words.noAnswer(macName))) }
                send(key)
            }
        }
    }

    /// Kind 20, judged.
    private func judge(_ r: PairResult, key: SymmetricKey?, macFingerprint fpMac: Data, endpoint: NWEndpoint) -> Outcome {
        if case .ask = request {
            // An ok to an ask comes only for the cable, which this Mac never claims.
            guard !r.ok, let reason = r.reason else { return .failed(Words.proofFailed(macName)) }
            if let words = r.unknownReasonMessage { return .failed(words) }
            return .asked(reason: reason, fingerprint: fpMac, endpoint: endpoint)
        }
        guard r.ok else { return .failed(Words.refusal(r, mac: macName)) }
        guard let key, let proofM = r.proof.flatMap(Base64URL.decode),
              PairingProof.isValidMacProof(proofM, key: key, macFingerprint: fpMac, deviceFingerprint: identity.fingerprint),
              r.macID == MacID.make(fingerprint: fpMac),
              let recognition = r.recognitionKey, Base64URL.decode(recognition)?.count == 32 else {
            return .failed(Words.proofFailed(macName))
        }
        let label = SafeText.label(r.name ?? macName)
        return .paired(PairedHost(macID: MacID.make(fingerprint: fpMac), name: label.isEmpty ? macName : label,
                                  fingerprint: fpMac, recognitionKey: recognition, endpoint: endpoint))
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        connection?.cancel()
        connection = nil
        onDone?(outcome)
    }

    // MARK: Saved Hosts

    /// The remote door's port a record carries until a kind 18 says otherwise (the Host's default).
    static let defaultRemotePort = 7455

    /// Where a saved Host is dialed: its Bonjour service name when it was paired on its row, else
    /// the first address it was paired at.
    static func endpoint(of mac: SavedMac) -> NWEndpoint? {
        if let name = mac.bonjourName { return .service(name: name, type: "_sill._tcp", domain: "local.", interface: nil) }
        guard let a = mac.typedAddresses?.first, let port = NWEndpoint.Port(rawValue: UInt16(clamping: a.port ?? mac.remotePort)) else { return nil }
        return .hostPort(host: NWEndpoint.Host(a.host), port: port)
    }

    /// The pairing proved is in Sill's words.
    enum Words {
        static let length = "A code has 12 digits."
        static let typo = "That code has a typo. Check it against the Mac."
        static func noAnswer(_ mac: String) -> String { "\(mac) didn\u{2019}t answer. Check that Sill is open on it, then try again." }
        static func proofFailed(_ mac: String) -> String {
            "Pairing didn\u{2019}t finish: \(mac) couldn\u{2019}t show it knows the code. Try again."
        }
        static func refusal(_ r: PairResult, mac: String) -> String {
            if let words = r.unknownReasonMessage { return words }
            switch r.reason {
            case PairResult.code?:
                let left = max(0, r.triesLeft ?? 0)
                // A no-break space keeps the count with its word when the line wraps.
                return "That code didn\u{2019}t work. Check the code on \(mac). \(left)\u{00A0}tr\(left == 1 ? "y" : "ies") left."
            case PairResult.expired?:
                return "That code expired. On \(mac), choose Pair iPhone or iPad\u{2026} in the Sill menu for a new one."
            case PairResult.stopped?:
                return "\(mac) stopped pairing after too many wrong codes. On the Mac, choose Pair iPhone or iPad\u{2026} in the Sill menu, then try again."
            case PairResult.busy?:
                return "\(mac) is busy. Wait a moment, then try again."
            default:
                return "That code no longer works. On \(mac), choose Pair iPhone or iPad\u{2026} in the Sill menu, then enter the new code."
            }
        }
    }
}

extension ClientPairing.PairedHost {
    /// The record the iOS app would save after this pairing (SavedMacs' format): pinned to the
    /// Host's key, `homeTLS` (its door speaks TLS), and where it answered: the Bonjour service name
    /// of its row, or the address it was paired at. `method` is "code" or "qr".
    func savedMac(method: String, now: Date = Date()) -> SavedMac {
        var bonjourName: String?
        var typed: [MacAddress]?
        switch endpoint {
        case .service(let name, _, _, _):
            bonjourName = name
        case .hostPort(let host, let port):
            let text: String
            switch host {
            case .name(let n, _): text = n
            case .ipv4(let a): text = "\(a)"
            case .ipv6(let a): text = "\(a)"
            @unknown default: text = "\(host)"
            }
            typed = [MacAddress(host: text, port: Int(port.rawValue), kind: MacAddress.lan, via: "Typed")]
        default:
            break
        }
        return SavedMac(macID: macID, fingerprint: Base64URL.encode(fingerprint), name: name, recognitionKey: recognitionKey,
                        remotePort: ClientPairing.defaultRemotePort, addresses: [], typedAddresses: typed, infoIssuedAt: 0,
                        bonjourName: bonjourName, lastWorked: nil, pairedAt: now, method: method, lastConnectedAt: nil,
                        lastRoute: nil, homeTLS: true, revoked: nil)
    }
}
