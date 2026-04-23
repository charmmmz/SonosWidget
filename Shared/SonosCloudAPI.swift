import Foundation

enum SonosCloudAPI {

    private static let baseURL = "https://api.ws.sonos.com/control/api/v1"

    // MARK: - Households

    struct Household: Decodable {
        let id: String
        let name: String?
    }

    static func getHouseholds(token: String) async throws -> [Household] {
        let data = try await get(path: "/households", token: token)
        let wrapper = try JSONDecoder().decode(HouseholdsResponse.self, from: data)
        return wrapper.households
    }

    private struct HouseholdsResponse: Decodable { let households: [Household] }

    // MARK: - Groups

    struct CloudGroup: Decodable {
        let id: String
        let name: String
        let playbackState: String?
        let playerIds: [String]
    }

    struct CloudPlayer: Decodable {
        let id: String
        let name: String
    }

    struct GroupsResponse: Decodable {
        let groups: [CloudGroup]
        let players: [CloudPlayer]
    }

    static func getGroups(token: String, householdId: String) async throws -> GroupsResponse {
        let data = try await get(path: "/households/\(householdId)/groups", token: token)
        return try JSONDecoder().decode(GroupsResponse.self, from: data)
    }

    // MARK: - Playback Metadata

    struct CloudPlaybackMetadata: Decodable {
        let container: MetadataContainer?
        let currentItem: CurrentItem?
    }

    struct MetadataContainer: Decodable {
        let name: String?
        let type: String?
    }

    struct CurrentItem: Decodable {
        let track: CloudTrack?
    }

    struct CloudTrack: Decodable {
        let name: String?
        let artist: CloudArtist?
        let album: CloudAlbum?
        let quality: CloudTrackQuality?
    }

    struct CloudArtist: Decodable { let name: String? }
    struct CloudAlbum: Decodable { let name: String? }

    struct CloudTrackQuality: Decodable, Sendable {
        let codec: String?
        let lossless: Bool?
        let bitDepth: Int?
        let sampleRate: Int?
        let immersive: Bool?
    }

    static func getPlaybackMetadata(token: String, groupId: String) async throws -> CloudPlaybackMetadata {
        let data = try await get(path: "/groups/\(groupId)/playbackMetadata", token: token)
        return try JSONDecoder().decode(CloudPlaybackMetadata.self, from: data)
    }

    // MARK: - Music Service Accounts

    struct CloudMusicServiceAccount: Codable {
        let id: String?
        let serviceId: String?
        let integrationId: String?
        let accountId: String?
        let nickname: String?
        let name: String?
        let username: String?
        let isGuest: Bool?

        /// Display name: prefer "name" (e.g. "Apple Music"), fallback to "nickname".
        var displayName: String { name ?? nickname ?? "Unknown" }

        private enum CodingKeys: String, CodingKey {
            case id
            case serviceId = "service-id"
            case integrationId = "integration-id"
            case accountId = "account-id"
            case nickname
            case name
            case username
            case isGuest = "is-guest"
        }
    }

    private struct MusicServiceAccountsResponse: Decodable {
        let accounts: [CloudMusicServiceAccount]?
    }

    static func getMusicServiceAccounts(token: String, householdId: String) async throws -> [CloudMusicServiceAccount] {
        let urlStr = "\(playBaseURL)/households/\(householdId)/integrations/registrations"
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        let text = String(data: data, encoding: .utf8) ?? ""
        SonosLog.debug(.cloudAPI, "integrations/registrations → HTTP \(status), \(data.count)B: \(text.prefix(2000))")

        guard (200...299).contains(status) else {
            throw SonosCloudError.httpError(status)
        }

        // Response is a direct JSON array
        if let arr = try? JSONDecoder().decode([CloudMusicServiceAccount].self, from: data) {
            return arr
        }
        // Or wrapped in an object
        if let wrapper = try? JSONDecoder().decode(MusicServiceAccountsResponse.self, from: data),
           let accounts = wrapper.accounts { return accounts }
        // Generic fallback
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (_, value) in json {
                if let arr = value as? [[String: Any]] {
                    let reEncoded = try JSONSerialization.data(withJSONObject: arr)
                    if let accounts = try? JSONDecoder().decode([CloudMusicServiceAccount].self, from: reEncoded) {
                        return accounts
                    }
                }
            }
        }
        SonosLog.error(.cloudAPI, "Could not parse integrations/registrations response")
        return []
    }

    // MARK: - Cloud Search (play.sonos.com)

    private static let playBaseURL = "https://play.sonos.com/api/content/v1"

    struct CloudSearchResponse: Decodable {
        let info: SearchInfo?
        let services: [CloudServiceResults]?

        struct SearchInfo: Decodable { let count: Int? }
    }

    struct CloudServiceResults: Decodable {
        let serviceId: String?
        let accountId: String?
        let resources: [CloudResource]?
        let errors: [CloudServiceError]?
    }

    struct CloudServiceError: Decodable {
        let errorCode: String?
        let reason: String?
    }

    struct CloudResource: Decodable {
        let id: CloudResourceId?
        let name: String?
        let type: String?
        let playable: Bool?
        let explicit: Bool?
        let images: [CloudImage]?
        let artists: [CloudResourceArtist]?
        let summary: CloudSummary?
        let container: CloudResourceContainer?
        let durationMs: Int?
        let defaults: String?
    }

    struct CloudResourceId: Decodable {
        let objectId: String?
        let serviceId: String?
        let accountId: String?
        let serviceName: String?
        let serviceNameId: String?
    }

    struct CloudImage: Decodable { let url: String? }
    struct CloudSummary: Decodable { let content: String? }

    struct CloudResourceArtist: Decodable {
        let name: String?
        let id: CloudResourceId?
    }

    struct CloudResourceContainer: Decodable {
        let id: CloudResourceId?
        let name: String?
        let type: String?
        let images: [CloudImage]?
        let playable: Bool?
    }

    /// Generic search across all linked services in one request.
    /// Fast but some services (e.g. Apple Music) only return TRACK + ARTIST.
    static func searchCatalog(token: String, householdId: String, term: String,
                              serviceIds: [String]) async throws -> CloudSearchResponse {
        let idsParam = serviceIds.joined(separator: ",")
        let encodedTerm = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term

        let urlStr = "\(playBaseURL)/households/\(householdId)/search" +
            "?query=\(encodedTerm)&services=\(idsParam)"

        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        SonosLog.debug(.cloudSearch, "GET \(urlStr.prefix(200))")

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        SonosLog.debug(.cloudSearch, "HTTP \(statusCode), \(data.count) bytes")

        if statusCode == 401 { throw SonosCloudError.unauthorized }
        if !(200...299).contains(statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            SonosLog.error(.cloudSearch, "Error body: \(body.prefix(500))")
            throw SonosCloudError.httpError(statusCode)
        }

        return try JSONDecoder().decode(CloudSearchResponse.self, from: data)
    }

    /// Per-service search (same endpoint as Sonos web player).
    /// Returns all resource types: TRACK, ARTIST, ALBUM, PLAYLIST, PROGRAM.
    static func searchService(token: String, householdId: String,
                              serviceId: String, accountId: String,
                              term: String, count: Int = 50) async throws -> ServiceSearchResponse {
        let encodedTerm = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let urlStr = "\(playBaseURL)/households/\(householdId)" +
            "/services/\(serviceId)/accounts/\(accountId)" +
            "/search?query=\(encodedTerm)&count=\(count)"

        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        SonosLog.debug(.cloudSearch, "GET \(urlStr.prefix(200))")

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        SonosLog.debug(.cloudSearch, "HTTP \(statusCode), \(data.count) bytes")

        if statusCode == 401 { throw SonosCloudError.unauthorized }
        if !(200...299).contains(statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            SonosLog.error(.cloudSearch, "Error body: \(body.prefix(500))")
            throw SonosCloudError.httpError(statusCode)
        }

        return try JSONDecoder().decode(ServiceSearchResponse.self, from: data)
    }

    struct ServiceSearchResponse: Decodable {
        let resourceOrder: [String]?
        var sections: [String: ResourceSection] = [:]

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init(_ string: String) { self.stringValue = string }
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            resourceOrder = try container.decodeIfPresent([String].self, forKey: DynamicKey("resourceOrder"))
            let skip: Set<String> = ["info", "errors", "externalLinks", "resourceOrder"]
            for key in container.allKeys where !skip.contains(key.stringValue) {
                if let section = try? container.decode(ResourceSection.self, forKey: key) {
                    sections[key.stringValue] = section
                }
            }
        }

        var allResources: [CloudResource] {
            let order = resourceOrder ?? Array(sections.keys)
            return order.flatMap { sections[$0]?.resources ?? [] }
        }
    }

    struct ResourceSection: Decodable {
        let info: SectionInfo?
        let resources: [CloudResource]?

        struct SectionInfo: Decodable {
            let count: Int?
            let offset: Int?
            let pageSize: Int?
        }
    }

    // MARK: - Artist Browse (v2)

    struct ArtistBrowseResponse: Decodable {
        let type: String?
        let title: String?
        let images: ContentImages?
        let resource: ArtistResource?
        let customActions: [CustomAction]?
        let sections: ArtistSections?
        let providerInfo: ProviderInfo?
    }

    struct ContentImages: Decodable {
        let tile1x1: String?
    }

    struct ArtistResource: Decodable {
        let type: String?
        let id: CloudResourceId?
    }

    struct CustomAction: Decodable {
        let action: String?
        let label: String?
        let resource: CustomActionResource?
    }

    struct CustomActionResource: Decodable {
        let id: CloudResourceId?
        let type: String?
    }

    struct ArtistSections: Decodable {
        let items: [ArtistSection]?
    }

    struct ArtistSection: Decodable {
        let items: [ArtistSectionItem]?
        let total: Int?
    }

    struct ArtistSectionItem: Decodable {
        let id: String?
        let title: String?
        let subtitle: String?
        let images: ContentImages?
        let type: String?
        let resource: ArtistItemResource?
        let isExplicit: Bool?
        let actions: [String]?
        let href: String?
    }

    struct ArtistItemResource: Decodable {
        let id: CloudResourceId?
        let type: String?
        let defaults: String?
    }

    struct ProviderInfo: Decodable {
        let id: String?
        let slug: String?
        let name: String?
    }

    static func browseArtist(token: String, householdId: String,
                             serviceId: String, accountId: String,
                             artistId: String) async throws -> ArtistBrowseResponse {
        let encodedArtist = artistId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artistId
        let urlStr = "\(playBaseURL.replacingOccurrences(of: "/v1", with: "/v2"))" +
            "/households/\(householdId)/services/\(serviceId)" +
            "/accounts/\(accountId)/artists/\(encodedArtist)/browse?muse2=true"

        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        SonosLog.debug(.cloudAPI, "browseArtist GET \(urlStr.prefix(200))")

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        SonosLog.debug(.cloudAPI, "browseArtist HTTP \(statusCode), \(data.count) bytes")

        if statusCode == 401 { throw SonosCloudError.unauthorized }
        if !(200...299).contains(statusCode) {
            throw SonosCloudError.httpError(statusCode)
        }

        return try JSONDecoder().decode(ArtistBrowseResponse.self, from: data)
    }

    // MARK: - Album Browse (v2)

    struct AlbumBrowseResponse: Decodable {
        let type: String?
        let title: String?
        let subtitle: String?
        let images: ContentImages?
        let resource: ArtistResource?
        let isExplicit: Bool?
        let actions: [String]?
        let tracks: AlbumTracks?
        let section: CollectionSection?
        let providerInfo: ProviderInfo?
    }

    struct CollectionSection: Decodable {
        let id: String?
        let type: String?
        let title: String?
        let href: String?
        let items: [AlbumTrackItem]?
        let total: Int?
    }

    struct AlbumTracks: Decodable {
        let items: [AlbumTrackItem]?
        let total: Int?
    }

    struct AlbumTrackItem: Decodable {
        let id: String?
        let title: String?
        let subtitle: String?
        let images: ContentImages?
        let type: String?
        let resource: ArtistItemResource?
        let artists: [TrackArtist]?
        let isExplicit: Bool?
        let ordinal: Int?
        let duration: String?
        let actions: [String]?

        var isBrowsable: Bool {
            if let actions, actions.contains("BROWSE") { return true }
            if let rType = resource?.type,
               ["CONTAINER", "PLAYLIST", "ALBUM"].contains(rType) { return true }
            return false
        }
    }

    struct TrackArtist: Decodable {
        let id: String?
        let name: String?
    }

    static func browseAlbum(token: String, householdId: String,
                            serviceId: String, accountId: String,
                            albumId: String, count: Int = 50) async throws -> AlbumBrowseResponse {
        let encodedAlbum = albumId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? albumId
        let urlStr = "\(playBaseURL.replacingOccurrences(of: "/v1", with: "/v2"))" +
            "/households/\(householdId)/services/\(serviceId)" +
            "/accounts/\(accountId)/albums/\(encodedAlbum)/browse?muse2=true&count=\(count)"

        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        SonosLog.debug(.cloudAPI, "browseAlbum GET \(urlStr.prefix(200))")

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        SonosLog.debug(.cloudAPI, "browseAlbum HTTP \(statusCode), \(data.count) bytes")

        if statusCode == 401 { throw SonosCloudError.unauthorized }
        if !(200...299).contains(statusCode) {
            throw SonosCloudError.httpError(statusCode)
        }

        return try JSONDecoder().decode(AlbumBrowseResponse.self, from: data)
    }

    // MARK: - Playlist Browse (v2)

    static func browsePlaylist(token: String, householdId: String,
                               serviceId: String, accountId: String,
                               playlistId: String, count: Int = 100,
                               offset: Int = 0) async throws -> AlbumBrowseResponse {
        let encodedPlaylist = playlistId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlistId
        var urlStr = "\(playBaseURL.replacingOccurrences(of: "/v1", with: "/v2"))" +
            "/households/\(householdId)/services/\(serviceId)" +
            "/accounts/\(accountId)/playlists/\(encodedPlaylist)/browse?muse2=true&count=\(count)"
        if offset > 0 { urlStr += "&offset=\(offset)" }

        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        SonosLog.debug(.cloudAPI, "browsePlaylist GET \(urlStr.prefix(200))")

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        SonosLog.debug(.cloudAPI, "browsePlaylist HTTP \(statusCode), \(data.count) bytes")

        if statusCode == 401 { throw SonosCloudError.unauthorized }
        if !(200...299).contains(statusCode) {
            throw SonosCloudError.httpError(statusCode)
        }

        return try JSONDecoder().decode(AlbumBrowseResponse.self, from: data)
    }

    // MARK: - Container Browse (v2) – for library folders / collections

    static func browseContainer(token: String, householdId: String,
                                serviceId: String, accountId: String,
                                containerId: String, count: Int = 100,
                                offset: Int = 0) async throws -> AlbumBrowseResponse {
        let encodedContainer = containerId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? containerId
        var urlStr = "\(playBaseURL.replacingOccurrences(of: "/v1", with: "/v2"))" +
            "/households/\(householdId)/services/\(serviceId)" +
            "/accounts/\(accountId)/containers/\(encodedContainer)/browse?muse2=true&count=\(count)"
        if offset > 0 { urlStr += "&offset=\(offset)" }

        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        SonosLog.debug(.cloudAPI, "browseContainer GET \(urlStr.prefix(200))")

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        SonosLog.debug(.cloudAPI, "browseContainer HTTP \(statusCode), \(data.count) bytes")

        if statusCode == 401 { throw SonosCloudError.unauthorized }
        if !(200...299).contains(statusCode) {
            throw SonosCloudError.httpError(statusCode)
        }

        return try JSONDecoder().decode(AlbumBrowseResponse.self, from: data)
    }

    // MARK: - Now Playing (v2)

    struct NowPlayingResponse: Decodable {
        let title: String?
        let subtitle: String?
        let type: String?
        let images: ContentImages?
        let item: NowPlayingItem?
    }

    struct NowPlayingItem: Decodable {
        let id: String?
        let title: String?
        let subtitle: String?
        let type: String?
        let images: ContentImages?
        let resource: ArtistItemResource?
        let artists: [NowPlayingArtist]?
        let duration: String?
        let isExplicit: Bool?

        private var decodedDefaults: [String: Any]? {
            guard let defaults = resource?.defaults else { return nil }
            var b64 = defaults
            while b64.count % 4 != 0 { b64.append("=") }
            guard let data = Data(base64Encoded: b64) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        var albumId: String? { decodedDefaults?["containerId"] as? String }
        var albumName: String? { decodedDefaults?["containerName"] as? String }
    }

    struct NowPlayingArtist: Decodable {
        let id: String?
        let name: String?

        var objectId: String? {
            guard let id else { return nil }
            let base = id.firstIndex(of: "#").map { String(id[..<$0]) } ?? id
            return base.components(separatedBy: ":").last
        }
    }

    static func nowPlaying(token: String, householdId: String,
                           serviceId: String, accountId: String,
                           trackObjectId: String) async throws -> NowPlayingResponse {
        let encodedTrack = trackObjectId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trackObjectId
        let urlStr = "\(playBaseURL.replacingOccurrences(of: "/v1", with: "/v2"))" +
            "/households/\(householdId)/services/\(serviceId)" +
            "/accounts/\(accountId)/tracks/\(encodedTrack)/nowplaying"

        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        SonosLog.debug(.cloudAPI, "nowPlaying GET \(urlStr.prefix(200))")

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        SonosLog.debug(.cloudAPI, "nowPlaying HTTP \(statusCode), \(data.count) bytes")

        if statusCode == 401 { throw SonosCloudError.unauthorized }
        if !(200...299).contains(statusCode) {
            throw SonosCloudError.httpError(statusCode)
        }

        return try JSONDecoder().decode(NowPlayingResponse.self, from: data)
    }

    // MARK: - Networking

    private static func get(path: String, token: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw SonosCloudError.unauthorized
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SonosCloudError.httpError(http.statusCode)
        }
        return data
    }
}

enum SonosCloudError: Error, LocalizedError {
    case unauthorized
    case httpError(Int)
    case noHousehold
    case groupNotFound

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Sonos Cloud session expired. Please reconnect."
        case .httpError(let code): "Sonos Cloud API error (\(code))"
        case .noHousehold: "No Sonos household found."
        case .groupNotFound: "Could not find matching Sonos group."
        }
    }
}
