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
    var isPlayingFromQueue = true
    var showingSpeakerPicker = false
    var showFullPlayer = true
    var miniPlayerDragOffset: CGFloat = 0
    var memberVolumes: [String: Int] = [:]
    var groupAlbumColors: [String: Color] = [:]
    var groupAlbumImages: [String: UIImage] = [:]
    private var groupLastArtURL: [String: String] = [:]

    var positionSeconds: TimeInterval = 0
    var durationSeconds: TimeInterval = 0
    var isShuffling: Bool = false
    var repeatMode: RepeatMode = .off
    var queue: [QueueItem] = []
    var connectionState: ConnectionState = .disconnected

    let discovery = SonosDiscovery()

    private var refreshTimer: Timer?
    private var positionTimer: Timer?
    private var lastAlbumArtURL: String?
    private var lastWidgetTrackTitle: String?
    private var lastEnrichedTrackKey: String?
    private var lastCloudQualityAttempt: Date = .distantPast
    private var consecutiveFailures = 0
    private var currentActivity: Activity<SonosActivityAttributes>?
    private var albumArtTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundKeepaliveTask: Task<Void, Never>?
    /// Timestamp of the last real Sonos position fetch, used to keep timerInterval accurate.
    private var positionFetchedAt: Date = .now

    /// Cloud API group ID resolved for the currently selected speaker.
    private var cloudGroupId: String?
    /// Cached cloud-sourced audio quality keyed by track title to survive UPnP refreshes.
    private var cachedCloudQuality: (track: String, quality: AudioQuality)?
    private var isEnrichingQuality = false
    /// When set, refreshState() will not overwrite isShuffling/repeatMode until this date.
    private var playModeLockUntil: Date = .distantPast

    private static let albumArtSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    enum ConnectionState { case connected, disconnected, reconnecting }

    var isPlaying: Bool { transportState == .playing }
    var isConfigured: Bool { selectedSpeaker != nil }
    var currentCloudGroupId: String? { cloudGroupId }

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
                await resolveCloudGroupId()
                await refreshState()
                await refreshAllGroupStatuses()
            }
        } else if let first = speakers.first {
            selectedSpeaker = first
            syncSpeakerToStorage(first)
            Task {
                await resolveCloudGroupId()
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
        consecutiveFailures = 0
        cloudGroupId = nil
        cachedCloudQuality = nil
        lastEnrichedTrackKey = nil
        lastCloudQualityAttempt = .distantPast
        prefetchTask?.cancel()
        prefetchTask = nil
        queueArtCache.removeAllObjects()
        cachedArtURLs = []
        dominantColorCache = [:]

        // Pre-populate from the group's cached trackInfo to avoid progress bar flash
        if let group = groupStatuses.first(where: {
            $0.coordinator.id == speaker.id || $0.coordinator.groupId == speaker.groupId
        }) {
            trackInfo = group.trackInfo
            positionSeconds = group.trackInfo?.positionSeconds ?? 0
            durationSeconds = group.trackInfo?.durationSeconds ?? 0
        } else {
            trackInfo = nil
            positionSeconds = 0
            durationSeconds = 0
        }

        await refreshState()
        await resolveCloudGroupId()
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
        let prev = transportState
        transportState = isPlaying ? .paused : .playing
        do {
            if prev == .playing { try await SonosAPI.pause(ip: ip) }
            else { try await SonosAPI.play(ip: ip) }
            try? await Task.sleep(for: .milliseconds(300))
            await refreshState()
        } catch {
            transportState = prev
            errorMessage = error.localizedDescription
        }
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

    func toggleShuffle() async {
        guard let ip = playbackIP else { return }
        let prev = isShuffling
        isShuffling = !prev
        playModeLockUntil = Date().addingTimeInterval(2)
        do {
            try await SonosAPI.setPlayMode(ip: ip, shuffle: isShuffling, repeat: repeatMode)
        } catch {
            isShuffling = prev
            playModeLockUntil = .distantPast
            errorMessage = error.localizedDescription
        }
    }

    func toggleRepeat() async {
        guard let ip = playbackIP else { return }
        let prev = repeatMode
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        playModeLockUntil = Date().addingTimeInterval(2)
        do {
            try await SonosAPI.setPlayMode(ip: ip, shuffle: isShuffling, repeat: repeatMode)
        } catch {
            repeatMode = prev
            playModeLockUntil = .distantPast
            errorMessage = error.localizedDescription
        }
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

    func fetchMemberVolumes() async {
        for player in currentGroupMembers {
            if let vol = try? await SonosAPI.getVolume(ip: player.ipAddress) {
                memberVolumes[player.ipAddress] = vol
            }
        }
    }

    func setMemberVolume(ip: String, volume: Int) async {
        memberVolumes[ip] = volume
        do {
            try await SonosAPI.setVolume(ip: ip, volume: volume)
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Per-Group Controls

    func togglePlayPauseForGroup(groupID: String, coordinatorIP: String, currentState: TransportState) async {
        guard let idx = groupStatuses.firstIndex(where: { $0.id == groupID }) else { return }
        let prev = groupStatuses[idx].transportState
        groupStatuses[idx].transportState = (prev == .playing) ? .paused : .playing
        do {
            if prev == .playing {
                try await SonosAPI.pause(ip: coordinatorIP)
            } else {
                try await SonosAPI.play(ip: coordinatorIP)
            }
            try? await Task.sleep(for: .milliseconds(400))
            if let state = try? await SonosAPI.getTransportInfo(ip: coordinatorIP) {
                if let i = groupStatuses.firstIndex(where: { $0.id == groupID }) {
                    groupStatuses[i].transportState = state
                }
            }
        } catch {
            if let i = groupStatuses.firstIndex(where: { $0.id == groupID }) {
                groupStatuses[i].transportState = prev
            }
            errorMessage = error.localizedDescription
        }
    }

    func setVolumeForGroup(groupID: String, coordinatorIP: String, newVolume: Int) async {
        guard let idx = groupStatuses.firstIndex(where: { $0.id == groupID }) else { return }
        groupStatuses[idx].volume = newVolume
        do {
            // Use GroupRenderingControl so all group members are adjusted proportionally.
            try await SonosAPI.setGroupVolume(ip: coordinatorIP, volume: newVolume)
            if coordinatorIP == volumeIP {
                volume = newVolume
                SharedStorage.cachedVolume = newVolume
            }
        } catch { errorMessage = error.localizedDescription }
    }

    var queueUpdateID: String = "0"
    /// Observable set of URLs whose images have been persisted to disk (survives NSCache eviction).
    private(set) var cachedArtURLs: Set<String> = []

    /// Returns the cached image for a queue item URL, checking memory then disk.
    /// Falls back gracefully if NSCache evicted the image while the view re-renders.
    func queueImage(for urlStr: String) -> UIImage? {
        if let img = queueArtCache.object(forKey: urlStr as NSString) { return img }
        // NSCache evicted it — restore from disk (local flash, ~0.1 ms, safe on main thread).
        return QueueArtDiskCache.shared.image(for: urlStr)
    }
    /// NSCache stores the actual UIImages; auto-evicts under memory pressure, capped at 150 images (~30 MB).
    let queueArtCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 150
        c.totalCostLimit = 30 * 1024 * 1024
        return c
    }()
    /// Dominant color cache keyed by album art URL — avoids re-computing per-pixel analysis on every track change.
    private var dominantColorCache: [String: Color] = [:]
    private var queueLoaded = false
    private var prefetchTask: Task<Void, Never>?

    // MARK: - Queue

    func loadQueue() async {
        guard let ip = playbackIP else { return }
        do {
            let result = try await SonosAPI.getQueue(ip: ip)
            queue = result.items
            queueUpdateID = result.updateID
            queueLoaded = true
            schedulePrefetch()
        } catch {
            if queue.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func schedulePrefetch() {
        prefetchTask?.cancel()

        // Build fetch order: start from now-playing, go forward, then wrap to beginning.
        let nowIndex = queue.firstIndex(where: {
            $0.title == trackInfo?.title && $0.artist == trackInfo?.artist
        }) ?? 0
        let reordered = Array(queue[nowIndex...]) + Array(queue[..<nowIndex])

        var seen = Set<String>()
        let ordered = reordered.compactMap { $0.albumArtURL }
            .filter { !cachedArtURLs.contains($0) && seen.insert($0).inserted }
        guard !ordered.isEmpty else { return }

        let diskCache = QueueArtDiskCache.shared
        prefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                let maxConcurrent = 3
                var index = 0

                func addNext() {
                    guard index < ordered.count else { return }
                    let urlStr = ordered[index]
                    index += 1
                    group.addTask { [weak self] in
                        guard let self, !Task.isCancelled else { return }
                        await self.fetchArtForURL(urlStr, diskCache: diskCache)
                    }
                }

                for _ in 0..<min(maxConcurrent, ordered.count) { addNext() }
                for await _ in group { addNext() }
            }
        }
    }

    private func fetchArtForURL(_ urlStr: String, diskCache: QueueArtDiskCache) async {
        guard !cachedArtURLs.contains(urlStr) else { return }

        // L2: disk cache.
        // L3: network. Always capture raw data so we can populate sibling disk slots.
        let imageData: Data
        if let d = diskCache.data(for: urlStr) {
            imageData = d
        } else {
            guard let url = URL(string: urlStr),
                  let (downloaded, _) = try? await Self.albumArtSession.data(from: url) else { return }
            imageData = downloaded
            diskCache.store(imageData, for: urlStr)
        }
        guard let image = UIImage(data: imageData) else { return }
        let color = dominantColorCache[urlStr] ?? image.dominantColor()

        // Collect all other uncached URLs from the same album so one download
        // populates every track's cache entry simultaneously.
        let albumKey = queue.first(where: { $0.albumArtURL == urlStr })
            .map { "\($0.album)||||\($0.artist)" }
        var siblings: [String] = []
        if let key = albumKey {
            var seen = Set<String>()
            siblings = queue.compactMap { item -> String? in
                guard let u = item.albumArtURL,
                      u != urlStr,
                      !cachedArtURLs.contains(u),
                      "\(item.album)||||\(item.artist)" == key,
                      seen.insert(u).inserted else { return nil }
                return u
            }
        }

        // Write primary URL to memory cache.
        queueArtCache.setObject(image, forKey: urlStr as NSString, cost: imageData.count)
        // Write all sibling URLs to memory + disk cache.
        for sibling in siblings {
            queueArtCache.setObject(image, forKey: sibling as NSString, cost: imageData.count)
            if !diskCache.contains(sibling) { diskCache.store(imageData, for: sibling) }
        }

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.dominantColorCache[urlStr] = color
            self.cachedArtURLs.insert(urlStr)
            for sibling in siblings {
                self.dominantColorCache[sibling] = color
                self.cachedArtURLs.insert(sibling)
            }
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

    func playQueueItemNext(_ item: QueueItem) async {
        guard let ip = playbackIP else { return }
        let currentIndex = queue.firstIndex(where: {
            $0.title == trackInfo?.title && $0.artist == trackInfo?.artist
        }) ?? 0
        let targetPosition = currentIndex + 2 // Sonos uses 1-based, insert after current
        let sonosFrom = item.trackNumber
        do {
            try await SonosAPI.reorderTracksInQueue(ip: ip, startIndex: sonosFrom,
                                                     numTracks: 1, insertBefore: targetPosition,
                                                     updateID: queueUpdateID)
            await loadQueue()
        } catch { errorMessage = error.localizedDescription }
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
            if !isPlayingFromQueue, let speaker = selectedSpeaker {
                try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: speaker.id)
            }
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

    var isEverywhereActive: Bool {
        let visible = allSpeakers.filter { !$0.isInvisible }
        guard visible.count > 1, let gid = selectedSpeaker.map({ $0.groupId ?? $0.id }) else { return false }
        return visible.allSatisfy { $0.groupId == gid }
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

    /// Separates every non-coordinator member of the group, leaving each speaker standalone.
    func separateGroup(groupID: String) async {
        guard let source = groupStatuses.first(where: { $0.id == groupID }) else { return }
        let nonCoordinators = source.members.filter { $0.id != source.coordinator.id }
        guard !nonCoordinators.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        for member in nonCoordinators {
            do {
                try await SonosAPI.leaveGroup(speakerIP: member.ipAddress)
                try? await Task.sleep(for: .milliseconds(300))
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        await reloadTopology()
        await refreshAllGroupStatuses()
    }

    /// Merges every member of `sourceGroupID` into `targetGroupID`.
    func mergeGroups(sourceGroupID: String, intoGroupID: String) async {
        guard sourceGroupID != intoGroupID,
              let target = groupStatuses.first(where: { $0.id == intoGroupID }),
              let source = groupStatuses.first(where: { $0.id == sourceGroupID }) else { return }

        isLoading = true
        defer { isLoading = false }

        for member in source.members {
            do {
                try await SonosAPI.joinGroup(speakerIP: member.ipAddress,
                                             coordinatorUUID: target.coordinator.id)
                try? await Task.sleep(for: .milliseconds(300))
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        await reloadTopology()
        await refreshAllGroupStatuses()
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
                    async let v = SonosAPI.getGroupVolume(ip: coord.ipAddress)
                    let state = try await t
                    let track = try await p
                    let vol = (try? await v) ?? 0
                    statuses.append(SpeakerGroupStatus(
                        id: coord.groupId ?? coord.id,
                        coordinator: coord, members: members,
                        trackInfo: track, transportState: state, volume: vol
                    ))
                } catch {
                    statuses.append(SpeakerGroupStatus(
                        id: coord.groupId ?? coord.id,
                        coordinator: coord, members: members,
                        trackInfo: nil, transportState: .unknown, volume: 0
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
            if groupAlbumImages[key] != nil, groupLastArtURL[key] == urlStr {
                continue
            }
            do {
                let (data, _) = try await Self.albumArtSession.data(from: url)
                if let image = UIImage(data: data) {
                    groupAlbumImages[key] = image
                    groupLastArtURL[key] = urlStr
                    let color = dominantColorCache[urlStr] ?? image.dominantColor()
                    dominantColorCache[urlStr] = color
                    groupAlbumColors[key] = color
                }
            } catch {
                groupAlbumColors[key] = nil
                groupAlbumImages[key] = nil
                groupLastArtURL[key] = nil
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

    /// Override track metadata (e.g. when Sonos can't resolve it) and reload album art.
    func patchTrackInfo(title: String, artist: String, album: String, albumArtURL: String?) {
        trackInfo?.title = title
        trackInfo?.artist = artist
        trackInfo?.album = album
        if let art = albumArtURL {
            trackInfo?.albumArtURL = art
        }
        updateSharedCache()
        Task { await loadAlbumArt() }
    }

    // MARK: - State Refresh

    func refreshState() async {
        guard let pIP = playbackIP, let vIP = volumeIP else { return }
        do {
            async let t = SonosAPI.getTransportInfo(ip: pIP)
            async let p = SonosAPI.getPositionInfo(ip: pIP)
            async let v = SonosAPI.getVolume(ip: vIP)
            async let m = SonosAPI.getPlayMode(ip: pIP)
            async let mediaURI = SonosAPI.getMediaInfo(ip: pIP)
            transportState = try await t
            trackInfo = try await p
            volume = try await v
            let mode = try await m
            isPlayingFromQueue = (try? await mediaURI)?.hasPrefix("x-rincon-queue:") ?? true
            if Date() > playModeLockUntil {
                isShuffling = mode.shuffle
                repeatMode = mode.repeat
            }

            positionSeconds = trackInfo?.positionSeconds ?? 0
            durationSeconds = trackInfo?.durationSeconds ?? 0
            positionFetchedAt = Date()

            // Restore cached cloud quality if UPnP didn't provide one and the track matches.
            if trackInfo?.audioQuality == nil,
               let cached = cachedCloudQuality,
               cached.track == trackInfo?.title {
                trackInfo?.audioQuality = cached.quality
            }

            consecutiveFailures = 0
            connectionState = .connected
            errorMessage = nil

            await enrichAudioQualityFromCloud()
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

    // MARK: - Sonos Cloud API

    /// Resolve the cloud group ID by matching the selected speaker's RINCON UUID to cloud players.
    func resolveCloudGroupId() async {
        guard let speaker = selectedSpeaker,
              let token = await SonosAuth.shared.validAccessToken() else {
            print("[SonosCloud] resolveCloudGroupId skipped — speaker: \(selectedSpeaker?.name ?? "nil"), loggedIn: \(SonosAuth.shared.isLoggedIn)")
            return
        }

        do {
            if SonosAuth.shared.householdId == nil {
                let households = try await SonosCloudAPI.getHouseholds(token: token)
                print("[SonosCloud] households: \(households.map { "\($0.id) (\($0.name ?? "?")" })")
                SonosAuth.shared.householdId = households.first?.id
            }
            guard let householdId = SonosAuth.shared.householdId else {
                print("[SonosCloud] no householdId")
                return
            }

            let response = try await SonosCloudAPI.getGroups(token: token, householdId: householdId)
            let rincon = speaker.id
            print("[SonosCloud] speaker id: \(rincon), name: \(speaker.name)")
            print("[SonosCloud] groups: \(response.groups.map { "\($0.id) playerIds=\($0.playerIds)" })")
            print("[SonosCloud] players: \(response.players.map { "\($0.id) name=\($0.name)" })")

            cloudGroupId = response.groups.first(where: { group in
                group.playerIds.contains(where: { $0.contains(rincon) || rincon.contains($0) })
            })?.id

            if cloudGroupId == nil {
                cloudGroupId = response.groups.first(where: { group in
                    response.players.filter { group.playerIds.contains($0.id) }
                        .contains(where: { $0.name == speaker.name })
                })?.id
            }

            if let gid = cloudGroupId {
                print("[SonosCloud] resolved cloudGroupId: \(gid)")
                SharedStorage.cloudGroupId = gid
            } else {
                print("[SonosCloud] Could not match speaker \(speaker.name) (id: \(rincon)) to any cloud group")
            }
        } catch SonosCloudError.unauthorized {
            print("[SonosCloud] unauthorized, refreshing token...")
            _ = await SonosAuth.shared.refreshAccessToken()
        } catch {
            print("[SonosCloud] resolveCloudGroupId error: \(error)")
        }
    }

    /// If UPnP didn't provide audio quality, fetch it from the Sonos Cloud API.
    private func enrichAudioQualityFromCloud() async {
        let trackKey = trackInfo.map { "\($0.title ?? "")|\($0.artist ?? "")|\($0.albumArtURL ?? "")" }

        guard trackInfo?.audioQuality == nil,
              !isEnrichingQuality,
              transportState == .playing,
              SonosAuth.shared.isLoggedIn else { return }

        // New track → fetch immediately; same track → respect cooldown
        if trackKey == lastEnrichedTrackKey {
            guard Date().timeIntervalSince(lastCloudQualityAttempt) > 15 else { return }
        }

        isEnrichingQuality = true
        defer { isEnrichingQuality = false }
        lastCloudQualityAttempt = Date()

        if cloudGroupId == nil {
            await resolveCloudGroupId()
        }
        guard let groupId = cloudGroupId,
              let token = await SonosAuth.shared.validAccessToken() else { return }

        do {
            let metadata = try await fetchPlaybackMetadata(token: token, groupId: groupId)
            if let quality = metadata.currentItem?.track?.quality,
               let mapped = AudioQuality.from(cloudQuality: quality) {
                trackInfo?.audioQuality = mapped
                if let title = trackInfo?.title {
                    cachedCloudQuality = (track: title, quality: mapped)
                }
            }
            lastEnrichedTrackKey = trackKey
        } catch SonosCloudError.unauthorized {
            _ = await SonosAuth.shared.refreshAccessToken()
        } catch {
            lastEnrichedTrackKey = trackKey
            print("[SonosCloud] playbackMetadata error: \(error)")
        }
    }

    private func fetchPlaybackMetadata(token: String, groupId: String) async throws -> SonosCloudAPI.CloudPlaybackMetadata {
        do {
            return try await SonosCloudAPI.getPlaybackMetadata(token: token, groupId: groupId)
        } catch SonosCloudError.httpError(410) {
            print("[SonosCloud] playbackMetadata 410 — re-resolving cloudGroupId…")
            cloudGroupId = nil
            await resolveCloudGroupId()
            guard let newGroupId = cloudGroupId else { throw SonosCloudError.groupNotFound }
            return try await SonosCloudAPI.getPlaybackMetadata(token: token, groupId: newGroupId)
        }
    }

    private var groupRefreshCounter = 0

    func startAutoRefresh() {
        stopAutoRefresh()
        groupRefreshCounter = 0
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshState()
                self.groupRefreshCounter += 1
                if self.groupRefreshCounter % 2 == 0 {
                    await self.refreshAllGroupStatuses()
                }
            }
        }

        // Start background keepalive when app goes to background (while Live Activity is running).
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.startBackgroundKeepalive() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopBackgroundKeepalive() }
        }
        // End Live Activity when the app is killed so it doesn't linger on Lock Screen.
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.stopLiveActivity()
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopBackgroundKeepalive()
        NotificationCenter.default.removeObserver(self,
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self,
            name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self,
            name: UIApplication.willTerminateNotification, object: nil)
    }

    // MARK: - Background Keepalive for Live Activity

    /// When music is playing and the app moves to background, iOS suspends our Timer.
    /// This grabs ~30s of background execution time and polls every 5s so the Live
    /// Activity (track title, progress timestamps) stays fresh through track changes.
    @MainActor
    private func startBackgroundKeepalive() {
        guard currentActivity != nil else { return }
        stopBackgroundKeepalive()

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SonosLiveActivity") { [weak self] in
            self?.stopBackgroundKeepalive()
        }

        backgroundKeepaliveTask = Task { [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { break }
                await self.refreshState()
            }
            await MainActor.run { self?.stopBackgroundKeepalive() }
        }
    }

    @MainActor
    private func stopBackgroundKeepalive() {
        backgroundKeepaliveTask?.cancel()
        backgroundKeepaliveTask = nil
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
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

        let shouldKeep = isPlaying || transportState == .paused || transportState == .transitioning
        guard shouldKeep else {
            stopLiveActivity()
            return
        }

        // Reattach to an existing activity if the in-memory reference was lost (app relaunch).
        if currentActivity == nil {
            currentActivity = Activity<SonosActivityAttributes>.activities.first
        }

        if currentActivity == nil {
            // No existing activity — create one (always, even during TRANSITIONING).
            let state = makeActivityState()
            let attrs = SonosActivityAttributes(speakerName: speaker.name)
            currentActivity = try? Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            return
        }

        // During TRANSITIONING the Sonos device is buffering between tracks.
        // isPlaying == false here, so makeActivityState() would produce nil startedAt/endsAt,
        // causing the Live Activity to fall back to a frozen static progress bar.
        // Instead, skip the update entirely — the existing timerInterval keeps animating on its
        // own using the device clock. We'll push a fresh state once the new track is actually
        // playing (next refreshState cycle).
        guard transportState != .transitioning else { return }

        let state = makeActivityState()
        Task { await currentActivity?.update(.init(state: state, staleDate: nil)) }
    }

    func stopLiveActivity() {
        // Only end activities when we actually have a reference — this prevents
        // accidentally killing a valid activity on app launch before state is fetched.
        guard let activity = currentActivity else { return }
        currentActivity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func makeActivityState() -> SonosActivityAttributes.ContentState {
        // Anchor the timerInterval to the moment the Sonos position was actually fetched,
        // not to Date() which is slightly later. This prevents small jitter on each update.
        let anchor = positionFetchedAt
        let startedAt = isPlaying && durationSeconds > 0
            ? anchor.addingTimeInterval(-positionSeconds) : nil
        let endsAt = isPlaying && durationSeconds > 0
            ? anchor.addingTimeInterval(durationSeconds - positionSeconds) : nil
        // Compress album art to a small thumbnail for embedding in ContentState.
        // Keep under ~2KB to stay well within ActivityKit's ContentState size limit.
        let thumbnail: Data? = albumArtImage.flatMap {
            $0.preparingThumbnail(of: CGSize(width: 60, height: 60))?
                .jpegData(compressionQuality: 0.65)
        }
        return .init(
            trackTitle: trackInfo?.title ?? "Not Playing",
            artist: trackInfo?.artist ?? "—",
            album: trackInfo?.album ?? "",
            isPlaying: isPlaying,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            dominantColorHex: SharedStorage.cachedDominantColorHex,
            startedAt: startedAt,
            endsAt: endsAt,
            albumArtThumbnail: thumbnail,
            groupMemberCount: currentGroupMembers.filter { !$0.isInvisible }.count,
            playbackSourceRaw: trackInfo?.source.rawValue
        )
    }

    // MARK: - Private Helpers

    private func syncSpeakerToStorage(_ speaker: SonosPlayer) {
        SharedStorage.speakerIP = speaker.ipAddress
        SharedStorage.speakerName = speaker.name
        SharedStorage.coordinatorIP = speaker.coordinatorIP
    }

    private func updateSharedCache() {
        let currentTitle = trackInfo?.title
        let trackChanged = currentTitle != lastWidgetTrackTitle

        SharedStorage.isPlaying = isPlaying
        SharedStorage.cachedTrackTitle = trackInfo?.title
        SharedStorage.cachedArtist = trackInfo?.artist
        SharedStorage.cachedAlbum = trackInfo?.album
        SharedStorage.cachedAlbumArtURL = trackInfo?.albumArtURL
        SharedStorage.cachedVolume = volume
        SharedStorage.cachedPlaybackSource = trackInfo?.source.rawValue
        SharedStorage.cachedAudioQualityLabel = trackInfo?.audioQuality?.label
        SharedStorage.cachedGroupMemberCount = currentGroupMembers.filter { !$0.isInvisible }.count
        // Keep cloudGroupId in sync so the widget can call Cloud API independently.
        if let gid = cloudGroupId { SharedStorage.cloudGroupId = gid }

        // Reload widget only when something meaningful changed (track, play state).
        if trackChanged || isPlaying != SharedStorage.isPlaying {
            lastWidgetTrackTitle = currentTitle
            WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        }
    }

    private func loadAlbumArt() async {
        guard let urlStr = trackInfo?.albumArtURL, urlStr != lastAlbumArtURL else { return }
        lastAlbumArtURL = urlStr
        albumArtTask?.cancel()

        guard let url = URL(string: urlStr) else {
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.5)) {
                    albumArtImage = nil
                    albumArtDominantColor = nil
                }
            }
            SharedStorage.albumArtData = nil
            SharedStorage.cachedDominantColorHex = nil
            return
        }

        let capturedURL = urlStr
        albumArtTask = Task {
            // Fast path: image already in memory cache.
            if let cached = self.queueArtCache.object(forKey: urlStr as NSString) {
                let color = self.dominantColorCache[urlStr] ?? cached.dominantColor()
                // Keep disk entry warm so LRU eviction doesn't drop the current song's art.
                QueueArtDiskCache.shared.touch(urlStr)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.8)) {
                        self.albumArtImage = cached
                        self.albumArtDominantColor = color
                        self.dominantColorCache[urlStr] = color
                        if let gid = self.selectedSpeaker?.groupId ?? self.selectedSpeaker?.id {
                            self.groupAlbumColors[gid] = color
                            self.groupAlbumImages[gid] = cached
                        }
                    }
                }
                if let data = cached.jpegData(compressionQuality: 0.9) {
                    SharedStorage.albumArtData = data
                }
                SharedStorage.cachedDominantColorHex = cached.dominantColorHex()
                return
            }

            // L2: check disk cache before hitting the network.
            if let cached = QueueArtDiskCache.shared.image(for: urlStr) {
                let color = self.dominantColorCache[urlStr] ?? cached.dominantColor()
                self.queueArtCache.setObject(cached, forKey: urlStr as NSString,
                                             cost: Int(cached.size.width * cached.size.height * 4))
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.8)) {
                        self.albumArtImage = cached
                        self.albumArtDominantColor = color
                        self.dominantColorCache[urlStr] = color
                        if let gid = self.selectedSpeaker?.groupId ?? self.selectedSpeaker?.id {
                            self.groupAlbumColors[gid] = color
                            self.groupAlbumImages[gid] = cached
                        }
                    }
                }
                if let data = cached.jpegData(compressionQuality: 0.9) {
                    SharedStorage.albumArtData = data
                }
                SharedStorage.cachedDominantColorHex = cached.dominantColorHex()
                return
            }

            // Slow path: download from network.
            do {
                let (data, _) = try await Self.albumArtSession.data(from: url)
                guard !Task.isCancelled, lastAlbumArtURL == capturedURL else { return }
                let image = UIImage(data: data)
                let dominantColor = self.dominantColorCache[urlStr] ?? image?.dominantColor()
                if let image { QueueArtDiskCache.shared.store(data, for: urlStr) }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.8)) {
                        self.albumArtImage = image
                        self.albumArtDominantColor = dominantColor
                        if let color = dominantColor { self.dominantColorCache[urlStr] = color }
                        if let gid = self.selectedSpeaker?.groupId ?? self.selectedSpeaker?.id {
                            if let color = dominantColor { self.groupAlbumColors[gid] = color }
                            if let img = image { self.groupAlbumImages[gid] = img }
                        }
                    }
                }
                SharedStorage.albumArtData = data
                SharedStorage.cachedDominantColorHex = image?.dominantColorHex()
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        self.albumArtImage = nil
                        self.albumArtDominantColor = nil
                    }
                }
            }
        }
        await albumArtTask?.value
    }
}
