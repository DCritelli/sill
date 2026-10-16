// The menus-model check (DCritelli/sill#8): the Mac Client's MenusModel (Sources/SillClient/
// MenusModel.swift) over the shared MacMenuState, with StreamProtocol as one module. Expected values
// are worked by hand. Prints "ok" or "FAIL" per check; exits 1 on any failure.
import Foundation

var failures = 0, checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    print(ok ? "ok   \(what())" : "FAIL (line \(line)) \(what())")
    if !ok { failures += 1 }
}

func top(_ version: Int, app: String = "Notes", _ titles: [String]) -> MacMenu {
    MacMenu(version: version, app: app, bundleID: "com.apple.Notes",
            menus: titles.enumerated().map { MacMenuItem(id: "\($0.offset + 1)", title: $0.element, submenu: true) })
}
func answer(_ token: Int?, version: Int, _ items: [MacMenuItem], more: Int? = nil) -> MacMenu {
    MacMenu(version: version, answering: token, items: items, more: more)
}

// MARK: Top level

do {
    var m = MenusModel()
    check(!m.hasMenus && m.topMenus.isEmpty, "no button before the Host sends menus")
    let u = m.receive(top(1, ["File", "Edit"]), now: 0)
    check(u.topChanged && m.hasMenus, "a top level shows the button")
    check(m.topMenus.map(\.title) == ["File", "Edit"] && m.topMenus.allSatisfy { $0.kind == .submenu && $0.enabled }, "menus in the Host's order")
    check(m.appName == "Notes", "the app named")
    // The Source moves to another app's Window: the Host sends that app's menus.
    let u2 = m.receive(top(2, app: "Safari", ["Safari", "File", "History"]), now: 1)
    check(u2.topChanged && m.appName == "Safari" && m.topMenus.map(\.title) == ["Safari", "File", "History"], "the menus follow the Source's app")
    check(!m.receive(top(2, app: "Safari", ["Safari", "File", "History"]), now: 2).topChanged, "the same top level changes nothing")
}

// MARK: Opening, items and marks

do {
    var m = MenusModel()
    _ = m.receive(top(1, ["File"]), now: 0)
    let file = m.topMenus[0]
    let o = m.open(file.row, now: 0)
    check(o.send == FetchMenu(version: 1, id: "1", title: "File", token: o.send?.token) && o.send?.token != nil && o.now == nil, "opening fetches the menu under its title")
    let items = [
        MacMenuItem(id: "1.0", title: "New Note", enabled: true, key: "⌘N"),
        MacMenuItem(id: "1.1", title: "Open", enabled: false, key: "⌘O"),
        MacMenuItem(separator: true),
        MacMenuItem(id: "1.3", title: "Show Ruler", mark: "✓"),
        MacMenuItem(id: "1.4", title: "Mixed", mark: "-"),
        MacMenuItem(id: "1.5", title: "Recent", submenu: true),
    ]
    let u = m.receive(answer(o.send?.token, version: 1, items), now: 0.1)
    check(u.settled.count == 1 && u.settled[0].key == o.key, "the answer settles the opened menu by its key")
    let sections = u.settled.first?.items ?? []
    check(sections.count == 2 && sections[0].count == 2 && sections[1].count == 3, "separators split sections")
    check(sections[0][0].title == "New Note" && sections[0][0].shortcut == "⌘N" && sections[0][0].enabled, "shortcut as text on an enabled item")
    check(!sections[0][1].enabled, "a disabled item looks disabled")
    check(sections[1][0].check == .on && sections[1][1].check == .mixed && sections[0][0].check == .off, "checked, mixed and plain")
    check(sections[1][2].kind == .submenu && sections[1][2].enabled && sections[1][2].shortcut == nil, "a submenu opens, no shortcut")
}

// MARK: Choosing

do {
    var m = MenusModel()
    _ = m.receive(top(1, ["File"]), now: 0)
    let o = m.open(m.topMenus[0].row, now: 0)
    let u = m.receive(answer(o.send?.token, version: 1, [MacMenuItem(id: "1.0", title: "New", enabled: true), MacMenuItem(id: "1.1", title: "Open", enabled: false)]), now: 0)
    let rows = u.settled[0].items[0]
    if case .send(let p)? = m.choose(rows[0]) {
        check(p.id == "1.0" && p.title == "New" && p.version == 1, "a choice carries the id, title and version shown")
        let q = m.choose(rows[0])
        if case .send(let p2)? = q { check(p2.token != p.token, "each choice has its own token") } else { check(false, "second choice sends") }
    } else { check(false, "choice sends kind 25") }
    check(m.choose(rows[1]) == nil, "a disabled item chooses nothing")
    check(m.choose(MenusModel.item(.note("x"))) == nil, "a note chooses nothing")
    check(!MenusModel.item(MacMenuState.Row(kind: .note, title: "x", enabled: true)).enabled, "a note is never enabled")
    var m3 = MenusModel()
    _ = m3.receive(top(1, ["File", "Edit"]), now: 0)
    let t1 = m3.open(m3.topMenus[0].row, now: 0).send?.token, t2 = m3.open(m3.topMenus[1].row, now: 0).send?.token
    check(t1 != nil && t2 != nil && t1 != t2, "each fetch has its own token")
    // The Host refuses.
    var m2 = MenusModel()
    _ = m2.receive(top(1, ["File"]), now: 0)
    let o2 = m2.open(m2.topMenus[0].row, now: 0)
    let rows2 = m2.receive(answer(o2.send?.token, version: 1, [MacMenuItem(id: "1.0", title: "New", enabled: true)]), now: 0).settled[0].items[0]
    guard case .send(let p)? = m2.choose(rows2[0]) else { fatalError() }
    let r = m2.receive(MacMenu(version: 1, answering: p.token, pressed: false, note: "Gone."), now: 1)
    check(r.refusal?.title == "New" && r.refusal?.note == "Gone.", "a refusal comes back with its words")
}

// MARK: Waiting, timing out, ending

do {
    var m = MenusModel()
    _ = m.receive(top(1, ["File"]), now: 0)
    let row = m.topMenus[0].row
    let a = m.open(row, now: 0), b = m.open(row, now: 0.5)
    check(a.send != nil && b.send == nil && b.now == nil && a.key != b.key, "a second opening joins the first fetch")
    check(m.expire(now: 2, timeout: 4, mac: "Studio").isEmpty, "not yet timed out")
    let e = m.expire(now: 4, timeout: 4, mac: "Studio")
    check(e.map(\.key).sorted() == [a.key, b.key] && e[0].items == [[MenusModel.item(.note("Studio didn’t answer. Open the menu again."))]], "a timeout settles every waiting menu with words")
    let c = m.open(row, now: 5)
    let ended = m.reset()
    check(ended.count == 1 && ended[0].key == c.key && ended[0].items[0][0].title == "Not connected." && !m.hasMenus, "the end settles waiting menus and clears the menus")
}

// MARK: Changed tree, nothing before a top level

do {
    var m = MenusModel()
    let early = m.open(MacMenuState.Row(kind: .submenu, id: "1", title: "File", version: 1), now: 0)
    check(early.send == nil && early.now?[0][0].title == "Not connected.", "nothing is asked before a top level")
    _ = m.receive(top(1, ["File"]), now: 0)
    let o = m.open(m.topMenus[0].row, now: 0)
    let u = m.receive(top(2, ["File", "Edit"]), now: 1)
    check(u.settled.count == 1 && u.settled[0].key == o.key && u.settled[0].items[0][0].title == MacMenuState.changedNote, "a new tree settles a waiting fetch")
    check(m.open(MacMenuState.Row(kind: .submenu, id: nil, title: "x", version: 2), now: 2).send == nil, "a row without an id asks nothing")
    let old = MacMenuState.Row(kind: .submenu, id: "1", title: "File", version: 1)
    check(m.open(old, now: 2).now?[0][0].title == MacMenuState.changedNote, "a row from an older tree is not asked")
    let stale = MenusModel.items(.message("x"))
    check(stale.count == 1 && !stale[0][0].enabled && stale[0][0].kind == .note, "words are a disabled note")
}

print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
