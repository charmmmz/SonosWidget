import XCTest
@testable import SonosWidget

@MainActor
final class HueAmbienceRelayConfigTests: XCTestCase {
    func testRelayConfigEncodesRelayGroupIDAndFlatHueTarget() throws {
        let suiteName = "HueAmbienceRelayConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HueAmbienceStore(storage: HueAmbienceDefaults(defaults: defaults))
        store.isEnabled = true
        store.isCS2SyncEnabled = true
        store.flowSpeed = .fast
        store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.50.216", name: "Hue Bridge")
        store.updateResources(HueBridgeResources(
            lights: [
                HueLightResource(
                    id: "light-1",
                    name: "Gradient",
                    ownerID: nil,
                    supportsColor: true,
                    supportsGradient: true,
                    supportsEntertainment: true,
                    function: .decorative,
                    functionMetadataResolved: true
                )
            ],
            areas: [
                HueAreaResource(
                    id: "ent-1",
                    name: "PC",
                    kind: .entertainmentArea,
                    childLightIDs: ["light-1"],
                    entertainmentChannels: [
                        HueEntertainmentChannelResource(id: "0", lightID: "light-1", serviceID: "svc-1")
                    ]
                )
            ]
        ))
        store.upsertMapping(HueSonosMapping(
            sonosID: "RINCON_playroom",
            sonosName: "Playroom",
            preferredTarget: .entertainmentArea("ent-1"),
            includedLightIDs: ["light-1"],
            excludedLightIDs: [],
            capability: .liveEntertainment
        ))

        let credentials = InMemoryHueRelayCredentialStorage()
        let credentialStore = HueCredentialStore(storage: credentials)
        credentialStore.saveApplicationKey("hue-secret", forBridgeID: "bridge-1")
        credentialStore.saveStreamingClientKey("streaming-secret", forBridgeID: "bridge-1")
        credentialStore.saveStreamingApplicationId("streaming-app-id", forBridgeID: "bridge-1")

        let config = try HueAmbienceRelayConfig(
            store: store,
            credentialStore: credentialStore,
            sonosSpeakers: [
                SonosPlayer(
                    id: "RINCON_playroom",
                    name: "Playroom",
                    ipAddress: "192.168.50.25",
                    isCoordinator: true
                )
            ]
        )
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mappings = try XCTUnwrap(object["mappings"] as? [[String: Any]])
        let firstMapping = try XCTUnwrap(mappings.first)
        let preferredTarget = try XCTUnwrap(firstMapping["preferredTarget"] as? [String: Any])

        XCTAssertEqual(object["applicationKey"] as? String, "hue-secret")
        XCTAssertEqual(object["streamingClientKey"] as? String, "streaming-secret")
        XCTAssertEqual(object["streamingApplicationId"] as? String, "streaming-app-id")
        XCTAssertEqual(firstMapping["relayGroupID"] as? String, "192.168.50.25")
        XCTAssertEqual(preferredTarget["kind"] as? String, "entertainmentArea")
        XCTAssertEqual(preferredTarget["id"] as? String, "ent-1")
        XCTAssertEqual(object["flowIntervalSeconds"] as? Double, 4)
        XCTAssertEqual(object["cs2LightingEnabled"] as? Bool, true)

        let resources = try XCTUnwrap(object["resources"] as? [String: Any])
        let areas = try XCTUnwrap(resources["areas"] as? [[String: Any]])
        let firstArea = try XCTUnwrap(areas.first)
        let entertainmentChannels = try XCTUnwrap(firstArea["entertainmentChannels"] as? [[String: Any]])
        let firstChannel = try XCTUnwrap(entertainmentChannels.first)

        XCTAssertEqual(firstChannel["id"] as? String, "0")
        XCTAssertEqual(firstChannel["lightID"] as? String, "light-1")
        XCTAssertEqual(firstChannel["serviceID"] as? String, "svc-1")
    }

    func testRelayConfigDoesNotEncodeEntertainmentLightOverrides() throws {
        let suiteName = "HueAmbienceRelayConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HueAmbienceStore(storage: HueAmbienceDefaults(defaults: defaults))
        let bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.2", name: "Hue Bridge")
        store.bridge = bridge
        store.updateResources(HueBridgeResources(
            lights: [
                HueLightResource(
                    id: "task-light",
                    name: "Task Lamp",
                    ownerID: "device-1",
                    supportsColor: true,
                    supportsGradient: false,
                    supportsEntertainment: true,
                    function: .functional,
                    functionMetadataResolved: true
                )
            ],
            areas: [
                HueAreaResource(
                    id: "ent-1",
                    name: "Playroom Area",
                    kind: .entertainmentArea,
                    childLightIDs: ["task-light"],
                    childDeviceIDs: ["device-1"]
                )
            ]
        ))
        store.upsertMapping(HueSonosMapping(
            sonosID: "playroom",
            sonosName: "Playroom",
            preferredTarget: .entertainmentArea("ent-1"),
            includedLightIDs: ["task-light"],
            excludedLightIDs: ["task-light"],
            capability: .liveEntertainment
        ))

        let credentials = InMemoryHueRelayCredentialStorage()
        let credentialStore = HueCredentialStore(storage: credentials)
        credentialStore.saveApplicationKey("secret", forBridgeID: bridge.id)

        let config = try HueAmbienceRelayConfig(
            store: store,
            credentialStore: credentialStore,
            sonosSpeakers: []
        )
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mappings = try XCTUnwrap(object["mappings"] as? [[String: Any]])
        let mapping = try XCTUnwrap(mappings.first)

        XCTAssertEqual(mapping["includedLightIDs"] as? [String], [])
        XCTAssertEqual(mapping["excludedLightIDs"] as? [String], [])
    }

    func testRelayConfigClearsOverridesWhenFallbackEntertainmentAreaIsEffective() throws {
        let suiteName = "HueAmbienceRelayConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HueAmbienceStore(storage: HueAmbienceDefaults(defaults: defaults))
        let bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.2", name: "Hue Bridge")
        store.bridge = bridge
        store.upsertMapping(HueSonosMapping(
            sonosID: "playroom",
            sonosName: "Playroom",
            preferredTarget: .light("legacy-light"),
            fallbackTarget: .entertainmentArea("ent-1"),
            includedLightIDs: ["task-light"],
            excludedLightIDs: ["task-light"],
            capability: .liveEntertainment
        ))

        let credentials = InMemoryHueRelayCredentialStorage()
        let credentialStore = HueCredentialStore(storage: credentials)
        credentialStore.saveApplicationKey("secret", forBridgeID: bridge.id)

        let config = try HueAmbienceRelayConfig(
            store: store,
            credentialStore: credentialStore,
            sonosSpeakers: []
        )
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mappings = try XCTUnwrap(object["mappings"] as? [[String: Any]])
        let mapping = try XCTUnwrap(mappings.first)

        XCTAssertEqual(mapping["includedLightIDs"] as? [String], [])
        XCTAssertEqual(mapping["excludedLightIDs"] as? [String], [])
    }

    func testRelayConfigRequiresStoredApplicationKey() {
        let suiteName = "HueAmbienceRelayConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HueAmbienceStore(storage: HueAmbienceDefaults(defaults: defaults))
        store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.50.216", name: "Hue Bridge")

        XCTAssertThrowsError(try HueAmbienceRelayConfig(
            store: store,
            credentialStore: HueCredentialStore(storage: InMemoryHueRelayCredentialStorage()),
            sonosSpeakers: []
        )) { error in
            XCTAssertEqual(error as? HueAmbienceRelayConfigError, .missingApplicationKey)
        }
    }

    func testRelayConfigEncodesDisabledState() throws {
        let suiteName = "HueAmbienceRelayConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HueAmbienceStore(storage: HueAmbienceDefaults(defaults: defaults))
        store.isEnabled = false
        store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.50.216", name: "Hue Bridge")

        let credentials = InMemoryHueRelayCredentialStorage()
        let credentialStore = HueCredentialStore(storage: credentials)
        credentialStore.saveApplicationKey("hue-secret", forBridgeID: "bridge-1")

        let config = try HueAmbienceRelayConfig(
            store: store,
            credentialStore: credentialStore,
            sonosSpeakers: []
        )
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["enabled"] as? Bool, false)
    }
}

private final class InMemoryHueRelayCredentialStorage: HueCredentialStorage {
    private var values: [String: String] = [:]

    func save(_ value: String, account: String) {
        values[account] = value
    }

    func read(account: String) -> String? {
        values[account]
    }

    func delete(account: String) {
        values.removeValue(forKey: account)
    }
}
