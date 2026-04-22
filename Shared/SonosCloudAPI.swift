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

    struct CloudMusicServiceAccount: Decodable {
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
        print("[CloudAPI] integrations/registrations → HTTP \(status), \(data.count)B: \(text.prefix(2000))")

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
        print("[CloudAPI] Could not parse integrations/registrations response")
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

    /// Search across all linked music services via the Sonos Cloud (play.sonos.com).
    /// `serviceAccounts` should be the array from `getMusicServiceAccounts`.
    static func searchCatalog(token: String, householdId: String, term: String,
                              serviceIds: [String]) async throws -> CloudSearchResponse {
        let idsParam = serviceIds.joined(separator: ",")
        let encodedTerm = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term

        let urlStr = "\(playBaseURL)/households/\(householdId)/search" +
            "?query=\(encodedTerm)&services=\(idsParam)"

        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        print("[CloudSearch] GET \(urlStr.prefix(200))")

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        print("[CloudSearch] HTTP \(statusCode), \(data.count) bytes")

        if statusCode == 401 { throw SonosCloudError.unauthorized }
        if !(200...299).contains(statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[CloudSearch] Error body: \(body.prefix(500))")
            throw SonosCloudError.httpError(statusCode)
        }

        return try JSONDecoder().decode(CloudSearchResponse.self, from: data)
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
