import AppKit
import Network
import StreamProtocol

/// The tracer's app: one ordinary window that shows the first Host found on the home network with a
/// plain door, and in it the first Window that Host lists. `-SillSource desktop` asks for the
/// Desktop instead (for a `SillHost --synthetic`, whose pattern is the Desktop's); `-SillAddress
/// host:port` dials a plain door by its address instead of browsing.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let video = VideoView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
    private let browser = HostBrowser()
    private var session: ClientSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: video.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Looking for a Mac…"
        window.contentView = video
        window.makeFirstResponder(video)
        NSApp.mainMenu = Self.mainMenu()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // `-SillAddress host:port` dials that plain door without browsing (a Host whose Bonjour this
        // Mac cannot see, or a script's).
        if let address = UserDefaults.standard.string(forKey: "SillAddress"),
           let colon = address.lastIndex(of: ":"), let port = NWEndpoint.Port(String(address[address.index(after: colon)...])) {
            let host = String(address[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            connect(to: .hostPort(host: NWEndpoint.Host(host), port: port), name: address)
            return
        }
        browser.onFound = { [weak self] endpoint, name in self?.connect(to: endpoint, name: name) }
        browser.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { session?.stop() }

    private func connect(to endpoint: NWEndpoint, name: String) {
        window.title = name
        let pick: ClientSession.Pick = UserDefaults.standard.string(forKey: "SillSource") == "desktop" ? .desktop : .firstWindow
        let size = video.bounds.size
        let fps = window.screen?.maximumFramesPerSecond ?? 60
        let session = ClientSession(endpoint: endpoint, parameters: ClientSession.plainParameters(), hello: Self.hello,
                                    pick: pick, viewport: Viewport(width: size.width, height: size.height, scale: nil, fps: fps))
        session.onWindowList = { [weak self] list in
            DispatchQueue.main.async {
                guard let self, case .window(let id) = list.active, let shown = list.windows.first(where: { $0.id == id }) else { return }
                self.window.title = "\(shown.title.isEmpty ? shown.appName : shown.title) — \(list.macName)"
            }
        }
        session.onParameterSets = { [video] in video.apply($0) }
        session.onFrame = { [video] in video.enqueue($0, isKeyframe: $1) }
        session.onCursorShape = { [video] blob in DispatchQueue.main.async { video.setCursorShape(blob) } }
        video.onInput = { [weak session] in session?.sendInput($0) }
        session.onEnd = { [weak self] why in
            print("Session ended: \(why)")
            DispatchQueue.main.async {
                self?.video.clear()
                self?.window.title = "\(name) — disconnected"
            }
        }
        self.session = session
        print("Connecting to \(name)")
        session.start()
    }

    /// Sill Client's own commands, reachable with the mouse: while the picture has the keys, their
    /// shortcuts go to the Host (DCritelli/sill#4).
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Sill Client")
        appMenu.addItem(withTitle: "Hide Sill Client", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sill Client", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }

    /// The hello (kind 23): this app's version and build, and the Mac as "computer name (model)",
    /// the shape the iOS app gives its device.
    static let hello: Hello = {
        let info = Bundle.main.infoDictionary
        let name = Host.current().localizedName ?? "Mac"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let id = String(cString: model)
        return Hello(appVersion: info?["CFBundleShortVersionString"] as? String ?? "0.0",
                     build: info?["CFBundleVersion"] as? String, protocol: SillProtocol.current,
                     device: id.isEmpty ? name : "\(name) (\(id))")
    }()
}
