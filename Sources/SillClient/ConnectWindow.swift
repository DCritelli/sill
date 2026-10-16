import AppKit
import SwiftUI
import Network
import StreamProtocol

/// The saved Hosts (DCritelli/sill#2), in the iOS app's record format (SavedMacs) under its key in
/// this app's defaults. Main thread.
enum SavedHosts {
    static var all: [SavedMac] {
        get { SavedMacs.decode(UserDefaults.standard.string(forKey: SavedMacs.defaultsKey)) }
        set { UserDefaults.standard.set(SavedMacs.encode(newValue), forKey: SavedMacs.defaultsKey) }
    }

    static func add(_ mac: SavedMac) { all = SavedMacs.adding(mac, to: all) }
    static func forget(_ macID: String) { all = all.filter { $0.macID != macID } }
    static func connected(_ macID: String, bonjourName: String?) {
        all = all.map { mac in
            guard mac.macID == macID else { return mac }
            var next = mac
            next.lastConnectedAt = Date()
            if let bonjourName { next.bonjourName = bonjourName }
            return next
        }
    }
}

/// One row of Connect to a Mac: a saved Host (found on the network now, or not), or a Host found
/// on the network that this Mac has not paired with.
struct HostRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case saved(SavedMac, found: FoundHost?)
        case found(FoundHost)
    }
    var kind: Kind

    var id: String {
        switch kind {
        case .saved(let mac, _): return "saved:" + mac.macID
        case .found(let host): return "found:" + host.name
        }
    }
    var name: String {
        switch kind {
        case .saved(let mac, _): return mac.name
        case .found(let host): return host.name
        }
    }
    var detail: String {
        switch kind {
        case .saved(_, let found?): return found.door == .plain ? "Paired · on this network, without pairing" : "Paired · on this network"
        case .saved: return "Paired"
        case .found(let host):
            switch host.door {
            case .pairingRequired: return "Not paired"
            case .open: return "Open to any device"
            case .plain: return "Development host, without pairing"
            }
        }
    }
    var isSaved: Bool { if case .saved = kind { return true }; return false }

    /// The saved Hosts first (each with its row on the network when one is there: by its recognition
    /// tag, or by its Bonjour name for a row with no tag), then the rest of the network's.
    static func rows(saved: [SavedMac], found: [FoundHost]) -> [HostRow] {
        var left = found
        var rows: [HostRow] = []
        for mac in SavedMacs.remoteOrder(saved) {
            let index = left.firstIndex { host in
                if let tag = host.tag { return SavedMacs.recognize(tag: tag, in: [mac]) == mac.macID }
                return host.name == mac.bonjourName
            }
            rows.append(HostRow(kind: .saved(mac, found: index.map { left[$0] })))
            if let index { left.remove(at: index) }
        }
        return rows + left.map { HostRow(kind: .found($0)) }
    }
}

/// Connect to a Mac's state; the app delegate acts on what it asks.
final class ConnectModel: ObservableObject {
    @Published var rows: [HostRow] = []
    @Published var status: String?
    @Published var working = false
    /// The code sheet: for one Host (after its ask), or Add a Mac… (a found Host or an address).
    @Published var codeSheet: CodeSheet?

    struct CodeSheet: Identifiable, Equatable {
        let id = UUID()
        /// Nil: Add a Mac…, which asks which Mac.
        var host: String?
        var note: String
    }

    var onConnect: ((HostRow) -> Void)?
    var onForget: ((HostRow) -> Void)?
    var onAddMac: (() -> Void)?
    /// The code, and for Add a Mac… the found Host chosen (its name) or the address typed.
    var onCode: ((String, _ host: String?, _ address: String) -> Void)?
    var onCancelCode: (() -> Void)?

    /// Found Hosts that Add a Mac… can pair with.
    var pairable: [String] {
        rows.compactMap { if case .found(let h) = $0.kind, h.door != .plain { return h.name }; return nil }
    }
}

struct ConnectView: View {
    @ObservedObject var model: ConnectModel
    @State private var selection: HostRow.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to a Mac").font(.title2.bold())
            Text("Macs running Sill on your network, and the ones you paired with.")
                .foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(row.id)
                    .contextMenu {
                        Button("Connect") { model.onConnect?(row) }
                        if row.isSaved { Button("Forget \(row.name)") { model.onForget?(row) } }
                    }
                }
            }
            .contextMenu(forSelectionType: HostRow.ID.self, menu: { _ in }, primaryAction: { ids in
                if let row = model.rows.first(where: { ids.contains($0.id) }) { model.onConnect?(row) }
            })
            .frame(minHeight: 180)
            if let status = model.status {
                Text(status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Add a Mac\u{2026}") { model.onAddMac?() }
                Button("Forget") { if let row = selected, row.isSaved { model.onForget?(row) } }
                    .disabled(!(selected?.isSaved ?? false))
                Spacer()
                if model.working { ProgressView().controlSize(.small) }
                Button("Connect") { if let row = selected { model.onConnect?(row) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || model.working)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 360)
        .sheet(item: $model.codeSheet) { sheet in
            CodeView(model: model, sheet: sheet)
        }
    }

    private var selected: HostRow? { model.rows.first { $0.id == selection } }
}

struct CodeView: View {
    @ObservedObject var model: ConnectModel
    let sheet: ConnectModel.CodeSheet
    @State private var code = ""
    @State private var host = ""
    @State private var address = ""
    private static let byAddress = "\u{0}address"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sheet.host.map { "Pair with \($0)" } ?? "Add a Mac").font(.title3.bold())
            Text(sheet.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if sheet.host == nil {
                Picker("Mac", selection: $host) {
                    ForEach(model.pairable, id: \.self) { Text($0).tag($0) }
                    Text("By address\u{2026}").tag(Self.byAddress)
                }
                if host == Self.byAddress {
                    TextField("Address", text: $address, prompt: Text("192.168.1.20:7455 or a name"))
                }
            }
            TextField("Code", text: $code, prompt: Text("1234 5678 9012"))
                .font(.body.monospacedDigit())
            HStack {
                Spacer()
                Button("Cancel") { model.codeSheet = nil; model.onCancelCode?() }
                    .keyboardShortcut(.cancelAction)
                Button("Pair") {
                    let chosen = sheet.host ?? (host == Self.byAddress ? nil : host)
                    model.codeSheet = nil
                    model.onCode?(code, chosen, address)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.isEmpty || (sheet.host == nil && host.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { host = model.pairable.first ?? Self.byAddress }
    }
}

/// The Connect to a Mac window.
final class ConnectWindow {
    let model = ConnectModel()
    let window: NSWindow

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Connect to a Mac"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ConnectView(model: model))
        window.center()
        window.setFrameAutosaveName("Connect to a Mac")
    }

    func show() { window.makeKeyAndOrderFront(nil) }
}
