import SwiftUI

struct SearchView: View {
    @Bindable var manager: SonosManager
    @State var searchManager = SearchManager()
    @State private var searchText = ""
    @State private var showServiceSettings = false

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
                        if !searchManager.hasFinishedProbing {
                            Task { await searchManager.probeLinkedServices() }
                        }
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
                searchManager.search(query: newValue)
            }
            .onAppear {
                searchManager.configure(speakerIP: manager.selectedSpeaker?.playbackIP)
                if searchManager.favorites.isEmpty {
                    Task { await searchManager.loadBrowseContent() }
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
                    if !searchManager.favorites.isEmpty {
                        browseSection(title: "Favorites", items: searchManager.favorites, horizontal: true)
                    }

                    if !searchManager.playlists.isEmpty {
                        browseSection(title: "Playlists", items: searchManager.playlists, horizontal: false)
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
                            browseCard(item)
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

    private func browseCard(_ item: BrowseItem) -> some View {
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
                                Image(systemName: item.isContainer ? "music.note.list" : "music.note")
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(item.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

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

    // MARK: - Search Results

    private var searchResultsContent: some View {
        Group {
            if searchManager.isSearching {
                VStack {
                    Spacer()
                    ProgressView("Searching…")
                    Spacer()
                }
            } else if searchManager.searchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(searchManager.searchResults) { group in
                        Section(group.service.name) {
                            ForEach(group.items) { item in
                                searchResultRow(item)
                                    .contextMenu { itemContextMenu(item) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func searchResultRow(_ item: BrowseItem) -> some View {
        Button {
            Task { await searchManager.playNow(item: item, manager: manager) }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: item.albumArtURL ?? "")) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay { Image(systemName: "music.note").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if !item.artist.isEmpty {
                            Text(item.artist)
                        }
                        if !item.album.isEmpty {
                            Text("· \(item.album)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func itemContextMenu(_ item: BrowseItem) -> some View {
        if item.uri != nil {
            Button {
                Task { await searchManager.playNow(item: item, manager: manager) }
            } label: {
                Label("Play Now", systemImage: "play.fill")
            }
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

// MARK: - Service Settings Sheet

struct ServiceSettingsSheet: View {
    @Bindable var searchManager: SearchManager
    @Environment(\.dismiss) private var dismiss

    /// Well-known services to show at the top of the auth list.
    private let pinnedServiceIds: Set<Int> = [12, 204, 284, 201, 174, 2, 165, 160, 212]

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
                } else {
                    List {
                        // Authenticated services (Spotify, Apple Music, etc.)
                        if !searchManager.authServices.isEmpty {
                            Section {
                                ForEach(sortedAuthServices) { service in
                                    authServiceRow(service)
                                }
                            } header: {
                                Text("需要登录的服务")
                            } footer: {
                                Text("点击\"登录\"授权后即可搜索该服务的曲库。登录信息保存在本地。")
                            }
                        }

                        // Anonymous services (TuneIn, Sonos Radio, etc.)
                        if !searchManager.anonymousServices.isEmpty {
                            Section {
                                ForEach(searchManager.anonymousServices) { service in
                                    anonymousServiceRow(service)
                                }
                            } header: {
                                Text("免登录服务")
                            } footer: {
                                Text("这些服务无需登录即可搜索。")
                            }
                        }

                        Section {
                            Button {
                                Task { await searchManager.forceReprobe() }
                            } label: {
                                Label("刷新列表", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                }
            }
            .navigationTitle("搜索设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .preferredColorScheme(.dark)
            .alert("登录失败", isPresented: .init(
                get: { searchManager.linkError != nil },
                set: { if !$0 { searchManager.linkError = nil } }
            )) {
                Button("好") { searchManager.linkError = nil }
            } message: {
                Text(searchManager.linkError ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var sortedAuthServices: [MusicService] {
        searchManager.authServices.sorted { a, b in
            let aPinned = pinnedServiceIds.contains(a.id)
            let bPinned = pinnedServiceIds.contains(b.id)
            if aPinned != bPinned { return aPinned }
            let aLinked = searchManager.linkedAuthServices.contains(a.id)
            let bLinked = searchManager.linkedAuthServices.contains(b.id)
            if aLinked != bLinked { return aLinked }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func authServiceRow(_ service: MusicService) -> some View {
        let isLinked = searchManager.linkedAuthServices.contains(service.id)
        let enabled = searchManager.serviceEnabled[service.id] ?? false

        HStack(spacing: 12) {
            Image(systemName: isLinked ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                .font(.title3)
                .foregroundStyle(isLinked ? .green : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .foregroundStyle(isLinked ? .primary : .secondary)
                if isLinked {
                    Text("已登录")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            if isLinked {
                Toggle("", isOn: Binding(
                    get: { searchManager.serviceEnabled[service.id] ?? true },
                    set: { searchManager.setServiceEnabled(service, enabled: $0) }
                ))
                .labelsHidden()
            } else if searchManager.isLinking && searchManager.linkingService?.id == service.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("登录") {
                    Task {
                        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                              let window = scene.windows.first else { return }
                        await searchManager.startLinking(service: service, from: window)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .swipeActions(edge: .trailing) {
            if isLinked {
                Button(role: .destructive) {
                    searchManager.deleteCredentials(serviceId: service.id)
                } label: {
                    Label("退出", systemImage: "trash")
                }
            }
        }
    }

    private func anonymousServiceRow(_ service: MusicService) -> some View {
        let enabled = searchManager.serviceEnabled[service.id] ?? true
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundStyle(enabled ? .primary : .tertiary)
                .frame(width: 32)

            Text(service.name)
                .foregroundStyle(enabled ? .primary : .secondary)

            Spacer()

            Toggle("", isOn: Binding(
                get: { searchManager.serviceEnabled[service.id] ?? true },
                set: { searchManager.setServiceEnabled(service, enabled: $0) }
            ))
            .labelsHidden()
        }
    }
}
