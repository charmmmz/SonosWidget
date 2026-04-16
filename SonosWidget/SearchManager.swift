import Foundation
import SwiftUI

@Observable
final class SearchManager {
    var favorites: [BrowseItem] = []
    var playlists: [BrowseItem] = []
    var radio: [BrowseItem] = []
    var searchResults: [ServiceSearchResult] = []
    var musicServices: [MusicService] = []
    var isLoadingBrowse = false
    var isSearching = false
    var searchQuery = ""
    var errorMessage: String?

    struct ServiceSearchResult: Identifiable {
        var id: Int { service.id }
        var service: MusicService
        var items: [BrowseItem]
    }

    private var speakerIP: String?
    private var searchTask: Task<Void, Never>?

    func configure(speakerIP: String?) {
        self.speakerIP = speakerIP
    }

    // MARK: - Browse

    func loadBrowseContent() async {
        guard let ip = speakerIP else { return }
        isLoadingBrowse = true
        errorMessage = nil

        async let favs = tryBrowse { try await SonosAPI.browseFavorites(ip: ip) }
        async let lists = tryBrowse { try await SonosAPI.browsePlaylists(ip: ip) }
        async let stations = tryBrowse { try await SonosAPI.browseRadio(ip: ip) }

        favorites = await favs
        playlists = await lists
        radio = await stations

        if musicServices.isEmpty {
            musicServices = (try? await SonosAPI.listMusicServices(ip: ip)) ?? []
        }

        isLoadingBrowse = false
    }

    private func tryBrowse(_ block: () async throws -> [BrowseItem]) async -> [BrowseItem] {
        (try? await block()) ?? []
    }

    // MARK: - Search

    func search(query: String) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task {
            guard let ip = speakerIP else { return }

            var results: [ServiceSearchResult] = []
            let searchableServices = musicServices.filter { $0.capabilities.contains("search") }

            for service in searchableServices {
                guard !Task.isCancelled else { return }
                do {
                    let sessionId = try await SonosAPI.getSessionId(ip: ip, serviceId: service.id)
                    let items = try await SonosAPI.searchMusicService(
                        smapiURI: service.smapiURI, sessionId: sessionId, searchTerm: query)
                    if !items.isEmpty {
                        results.append(ServiceSearchResult(service: service, items: items))
                    }
                } catch {
                    // Skip services that fail
                }
            }

            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        }
    }

    // MARK: - Playback Actions

    func playNow(item: BrowseItem, manager: SonosManager) async {
        guard let ip = manager.selectedSpeaker?.playbackIP,
              let uri = item.uri else { return }
        do {
            try await SonosAPI.addURIToQueue(ip: ip, uri: uri, metadata: item.metaXML ?? "", asNext: true)
            try await SonosAPI.next(ip: ip)
            try await SonosAPI.play(ip: ip)
            try? await Task.sleep(for: .milliseconds(500))
            await manager.refreshState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playNext(item: BrowseItem, manager: SonosManager) async {
        guard let uri = item.uri else { return }
        await manager.playNext(uri: uri, metadata: item.metaXML ?? "")
    }

    func addToQueue(item: BrowseItem, manager: SonosManager) async {
        guard let ip = manager.selectedSpeaker?.playbackIP,
              let uri = item.uri else { return }
        do {
            try await SonosAPI.addURIToQueue(ip: ip, uri: uri, metadata: item.metaXML ?? "")
            await manager.loadQueue()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
