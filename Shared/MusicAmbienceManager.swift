import Foundation
import Observation
import UIKit

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
                return "Set Up Music Ambience"
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
    @ObservationIgnored private var lastTrackKey: String?
    @ObservationIgnored private var lastPalette: [HueRGBColor] = []
    @ObservationIgnored private var lastRenderSignature: RenderSignature?
    @ObservationIgnored private var lastResolvedTargets: [HueResolvedAmbienceTarget] = []
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderGeneration = 0

    init(
        store: HueAmbienceStore? = nil,
        renderer: HueAmbienceRendering? = nil,
        targetResolver: HueTargetResolving? = nil
    ) {
        self.store = store ?? .shared
        self.renderer = renderer
        self.targetResolver = targetResolver
        refreshStatus()
    }

    func refreshStatus() {
        if !store.isEnabled {
            stopActiveAmbience()
            setStatus(.disabled)
        } else if store.bridge == nil || store.mappings.isEmpty {
            stopActiveAmbience()
            setStatus(.unconfigured)
        } else {
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
            stopActiveAmbience()
            setStatus(.disabled)
            return
        }
        guard store.bridge != nil else {
            stopActiveAmbience()
            setStatus(.unconfigured)
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
        let signature = RenderSignature(
            trackKey: trackKey,
            palette: palette,
            targets: resolvedTargets
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
        renderTask = Task {
            do {
                try await renderer.apply(
                    palette: palette,
                    to: resolvedTargets,
                    transitionSeconds: 4
                )
                if renderGeneration == generation {
                    renderTask = nil
                }
            } catch is CancellationError {
                if renderGeneration == generation {
                    renderTask = nil
                }
            } catch {
                guard !Task.isCancelled, renderGeneration == generation else {
                    return
                }

                renderTask = nil
                lastRenderSignature = nil
                setStatus(.error(error.localizedDescription))
            }
        }
    }

    private func defaultRenderer() -> HueAmbienceRendering? {
        guard let bridge = store.bridge else {
            return nil
        }

        return HueAmbienceRenderer(lightClient: HueBridgeClient(bridge: bridge))
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
}

private struct RenderSignature: Equatable {
    var trackKey: String
    var palette: [HueRGBColor]
    var targets: [HueResolvedAmbienceTarget]
}
