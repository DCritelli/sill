import Foundation
import Network
import StreamProtocol

/// Finds Hosts on the home network (`_sill._tcp`) and reports the first one whose home door is
/// plain, which is what the tracer can dial without pairing: SillHost without `--pairing`. Doors
/// that need pairing are skipped and logged until DCritelli/sill#2. Callbacks on main.
final class HostBrowser {
    var onFound: ((NWEndpoint, String) -> Void)?
    private let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sill._tcp", domain: nil), using: .tcp)
    private var reported = false
    private var skipped: Set<String> = []

    func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !reported else { return }
            for result in results {
                let name: String
                if case .service(let n, _, _, _) = result.endpoint { name = n } else { name = "\(result.endpoint)" }
                // No TXT record reads as a plain door, as the iOS app reads it.
                var door = HomeDoorTXT.Door.plain
                if case .bonjour(let txt) = result.metadata { door = HomeDoorTXT.door(txt) }
                guard door == .plain else {
                    if skipped.insert(name).inserted { print("Skipping \(name): its door needs pairing, which comes with #2") }
                    continue
                }
                reported = true
                browser.cancel()
                onFound?(result.endpoint, name)
                return
            }
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
    }

    func stop() { browser.cancel() }
}
