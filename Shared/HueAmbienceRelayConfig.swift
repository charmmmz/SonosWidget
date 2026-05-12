import Foundation

enum HueAmbienceRelayConfigError: Error, LocalizedError, Equatable {
    case missingBridge
    case missingApplicationKey

    var errorDescription: String? {
        switch self {
        case .missingBridge:
            return "Pair a Hue Bridge before syncing Hue Ambience to the NAS relay."
        case .missingApplicationKey:
            return "Hue Bridge application key is missing. Pair the Bridge again before syncing to NAS."
        }
    }
}

struct HueAmbienceRelayConfig: Encodable, Sendable {
    let schemaVersion: Int
    let enabled: Bool
    let cs2LightingEnabled: Bool
    let bridge: HueBridgeInfo
    let applicationKey: String
    let streamingClientKey: String?
    let streamingApplicationId: String?
    let resources: HueBridgeResources
    let mappings: [HueAmbienceRelayMapping]
    let groupStrategy: HueGroupSyncStrategy
    let stopBehavior: HueAmbienceStopBehavior
    let motionStyle: HueAmbienceMotionStyle
    let flowIntervalSeconds: Double

    @MainActor
    init(
        store: HueAmbienceStore,
        credentialStore: HueCredentialStore = HueCredentialStore(),
        sonosSpeakers: [SonosPlayer],
        flowIntervalSeconds: Double? = nil
    ) throws {
        guard let bridge = store.bridge else {
            throw HueAmbienceRelayConfigError.missingBridge
        }
        guard let applicationKey = credentialStore.applicationKey(forBridgeID: bridge.id),
              !applicationKey.isEmpty else {
            throw HueAmbienceRelayConfigError.missingApplicationKey
        }

        let speakersByID = sonosSpeakers.reduce(into: [String: SonosPlayer]()) { result, speaker in
            result[speaker.id] = speaker
        }

        self.schemaVersion = 1
        self.enabled = store.isEnabled
        self.cs2LightingEnabled = store.isCS2SyncEnabled
        self.bridge = bridge
        self.applicationKey = applicationKey
        self.streamingClientKey = credentialStore.streamingClientKey(forBridgeID: bridge.id)
        self.streamingApplicationId = credentialStore.streamingApplicationId(forBridgeID: bridge.id)
        self.resources = store.hueResources
        self.mappings = store.mappings.map { mapping in
            HueAmbienceRelayMapping(
                mapping: mapping,
                relayGroupID: speakersByID[mapping.sonosID]?.playbackIP
            )
        }
        self.groupStrategy = store.groupStrategy
        self.stopBehavior = store.stopBehavior
        self.motionStyle = store.motionStyle
        self.flowIntervalSeconds = flowIntervalSeconds ?? store.flowSpeed.intervalSeconds
    }
}

struct HueAmbienceRelayMapping: Encodable, Equatable, Sendable {
    let sonosID: String
    let sonosName: String
    let relayGroupID: String?
    let preferredTarget: HueAmbienceRelayTarget?
    let fallbackTarget: HueAmbienceRelayTarget?
    let includedLightIDs: [String]
    let excludedLightIDs: [String]
    let capability: HueAmbienceCapability

    init(mapping: HueSonosMapping, relayGroupID: String?) {
        self.sonosID = mapping.sonosID
        self.sonosName = mapping.sonosName
        self.relayGroupID = relayGroupID
        self.preferredTarget = mapping.preferredTarget.map(HueAmbienceRelayTarget.init)
        self.fallbackTarget = mapping.fallbackTarget.map(HueAmbienceRelayTarget.init)
        if mapping.effectiveRelayTarget?.isEntertainmentArea == true {
            self.includedLightIDs = []
            self.excludedLightIDs = []
        } else {
            self.includedLightIDs = mapping.includedLightIDs.sorted()
            self.excludedLightIDs = mapping.excludedLightIDs.sorted()
        }
        self.capability = mapping.capability
    }
}

private extension HueSonosMapping {
    var effectiveRelayTarget: HueAmbienceTarget? {
        if preferredTarget?.isLegacyDirectLightTarget == true {
            return fallbackTarget
        }
        return preferredTarget ?? fallbackTarget
    }
}

struct HueAmbienceRelayTarget: Encodable, Equatable, Sendable {
    let kind: String
    let id: String

    init(target: HueAmbienceTarget) {
        switch target {
        case .entertainmentArea(let id):
            self.kind = "entertainmentArea"
            self.id = id
        case .room(let id):
            self.kind = "room"
            self.id = id
        case .zone(let id):
            self.kind = "zone"
            self.id = id
        case .light(let id):
            self.kind = "light"
            self.id = id
        }
    }
}

extension RelayClient {
    struct HueAmbienceStatusResponse: Decodable, Sendable {
        struct Status: Decodable, Sendable {
            struct Bridge: Decodable, Sendable {
                let id: String
                let ipAddress: String
                let name: String
            }

            let configured: Bool
            let enabled: Bool?
            let cs2LightingEnabled: Bool?
            let bridge: Bridge?
            let mappings: Int?
            let lights: Int?
            let areas: Int?
            let runtimeActive: Bool?
            let activeGroupId: String?
            let renderMode: HueAmbienceRelayRenderMode?
            let activeTargetIds: [String]?
            let entertainmentTargetActive: Bool?
            let entertainmentMetadataComplete: Bool?
            let lastFrameAt: String?
            let lastError: String?

            private enum CodingKeys: String, CodingKey {
                case configured
                case enabled
                case cs2LightingEnabled
                case bridge
                case mappings
                case lights
                case areas
                case runtimeActive
                case activeGroupId
                case renderMode
                case activeTargetIds
                case entertainmentTargetActive
                case entertainmentMetadataComplete
                case lastFrameAt
                case lastError
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                configured = try container.decode(Bool.self, forKey: .configured)
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
                cs2LightingEnabled = try container.decodeIfPresent(Bool.self, forKey: .cs2LightingEnabled)
                bridge = try container.decodeIfPresent(Bridge.self, forKey: .bridge)
                mappings = try container.decodeIfPresent(Int.self, forKey: .mappings)
                lights = try container.decodeIfPresent(Int.self, forKey: .lights)
                areas = try container.decodeIfPresent(Int.self, forKey: .areas)
                runtimeActive = try container.decodeIfPresent(Bool.self, forKey: .runtimeActive)
                activeGroupId = try container.decodeIfPresent(String.self, forKey: .activeGroupId)
                renderMode = try container
                    .decodeIfPresent(String.self, forKey: .renderMode)
                    .flatMap(HueAmbienceRelayRenderMode.init(rawValue:))
                activeTargetIds = try container.decodeIfPresent([String].self, forKey: .activeTargetIds)
                entertainmentTargetActive = try container.decodeIfPresent(Bool.self, forKey: .entertainmentTargetActive)
                entertainmentMetadataComplete = try container.decodeIfPresent(Bool.self, forKey: .entertainmentMetadataComplete)
                lastFrameAt = try container.decodeIfPresent(String.self, forKey: .lastFrameAt)
                lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
            }
        }

        let ok: Bool
        let status: Status
    }

    static func hueAmbienceStatus(baseURL: URL) async throws -> HueAmbienceStatusResponse {
        let url = baseURL.appendingPathComponent("/api/hue-ambience/status")
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(HueAmbienceStatusResponse.self, from: data)
    }

    static func putHueAmbienceConfig(
        baseURL: URL,
        config: HueAmbienceRelayConfig
    ) async throws {
        let url = baseURL.appendingPathComponent("/api/hue-ambience/config")
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(config)
        let (_, response) = try await noProxySession.data(for: request)
        try validate(response)
    }

    static func deleteHueAmbienceConfig(baseURL: URL) async throws {
        let url = baseURL.appendingPathComponent("/api/hue-ambience/config")
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "DELETE"
        let (_, response) = try await noProxySession.data(for: request)
        try validate(response)
    }
}

@MainActor
extension RelayManager {
    func pushHueAmbienceConfig(
        store: HueAmbienceStore = .shared,
        sonosSpeakers: [SonosPlayer]
    ) async {
        guard let url else {
            hueAmbienceSyncStatus = .failed("Configure NAS Relay URL first")
            return
        }

        hueAmbienceSyncStatus = .syncing
        do {
            let config = try HueAmbienceRelayConfig(
                store: store,
                sonosSpeakers: sonosSpeakers
            )
            try await RelayClient.putHueAmbienceConfig(baseURL: url, config: config)
            updateHueAmbienceRuntimeStatus(configured: true, enabled: config.enabled)
            updateCS2LightingStatus(enabled: config.cs2LightingEnabled)
        } catch {
            hueAmbienceSyncStatus = .failed(error.localizedDescription)
        }
    }

    func clearHueAmbienceConfig() async {
        guard let url else {
            hueAmbienceSyncStatus = .idle
            return
        }

        hueAmbienceSyncStatus = .syncing
        do {
            try await RelayClient.deleteHueAmbienceConfig(baseURL: url)
            updateHueAmbienceRuntimeStatus(configured: false)
            updateCS2LightingStatus(enabled: false)
            hueAmbienceSyncStatus = .idle
        } catch {
            hueAmbienceSyncStatus = .failed(error.localizedDescription)
        }
    }

    func refreshHueAmbienceStatus() async {
        guard let url else {
            hueAmbienceSyncStatus = .idle
            return
        }

        do {
            let response = try await RelayClient.hueAmbienceStatus(baseURL: url)
            updateHueAmbienceRuntimeStatus(
                configured: response.status.configured,
                enabled: response.status.enabled != false,
                renderMode: response.status.renderMode,
                runtimeActive: response.status.runtimeActive,
                activeTargetIds: response.status.activeTargetIds,
                entertainmentTargetActive: response.status.entertainmentTargetActive,
                entertainmentMetadataComplete: response.status.entertainmentMetadataComplete,
                lastFrameAt: response.status.lastFrameAt,
                lastError: response.status.lastError
            )
            if let cs2LightingEnabled = response.status.cs2LightingEnabled {
                updateCS2LightingStatus(enabled: cs2LightingEnabled)
            }
        } catch {
            hueAmbienceSyncStatus = .failed(error.localizedDescription)
        }
    }
}
