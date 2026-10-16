import Foundation
// In the app StreamProtocol is its own module; the menus-model check compiles this file together
// with Sources/StreamProtocol as one module, where there is nothing to import.
#if canImport(StreamProtocol)
import StreamProtocol
#endif

/// The Mac Client's Menus button (DCritelli/sill#8), without AppKit: the iOS app's `MacMenuState`
/// (shared in place, docs/adr/0002) plus the two counters a UI needs to use it (a completion key
/// for each menu opened, a token for each fetch and choice) and the rows as menu items would be
/// drawn (title, shortcut text, disabled, checked or mixed). The Host follows the Source's app and
/// sends a new top level when it changes (kind 24), so the Menus follow the Source with nothing
/// asked here; `receive` shows them. Foundation and StreamProtocol only (Tests/checks/menus-model).
struct MenusModel {
    /// One menu item as the Mac Client draws it.
    struct Item: Equatable {
        enum Kind: Equatable { case item, submenu, note }
        enum Check: Equatable { case off, on, mixed }
        var kind: Kind
        var title: String
        /// The Host's shortcut as text ("⇧⌘S"); shown beside the title, never bound as a key.
        var shortcut: String?
        var enabled: Bool
        var check: Check
        /// What a choice or an opening hands back to `choose` and `open`.
        var row: MacMenuState.Row
    }

    private(set) var state = MacMenuState()
    private var nextKey = 1
    private var nextToken = 1

    /// Whether the Menus button shows: the Host sent menus (or a note to show).
    var hasMenus: Bool { state.hasMenus }
    /// The app whose menus these are, for the button's tooltip.
    var appName: String? { state.app }
    /// The bar's menus as items to open, in the Host's order.
    var topMenus: [Item] { state.menus.map(Self.item) }
    /// A note to show in place of menus (no Accessibility on the Host, the app not answering).
    var topNote: String? { state.note }

    /// What a kind 24 changed.
    struct Update: Equatable {
        /// Menus waiting for words (a changed tree), by the key `open` gave them.
        var settled: [(key: Int, items: [[Item]])]
        var topChanged: Bool
        var refusal: MacMenuState.Refusal?
        static func == (a: Update, b: Update) -> Bool {
            a.topChanged == b.topChanged && a.refusal == b.refusal && a.settled.count == b.settled.count
                && zip(a.settled, b.settled).allSatisfy { $0.key == $1.key && $0.items == $1.items }
        }
    }

    mutating func receive(_ m: MacMenu, now: Double) -> Update {
        let r = state.receive(m, now: now)
        return Update(settled: Self.settled(r.done), topChanged: r.topChanged, refusal: r.refusal)
    }

    /// What opening a menu does.
    struct Opened {
        /// The completion's key: `receive` or `expire` settles it with this key.
        var key: Int
        /// A kind 27 to send, or nil when it waits on one already sent or is answered at once.
        var send: FetchMenu?
        /// The items now, when there is no waiting (nothing asked, or words of our own).
        var now: [[Item]]?
    }

    /// A menu opened (a top-level one, or a submenu row of an opened menu).
    mutating func open(_ row: MacMenuState.Row, now: Double) -> Opened {
        let key = nextKey; nextKey += 1
        let token = nextToken; nextToken += 1
        guard let id = row.id else { return Opened(key: key, send: nil, now: Self.items(.message(MacMenuState.notConnected))) }
        switch state.fetch(id, title: row.title, version: row.version, key: key, token: token, now: now) {
        case .send(let fetch): return Opened(key: key, send: fetch, now: nil)
        case .joined: return Opened(key: key, send: nil, now: nil)
        case .settled(let content): return Opened(key: key, send: nil, now: Self.items(content))
        }
    }

    /// An item chosen: the kind 25 to send, a refusal made here, or nil when nothing happens (a
    /// disabled item, a submenu, a note).
    mutating func choose(_ item: Item) -> MacMenuState.Press? {
        let token = nextToken
        guard let press = state.press(item.row, token: token) else { return nil }
        nextToken += 1
        return press
    }

    /// Fetches that have waited `timeout` seconds or more, settled with words.
    mutating func expire(now: Double, timeout: Double, mac: String) -> [(key: Int, items: [[Item]])] {
        Self.settled(state.expire(now: now, timeout: timeout, mac: mac))
    }

    /// The connection ended: every waiting menu says so, and nothing is kept.
    mutating func reset() -> [(key: Int, items: [[Item]])] {
        Self.settled(state.reset())
    }

    // MARK: Rows as items

    static func settled(_ done: [MacMenuState.Done]) -> [(key: Int, items: [[Item]])] {
        done.map { ($0.key, items($0.content)) }
    }

    /// An opened menu's content as sections of items (words of our own as one disabled note).
    static func items(_ content: MacMenuState.Content) -> [[Item]] {
        switch content {
        case .sections(let sections, _): return sections.map { $0.map(item) }
        case .message(let text): return [[item(.note(text))]]
        }
    }

    static func item(_ row: MacMenuState.Row) -> Item {
        let kind: Item.Kind = row.kind == .submenu ? .submenu : (row.kind == .note ? .note : .item)
        let check: Item.Check = row.mark == .on ? .on : (row.mark == .mixed ? .mixed : .off)
        return Item(kind: kind, title: row.title, shortcut: row.key, enabled: row.enabled && row.kind != .note,
                    check: check, row: row)
    }
}
