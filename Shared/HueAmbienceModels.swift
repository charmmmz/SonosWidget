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

enum HueLiveEntertainmentRuntimeStatus: Equatable, Sendable {
    case unavailable
    case available
    case streaming
    case conflict

    var reason: String {
        switch self {
        case .unavailable:
            return "Requires NAS/Entertainment streaming runtime"
        case .available:
            return "Ready for Live Entertainment"
        case .streaming:
            return "Live Entertainment streaming"
        case .conflict:
            return "Another Hue app is using this Entertainment Area"
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

        var label: String {
            switch self {
            case .entertainmentArea:
                return "Entertainment Area"
            case .room:
                return "Room"
            case .zone:
                return "Zone"
            }
        }
    }

    let id: String
    var name: String
    var kind: Kind
    var childLightIDs: [String]

    var ambienceTarget: HueAmbienceTarget {
        switch kind {
        case .entertainmentArea:
            return .entertainmentArea(id)
        case .room:
            return .room(id)
        case .zone:
            return .zone(id)
        }
    }
}

enum HueAmbienceAreaOptions {
    static func displayAreas(from areas: [HueAreaResource]) -> [HueAreaResource] {
        let entertainmentAreas = areas.filter { $0.kind == .entertainmentArea }
        if !entertainmentAreas.isEmpty {
            return entertainmentAreas
        }

        return areas.filter { $0.kind == .room || $0.kind == .zone }
    }

    static func mapping(
        sonosID: String,
        sonosName: String,
        selectedArea: HueAreaResource,
        lights: [HueLightResource]
    ) -> HueSonosMapping {
        HueSonosMapping(
            sonosID: sonosID,
            sonosName: sonosName,
            preferredTarget: selectedArea.ambienceTarget,
            fallbackTarget: nil,
            capability: capability(for: selectedArea, lights: lights)
        )
    }

    private static func capability(
        for area: HueAreaResource,
        lights: [HueLightResource]
    ) -> HueAmbienceCapability {
        if area.kind == .entertainmentArea {
            return .liveEntertainment
        }

        let childLightIDs = Set(area.childLightIDs)
        let hasGradientLight = lights.contains { childLightIDs.contains($0.id) && $0.supportsGradient }
        return hasGradientLight ? .gradientReady : .basic
    }
}
