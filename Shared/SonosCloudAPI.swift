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
