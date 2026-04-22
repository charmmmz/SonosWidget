import SwiftUI

struct ArtistDetailView: View {
    let artistItem: BrowseItem
    let searchManager: SearchManager
    let manager: SonosManager

    @State private var response: SonosCloudAPI.ArtistBrowseResponse?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var playingItemId: String?

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
        .background(Color(.systemGroupedBackground))
        .navigationTitle(artistName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadArtist() }
    }

    // MARK: - Header

    private var headerSection: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: headerImageURL ?? "")) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 60))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(height: 300)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                           startPoint: .center, endPoint: .bottom)

            Text(artistName)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .padding()
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if let stationAction = response?.customActions?.first(where: { $0.action == "ACTION_PLAY_STATION" }) {
                Button {
                    startStation(stationAction)
                } label: {
                    Label(stationAction.label ?? "Start Station",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
            }

            Spacer()
        }
        .padding()
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
        let isLoading = playingItemId == item.id
        let isDisabled = playingItemId != nil && !isLoading

        return Button {
            playAlbum(item)
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
                .overlay {
                    if isLoading {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.ultraThinMaterial.opacity(0.85))
                            .overlay {
                                ProgressView()
                                    .tint(.white)
                                    .controlSize(.regular)
                            }
                    }
                }

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
            .opacity(isDisabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
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

        do {
            response = try await SonosCloudAPI.browseArtist(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: accountId,
                artistId: artistItem.id)
            isLoading = false
        } catch {
            print("[ArtistDetail] Load failed: \(error)")
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Playback

    private func playAlbum(_ item: SonosCloudAPI.ArtistSectionItem) {
        guard playingItemId == nil,
              let objectId = item.resource?.id?.objectId,
              let serviceId = item.resource?.id?.serviceId,
              let accountId = item.resource?.id?.accountId else { return }

        playingItemId = item.id

        let browseItem = BrowseItem(
            id: objectId,
            title: item.title ?? "",
            artist: artistName,
            album: item.title ?? "",
            albumArtURL: item.images?.tile1x1,
            uri: searchManager.buildPlayableURIPublic(
                objectId: objectId, serviceId: serviceId,
                accountId: accountId, type: "ALBUM"),
            isContainer: true,
            serviceId: searchManager.localSid(forCloudServiceId: serviceId),
            cloudType: "ALBUM"
        )

        Task {
            await searchManager.playNow(item: browseItem, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }

    private func startStation(_ action: SonosCloudAPI.CustomAction) {
        guard playingItemId == nil else { return }
        guard let objectId = action.resource?.id?.objectId,
              let serviceId = action.resource?.id?.serviceId,
              let accountId = action.resource?.id?.accountId else { return }

        playingItemId = "station"

        let browseItem = BrowseItem(
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
            await searchManager.playNow(item: browseItem, manager: manager)
            withAnimation(.easeOut(duration: 0.2)) { playingItemId = nil }
        }
    }
}
