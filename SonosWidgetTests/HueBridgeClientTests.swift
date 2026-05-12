import Foundation
import XCTest
@testable import SonosWidget

final class HueBridgeClientTests: XCTestCase {
    func testLocalDiscoveryBuildsBridgeInfoFromBonjourRecords() async {
        let browser = StubHueLocalBridgeBrowser(records: [
            HueLocalBridgeRecord(
                name: "Philips hue - 001788fffe123456",
                hostName: "Philips-hue.local.",
                ipAddresses: ["192.168.1.20"]
            )
        ])

        let bridges = await HueBridgeDiscovery.discoverLocal(browser: browser, timeout: 0.1)

        XCTAssertEqual(bridges, [
            HueBridgeInfo(id: "001788fffe123456", ipAddress: "192.168.1.20", name: "Philips hue")
        ])
    }

    func testLocalDiscoveryDeduplicatesBridgeRecordsByIPAddress() async {
        let browser = StubHueLocalBridgeBrowser(records: [
            HueLocalBridgeRecord(
                name: "Philips hue - 001788fffe123456",
                hostName: "Philips-hue.local.",
                ipAddresses: ["192.168.1.20"]
            ),
            HueLocalBridgeRecord(
                name: "Hue Bridge Duplicate",
                hostName: nil,
                ipAddresses: ["192.168.1.20"]
            )
        ])

        let bridges = await HueBridgeDiscovery.discoverLocal(browser: browser, timeout: 0.1)

        XCTAssertEqual(bridges.count, 1)
        XCTAssertEqual(bridges.first?.ipAddress, "192.168.1.20")
    }

    func testCredentialStoreSavesReadsAndDeletesApplicationKey() {
        let storage = InMemoryHueCredentialStorage()
        let store = HueCredentialStore(storage: storage)

        store.saveApplicationKey("app-key-1", forBridgeID: "bridge-1")
        XCTAssertEqual(store.applicationKey(forBridgeID: "bridge-1"), "app-key-1")

        store.deleteApplicationKey(forBridgeID: "bridge-1")
        XCTAssertNil(store.applicationKey(forBridgeID: "bridge-1"))
    }

    func testCredentialStoreSavesReadsAndDeletesStreamingClientKey() {
        let storage = InMemoryHueCredentialStorage()
        let store = HueCredentialStore(storage: storage)

        store.saveStreamingClientKey("streaming-key-1", forBridgeID: "bridge-1")
        XCTAssertEqual(store.streamingClientKey(forBridgeID: "bridge-1"), "streaming-key-1")

        store.deleteStreamingClientKey(forBridgeID: "bridge-1")
        XCTAssertNil(store.streamingClientKey(forBridgeID: "bridge-1"))
    }

    func testCredentialStoreSavesReadsAndDeletesStreamingApplicationId() {
        let storage = InMemoryHueCredentialStorage()
        let store = HueCredentialStore(storage: storage)

        store.saveStreamingApplicationId("streaming-app-id-1", forBridgeID: "bridge-1")
        XCTAssertEqual(store.streamingApplicationId(forBridgeID: "bridge-1"), "streaming-app-id-1")

        store.deleteStreamingApplicationId(forBridgeID: "bridge-1")
        XCTAssertNil(store.streamingApplicationId(forBridgeID: "bridge-1"))
    }

    func testPairBridgeStoresApplicationKeyAndEntertainmentCredentialsFromLinkButtonResponse() async throws {
        let credentials = InMemoryHueCredentialStorage()
        let credentialStore = HueCredentialStore(storage: credentials)
        let transport = MockHueTransport(
            responses: [
            "POST /api": """
            [
              {
                "success": {
                  "username": "generated-key",
                  "clientkey": "generated-streaming-key"
                }
              }
            ]
            """,
            "GET /auth/v1": "{}"
            ],
            responseHeaders: [
                "GET /auth/v1": ["hue-application-id": "streaming-app-id"]
            ]
        )
        let client = HueBridgeClient(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
            credentialStore: credentialStore,
            transport: transport
        )

        let key = try await client.pairBridge(deviceType: "Charm Player#iPhone")

        XCTAssertEqual(key, "generated-key")
        XCTAssertEqual(credentialStore.applicationKey(forBridgeID: "bridge-1"), "generated-key")
        XCTAssertEqual(credentialStore.streamingClientKey(forBridgeID: "bridge-1"), "generated-streaming-key")
        XCTAssertEqual(credentialStore.streamingApplicationId(forBridgeID: "bridge-1"), "streaming-app-id")
        XCTAssertEqual(transport.requests.first?.method, "POST")
        XCTAssertEqual(transport.requests.first?.path, "/api")
        XCTAssertEqual(transport.requests.map(\.path), ["/api", "/auth/v1"])
        let body = try XCTUnwrap(transport.requests.first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["devicetype"] as? String, "Charm Player#iPhone")
        XCTAssertEqual(json["generateclientkey"] as? Bool, true)
    }

    func testFetchResourcesDecodesEntertainmentAreasRoomsZonesAndLights() async throws {
        let transport = MockHueTransport(responses: [
            "GET /clip/v2/resource/light": """
            {
              "data": [
                {
                  "id": "light-1",
                  "metadata": {
                    "name": "Gradient Strip"
                  },
                  "owner": {
                    "rid": "room-1",
                    "rtype": "room"
                  },
                  "color": {},
                  "gradient": {
                    "points_capable": 5
                  },
                  "mode": "normal"
                }
              ]
            }
            """,
            "GET /clip/v2/resource/device": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/room": """
            {
              "data": [
                {
                  "id": "room-1",
                  "metadata": {
                    "name": "Living Room"
                  },
                  "children": [
                    {
                      "rid": "light-1",
                      "rtype": "light"
                    }
                  ]
                }
              ]
            }
            """,
            "GET /clip/v2/resource/zone": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/entertainment_configuration": """
            {
              "data": [
                {
                  "id": "ent-1",
                  "metadata": {
                    "name": "Living Sync"
                  },
                  "channels": [
                    {
                      "members": [
                        {
                          "service": {
                            "rid": "light-1",
                            "rtype": "light"
                          }
                        }
                      ]
                    }
                  ]
                }
              ]
            }
            """
        ])
        let client = HueBridgeClient(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
            credentialStore: HueCredentialStore(storage: InMemoryHueCredentialStorage()),
            transport: transport,
            applicationKeyProvider: { "generated-key" }
        )

        let resources = try await client.fetchResources()

        XCTAssertEqual(resources.lights.first?.id, "light-1")
        XCTAssertEqual(resources.lights.first?.name, "Gradient Strip")
        XCTAssertEqual(resources.lights.first?.ownerID, "room-1")
        XCTAssertEqual(resources.lights.first?.supportsColor, true)
        XCTAssertEqual(resources.lights.first?.supportsGradient, true)
        XCTAssertEqual(resources.areas.first, HueAreaResource(
            id: "ent-1",
            name: "Living Sync",
            kind: .entertainmentArea,
            childLightIDs: ["light-1"],
            entertainmentChannels: [
                HueEntertainmentChannelResource(id: "0", lightID: "light-1", serviceID: "light-1")
            ]
        ))
        XCTAssertEqual(resources.areas.dropFirst().first, HueAreaResource(
            id: "room-1",
            name: "Living Room",
            kind: .room,
            childLightIDs: ["light-1"]
        ))
        XCTAssertTrue(transport.requests.allSatisfy { request in
            request.headers["hue-application-key"] == "generated-key"
        })
    }

    func testFetchResourcesResolvesEntertainmentLightServicesToLights() async throws {
        let transport = MockHueTransport(responses: [
            "GET /clip/v2/resource/light": """
            {
              "data": [
                {
                  "id": "light-1",
                  "metadata": {
                    "name": "Gradient Strip"
                  },
                  "services": [
                    {
                      "rid": "service-ent-1",
                      "rtype": "entertainment"
                    }
                  ],
                  "color": {},
                  "gradient": {
                    "points_capable": 5
                  },
                  "mode": "normal"
                }
              ]
            }
            """,
            "GET /clip/v2/resource/device": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/room": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/zone": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/entertainment_configuration": """
            {
              "data": [
                {
                  "id": "ent-1",
                  "metadata": {
                    "name": "Living Sync"
                  },
                  "light_services": [
                    {
                      "rid": "service-ent-1",
                      "rtype": "entertainment"
                    }
                  ],
                  "channels": [
                    {
                      "members": [
                        {
                          "service": {
                            "rid": "service-ent-1",
                            "rtype": "entertainment"
                          }
                        }
                      ]
                    }
                  ]
                }
              ]
            }
            """
        ])
        let client = HueBridgeClient(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
            credentialStore: HueCredentialStore(storage: InMemoryHueCredentialStorage()),
            transport: transport,
            applicationKeyProvider: { "generated-key" }
        )

        let resources = try await client.fetchResources()

        XCTAssertEqual(resources.areas.first, HueAreaResource(
            id: "ent-1",
            name: "Living Sync",
            kind: .entertainmentArea,
            childLightIDs: ["light-1"],
            entertainmentChannels: [
                HueEntertainmentChannelResource(id: "0", lightID: "light-1", serviceID: "service-ent-1")
            ]
        ))
    }

    func testFetchResourcesResolvesDeviceEntertainmentServicesForFunctionalLights() async throws {
        let transport = MockHueTransport(responses: [
            "GET /clip/v2/resource/light": """
            {
              "data": [
                {
                  "id": "task-light",
                  "metadata": {
                    "name": "Desk Lamp",
                    "function": "functional"
                  },
                  "owner": {
                    "rid": "device-1",
                    "rtype": "device"
                  },
                  "color": {}
                }
              ]
            }
            """,
            "GET /clip/v2/resource/device": """
            {
              "data": [
                {
                  "id": "device-1",
                  "services": [
                    {
                      "rid": "task-light",
                      "rtype": "light"
                    },
                    {
                      "rid": "service-ent-task",
                      "rtype": "entertainment"
                    }
                  ]
                }
              ]
            }
            """,
            "GET /clip/v2/resource/room": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/zone": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/entertainment_configuration": """
            {
              "data": [
                {
                  "id": "ent-1",
                  "metadata": {
                    "name": "PC Entertainment"
                  },
                  "channels": [
                    {
                      "members": [
                        {
                          "service": {
                            "rid": "service-ent-task",
                            "rtype": "entertainment"
                          }
                        }
                      ]
                    }
                  ]
                }
              ]
            }
            """
        ])
        let client = HueBridgeClient(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
            credentialStore: HueCredentialStore(storage: InMemoryHueCredentialStorage()),
            transport: transport,
            applicationKeyProvider: { "generated-key" }
        )

        let resources = try await client.fetchResources()
        let area = try XCTUnwrap(resources.areas.first)

        XCTAssertEqual(area.childLightIDs, ["task-light"])
        XCTAssertEqual(area.entertainmentChannels.first?.lightID, "task-light")
        XCTAssertEqual(area.entertainmentChannels.first?.serviceID, "service-ent-task")
    }

    func testFetchResourcesPopulatesEntertainmentChannelMetadata() async throws {
        let transport = MockHueTransport(responses: [
            "GET /clip/v2/resource/light": """
            {
              "data": [
                {
                  "id": "light-1",
                  "metadata": {
                    "name": "Gradient Strip"
                  },
                  "services": [
                    {
                      "rid": "service-ent-1",
                      "rtype": "entertainment"
                    }
                  ],
                  "color": {},
                  "gradient": {
                    "points_capable": 5
                  },
                  "mode": "normal"
                }
              ]
            }
            """,
            "GET /clip/v2/resource/device": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/room": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/zone": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/entertainment_configuration": """
            {
              "data": [
                {
                  "id": "ent-1",
                  "metadata": {
                    "name": "Living Sync"
                  },
                  "channels": [
                    {
                      "channel_id": 0,
                      "position": { "x": 0, "y": 1, "z": 0 },
                      "members": [
                        {
                          "service": {
                            "rid": "service-ent-1",
                            "rtype": "entertainment"
                          }
                        }
                      ]
                    }
                  ]
                }
              ]
            }
            """
        ])
        let client = HueBridgeClient(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
            credentialStore: HueCredentialStore(storage: InMemoryHueCredentialStorage()),
            transport: transport,
            applicationKeyProvider: { "generated-key" }
        )

        let resources = try await client.fetchResources()
        let area = try XCTUnwrap(resources.areas.first)
        let channel = try XCTUnwrap(area.entertainmentChannels.first)

        XCTAssertEqual(channel.id, "0")
        XCTAssertEqual(channel.lightID, "light-1")
        XCTAssertEqual(channel.serviceID, "service-ent-1")
        XCTAssertEqual(channel.position?.y, 1)
    }

    func testFetchResourcesFallsBackToChannelIndexWhenChannelIDIsMissing() async throws {
        let transport = MockHueTransport(responses: [
            "GET /clip/v2/resource/light": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/device": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/room": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/zone": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/entertainment_configuration": """
            {
              "data": [
                {
                  "id": "ent-1",
                  "metadata": {
                    "name": "Living Sync"
                  },
                  "channels": [
                    {},
                    {}
                  ]
                }
              ]
            }
            """
        ])
        let client = HueBridgeClient(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
            credentialStore: HueCredentialStore(storage: InMemoryHueCredentialStorage()),
            transport: transport,
            applicationKeyProvider: { "generated-key" }
        )

        let resources = try await client.fetchResources()
        let area = try XCTUnwrap(resources.areas.first)

        XCTAssertEqual(area.entertainmentChannels.map(\.id), ["0", "1"])
    }

    func testFetchResourcesPrefersNonzeroBridgeChannelIDOverArrayIndex() async throws {
        let transport = MockHueTransport(responses: [
            "GET /clip/v2/resource/light": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/device": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/room": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/zone": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/entertainment_configuration": """
            {
              "data": [
                {
                  "id": "ent-1",
                  "metadata": {
                    "name": "Living Sync"
                  },
                  "channels": [
                    {
                      "channel_id": 7
                    }
                  ]
                }
              ]
            }
            """
        ])
        let client = HueBridgeClient(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
            credentialStore: HueCredentialStore(storage: InMemoryHueCredentialStorage()),
            transport: transport,
            applicationKeyProvider: { "generated-key" }
        )

        let resources = try await client.fetchResources()
        let area = try XCTUnwrap(resources.areas.first)

        XCTAssertEqual(area.entertainmentChannels.map(\.id), ["7"])
    }

    func testFetchResourcesResolvesZoneRoomChildrenToLights() async throws {
        let transport = MockHueTransport(responses: [
            "GET /clip/v2/resource/light": """
            {
              "data": [
                {
                  "id": "light-1",
                  "metadata": {
                    "name": "Gradient Strip"
                  },
                  "color": {},
                  "gradient": {
                    "points_capable": 5
                  }
                }
              ]
            }
            """,
            "GET /clip/v2/resource/device": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/room": """
            {
              "data": [
                {
                  "id": "room-1",
                  "metadata": {
                    "name": "Living Room"
                  },
                  "children": [
                    {
                      "rid": "light-1",
                      "rtype": "light"
                    }
                  ]
                }
              ]
            }
            """,
            "GET /clip/v2/resource/zone": """
            {
              "data": [
                {
                  "id": "zone-1",
                  "metadata": {
                    "name": "Downstairs"
                  },
                  "children": [
                    {
                      "rid": "room-1",
                      "rtype": "room"
                    }
                  ]
                }
              ]
            }
            """,
            "GET /clip/v2/resource/entertainment_configuration": """
            {
              "data": []
            }
            """
        ])
        let client = HueBridgeClient(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
            credentialStore: HueCredentialStore(storage: InMemoryHueCredentialStorage()),
            transport: transport,
            applicationKeyProvider: { "generated-key" }
        )

        let resources = try await client.fetchResources()
        let zone = resources.areas.first { $0.id == "zone-1" }

        XCTAssertEqual(zone?.childLightIDs, ["light-1"])
    }

    func testFetchResourcesResolvesRoomDeviceChildrenWithoutUsingLightNames() async throws {
        let transport = MockHueTransport(responses: [
            "GET /clip/v2/resource/light": """
            {
              "data": [
                {
                  "id": "study-lamp",
                  "metadata": {
                    "name": "台灯"
                  },
                  "owner": {
                    "rid": "study-device",
                    "rtype": "device"
                  },
                  "color": {}
                },
                {
                  "id": "bedroom-lamp",
                  "metadata": {
                    "name": "台灯"
                  },
                  "owner": {
                    "rid": "bedroom-device",
                    "rtype": "device"
                  },
                  "color": {}
                }
              ]
            }
            """,
            "GET /clip/v2/resource/device": """
            {
              "data": [
                {
                  "id": "study-device",
                  "services": [
                    {
                      "rid": "study-lamp",
                      "rtype": "light"
                    }
                  ]
                },
                {
                  "id": "bedroom-device",
                  "services": [
                    {
                      "rid": "bedroom-lamp",
                      "rtype": "light"
                    }
                  ]
                }
              ]
            }
            """,
            "GET /clip/v2/resource/room": """
            {
              "data": [
                {
                  "id": "study-room",
                  "metadata": {
                    "name": "Study"
                  },
                  "children": [
                    {
                      "rid": "study-device",
                      "rtype": "device"
                    }
                  ]
                }
              ]
            }
            """,
            "GET /clip/v2/resource/zone": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/entertainment_configuration": """
            {
              "data": []
            }
            """
        ])
        let client = HueBridgeClient(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
            credentialStore: HueCredentialStore(storage: InMemoryHueCredentialStorage()),
            transport: transport,
            applicationKeyProvider: { "generated-key" }
        )

        let resources = try await client.fetchResources()
        let room = resources.areas.first { $0.id == "study-room" }

        XCTAssertEqual(room?.childLightIDs, ["study-lamp"])
        XCTAssertEqual(room?.childDeviceIDs, ["study-device"])
    }

    func testFetchResourcesDecodesLightFunctionMetadata() async throws {
        let transport = MockHueTransport(responses: [
            "GET /clip/v2/resource/light": """
            {
              "data": [
                {
                  "id": "decorative-light",
                  "metadata": {
                    "name": "Decorative Strip",
                    "function": "decorative"
                  },
                  "color": {}
                },
                {
                  "id": "task-light",
                  "metadata": {
                    "name": "Desk Lamp",
                    "function": "functional"
                  },
                  "color": {}
                },
                {
                  "id": "mixed-light",
                  "metadata": {
                    "name": "Mixed Lamp",
                    "function": "mixed"
                  },
                  "color": {}
                },
                {
                  "id": "unknown-light",
                  "metadata": {
                    "name": "Unknown Lamp"
                  },
                  "color": {}
                }
              ]
            }
            """,
            "GET /clip/v2/resource/device": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/room": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/zone": """
            {
              "data": []
            }
            """,
            "GET /clip/v2/resource/entertainment_configuration": """
            {
              "data": []
            }
            """
        ])
        let client = HueBridgeClient(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
            credentialStore: HueCredentialStore(storage: InMemoryHueCredentialStorage()),
            transport: transport,
            applicationKeyProvider: { "generated-key" }
        )

        let resources = try await client.fetchResources()

        XCTAssertEqual(resources.lights.map(\.function), [
            .decorative,
            .functional,
            .mixed,
            .unknown
        ])
        XCTAssertTrue(resources.lights.allSatisfy(\.functionMetadataResolved))
    }

    func testFetchResourcesThrowsMissingApplicationKeyBeforeSendingRequest() async throws {
        let transport = MockHueTransport(responses: [:])
        let client = HueBridgeClient(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
            credentialStore: HueCredentialStore(storage: InMemoryHueCredentialStorage()),
            transport: transport
        )

        do {
            _ = try await client.fetchResources()
            XCTFail("Expected missing application key")
        } catch HueBridgeError.missingApplicationKey {
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func testPairBridgeMapsLinkButtonError101() async throws {
        let transport = MockHueTransport(responses: [
            "POST /api": """
            [
              {
                "error": {
                  "type": 101
                }
              }
            ]
            """
        ])
        let client = HueBridgeClient(
            bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
            credentialStore: HueCredentialStore(storage: InMemoryHueCredentialStorage()),
            transport: transport
        )

        do {
            _ = try await client.pairBridge(deviceType: "Charm Player#iPhone")
            XCTFail("Expected link button error")
        } catch HueBridgeError.linkButtonNotPressed {
            XCTAssertEqual(transport.requests.count, 1)
        }
    }
}

private struct StubHueLocalBridgeBrowser: HueLocalBridgeBrowsing {
    var records: [HueLocalBridgeRecord]

    func discover(timeout: TimeInterval) async -> [HueLocalBridgeRecord] {
        records
    }
}

private final class InMemoryHueCredentialStorage: HueCredentialStorage {
    private var values: [String: String] = [:]

    func save(_ value: String, account: String) {
        values[account] = value
    }

    func read(account: String) -> String? {
        values[account]
    }

    func delete(account: String) {
        values[account] = nil
    }
}

private final class MockHueTransport: HueBridgeTransport {
    private let responses: [String: Data]
    private let responseHeaders: [String: [String: String]]
    private(set) var requests: [HueBridgeRequest] = []

    init(responses: [String: String], responseHeaders: [String: [String: String]] = [:]) {
        self.responses = responses.mapValues { Data($0.utf8) }
        self.responseHeaders = responseHeaders
    }

    func send(_ request: HueBridgeRequest) async throws -> Data {
        try await sendResponse(request).data
    }

    func sendResponse(_ request: HueBridgeRequest) async throws -> HueBridgeResponse {
        requests.append(request)

        guard let response = responses["\(request.method) \(request.path)"] else {
            throw URLError(.badServerResponse)
        }

        return HueBridgeResponse(
            data: response,
            headers: responseHeaders["\(request.method) \(request.path)"] ?? [:]
        )
    }
}
