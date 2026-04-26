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
        return try decodeOrLog(GroupsResponse.self, from: data, endpoint: "getGroups")
    }

    // MARK: - Playback Metadata

    struct CloudPlaybackMetadata: Decodable {
        let container: MetadataContainer?
        let currentItem: CurrentItem?
    }

    struct MetadataContainer: Decodable {
        let name: String?
        let type: String?
        /// Playlist / station / album artwork — served at the container level
        /// instead of the track level for some Sonos Cloud sources (e.g. line-in,
        /// radio stations, whole-playlist views where the track itself has no
        /// per-track imagery). Used as a fallback when `track.imageUrl` is nil.
        let imageUrl: String?
    }

    struct CurrentItem: Decodable {
        let track: CloudTrack?
    }

    struct CloudTrack: Decodable {
        let name: String?
        let artist: CloudArtist?
        let album: CloudAlbum?
        let quality: CloudTrackQuality?
        let imageUrl: String?
        let durationMillis: Int?
        /// Identifies which streaming service the track is coming from —
        /// Sonos embeds a `service.name` blob in the playbackMetadata
        /// response so clients can render a "playing via Apple Music" badge
        /// without having to map internal service IDs themselves.
        let service: CloudTrackService?
    }

    struct CloudTrackService: Decodable {
        let name: String?
        // NOTE: intentionally omitted here. Sonos's `playbackMetadata`
        // response sometimes emits `service.id` as a bare string ("52231")
        // and sometimes as a nested object ({objectId, serviceId, …}); a
        // strict Decodable definition crashed the whole decode with
        // "The data couldn't be read because it isn't in the correct
        // format." Since we only use `name` for the badge, not carrying
        // the id is the cheapest unblock.
    }

    struct CloudArtist: Decodable {
        let name: String?
        let imageUrl: String?
    }
    struct CloudAlbum: Decodable {
        let name: String?
        let imageUrl: String?
    }

    struct CloudTrackQuality: Decodable, Sendable {
        let codec: String?
        let lossless: Bool?
        let bitDepth: Int?
        let sampleRate: Int?
        let immersive: Bool?
    }

    static func getPlaybackMetadata(token: String, groupId: String) async throws -> CloudPlaybackMetadata {
        let data = try await get(path: "/groups/\(groupId)/playbackMetadata", token: token)
        return try decodeOrLog(CloudPlaybackMetadata.self, from: data, endpoint: "playbackMetadata")
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        SonosLog.debug(.cloudAPI, "integrations/registrations \(status), \(data.count)B")

        guard (200...299).contains(status) else {
            // Body preview only on failure — happy path used to dump 2 KB
            // of harmless JSON on every launch which buried more useful logs.
            let body = String(data: data, encoding: .utf8) ?? ""
            SonosLog.error(.cloudAPI, "integrations/registrations HTTP \(status): \(body.prefix(500))")
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

        return try await getJSON(label: "searchCatalog", urlString: urlStr,
                                 token: token, category: .cloudSearch,
                                 as: CloudSearchResponse.self)
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

        return try await getJSON(label: "searchService(\(serviceId))",
                                 urlString: urlStr, token: token,
                                 category: .cloudSearch,
                                 as: ServiceSearchResponse.self)
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

        return try await getJSON(label: "browseArtist", urlString: urlStr,
                                 token: token, as: ArtistBrowseResponse.self)
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

        return try await getJSON(label: "browseAlbum", urlString: urlStr,
                                 token: token, as: AlbumBrowseResponse.self)
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

        return try await getJSON(label: "browsePlaylist", urlString: urlStr,
                                 token: token, as: AlbumBrowseResponse.self)
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

        return try await getJSON(label: "browseContainer", urlString: urlStr,
                                 token: token, as: AlbumBrowseResponse.self)
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

        return try await getJSON(label: "nowPlaying", urlString: urlStr,
                                 token: token, timeout: 10,
                                 as: NowPlayingResponse.self)
    }

    // MARK: - Networking helpers

    /// Single point of truth for `GET … → JSON-decode` against the
    /// `play.sonos.com` content APIs. Centralising this kills the
    /// 7× copy-pasted `[cloudAPI] xxx GET …` / `[cloudAPI] xxx HTTP …`
    /// log pairs that used to live at every endpoint. On the happy path
    /// you get one debug line (`browseArtist 200, 12.3KB`); on a non-2xx
    /// the body preview is logged at error level so failures are still
    /// debuggable.
    private static func getJSON<T: Decodable>(
        label: String,
        urlString: String,
        token: String,
        timeout: TimeInterval = 15,
        category: SonosLog.Category = .cloudAPI,
        as type: T.Type
    ) async throws -> T {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        SonosLog.debug(category, "\(label) \(status), \(data.count)B")

        if status == 401 { throw SonosCloudError.unauthorized }
        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            SonosLog.error(category, "\(label) HTTP \(status): \(body.prefix(500))")
            throw SonosCloudError.httpError(status)
        }

        return try decodeOrLog(type, from: data, endpoint: label)
    }

    /// Wraps `JSONDecoder().decode(...)` with a descriptive error log that
    /// includes the first 1 KB of the response body when decoding fails.
    /// Makes the otherwise-opaque "The data couldn't be read because it
    /// isn't in the correct format." error actionable — we immediately see
    /// which endpoint + which bytes tripped it up.
    fileprivate static func decodeOrLog<T: Decodable>(
        _ type: T.Type, from data: Data, endpoint: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(1024) ?? ""
            SonosLog.error(.cloudAPI, "decode failed for \(endpoint): \(error)")
            SonosLog.error(.cloudAPI, "body: \(bodyPreview)")
            throw error
        }
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

    // MARK: - Control POST helper

    /// POST a JSON-body command against the Sonos Control API. `body` may be
    /// `nil` for commands that take no arguments (most transport verbs).
    /// Returns the raw response data (many endpoints respond 200 with `{}` or
    /// 204 with no body — caller usually ignores it).
    @discardableResult
    private static func postControl(path: String, token: String,
                                    body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 { throw SonosCloudError.unauthorized }
        guard (200...299).contains(status) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            SonosLog.error(.cloudAPI, "POST \(path) → HTTP \(status): \(bodyStr.prefix(500))")
            throw SonosCloudError.httpError(status)
        }
        return data
    }

    // MARK: - Transport Control (POST /groups/{gid}/playback/*)

    static func play(token: String, groupId: String) async throws {
        try await postControl(path: "/groups/\(groupId)/playback/play", token: token)
    }

    static func pause(token: String, groupId: String) async throws {
        try await postControl(path: "/groups/\(groupId)/playback/pause", token: token)
    }

    static func togglePlayPause(token: String, groupId: String) async throws {
        try await postControl(path: "/groups/\(groupId)/playback/togglePlayPause", token: token)
    }

    static func skipToNextTrack(token: String, groupId: String) async throws {
        try await postControl(path: "/groups/\(groupId)/playback/skipToNextTrack", token: token)
    }

    static func skipToPreviousTrack(token: String, groupId: String) async throws {
        try await postControl(path: "/groups/\(groupId)/playback/skipToPreviousTrack", token: token)
    }

    /// Seek within the current track. Position is in **milliseconds**.
    static func seek(token: String, groupId: String, positionMillis: Int) async throws {
        try await postControl(
            path: "/groups/\(groupId)/playback/seek",
            token: token,
            body: ["positionMillis": positionMillis])
    }

    // MARK: - Volume

    /// Set group-level volume (0–100).
    static func setGroupVolume(token: String, groupId: String, volume: Int) async throws {
        let clamped = max(0, min(100, volume))
        try await postControl(
            path: "/groups/\(groupId)/groupVolume",
            token: token,
            body: ["volume": clamped])
    }

    /// Read-side counterpart to `setGroupVolume`. Used to populate the
    /// per-group volume slider on non-selected cards when in cloud mode,
    /// where we don't have LAN access to per-speaker volume.
    struct GroupVolume: Decodable {
        let volume: Int?
        let muted: Bool?
        /// `"FIXED"` / `"VARIABLE"` — players that output to fixed-level
        /// line-in can't be volume-controlled. We just surface whatever
        /// the API returns; the app rarely needs to inspect this.
        let fixed: Bool?
    }

    static func getGroupVolume(token: String, groupId: String) async throws -> GroupVolume {
        let data = try await get(path: "/groups/\(groupId)/groupVolume", token: token)
        return try decodeOrLog(GroupVolume.self, from: data, endpoint: "groupVolume")
    }

    /// Set single-player volume (0–100).
    static func setPlayerVolume(token: String, playerId: String, volume: Int) async throws {
        let clamped = max(0, min(100, volume))
        try await postControl(
            path: "/players/\(playerId)/playerVolume",
            token: token,
            body: ["volume": clamped])
    }

    static func setGroupMuted(token: String, groupId: String, muted: Bool) async throws {
        try await postControl(
            path: "/groups/\(groupId)/groupVolume/mute",
            token: token,
            body: ["muted": muted])
    }

    // MARK: - Lightweight Transport Status (GET /groups/{gid}/playback)

    /// Subset of fields returned by `GET /groups/{gid}/playback`. Much cheaper
    /// than `getPlaybackMetadata` — use this for the 5s cloud polling cadence.
    struct PlaybackStatus: Decodable {
        /// `"PLAYBACK_STATE_PLAYING"` / `"..._PAUSED"` / `"..._IDLE"` / `"..._BUFFERING"`.
        let playbackState: String?
        /// Current position within the track, milliseconds.
        let positionMillis: Int?
        /// Available play modes (shuffle / repeat etc.).
        let playModes: PlayModes?

        struct PlayModes: Decodable {
            let repeatMode: String?
            let repeatOne: Bool?
            let shuffle: Bool?
            let crossfade: Bool?
        }
    }

    static func getPlaybackStatus(token: String, groupId: String) async throws -> PlaybackStatus {
        let data = try await get(path: "/groups/\(groupId)/playback", token: token)
        return try decodeOrLog(PlaybackStatus.self, from: data, endpoint: "playback")
    }

    // MARK: - Favorites (household-scoped, Control API)

    struct CloudFavorite: Decodable, Identifiable {
        let id: String
        let name: String
        let description: String?
        let imageUrl: String?
        let service: Service?
        let resource: FavoriteResource?

        struct Service: Decodable {
            let name: String?
            /// Some households return `service.id` as a bare string like
            /// `"52231"` (the service type), others as the richer
            /// `universalMusicObjectId` dictionary. Decode both shapes
            /// into the same struct so either kind of favorite list
            /// parses successfully.
            let id: ServiceId?

            struct ServiceId: Decodable {
                let accountId: String?
                let objectId: String?
                let serviceId: String?

                init(from decoder: Decoder) throws {
                    if let container = try? decoder.singleValueContainer(),
                       let str = try? container.decode(String.self) {
                        self.accountId = nil
                        self.objectId = nil
                        self.serviceId = str
                        return
                    }
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    self.accountId = try c.decodeIfPresent(String.self, forKey: .accountId)
                    self.objectId = try c.decodeIfPresent(String.self, forKey: .objectId)
                    self.serviceId = try c.decodeIfPresent(String.self, forKey: .serviceId)
                }

                private enum CodingKeys: String, CodingKey {
                    case accountId, objectId, serviceId
                }
            }
        }

        struct FavoriteResource: Decodable {
            let type: String?
            let name: String?
        }
    }

    private struct FavoritesResponse: Decodable {
        let version: String?
        let items: [CloudFavorite]
    }

    static func listFavorites(token: String, householdId: String) async throws -> [CloudFavorite] {
        let data = try await get(path: "/households/\(householdId)/favorites", token: token)
        return try JSONDecoder().decode(FavoritesResponse.self, from: data).items
    }

    /// Start playing a favorite on the given group. `playOnCompletion` controls
    /// whether playback auto-starts after the load (default true, matches the
    /// Sonos app's tap-to-play behavior).
    static func loadFavorite(token: String, groupId: String, favoriteId: String,
                             playOnCompletion: Bool = true) async throws {
        try await postControl(
            path: "/groups/\(groupId)/favorites",
            token: token,
            body: [
                "favoriteId": favoriteId,
                "playOnCompletion": playOnCompletion
            ])
    }

    // MARK: - Playlists (Sonos-managed household playlists)

    /// Load a Sonos-managed playlist (from `SQ:` on LAN, household-scoped on
    /// cloud). `action`: `"REPLACE"` (clear queue) / `"APPEND"` / `"INSERT"` /
    /// `"INSERT_NEXT"`. Default REPLACE matches the "play now" semantics the
    /// app uses elsewhere.
    static func loadPlaylist(token: String, groupId: String, playlistId: String,
                             action: String = "REPLACE",
                             playOnCompletion: Bool = true) async throws {
        try await postControl(
            path: "/groups/\(groupId)/playlists",
            token: token,
            body: [
                "playlistId": playlistId,
                "action": action,
                "playOnCompletion": playOnCompletion
            ])
    }

    // MARK: - Load Stream URL (artist station / arbitrary stream)

    /// Push an arbitrary stream URI to the group. Used as the remote-mode
    /// equivalent of `SetAVTransportURI` — in particular for `x-sonosapi-radio:`
    /// station URIs constructed by `SearchManager.startStation`. Sonos may
    /// refuse non-standard schemes; caller should fall back to LAN when this
    /// errors.
    static func loadStreamUrl(token: String, groupId: String, streamUrl: String,
                              itemId: String? = nil,
                              playOnCompletion: Bool = true) async throws {
        var body: [String: Any] = [
            "streamUrl": streamUrl,
            "playOnCompletion": playOnCompletion
        ]
        if let itemId { body["itemId"] = itemId }
        try await postControl(
            path: "/groups/\(groupId)/playbackSession/loadStreamUrl",
            token: token,
            body: body)
    }

    // MARK: - Grouping

    /// Create a new group from a list of players. Returns the new group id
    /// embedded in the response body.
    struct CreateGroupResponse: Decodable {
        let group: CloudGroup
    }

    @discardableResult
    static func createGroup(token: String, householdId: String,
                            playerIds: [String],
                            musicContextGroupId: String? = nil) async throws -> CreateGroupResponse {
        var body: [String: Any] = ["playerIds": playerIds]
        if let musicContextGroupId { body["musicContextGroupId"] = musicContextGroupId }
        let data = try await postControl(
            path: "/households/\(householdId)/groups/createGroup",
            token: token,
            body: body)
        return try JSONDecoder().decode(CreateGroupResponse.self, from: data)
    }

    /// Replace the full member list of an existing group. Simpler than
    /// `modifyGroupMembers` (add/remove deltas) and covers our grouping UI.
    static func setGroupMembers(token: String, groupId: String,
                                playerIds: [String]) async throws {
        try await postControl(
            path: "/groups/\(groupId)/groups/setGroupMembers",
            token: token,
            body: ["playerIds": playerIds])
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
