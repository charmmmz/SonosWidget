import Foundation

struct HueBridgeInfo: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var ipAddress: String
    var name: String

    var baseURL: URL? {
        URL(string: "https://\(ipAddress)")
    }
}

enum HueAmbienceTarget: Codable, Equatable, Hashable, Sendable {
    case entertainmentArea(String)
    case room(String)
    case zone(String)

    var id: String {
        switch self {
        case .entertainmentArea(let id), .room(let id), .zone(let id):
            return id
        }
    }

    var isEntertainmentArea: Bool {
        if case .entertainmentArea = self { return true }
        return false
    }
}

enum HueAmbienceCapability: String, Codable, Equatable, Sendable, CaseIterable {
    case basic
    case gradientReady
    case liveEntertainment

    var label: String {
        switch self {
        case .basic: return "Basic"
        case .gradientReady: return "Gradient Ready"
        case .liveEntertainment: return "Live Entertainment"
        }
    }
}

enum HueGroupSyncStrategy: String, Codable, Equatable, Sendable, CaseIterable {
    case allMappedRooms
    case coordinatorOnly

    static let `default`: HueGroupSyncStrategy = .allMappedRooms

    var label: String {
        switch self {
        case .allMappedRooms: return "All mapped rooms"
        case .coordinatorOnly: return "Coordinator only"
        }
    }
}

enum HueAmbienceStopBehavior: String, Codable, Equatable, Sendable, CaseIterable {
    case leaveCurrent
    case turnOff

    static let `default`: HueAmbienceStopBehavior = .leaveCurrent

    var label: String {
        switch self {
        case .leaveCurrent: return "Leave ambience"
        case .turnOff: return "Turn off synced lights"
        }
    }
}

struct HueSonosMapping: Codable, Equatable, Identifiable, Sendable {
    var id: String { sonosID }
    var sonosID: String
    var sonosName: String
    var preferredTarget: HueAmbienceTarget?
    var fallbackTarget: HueAmbienceTarget?
    var excludedLightIDs: Set<String>
    var capability: HueAmbienceCapability

    init(
        sonosID: String,
        sonosName: String,
        preferredTarget: HueAmbienceTarget? = nil,
        fallbackTarget: HueAmbienceTarget? = nil,
        excludedLightIDs: Set<String> = [],
        capability: HueAmbienceCapability = .basic
    ) {
        self.sonosID = sonosID
        self.sonosName = sonosName
        self.preferredTarget = preferredTarget
        self.fallbackTarget = fallbackTarget
        self.excludedLightIDs = excludedLightIDs
        self.capability = capability
    }
}

struct HueAmbiencePlaybackSnapshot: Equatable, Sendable {
    var selectedSonosID: String?
    var selectedSonosName: String?
    var groupMemberIDs: [String]
    var groupMemberNamesByID: [String: String]
    var trackTitle: String?
    var artist: String?
    var albumArtURL: String?
    var isPlaying: Bool
    var albumArtImage: Data?
}

struct HueLightResource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var ownerID: String?
    var supportsColor: Bool
    var supportsGradient: Bool
    var supportsEntertainment: Bool
}

struct HueAreaResource: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case entertainmentArea
        case room
        case zone
    }

    let id: String
    var name: String
    var kind: Kind
    var childLightIDs: [String]
}
