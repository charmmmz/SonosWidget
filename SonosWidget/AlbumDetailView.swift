import SwiftUI

struct AlbumDetailView: View {
    let albumItem: BrowseItem
    let searchManager: SearchManager
    let manager: SonosManager

    @State private var response: SonosCloudAPI.AlbumBrowseResponse?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var playingItemId: String?
    @State private var toastMessage: String?
    @State private var isFavorited = false
    @State private var coverImage: UIImage?
    @State private var resolvedAlbumCoverURL: String?
    @State private var themeColor: Color?

    private var albumTitle: String { response?.title ?? albumItem.title }
    private var artistName: String { response?.subtitle ?? albumItem.artist }
    /// Resolves the album cover from any non-empty image source. NetEase Cloud
    /// Music's browseAlbum often omits the album-level image but populates
    /// each track's `images.tile1x1`, so we fall through to the first track's
    /// art before giving up and showing the placeholder disc icon.
    private var coverURL: String? {
        let candidates: [String?] = [
            response?.images?.tile1x1,
            resolvedAlbumCoverURL,
            albumItem.albumArtURL,
            response?.tracks?.items?.first?.images?.tile1x1
        ]
        return candidates.lazy
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }
    private var tracks: [SonosCloudAPI.AlbumTrackItem] {
        response?.tracks?.items ?? []
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
        .background {
            albumBackground
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                albumMenu
            }
        }
        .task { await loadAlbum() }
        .task(id: coverURL) { await loadCoverImage() }
        .onAppear { isFavorited = searchManager.isFavorited(albumItem) }
        .toast($toastMessage)
    }

    // MARK: - Blurred Background

    @ViewBuilder
    private var albumBackground: some View {
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
            SonosLog.error(.albumDetail, "Cover image load failed: \(error)")
        }
    }

    // MARK: - Three-Dot Menu

    private var albumMenu: some View {
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
                    await searchManager.playNext(item: albumItem, manager: manager)
                    showToast("Playing next")
                }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                Task {
                    await searchManager.addToQueue(item: albumItem, manager: manager)
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
                            Image(systemName: "opticaldisc")
                                .font(.system(size: 48))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(maxWidth: 280)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)

            VStack(spacing: 4) {
                Text(albumTitle)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                artistLabel

                if let total = response?.tracks?.total {
                    Text(albumSubtitle(trackCount: total))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private var artistLabel: some View {
        let label = Text(artistName)
            .font(.subheadline)
            .foregroundStyle(themeColor ?? .secondary)

        if let nav = artistBrowseItem {
            NavigationLink {
                ArtistDetailView(artistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    /// Resolve the album's primary artist into a navigable `BrowseItem`.
    /// Uses the first track whose primary artist matches the album subtitle so
    /// "Various Artists" / featured artist tracks don't hijack the link.
    private var artistBrowseItem: BrowseItem? {
        let preferred = tracks.first { $0.artists?.first?.name == artistName } ?? tracks.first
        guard let track = preferred,
              let artist = track.artists?.first,
              let rawId = artist.id,
              let serviceId = track.resource?.id?.serviceId,
              let accountId = track.resource?.id?.accountId else { return nil }

        // `id` looks like "appleMusic:artist:12345#…" — strip the suffix and take the last component.
        let base = rawId.firstIndex(of: "#").map { String(rawId[..<$0]) } ?? rawId
        guard let objectId = base.components(separatedBy: ":").last,
              !objectId.isEmpty else { return nil }

        return searchManager.makeArtistItem(
            objectId: objectId,
            name: artist.name ?? artistName,
            cloudServiceId: serviceId,
            accountId: accountId)
    }

    private func albumSubtitle(trackCount: Int) -> String {
        var parts: [String] = []
        if let provider = response?.providerInfo?.name {
            parts.append(provider)
        }
        parts.append("\(trackCount) tracks")
        parts.append(totalDuration)
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
                playAlbum()
            }

            actionButton(icon: "shuffle", label: "Shuffle", id: "shuffle") {
                playAlbumShuffled()
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
                    trackRow(track, isLast: idx == tracks.count - 1)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    private func trackRow(_ track: SonosCloudAPI.AlbumTrackItem, isLast: Bool) -> some View {
        let isPlaying = playingItemId == track.id
        let isDisabled = playingItemId != nil && !isPlaying

        return Button {
            playTrack(track)
        } label: {
            HStack(spacing: 12) {
                Text("\(track.ordinal ?? 0)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)

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

                    if let artist = track.artists?.first?.name, artist != artistName {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isPlaying {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    trackActions(track)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .opacity(isDisabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .contextMenu { trackContextMenu(track) }
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().padding(.leading, 40)
            }
        }
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
        let trackArtist = track.artists?.first?.name ?? artistName
        let mimeType = track.resource?.defaults.flatMap { defaults -> String? in
            guard let data = Data(base64Encoded: defaults),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["mimeType"] as? String
        }

        guard let serviceId = track.resource?.id?.serviceId,
              let accountId = track.resource?.id?.accountId else {
            return BrowseItem(id: objectId, title: title, artist: trackArtist,
                              album: albumTitle, albumArtURL: coverURL,
                              isContainer: false)
        }
        return searchManager.makeTrackItem(
            objectId: objectId, title: title, artist: trackArtist,
            album: albumTitle, artURL: coverURL, mimeType: mimeType,
            cloudServiceId: serviceId, accountId: accountId)
    }

    // MARK: - Data Loading

    private func loadAlbum() async {
        guard response == nil else { isLoading = false; return }
        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            errorText = "Not logged in to Sonos Cloud"
            isLoading = false
            return
        }

        let serviceIdStr: String? = {
            if let sid = albumItem.serviceId {
                return searchManager.cloudServiceId(forLocalSid: sid)
            }
            return searchManager.activeServiceIds.first
        }()

        guard let serviceId = serviceIdStr else {
            errorText = "No music service linked"
            isLoading = false
            return
        }

        let accountId = accountIdFromURI(albumItem.uri) ?? searchManager.linkedAccounts
            .first { $0.serviceId == serviceId }?.accountId ?? "2"

        do {
            let albumId = try await initialAlbumId(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: accountId)
            response = try await SonosCloudAPI.browseAlbum(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: accountId,
                albumId: albumId)
            isLoading = false
        } catch is CancellationError {
            SonosLog.debug(.albumDetail, "Load cancelled (tab switch)")
        } catch {
            SonosLog.error(.albumDetail, "Load failed: \(error)")
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    private func initialAlbumId(token: String, householdId: String,
                                serviceId: String, accountId: String) async throws -> String {
        guard shouldResolveCatalogAlbum(serviceId: serviceId) else {
            return browseAlbumId(from: albumItem.id)
        }

        do {
            let searchResult = try await SonosCloudAPI.searchService(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: accountId,
                term: albumItem.title, count: 50)
            guard let albumResource = preferredAlbumResource(in: searchResult),
                  let rawResolvedId = albumResource.id?.objectId,
                  !rawResolvedId.isEmpty else { return browseAlbumId(from: albumItem.id) }

            let resolvedId = browseAlbumId(from: rawResolvedId)
            resolvedAlbumCoverURL = albumResource.images?.first?.url
                ?? albumResource.container?.images?.first?.url

            if resolvedId != albumItem.id {
                SonosLog.debug(.albumDetail, "Resolved Apple Music album id \(albumItem.id) → \(resolvedId)")
            }
            return resolvedId
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SonosLog.debug(.albumDetail, "Album id resolution failed: \(error)")
            return browseAlbumId(from: albumItem.id)
        }
    }

    private func shouldResolveCatalogAlbum(serviceId: String) -> Bool {
        if let account = searchManager.linkedAccounts.first(where: { $0.serviceId == serviceId }),
           PlaybackSource.from(serviceName: account.displayName) == .appleMusic {
            return true
        }
        if let localSid = albumItem.serviceId,
           PlaybackSource.from(serviceName: SharedStorage.serviceNamesByLocalSid[String(localSid)]) == .appleMusic {
            return true
        }
        return false
    }

    private func accountIdFromURI(_ uri: String?) -> String? {
        guard let queryPart = uri?.split(separator: "?").last else { return nil }
        for param in queryPart.split(separator: "&") {
            let kv = param.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "sn" {
                return String(kv[1])
            }
        }
        return nil
    }

    private func preferredAlbumResource(in result: SonosCloudAPI.ServiceSearchResponse) -> SonosCloudAPI.CloudResource? {
        let albums = result.allResources.filter { $0.type == "ALBUM" }
        let targetTitle = normalizedCatalogText(albumItem.title)
        let targetArtist = normalizedCatalogText(albumItem.artist)
        let titleMatches = albums.filter { normalizedCatalogText($0.name ?? "") == targetTitle }

        if !targetArtist.isEmpty {
            let titleAndArtistMatches = titleMatches.filter {
                normalizedCatalogText($0.artists?.first?.name ?? "") == targetArtist
            }
            if let match = titleAndArtistMatches.first(where: { !isLibraryScopedId($0.id?.objectId) }) {
                return match
            }
            if let match = titleAndArtistMatches.first {
                return match
            }
        }

        return titleMatches.first { !isLibraryScopedId($0.id?.objectId) }
            ?? titleMatches.first
            ?? albums.first { !isLibraryScopedId($0.id?.objectId) }
            ?? albums.first
    }

    private func normalizedCatalogText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func isLibraryScopedId(_ id: String?) -> Bool {
        id?.lowercased().contains("library") == true
    }

    private func browseAlbumId(from rawId: String) -> String {
        let base = rawId.firstIndex(of: "#").map { String(rawId[..<$0]) } ?? rawId
        let parts = base.components(separatedBy: ":")
        guard let albumIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("album") == .orderedSame }),
              albumIndex < parts.index(before: parts.endIndex) else { return base }
        return parts[albumIndex...].joined(separator: ":")
    }

    // MARK: - Playback

    private func playAlbum() {
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
            await searchManager.playNow(item: albumItem, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    private func playAlbumShuffled() {
        guard playingItemId == nil else { return }
        playingItemId = "shuffle"

        Task {
            if let ip = manager.selectedSpeaker?.playbackIP {
                let current = try? await SonosAPI.getPlayMode(ip: ip)
                try? await SonosAPI.setPlayMode(ip: ip, shuffle: true,
                                                repeat: current?.repeat ?? .off)
            }
            await searchManager.playNow(item: albumItem, manager: manager)
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
                let ok = await searchManager.removeFromFavorites(item: albumItem, manager: manager)
                if ok { isFavorited = false }
                showToast(ok ? "Removed from Favorites" : "Failed to remove")
            } else {
                let ok = await searchManager.addToFavorites(item: albumItem, manager: manager)
                if ok { isFavorited = true }
                showToast(ok ? "Added to Favorites" : "Failed to add")
            }
        }
    }
}
