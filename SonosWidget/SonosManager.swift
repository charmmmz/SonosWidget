import Foundation
import SwiftUI
import WidgetKit
import ActivityKit

@Observable
final class SonosManager {
    var speakers: [SonosPlayer] = []
    var selectedSpeaker: SonosPlayer?
    var trackInfo: TrackInfo?
    var transportState: TransportState = .stopped
    var volume: Int = 0
    var isLoading = false
    var errorMessage: String?
    var albumArtImage: UIImage?
    var showingAddSpeaker = false
    var showingQueue = false

    var positionSeconds: TimeInterval = 0
    var durationSeconds: TimeInterval = 0
    var queue: [QueueItem] = []
    var connectionState: ConnectionState = .disconnected

    let discovery = SonosDiscovery()

    private var refreshTimer: Timer?
    private var positionTimer: Timer?
    private var lastAlbumArtURL: String?
    private var consecutiveFailures = 0
    private var currentActivity: Activity<SonosActivityAttributes>?
    private var albumArtTask: Task<Void, Never>?

    private static let albumArtSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    enum ConnectionState { case connected, disconnected, reconnecting }

    var isPlaying: Bool { transportState == .playing }
    var isConfigured: Bool { selectedSpeaker != nil }

    /// IP to send playback commands (group coordinator)
    private var playbackIP: String? { selectedSpeaker?.playbackIP }
    /// IP for volume commands (individual speaker)
    private var volumeIP: String? { selectedSpeaker?.ipAddress }

    // MARK: - Lifecycle

    func loadSavedState() {
        speakers = SharedStorage.savedSpeakers.filter(\.isCoordinator)
        if let ip = SharedStorage.speakerIP,
           let speaker = speakers.first(where: { $0.ipAddress == ip }) {
            selectedSpeaker = speaker
            Task { await refreshState() }
        } else if let first = speakers.first {
            selectedSpeaker = first
            syncSpeakerToStorage(first)
            Task { await refreshState() }
        } else {
            discovery.startScan()
        }
    }

    // MARK: - Speaker Management

    func connectFromDiscovery(_ speaker: SonosPlayer) async {
        isLoading = true
        errorMessage = nil
        discovery.stopScan()
        speakers = discovery.discoveredSpeakers
        SharedStorage.savedSpeakers = speakers
        let target = speaker.isCoordinator ? speaker : speakers.first(where: { $0.groupId == speaker.groupId && $0.isCoordinator }) ?? speaker
        await selectSpeaker(target)
        isLoading = false
    }

    func addSpeaker(ip: String) async {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        errorMessage = nil

        do {
            let discovered = try await SonosAPI.withRetry {
                try await SonosAPI.getZoneGroupState(ip: trimmed)
            }
            if discovered.isEmpty {
                let name = try await SonosAPI.getDeviceName(ip: trimmed)
                speakers = [SonosPlayer(id: UUID().uuidString, name: name, ipAddress: trimmed, isCoordinator: true)]
            } else {
                speakers = discovered.filter(\.isCoordinator)
            }
            SharedStorage.savedSpeakers = speakers
            let speaker = speakers.first(where: { $0.isCoordinator }) ?? speakers.first
            if let speaker { await selectSpeaker(speaker) }
        } catch {
            errorMessage = "Cannot connect to \(trimmed): \(error.localizedDescription)"
        }
        isLoading = false
    }

    func selectSpeaker(_ speaker: SonosPlayer) async {
        selectedSpeaker = speaker
        syncSpeakerToStorage(speaker)

        albumArtTask?.cancel()
        lastAlbumArtURL = nil
        albumArtImage = nil
        trackInfo = nil
        consecutiveFailures = 0

        await refreshState()
    }

    func rescan() {
        stopAutoRefresh()
        stopLiveActivity()
        speakers.removeAll()
        selectedSpeaker = nil
        SharedStorage.savedSpeakers = []
        SharedStorage.speakerIP = nil
        discovery.startScan()
    }

    // MARK: - Playback Controls

    func togglePlayPause() async {
        guard let ip = playbackIP else { return }
        do {
            if isPlaying { try await SonosAPI.pause(ip: ip) }
            else { try await SonosAPI.play(ip: ip) }
            try? await Task.sleep(for: .milliseconds(300))
            await refreshState()
        } catch { errorMessage = error.localizedDescription }
    }

    func nextTrack() async {
        guard let ip = playbackIP else { return }
        do {
            try await SonosAPI.next(ip: ip)
            try? await Task.sleep(for: .milliseconds(500))
            await refreshState()
        } catch { errorMessage = error.localizedDescription }
    }

    func previousTrack() async {
        guard let ip = playbackIP else { return }
        do {
            try await SonosAPI.previous(ip: ip)
            try? await Task.sleep(for: .milliseconds(500))
            await refreshState()
        } catch { errorMessage = error.localizedDescription }
    }

    func seekTo(_ seconds: TimeInterval) async {
        guard let ip = playbackIP else { return }
        positionSeconds = seconds
        do {
            try await SonosAPI.seek(ip: ip, position: SonosTime.apiFormat(seconds))
        } catch { errorMessage = error.localizedDescription }
    }

    func updateVolume(_ newVolume: Int) async {
        guard let ip = volumeIP else { return }
        volume = newVolume
        do {
            try await SonosAPI.setVolume(ip: ip, volume: newVolume)
            SharedStorage.cachedVolume = newVolume
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Queue

    func loadQueue() async {
        guard let ip = playbackIP else { return }
        queue = (try? await SonosAPI.getQueue(ip: ip)) ?? []
    }

    // MARK: - State Refresh

    func refreshState() async {
        guard let pIP = playbackIP, let vIP = volumeIP else { return }
        do {
            async let t = SonosAPI.getTransportInfo(ip: pIP)
            async let p = SonosAPI.getPositionInfo(ip: pIP)
            async let v = SonosAPI.getVolume(ip: vIP)
            transportState = try await t
            trackInfo = try await p
            volume = try await v

            positionSeconds = trackInfo?.positionSeconds ?? 0
            durationSeconds = trackInfo?.durationSeconds ?? 0

            consecutiveFailures = 0
            connectionState = .connected
            errorMessage = nil

            updateSharedCache()
            await loadAlbumArt()
            managePositionTimer()
            manageLiveActivity()
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                connectionState = .disconnected
                errorMessage = "Connection lost — pull to refresh."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refreshState() }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Position Timer

    private func managePositionTimer() {
        if isPlaying && durationSeconds > 0 {
            if positionTimer == nil {
                positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self, self.isPlaying else { return }
                    self.positionSeconds = min(self.positionSeconds + 1, self.durationSeconds)
                }
            }
        } else {
            positionTimer?.invalidate()
            positionTimer = nil
        }
    }

    // MARK: - Live Activity

    private func manageLiveActivity() {
        guard let speaker = selectedSpeaker else { return }
        let state = makeActivityState()

        if isPlaying || transportState == .paused {
            if currentActivity == nil {
                let attrs = SonosActivityAttributes(speakerName: speaker.name)
                currentActivity = try? Activity.request(
                    attributes: attrs,
                    content: .init(state: state, staleDate: nil),
                    pushType: nil
                )
            } else {
                Task { await currentActivity?.update(.init(state: state, staleDate: nil)) }
            }
        } else {
            stopLiveActivity()
        }
    }

    func stopLiveActivity() {
        guard let activity = currentActivity else { return }
        currentActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func makeActivityState() -> SonosActivityAttributes.ContentState {
        .init(
            trackTitle: trackInfo?.title ?? "Not Playing",
            artist: trackInfo?.artist ?? "—",
            album: trackInfo?.album ?? "",
            isPlaying: isPlaying,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds
        )
    }

    // MARK: - Private Helpers

    private func syncSpeakerToStorage(_ speaker: SonosPlayer) {
        SharedStorage.speakerIP = speaker.ipAddress
        SharedStorage.speakerName = speaker.name
        SharedStorage.coordinatorIP = speaker.coordinatorIP
    }

    private func updateSharedCache() {
        SharedStorage.isPlaying = isPlaying
        SharedStorage.cachedTrackTitle = trackInfo?.title
        SharedStorage.cachedArtist = trackInfo?.artist
        SharedStorage.cachedAlbum = trackInfo?.album
        SharedStorage.cachedAlbumArtURL = trackInfo?.albumArtURL
        SharedStorage.cachedVolume = volume
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
    }

    private func loadAlbumArt() async {
        guard let urlStr = trackInfo?.albumArtURL, urlStr != lastAlbumArtURL else { return }
        lastAlbumArtURL = urlStr
        albumArtTask?.cancel()

        guard let url = URL(string: urlStr) else {
            albumArtImage = nil
            SharedStorage.albumArtData = nil
            return
        }

        let capturedURL = urlStr
        albumArtTask = Task {
            do {
                let (data, _) = try await Self.albumArtSession.data(from: url)
                guard !Task.isCancelled, lastAlbumArtURL == capturedURL else { return }
                albumArtImage = UIImage(data: data)
                SharedStorage.albumArtData = data
            } catch {
                guard !Task.isCancelled else { return }
                albumArtImage = nil
            }
        }
        await albumArtTask?.value
    }
}
