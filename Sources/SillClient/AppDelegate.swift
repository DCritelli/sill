import AppKit
import Network
import StreamProtocol

/// Sill Client's app: Connect to a Mac (the Hosts found on the network and the ones saved, Add a
/// Mac…), and one stream window for the one Host connected (DCritelli/sill#2). Choosing another
/// Host, or closing the stream window, goes back through Connect to a Mac.
///
/// Launch arguments for scripts and tests: `-SillSource desktop` asks for the Desktop instead of the
/// first Window (a `SillHost --synthetic`, whose pattern is the Desktop's); `-SillAddress host:port`
/// dials a plain door by its address; `-SillPairAddress host:port -SillPairCode <12 digits>` pairs at
/// that address by code, then connects pinned; `-SillMemoryIdentity 1` keeps this Mac's key in
/// memory for the run (ClientIdentity); `-Sill.savedMacs '[]'` starts with no saved Host for the run.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let connectWindow = ConnectWindow()
    private var model: ConnectModel { connectWindow.model }
    private var streamWindow: NSWindow!
    private let video = VideoView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
    /// What to ask the Host for as the window resizes and moves (DCritelli/sill#6); on main.
    private var viewports = ViewportPolicy()
    private var viewportTimer: Timer?
    private lazy var container = StreamContainerView(video: video)
    /// The Bar's state for the Host connected (DCritelli/sill#7); on main.
    private var bar = BarModel()
    /// Where the stream window was left, for each Host (UserDefaults "SillFrames").
    private var frames = FrameMemory(data: UserDefaults.standard.data(forKey: "SillFrames") ?? Data())
    private var frameKey: String?
    private let browser = HostBrowser()
    private var found: [FoundHost] = []
    /// The one Host connection.
    private var session: ClientSession?
    private var pairing: ClientPairing?
    /// Where the code typed next goes: the Host an ask reached, pinned to the key it answered with.
    private var codeTarget: (endpoint: NWEndpoint, pin: Data, name: String)?
    private var launched = false
    private var pendingLinks: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        streamWindow = NSWindow(contentRect: video.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
        streamWindow.isReleasedWhenClosed = false
        streamWindow.contentView = container
        container.bar.onSelect = { [weak self] source in self?.session?.sendSource(source) }
        container.bar.onCommand = { [weak self] action, id in self?.session?.sendWindowCommand(WindowCommand(id: id, action: action)) }
        streamWindow.collectionBehavior.insert(.fullScreenPrimary)
        streamWindow.delegate = self
        video.onContentSize = { [weak self] size in
            guard let self else { return }
            self.sendViewport(self.viewports.contentSizeChanged(size, now: Self.now))
        }
        NSApp.mainMenu = Self.mainMenu()

        model.onConnect = { [weak self] in self?.connect($0) }
        model.onForget = { [weak self] row in
            guard case .saved(let mac, _) = row.kind else { return }
            SavedHosts.forget(mac.macID)
            self?.model.status = "\(mac.name) is forgotten. Pair with it again to connect."
            self?.refreshRows()
        }
        model.onAddMac = { [weak self] in
            self?.codeTarget = nil
            self?.model.codeSheet = ConnectModel.CodeSheet(host: nil,
                note: "On the Mac you want to add, choose Pair iPhone or iPad\u{2026} in the Sill menu, then enter the code it shows.")
        }
        model.onCode = { [weak self] code, host, address in self?.pairByCode(code, host: host, address: address) }
        model.onCancelCode = { [weak self] in self?.codeTarget = nil }
        browser.onChange = { [weak self] hosts in self?.found = hosts; self?.refreshRows() }
        refreshRows()
        connectWindow.show()
        NSApp.activate(ignoringOtherApps: true)
        browser.start()
        launched = true

        let defaults = UserDefaults.standard
        if let text = defaults.string(forKey: "SillPairAddress"), let endpoint = Self.endpoint(text),
           let code = defaults.string(forKey: "SillPairCode") {
            pair(.code(code), targets: [endpoint], pin: nil, name: text)
        } else if let text = defaults.string(forKey: "SillAddress"), let endpoint = Self.endpoint(text) {
            startSession(endpoint, parameters: ClientSession.plainParameters(), name: text, macID: nil)
        }
        pendingLinks.forEach(openLink)
        pendingLinks = []
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { session?.stop() }

    /// `sill://pair` links (CFBundleURLTypes), always behind a confirmation, as on the iOS app.
    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { urls.forEach(openLink) } else { pendingLinks += urls }
    }

    private func openLink(_ url: URL) {
        guard case .success(let link) = PairLink.parse(url.absoluteString) else {
            connectWindow.show()
            model.status = "That link isn\u{2019}t a Sill pairing link."
            return
        }
        connectWindow.show()
        let alert = NSAlert()
        alert.messageText = "Pair with \(link.name)?"
        alert.informativeText = "Sill Client will pair this Mac with \(link.name), then connect to it."
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The Host's rows on this network first (only its own key answers), then the link's addresses.
        var targets = found.filter { $0.door != .plain }.map(\.endpoint)
        targets += link.addresses.compactMap { a in
            NWEndpoint.Port(rawValue: UInt16(clamping: a.port ?? link.port)).map { NWEndpoint.hostPort(host: NWEndpoint.Host(a.host), port: $0) }
        }
        pair(.link(link), targets: targets, pin: link.fingerprint, name: link.name, dialWait: 4)
    }

    // MARK: Connect to a Mac

    private func refreshRows() {
        model.rows = HostRow.rows(saved: SavedHosts.all, found: found)
    }

    private func connect(_ row: HostRow) {
        model.status = nil
        switch row.kind {
        case .saved(let mac, let host):
            guard let endpoint = host?.endpoint ?? ClientPairing.endpoint(of: mac), let pin = mac.fingerprintData else {
                model.status = "\(mac.name) isn\u{2019}t on this network. Open Sill on it, then try again."
                return
            }
            startSession(endpoint, parameters: pinned(pin), name: mac.name, macID: mac.macID, bonjourName: host?.name)
        case .found(let host):
            switch host.door {
            case .plain: startSession(host.endpoint, parameters: ClientSession.plainParameters(), name: host.name, macID: nil)
            case .open: startSession(host.endpoint, parameters: pinned(nil), name: host.name, macID: nil)
            case .pairingRequired: ask(host)
            }
        }
    }

    private func pinned(_ pin: Data?) -> NWParameters {
        guard let identity = ClientIdentity.loadOrCreate() else { return ClientSession.refusingParameters() }
        return ClientSession.pinnedParameters(identity: identity, pin: pin)
    }

    /// An unpaired Host's row: ask it to show its code, then take the code pinned to the key that answered.
    private func ask(_ host: FoundHost) {
        guard let identity = ClientIdentity.loadOrCreate() else { model.status = Self.noIdentity; return }
        model.working = true
        model.status = "Asking \(host.name) for a code\u{2026}"
        let p = makePairing(.ask, targets: [host.endpoint], pin: nil, name: host.name, identity: identity, dialWait: 10)
        p.onDone = { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self, self.pairing === p else { return }
                self.pairing = nil
                self.model.working = false
                switch outcome {
                case .asked(let reason, let fp, let endpoint):
                    if reason == PairResult.locked { self.model.status = "Unlock \(host.name), then try again."; return }
                    self.codeTarget = (endpoint, fp, host.name)
                    self.model.status = nil
                    let note = reason == PairResult.shown
                        ? "Enter the code \(host.name) shows."
                        : "On \(host.name), choose Pair iPhone or iPad\u{2026} in the Sill menu, then enter the code it shows."
                    self.model.codeSheet = ConnectModel.CodeSheet(host: host.name, note: note)
                case .failed(let words):
                    self.model.status = words
                case .paired:
                    break   // an ask never pairs
                }
            }
        }
        p.start()
    }

    private func pairByCode(_ code: String, host: String?, address: String) {
        if let target = codeTarget {
            codeTarget = nil
            pair(.code(code), targets: [target.endpoint], pin: target.pin, name: target.name)
        } else if let host, let row = found.first(where: { $0.name == host }) {
            pair(.code(code), targets: [row.endpoint], pin: nil, name: host)
        } else if let endpoint = Self.endpoint(address) {
            pair(.code(code), targets: [endpoint], pin: nil, name: address)
        } else {
            model.status = "That address isn\u{2019}t one Sill can dial. Type a name or an IP address, with its port if it has one."
        }
    }

    private func pair(_ request: ClientPairing.Request, targets: [NWEndpoint], pin: Data?, name: String, dialWait: Double = 10) {
        guard let identity = ClientIdentity.loadOrCreate() else { model.status = Self.noIdentity; return }
        let method: String = { if case .link = request { return PairRequest.qr }; return PairRequest.code }()
        model.working = true
        model.status = "Pairing with \(name)\u{2026}"
        let p = makePairing(request, targets: targets, pin: pin, name: name, identity: identity, dialWait: dialWait)
        p.onDone = { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self, self.pairing === p else { return }
                self.pairing = nil
                self.model.working = false
                switch outcome {
                case .paired(let host):
                    SavedHosts.add(host.savedMac(method: method))
                    self.refreshRows()
                    self.model.status = "Paired with \(host.name)."
                    print("Paired with \(host.name) (\(host.macID)), proof checked, pin saved")
                    self.startSession(host.endpoint, parameters: ClientSession.pinnedParameters(identity: identity, pin: host.fingerprint),
                                      name: host.name, macID: host.macID)
                case .failed(let words):
                    self.model.status = words
                    print("Pairing with \(name) failed: \(words)")
                case .asked:
                    break
                }
            }
        }
        p.start()
    }

    private func makePairing(_ request: ClientPairing.Request, targets: [NWEndpoint], pin: Data?, name: String,
                             identity: RemoteIdentity, dialWait: Double) -> ClientPairing {
        pairing?.cancel()
        let p = ClientPairing(targets: targets, pin: pin, request: request, macName: name, identity: identity,
                              deviceName: Self.computerName, model: Self.model, dialWait: dialWait)
        pairing = p
        return p
    }

    // MARK: The one session

    /// One Host at a time: whatever was connected is let go first.
    private func startSession(_ endpoint: NWEndpoint, parameters: NWParameters, name: String, macID: String?, bonjourName: String? = nil) {
        disconnect()
        streamWindow.title = name
        bar = BarModel()
        container.bar.update(bar)
        frameKey = FrameMemory.key(macID: macID, name: name)
        if let remembered = frames.frame(for: frameKey!), !streamWindow.isVisible {
            streamWindow.setFrame(streamWindow.constrainFrameRect(remembered, to: streamWindow.screen ?? NSScreen.main), display: false)
        }
        let pick: ClientSession.Pick = UserDefaults.standard.string(forKey: "SillSource") == "desktop" ? .desktop : .firstWindow
        let size = video.bounds.size
        let fps = streamWindow.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        viewports.sourceKind = .window
        _ = viewports.hostMaxFPSChanged(nil, now: Self.now)
        _ = viewports.displayChanged(maxFPS: fps, now: Self.now)
        _ = viewports.contentSizeChanged(size, now: Self.now)
        viewports.sessionStarted()   // nothing of this has been sent on the new connection
        let session = ClientSession(endpoint: endpoint, parameters: parameters, hello: Self.hello,
                                    pick: pick, viewport: Viewport(width: size.width, height: size.height, scale: nil, fps: fps))
        var first = true
        session.onWindowList = { [weak self] list in
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }
                if first, let macID {
                    first = false
                    SavedHosts.connected(macID, bonjourName: bonjourName)
                    self.refreshRows()
                }
                self.bar.windowListReceived(list)
                self.container.bar.update(self.bar)
                self.streamWindow.title = self.bar.windowTitle
                let kind: ViewportPolicy.SourceKind = self.bar.desktopActive ? .desktop : .window
                if kind != self.viewports.sourceKind {
                    self.sendViewport(self.viewports.sourceChanged(kind, now: Self.now))
                }
            }
        }
        session.onThumbnail = { [weak self] blob in
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }
                self.bar.thumbnailReceived(blob)
                self.container.bar.update(self.bar)
            }
        }
        session.onIcon = { [weak self] blob in
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }
                self.bar.iconReceived(blob)
                self.container.bar.update(self.bar)
            }
        }
        session.onParameterSets = { [video] in video.apply($0) }
        session.onFrame = { [video] in video.enqueue($0, isKeyframe: $1) }
        session.onCursorShape = { [video] blob in DispatchQueue.main.async { video.setCursorShape(blob) } }
        video.onInput = { [weak session] in session?.sendInput($0) }
        session.onEnd = { [weak self] why in
            print("Session ended: \(why)")
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }
                self.video.clear()
                self.streamWindow.title = "\(name) — disconnected"
                self.model.status = "Disconnected from \(name)."
            }
        }
        self.session = session
        print("Connecting to \(name)")
        streamWindow.makeKeyAndOrderFront(nil)
        streamWindow.makeFirstResponder(video)
        connectWindow.window.orderOut(nil)
        session.start()
    }

    // MARK: Viewport (DCritelli/sill#6)

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Sends a Viewport the policy made, and arms the timer for one it holds back.
    private func sendViewport(_ viewport: Viewport?) {
        if let viewport { session?.sendViewport(viewport) }
        viewportTimer?.invalidate()
        viewportTimer = nil
        guard let deadline = viewports.pendingDeadline else { return }
        // Common modes: a live resize tracks the event loop in its own mode.
        let timer = Timer(timeInterval: max(deadline - Self.now, 0.005), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.viewportTimer = nil
            self.sendViewport(self.viewports.tick(now: Self.now))
        }
        RunLoop.main.add(timer, forMode: .common)
        viewportTimer = timer
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberFrame()
        sendViewport(viewports.resizeEnded(now: Self.now))
    }

    func windowWillEnterFullScreen(_ notification: Notification) { container.setFullScreen(true) }
    func windowDidEnterFullScreen(_ notification: Notification) {
        sendViewport(viewports.resizeEnded(now: Self.now))
    }

    func windowWillExitFullScreen(_ notification: Notification) { container.setFullScreen(false) }

    func windowDidExitFullScreen(_ notification: Notification) {
        sendViewport(viewports.resizeEnded(now: Self.now))
    }

    /// Another display: its maximum refresh rate is asked for.
    func windowDidChangeScreen(_ notification: Notification) {
        guard let fps = streamWindow.screen?.maximumFramesPerSecond else { return }
        sendViewport(viewports.displayChanged(maxFPS: fps, now: Self.now))
    }

    private func rememberFrame() {
        guard let key = frameKey, streamWindow.isVisible, !streamWindow.styleMask.contains(.fullScreen) else { return }
        frames.remember(streamWindow.frame, for: key)
        UserDefaults.standard.set(frames.data, forKey: "SillFrames")
    }

    func windowDidMove(_ notification: Notification) { rememberFrame() }

    @objc func toggleBar(_ sender: NSMenuItem) {
        container.toggleBar()
        sender.title = container.visibility.menuTitle
    }

    private func disconnect() {
        rememberFrame()
        session?.stop()
        session = nil
        video.onInput = nil
        video.clear()
    }

    /// Back to Connect to a Mac: the session ends, the stream window goes.
    @objc func showConnect(_ sender: Any?) {
        disconnect()
        streamWindow.orderOut(nil)
        connectWindow.show()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === streamWindow else { return }
        // Closing the stream window disconnects (the remote Window stays open on the Host).
        disconnect()
        connectWindow.show()
    }

    // MARK: Menus and names

    /// Sill Client's own commands, reachable with the mouse: while the picture has the keys, their
    /// shortcuts go to the Host (DCritelli/sill#4).
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Sill Client")
        appMenu.addItem(withTitle: "Connect to a Mac\u{2026}", action: #selector(showConnect(_:)), keyEquivalent: "K")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Sill Client", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sill Client", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let hideBar = NSMenuItem(title: "Hide Bar", action: #selector(toggleBar(_:)), keyEquivalent: "b")
        hideBar.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(hideBar)
        viewItem.submenu = viewMenu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }

    private static let noIdentity = "Sill Client couldn\u{2019}t make its key in the keychain, so it can\u{2019}t pair. The log says why."

    /// "host:port", "[v6]:port", or a name or address alone (the remote door's port, 7455).
    static func endpoint(_ text: String) -> NWEndpoint? {
        guard case .success(let a) = AddressParser.parse(text.trimmingCharacters(in: .whitespaces)),
              let port = NWEndpoint.Port(rawValue: UInt16(clamping: a.port ?? ClientPairing.defaultRemotePort)) else { return nil }
        return .hostPort(host: NWEndpoint.Host(a.host), port: port)
    }

    /// This Mac's computer name: how the Host's paired-device list names it.
    static let computerName = Host.current().localizedName ?? "Mac"

    /// "Mac14,9".
    static let model: String? = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let id = String(cString: model)
        return id.isEmpty ? nil : id
    }()

    /// The hello (kind 23): this app's version and build, and the Mac as "computer name (model)",
    /// the shape the iOS app gives its device.
    static let hello: Hello = {
        let info = Bundle.main.infoDictionary
        return Hello(appVersion: info?["CFBundleShortVersionString"] as? String ?? "0.0",
                     build: info?["CFBundleVersion"] as? String, protocol: SillProtocol.current,
                     device: model.map { "\(computerName) (\($0))" } ?? computerName)
    }()
}
