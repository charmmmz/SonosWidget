import XCTest
@testable import SonosWidget

final class HueAmbienceStoreTests: XCTestCase {
    func testMappingPrefersEntertainmentAreaAndKeepsFallback() throws {
        let mapping = HueSonosMapping(
            sonosID: "RINCON_living",
            sonosName: "Living Room",
            preferredTarget: .entertainmentArea("ent-1"),
            fallbackTarget: .room("room-1"),
            includedLightIDs: ["light-1"],
            excludedLightIDs: ["light-2"],
            capability: .liveEntertainment
        )

        let data = try JSONEncoder().encode(mapping)
        let decoded = try JSONDecoder().decode(HueSonosMapping.self, from: data)

        XCTAssertEqual(decoded.sonosID, "RINCON_living")
        XCTAssertEqual(decoded.preferredTarget, .entertainmentArea("ent-1"))
        XCTAssertEqual(decoded.fallbackTarget, .room("room-1"))
        XCTAssertEqual(decoded.includedLightIDs, ["light-1"])
        XCTAssertEqual(decoded.excludedLightIDs, ["light-2"])
        XCTAssertEqual(decoded.capability, .liveEntertainment)
    }

    func testMappingSupportsDirectLightTarget() throws {
        let mapping = HueSonosMapping(
            sonosID: "RINCON_desk",
            sonosName: "Desk",
            preferredTarget: .light("light-1"),
            capability: .gradientReady
        )

        let data = try JSONEncoder().encode(mapping)
        let decoded = try JSONDecoder().decode(HueSonosMapping.self, from: data)

        XCTAssertEqual(decoded.preferredTarget, .light("light-1"))
        XCTAssertEqual(decoded.preferredTarget?.id, "light-1")
    }

    func testOlderMappingPayloadDefaultsIncludedLightsToEmpty() throws {
        let data = """
        {
          "sonosID": "RINCON_living",
          "sonosName": "Living Room",
          "preferredTarget": {
            "room": {
              "_0": "room-1"
            }
          },
          "excludedLightIDs": [],
          "capability": "basic"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HueSonosMapping.self, from: data)

        XCTAssertTrue(decoded.includedLightIDs.isEmpty)
    }

    func testOlderLightPayloadDefaultsFunctionToUnknown() throws {
        let data = """
        {
          "id": "light-1",
          "name": "Lamp",
          "ownerID": "room-1",
          "supportsColor": true,
          "supportsGradient": false,
          "supportsEntertainment": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HueLightResource.self, from: data)

        XCTAssertEqual(decoded.function, .unknown)
        XCTAssertFalse(decoded.functionMetadataResolved)
    }

    func testHueAreaResourcePersistsEntertainmentChannels() throws {
        let area = HueAreaResource(
            id: "ent-1",
            name: "Playroom Area",
            kind: .entertainmentArea,
            childLightIDs: ["light-1"],
            childDeviceIDs: ["device-1"],
            entertainmentChannels: [
                HueEntertainmentChannelResource(
                    id: "0",
                    lightID: "light-1",
                    serviceID: "svc-1",
                    position: HueEntertainmentChannelPosition(x: 0, y: 1, z: 0)
                )
            ]
        )

        let data = try JSONEncoder().encode(area)
        let decoded = try JSONDecoder().decode(HueAreaResource.self, from: data)

        XCTAssertEqual(decoded.entertainmentChannels.first?.id, "0")
        XCTAssertEqual(decoded.entertainmentChannels.first?.lightID, "light-1")
        XCTAssertEqual(decoded.entertainmentChannels.first?.serviceID, "svc-1")
        XCTAssertEqual(decoded.entertainmentChannels.first?.position?.y, 1)
    }

    func testUpdateResourcesPreservesEntertainmentChannels() {
        let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = HueAmbienceDefaults(defaults: defaults)
        let store = HueAmbienceStore(storage: storage)

        store.updateResources(HueBridgeResources(
            lights: [
                HueLightResource(
                    id: "light-1",
                    name: "Gradient Strip",
                    ownerID: "device-1",
                    supportsColor: true,
                    supportsGradient: true,
                    supportsEntertainment: true
                )
            ],
            areas: [
                HueAreaResource(
                    id: "ent-1",
                    name: "Playroom Area",
                    kind: .entertainmentArea,
                    childLightIDs: ["light-1"],
                    childDeviceIDs: ["device-1"],
                    entertainmentChannels: [
                        HueEntertainmentChannelResource(
                            id: "channel-0",
                            lightID: "light-1",
                            serviceID: "svc-1",
                            position: HueEntertainmentChannelPosition(x: 0, y: 1, z: 0)
                        )
                    ]
                )
            ]
        ))

        let channel = store.hueAreas.first?.entertainmentChannels.first

        XCTAssertEqual(channel?.id, "channel-0")
        XCTAssertEqual(channel?.lightID, "light-1")
        XCTAssertEqual(channel?.serviceID, "svc-1")
        XCTAssertEqual(channel?.position?.y, 1)
    }

    func testHueBridgeResourcesDetectsUnresolvedFunctionMetadata() {
        let resources = HueBridgeResources(
            lights: [
                HueLightResource(
                    id: "light-1",
                    name: "Lamp",
                    ownerID: nil,
                    supportsColor: true,
                    supportsGradient: false,
                    supportsEntertainment: false,
                    function: .unknown,
                    functionMetadataResolved: false
                )
            ],
            areas: []
        )

        XCTAssertTrue(resources.needsFunctionMetadataRefresh)
    }

    func testGroupStrategyDefaultsToAllMappedRooms() {
        XCTAssertEqual(HueGroupSyncStrategy.default, .allMappedRooms)
    }

    func testStopBehaviorDefaultsToLeaveCurrent() {
        XCTAssertEqual(HueAmbienceStopBehavior.default, .leaveCurrent)
    }

    func testMotionStyleDefaultsToFlowing() {
        XCTAssertEqual(HueAmbienceMotionStyle.default, .flowing)
    }

    func testFlowSpeedDefaultsToSlow() {
        XCTAssertEqual(HueAmbienceFlowSpeed.default, .slow)
        XCTAssertEqual(HueAmbienceFlowSpeed.fast.intervalSeconds, 4)
    }

    func testLiveEntertainmentWithoutRuntimeUsesClearUnavailableStatus() {
        XCTAssertEqual(
            HueLiveEntertainmentRuntimeStatus.unavailable.reason,
            "NAS runtime not configured"
        )
        XCTAssertEqual(
            HueLiveEntertainmentRuntimeStatus.fallback("Streaming-ready via CLIP fallback").reason,
            "Streaming-ready via CLIP fallback"
        )
    }

    func testSetupPresentationStateOnlyDismissesExplicitly() {
        var presentation = MusicAmbienceSetupPresentationState()

        presentation.present()
        let presentationAfterParentRefresh = presentation

        XCTAssertTrue(presentationAfterParentRefresh.isPresented)

        presentation.dismiss()

        XCTAssertFalse(presentation.isPresented)
    }

    func testStorePersistsStopBehavior() {
        let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = HueAmbienceDefaults(defaults: defaults)
        let store = HueAmbienceStore(storage: storage)

        store.stopBehavior = .turnOff

        let restored = HueAmbienceStore(storage: storage)

        XCTAssertEqual(restored.stopBehavior, .turnOff)
    }

    func testStorePersistsMotionStyle() {
        let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = HueAmbienceDefaults(defaults: defaults)
        let store = HueAmbienceStore(storage: storage)

        store.motionStyle = .still

        let restored = HueAmbienceStore(storage: storage)

        XCTAssertEqual(restored.motionStyle, .still)
    }

    func testStorePersistsFlowSpeed() {
        let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = HueAmbienceDefaults(defaults: defaults)
        let store = HueAmbienceStore(storage: storage)

        store.flowSpeed = .fast

        let restored = HueAmbienceStore(storage: storage)

        XCTAssertEqual(restored.flowSpeed, .fast)
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

    func testAssignAreaPersistsSelectedHueAreaImmediately() {
        let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = HueAmbienceDefaults(defaults: defaults)
        let store = HueAmbienceStore(storage: storage)

        let didAssign = store.assignArea(
            sonosID: "RINCON_playroom",
            sonosName: "Playroom",
            areaID: "ent-playroom",
            from: [
                HueAreaResource(
                    id: "ent-playroom",
                    name: "PC",
                    kind: .entertainmentArea,
                    childLightIDs: ["light-1"]
                )
            ],
            lights: [
                HueLightResource(
                    id: "light-1",
                    name: "Gradient Strip",
                    ownerID: nil,
                    supportsColor: true,
                    supportsGradient: true,
                    supportsEntertainment: true
                )
            ]
        )

        let restored = HueAmbienceStore(storage: storage)

        XCTAssertTrue(didAssign)
        XCTAssertEqual(restored.mapping(forSonosID: "RINCON_playroom")?.preferredTarget, .entertainmentArea("ent-playroom"))
        XCTAssertEqual(restored.mapping(forSonosID: "RINCON_playroom")?.capability, .liveEntertainment)
    }

    func testStorePersistsHueResources() {
        let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = HueAmbienceDefaults(defaults: defaults)
        let store = HueAmbienceStore(storage: storage)

        store.updateResources(HueBridgeResources(
            lights: [
                HueLightResource(
                    id: "light-1",
                    name: "Gradient Strip",
                    ownerID: "room-1",
                    supportsColor: true,
                    supportsGradient: true,
                    supportsEntertainment: true
                )
            ],
            areas: [
                HueAreaResource(
                    id: "room-1",
                    name: "Living Room",
                    kind: .room,
                    childLightIDs: ["light-1"]
                )
            ]
        ))

        let restored = HueAmbienceStore(storage: storage)

        XCTAssertEqual(restored.hueLights.map(\.id), ["light-1"])
        XCTAssertEqual(restored.hueAreas.map(\.id), ["room-1"])
    }

    func testChangingBridgeClearsMappingsAndHueResources() {
        let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = HueAmbienceDefaults(defaults: defaults)
        let store = HueAmbienceStore(storage: storage)
        store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue")
        store.upsertMapping(HueSonosMapping(
            sonosID: "living",
            sonosName: "Living",
            preferredTarget: .room("room-1")
        ))
        store.updateResources(HueBridgeResources(
            lights: [
                HueLightResource(
                    id: "light-1",
                    name: "Lamp",
                    ownerID: "room-1",
                    supportsColor: true,
                    supportsGradient: false,
                    supportsEntertainment: false
                )
            ],
            areas: [
                HueAreaResource(
                    id: "room-1",
                    name: "Living Room",
                    kind: .room,
                    childLightIDs: ["light-1"]
                )
            ]
        ))

        store.bridge = HueBridgeInfo(id: "bridge-2", ipAddress: "192.168.1.21", name: "New Hue")
        let restored = HueAmbienceStore(storage: storage)

        XCTAssertEqual(restored.bridge?.id, "bridge-2")
        XCTAssertTrue(restored.mappings.isEmpty)
        XCTAssertTrue(restored.hueLights.isEmpty)
        XCTAssertTrue(restored.hueAreas.isEmpty)
    }

    func testStoreIgnoresHueResourcesForStaleBridgeID() {
        let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = HueAmbienceDefaults(defaults: defaults)
        let store = HueAmbienceStore(storage: storage)
        store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue")
        store.bridge = HueBridgeInfo(id: "bridge-2", ipAddress: "192.168.1.21", name: "New Hue")

        let didUpdate = store.updateResources(
            HueBridgeResources(
                lights: [
                    HueLightResource(
                        id: "light-1",
                        name: "Lamp",
                        ownerID: "room-1",
                        supportsColor: true,
                        supportsGradient: false,
                        supportsEntertainment: false
                    )
                ],
                areas: [
                    HueAreaResource(
                        id: "room-1",
                        name: "Living Room",
                        kind: .room,
                        childLightIDs: ["light-1"]
                    )
                ]
            ),
            forBridgeID: "bridge-1"
        )

        XCTAssertFalse(didUpdate)
        XCTAssertTrue(store.hueLights.isEmpty)
        XCTAssertTrue(store.hueAreas.isEmpty)
    }

    func testUpdatingResourcesRemovesStaleMappingTargetsAndLightOverrides() {
        let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = HueAmbienceDefaults(defaults: defaults)
        let store = HueAmbienceStore(storage: storage)
        store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue")
        store.upsertMapping(HueSonosMapping(
            sonosID: "study",
            sonosName: "Study",
            preferredTarget: .room("study-room"),
            fallbackTarget: .zone("old-zone"),
            includedLightIDs: ["study-lamp", "old-lamp"],
            excludedLightIDs: ["old-lamp"]
        ))
        store.upsertMapping(HueSonosMapping(
            sonosID: "old",
            sonosName: "Old Room",
            preferredTarget: .room("old-room")
        ))

        store.updateResources(HueBridgeResources(
            lights: [
                HueLightResource(
                    id: "study-lamp",
                    name: "台灯",
                    ownerID: "study-device",
                    supportsColor: true,
                    supportsGradient: false,
                    supportsEntertainment: true
                )
            ],
            areas: [
                HueAreaResource(
                    id: "study-room",
                    name: "Study",
                    kind: .room,
                    childLightIDs: ["study-lamp", "old-lamp"],
                    childDeviceIDs: ["study-device"]
                )
            ]
        ))

        XCTAssertEqual(store.mappings.map(\.sonosID), ["study"])
        XCTAssertEqual(store.mappings.first?.fallbackTarget, nil)
        XCTAssertEqual(store.mappings.first?.includedLightIDs, ["study-lamp"])
        XCTAssertEqual(store.mappings.first?.excludedLightIDs, [])
        XCTAssertEqual(store.hueAreas.first?.childLightIDs, ["study-lamp"])
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
