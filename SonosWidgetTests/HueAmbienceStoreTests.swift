import XCTest
@testable import SonosWidget

final class HueAmbienceStoreTests: XCTestCase {
    func testMappingPrefersEntertainmentAreaAndKeepsFallback() throws {
        let mapping = HueSonosMapping(
            sonosID: "RINCON_living",
            sonosName: "Living Room",
            preferredTarget: .entertainmentArea("ent-1"),
            fallbackTarget: .room("room-1"),
            excludedLightIDs: ["light-2"],
            capability: .liveEntertainment
        )

        let data = try JSONEncoder().encode(mapping)
        let decoded = try JSONDecoder().decode(HueSonosMapping.self, from: data)

        XCTAssertEqual(decoded.sonosID, "RINCON_living")
        XCTAssertEqual(decoded.preferredTarget, .entertainmentArea("ent-1"))
        XCTAssertEqual(decoded.fallbackTarget, .room("room-1"))
        XCTAssertEqual(decoded.excludedLightIDs, ["light-2"])
        XCTAssertEqual(decoded.capability, .liveEntertainment)
    }

    func testGroupStrategyDefaultsToAllMappedRooms() {
        XCTAssertEqual(HueGroupSyncStrategy.default, .allMappedRooms)
    }

    func testStopBehaviorDefaultsToLeaveCurrent() {
        XCTAssertEqual(HueAmbienceStopBehavior.default, .leaveCurrent)
    }

    func testStorePersistsEnabledBridgeMappingsAndStrategy() {
        let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = HueAmbienceDefaults(defaults: defaults)
        let store = HueAmbienceStore(storage: storage)

        store.isEnabled = true
        store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue")
        store.groupStrategy = .coordinatorOnly
        store.statusText = "Ready"
        store.upsertMapping(HueSonosMapping(
            sonosID: "RINCON_kitchen",
            sonosName: "Kitchen",
            preferredTarget: .entertainmentArea("ent-kitchen"),
            fallbackTarget: .zone("zone-kitchen"),
            capability: .gradientReady
        ))

        let restored = HueAmbienceStore(storage: storage)

        XCTAssertTrue(restored.isEnabled)
        XCTAssertEqual(restored.bridge?.id, "bridge-1")
        XCTAssertEqual(restored.groupStrategy, .coordinatorOnly)
        XCTAssertEqual(restored.statusText, "Ready")
        XCTAssertEqual(restored.mapping(forSonosID: "RINCON_kitchen")?.preferredTarget, .entertainmentArea("ent-kitchen"))
    }

    func testRemovingBridgeClearsMappingsAndDisablesSync() {
        let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = HueAmbienceDefaults(defaults: defaults)
        let store = HueAmbienceStore(storage: storage)
        store.isEnabled = true
        store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue")
        store.statusText = "Connected"
        store.upsertMapping(HueSonosMapping(sonosID: "RINCON_living", sonosName: "Living Room"))

        store.disconnectBridge()
        let restored = HueAmbienceStore(storage: storage)

        XCTAssertFalse(restored.isEnabled)
        XCTAssertNil(restored.bridge)
        XCTAssertTrue(restored.mappings.isEmpty)
        XCTAssertNil(restored.statusText)
    }
}
