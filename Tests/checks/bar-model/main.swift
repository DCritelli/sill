// The bar-model check (DCritelli/sill#7): the Mac Client's BarModel, BarVisibility and FrameMemory
// (Sources/SillClient/BarModel.swift) with StreamProtocol's Switcher.swift. Expected values are
// worked by hand. Prints "ok" or "FAIL" per check; exits 1 on any failure.
import CoreGraphics
import Foundation

var failures = 0, checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    print(ok ? "ok   \(what())" : "FAIL (line \(line)) \(what())")
    if !ok { failures += 1 }
}

func win(_ id: UInt32, _ title: String, _ app: String, _ bundle: String = "") -> WindowInfo {
    WindowInfo(id: id, title: title, appName: app, bundleID: bundle.isEmpty ? "com.\(app)" : bundle, width: 800, height: 600)
}
func list(_ windows: [WindowInfo], active: StreamSource, mac: String = "Studio") -> WindowList {
    WindowList(macName: mac, windows: windows, active: active)
}
let notes = win(1, "Groceries", "Notes"), safari = win(2, "Apple", "Safari"), mail = win(3, "Inbox", "Mail")

// MARK: Windows in the Bar

do {
    var bar = BarModel()
    check(bar.items.isEmpty && bar.active == .none, "empty before the first list")
    bar.windowListReceived(list([notes, safari], active: .window(2)))
    check(bar.items.map(\.id) == [1, 2], "the Host's order")
    check(bar.active == .window(2) && bar.isActive(2) && !bar.isActive(1), "the Host's active Source")
    // A Window the remote app opens appears; the Source stays.
    bar.windowListReceived(list([notes, safari, mail], active: .window(2)))
    check(bar.items.map(\.id) == [1, 2, 3], "a new Window appears in the Bar")
    check(bar.active == .window(2), "the Source stays where it was")
    // A window closes.
    bar.windowListReceived(list([notes, mail], active: .desktop))
    check(bar.items.map(\.id) == [1, 3] && bar.desktopActive, "a closed Window leaves; the Desktop is the Source")
}

// MARK: Thumbnails and icons

do {
    var bar = BarModel()
    bar.windowListReceived(list([notes, safari], active: .window(1)))
    let jpeg1 = Data([1, 2, 3]), jpeg2 = Data([9, 9])
    bar.thumbnailReceived(ImageBlob.encodeThumbnail(windowID: 1, jpeg: jpeg1))
    bar.thumbnailReceived(ImageBlob.encodeThumbnail(windowID: 2, jpeg: jpeg2))
    check(bar.items[0].thumbnail == jpeg1 && bar.items[1].thumbnail == jpeg2, "each thumbnail on its Window")
    bar.thumbnailReceived(ImageBlob.encodeThumbnail(windowID: 1, jpeg: Data([7])))
    check(bar.items[0].thumbnail == Data([7]), "a refreshed thumbnail replaces the old one")
    bar.thumbnailReceived(Data([1]))
    check(bar.items[0].thumbnail == Data([7]), "a malformed thumbnail is ignored")
    bar.iconReceived(ImageBlob.encodeIcon(bundleID: "com.Notes", png: Data([5])))
    check(bar.items[0].icon == Data([5]) && bar.items[1].icon == nil, "an icon goes to every Window of its app only")
    bar.windowListReceived(list([notes], active: .window(1)))
    check(bar.items[0].thumbnail == Data([7]) && bar.items[0].icon == Data([5]), "a new list keeps what was received")
    bar.windowListReceived(list([notes, safari], active: .window(1)))
    check(bar.items[1].thumbnail == nil, "a Window that left and came back has no old thumbnail")
    // A thumbnail that arrives before its Window's list is shown once the list lists it.
    var early = BarModel()
    early.thumbnailReceived(ImageBlob.encodeThumbnail(windowID: 3, jpeg: Data([4])))
    early.windowListReceived(list([mail], active: .none))
    check(early.items[0].thumbnail == Data([4]), "a thumbnail ahead of its list is kept")
    var ahead = BarModel()
    ahead.windowListReceived(list([notes], active: .none))
    ahead.thumbnailReceived(ImageBlob.encodeThumbnail(windowID: 3, jpeg: Data([4])))
    ahead.windowListReceived(list([notes], active: .none))
    ahead.windowListReceived(list([notes, mail], active: .none))
    check(ahead.items[1].thumbnail == Data([4]), "a thumbnail ahead of the list that adds its Window is kept")
}

// MARK: Choosing and commands

do {
    var bar = BarModel()
    bar.windowListReceived(list([notes, safari], active: .window(1)))
    check(bar.select(windowID: 2) == .window(2), "clicking a thumbnail picks that Window")
    check(bar.select(windowID: 99) == nil, "a Window not listed picks nothing")
    check(bar.selectDesktop == .desktop, "the Desktop button picks the Desktop")
    check(bar.command(.close, windowID: 2)?.id == 2 && bar.command(.close, windowID: 2)?.action == .close, "Close for that Window")
    check(bar.command(.minimize, windowID: 1)?.action == .minimize, "Minimize")
    check(bar.command(.fullScreen, windowID: 1)?.action == .fullScreen, "Full Screen")
    check(bar.command(.close, windowID: 99) == nil, "no command for a Window not listed")
}

// MARK: Title

do {
    var bar = BarModel()
    check(bar.windowTitle == "Sill Client", "no list yet: the app's name")
    bar.windowListReceived(list([notes, safari], active: .window(1), mac: "Studio"))
    check(bar.windowTitle == "Groceries \u{2014} Notes", "title and app")
    bar.windowListReceived(list([win(4, "", "Finder")], active: .window(4)))
    check(bar.windowTitle == "Finder", "no title: the app alone")
    bar.windowListReceived(list([notes], active: .window(1)))
    bar.windowListReceived(list([notes], active: .desktop, mac: "Studio"))
    check(bar.windowTitle == "Desktop \u{2014} Studio", "the Desktop and the Host")
    bar.windowListReceived(list([notes], active: .none, mac: "Studio"))
    check(bar.windowTitle == "Studio", "nothing streaming: the Host's name")
    bar.windowListReceived(list([notes], active: .window(77), mac: "Studio"))
    check(bar.windowTitle == "Studio", "an active Window not listed: the Host's name")
    bar.windowListReceived(list([win(5, "Notes", "Notes")], active: .window(5)))
    check(bar.windowTitle == "Notes", "title equal to the app is not said twice")
}

// MARK: Hiding

do {
    var v = BarVisibility()
    check(v.visible, "shown by default")
    check(v.menuTitle == "Hide Bar", "menu says Hide Bar")
    v.toggle()
    check(!v.visible && v.menuTitle == "Show Bar", "hidden by the toggle")
    v.pointerAtTop = true
    check(!v.visible, "the pointer at the top does not reveal a hidden Bar outside full screen")
    v.toggle()
    check(v.visible, "toggled back")
    v.pointerAtTop = false
    v.fullScreen = true
    check(!v.visible, "full screen: hidden until the pointer reaches the top")
    v.pointerAtTop = true
    check(v.visible, "full screen with the pointer at the top edge: shown")
    v.pointerAtTop = false
    check(!v.visible, "the pointer leaves: hidden again")
    v.toggle()
    v.pointerAtTop = true
    check(!v.visible, "hidden by the user, full screen, pointer at top: still hidden")
    v.toggle()
    v.fullScreen = false
    v.pointerAtTop = false
    check(v.visible, "leaving full screen brings the Bar back")
    check(v.topEdgeBand == 4 && BarVisibility.reveals(pointerY: 3, in: 900) && !BarVisibility.reveals(pointerY: 10, in: 900),
          "the top edge is a band of 4 points")
    check(BarVisibility.reveals(pointerY: 0, in: 900) && BarVisibility.reveals(pointerY: -2, in: 900), "at and above the edge reveals")
    // The shown Bar keeps showing while the pointer is over it (its own height).
    check(BarVisibility.stillRevealed(pointerY: 60, barHeight: 78, in: 900) && !BarVisibility.stillRevealed(pointerY: 90, barHeight: 78, in: 900),
          "a revealed Bar stays while the pointer is over it")
}

// MARK: Frame memory

do {
    var m = FrameMemory()
    let a = CGRect(x: 100, y: 200, width: 900, height: 600), b = CGRect(x: 5, y: 6, width: 700, height: 500)
    check(m.frame(for: "mac-a") == nil, "no frame yet")
    m.remember(a, for: "mac-a")
    m.remember(b, for: "mac-b")
    check(m.frame(for: "mac-a") == a && m.frame(for: "mac-b") == b, "each Host its own frame")
    m.remember(b, for: "mac-a")
    check(m.frame(for: "mac-a") == b, "the newer frame wins")
    let restored = FrameMemory(data: m.data)
    check(restored.frame(for: "mac-a") == b && restored.frame(for: "mac-b") == b, "survives encoding")
    check(FrameMemory(data: Data([0, 1])).frame(for: "mac-a") == nil, "garbage reads as empty")
    check(FrameMemory.key(macID: "ID1", name: "Studio") == "mac:ID1", "a saved Host by its ID")
    check(FrameMemory.key(macID: nil, name: "Studio") == "name:Studio", "an unsaved Host by its name")
    m.remember(CGRect(x: 0, y: 0, width: 0, height: 0), for: "mac-c")
    check(m.frame(for: "mac-c") == nil, "an empty frame is not remembered")
}

print(failures == 0 ? "all \(checks) checks passed" : "\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
