import Foundation
import SwiftUI
import WidgetKit
import ActivityKit

@Observable
final class SonosManager {
    var speakers: [SonosPlayer] = []
    var allSpeakers: [SonosPlayer] = []
    var groupStatuses: [SpeakerGroupStatus] = []
    var selectedSpeaker: SonosPlayer?
    var trackInfo: TrackInfo?
    var transportState: TransportState = .stopped
    var volume: Int = 0
    var isLoading = false
    var errorMessage: String?
    var albumArtImage: UIImage?
    var albumArtDominantColor: Color?
    var showingAddSpeaker = false
    var showingQueue = false
    var showingSpeakerPicker = false
    var showFullPlayer = true
    var groupAlbumColors: [String: Color] = [:]
    var groupAlbumImages: [String: UIImage] = [:]

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
        allSpeakers = SharedStorage.savedSpeakers
        speakers = allSpeakers.filter(\.isCoordinator)
        if let ip = SharedStorage.speakerIP,
           let speaker = speakers.first(where: { $0.ipAddress == ip }) {
            selectedSpeaker = speaker
            Task {
                await refreshState()
                await refreshAllGroupStatuses()
            }
        } else if let first = speakers.first {
            selectedSpeaker = first
            syncSpeakerToStorage(first)
            Task {
                await refreshState()
                await refreshAllGroupStatuses()
            }
        } else {
            discovery.startScan()
        }
    }

    // MARK: - Speaker Management

    func connectFromDiscovery(_ speaker: SonosPlayer) async {
        isLoading = true
        errorMessage = nil
        discovery.stopScan()
        allSpeakers = discovery.discoveredSpeakers
        speakers = allSpeakers.filter(\.isCoordinator)
        SharedStorage.savedSpeakers = allSpeakers
        let target = speaker.isCoordinator ? speaker : speakers.first(where: { $0.groupId == speaker.groupId && $0.isCoordinator }) ?? speaker
        await selectSpeaker(target)
        await refreshAllGroupStatuses()
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
                allSpeakers = [SonosPlayer(id: UUID().uuidString, name: name, ipAddress: trimmed, isCoordinator: true)]
            } else {
                allSpeakers = discovered
            }
            speakers = allSpeakers.filter(\.isCoordinator)
            SharedStorage.savedSpeakers = allSpeakers
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

    var queueUpdateID: String = "0"
    private var queueLoaded = false

    // MARK: - Queue

    func loadQueue() async {
        guard let ip = playbackIP else { return }
        do {
            let result = try await SonosAPI.getQueue(ip: ip)
            queue = result.items
            queueUpdateID = result.updateID
            queueLoaded = true
        } catch {
            if queue.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    func deleteFromQueue(item: QueueItem) async {
        guard let ip = playbackIP else { return }
        do {
            try await SonosAPI.removeTrackFromQueue(ip: ip, objectID: item.objectID, updateID: queueUpdateID)
            await loadQueue()
        } catch { errorMessage = error.localizedDescription }
    }

    func moveQueueItem(from source: IndexSet, to destination: Int) {
        guard let ip = playbackIP else { return }
        guard let fromIndex = source.first else { return }
        let sonosFrom = fromIndex + 1
        let sonosDest = destination > fromIndex ? destination + 1 : destination + 1
        queue.move(fromOffsets: source, toOffset: destination)

        let capturedUpdateID = queueUpdateID
        Task {
            do {
                try await SonosAPI.reorderTracksInQueue(ip: ip, startIndex: sonosFrom,
                                                         numTracks: 1, insertBefore: sonosDest,
                                                         updateID: capturedUpdateID)
                await loadQueue()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func playNext(uri: String, metadata: String) async {
        guard let ip = playbackIP else { return }
        do {
            try await SonosAPI.addURIToQueue(ip: ip, uri: uri, metadata: metadata, asNext: true)
            await loadQueue()
        } catch { errorMessage = error.localizedDescription }
    }

    func playTrackInQueue(_ item: QueueItem) async {
        guard let ip = playbackIP else { return }
        do {
            try await SonosAPI.seekToTrack(ip: ip, trackNumber: item.trackNumber)
            try await SonosAPI.play(ip: ip)
            try? await Task.sleep(for: .milliseconds(300))
            await refreshState()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Speaker Grouping

    var currentGroupMembers: [SonosPlayer] {
        guard let selected = selectedSpeaker else { return [] }
        let groupId = selected.groupId ?? selected.id
        return allSpeakers.filter { $0.groupId == groupId && !$0.isInvisible }
    }

    func addSpeakerToGroup(_ speaker: SonosPlayer) async {
        guard let coordinator = selectedSpeaker else { return }
        let coordUUID = coordinator.id
        do {
            try await SonosAPI.joinGroup(speakerIP: speaker.ipAddress, coordinatorUUID: coordUUID)
            try? await Task.sleep(for: .milliseconds(500))
            await reloadTopology()
        } catch { errorMessage = error.localizedDescription }
    }

    func removeSpeakerFromGroup(_ speaker: SonosPlayer) async {
        do {
            try await SonosAPI.leaveGroup(speakerIP: speaker.ipAddress)
            try? await Task.sleep(for: .milliseconds(500))
            await reloadTopology()
        } catch { errorMessage = error.localizedDescription }
    }

    func transferPlayback(to target: SonosPlayer) async {
        guard let current = selectedSpeaker, current.id != target.id else { return }
        do {
            let targetAlreadyInGroup = currentGroupMembers.contains { $0.id == target.id }

            if targetAlreadyInGroup {
                // Target is already in our group — just remove current coordinator
                // so target becomes the new coordinator and keeps playing.
                try await SonosAPI.leaveGroup(speakerIP: current.ipAddress)
            } else {
                // Target is standalone — add it to our group first, then remove current.
                try await SonosAPI.joinGroup(speakerIP: target.ipAddress, coordinatorUUID: current.id)
                try? await Task.sleep(for: .milliseconds(500))
                try await SonosAPI.leaveGroup(speakerIP: current.ipAddress)
            }

            try? await Task.sleep(for: .milliseconds(500))
            await reloadTopology()

            if let updated = speakers.first(where: { $0.id == target.id })
                ?? allSpeakers.first(where: { $0.id == target.id }) {
                await selectSpeaker(updated)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshAllGroupStatuses() async {
        guard let anyIP = allSpeakers.first?.ipAddress ?? selectedSpeaker?.ipAddress else { return }

        do {
            let fresh = try await SonosAPI.getZoneGroupState(ip: anyIP)
            allSpeakers = fresh
            speakers = fresh.filter(\.isCoordinator)
            SharedStorage.savedSpeakers = fresh

            var statuses: [SpeakerGroupStatus] = []
            let coordinators = fresh.filter(\.isCoordinator)

            for coord in coordinators {
                let members = fresh.filter { $0.groupId == coord.groupId && !$0.isInvisible }
                do {
                    async let t = SonosAPI.getTransportInfo(ip: coord.ipAddress)
                    async let p = SonosAPI.getPositionInfo(ip: coord.ipAddress)
                    let state = try await t
                    let track = try await p
                    statuses.append(SpeakerGroupStatus(
                        id: coord.groupId ?? coord.id,
                        coordinator: coord, members: members,
                        trackInfo: track, transportState: state
                    ))
                } catch {
                    statuses.append(SpeakerGroupStatus(
                        id: coord.groupId ?? coord.id,
                        coordinator: coord, members: members,
                        trackInfo: nil, transportState: .unknown
                    ))
                }
            }
            groupStatuses = statuses
            await loadGroupAlbumColors()
        } catch { /* keep existing data */ }
    }

    private func loadGroupAlbumColors() async {
        for status in groupStatuses {
            let key = status.id
            if status.coordinator.id == selectedSpeaker?.id {
                if let color = albumArtDominantColor { groupAlbumColors[key] = color }
                if let img = albumArtImage { groupAlbumImages[key] = img }
                continue
            }
            guard let urlStr = status.trackInfo?.albumArtURL,
                  let url = URL(string: urlStr) else {
                groupAlbumColors[key] = nil
                groupAlbumImages[key] = nil
                continue
            }
            if groupAlbumImages[key] != nil,
               status.trackInfo?.title == groupStatuses.first(where: { $0.id == key })?.trackInfo?.title {
                continue
            }
            do {
                let (data, _) = try await Self.albumArtSession.data(from: url)
                if let image = UIImage(data: data) {
                    groupAlbumImages[key] = image
                    groupAlbumColors[key] = image.dominantColor()
                }
            } catch {
                groupAlbumColors[key] = nil
                groupAlbumImages[key] = nil
            }
        }
    }

    private func reloadTopology() async {
        guard let anyIP = allSpeakers.first?.ipAddress ?? selectedSpeaker?.ipAddress else { return }
        if let fresh = try? await SonosAPI.getZoneGroupState(ip: anyIP) {
            allSpeakers = fresh
            speakers = fresh.filter(\.isCoordinator)
            SharedStorage.savedSpeakers = fresh
        }
        await refreshAllGroupStatuses()
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
            if queueLoaded { await loadQueue() }
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
        SharedStorage.cachedPlaybackSource = trackInfo?.source.rawValue
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
    }

    private func loadAlbumArt() async {
        guard let urlStr = trackInfo?.albumArtURL, urlStr != lastAlbumArtURL else { return }
        lastAlbumArtURL = urlStr
        albumArtTask?.cancel()

        guard let url = URL(string: urlStr) else {
            albumArtImage = nil
            albumArtDominantColor = nil
            SharedStorage.albumArtData = nil
            SharedStorage.cachedDominantColorHex = nil
            return
        }

        let capturedURL = urlStr
        albumArtTask = Task {
            do {
                let (data, _) = try await Self.albumArtSession.data(from: url)
                guard !Task.isCancelled, lastAlbumArtURL == capturedURL else { return }
                let image = UIImage(data: data)
                albumArtImage = image
                albumArtDominantColor = image?.dominantColor()
                if let gid = selectedSpeaker?.groupId ?? selectedSpeaker?.id {
                    if let color = albumArtDominantColor { groupAlbumColors[gid] = color }
                    if let img = image { groupAlbumImages[gid] = img }
                }
                SharedStorage.albumArtData = data
                SharedStorage.cachedDominantColorHex = image?.dominantColorHex()
            } catch {
                guard !Task.isCancelled else { return }
                albumArtImage = nil
                albumArtDominantColor = nil
            }
        }
        await albumArtTask?.value
    }
}
