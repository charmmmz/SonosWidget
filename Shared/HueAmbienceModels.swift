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

enum HueAmbienceMotionStyle: String, Codable, Equatable, Sendable, CaseIterable {
    case flowing
    case still

    static let `default`: HueAmbienceMotionStyle = .flowing

    var label: String {
        switch self {
        case .flowing:
            return "Flowing"
        case .still:
            return "Still"
        }
    }

    var description: String {
        switch self {
        case .flowing:
            return "Slowly rotates album colors across the selected Hue lights while the app is active."
        case .still:
            return "Applies the current album colors once per track."
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
    var includedLightIDs: Set<String>
    var excludedLightIDs: Set<String>
    var capability: HueAmbienceCapability

    init(
        sonosID: String,
        sonosName: String,
        preferredTarget: HueAmbienceTarget? = nil,
        fallbackTarget: HueAmbienceTarget? = nil,
        includedLightIDs: Set<String> = [],
        excludedLightIDs: Set<String> = [],
        capability: HueAmbienceCapability = .basic
    ) {
        self.sonosID = sonosID
        self.sonosName = sonosName
        self.preferredTarget = preferredTarget
        self.fallbackTarget = fallbackTarget
        self.includedLightIDs = includedLightIDs
        self.excludedLightIDs = excludedLightIDs
        self.capability = capability
    }

    private enum CodingKeys: String, CodingKey {
        case sonosID
        case sonosName
        case preferredTarget
        case fallbackTarget
        case includedLightIDs
        case excludedLightIDs
        case capability
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sonosID = try container.decode(String.self, forKey: .sonosID)
        sonosName = try container.decode(String.self, forKey: .sonosName)
        preferredTarget = try container.decodeIfPresent(HueAmbienceTarget.self, forKey: .preferredTarget)
        fallbackTarget = try container.decodeIfPresent(HueAmbienceTarget.self, forKey: .fallbackTarget)
        includedLightIDs = try container.decodeIfPresent(Set<String>.self, forKey: .includedLightIDs) ?? []
        excludedLightIDs = try container.decodeIfPresent(Set<String>.self, forKey: .excludedLightIDs) ?? []
        capability = try container.decodeIfPresent(HueAmbienceCapability.self, forKey: .capability) ?? .basic
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

enum HueLightFunction: String, Codable, Equatable, Sendable, CaseIterable {
    case decorative
    case functional
    case mixed
    case unknown

    init(apiValue: String?) {
        let normalizedValue = apiValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")

        switch normalizedValue {
        case "decorative", "decoration", "for_decoration":
            self = .decorative
        case "functional", "task", "tasks", "for_task", "for_tasks":
            self = .functional
        case "mixed":
            self = .mixed
        default:
            self = .unknown
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(apiValue: try? container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var label: String {
        switch self {
        case .decorative:
            return "Decoration"
        case .functional:
            return "Task"
        case .mixed:
            return "Mixed"
        case .unknown:
            return "Unknown"
        }
    }

    var participatesInAmbienceByDefault: Bool {
        self != .functional
    }
}

struct HueLightResource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var ownerID: String?
    var supportsColor: Bool
    var supportsGradient: Bool
    var supportsEntertainment: Bool
    var function: HueLightFunction
    var functionMetadataResolved: Bool

    init(
        id: String,
        name: String,
        ownerID: String?,
        supportsColor: Bool,
        supportsGradient: Bool,
        supportsEntertainment: Bool,
        function: HueLightFunction = .unknown,
        functionMetadataResolved: Bool = true
    ) {
        self.id = id
        self.name = name
        self.ownerID = ownerID
        self.supportsColor = supportsColor
        self.supportsGradient = supportsGradient
        self.supportsEntertainment = supportsEntertainment
        self.function = function
        self.functionMetadataResolved = functionMetadataResolved
    }

    var participatesInAmbienceByDefault: Bool {
        functionMetadataResolved && function.participatesInAmbienceByDefault
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerID
        case supportsColor
        case supportsGradient
        case supportsEntertainment
        case function
        case functionMetadataResolved
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        ownerID = try container.decodeIfPresent(String.self, forKey: .ownerID)
        supportsColor = try container.decode(Bool.self, forKey: .supportsColor)
        supportsGradient = try container.decode(Bool.self, forKey: .supportsGradient)
        supportsEntertainment = try container.decode(Bool.self, forKey: .supportsEntertainment)
        function = try container.decodeIfPresent(HueLightFunction.self, forKey: .function) ?? .unknown
        functionMetadataResolved = try container.decodeIfPresent(
            Bool.self,
            forKey: .functionMetadataResolved
        ) ?? false
    }
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
