import Foundation
import Network
#if canImport(StreamProtocol)
import StreamProtocol
#endif

/// When the redial of a dropped Host comes (DCritelli/sill#9): the first soon, then further apart,
/// and it gives up after `maxAttempts` in a row.
enum RedialPolicy {
    static let delays: [Double] = [0.5, 1, 2, 4, 8, 15, 30]
    static let maxAttempts = 12

    /// The wait before attempt `attempt` (0 is the first redial after a drop).
    static func delay(attempt: Int, schedule: [Double] = delays) -> Double {
        schedule[min(max(attempt, 0), schedule.count - 1)]
    }
}

/// The Mac Client's connection to one saved or found Host across drops (docs/adr/0002): a
/// `ClientSession` that is dialed again when it ends, by the iOS app's rules. Without a goodbye
/// (the link dropped, the Host slept or restarted, the network changed) or with one that allows it
/// (`GoodbyePolicy`: quit, Remote Access off, busy, a notice with `reconnect`), the Host is dialed
/// again with growing waits and the same Source is resumed when the Host still lists it. A goodbye
/// that says not to reconnect (removed, update, pairing required, a notice without `reconnect`)
/// stops here with the Host's reason and never redials. A Host that never answered the first dial
/// stops too: only a connection that was up is carried on. Foundation, Network, StreamProtocol and
/// GoodbyePolicy only: checked against the stand-in Host (Tests/checks/client-session).
///
/// Every session runs on `queue`, one at a time, and so do the callbacks here; `start()` and
/// `stop()` may be called from any thread.
final class ClientConnection {
    enum State: Equatable {
        case connecting
        /// A Window list has come on the current session.
        case connected
        /// Dropped; the next dial is `attempt` (1 is the first).
        case reconnecting(attempt: Int)
        /// Final. `reason` is the Host's words or ours; `storeLink`: offer the App Store ("update").
        case stopped(reason: String, storeLink: Bool)
    }

    struct Dial {
        var endpoint: NWEndpoint
        var parameters: NWParameters
    }

    /// For each session as it is made, before it starts: the owner sets its callbacks (everything
    /// but `onEnd` and `onGoodbye`, which are this class's, and `onWindowList`, which it wraps).
    var attach: ((ClientSession) -> Void)?
    var onState: ((State) -> Void)?
    /// The Host's goodbye, whatever it leads to (for the log).
    var onGoodbye: ((Goodbye) -> Void)?

    let queue: DispatchQueue
    private let name: String
    private let saved: Bool
    private let hello: Hello
    private let pick: ClientSession.Pick
    private let viewport: () -> Viewport
    private let dial: () -> Dial?
    private let schedule: [Double]
    private let maxAttempts: Int

    // All on `queue`.
    private var running = false
    private var current: ClientSession?
    private var goodbye: Goodbye?
    private var everConnected = false
    private var failures = 0
    private var lastSource: StreamSource?
    private var generation = 0

    /// - `dial`: where the Host is now, asked at every attempt (its Bonjour row may have moved);
    ///   nil: not found, which counts as a failed attempt.
    /// - `viewport`: the window's size now, for the pick of each new session.
    init(name: String, saved: Bool, hello: Hello, pick: ClientSession.Pick, viewport: @escaping () -> Viewport,
         dial: @escaping () -> Dial?, schedule: [Double] = RedialPolicy.delays, maxAttempts: Int = RedialPolicy.maxAttempts,
         queue: DispatchQueue = DispatchQueue(label: "sill.client.connection", qos: .userInteractive)) {
        self.name = name; self.saved = saved; self.hello = hello; self.pick = pick; self.viewport = viewport
        self.dial = dial; self.schedule = schedule; self.maxAttempts = maxAttempts; self.queue = queue
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            onState?(.connecting)
            launch()
        }
    }

    /// Ends it for good: no callback follows.
    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            generation += 1
            current?.stop()
            current = nil
        }
    }

    private func launch() {
        guard running else { return }
        guard let target = dial() else { failed("\(name) isn\u{2019}t on this network."); return }
        let session = ClientSession(endpoint: target.endpoint, parameters: target.parameters, hello: hello,
                                    pick: lastSource.map { .resume($0) } ?? pick, viewport: viewport(), queue: queue)
        goodbye = nil
        attach?(session)
        let owners = session.onWindowList
        session.onWindowList = { [weak self, weak session] list in
            guard let self, self.current === session else { return }
            self.everConnected = true
            self.failures = 0
            if list.active != .none { self.lastSource = list.active }
            self.onState?(.connected)
            owners?(list)
        }
        let ownerPicked = session.onPicked
        session.onPicked = { [weak self] source in
            self?.lastSource = source
            ownerPicked?(source)
        }
        session.onGoodbye = { [weak self, weak session] in
            guard let self, self.current === session else { return }
            self.goodbye = $0
            self.onGoodbye?($0)
        }
        session.onEnd = { [weak self, weak session] why in
            guard let self, self.current === session else { return }
            self.ended(why)
        }
        current = session
        session.start()
    }

    private func ended(_ why: String) {
        guard running else { return }
        current = nil
        if let goodbye {
            let outcome = GoodbyePolicy.outcome(goodbye, mac: name, device: "Mac", saved: saved)
            guard outcome.reconnect else { stopFor(outcome.text, storeLink: outcome.storeLink); return }
            failed(outcome.text)
            return
        }
        failed(nil)
    }

    /// A dial that did not hold: another attempt, or the end of them.
    private func failed(_ unreachable: String?) {
        guard running else { return }
        guard everConnected else {
            stopFor(unreachable ?? "\(name) didn\u{2019}t answer. Check that Sill is open on it.", storeLink: false)
            return
        }
        guard failures < maxAttempts else {
            stopFor("\(name) didn\u{2019}t come back. Check that Sill is open on it, then connect again.", storeLink: false)
            return
        }
        let wait = RedialPolicy.delay(attempt: failures, schedule: schedule)
        failures += 1
        generation += 1
        let mine = generation
        onState?(.reconnecting(attempt: failures))
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.running, self.generation == mine else { return }
            self.launch()
        }
    }

    private func stopFor(_ reason: String, storeLink: Bool) {
        running = false
        generation += 1
        onState?(.stopped(reason: reason, storeLink: storeLink))
    }
}
