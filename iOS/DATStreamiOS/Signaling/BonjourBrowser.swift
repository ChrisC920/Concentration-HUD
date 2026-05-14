import Foundation
import Network
import DATSignaling

@MainActor
@Observable
final class BonjourBrowser {
    struct DiscoveredPeer: Identifiable, Equatable {
        let id: String       // Bonjour service name, unique per advertiser
        let endpoint: NWEndpoint
        let txtVersion: String?

        static func == (l: DiscoveredPeer, r: DiscoveredPeer) -> Bool { l.id == r.id }
    }

    enum State: Equatable {
        case idle
        case browsing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var peers: [DiscoveredPeer] = []

    private var browser: NWBrowser?

    func start() {
        stop()
        let params = NWParameters()
        params.includePeerToPeer = true
        params.prohibitedInterfaceTypes = [.cellular]

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: BonjourConfig.serviceType, domain: nil),
            using: params
        )
        browser.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in self?.handleBrowserState(s) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handleResults(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        peers = []
        state = .idle
    }

    private func handleBrowserState(_ s: NWBrowser.State) {
        switch s {
        case .ready:    state = .browsing
        case .failed(let err): state = .failed(err.localizedDescription)
        case .cancelled:
            if state != .idle { state = .idle }
        default: break
        }
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        peers = results.compactMap { result in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            var version: String?
            if case let .bonjour(txt) = result.metadata {
                version = txt[BonjourConfig.txtVersionKey]
            }
            return DiscoveredPeer(id: name, endpoint: result.endpoint, txtVersion: version)
        }
        .sorted { $0.id < $1.id }
    }
}
