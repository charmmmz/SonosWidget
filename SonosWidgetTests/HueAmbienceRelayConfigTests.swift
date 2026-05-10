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
                    childLightIDs: ["light-1"]
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
        XCTAssertEqual(firstMapping["relayGroupID"] as? String, "192.168.50.25")
        XCTAssertEqual(preferredTarget["kind"] as? String, "entertainmentArea")
        XCTAssertEqual(preferredTarget["id"] as? String, "ent-1")
        XCTAssertEqual(object["flowIntervalSeconds"] as? Double, 4)
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
