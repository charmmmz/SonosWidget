import Network
import Foundation

@Observable
final class SonosDiscovery {
    var discoveredSpeakers: [SonosPlayer] = []
    var isScanning = false

    private var browser: NWBrowser?
    private var connections: [NWConnection] = []
    private var resolvedIPs: Set<String> = []
    private var scanTask: Task<Void, Never>?

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        resolvedIPs.removeAll()
        discoveredSpeakers.removeAll()

        let browser = NWBrowser(for: .bonjour(type: "_sonos._tcp", domain: nil), using: .tcp)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            for change in changes {
                if case .added(let result) = change {
                    self.resolve(result.endpoint)
                }
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor [weak self] in self?.stopScan() }
            }
        }

        browser.start(queue: .main)

        scanTask = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { stopScan() }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        browser?.cancel()
        browser = nil
        for c in connections { c.cancel() }
        connections.removeAll()
        isScanning = false
    }

    private func resolve(_ endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        connections.append(conn)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                if let remote = conn.currentPath?.remoteEndpoint,
                   case .hostPort(let host, _) = remote {
                    let raw = "\(host)"
                    let ip = raw.split(separator: "%").first.map(String.init) ?? raw
                    guard !ip.contains(":") else { conn.cancel(); return }
                    Task { @MainActor in
                        self.didResolveIP(ip)
                    }
                }
                conn.cancel()
            }
        }

        conn.start(queue: .main)
    }

    private func didResolveIP(_ ip: String) {
        guard !resolvedIPs.contains(ip) else { return }
        resolvedIPs.insert(ip)

        Task {
            do {
                let allSpeakers = try await SonosAPI.getZoneGroupState(ip: ip)
                let coordinators = allSpeakers.filter(\.isCoordinator)
                if !coordinators.isEmpty {
                    for speaker in coordinators where !discoveredSpeakers.contains(where: { $0.id == speaker.id }) {
                        discoveredSpeakers.append(speaker)
                    }
                    return
                }
            } catch { /* fall through to single-speaker path */ }

            let name = (try? await SonosAPI.getDeviceName(ip: ip)) ?? ip
            let player = SonosPlayer(id: UUID().uuidString, name: name, ipAddress: ip, isCoordinator: true)
            if !discoveredSpeakers.contains(where: { $0.ipAddress == ip }) {
                discoveredSpeakers.append(player)
            }
        }
    }
}
