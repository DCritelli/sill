import Foundation
import Network
import StreamProtocol

/// A Host on the home network, as its Bonjour row describes it.
struct FoundHost: Equatable {
    /// The service name ("Noah's MacBook Pro").
    var name: String
    var endpoint: NWEndpoint
    /// How its home door speaks (TXT `p`): plain, TLS with pairing required, or TLS open to any Device.
    var door: HomeDoorTXT.Door
    /// Its recognition tag (TXT `r`), which a saved Host's recognition key resolves.
    var tag: String?
}

/// Finds Hosts on the home network (`_sill._tcp`) and reports every one, whenever the list changes
/// (DCritelli/sill#2: Connect to a Mac lists them all, plain doors and TLS ones). Callbacks on main.
final class HostBrowser {
    var onChange: (([FoundHost]) -> Void)?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sill._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { result -> FoundHost? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                // No TXT record reads as a plain door, as the iOS app reads it.
                var door = HomeDoorTXT.Door.plain
                var tag: String?
                if case .bonjour(let txt) = result.metadata {
                    door = HomeDoorTXT.door(txt)
                    if case .string(let r)? = txt.getEntry(for: RecognitionTag.txtKey) { tag = r }
                }
                return FoundHost(name: name, endpoint: result.endpoint, door: door, tag: tag)
            }
            self?.onChange?(hosts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready: print("Looking for Macs on the network")
            case .waiting(let error): print("Browsing waits: \(error) (is Local Network allowed for Sill Client?)")
            case .failed(let error): print("Browsing failed: \(error)")
            default: break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
