import SwiftUI

struct PlaylistDetailView: View {
    let playlistItem: BrowseItem
    let searchManager: SearchManager
    let manager: SonosManager

    @State private var response: SonosCloudAPI.AlbumBrowseResponse?
    @State private var extraTracks: [SonosCloudAPI.AlbumTrackItem] = []
    @State private var allPagesLoaded = false
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var playingItemId: String?
    @State private var toastMessage: String?
    @State private var isFavorited = false
    @State private var coverImage: UIImage?
    @State private var themeColor: Color?
    /// Sticky "known working" page size for this browse session. We start
    /// at 100; if the service rejects it (NetEase's "我喜欢的音乐" 2000+
    /// track dynamic playlist returns 500 for large pages), `fetchPage`
    /// halves and records the successful size here so subsequent pagination
    /// calls skip the doomed larger attempts.
    @State private var effectivePageSize: Int = 100

    private var playlistTitle: String { response?.title ?? playlistItem.title }
    private var subtitleText: String { response?.subtitle ?? playlistItem.artist }
    private var coverURL: String? {
        response?.images?.tile1x1 ?? playlistItem.albumArtURL
    }
    private var tracks: [SonosCloudAPI.AlbumTrackItem] {
        let base = response?.tracks?.items ?? response?.section?.items ?? []
        return extraTracks.isEmpty ? base : base + extraTracks
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                actionBar
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                trackList
            }
        }
        .background { playlistBackground }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                playlistMenu
            }
        }
        .task { await loadPlaylist() }
        .task(id: coverURL) { await loadCoverImage() }
        .onAppear { isFavorited = searchManager.isFavorited(playlistItem) }
        .toast($toastMessage)
    }

    // MARK: - Blurred Background

    @ViewBuilder
    private var playlistBackground: some View {
        if let img = coverImage {
            ZStack {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80)
                    .scaleEffect(1.5)
                Color.black.opacity(0.5)
            }
            .ignoresSafeArea()
        } else {
            Color(.systemBackground).ignoresSafeArea()
        }
    }

    private func loadCoverImage() async {
        guard let urlStr = coverURL, let url = URL(string: urlStr) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let img = UIImage(data: data)
            coverImage = img
            if let color = img?.dominantColor() {
                themeColor = color
            }
        } catch {
            SonosLog.error(.playlistDetail, "Cover image load failed: \(error)")
        }
    }

    // MARK: - Three-Dot Menu

    private var playlistMenu: some View {
        Menu {
            Button {
                toggleFavorite()
            } label: {
                Label(isFavorited ? "Remove from Sonos Favorites" : "Add to Sonos Favorites",
                      systemImage: isFavorited ? "heart.fill" : "heart")
            }

            Divider()

            Button {
                Task {
                    await searchManager.playNext(item: playlistItem, manager: manager)
                    showToast("Playing next")
                }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                Task {
                    await searchManager.addToQueue(item: playlistItem, manager: manager)
                    showToast("Added to queue")
                }
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .symbolRenderingMode(.hierarchical)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 10) {
            AsyncImage(url: URL(string: coverURL ?? "")) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: playlistItem.cloudType == "COLLECTION" ? "folder.fill" : "music.note.list")
                                .font(.system(size: 48))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(maxWidth: 280)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)

            VStack(spacing: 4) {
                Text(playlistTitle)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                if !subtitleText.isEmpty {
                    // Subtitle doubles as a short tagline for Apple Music
                    // ("Curated by Apple Music") and as a full editorial
                    // paragraph for NetEase Cloud Music. Use ExpandableText
                    // so long blurbs get a "MORE" toggle that opens a
                    // fullscreen reader sheet (Apple Music pattern) instead
                    // of pushing the track list off-screen.
                    if subtitleText.count > 80 {
                        ExpandableText(text: subtitleText,
                                       title: playlistTitle,
                                       collapsedLineLimit: 3)
                            .padding(.top, 4)
                    } else {
                        Text(subtitleText)
                            .font(.subheadline)
                            .foregroundStyle(themeColor ?? .secondary)
                    }
                }

                if let total = response?.tracks?.total ?? response?.section?.total {
                    Text(playlistSubtitle(trackCount: total))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    private func playlistSubtitle(trackCount: Int) -> String {
        var parts: [String] = []
        if let provider = response?.providerInfo?.name {
            parts.append(provider)
        }
        let containerCount = tracks.filter(\.isBrowsable).count
        let pureTrackCount = trackCount - containerCount
        if containerCount > 0 && pureTrackCount > 0 {
            parts.append("\(pureTrackCount) tracks · \(containerCount) folders")
        } else if containerCount > 0 {
            parts.append("\(containerCount) items")
        } else {
            parts.append("\(trackCount) tracks")
            if allPagesLoaded {
                parts.append(totalDuration)
            }
        }
        return parts.joined(separator: " · ")
    }

    private var totalDuration: String {
        let seconds = tracks.compactMap { Int($0.duration ?? "") }.reduce(0, +)
        let mins = seconds / 60
        if mins >= 60 {
            return "\(mins / 60) hr \(mins % 60) min"
        }
        return "\(mins) min"
    }

    // MARK: - Action Bar (Play / Shuffle)

    private var actionBar: some View {
        HStack(spacing: 12) {
            actionButton(icon: "play.fill", label: "Play", id: "play-all") {
                playPlaylist()
            }

            actionButton(icon: "shuffle", label: "Shuffle", id: "shuffle") {
                playPlaylistShuffled()
            }
        }
        .padding(.horizontal)
    }

    private func actionButton(icon: String, label: String, id: String,
                              action: @escaping () -> Void) -> some View {
        let isActive = playingItemId == id
        let isDisabled = playingItemId != nil && !isActive

        return Button(action: action) {
            HStack(spacing: 6) {
                if isActive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                }
                Text(label)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(themeColor ?? .white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }

    // MARK: - Track List

    @ViewBuilder
    private var trackList: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 40)
        } else if let err = errorText {
            ContentUnavailableView("Failed to Load",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(err))
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { idx, track in
                    if track.isBrowsable {
                        containerRow(track, isLast: idx == tracks.count - 1)
                    } else {
                        trackRow(track, index: idx + 1, isLast: idx == tracks.count - 1)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    private func trackRow(_ track: SonosCloudAPI.AlbumTrackItem, index: Int, isLast: Bool) -> some View {
        let isPlaying = playingItemId == track.id
        let isDisabled = playingItemId != nil && !isPlaying

        return Button {
            playTrack(track)
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: track.images?.tile1x1 ?? "")) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(.tertiarySystemFill)
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(track.title ?? "")
                            .font(.body)
                            .lineLimit(1)
                        if track.isExplicit == true {
                            Image(systemName: "e.square.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(track.subtitle ?? track.artists?.first?.name ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isPlaying {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    trackActions(track)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .opacity(isDisabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .contextMenu { trackContextMenu(track) }
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().padding(.leading, 60)
            }
        }
    }

    private func containerRow(_ item: SonosCloudAPI.AlbumTrackItem, isLast: Bool) -> some View {
        let navItem = browseItemFromContainer(item)
        return NavigationLink {
            PlaylistDetailView(playlistItem: navItem, searchManager: searchManager, manager: manager)
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: item.images?.tile1x1 ?? "")) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(.tertiarySystemFill)
                            .overlay {
                                Image(systemName: "folder.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title ?? "")
                        .font(.body)
                        .lineLimit(1)
                    Text(item.subtitle ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().padding(.leading, 60)
            }
        }
    }

    private func browseItemFromContainer(_ item: SonosCloudAPI.AlbumTrackItem) -> BrowseItem {
        let objectId = item.resource?.id?.objectId ?? item.id ?? ""
        let serviceId = item.resource?.id?.serviceId
        let accountId = item.resource?.id?.accountId
        let rType = item.resource?.type ?? "CONTAINER"

        let cloudType: String
        if rType == "ALBUM" {
            cloudType = "ALBUM"
        } else if rType == "PLAYLIST" {
            cloudType = "PLAYLIST"
        } else {
            cloudType = "COLLECTION"
        }

        let uri: String? = if let sid = serviceId, let aid = accountId {
            searchManager.buildPlayableURIPublic(
                objectId: objectId, serviceId: sid,
                accountId: aid, type: rType)
        } else {
            nil
        }

        return BrowseItem(
            id: objectId,
            title: item.title ?? "",
            artist: item.subtitle ?? "",
            album: "",
            albumArtURL: item.images?.tile1x1,
            uri: uri,
            isContainer: true,
            serviceId: serviceId.flatMap { searchManager.localSid(forCloudServiceId: $0) },
            cloudType: cloudType
        )
    }

    private func trackActions(_ track: SonosCloudAPI.AlbumTrackItem) -> some View {
        HStack(spacing: 2) {
            if let dur = track.duration, let secs = Int(dur) {
                Text(formatDuration(secs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Menu {
                trackContextMenu(track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
    }

    @ViewBuilder
    private func trackContextMenu(_ track: SonosCloudAPI.AlbumTrackItem) -> some View {
        let item = browseItemFromTrack(track)
        let trackFavorited = searchManager.isFavorited(item)

        Button { playTrack(track) } label: {
            Label("Play Now", systemImage: "play.fill")
        }

        Button {
            Task { await searchManager.playNext(item: item, manager: manager) }
            showToast("Playing next")
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            Task { await searchManager.addToQueue(item: item, manager: manager) }
            showToast("Added to queue")
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }

        Divider()

        Button {
            Task {
                if trackFavorited {
                    let ok = await searchManager.removeFromFavorites(item: item, manager: manager)
                    showToast(ok ? "Removed from Favorites" : "Failed to remove")
                } else {
                    let ok = await searchManager.addToFavorites(item: item, manager: manager)
                    showToast(ok ? "Added to Favorites" : "Failed to add")
                }
            }
        } label: {
            Label(trackFavorited ? "Remove from Sonos Favorites" : "Add to Sonos Favorites",
                  systemImage: trackFavorited ? "heart.slash" : "heart")
        }
    }

    // MARK: - Toast

    private func showToast(_ message: String) {
        withAnimation(ToastModifier.fadeAnimation) { toastMessage = message }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    private func browseItemFromTrack(_ track: SonosCloudAPI.AlbumTrackItem) -> BrowseItem {
        let objectId = track.resource?.id?.objectId ?? ""
        let title = track.title ?? ""
        let trackArtist = track.artists?.first?.name ?? ""
        let albumName = track.subtitle ?? ""
        let artURL = track.images?.tile1x1
        let mimeType = track.resource?.defaults.flatMap { defaults -> String? in
            guard let data = Data(base64Encoded: defaults),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["mimeType"] as? String
        }

        guard let serviceId = track.resource?.id?.serviceId,
              let accountId = track.resource?.id?.accountId else {
            return BrowseItem(id: objectId, title: title, artist: trackArtist,
                              album: albumName, albumArtURL: artURL,
                              isContainer: false)
        }
        return searchManager.makeTrackItem(
            objectId: objectId, title: title, artist: trackArtist,
            album: albumName, artURL: artURL, mimeType: mimeType,
            cloudServiceId: serviceId, accountId: accountId)
    }

    // MARK: - Data Loading

    private func loadPlaylist() async {
        guard response == nil else { isLoading = false; return }
        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            errorText = "Not logged in to Sonos Cloud"
            isLoading = false
            return
        }

        let serviceIdStr: String? = {
            if let sid = playlistItem.serviceId {
                return searchManager.cloudServiceId(forLocalSid: sid)
            }
            return searchManager.activeServiceIds.first
        }()

        guard let serviceId = serviceIdStr else {
            errorText = "No music service linked"
            isLoading = false
            return
        }

        let accountId = searchManager.linkedAccounts
            .first { $0.serviceId == serviceId }?.accountId ?? "2"

        let pageSize = 100
        do {
            response = try await fetchPage(
                offset: 0, pageSize: pageSize, token: token,
                householdId: householdId, serviceId: serviceId, accountId: accountId)
            isLoading = false

            let total = response?.tracks?.total ?? response?.section?.total ?? 0
            let fetched = response?.tracks?.items?.count ?? response?.section?.items?.count ?? 0
            if fetched < total {
                await loadRemainingPages(token: token, householdId: householdId,
                                         serviceId: serviceId, accountId: accountId,
                                         fetched: fetched, total: total, pageSize: pageSize)
            }
            allPagesLoaded = true
        } catch is CancellationError {
            SonosLog.debug(.playlistDetail, "Load cancelled (tab switch)")
        } catch {
            SonosLog.error(.playlistDetail, "Load failed: \(error)")
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    /// Fetch a single browse page for the current `playlistItem`. Tries the
    /// endpoint most likely to work given `cloudType`, and transparently
    /// falls back to `browseContainer` + smaller page sizes when the
    /// primary call errors out — NetEase Cloud Music's "我喜欢的音乐"
    /// (2000+ track dynamic "liked songs" playlist) returns HTTP 500 on
    /// `/playlists/{id}/browse?count=100`; halving the page size lets the
    /// SMAPI adapter enumerate items within its internal budget. We also
    /// fall back from `/playlists/` to `/containers/` because some dynamic
    /// playlists are modeled as containers on the service side.
    private func fetchPage(offset: Int, pageSize: Int,
                           token: String, householdId: String,
                           serviceId: String, accountId: String) async throws -> SonosCloudAPI.AlbumBrowseResponse {
        let id = playlistItem.id
        switch playlistItem.cloudType {
        case "COLLECTION":
            return try await browseWithFallback(
                token: token, householdId: householdId, serviceId: serviceId,
                accountId: accountId, offset: offset, initialCount: pageSize,
                primary: { count in
                    try await SonosCloudAPI.browseContainer(
                        token: token, householdId: householdId,
                        serviceId: serviceId, accountId: accountId,
                        containerId: id, count: count, offset: offset)
                },
                secondary: nil)
        case "ALBUM":
            return try await SonosCloudAPI.browseAlbum(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: accountId,
                albumId: id)
        default:
            return try await browseWithFallback(
                token: token, householdId: householdId, serviceId: serviceId,
                accountId: accountId, offset: offset, initialCount: pageSize,
                primary: { count in
                    try await SonosCloudAPI.browsePlaylist(
                        token: token, householdId: householdId,
                        serviceId: serviceId, accountId: accountId,
                        playlistId: id, count: count, offset: offset)
                },
                secondary: { count in
                    try await SonosCloudAPI.browseContainer(
                        token: token, householdId: householdId,
                        serviceId: serviceId, accountId: accountId,
                        containerId: id, count: count, offset: offset)
                })
        }
    }

    /// Try `primary` at the initial page size. On 5xx, try `secondary` (if
    /// provided). If either still 5xxs, halve the page size and retry.
    /// Gives up after shrinking below 10, at which point the service is
    /// genuinely unable to serve the container and we propagate the error.
    private func browseWithFallback(
        token: String, householdId: String, serviceId: String, accountId: String,
        offset: Int, initialCount: Int,
        primary: (Int) async throws -> SonosCloudAPI.AlbumBrowseResponse,
        secondary: ((Int) async throws -> SonosCloudAPI.AlbumBrowseResponse)?
    ) async throws -> SonosCloudAPI.AlbumBrowseResponse {
        // Start from `effectivePageSize` (sticky) rather than `initialCount`
        // so that once we've learned NetEase can only serve 25-per-page for
        // this playlist, we don't re-try 100 on every subsequent page.
        var count = min(effectivePageSize, initialCount)
        var lastError: Error?
        while count >= 10 {
            do {
                let result = try await primary(count)
                if effectivePageSize != count { effectivePageSize = count }
                return result
            } catch SonosCloudError.httpError(let code) where (500...599).contains(code) {
                SonosLog.info(.playlistDetail,
                    "primary browse \(code) at count=\(count) for '\(playlistItem.title)'")
                lastError = SonosCloudError.httpError(code)
            } catch {
                throw error
            }
            if let secondary {
                do {
                    let result = try await secondary(count)
                    if effectivePageSize != count { effectivePageSize = count }
                    return result
                } catch SonosCloudError.httpError(let code) where (500...599).contains(code) {
                    SonosLog.info(.playlistDetail,
                        "secondary browse \(code) at count=\(count) for '\(playlistItem.title)'")
                    lastError = SonosCloudError.httpError(code)
                } catch {
                    throw error
                }
            }
            count /= 2  // halve and retry — 100 → 50 → 25 → 12 → stop
        }
        throw lastError ?? SonosCloudError.httpError(500)
    }

    private func loadRemainingPages(token: String, householdId: String,
                                     serviceId: String, accountId: String,
                                     fetched: Int, total: Int, pageSize: Int) async {
        var offset = fetched
        while offset < total {
            do {
                try Task.checkCancellation()
                let page = try await fetchPage(
                    offset: offset, pageSize: pageSize, token: token,
                    householdId: householdId, serviceId: serviceId, accountId: accountId)
                let newItems = page.tracks?.items ?? page.section?.items ?? []
                if newItems.isEmpty { break }
                extraTracks.append(contentsOf: newItems)
                offset += newItems.count
                SonosLog.debug(.playlistDetail, "Pagination: loaded \(offset)/\(total)")
            } catch is CancellationError {
                SonosLog.debug(.playlistDetail, "Pagination cancelled")
                return
            } catch {
                SonosLog.error(.playlistDetail, "Pagination error at offset \(offset): \(error)")
                break
            }
        }
    }

    // MARK: - Playback

    private func playPlaylist() {
        guard playingItemId == nil else { return }
        playingItemId = "play-all"

        Task {
            if let ip = manager.selectedSpeaker?.playbackIP {
                let current = try? await SonosAPI.getPlayMode(ip: ip)
                if current?.shuffle == true {
                    try? await SonosAPI.setPlayMode(ip: ip, shuffle: false,
                                                    repeat: current?.repeat ?? .off)
                }
            }
            await searchManager.playNow(item: playlistItem, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    private func playPlaylistShuffled() {
        guard playingItemId == nil else { return }
        playingItemId = "shuffle"

        Task {
            if let ip = manager.selectedSpeaker?.playbackIP {
                let current = try? await SonosAPI.getPlayMode(ip: ip)
                try? await SonosAPI.setPlayMode(ip: ip, shuffle: true,
                                                repeat: current?.repeat ?? .off)
            }
            await searchManager.playNow(item: playlistItem, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    private func playTrack(_ track: SonosCloudAPI.AlbumTrackItem) {
        guard playingItemId == nil else { return }
        playingItemId = track.id

        let item = browseItemFromTrack(track)
        Task {
            await searchManager.playNow(item: item, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    private func toggleFavorite() {
        Task {
            if isFavorited {
                let ok = await searchManager.removeFromFavorites(item: playlistItem, manager: manager)
                if ok { isFavorited = false }
                showToast(ok ? "Removed from Favorites" : "Failed to remove")
            } else {
                let ok = await searchManager.addToFavorites(item: playlistItem, manager: manager)
                if ok { isFavorited = true }
                showToast(ok ? "Added to Favorites" : "Failed to add")
            }
        }
    }
}
