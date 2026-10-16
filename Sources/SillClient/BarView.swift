import AppKit
import StreamProtocol

/// The Bar's strip (DCritelli/sill#7): a Desktop button and one thumbnail per Window of the Host,
/// each with its app's icon, the Source's marked. What it shows is BarModel's; a click goes to
/// `onSelect`, the context menu (Close, Minimize, Full Screen) to `onCommand`. Flipped.
final class BarView: NSView {
    static let height: CGFloat = 78

    var onSelect: ((StreamSource) -> Void)?
    var onCommand: ((WindowCommand.Action, UInt32) -> Void)?

    private var model = BarModel()
    private var buttons: [NSView] = []
    private static let thumbSize = CGSize(width: 104, height: 62)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The Menus button (DCritelli/sill#8), at the trailing edge; MenusController owns it.
    func install(menusButton button: NSButton) {
        addSubview(button)
        button.autoresizingMask = [.minXMargin]
        button.frame = CGRect(x: bounds.width - 92, y: (Self.height - 28) / 2, width: 84, height: 28)
    }

    override func layout() {
        super.layout()
        for case let b as NSButton in subviews { b.frame.origin.x = bounds.width - b.frame.width - 8 }
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    func update(_ model: BarModel) {
        self.model = model
        buttons.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 8
        let y = (Self.height - Self.thumbSize.height) / 2
        let desktop = TileView(title: "Desktop", image: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "Desktop"),
                               icon: nil, active: model.desktopActive)
        desktop.frame = CGRect(x: x, y: y, width: 72, height: Self.thumbSize.height)
        desktop.onClick = { [weak self] in self?.onSelect?(.desktop) }
        addSubview(desktop)
        buttons = [desktop]
        x += 72 + 8
        for item in model.items {
            let tile = TileView(title: item.title.isEmpty ? item.appName : item.title,
                                image: item.thumbnail.flatMap { NSImage(data: $0) },
                                icon: item.icon.flatMap { NSImage(data: $0) }, active: model.isActive(item.id))
            tile.frame = CGRect(x: x, y: y, width: Self.thumbSize.width, height: Self.thumbSize.height)
            let id = item.id
            tile.onClick = { [weak self] in
                if let source = self?.model.select(windowID: id) { self?.onSelect?(source) }
            }
            tile.menu = contextMenu(for: id)
            addSubview(tile)
            buttons.append(tile)
            x += Self.thumbSize.width + 8
        }
    }

    private func contextMenu(for id: UInt32) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Close", WindowCommand.Action.close), ("Minimize", .minimize), ("Full Screen", .fullScreen)] {
            let item = NSMenuItem(title: title, action: #selector(commandChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CommandBox(id: id, action: action)
            menu.addItem(item)
        }
        return menu
    }

    private final class CommandBox: NSObject {
        let id: UInt32, action: WindowCommand.Action
        init(id: UInt32, action: WindowCommand.Action) { self.id = id; self.action = action }
    }

    @objc private func commandChosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox,
              let command = model.command(box.action, windowID: box.id) else { return }
        onCommand?(command.action, command.id)
    }
}

/// One Window's thumbnail (or the Desktop button): the picture, the app's icon in a corner, the
/// Source ringed.
private final class TileView: NSView {
    var onClick: (() -> Void)?
    private let image: NSImage?
    private let icon: NSImage?
    private let active: Bool

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title: String, image: NSImage?, icon: NSImage?, active: Bool) {
        self.image = image
        self.icon = icon
        self.active = active
        super.init(frame: .zero)
        toolTip = title
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        if let image {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            if image.isTemplate || image.size.width < 64 {
                image.draw(in: CGRect(x: bounds.midX - 14, y: bounds.midY - 14, width: 28, height: 28))
            } else {
                image.draw(in: bounds.insetBy(dx: 1, dy: 1), from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if let icon {
            icon.draw(in: CGRect(x: 5, y: bounds.height - 23, width: 18, height: 18), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
        }
        (active ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        shape.lineWidth = active ? 2.5 : 1
        shape.stroke()
    }
}

/// The stream window's content: the picture, with the Bar above it. Outside full screen the Bar takes
/// its height from the picture; in full screen the picture keeps the whole screen and the Bar, when
/// the pointer reaches the top edge, is drawn over it. The visibility rules are BarVisibility's.
/// A message over the last picture (DCritelli/sill#9): "Reconnecting\u{2026}" while the Host is
/// dialed again, or a Host's final reason with the way back to Connect to a Mac. It takes the
/// mouse, so nothing reaches the Host through it.
final class StatusOverlayView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(pressed)
        addSubview(label)
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self.frame.contains(point) ? (super.hitTest(point) ?? self) : nil }
    override func mouseDown(with event: NSEvent) {}

    func show(_ text: String, actionTitle: String?, action: (() -> Void)?) {
        label.stringValue = text
        button.title = actionTitle ?? ""
        button.isHidden = actionTitle == nil
        self.action = action
        isHidden = false
        needsLayout = true
    }

    @objc private func pressed() { action?() }

    override func layout() {
        super.layout()
        let width = min(max(bounds.width - 48, 80), 460)
        let text = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        let buttonHeight: CGFloat = button.isHidden ? 0 : 32
        let gap: CGFloat = button.isHidden ? 0 : 14
        let total = text.height + gap + buttonHeight
        let top = (bounds.height - total) / 2
        label.frame = NSRect(x: (bounds.width - width) / 2, y: top, width: width, height: text.height)
        button.sizeToFit()
        button.frame = NSRect(x: (bounds.width - button.frame.width) / 2, y: top + text.height + gap,
                              width: button.frame.width, height: 32)
    }
}

final class StreamContainerView: NSView {
    let bar = BarView(frame: .zero)
    private let status = StatusOverlayView(frame: .zero)
    let video: NSView
    private(set) var visibility = BarVisibility()
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(video: NSView) {
        self.video = video
        super.init(frame: video.frame)
        addSubview(video)
        addSubview(bar)
        addSubview(status)
        status.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    var barVisible: Bool { visibility.visible }

    /// A message over the picture, with a button when `actionTitle` is given.
    func showStatus(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        status.show(text, actionTitle: actionTitle, action: action)
        needsLayout = true
    }
    func hideStatus() { status.isHidden = true }

    func toggleBar() { visibility.toggle(); needsLayout = true }
    func setFullScreen(_ on: Bool) {
        visibility.fullScreen = on
        visibility.pointerAtTop = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = BarView.height
        bar.isHidden = !visibility.visible
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        let inset = (visibility.userHidden || visibility.fullScreen) ? 0 : h
        video.frame = CGRect(x: 0, y: inset, width: bounds.width, height: max(bounds.height - inset, 0))
        status.frame = video.frame
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { setPointerAtTop(false) }

    private func pointerMoved(to p: CGPoint) {
        guard visibility.fullScreen else { return }
        let at = visibility.pointerAtTop
            ? BarVisibility.stillRevealed(pointerY: p.y, barHeight: BarView.height, in: bounds.height)
            : BarVisibility.reveals(pointerY: p.y, in: bounds.height)
        setPointerAtTop(at)
    }

    private func setPointerAtTop(_ at: Bool) {
        guard visibility.pointerAtTop != at else { return }
        visibility.pointerAtTop = at
        needsLayout = true
    }
}
