import SwiftUI

struct SearchView: View {
    @Bindable var manager: SonosManager
    @State var searchManager = SearchManager()
    @State private var searchText = ""

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
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
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
                Task { await searchManager.loadBrowseContent() }
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

                    if !searchManager.musicServices.isEmpty {
                        servicesSection
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

    // MARK: - Services Section

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Music Services")
                .font(.title3.bold())
                .padding(.horizontal)

            LazyVStack(spacing: 0) {
                ForEach(searchManager.musicServices) { service in
                    HStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 36)

                        Text(service.name)
                            .font(.subheadline)

                        Spacer()

                        if service.capabilities.contains("search") {
                            Text("Searchable")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
            }
        }
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
