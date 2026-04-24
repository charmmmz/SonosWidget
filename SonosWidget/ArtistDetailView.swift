import SwiftUI

struct ArtistDetailView: View {
    let artistItem: BrowseItem
    let searchManager: SearchManager
    let manager: SonosManager

    @State private var response: SonosCloudAPI.ArtistBrowseResponse?
    /// Discography assembled from search results when `browseArtist` is
    /// unsupported by the service (e.g. NetEase Cloud Music returns HTTP 500
    /// for the artists/{id}/browse endpoint). Used as a last-resort fallback
    /// so the artist page still shows something useful.
    @State private var fallbackAlbums: [BrowseItem] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var playingItemId: String?
    @State private var toastMessage: String?
    @State private var isFavorited = false
    @State private var headerImage: UIImage?
    @State private var themeColor: Color?

    private var artistName: String { response?.title ?? artistItem.title }
    private var headerImageURL: String? {
        response?.images?.tile1x1 ?? artistItem.albumArtURL
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                    .padding(.bottom, 8)
                albumsGrid
            }
        }
        .background { artistBackground }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                favoriteButton
            }
        }
        .task { await loadArtist() }
        .task(id: headerImageURL) { await loadHeaderImage() }
        .onAppear { isFavorited = searchManager.isFavorited(artistItem) }
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
                toast(msg)
            }
        }
    }

    // MARK: - Blurred Background

    @ViewBuilder
    private var artistBackground: some View {
        if let img = headerImage {
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
            Color(.systemGroupedBackground).ignoresSafeArea()
        }
    }

    private func loadHeaderImage() async {
        guard let urlStr = headerImageURL, let url = URL(string: urlStr) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let img = UIImage(data: data)
            headerImage = img
            if let color = img?.dominantColor() {
                themeColor = color
            }
        } catch {
            SonosLog.error(.artistDetail, "Header image load failed: \(error)")
        }
    }

    // MARK: - Favorite Toggle (Toolbar)

    private var favoriteButton: some View {
        Button {
            toggleFavorite()
        } label: {
            Image(systemName: isFavorited ? "heart.fill" : "heart")
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isFavorited ? .pink : .primary)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                artistAvatar
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 8)

                if let stationAction = response?.customActions?.first(where: { $0.action == "ACTION_PLAY_STATION" }) {
                    stationBadge(stationAction)
                        .offset(x: 6, y: 6)
                }
            }

            Text(artistName)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                // Without an explicit full-width frame the Text's frame is
                // only as wide as the text itself, so the outer VStack's
                // implicit centering aligns it against the widest sibling
                // (the 200pt avatar). Force the label to span the whole
                // width and centre within it — feels more balanced under
                // the circular avatar, especially on wider devices.
                .frame(maxWidth: .infinity, alignment: .center)

            // Unified streaming-service chip — same component the
            // now-playing view and widget use — instead of a plain
            // "Apple Music" / "Spotify" / "网易云音乐" text line. Falls
            // back silently to nothing if we can't map the provider
            // name to a known source.
            if let provider = response?.providerInfo?.name {
                let source = PlaybackSource.from(serviceName: provider)
                if source != .unknown {
                    SourceBadgeView(source: source, tintColor: nil)
                } else {
                    Text(provider)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var artistAvatar: some View {
        if let url = headerImageURL {
            AsyncImage(url: URL(string: url)) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Circle().fill(.quaternary)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
        } else {
            Circle().fill(.quaternary)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private func stationBadge(_ action: SonosCloudAPI.CustomAction) -> some View {
        let isActive = playingItemId == "station"

        return Button {
            startStation(action)
        } label: {
            ZStack {
                Circle()
                    .fill(themeColor ?? .white.opacity(0.2))
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)

                if isActive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .disabled(playingItemId != nil && !isActive)
    }

    // MARK: - Albums Grid

    @ViewBuilder
    private var albumsGrid: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 40)
        } else if let err = errorText {
            ContentUnavailableView("Failed to Load",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(err))
        } else if let sections = response?.sections?.items {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    albumSection(section)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        } else if !fallbackAlbums.isEmpty {
            // Search-derived discography (used when service doesn't support
            // dedicated artist browse, e.g. NetEase Cloud Music).
            fallbackAlbumsSection
                .padding(.horizontal)
                .padding(.bottom, 32)
        }
    }

    private var fallbackAlbumsSection: some View {
        let columns = [GridItem(.flexible(), spacing: 12),
                       GridItem(.flexible(), spacing: 12)]
        return VStack(alignment: .leading, spacing: 12) {
            Text("Albums")
                .font(.headline)
                .padding(.top, 8)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(fallbackAlbums) { album in
                    fallbackAlbumCard(album)
                }
            }
        }
    }

    private func fallbackAlbumCard(_ album: BrowseItem) -> some View {
        NavigationLink {
            AlbumDetailView(albumItem: album,
                            searchManager: searchManager,
                            manager: manager)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                squareAlbumArt(url: album.albumArtURL)

                Text(album.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
    }

    private func albumSection(_ section: SonosCloudAPI.ArtistSection) -> some View {
        let items = section.items ?? []
        let columns = [GridItem(.flexible(), spacing: 12),
                       GridItem(.flexible(), spacing: 12)]

        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, sectionItem in
                albumCard(sectionItem)
            }
        }
    }

    private func albumCard(_ item: SonosCloudAPI.ArtistSectionItem) -> some View {
        NavigationLink {
            AlbumDetailView(albumItem: browseItem(from: item),
                            searchManager: searchManager,
                            manager: manager)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                squareAlbumArt(url: item.images?.tile1x1)

                Text(item.title ?? "")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Always-1:1 album thumbnail. Uses `Color.clear` as the aspect-ratio
    /// anchor and overlays the AsyncImage on top, so cells stay perfectly
    /// aligned even when the service returns covers with non-square
    /// aspect ratios (common on NetEase / user-uploaded art). Non-square
    /// covers get centre-cropped instead of reshaping the grid.
    private func squareAlbumArt(url: String?) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: URL(string: url ?? "")) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay {
                                Image(systemName: "opticaldisc")
                                    .font(.title)
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func browseItem(from item: SonosCloudAPI.ArtistSectionItem) -> BrowseItem {
        let objectId = item.resource?.id?.objectId ?? ""
        let title = item.title ?? ""
        guard let serviceId = item.resource?.id?.serviceId,
              let accountId = item.resource?.id?.accountId else {
            // No cloud account → return a typeless placeholder so the row still
            // shows up; tapping it will fail playback but not crash.
            return BrowseItem(id: objectId, title: title, artist: artistName,
                              album: title, albumArtURL: item.images?.tile1x1,
                              isContainer: true)
        }
        return searchManager.makeAlbumItem(
            objectId: objectId, title: title, artist: artistName,
            artURL: item.images?.tile1x1,
            cloudServiceId: serviceId, accountId: accountId)
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

    private func loadArtist() async {
        guard response == nil else { isLoading = false; return }
        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            errorText = "Not logged in to Sonos Cloud"
            isLoading = false
            return
        }

        let serviceIdStr: String? = {
            if let sid = artistItem.serviceId {
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

        SonosLog.debug(.artistDetail, "Loading artist: id=\(artistItem.id), serviceId=\(serviceId), accountId=\(accountId)")

        do {
            response = try await SonosCloudAPI.browseArtist(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: accountId,
                artistId: artistItem.id)
            isLoading = false
        } catch is CancellationError {
            SonosLog.debug(.artistDetail, "Load cancelled (tab switch)")
        } catch {
            SonosLog.info(.artistDetail, "Browse failed (\(error)), trying search fallback for '\(artistItem.title)'")
            await searchFallback(token: token, householdId: householdId,
                                 serviceId: serviceId, accountId: accountId)
        }
    }

    private func searchFallback(token: String, householdId: String,
                                serviceId: String, accountId: String) async {
        do {
            let searchResult = try await SonosCloudAPI.searchService(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: accountId,
                term: artistItem.title, count: 50)

            let artistResource = searchResult.allResources
                .first { $0.type == "ARTIST" && $0.name?.lowercased() == artistItem.title.lowercased() }
                ?? searchResult.allResources.first { $0.type == "ARTIST" }

            // Collect albums up-front so we can use them as a last-resort
            // fallback if the second browseArtist call also fails.
            let albumsByArtist = albumsForArtist(in: searchResult,
                                                 serviceId: serviceId,
                                                 accountId: accountId)

            guard let correctId = artistResource?.id?.objectId else {
                useDiscographyFallback(albumsByArtist)
                return
            }

            SonosLog.debug(.artistDetail, "Search fallback: found artistId=\(correctId)")
            do {
                response = try await SonosCloudAPI.browseArtist(
                    token: token, householdId: householdId,
                    serviceId: serviceId, accountId: accountId,
                    artistId: correctId)
                isLoading = false
            } catch is CancellationError {
                SonosLog.debug(.artistDetail, "Search fallback cancelled (tab switch)")
            } catch {
                // browseArtist still 500s — fall back to a search-derived
                // discography (mostly happens for NetEase Cloud Music).
                SonosLog.info(.artistDetail, "browseArtist still failed (\(error)); using search-derived discography")
                useDiscographyFallback(albumsByArtist)
            }
        } catch is CancellationError {
            SonosLog.debug(.artistDetail, "Search fallback cancelled (tab switch)")
        } catch {
            SonosLog.error(.artistDetail, "Search fallback failed: \(error)")
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    /// Filter ALBUM resources from a search result down to those whose
    /// primary artist name matches `artistItem.title` (case-insensitively).
    /// Falls back to the full ALBUM list if no name match — better to show
    /// loosely-related albums than nothing.
    private func albumsForArtist(in result: SonosCloudAPI.ServiceSearchResponse,
                                 serviceId: String, accountId: String) -> [BrowseItem] {
        let lowerName = artistItem.title.lowercased()
        let allAlbums = result.allResources.filter { $0.type == "ALBUM" }
        let filtered = allAlbums.filter { res in
            (res.artists?.first?.name ?? "").lowercased() == lowerName
        }
        let chosen = filtered.isEmpty ? allAlbums : filtered

        return chosen.compactMap { res -> BrowseItem? in
            guard let objectId = res.id?.objectId else { return nil }
            let artURL = res.images?.first?.url
                ?? res.container?.images?.first?.url
            return searchManager.makeAlbumItem(
                objectId: objectId,
                title: res.name ?? "",
                artist: res.artists?.first?.name ?? artistItem.title,
                artURL: artURL,
                cloudServiceId: serviceId,
                accountId: accountId)
        }
    }

    private func useDiscographyFallback(_ albums: [BrowseItem]) {
        if albums.isEmpty {
            errorText = "No albums found for this artist"
        } else {
            fallbackAlbums = albums
            errorText = nil
        }
        isLoading = false
    }

    // MARK: - Playback

    private func startStation(_ action: SonosCloudAPI.CustomAction) {
        guard playingItemId == nil else { return }
        playingItemId = "station"

        // Delegate to SearchManager.startStation which resolves the radio:ra.{id}
        // URI and calls playRadioStation — that path embeds <upnp:albumArtURI>
        // in the station DIDL so the mini-player / now-playing screen picks up
        // the cover. Going through `playNow` instead produces the minimal
        // PROGRAM metadata (no album art) and leaves the mini-player blank.
        var artistForStation = artistItem
        if let url = headerImageURL { artistForStation.albumArtURL = url }

        Task {
            await searchManager.startStation(item: artistForStation, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    private func toggleFavorite() {
        Task {
            if isFavorited {
                let ok = await searchManager.removeFromFavorites(item: artistItem, manager: manager)
                if ok { isFavorited = false }
                showToast(ok ? "Removed from Favorites" : "Failed to remove")
            } else {
                // Prefer the loaded artist header image (high-res from Apple
                // Music) over whatever low-res or nil albumArtURL was passed
                // in via navigation — this is the URL that ends up in
                // <upnp:albumArtURI> and drives the favorite's cover art.
                var itemForFav = artistItem
                if let url = headerImageURL { itemForFav.albumArtURL = url }
                let ok = await searchManager.addToFavorites(item: itemForFav, manager: manager)
                if ok { isFavorited = true }
                showToast(ok ? "Added to Favorites" : "Failed to add")
            }
        }
    }
}
