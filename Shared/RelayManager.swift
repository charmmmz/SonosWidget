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
                return "Syncing Hue Ambience"
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
    private(set) var hueAmbienceRuntimeDetail = "Sync Hue Ambience to NAS Relay to enable always-on ambience."
    private(set) var hueEntertainmentStreamingStatus: HueEntertainmentStreamingStatus = .unknown
    private(set) var hueEntertainmentStreamingDetail = "Entertainment streaming status has not been checked."
    private(set) var isCS2LightingEnabled = false
    private(set) var isCS2LightingActive = false
    private(set) var cs2LightingMode: CS2LightingMode = .idle
    private(set) var cs2LightingTransport: CS2LightingTransport = .unavailable
    private(set) var cs2LightingDetail = "CS2 sync is idle."
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
            updateHueEntertainmentStatus(nil)
            updateCS2LightingStatus(nil)
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
                self.updateHueEntertainmentStatus(health.hueEntertainment)
                self.updateCS2LightingStatus(health.cs2Lighting)
            } catch is CancellationError {
                // Newer probe took over — its result is what matters.
            } catch {
                guard !Task.isCancelled else { return }
                self.status = .unreachable(reason: error.localizedDescription)
                self.updateHueEntertainmentStatus(nil)
                self.updateCS2LightingStatus(nil)
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
            hueAmbienceRuntimeDetail = "Sync Hue Ambience to NAS Relay to enable always-on ambience."
            return
        }

        guard enabled else {
            hueAmbienceRuntimeStatus = .ready("Album ambience disabled")
            hueAmbienceRuntimeDetail = "Enable album ambience or CS2 sync to let NAS control your lights."
            return
        }

        let trimmedError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedError.isEmpty {
            hueAmbienceRuntimeStatus = .error(trimmedError)
            hueAmbienceRuntimeDetail = "NAS reported a Hue Ambience runtime error."
            return
        }

        if runtimeActive == true {
            switch renderMode {
            case .entertainmentStreaming:
                hueAmbienceRuntimeStatus = .active("Entertainment streaming active")
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
            : "NAS controls Hue Ambience while it is reachable."
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

    private func updateHueEntertainmentStatus(_ health: RelayClient.HealthResponse.HueEntertainment?) {
        guard let health else {
            hueEntertainmentStreamingStatus = .unknown
            hueEntertainmentStreamingDetail = "Entertainment streaming status has not been checked."
            return
        }

        hueEntertainmentStreamingStatus = health.streaming
        if let error = health.lastError, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hueEntertainmentStreamingDetail = error
            return
        }

        switch health.streaming {
        case .free:
            hueEntertainmentStreamingDetail = "Bridge Entertainment streaming is free."
        case .activeByRelay:
            hueEntertainmentStreamingDetail = "NAS Relay owns the active Entertainment stream."
        case .occupied:
            if let streamer = health.activeStreamer, !streamer.isEmpty {
                hueEntertainmentStreamingDetail = "Occupied by \(streamer)."
            } else {
                hueEntertainmentStreamingDetail = "Occupied by another Hue streaming app."
            }
        case .unknown:
            hueEntertainmentStreamingDetail = "Entertainment streaming status is not available yet."
        }
    }

    private func updateCS2LightingStatus(_ health: RelayClient.HealthResponse.CS2Lighting?) {
        guard let health else {
            isCS2LightingEnabled = false
            isCS2LightingActive = false
            cs2LightingMode = .idle
            cs2LightingTransport = .unavailable
            cs2LightingDetail = "CS2 sync is idle."
            return
        }

        isCS2LightingEnabled = health.enabled == true
        isCS2LightingActive = health.active == true
        cs2LightingMode = health.mode
        cs2LightingTransport = health.transport
        if let fallback = health.fallbackReason, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cs2LightingDetail = "Paused: \(fallback)"
        } else if isCS2LightingActive {
            cs2LightingDetail = "CS2 lighting is active."
        } else if isCS2LightingEnabled {
            cs2LightingDetail = "Waiting for CS2 game state."
        } else {
            cs2LightingDetail = "CS2 sync is disabled."
        }
    }

    func updateCS2LightingStatus(enabled: Bool) {
        isCS2LightingEnabled = enabled
        isCS2LightingActive = false
        cs2LightingMode = .idle
        cs2LightingTransport = .unavailable
        cs2LightingDetail = enabled
            ? "Waiting for CS2 game state."
            : "CS2 sync is disabled."
    }

}

extension RelayManager: HueAmbienceRelayRuntimeProviding {}
