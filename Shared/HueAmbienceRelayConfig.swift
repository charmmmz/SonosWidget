import Foundation

enum HueAmbienceRelayConfigError: Error, LocalizedError, Equatable {
    case missingBridge
    case missingApplicationKey

    var errorDescription: String? {
        switch self {
        case .missingBridge:
            return "Pair a Hue Bridge before syncing Music Ambience to the NAS relay."
        case .missingApplicationKey:
            return "Hue Bridge application key is missing. Pair the Bridge again before syncing to NAS."
        }
    }
}

struct HueAmbienceRelayConfig: Encodable, Sendable {
    let schemaVersion: Int
    let enabled: Bool
    let bridge: HueBridgeInfo
    let applicationKey: String
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
        flowIntervalSeconds: Double = 8
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
        self.bridge = bridge
        self.applicationKey = applicationKey
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
        self.flowIntervalSeconds = flowIntervalSeconds
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
        self.includedLightIDs = mapping.includedLightIDs.sorted()
        self.excludedLightIDs = mapping.excludedLightIDs.sorted()
        self.capability = mapping.capability
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
            let bridge: Bridge?
            let mappings: Int?
            let lights: Int?
            let areas: Int?
            let runtimeActive: Bool?
            let activeGroupId: String?
            let lastError: String?
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
                enabled: response.status.enabled != false
            )
        } catch {
            hueAmbienceSyncStatus = .failed(error.localizedDescription)
        }
    }
}
