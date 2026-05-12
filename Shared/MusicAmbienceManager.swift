import Foundation
import Observation
import UIKit

protocol HueAmbienceResourceFetching {
    func fetchResources(for bridge: HueBridgeInfo) async throws -> HueBridgeResources
}

private struct DefaultHueAmbienceResourceFetcher: HueAmbienceResourceFetching {
    func fetchResources(for bridge: HueBridgeInfo) async throws -> HueBridgeResources {
        try await HueBridgeClient(bridge: bridge).fetchResources()
    }
}

@MainActor
@Observable
final class MusicAmbienceManager {
    static let shared = MusicAmbienceManager()

    enum Status: Equatable {
        case disabled
        case unconfigured
        case idle
        case syncing(String)
        case paused(String)
        case error(String)

        var title: String {
            switch self {
            case .disabled:
                return "Disabled"
            case .unconfigured:
                return "Set Up Hue Ambience"
            case .idle:
                return "Ready"
            case .syncing(let detail), .paused(let detail):
                return detail
            case .error(let message):
                return message
            }
        }
    }

    private(set) var status: Status = .unconfigured

    @ObservationIgnored private let store: HueAmbienceStore
    @ObservationIgnored private let renderer: HueAmbienceRendering?
    @ObservationIgnored private let targetResolver: HueTargetResolving?
    @ObservationIgnored private let resourceFetcher: HueAmbienceResourceFetching?
    @ObservationIgnored private let relayRuntime: HueAmbienceRelayRuntimeProviding?
    @ObservationIgnored private let flowIntervalSecondsOverride: TimeInterval?
    @ObservationIgnored private var lastTrackKey: String?
    @ObservationIgnored private var lastPalette: [HueRGBColor] = []
    @ObservationIgnored private var lastRenderSignature: RenderSignature?
    @ObservationIgnored private var lastResolvedTargets: [HueResolvedAmbienceTarget] = []
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var resourceRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var renderGeneration = 0

    init(
        store: HueAmbienceStore? = nil,
        renderer: HueAmbienceRendering? = nil,
        targetResolver: HueTargetResolving? = nil,
        resourceFetcher: HueAmbienceResourceFetching? = nil,
        relayRuntime: HueAmbienceRelayRuntimeProviding? = nil,
        flowIntervalSeconds: TimeInterval? = nil
    ) {
        self.store = store ?? .shared
        self.renderer = renderer
        self.targetResolver = targetResolver
        self.resourceFetcher = resourceFetcher
        self.relayRuntime = relayRuntime
        self.flowIntervalSecondsOverride = flowIntervalSeconds
        refreshStatus()
    }

    func refreshStatus() {
        if !store.isEnabled {
            stopLocalAmbienceForCurrentControlMode()
            setStatus(.disabled)
        } else if store.bridge == nil || store.mappings.isEmpty {
            stopLocalAmbienceForCurrentControlMode()
            setStatus(.unconfigured)
        } else if shouldDeferLocalHueAmbience {
            resetRenderState()
            setStatus(.syncing("NAS Relay controlling Hue Ambience"))
        } else {
            refreshHueResourcesIfNeeded(for: store.mappings)
            setStatus(.idle)
        }
    }

    func mappingsForCurrentPlayback(_ snapshot: HueAmbiencePlaybackSnapshot) -> [HueSonosMapping] {
        guard store.isEnabled else { return [] }

        let ids: [String]
        switch store.groupStrategy {
        case .allMappedRooms:
            ids = snapshot.groupMemberIDs.isEmpty
                ? snapshot.selectedSonosID.map { [$0] } ?? []
                : snapshot.groupMemberIDs
        case .coordinatorOnly:
            ids = snapshot.selectedSonosID.map { [$0] } ?? []
        }

        var seenIDs = Set<String>()
        return ids.compactMap { sonosID in
            guard seenIDs.insert(sonosID).inserted else { return nil }
            return store.mapping(forSonosID: sonosID)
        }
    }

    func receive(snapshot: HueAmbiencePlaybackSnapshot) {
        guard store.isEnabled else {
            stopLocalAmbienceForCurrentControlMode()
            setStatus(.disabled)
            return
        }
        guard store.bridge != nil else {
            stopLocalAmbienceForCurrentControlMode()
            setStatus(.unconfigured)
            return
        }
        guard !shouldDeferLocalHueAmbience else {
            resetRenderState()
            setStatus(snapshot.isPlaying ? .syncing("NAS Relay controlling Hue Ambience") : .idle)
            return
        }
        guard snapshot.isPlaying else {
            stopActiveAmbience()
            setStatus(.idle)
            return
        }

        let mappings = mappingsForCurrentPlayback(snapshot)
        guard !mappings.isEmpty else {
            stopActiveAmbience()
            setStatus(.paused("No Hue area mapped"))
            return
        }
        guard !needsFunctionMetadataRefresh(for: mappings) else {
            refreshHueResourcesIfNeeded(for: mappings)
            setStatus(.paused("Refreshing Hue lights"))
            return
        }

        let trackKey = [snapshot.trackTitle, snapshot.artist, snapshot.albumArtURL]
            .compactMap { $0 }
            .joined(separator: "|")
        if trackKey != lastTrackKey || lastPalette.isEmpty {
            lastTrackKey = trackKey
            if let data = snapshot.albumArtImage, let image = UIImage(data: data) {
                lastPalette = AlbumPaletteExtractor.palette(from: image)
            }
        }

        setStatus(.syncing("Syncing \(mappings.count) Hue area\(mappings.count == 1 ? "" : "s")"))
        applyPalette(to: mappings, trackKey: trackKey)
    }

    private func setStatus(_ newStatus: Status) {
        status = newStatus
        store.statusText = newStatus.title
    }

    private func applyPalette(to mappings: [HueSonosMapping], trackKey: String) {
        let resolvedTargets = (targetResolver ?? StoredHueTargetResolver(
            areas: store.hueAreas,
            lights: store.hueLights
        )).resolveTargets(for: mappings)
        guard !resolvedTargets.isEmpty, !lastPalette.isEmpty else {
            return
        }
        lastResolvedTargets = resolvedTargets

        let palette = lastPalette
        let motionStyle = store.motionStyle
        let signature = RenderSignature(
            trackKey: trackKey,
            palette: palette,
            targets: resolvedTargets,
            motionStyle: motionStyle
        )
        guard signature != lastRenderSignature else {
            return
        }
        lastRenderSignature = signature

        guard let renderer = renderer ?? defaultRenderer() else {
            return
        }

        renderTask?.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        let intervalSeconds = flowIntervalSecondsOverride ?? store.flowSpeed.intervalSeconds
        renderTask = Task { [weak self] in
            do {
                switch motionStyle {
                case .flowing where palette.count > 1:
                    var step = 0
                    while !Task.isCancelled {
                        try await renderer.apply(
                            palette: Self.rotatedPalette(palette, by: step),
                            to: resolvedTargets,
                            transitionSeconds: intervalSeconds
                        )
                        step += 1
                        try await Task.sleep(nanoseconds: Self.sleepNanoseconds(for: intervalSeconds))
                    }
                case .flowing, .still:
                    try await renderer.apply(
                        palette: palette,
                        to: resolvedTargets,
                        transitionSeconds: 4
                    )
                }

                await MainActor.run { [weak self] in
                    guard let self, renderGeneration == generation else {
                        return
                    }

                    renderTask = nil
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, renderGeneration == generation else {
                        return
                    }

                    renderTask = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled, renderGeneration == generation else {
                        return
                    }

                    renderTask = nil
                    lastRenderSignature = nil
                    setStatus(.error(error.localizedDescription))
                }
            }
        }
    }

    private func defaultRenderer() -> HueAmbienceRendering? {
        guard let bridge = store.bridge else {
            return nil
        }

        return HueAmbienceRenderer(lightClient: HueBridgeClient(bridge: bridge))
    }

    private func needsFunctionMetadataRefresh(for mappings: [HueSonosMapping]) -> Bool {
        guard store.hueResources.needsFunctionMetadataRefresh else {
            return false
        }

        return mappings.contains { mapping in
            mapping.effectiveAmbienceTarget?.allowsManualLightSelection == true
        }
    }

    private func refreshHueResourcesIfNeeded(for mappings: [HueSonosMapping]) {
        guard resourceRefreshTask == nil,
              needsFunctionMetadataRefresh(for: mappings),
              let bridge = store.bridge else {
            return
        }

        let fetcher = resourceFetcher ?? DefaultHueAmbienceResourceFetcher()
        resourceRefreshTask = Task { [weak self] in
            do {
                let resources = try await fetcher.fetchResources(for: bridge)
                await MainActor.run { [weak self] in
                    guard let self else {
                        return
                    }

                    resourceRefreshTask = nil
                    guard store.updateResources(resources, forBridgeID: bridge.id) else {
                        return
                    }

                    if store.isEnabled && store.bridge != nil && !store.mappings.isEmpty {
                        setStatus(.idle)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else {
                        return
                    }

                    resourceRefreshTask = nil
                    guard store.isEnabled, store.bridge?.id == bridge.id else {
                        return
                    }

                    setStatus(.error(error.localizedDescription))
                }
            }
        }
    }

    private var shouldDeferLocalHueAmbience: Bool {
        (relayRuntime ?? RelayManager.shared).shouldDeferLocalHueAmbience
    }

    private func stopLocalAmbienceForCurrentControlMode() {
        if shouldDeferLocalHueAmbience {
            resetRenderState()
        } else {
            stopActiveAmbience()
        }
    }

    private func resetRenderState() {
        renderTask?.cancel()
        renderTask = nil
        lastRenderSignature = nil
        lastResolvedTargets = []
        renderGeneration += 1
    }

    private func stopActiveAmbience() {
        renderTask?.cancel()
        renderTask = nil
        lastRenderSignature = nil
        renderGeneration += 1

        guard !lastResolvedTargets.isEmpty else {
            return
        }
        let targets = lastResolvedTargets
        lastResolvedTargets = []

        guard store.stopBehavior == .turnOff,
              let renderer = renderer ?? defaultRenderer() else {
            return
        }

        let behavior = store.stopBehavior
        let generation = renderGeneration
        renderTask = Task {
            try? await renderer.stop(targets: targets, behavior: behavior)
            if renderGeneration == generation {
                renderTask = nil
            }
        }
    }

    private static func rotatedPalette(_ palette: [HueRGBColor], by offset: Int) -> [HueRGBColor] {
        guard !palette.isEmpty else { return [] }
        let shift = offset % palette.count
        return Array(palette[shift...] + palette[..<shift])
    }

    private static func sleepNanoseconds(for seconds: TimeInterval) -> UInt64 {
        UInt64(max(seconds, 0.1) * 1_000_000_000)
    }
}

private extension HueSonosMapping {
    var effectiveAmbienceTarget: HueAmbienceTarget? {
        if preferredTarget?.isLegacyDirectLightTarget == true {
            return fallbackTarget
        }

        return preferredTarget ?? fallbackTarget
    }
}

private struct RenderSignature: Equatable {
    var trackKey: String
    var palette: [HueRGBColor]
    var targets: [HueResolvedAmbienceTarget]
    var motionStyle: HueAmbienceMotionStyle
}
