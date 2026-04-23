import SwiftUI

struct SearchView: View {
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager
    @State private var searchText = ""
    @State private var showServiceSettings = false
    /// nil = "All", otherwise the serviceId string
    @State private var selectedServiceTab: String?
    /// Tracks which item is currently being loaded for playback
    @State private var playingItemId: String?

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
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showServiceSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .scrollContentBackground(.hidden)
            .preferredColorScheme(.dark)
            .searchable(text: $searchText, prompt: "Search songs, artists, albums…")
            .onSubmit(of: .search) {
                selectedServiceTab = nil
                searchManager.search(query: searchText)
            }
            .onAppear {
                searchManager.configure(speakerIP: manager.selectedSpeaker?.playbackIP)
                Task {
                    async let browse: () = searchManager.loadBrowseContent()
                    async let probe: () = searchManager.probeLinkedServices()
                    _ = await (browse, probe)
                }
            }
            .onChange(of: manager.selectedSpeaker?.ipAddress) { _, newIP in
                searchManager.configure(speakerIP: manager.selectedSpeaker?.playbackIP)
                searchManager.resetProbe()
                Task { await searchManager.loadBrowseContent() }
            }
            .sheet(isPresented: $showServiceSettings) {
                ServiceSettingsSheet(searchManager: searchManager)
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
                        browseSection(title: "Sonos Playlists", items: searchManager.playlists, horizontal: false)
                    }

                    if !searchManager.radio.isEmpty {
                        browseSection(title: "Radio Stations", items: searchManager.radio, horizontal: true)
                    }

                    if searchManager.favorites.isEmpty && searchManager.playlists.isEmpty && searchManager.radio.isEmpty {
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

    // MARK: - Favorite Grouped Section

    @ViewBuilder
    private func favoriteSection(category: BrowseItem.FavoriteCategory, items: [BrowseItem]) -> some View {
        let previewCount = 5
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
                .lineLimit(2)
                .foregroundStyle(.primary)

            categoryLabel(for: item, category: category)
        }
        .frame(width: 140)
    }

    /// Build a BrowseItem suitable for AlbumDetailView from a Favorite.
    private func albumNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "ALBUM" { return item }
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
        if item.cloudType == "ARTIST" { return item }
        guard let ids = searchManager.parseCloudIds(from: item) else {
            SonosLog.debug(.navItem, "artistNavItem parseCloudIds failed for '\(item.title)' uri=\(item.uri ?? "nil") resMD=\(item.resMD?.prefix(200) ?? "nil")")
            return nil
        }
        return searchManager.makeArtistItem(
            objectId: ids.objectId, name: item.title, artURL: item.albumArtURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId)
    }

    private func playlistNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "PLAYLIST" { return item }
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
        let subtitle: String = {
            switch cat {
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
                if cat == .station || cat == .playlist || cat == .album || cat == .collection || cat == .song {
                    FavoritesStreamingGlyph(
                        cloudServiceId: item.serviceId.flatMap { searchManager.cloudServiceId(forLocalSid: $0) },
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
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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

    // MARK: - Search Results (Tabbed)

    private var searchResultsContent: some View {
        Group {
            if searchManager.isSearching && searchManager.searchResults.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("Searching…")
                    Spacer()
                }
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

                            Text("Artist")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
                            Button {
                                // Future: show action sheet
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, height: 32)
                            }
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
                .lineLimit(2)

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
                    let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)]
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filteredItems) { item in
                            cardView(item)
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

        return VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: item.albumArtURL ?? "")) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            Image(systemName: placeholderIcon(for: item))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            Text(item.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            subtitleLabel(for: item)
        }
        .frame(width: 140)
    }

    // MARK: - Helpers

    private func albumNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "ALBUM" { return item }
        guard let ids = searchManager.parseCloudIds(from: item) else { return nil }
        var nav = searchManager.makeAlbumItem(
            objectId: ids.objectId, title: item.title, artist: item.artist,
            artURL: item.albumArtURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId)
        if let original = item.uri { nav.uri = original }
        return nav
    }

    private func artistNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "ARTIST" { return item }
        guard let ids = searchManager.parseCloudIds(from: item) else { return nil }
        return searchManager.makeArtistItem(
            objectId: ids.objectId, name: item.title, artURL: item.albumArtURL,
            cloudServiceId: ids.cloudServiceId, accountId: ids.accountId)
    }

    private func playlistNavItem(for item: BrowseItem) -> BrowseItem? {
        if item.cloudType == "PLAYLIST" { return item }
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
    private func subtitleLabel(for item: BrowseItem) -> some View {
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
                if category == .station || category == .playlist || category == .album || category == .song {
                    FavoritesStreamingGlyph(
                        cloudServiceId: item.serviceId.flatMap { searchManager.cloudServiceId(forLocalSid: $0) },
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

// MARK: - Service Settings Sheet

struct ServiceSettingsSheet: View {
    @Bindable var searchManager: SearchManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if searchManager.isProbing {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Detecting available services…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchManager.linkedAccounts.isEmpty {
                    ContentUnavailableView(
                        "No Music Services Found",
                        systemImage: "music.note.list",
                        description: Text("Link a music service in the official Sonos app first, then tap refresh below.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(sortedAccounts, id: \.serviceId) { account in
                                accountRow(account)
                            }
                        } header: {
                            Text("Linked Services (\(searchManager.linkedAccounts.count))")
                        } footer: {
                            Text("These services are linked to your Sonos system. Search is proxied through the Sonos Cloud API — no extra login needed.")
                        }
                    }
                }
            }
            .navigationTitle("Search Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await searchManager.forceReprobe() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .preferredColorScheme(.dark)
        }
        .presentationDetents([.medium, .large])
    }

    private var sortedAccounts: [SonosCloudAPI.CloudMusicServiceAccount] {
        let pinned: Set<String> = ["3079", "52231", "51463", "42247", "49671"]
        return searchManager.linkedAccounts.sorted { a, b in
            let aPinned = pinned.contains(a.serviceId ?? "")
            let bPinned = pinned.contains(b.serviceId ?? "")
            if aPinned != bPinned { return aPinned }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private func accountRow(_ account: SonosCloudAPI.CloudMusicServiceAccount) -> some View {
        let sid = account.serviceId ?? ""
        let enabled = searchManager.serviceEnabled[sid] ?? true

        return HStack(spacing: 12) {
            CloudServiceBrandMark(
                cloudServiceId: sid,
                displayNameHint: account.displayName,
                dimension: 24,
                symbolUsesTitle3: true
            )
                .foregroundStyle(enabled ? .primary : .secondary)
                .opacity(enabled ? 1 : 0.45)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .foregroundStyle(enabled ? .primary : .secondary)
                if let nick = account.nickname, nick != account.displayName {
                    Text(nick)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { searchManager.serviceEnabled[sid] ?? true },
                set: { searchManager.setServiceEnabled(serviceId: sid, enabled: $0) }
            ))
            .labelsHidden()
        }
    }

}
