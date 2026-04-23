import SwiftUI

/// Detail view for a Sonos *system* playlist (`SQ:<n>`) — the local queues
/// created inside the Sonos app and exposed over UPnP. Sonos Cloud API has no
/// representation for these, so we enumerate tracks via `SonosAPI.browsePlaylistTracks`
/// directly and play individual items / the whole container using the
/// existing `SearchManager.playNow` paths.
struct SonosLocalPlaylistDetailView: View {
    let playlistItem: BrowseItem
    @Bindable var searchManager: SearchManager
    @Bindable var manager: SonosManager

    @State private var tracks: [BrowseItem] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var actionInFlight: String?
    @State private var playingItemId: String?
    @State private var toastMessage: String?
    @State private var isFavorited = false
    @State private var coverImage: UIImage?
    @State private var themeColor: Color?

    private var playlistTitle: String { playlistItem.title }

    /// Sonos system playlists usually ship without their own cover art, so
    /// we fall back to the first track's album art to match how Music apps
    /// display user-created playlists.
    private var coverURL: String? {
        if let url = playlistItem.albumArtURL, !url.isEmpty { return url }
        return tracks.first(where: { ($0.albumArtURL?.isEmpty == false) })?.albumArtURL
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
        .background { blurredBackground }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                playlistMenu
            }
        }
        .task { await loadTracks() }
        .task(id: coverURL) { await loadCoverImage() }
        .onAppear { isFavorited = searchManager.isFavorited(playlistItem) }
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
                toast(msg)
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var blurredBackground: some View {
        if let img = coverImage {
            ZStack {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80)
                    .scaleEffect(1.5)
                Color.black.opacity(0.55)
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

    // MARK: - Toolbar Menu

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
                            Image(systemName: "music.note.list")
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

                Text(countSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.horizontal)
        }
        .padding(.top, 20)
    }

    private var countSubtitle: String {
        if isLoading && tracks.isEmpty { return "Loading…" }
        let n = tracks.count
        return n == 1 ? "1 track" : "\(n) tracks"
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            actionButton(icon: "play.fill", label: "Play", id: "play-all") {
                playPlaylist(shuffle: false)
            }
            actionButton(icon: "shuffle", label: "Shuffle", id: "shuffle") {
                playPlaylist(shuffle: true)
            }
        }
        .padding(.horizontal)
    }

    private func actionButton(icon: String, label: String, id: String,
                              action: @escaping () -> Void) -> some View {
        let isActive = actionInFlight == id
        let isDisabled = actionInFlight != nil && !isActive

        return Button(action: action) {
            HStack(spacing: 6) {
                if isActive {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: icon).font(.subheadline.weight(.semibold))
                }
                Text(label).font(.subheadline.weight(.semibold))
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
        if isLoading && tracks.isEmpty {
            ProgressView()
                .padding(.top, 40)
        } else if let err = errorText {
            ContentUnavailableView("Failed to Load",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(err))
        } else if tracks.isEmpty {
            ContentUnavailableView("Empty Playlist",
                                   systemImage: "music.note.list",
                                   description: Text("This Sonos Playlist has no tracks yet."))
                .padding(.top, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { idx, track in
                    trackRow(track, index: idx + 1, isLast: idx == tracks.count - 1)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    private func trackRow(_ track: BrowseItem, index: Int, isLast: Bool) -> some View {
        let isPlaying = playingItemId == track.id
        let isDisabled = playingItemId != nil && !isPlaying

        return Button {
            playTrack(track)
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: track.albumArtURL ?? "")) { phase in
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
                    Text(track.title)
                        .font(.body)
                        .lineLimit(1)
                    if !track.artist.isEmpty || !track.album.isEmpty {
                        HStack(spacing: 4) {
                            if !track.artist.isEmpty { Text(track.artist) }
                            if !track.album.isEmpty && !track.artist.isEmpty { Text("·") }
                            if !track.album.isEmpty { Text(track.album) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }

                Spacer()

                if isPlaying {
                    ProgressView().controlSize(.small)
                } else {
                    Menu {
                        trackContextMenu(track)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                Divider().padding(.leading, 56)
            }
        }
    }

    @ViewBuilder
    private func trackContextMenu(_ track: BrowseItem) -> some View {
        let trackFavorited = searchManager.isFavorited(track)

        Button { playTrack(track) } label: {
            Label("Play Now", systemImage: "play.fill")
        }

        if track.uri != nil {
            Button {
                Task {
                    await searchManager.playNext(item: track, manager: manager)
                    showToast("Playing next")
                }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                Task {
                    await searchManager.addToQueue(item: track, manager: manager)
                    showToast("Added to queue")
                }
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }

            Divider()

            Button {
                Task {
                    if trackFavorited {
                        let ok = await searchManager.removeFromFavorites(item: track, manager: manager)
                        showToast(ok ? "Removed from Favorites" : "Failed to remove")
                    } else {
                        let ok = await searchManager.addToFavorites(item: track, manager: manager)
                        showToast(ok ? "Added to Favorites" : "Failed to add")
                    }
                }
            } label: {
                Label(trackFavorited ? "Remove from Sonos Favorites" : "Add to Sonos Favorites",
                      systemImage: trackFavorited ? "heart.slash" : "heart")
            }
        }
    }

    // MARK: - Toast

    private func toast(_ message: String) -> some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(radius: 4)
            .padding(.bottom, 80)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation { toastMessage = nil }
                }
            }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.25)) { toastMessage = message }
    }

    // MARK: - Data Loading

    private func loadTracks() async {
        guard tracks.isEmpty else { isLoading = false; return }
        guard let ip = manager.selectedSpeaker?.playbackIP else {
            errorText = "No speaker selected"
            isLoading = false
            return
        }

        do {
            // Sonos Playlists are rarely more than a few hundred tracks; pull
            // up to four pages of 100 to keep us bounded without needing true
            // incremental scrolling.
            let pageSize = 100
            var collected: [BrowseItem] = []
            for pageIndex in 0..<10 {
                try Task.checkCancellation()
                let page = try await SonosAPI.browsePlaylistTracks(
                    ip: ip, playlistId: playlistItem.id,
                    start: pageIndex * pageSize, count: pageSize)
                collected.append(contentsOf: page)
                if page.count < pageSize { break }
            }
            tracks = collected
            isLoading = false
        } catch is CancellationError {
            SonosLog.debug(.playlistDetail, "Local playlist load cancelled")
        } catch {
            SonosLog.error(.playlistDetail, "Local playlist load failed: \(error)")
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Playback

    private func playPlaylist(shuffle: Bool) {
        guard actionInFlight == nil else { return }
        actionInFlight = shuffle ? "shuffle" : "play-all"

        Task {
            if let ip = manager.selectedSpeaker?.playbackIP {
                let current = try? await SonosAPI.getPlayMode(ip: ip)
                try? await SonosAPI.setPlayMode(
                    ip: ip,
                    shuffle: shuffle,
                    repeat: current?.repeat ?? .off)
            }
            await searchManager.playNow(item: playlistItem, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { actionInFlight = nil }
        }
    }

    private func playTrack(_ track: BrowseItem) {
        guard playingItemId == nil else { return }
        playingItemId = track.id
        Task {
            await searchManager.playNow(item: track, manager: manager)
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
