import SwiftUI

struct SearchView: View {
    @Bindable var manager: SonosManager
    @State var searchManager = SearchManager()
    @State private var searchText = ""
    @State private var showServiceSettings = false
    @State private var expandedCategory: BrowseItem.FavoriteCategory?
    /// nil = "All", otherwise the serviceId string
    @State private var selectedServiceTab: String?

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
            .searchable(text: $searchText, prompt: "Songs, artists, albums…")
            .onChange(of: searchText) { _, newValue in
                selectedServiceTab = nil
                searchManager.search(query: newValue)
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
                } else if let expanded = expandedCategory {
                    expandedSection(category: expanded)
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
                    Button("View All") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            expandedCategory = category
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func expandedSection(category: BrowseItem.FavoriteCategory) -> some View {
        let items = searchManager.favorites.filter { $0.favoriteCategory == category }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        expandedCategory = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                        Text("Back")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal)

            Text(category.rawValue)
                .font(.title.bold())
                .padding(.horizontal)

            let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)]
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(items) { item in
                    browseCard(item, category: category)
                }
            }
            .padding(.horizontal)
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

    private func browseCard(_ item: BrowseItem, category: BrowseItem.FavoriteCategory?) -> some View {
        Button {
            Task { await searchManager.playNow(item: item, manager: manager) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
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
                .clipShape(RoundedRectangle(cornerRadius: category == .artist ? 70 : 10))

                Text(item.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                categoryLabel(for: item, category: category)
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
        .contextMenu { itemContextMenu(item) }
    }

    @ViewBuilder
    private func categoryLabel(for item: BrowseItem, category: BrowseItem.FavoriteCategory?) -> some View {
        let cat = category ?? item.favoriteCategory
        let subtitle: String = {
            switch cat {
            case .playlist: return item.artist.isEmpty ? "Playlist" : item.artist
            case .album: return item.artist.isEmpty ? "Album" : "\(item.artist) · Album"
            case .station: return "Station"
            case .artist: return "Artist"
            case .other: return item.artist.isEmpty ? "" : item.artist
            }
        }()

        if !subtitle.isEmpty {
            HStack(spacing: 4) {
                if cat == .station || cat == .playlist || cat == .album {
                    Image(systemName: "applelogo")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
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
        case .station: return "antenna.radiowaves.left.and.right"
        case .artist: return "person.fill"
        case .other: return item.isContainer ? "music.note.list" : "music.note"
        }
    }

    private func browseRow(_ item: BrowseItem) -> some View {
        Button {
            Task { await searchManager.playNow(item: item, manager: manager) }
        } label: {
            HStack(spacing: 12) {
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

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
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
            } else if searchManager.searchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
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
                serviceTabChip(id: nil, label: "All", icon: nil)
                ForEach(searchManager.searchResults) { group in
                    serviceTabChip(id: group.id, label: group.serviceName,
                                   icon: serviceTabIcon(group.id))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func serviceTabChip(id: String?, label: String, icon: String?) -> some View {
        let isSelected = selectedServiceTab == id
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedServiceTab = id }
        } label: {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
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

    private func serviceTabIcon(_ serviceId: String) -> String? {
        switch serviceId {
        case "52231": return "apple.logo"
        case "3079": return "bolt.horizontal.circle.fill"
        case "42247": return "cloud.fill"
        case "49671": return "waveform.circle.fill"
        case "77575": return "antenna.radiowaves.left.and.right"
        default: return "music.note"
        }
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
                return searchManager.searchResults.first { $0.id == sid }?.items ?? []
            }
            // "All" tab: merge all services, keeping service order
            return searchManager.searchResults.flatMap { $0.items }
        }()

        let grouped = Dictionary(grouping: items) { categoryFor($0) }

        return VStack(alignment: .leading, spacing: 24) {
            // When "All" tab and multiple services, show per-service sections
            if selectedServiceTab == nil && searchManager.searchResults.count > 1 {
                ForEach(searchManager.searchResults) { group in
                    allTabServiceSection(group)
                }
            } else {
                // Single service or specific service tab: group by type
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
                if let icon = serviceTabIcon(group.id) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
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
                    Button {
                        Task { await searchManager.startStation(item: item, manager: manager) }
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
                Button {
                    Task { await searchManager.playNow(item: item, manager: manager) }
                } label: {
                    HStack(spacing: 12) {
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

                        Button {
                            // Future: show action sheet
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .contextMenu { itemContextMenu(item) }
            }
        }
    }

    // MARK: Album / Playlist Horizontal Scroll

    private func albumHorizontalScroll(items: [BrowseItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(items) { item in
                    Button {
                        Task { await searchManager.playNow(item: item, manager: manager) }
                    } label: {
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
                    .buttonStyle(.plain)
                    .contextMenu { itemContextMenu(item) }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func itemContextMenu(_ item: BrowseItem) -> some View {
        if item.isArtist {
            Button {
                Task { await searchManager.startStation(item: item, manager: manager) }
            } label: {
                Label("Start Station", systemImage: "antenna.radiowaves.left.and.right")
            }
        } else if item.uri != nil || item.resMD != nil {
            Button {
                Task { await searchManager.playNow(item: item, manager: manager) }
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
                        Text("正在检测可用服务…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchManager.linkedAccounts.isEmpty {
                    ContentUnavailableView(
                        "未检测到流媒体",
                        systemImage: "music.note.list",
                        description: Text("请先在 Sonos 官方 App 中绑定流媒体服务，然后点击下方刷新。")
                    )
                } else {
                    List {
                        Section {
                            ForEach(sortedAccounts, id: \.serviceId) { account in
                                accountRow(account)
                            }
                        } header: {
                            Text("已绑定的流媒体 (\(searchManager.linkedAccounts.count))")
                        } footer: {
                            Text("这些流媒体已在你的 Sonos 系统中绑定。搜索功能通过 Sonos Cloud 直接代理，无需额外登录。")
                        }
                    }
                }
            }
            .navigationTitle("搜索设置")
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
                    Button("完成") { dismiss() }
                }
            }
            .preferredColorScheme(.dark)
        }
        .presentationDetents([.medium, .large])
    }

    private var sortedAccounts: [SonosCloudAPI.CloudMusicServiceAccount] {
        let pinned: Set<String> = ["3079", "52231", "42247", "49671"]
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
            Image(systemName: serviceIcon(for: sid))
                .font(.title3)
                .foregroundStyle(enabled ? .green : .secondary)
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

    private func serviceIcon(for serviceId: String) -> String {
        switch serviceId {
        case "3079": return "bolt.horizontal.circle.fill" // Spotify
        case "52231": return "apple.logo" // Apple Music
        case "42247": return "cloud.fill" // NetEase
        case "49671": return "waveform.circle.fill" // Lizhi
        case "77575": return "antenna.radiowaves.left.and.right" // Sonos Radio
        default: return "music.note"
        }
    }
}
