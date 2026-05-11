import SwiftUI
import UIKit

struct SearchView: View {
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager
    @State private var searchText = ""
    /// nil = "All", otherwise the serviceId string
    @State private var selectedServiceTab: String?
    /// Tracks which item is currently being loaded for playback
    @State private var playingItemId: String?
    @State private var isReconnectingSonos = false
    @Bindable private var auth = SonosAuth.shared

    var body: some View {
        NavigationStack {
            Group {
                if !manager.isConfigured {
                    ContentUnavailableView("No Speaker Connected",
                                           systemImage: "hifispeaker.slash",
                                           description: Text("Connect to a Sonos speaker in the Player tab first."))
                } else if searchText.isEmpty {
                    browseContent
                } else {
                    searchResultsContent
                }
            }
            .background {
                ZStack {
                    if let image = manager.albumArtImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 80)
                            .scaleEffect(1.5)
                        Color.black.opacity(0.6)
                    } else {
                        Color.black
                    }
                }
                .ignoresSafeArea()
            }
            // Hide the "Search" navigation title entirely (both the large and
            // inline forms). The `.searchable` field is already self-
            // explanatory; a redundant title just costs vertical space.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .scrollContentBackground(.hidden)
            .preferredColorScheme(.dark)
            .searchable(text: $searchText, prompt: "Search songs, artists, albums…")
            .onSubmit(of: .search) {
                // Preserve the currently-selected service tab across searches
                // so the user doesn't get yanked back to "All" every time they
                // retype a query. The onChange(lastSearchQuery) below takes
                // care of re-fetching the tab's results for the new query.
                searchManager.search(query: searchText)
            }
            .onChange(of: searchManager.lastSearchQuery) { _, _ in
                // search() clears serviceDetailResults before fetching; if
                // a service tab is selected we proactively repopulate it so
                // switching back doesn't require a second tap.
                if let sid = selectedServiceTab {
                    Task { await searchManager.loadServiceDetail(serviceId: sid) }
                }
            }
            .onAppear {
                searchManager.configure(speakerIP: manager.selectedSpeaker?.playbackIP)
                Task {
                    async let browse: () = loadBrowseForCurrentBackend()
                    async let probe: () = searchManager.probeLinkedServices()
                    _ = await (browse, probe)
                }
            }
            .onChange(of: manager.selectedSpeaker?.ipAddress) { _, _ in
                searchManager.configure(speakerIP: manager.selectedSpeaker?.playbackIP)
                searchManager.resetProbe()
                Task { await loadBrowseForCurrentBackend() }
            }
            .onChange(of: manager.transportBackend) { _, _ in
                // Flipping between LAN and Cloud changes where Sonos Favorites
                // come from. Re-load so the list matches the active backend.
                Task { await loadBrowseForCurrentBackend() }
            }
            .onChange(of: manager.currentCloudGroupId) { _, gid in
                // Cloud group id resolves asynchronously after the backend
                // flips to .cloud — if the Browse tab was already on screen,
                // the initial `loadBrowseForCurrentBackend()` call took the
                // LAN fallback with an empty IP and silently left the page
                // blank. Re-fire as soon as the id is ready.
                if gid != nil { Task { await loadBrowseForCurrentBackend() } }
            }
            .confirmationDialog("Start Station",
                                isPresented: $searchManager.showStationPicker,
                                titleVisibility: .visible) {
                ForEach(searchManager.stationOptions) { option in
                    Button(option.name) {
                        guard let mgr = searchManager.pendingStationManager else { return }
                        Task { await searchManager.playStationOption(option, manager: mgr) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func playItem(_ item: BrowseItem) {
        guard playingItemId == nil else { return }
        playingItemId = item.id
        Task {
            await searchManager.playNow(item: item, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    private var sonosCloudErrorContent: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Sonos Cloud",
                systemImage: "exclamationmark.triangle",
                description: Text(searchManager.errorMessage ?? "")
            )
            if auth.sessionState == .expired || auth.sessionState == .disconnected {
                Button {
                    reconnectSonos()
                } label: {
                    HStack(spacing: 8) {
                        if isReconnectingSonos {
                            ProgressView().controlSize(.small)
                        }
                        Text(isReconnectingSonos ? "Reconnecting..." : sonosCloudConnectTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isReconnectingSonos)
            }
        }
        .padding(.horizontal)
    }

    private var sonosCloudConnectTitle: String {
        auth.sessionState == .expired ? "Reconnect" : "Connect"
    }

    private func reconnectSonos() {
        isReconnectingSonos = true
        Task {
            let window = await UIApplication.shared.sonosPresentationWindow
            let success = await auth.reconnect(from: window)
            if success {
                searchManager.errorMessage = nil
                await manager.resolveCloudGroupId()
                await manager.refreshState()
                await searchManager.forceReprobe()
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await loadBrowseForCurrentBackend()
                } else {
                    searchManager.search(query: searchText)
                }
            } else if let authError = auth.lastErrorMessage {
                searchManager.errorMessage = authError
            }
            isReconnectingSonos = false
        }
    }

    /// Dispatches Browse-tab content loading based on whether we're LAN or
    /// remote. In remote mode we hand SearchManager a cloud context so it can
    /// source Sonos Favorites from the Control API's `listFavorites` endpoint.
    ///
    /// Important: never fall through to the LAN path while we're in cloud
    /// mode — `SonosAPI.browseFavorites(ip: "")` would just time out and
    /// leave the page blank. When cloud prerequisites (token, household id,
    /// group id) aren't ready yet, we bail and rely on the `onChange`
    /// handlers above to re-fire once they resolve.
    private func loadBrowseForCurrentBackend() async {
        switch manager.transportBackend {
        case .cloud:
            guard let token = await SonosAuth.shared.validAccessToken(),
                  let householdId = SonosAuth.shared.householdId else {
                searchManager.errorMessage = SonosCloudError.unauthorized.localizedDescription
                return
            }
            // Group id usually resolves shortly after the backend flips —
            // kick a resolve if we don't have it yet so the Browse tab
            // doesn't sit empty waiting for the next poll.
            if manager.currentCloudGroupId == nil {
                await manager.resolveCloudGroupId()
            }
            guard let gid = manager.currentCloudGroupId else { return }
            await searchManager.loadBrowseContent(
                cloudMode: true,
                cloudContext: .init(token: token, householdId: householdId, groupId: gid))
        case .lan:
            await searchManager.loadBrowseContent()
        case .unknown:
            // Backend probe hasn't finished yet — `onChange(transportBackend)`
            // re-triggers this func once it flips to .lan or .cloud.
            return
        }
    }

    private func startStationForItem(_ item: BrowseItem) {
        guard playingItemId == nil else { return }
        playingItemId = item.id
        Task {
            await searchManager.startStation(item: item, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    // MARK: - Browse Content

    private var browseContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if searchManager.isLoadingBrowse {
                    HStack {
                        Spacer()
                        ProgressView("Loading…")
                        Spacer()
                    }
                    .padding(.top, 40)
                } else {
                    if !searchManager.recentlyPlayed.isEmpty {
                        recentlyPlayedSection
                    }

                    let grouped = searchManager.groupedFavorites
                    if !grouped.isEmpty {
                        Text("Sonos Favorites")
                            .font(.title.bold())
                            .padding(.horizontal)

                        ForEach(grouped, id: \.category) { group in
                            favoriteSection(category: group.category, items: group.items)
                        }
                    }

                    if !searchManager.playlists.isEmpty {
                        sonosPlaylistsSection
                    }

                    if !searchManager.radio.isEmpty {
                        browseSection(title: "Radio Stations", items: searchManager.radio, horizontal: true)
                    }

                    if searchManager.errorMessage?.isEmpty == false {
                        sonosCloudErrorContent
                            .padding(.top, 20)
                    } else if searchManager.favorites.isEmpty && searchManager.playlists.isEmpty && searchManager.radio.isEmpty {
                        ContentUnavailableView("No Content",
                                               systemImage: "music.note.list",
                                               description: Text("Add favorites, playlists, or radio stations in the Sonos app."))
                        .padding(.top, 20)
                    }
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: - Recently Played Section

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played")
                .font(.title3.bold())
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(searchManager.recentlyPlayed) { item in
                        // Categorization uses the item's own metadata (cloudType
                        // / URI), same logic as favorites — so tapping "Daniel
                        // Caesar" opens the artist page, tapping an album opens
                        // its detail page, etc.
                        browseCard(item, category: item.favoriteCategory)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Favorite Grouped Section

    @ViewBuilder
    private func favoriteSection(category: BrowseItem.FavoriteCategory, items: [BrowseItem]) -> some View {
        // Songs render as a vertical list (tall-thumbnail + title + artist
        // row), since a large favorites library tends to produce dozens of
        // song entries that are awkward in a horizontal scroll. Other
        // categories (Playlists, Albums, Artists, Stations, Collections)
        // keep the horizontal card layout.
        let useListLayout = category == .song
        let previewCount = useListLayout ? 4 : 5
        let hasMore = items.count > previewCount
        let displayItems = hasMore ? Array(items.prefix(previewCount)) : items

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(category.rawValue)
                    .font(.title3.bold())
                Spacer()
                if hasMore {
                    NavigationLink {
                        FavoriteCategoryDetailView(
                            category: category,
                            items: items,
                            searchManager: searchManager,
                            manager: manager
                        )
                    } label: {
                        Text("View All")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)

            if useListLayout {
                LazyVStack(spacing: 0) {
                    ForEach(displayItems) { item in
                        browseRow(item)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(displayItems) { item in
                            browseCard(item, category: category)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Generic Section (for Sonos Playlists / Radio)

    @ViewBuilder
    private func browseSection(title: String, items: [BrowseItem], horizontal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal)

            if horizontal {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(items) { item in
                            browseCard(item, category: nil)
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        browseRow(item)
                    }
                }
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func browseCard(_ item: BrowseItem, category: BrowseItem.FavoriteCategory?) -> some View {
        let cat = category ?? item.favoriteCategory

        if cat == .album, let nav = albumNavItem(for: item) {
            NavigationLink {
                AlbumDetailView(albumItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                browseCardContent(item, category: category)
            }
            .buttonStyle(.plain)
            .contextMenu { itemContextMenu(item) }
        } else if cat == .artist {
            let nav = artistNavItem(for: item) ?? item
            NavigationLink {
                ArtistDetailView(artistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                browseCardContent(item, category: category)
            }
            .buttonStyle(.plain)
            .contextMenu { itemContextMenu(item) }
        } else if cat == .playlist, let nav = playlistNavItem(for: item) {
            NavigationLink {
                PlaylistDetailView(playlistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                browseCardContent(item, category: category)
            }
            .buttonStyle(.plain)
            .contextMenu { itemContextMenu(item) }
        } else if cat == .collection, let nav = collectionNavItem(for: item) {
            NavigationLink {
                PlaylistDetailView(playlistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                browseCardContent(item, category: category)
            }
            .buttonStyle(.plain)
            .contextMenu { itemContextMenu(item) }
        } else {
            let isLoading = playingItemId == item.id
            let isDisabled = playingItemId != nil && !isLoading

            Button { playItem(item) } label: {
                browseCardContent(item, category: category)
                    .opacity(isDisabled ? 0.4 : 1)
                    .overlay(alignment: .top) {
                        let cr: CGFloat = cat == .artist ? 70 : 10
                        if isLoading {
                            RoundedRectangle(cornerRadius: cr)
                                .fill(.ultraThinMaterial.opacity(0.85))
                                .frame(width: 140, height: 140)
                                .overlay {
                                    ProgressView()
                                        .tint(.white)
                                        .controlSize(.regular)
                                }
                                .transition(.opacity)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .animation(.easeInOut(duration: 0.2), value: playingItemId)
            .contextMenu { itemContextMenu(item) }
        }
    }

    private func browseCardContent(_ item: BrowseItem, category: BrowseItem.FavoriteCategory?) -> some View {
        let cat = category ?? item.favoriteCategory
        let cornerRadius: CGFloat = cat == .artist ? 70 : 10

        return VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: item.albumArtURL ?? "")) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            Image(systemName: placeholderIcon(for: item, category: category))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            Text(item.title)
                .font(.caption.weight(.medium))
                // Single-line with trailing ellipsis keeps the card heights
                // uniform across the horizontal scroll — two-line wrapping
                // looked ragged when some titles fit and others didn't.
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)

            categoryLabel(for: item, category: category)
        }
        .frame(width: 140)
    }

    /// Build a BrowseItem suitable for AlbumDetailView from a Favorite.
    private func albumNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "ALBUM" {
            // Cloud `listFavorites` rows and shortcut favorites can omit a top-level
            // playable URI; resolve the same way as add-to-favorites.
            return searchManager.browseItemWithResolvedFavoriteURI(item) ?? item
        }
        guard let ids = searchManager.parseCloudIds(from: item) else { return nil }
        var nav = searchManager.makeAlbumItem(
            objectId: ids.objectId, title: item.title, artist: item.artist,
            artURL: item.albumArtURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId)
        // Preserve the Sonos browse URI as a safety net (it's known to work for
        // this specific favorite); fall back to the factory-built URI if absent.
        if let original = item.uri { nav.uri = original }
        return nav
    }

    /// Build a BrowseItem suitable for ArtistDetailView from a Favorite.
    private func artistNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "ARTIST" {
            return searchManager.browseItemWithResolvedFavoriteURI(item) ?? item
        }
        guard let ids = searchManager.parseCloudIds(from: item) else {
            SonosLog.debug(.navItem, "artistNavItem parseCloudIds failed for '\(item.title)' uri=\(item.uri ?? "nil") resMD=\(item.resMD?.prefix(200) ?? "nil")")
            return nil
        }
        return searchManager.makeArtistItem(
            objectId: ids.objectId, name: item.title, artURL: item.albumArtURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId)
    }

    private func playlistNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "PLAYLIST" {
            return searchManager.browseItemWithResolvedFavoriteURI(item) ?? item
        }
        guard let ids = searchManager.parseCloudIds(from: item) else { return nil }
        var nav = searchManager.makePlaylistItem(
            objectId: ids.objectId, title: item.title, artist: item.artist,
            artURL: item.albumArtURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId)
        if let original = item.uri { nav.uri = original }
        return nav
    }

    private func collectionNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "COLLECTION" { return item }
        if let ids = searchManager.parseCloudIds(from: item) {
            // COLLECTION is a generic library folder; we don't have a dedicated
            // factory because there's no canonical URI scheme — preserve the
            // existing browse URI verbatim and just normalize the type fields.
            return BrowseItem(
                id: ids.objectId, title: item.title, artist: item.artist,
                album: "", albumArtURL: item.albumArtURL,
                uri: item.uri, isContainer: true,
                serviceId: searchManager.localSid(forCloudServiceId: ids.cloudServiceId),
                cloudType: "COLLECTION")
        }
        let sources = [item.uri, item.resMD, item.metaXML].compactMap { $0 }
        for src in sources where src.contains("libraryfolder") {
            if let range = src.range(of: "libraryfolder[^\"&<\\s]*", options: .regularExpression) {
                let objectId = String(src[range])
                return BrowseItem(
                    id: objectId, title: item.title, artist: item.artist,
                    album: "", albumArtURL: item.albumArtURL,
                    uri: item.uri, isContainer: true,
                    serviceId: item.serviceId,
                    cloudType: "COLLECTION")
            }
        }
        return nil
    }

    @ViewBuilder
    private func categoryLabel(for item: BrowseItem, category: BrowseItem.FavoriteCategory?) -> some View {
        let cat = category ?? item.favoriteCategory
        // Keep the subtitle to just the category name ("Album" / "Playlist" /
        // "Artist" / …) — no artist prefix. Matches Apple Music's home grid
        // and avoids the redundancy of "Yoga Lin · Album" beneath an album
        // whose title already carries the artist context (e.g. in Recently
        // Played). The artist name is still visible on detail pages and in
        // the vertical track rows where it's actually informational.
        let subtitle: String = {
            switch cat {
            case .playlist:   return "Playlist"
            case .album:      return "Album"
            case .song:       return "Song"
            case .station:    return "Station"
            case .artist:     return "Artist"
            case .collection: return "Collection"
            }
        }()

        if !subtitle.isEmpty {
            HStack(spacing: 4) {
                if cat == .station || cat == .playlist || cat == .album
                    || cat == .collection || cat == .song || cat == .artist {
                    FavoritesStreamingGlyph(
                        cloudServiceId: searchManager.cloudServiceId(forFavorite: item),
                        displayNameHint: searchManager.serviceDisplayHint(forFavorite: item),
                        size: 10
                    )
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func placeholderIcon(for item: BrowseItem, category: BrowseItem.FavoriteCategory?) -> String {
        let cat = category ?? item.favoriteCategory
        switch cat {
        case .playlist: return "music.note.list"
        case .album: return "opticaldisc"
        case .song: return "music.note"
        case .station: return "antenna.radiowaves.left.and.right"
        case .artist: return "person.fill"
        case .collection: return "folder.fill"
        }
    }

    private func browseRow(_ item: BrowseItem) -> some View {
        let isLoading = playingItemId == item.id
        let isDisabled = playingItemId != nil && !isLoading

        return Button {
            playItem(item)
        } label: {
            browseRowLabel(item, isLoading: isLoading, isDisabled: isDisabled)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(.easeInOut(duration: 0.2), value: playingItemId)
        .contextMenu { itemContextMenu(item) }
    }

    /// The visual content of a browse row, factored out so it can sit inside
    /// either a `Button` (tap-to-play: songs) or a `NavigationLink`
    /// (tap-to-open: Sonos Playlists) without duplicating layout.
    ///
    /// Songs (non-containers) render an `ellipsis` menu on the right that
    /// surfaces Play Next / Add to Queue / Favorite from `itemContextMenu`;
    /// containers keep the simpler `chevron.right` affordance.
    @ViewBuilder
    private func browseRowLabel(_ item: BrowseItem, isLoading: Bool, isDisabled: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                AsyncImage(url: URL(string: item.albumArtURL ?? "")) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay {
                                Image(systemName: item.isContainer ? "music.note.list" : "music.note")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if isLoading {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.ultraThinMaterial.opacity(0.85))
                        .frame(width: 48, height: 48)
                        .overlay {
                            ProgressView()
                                .tint(.white)
                                .controlSize(.small)
                        }
                        .transition(.opacity)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(1)
                if !item.artist.isEmpty {
                    Text(item.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .tint(.secondary)
                    .controlSize(.small)
            } else if item.isContainer {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Menu {
                    itemContextMenu(item)
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
        .padding(.horizontal)
        .padding(.vertical, 8)
        // Without this, SwiftUI's default hit-test shape for an HStack with
        // a `Spacer()` skips the empty gap in the middle — so taps landing
        // between the thumbnail and the trailing chevron/ellipsis fall
        // through. Forcing a rect makes the whole row selectable the way
        // List rows behave.
        .contentShape(Rectangle())
        .opacity(isDisabled ? 0.4 : 1)
    }

    // MARK: - Sonos Playlists Section

    /// Sonos system playlists (`SQ:<n>`) are local to the household and have
    /// no Cloud API representation, so tapping them opens a dedicated UPnP
    /// detail view instead of going through `PlaylistDetailView` (which is
    /// cloud-only). Tap-to-play is replaced by tap-to-open-detail so users
    /// can preview and pick individual tracks, matching the rest of the app.
    @ViewBuilder
    private var sonosPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sonos Playlists")
                .font(.title3.bold())
                .padding(.horizontal)

            LazyVStack(spacing: 0) {
                ForEach(searchManager.playlists) { item in
                    NavigationLink {
                        SonosLocalPlaylistDetailView(
                            playlistItem: item,
                            searchManager: searchManager,
                            manager: manager
                        )
                    } label: {
                        browseRowLabel(item, isLoading: false, isDisabled: false)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { itemContextMenu(item) }
                }
            }
        }
    }

    // MARK: - Search Results (Tabbed)

    private var searchResultsContent: some View {
        Group {
            if searchManager.isSearching && searchManager.searchResults.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("Searching…")
                    Spacer()
                }
            } else if searchManager.errorMessage?.isEmpty == false {
                sonosCloudErrorContent
            } else if searchManager.hasSearched && searchManager.searchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if searchManager.searchResults.isEmpty {
                Color.clear
            } else {
                VStack(spacing: 0) {
                    serviceTabBar
                    Divider().opacity(0.3)
                    ScrollView {
                        groupedResultsForSelectedTab
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    // MARK: Service Tab Bar

    private var serviceTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                serviceTabChip(id: nil, label: "All")
                ForEach(searchManager.searchResults) { group in
                    serviceTabChip(id: group.id, label: group.serviceName)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func serviceTabChip(id: String?, label: String) -> some View {
        let isSelected = selectedServiceTab == id
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedServiceTab = id }
            if let id { Task { await searchManager.loadServiceDetail(serviceId: id) } }
        } label: {
            HStack(spacing: 6) {
                if let id {
                    CloudServiceBrandMark(
                        cloudServiceId: id,
                        displayNameHint: label,
                        dimension: 14,
                        symbolUsesTitle3: false,
                        lightChromeBackdrop: isSelected
                    )
                }
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color.white : Color.white.opacity(0.1))
            .foregroundStyle(isSelected ? .black : .white)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Grouped Results

    private enum ResultCategory: String, CaseIterable {
        case artist = "Artists"
        case track = "Songs"
        case album = "Albums"
        case playlist = "Playlists"
        case program = "Stations"
    }

    private func categoryFor(_ item: BrowseItem) -> ResultCategory {
        switch item.cloudType {
        case "ARTIST": return .artist
        case "TRACK": return .track
        case "ALBUM": return .album
        case "PLAYLIST": return .playlist
        case "PROGRAM": return .program
        default: return .track
        }
    }

    /// Items for the currently selected tab, grouped by type.
    private var groupedResultsForSelectedTab: some View {
        let items: [BrowseItem] = {
            if let sid = selectedServiceTab {
                if let detail = searchManager.serviceDetailResults[sid] {
                    return detail.items
                }
                return searchManager.searchResults.first { $0.id == sid }?.items ?? []
            }
            return searchManager.searchResults.flatMap { $0.items }
        }()

        let grouped = Dictionary(grouping: items) { categoryFor($0) }

        return VStack(alignment: .leading, spacing: 24) {
            if selectedServiceTab == nil && searchManager.searchResults.count > 1 {
                ForEach(searchManager.searchResults) { group in
                    allTabServiceSection(group)
                }
            } else if let sid = selectedServiceTab, searchManager.isLoadingServiceDetail,
                      searchManager.serviceDetailResults[sid] == nil {
                HStack {
                    Spacer()
                    ProgressView("Loading full results…")
                    Spacer()
                }
                .padding(.top, 40)
            } else {
                ForEach(ResultCategory.allCases, id: \.self) { category in
                    if let categoryItems = grouped[category], !categoryItems.isEmpty {
                        resultCategorySection(category: category, items: categoryItems)
                    }
                }
            }
        }
    }

    /// "All" tab: a section for each service with a header, showing grouped results inside.
    @ViewBuilder
    private func allTabServiceSection(_ group: SearchManager.ServiceSearchResult) -> some View {
        let grouped = Dictionary(grouping: group.items) { categoryFor($0) }

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                CloudServiceBrandMark(
                    cloudServiceId: group.id,
                    displayNameHint: group.serviceName,
                    dimension: 26,
                    symbolUsesTitle3: true
                )
                    .foregroundStyle(.secondary)
                Text(group.serviceName)
                    .font(.title2.bold())
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { selectedServiceTab = group.id }
                Task { await searchManager.loadServiceDetail(serviceId: group.id) }
            }

            ForEach(ResultCategory.allCases, id: \.self) { category in
                if let categoryItems = grouped[category], !categoryItems.isEmpty {
                    resultCategorySection(category: category,
                                          items: Array(categoryItems.prefix(category == .artist ? 10 : 5)))
                }
            }
        }
    }

    @ViewBuilder
    private func resultCategorySection(category: ResultCategory, items: [BrowseItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(category.rawValue)
                .font(.title3.bold())
                .padding(.horizontal)

            switch category {
            case .artist:
                artistHorizontalScroll(items: items)
            case .track, .program:
                songList(items: items)
            case .album, .playlist:
                albumHorizontalScroll(items: items)
            }
        }
    }

    // MARK: Artist Horizontal Scroll (circular images)

    private func artistHorizontalScroll(items: [BrowseItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(items) { item in
                    NavigationLink {
                        ArtistDetailView(artistItem: item,
                                         searchManager: searchManager,
                                         manager: manager)
                    } label: {
                        VStack(spacing: 8) {
                            AsyncImage(url: URL(string: item.albumArtURL ?? "")) { phase in
                                if let img = phase.image {
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Circle().fill(.quaternary)
                                        .overlay {
                                            Image(systemName: "person.fill")
                                                .foregroundStyle(.tertiary)
                                        }
                                }
                            }
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())

                            Text(item.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: 120)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { itemContextMenu(item) }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: Song List (rows)

    private func songList(items: [BrowseItem]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                let isLoading = playingItemId == item.id
                let isDisabled = playingItemId != nil && !isLoading

                Button {
                    playItem(item)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            AsyncImage(url: URL(string: item.albumArtURL ?? "")) { phase in
                                if let img = phase.image {
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle().fill(.quaternary)
                                        .overlay {
                                            Image(systemName: item.cloudType == "PROGRAM"
                                                  ? "antenna.radiowaves.left.and.right"
                                                  : "music.note")
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                }
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                            if isLoading {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.ultraThinMaterial.opacity(0.85))
                                    .frame(width: 48, height: 48)
                                    .overlay {
                                        ProgressView()
                                            .tint(.white)
                                            .controlSize(.small)
                                    }
                                    .transition(.opacity)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                if item.cloudType == "PROGRAM" {
                                    Text("Station")
                                } else {
                                    if !item.artist.isEmpty { Text(item.artist) }
                                    if !item.album.isEmpty { Text("· \(item.album)") }
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }

                        Spacer()

                        if isLoading {
                            ProgressView()
                                .tint(.secondary)
                                .controlSize(.small)
                        } else {
                            // Tap the ellipsis to open the same action list
                            // a long-press already shows — Play Next / Add to
                            // Queue / Add to Sonos Favorites, etc. Wrapped in
                            // a Menu so tap + long-press both work without
                            // hijacking the outer Button's tap-to-play.
                            Menu {
                                itemContextMenu(item)
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
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .opacity(isDisabled ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .animation(.easeInOut(duration: 0.2), value: playingItemId)
                .contextMenu { itemContextMenu(item) }
            }
        }
    }

    // MARK: Album / Playlist Horizontal Scroll

    private func albumHorizontalScroll(items: [BrowseItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(items) { item in
                    if item.cloudType == "ALBUM" {
                        NavigationLink {
                            AlbumDetailView(albumItem: item,
                                            searchManager: searchManager,
                                            manager: manager)
                        } label: {
                            albumScrollCard(item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { itemContextMenu(item) }
                    } else if item.cloudType == "PLAYLIST" {
                        NavigationLink {
                            PlaylistDetailView(playlistItem: item,
                                               searchManager: searchManager,
                                               manager: manager)
                        } label: {
                            albumScrollCard(item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { itemContextMenu(item) }
                    } else {
                        let isLoading = playingItemId == item.id
                        let isDisabled = playingItemId != nil && !isLoading

                        Button { playItem(item) } label: {
                            albumScrollCard(item)
                                .opacity(isDisabled ? 0.4 : 1)
                                .overlay {
                                    if isLoading {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(.ultraThinMaterial.opacity(0.85))
                                            .frame(width: 140, height: 140)
                                            .overlay {
                                                ProgressView()
                                                    .tint(.white)
                                                    .controlSize(.regular)
                                            }
                                            .transition(.opacity)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDisabled)
                        .animation(.easeInOut(duration: 0.2), value: playingItemId)
                        .contextMenu { itemContextMenu(item) }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func albumScrollCard(_ item: BrowseItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: item.albumArtURL ?? "")) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            Image(systemName: item.cloudType == "PLAYLIST"
                                  ? "music.note.list" : "opticaldisc")
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(item.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            if !item.artist.isEmpty {
                Text(item.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 140)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func itemContextMenu(_ item: BrowseItem) -> some View {
        let favorited = searchManager.isFavorited(item)

        if item.isArtist {
            Button {
                startStationForItem(item)
            } label: {
                Label("Start Station", systemImage: "antenna.radiowaves.left.and.right")
            }
        } else if item.uri != nil || item.resMD != nil {
            Button {
                playItem(item)
            } label: {
                Label("Play Now", systemImage: "play.fill")
            }
            if item.uri != nil {
                Button {
                    Task { await searchManager.playNext(item: item, manager: manager) }
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    Task { await searchManager.addToQueue(item: item, manager: manager) }
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }

                Divider()

                Button {
                    Task {
                        if favorited {
                            _ = await searchManager.removeFromFavorites(item: item, manager: manager)
                        } else {
                            _ = await searchManager.addToFavorites(item: item, manager: manager)
                        }
                    }
                } label: {
                    Label(favorited ? "Remove from Sonos Favorites" : "Add to Sonos Favorites",
                          systemImage: favorited ? "heart.slash" : "heart")
                }
            }
        }
    }
}

// MARK: - Favorite grid cover (URLSession)

/// Replaces `AsyncImage`, which could fail to repaint in `LazyVGrid` + `NavigationLink`
/// labels. `URLSession` + `UIImage` state is reliable; the grid layout itself is
/// unchanged (two flexible columns, same as before the workaround).
private enum FavoriteCoverArtCache {
    static let memory = NSCache<NSString, UIImage>()
}

private struct FavoriteCoverImageView: View {
    let itemId: String
    let imageURLString: String?
    let placeholderIcon: String

    @State private var image: UIImage?
    @State private var didFail = false

    private var resolvedURL: URL? {
        guard var s = imageURLString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let u = URL(string: s) { return u }
        return URL(string: s, encodingInvalidCharacters: true)
    }

    private var taskIdentity: String { "\(itemId)|\(imageURLString ?? "")" }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if didFail || resolvedURL == nil {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: placeholderIcon)
                            .foregroundStyle(.tertiary)
                    }
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { ProgressView().tint(.secondary) }
            }
        }
        .task(id: taskIdentity) { await loadImage() }
    }

    private func loadImage() async {
        await MainActor.run {
            image = nil
            didFail = false
        }
        guard let url = resolvedURL else {
            await MainActor.run { didFail = true }
            return
        }
        let key = url.absoluteString as NSString
        if let cached = FavoriteCoverArtCache.memory.object(forKey: key) {
            await MainActor.run { image = cached }
            return
        }
        do {
            var req = URLRequest(url: url, timeoutInterval: 25)
            req.httpMethod = "GET"
            let (data, response) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                await MainActor.run { didFail = true }
                return
            }
            if let ui = UIImage(data: data) {
                FavoriteCoverArtCache.memory.setObject(ui, forKey: key, cost: data.count)
                await MainActor.run { image = ui }
            } else {
                await MainActor.run { didFail = true }
            }
        } catch {
            await MainActor.run { didFail = true }
        }
    }
}

// MARK: - Favorite Category Detail (pushed via NavigationLink)

struct FavoriteCategoryDetailView: View {
    let category: BrowseItem.FavoriteCategory
    let items: [BrowseItem]
    @Bindable var searchManager: SearchManager
    @Bindable var manager: SonosManager

    @State private var filterText = ""
    @State private var playingItemId: String?

    private var filteredItems: [BrowseItem] {
        guard !filterText.isEmpty else { return items }
        let query = filterText.lowercased()
        return items.filter {
            $0.title.lowercased().contains(query)
            || $0.artist.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                searchBar
                    .padding(.horizontal)
                    .padding(.bottom, 12)

                if filteredItems.isEmpty && !filterText.isEmpty {
                    ContentUnavailableView.search(text: filterText)
                        .padding(.top, 20)
                } else {
                    // `URLSession` cover loading no longer needs the `HStack` workaround
                    // that replaced `AsyncImage` + `LazyVGrid` — bring the grid back so
                    // columns space evenly (the manual row + leading `HStack` hugged the
                    // left edge and broke margins).
                    let columns = [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16),
                    ]
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filteredItems) { item in
                            cardView(item)
                                .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle(category.rawValue)
        .navigationBarTitleDisplayMode(.large)
        .scrollContentBackground(.hidden)
        .background {
            ZStack {
                if let image = manager.albumArtImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 80)
                        .scaleEffect(1.5)
                    Color.black.opacity(0.6)
                } else {
                    Color.black
                }
            }
            .ignoresSafeArea()
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: - Local Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Search \(category.rawValue.lowercased())…", text: $filterText)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Card

    @ViewBuilder
    private func cardView(_ item: BrowseItem) -> some View {
        let cat = category

        if cat == .album, let nav = albumNavItem(for: item) {
            NavigationLink {
                AlbumDetailView(albumItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .contextMenu { contextMenu(item) }
        } else if cat == .artist {
            let nav = artistNavItem(for: item) ?? item
            NavigationLink {
                ArtistDetailView(artistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .contextMenu { contextMenu(item) }
        } else if cat == .playlist, let nav = playlistNavItem(for: item) {
            NavigationLink {
                PlaylistDetailView(playlistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .contextMenu { contextMenu(item) }
        } else if cat == .collection, let nav = collectionNavItem(for: item) {
            NavigationLink {
                PlaylistDetailView(playlistItem: nav, searchManager: searchManager, manager: manager)
            } label: {
                cardContent(item)
            }
            .buttonStyle(.plain)
            .contextMenu { contextMenu(item) }
        } else {
            let isLoading = playingItemId == item.id
            let isDisabled = playingItemId != nil && !isLoading

            Button { playItem(item) } label: {
                cardContent(item)
                    .opacity(isDisabled ? 0.4 : 1)
                    .overlay(alignment: .top) {
                        if isLoading {
                            RoundedRectangle(cornerRadius: cat == .artist ? 70 : 10)
                                .fill(.ultraThinMaterial.opacity(0.85))
                                .frame(width: 140, height: 140)
                                .overlay {
                                    ProgressView()
                                        .tint(.white)
                                        .controlSize(.regular)
                                }
                                .transition(.opacity)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .animation(.easeInOut(duration: 0.2), value: playingItemId)
            .contextMenu { contextMenu(item) }
        }
    }

    private func cardContent(_ item: BrowseItem) -> some View {
        let cornerRadius: CGFloat = category == .artist ? 70 : 10
        let centerInCard = (category == .artist)
        let hAlign: HorizontalAlignment = centerInCard ? .center : .leading

        return VStack(alignment: hAlign, spacing: 0) {
            FavoriteCoverImageView(
                itemId: item.id,
                imageURLString: item.albumArtURL,
                placeholderIcon: placeholderIcon(for: item)
            )
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            VStack(alignment: hAlign, spacing: 4) {
                Text(item.title)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(centerInCard ? .center : .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)

                subtitleLabel(for: item, centerInCard: centerInCard)
            }
            .padding(.top, 6)
        }
        .frame(width: 140)
    }

    // MARK: - Helpers

    private func albumNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "ALBUM" {
            return searchManager.browseItemWithResolvedFavoriteURI(item) ?? item
        }
        guard let ids = searchManager.parseCloudIds(from: item) else { return nil }
        var nav = searchManager.makeAlbumItem(
            objectId: ids.objectId, title: item.title, artist: item.artist,
            artURL: item.albumArtURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId)
        if let original = item.uri { nav.uri = original }
        return nav
    }

    private func artistNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "ARTIST" {
            return searchManager.browseItemWithResolvedFavoriteURI(item) ?? item
        }
        guard let ids = searchManager.parseCloudIds(from: item) else { return nil }
        return searchManager.makeArtistItem(
            objectId: ids.objectId, name: item.title, artURL: item.albumArtURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId)
    }

    private func playlistNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "PLAYLIST" {
            return searchManager.browseItemWithResolvedFavoriteURI(item) ?? item
        }
        guard let ids = searchManager.parseCloudIds(from: item) else { return nil }
        var nav = searchManager.makePlaylistItem(
            objectId: ids.objectId, title: item.title, artist: item.artist,
            artURL: item.albumArtURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId)
        if let original = item.uri { nav.uri = original }
        return nav
    }

    private func collectionNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "COLLECTION" { return item }
        if let ids = searchManager.parseCloudIds(from: item) {
            return BrowseItem(
                id: ids.objectId, title: item.title, artist: item.artist,
                album: "", albumArtURL: item.albumArtURL,
                uri: item.uri, isContainer: true,
                serviceId: searchManager.localSid(forCloudServiceId: ids.cloudServiceId),
                cloudType: "COLLECTION")
        }
        let sources = [item.uri, item.resMD, item.metaXML].compactMap { $0 }
        for src in sources where src.contains("libraryfolder") {
            if let range = src.range(of: "libraryfolder[^\"&<\\s]*", options: .regularExpression) {
                let objectId = String(src[range])
                return BrowseItem(
                    id: objectId, title: item.title, artist: item.artist,
                    album: "", albumArtURL: item.albumArtURL,
                    uri: item.uri, isContainer: true,
                    serviceId: item.serviceId,
                    cloudType: "COLLECTION")
            }
        }
        return nil
    }

    private func placeholderIcon(for item: BrowseItem) -> String {
        switch category {
        case .playlist: return "music.note.list"
        case .album: return "opticaldisc"
        case .song: return "music.note"
        case .station: return "antenna.radiowaves.left.and.right"
        case .artist: return "person.fill"
        case .collection: return "folder.fill"
        }
    }

    @ViewBuilder
    private func subtitleLabel(
        for item: BrowseItem,
        centerInCard: Bool
    ) -> some View {
        let subtitle: String = {
            switch category {
            case .playlist: return item.artist.isEmpty ? "Playlist" : item.artist
            case .album: return item.artist.isEmpty ? "Album" : "\(item.artist) · Album"
            case .song: return item.artist.isEmpty ? "Song" : "\(item.artist) · Song"
            case .station: return "Station"
            case .artist: return "Artist"
            case .collection: return item.artist.isEmpty ? "Collection" : item.artist
            }
        }()

        if !subtitle.isEmpty {
            HStack(spacing: 4) {
                if category == .station || category == .playlist || category == .album
                    || category == .song || category == .artist || category == .collection {
                    FavoritesStreamingGlyph(
                        cloudServiceId: searchManager.cloudServiceId(forFavorite: item),
                        displayNameHint: searchManager.serviceDisplayHint(forFavorite: item),
                        size: 10
                    )
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: centerInCard ? .center : .leading)
        }
    }

    private func playItem(_ item: BrowseItem) {
        guard playingItemId == nil else { return }
        playingItemId = item.id
        Task {
            await searchManager.playNow(item: item, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    @ViewBuilder
    private func contextMenu(_ item: BrowseItem) -> some View {
        let favorited = searchManager.isFavorited(item)

        if item.isArtist {
            Button {
                guard playingItemId == nil else { return }
                playingItemId = item.id
                Task {
                    await searchManager.startStation(item: item, manager: manager)
                    withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
                }
            } label: {
                Label("Start Station", systemImage: "antenna.radiowaves.left.and.right")
            }
        } else if item.uri != nil || item.resMD != nil {
            Button { playItem(item) } label: {
                Label("Play Now", systemImage: "play.fill")
            }
            if item.uri != nil {
                Button {
                    Task { await searchManager.playNext(item: item, manager: manager) }
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    Task { await searchManager.addToQueue(item: item, manager: manager) }
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }

                Divider()

                Button {
                    Task {
                        if favorited {
                            _ = await searchManager.removeFromFavorites(item: item, manager: manager)
                        } else {
                            _ = await searchManager.addToFavorites(item: item, manager: manager)
                        }
                    }
                } label: {
                    Label(favorited ? "Remove from Sonos Favorites" : "Add to Sonos Favorites",
                          systemImage: favorited ? "heart.slash" : "heart")
                }
            }
        }
    }
}
