import CoreGraphics
import Foundation
// In the app StreamProtocol is its own module; the bar-model check compiles this file together with
// Sources/StreamProtocol as one module, where there is nothing to import.
#if canImport(StreamProtocol)
import StreamProtocol
#endif

/// The Bar's state (DCritelli/sill#7): the Host's Windows in the Host's order with the thumbnail
/// and icon received for each, and the Source the Host says is showing. Pure; the AppKit strip
/// draws `items` and hands a click to `select`.
struct BarModel {
    struct Item: Equatable {
        var id: UInt32
        var title: String
        var appName: String
        var bundleID: String
        var thumbnail: Data?
        var icon: Data?
    }

    private(set) var items: [Item] = []
    /// The Host's Source. Only a Window list moves it: a new Window never does.
    private(set) var active: StreamSource = .none
    private var macName = ""
    private var windows: [WindowInfo] = []
    private var thumbnails: [UInt32: Data] = [:]
    private var icons: [String: Data] = [:]

    var desktopActive: Bool { active == .desktop }
    func isActive(_ id: UInt32) -> Bool { active == .window(id) }

    mutating func windowListReceived(_ list: WindowList) {
        macName = list.macName
        active = list.active
        windows = list.windows
        let listed = Set(list.windows.map(\.id))
        thumbnails = thumbnails.filter { listed.contains($0.key) || !knownBefore.contains($0.key) }
        knownBefore = listed
        rebuild()
    }

    /// Windows seen in a list so far; a thumbnail for one that left is dropped, one that has not been
    /// listed yet (it came ahead of its list) is kept.
    private var knownBefore: Set<UInt32> = []

    mutating func thumbnailReceived(_ blob: Data) {
        guard let t = ImageBlob.decodeThumbnail(blob) else { return }
        thumbnails[t.windowID] = t.jpeg
        rebuild()
    }

    mutating func iconReceived(_ blob: Data) {
        guard let i = ImageBlob.decodeIcon(blob) else { return }
        icons[i.bundleID] = i.png
        rebuild()
    }

    private mutating func rebuild() {
        items = windows.map { Item(id: $0.id, title: $0.title, appName: $0.appName, bundleID: $0.bundleID,
                                   thumbnail: thumbnails[$0.id], icon: icons[$0.bundleID]) }
    }

    /// The Source a click on a thumbnail asks for; nil for a Window the Host does not list.
    func select(windowID: UInt32) -> StreamSource? {
        windows.contains { $0.id == windowID } ? .window(windowID) : nil
    }

    var selectDesktop: StreamSource { .desktop }

    /// What a thumbnail's context menu asks of that remote Window; nil for one not listed.
    func command(_ action: WindowCommand.Action, windowID: UInt32) -> WindowCommand? {
        windows.contains { $0.id == windowID } ? WindowCommand(id: windowID, action: action) : nil
    }

    /// The stream window's title: the Source Window's title and app, the Desktop and its Host, else
    /// the Host.
    var windowTitle: String {
        guard !macName.isEmpty else { return "Sill Client" }
        switch active {
        case .window(let id):
            guard let w = windows.first(where: { $0.id == id }) else { return macName }
            if w.title.isEmpty || w.title == w.appName { return w.appName }
            return "\(w.title) \u{2014} \(w.appName)"
        case .desktop:
            return "Desktop \u{2014} \(macName)"
        case .none:
            return macName
        }
    }
}

/// Whether the Bar shows: View › Hide Bar toggles it, and in full screen it shows only while the
/// pointer is at the top edge.
struct BarVisibility {
    var userHidden = false
    var fullScreen = false
    var pointerAtTop = false

    var visible: Bool { !userHidden && (!fullScreen || pointerAtTop) }
    var menuTitle: String { userHidden ? "Show Bar" : "Hide Bar" }
    mutating func toggle() { userHidden.toggle() }

    /// How far down from the top edge, in points, the pointer reveals a hidden Bar.
    static let edgeBand: CGFloat = 4
    static func reveals(pointerY y: CGFloat) -> Bool { y <= edgeBand }
    /// A revealed Bar stays while the pointer is over it.
    static func stillRevealed(pointerY y: CGFloat, barHeight: CGFloat) -> Bool { y <= barHeight }
}

/// The stream window's frame for each Host, as the window reopens where it was left.
struct FrameMemory {
    private var frames: [String: [Double]] = [:]

    init() {}
    init(data: Data) {
        frames = (try? JSONDecoder().decode([String: [Double]].self, from: data)) ?? [:]
    }

    var data: Data { (try? JSONEncoder().encode(frames)) ?? Data() }

    static func key(macID: String?, name: String) -> String { macID.map { "mac:\($0)" } ?? "name:\(name)" }

    func frame(for key: String) -> CGRect? {
        guard let f = frames[key], f.count == 4 else { return nil }
        return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
    }

    mutating func remember(_ frame: CGRect, for key: String) {
        guard frame.width > 0, frame.height > 0 else { return }
        frames[key] = [frame.minX, frame.minY, frame.width, frame.height]
    }
}
