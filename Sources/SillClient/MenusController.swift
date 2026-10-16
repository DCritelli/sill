import AppKit
import StreamProtocol

/// The Menus button's AppKit shell (DCritelli/sill#8): a pull-down NSMenu of the Host app's menus,
/// each submenu fetched when it opens (a "Loading…" row until the answer), items shown with their
/// shortcut as text, disabled and checked as on the Host, a choice pressed on the Host. What it
/// holds is MenusModel's; on the main thread. Not unit-tested (AppKit): MenusModel is.
final class MenusController: NSObject, NSMenuDelegate {
    let button: NSButton
    var onFetch: ((FetchMenu) -> Void)?
    var onPress: ((PressMenuItem) -> Void)?

    private var model = MenusModel()
    /// The menu each open request fills, by the model's key.
    private var pending: [Int: NSMenu] = [:]
    private var rows: [ObjectIdentifier: MenusModel.Item] = [:]
    private var macName = ""
    private var timer: Timer?
    private static let shortcutTab: CGFloat = 220

    override init() {
        button = NSButton(title: "Menus", target: nil, action: nil)
        super.init()
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: "filemenu.and.selection", accessibilityDescription: "Menus")
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(showMenus(_:))
        button.isHidden = true
    }

    func setMacName(_ name: String) { macName = name }

    func received(_ menu: MacMenu) {
        let update = model.receive(menu, now: Self.now)
        apply(update.settled)
        if let refusal = update.refusal { refused(refusal) }
        refreshButton()
        scheduleTimeout()
    }

    /// The connection ended or changed: waiting menus say so, the button goes.
    func reset() {
        apply(model.reset())
        refreshButton()
        timer?.invalidate(); timer = nil
    }

    private func refreshButton() {
        button.isHidden = !model.hasMenus
        button.toolTip = model.appName.map { "\($0) menus" }
        button.setAccessibilityLabel(model.appName.map { "\($0) menus" } ?? "Menus")
    }

    @objc private func showMenus(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if model.topMenus.isEmpty, let note = model.topNote {
            populate(menu, [[MenusModel.item(.note(note))]])
        } else {
            for top in model.topMenus { menu.addItem(menuItem(for: top)) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: sender)
    }

    // MARK: Building

    private func menuItem(for item: MenusModel.Item) -> NSMenuItem {
        let mi = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        mi.isEnabled = item.enabled
        switch item.kind {
        case .submenu:
            let sub = NSMenu(title: item.title)
            sub.autoenablesItems = false
            sub.delegate = self
            rows[ObjectIdentifier(sub)] = item
            mi.submenu = sub
        case .item:
            mi.target = self
            mi.action = #selector(chosen(_:))
            mi.representedObject = Box(item)
            mi.state = item.check == .on ? .on : (item.check == .mixed ? .mixed : .off)
            if item.shortcut != nil || !item.enabled { mi.attributedTitle = Self.attributed(item) }
        case .note:
            break
        }
        return mi
    }

    /// The title, then the Host's shortcut as text at a right tab stop, grey; disabled items grey.
    private static func attributed(_ item: MenusModel.Item) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: shortcutTab)]
        let font = NSFont.menuFont(ofSize: 0)
        let title = item.enabled ? NSColor.labelColor : NSColor.disabledControlTextColor
        let out = NSMutableAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: title, .paragraphStyle: style])
        if let key = item.shortcut {
            out.append(NSAttributedString(string: "\t" + key, attributes: [.font: font, .paragraphStyle: style,
                .foregroundColor: item.enabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor]))
        }
        return out
    }

    private func populate(_ menu: NSMenu, _ sections: [[MenusModel.Item]]) {
        menu.removeAllItems()
        for (i, section) in sections.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for item in section { menu.addItem(menuItem(for: item)) }
        }
    }

    private func apply(_ settled: [(key: Int, items: [[MenusModel.Item]])]) {
        for s in settled {
            guard let menu = pending.removeValue(forKey: s.key) else { continue }
            populate(menu, s.items)
        }
    }

    // MARK: Submenus

    func menuWillOpen(_ menu: NSMenu) {
        guard let item = rows[ObjectIdentifier(menu)] else { return }
        let opened = model.open(item.row, now: Self.now)
        if let now = opened.now {
            populate(menu, now)
        } else {
            let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.removeAllItems()
            menu.addItem(loading)
            pending[opened.key] = menu
        }
        if let fetch = opened.send { onFetch?(fetch) }
        scheduleTimeout()
    }

    func menuDidClose(_ menu: NSMenu) {
        // A fetch nobody waits on any more is let go when it answers; its key stays until then.
        for (key, m) in pending where m === menu { pending[key] = nil }
    }

    // MARK: Choosing

    private final class Box: NSObject {
        let item: MenusModel.Item
        init(_ item: MenusModel.Item) { self.item = item }
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? Box, let press = model.choose(box.item) else { return }
        switch press {
        case .send(let p): onPress?(p)
        case .refused(let r): refused(r)
        }
    }

    private func refused(_ r: MacMenuState.Refusal) {
        NSSound.beep()
        print("Menu: \(r.announcement)")
    }

    // MARK: Timeout

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    private func scheduleTimeout() {
        guard timer == nil, model.state.oldestWait != nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.apply(self.model.expire(now: Self.now, timeout: 4, mac: self.macName))
            if self.model.state.oldestWait == nil { self.timer?.invalidate(); self.timer = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
