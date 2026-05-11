import Foundation
import Observation

@MainActor
protocol HueAmbienceRelayRuntimeProviding {
    var shouldDeferLocalHueAmbience: Bool { get }
}

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

    enum HueAmbienceSyncStatus: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)

        var title: String {
            switch self {
            case .idle:
                return "Not synced"
            case .syncing:
                return "Syncing Music Ambience"
            case .synced:
                return "Synced to NAS Relay"
            case .failed(let reason):
                return reason
            }
        }
    }

    private(set) var urlString: String = ""
    private(set) var status: Status = .disabled
    private(set) var isHueAmbienceRelayConfigured = false
    private(set) var isHueAmbienceRelayEnabled = false
    private(set) var hueAmbienceRuntimeStatus: HueLiveEntertainmentRuntimeStatus = .unavailable
    private(set) var hueAmbienceRuntimeDetail = "Sync Music Ambience to NAS Relay to enable always-on ambience."
    var hueAmbienceSyncStatus: HueAmbienceSyncStatus = .idle

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

    var shouldDeferLocalHueAmbience: Bool {
        isAvailable && isHueAmbienceRelayConfigured && isHueAmbienceRelayEnabled
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
            updateHueAmbienceRuntimeStatus(configured: false)
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
                self.updateHueAmbienceRuntimeStatus(from: health.hueAmbience)
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

    func updateHueAmbienceRuntimeStatus(
        configured: Bool,
        enabled: Bool = true,
        renderMode: HueAmbienceRelayRenderMode? = nil,
        runtimeActive: Bool? = nil,
        activeTargetIds: [String]? = nil,
        entertainmentTargetActive: Bool? = nil,
        entertainmentMetadataComplete: Bool? = nil,
        lastFrameAt: String? = nil,
        lastError: String? = nil
    ) {
        isHueAmbienceRelayConfigured = configured
        isHueAmbienceRelayEnabled = configured && enabled
        hueAmbienceSyncStatus = configured ? .synced(Date()) : .idle

        guard configured else {
            hueAmbienceRuntimeStatus = .unavailable
            hueAmbienceRuntimeDetail = "Sync Music Ambience to NAS Relay to enable always-on ambience."
            return
        }

        guard enabled else {
            hueAmbienceRuntimeStatus = .ready("Music Ambience disabled")
            hueAmbienceRuntimeDetail = "Enable Music Ambience to let NAS control your lights."
            return
        }

        let trimmedError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedError.isEmpty {
            hueAmbienceRuntimeStatus = .error(trimmedError)
            hueAmbienceRuntimeDetail = "NAS reported a Music Ambience runtime error."
            return
        }

        if runtimeActive == true {
            switch renderMode {
            case .streamingReady:
                hueAmbienceRuntimeStatus = .fallback("Streaming-ready via CLIP fallback")
            case .clipFallback, nil:
                hueAmbienceRuntimeStatus = .fallback("CLIP fallback active")
            }
        } else {
            hueAmbienceRuntimeStatus = .ready("NAS runtime ready")
        }

        hueAmbienceRuntimeDetail = entertainmentTargetActive == true && entertainmentMetadataComplete == false
            ? "Entertainment channel metadata is incomplete."
            : "NAS controls Music Ambience while it is reachable."
    }

    private func updateHueAmbienceRuntimeStatus(from health: RelayClient.HealthResponse.HueAmbience?) {
        guard let health else {
            updateHueAmbienceRuntimeStatus(configured: false)
            return
        }

        updateHueAmbienceRuntimeStatus(
            configured: health.configured == true,
            enabled: health.enabled != false,
            renderMode: health.renderMode,
            runtimeActive: health.runtimeActive,
            activeTargetIds: health.activeTargetIds,
            entertainmentTargetActive: health.entertainmentTargetActive,
            entertainmentMetadataComplete: health.entertainmentMetadataComplete,
            lastFrameAt: health.lastFrameAt,
            lastError: health.lastError
        )
    }

}

extension RelayManager: HueAmbienceRelayRuntimeProviding {}
