import SwiftUI

struct ArtistDetailView: View {
    let artistItem: BrowseItem
    let searchManager: SearchManager
    let manager: SonosManager

    @State private var response: SonosCloudAPI.ArtistBrowseResponse?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var playingItemId: String?
    @State private var toastMessage: String?
    @State private var isFavorited = false
    @State private var headerImage: UIImage?
    @State private var themeColor: Color = .teal

    private var artistName: String { response?.title ?? artistItem.title }
    private var headerImageURL: String? {
        response?.images?.tile1x1 ?? artistItem.albumArtURL
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                actionButtons
                albumsGrid
            }
        }
        .background { artistBackground }
        .navigationTitle(artistName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                artistMenu
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
                withAnimation(.easeInOut(duration: 0.4)) { themeColor = color }
            }
        } catch {
            print("[ArtistDetail] Header image load failed: \(error)")
        }
    }

    // MARK: - Three-Dot Menu

    private var artistMenu: some View {
        Menu {
            Button {
                toggleFavorite()
            } label: {
                Label(isFavorited ? "Remove from Sonos Favorites" : "Add to Sonos Favorites",
                      systemImage: isFavorited ? "heart.fill" : "heart")
            }

            if let stationAction = response?.customActions?.first(where: { $0.action == "ACTION_PLAY_STATION" }) {
                Divider()

                Button {
                    startStation(stationAction)
                } label: {
                    Label(stationAction.label ?? "Start Station",
                          systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .symbolRenderingMode(.hierarchical)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
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
                .frame(width: 200, height: 200)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            } else {
                Circle().fill(.quaternary)
                    .frame(width: 200, height: 200)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                    }
            }

            Text(artistName)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            if let provider = response?.providerInfo?.name {
                Text(provider)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 24)
        .padding(.horizontal)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if let stationAction = response?.customActions?.first(where: { $0.action == "ACTION_PLAY_STATION" }) {
                let isActive = playingItemId == "station"
                let isDisabled = playingItemId != nil && !isActive

                Button {
                    startStation(stationAction)
                } label: {
                    HStack(spacing: 6) {
                        if isActive {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.subheadline.weight(.semibold))
                        }
                        Text(stationAction.label ?? "Start Station")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(themeColor, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                }
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.4 : 1)
            }
        }
        .padding(.horizontal)
        .padding(.top, 16)
        .padding(.bottom, 8)
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
        }
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
                AsyncImage(url: URL(string: item.images?.tile1x1 ?? "")) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                            .overlay {
                                Image(systemName: "opticaldisc")
                                    .font(.title)
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(item.title ?? "")
                    .font(.caption.weight(.medium))
                    .lineLimit(2)

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

    private func browseItem(from item: SonosCloudAPI.ArtistSectionItem) -> BrowseItem {
        let objectId = item.resource?.id?.objectId ?? ""
        let serviceId = item.resource?.id?.serviceId
        let accountId = item.resource?.id?.accountId

        return BrowseItem(
            id: objectId,
            title: item.title ?? "",
            artist: artistName,
            album: item.title ?? "",
            albumArtURL: item.images?.tile1x1,
            uri: serviceId.flatMap { sid in
                accountId.flatMap { aid in
                    searchManager.buildPlayableURIPublic(
                        objectId: objectId, serviceId: sid,
                        accountId: aid, type: "ALBUM")
                }
            },
            isContainer: true,
            serviceId: serviceId.flatMap { searchManager.localSid(forCloudServiceId: $0) },
            cloudType: "ALBUM"
        )
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

        print("[ArtistDetail] Loading artist: id=\(artistItem.id), serviceId=\(serviceId), accountId=\(accountId)")

        do {
            response = try await SonosCloudAPI.browseArtist(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: accountId,
                artistId: artistItem.id)
            isLoading = false
        } catch {
            print("[ArtistDetail] Browse failed (\(error)), trying search fallback for '\(artistItem.title)'")
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
                term: artistItem.title, count: 10)

            let artistResource = searchResult.allResources
                .first { $0.type == "ARTIST" && $0.name?.lowercased() == artistItem.title.lowercased() }
                ?? searchResult.allResources.first { $0.type == "ARTIST" }

            guard let correctId = artistResource?.id?.objectId else {
                errorText = "Artist not found"
                isLoading = false
                return
            }

            print("[ArtistDetail] Search fallback: found artistId=\(correctId)")
            response = try await SonosCloudAPI.browseArtist(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: accountId,
                artistId: correctId)
            isLoading = false
        } catch {
            print("[ArtistDetail] Search fallback failed: \(error)")
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Playback

    private func startStation(_ action: SonosCloudAPI.CustomAction) {
        guard playingItemId == nil else { return }
        guard let objectId = action.resource?.id?.objectId,
              let serviceId = action.resource?.id?.serviceId,
              let accountId = action.resource?.id?.accountId else { return }

        playingItemId = "station"

        let item = BrowseItem(
            id: objectId,
            title: "\(artistName) Station",
            artist: artistName,
            album: "",
            albumArtURL: headerImageURL,
            uri: searchManager.buildPlayableURIPublic(
                objectId: objectId, serviceId: serviceId,
                accountId: accountId, type: "PROGRAM"),
            isContainer: false,
            serviceId: searchManager.localSid(forCloudServiceId: serviceId),
            cloudType: "PROGRAM"
        )

        Task {
            await searchManager.playNow(item: item, manager: manager)
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
                let ok = await searchManager.addToFavorites(item: artistItem, manager: manager)
                if ok { isFavorited = true }
                showToast(ok ? "Added to Favorites" : "Failed to add")
            }
        }
    }
}
