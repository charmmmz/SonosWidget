import Foundation
import Observation

/// Optional NAS-side Live Activity relay. Runs as a global singleton because
/// SettingsView, SonosManager, and the persisted UserDefaults entry all need
/// to agree on one source of truth.
///
/// **Optional**: when `urlString` is empty or the relay is unreachable, the
/// rest of the app behaves exactly as it did before (local `Activity.update`
/// path drives the Lock Screen). When it's configured and healthy, we shift
/// to APNs push tokens so the Live Activity stays fresh even with the app
/// fully suspended.
@MainActor
@Observable
final class RelayManager {

    static let shared = RelayManager()

    enum Status: Equatable {
        case disabled
        case probing
        case connected(groupCount: Int)
        case unreachable(reason: String?)
    }

    private(set) var urlString: String = ""
    private(set) var status: Status = .disabled

    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightProbe: Task<Void, Never>?

    /// Trimmed URL parsed from `urlString`, or nil if blank / malformed.
    var url: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    /// Convenience flag callers gate "use the relay" on. True only when the
    /// last probe succeeded — `disabled` and `unreachable` both return false.
    var isAvailable: Bool {
        if case .connected = status { return true }
        return false
    }

    private init() {
        urlString = SharedStorage.relayURLString ?? ""
    }

    // MARK: - Lifecycle

    /// Persist the user's input, kick a fresh probe, and (re)start periodic
    /// background probing. Empty input fully disables the relay path.
    func setURL(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        urlString = trimmed
        SharedStorage.relayURLString = trimmed.isEmpty ? nil : trimmed

        if trimmed.isEmpty {
            status = .disabled
            stopPeriodicProbe()
            return
        }
        Task { await probeNow() }
        startPeriodicProbe()
    }

    /// Spawn an immediate probe; results land on `status`. Safe to call at
    /// any time (older in-flight probes are cancelled implicitly because we
    /// just overwrite `status` once a fresh result arrives).
    func probeNow() async {
        guard let url else {
            status = .disabled
            return
        }
        // Don't pile up parallel probes on every onAppear / 30s tick.
        inFlightProbe?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            self.status = .probing
            do {
                let health = try await RelayClient.health(baseURL: url)
                guard !Task.isCancelled else { return }
                self.status = .connected(groupCount: health.groups.count)
            } catch is CancellationError {
                // Newer probe took over — its result is what matters.
            } catch {
                guard !Task.isCancelled else { return }
                self.status = .unreachable(reason: error.localizedDescription)
            }
        }
        inFlightProbe = task
        await task.value
    }

    /// 30-second probe loop, used as a passive watchdog so the iOS side
    /// notices when the NAS comes back online (or goes away) without the
    /// user opening Settings to retest.
    func startPeriodicProbe() {
        guard url != nil else { return }
        stopPeriodicProbe()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await probeNow()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stopPeriodicProbe() {
        periodicTask?.cancel()
        periodicTask = nil
    }
}
