import XCTest
@testable import SonosWidget

@MainActor
final class RelayManagerTests: XCTestCase {
    func testHealthResponseDecodesUnknownHueAmbienceRenderModeAsNil() throws {
        let data = Data("""
        {
          "ok": true,
          "groups": [],
          "hueAmbience": {
            "configured": true,
            "enabled": true,
            "runtimeActive": true,
            "renderMode": "trueStreaming",
            "activeTargetIds": ["area-1", "light-2"],
            "entertainmentTargetActive": true,
            "entertainmentMetadataComplete": true,
            "lastFrameAt": "2026-05-12T00:00:00.000Z",
            "lastError": null
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(RelayClient.HealthResponse.self, from: data)

        XCTAssertNil(response.hueAmbience?.renderMode)
        XCTAssertEqual(response.hueAmbience?.activeTargetIds, ["area-1", "light-2"])
    }

    func testHealthResponseDecodesEntertainmentAndCS2LightingStatus() throws {
        let data = Data("""
        {
          "ok": true,
          "groups": [],
          "hueAmbience": {
            "configured": true,
            "enabled": true
          },
          "hueEntertainment": {
            "configured": true,
            "bridgeReachable": true,
            "streaming": "occupied",
            "activeStreamer": "Hue Sync",
            "activeAreaId": "ent-1",
            "lastError": null
          },
          "cs2Lighting": {
            "enabled": true,
            "active": false,
            "mode": "competitive",
            "transport": "clipFallback",
            "fallbackReason": "entertainment_occupied"
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(RelayClient.HealthResponse.self, from: data)

        XCTAssertEqual(response.hueEntertainment?.streaming, .occupied)
        XCTAssertEqual(response.hueEntertainment?.activeStreamer, "Hue Sync")
        XCTAssertEqual(response.hueEntertainment?.activeAreaId, "ent-1")
        XCTAssertEqual(response.cs2Lighting?.enabled, true)
        XCTAssertEqual(response.cs2Lighting?.active, false)
        XCTAssertEqual(response.cs2Lighting?.mode, .competitive)
        XCTAssertEqual(response.cs2Lighting?.transport, .clipFallback)
        XCTAssertEqual(response.cs2Lighting?.fallbackReason, "entertainment_occupied")
    }

    func testHueAmbienceStatusResponseDecodesUnknownRenderModeAsNil() throws {
        let data = Data("""
        {
          "ok": true,
          "status": {
            "configured": true,
            "enabled": true,
            "bridge": {
              "id": "bridge-1",
              "ipAddress": "192.168.1.2",
              "name": "Hue Bridge"
            },
            "mappings": 1,
            "lights": 2,
            "areas": 1,
            "cs2LightingEnabled": true,
            "runtimeActive": true,
            "activeGroupId": "group-1",
            "renderMode": "trueStreaming",
            "activeTargetIds": ["area-1"],
            "entertainmentTargetActive": true,
            "entertainmentMetadataComplete": true,
            "lastFrameAt": "2026-05-12T00:00:00.000Z",
            "lastError": null
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(RelayClient.HueAmbienceStatusResponse.self, from: data)

        XCTAssertNil(response.status.renderMode)
        XCTAssertEqual(response.status.cs2LightingEnabled, true)
    }

    func testDisabledHueAmbienceConfigStillReportsSynced() {
        let relay = RelayManager.shared
        relay.setURL("")
        defer { relay.setURL("") }

        relay.updateHueAmbienceRuntimeStatus(
            configured: true,
            enabled: false,
            lastError: "stale runtime failure"
        )

        XCTAssertTrue(relay.isHueAmbienceRelayConfigured)
        XCTAssertFalse(relay.isHueAmbienceRelayEnabled)
        guard case .synced = relay.hueAmbienceSyncStatus else {
            return XCTFail("Disabled Hue config should still be marked as synced to NAS")
        }
        XCTAssertEqual(
            relay.hueAmbienceRuntimeStatus,
            .ready("Album ambience disabled")
        )
        XCTAssertEqual(
            relay.hueAmbienceRuntimeDetail,
            "Enable album ambience or CS2 sync to let NAS control your lights."
        )
        XCTAssertFalse(relay.shouldDeferLocalHueAmbience)
    }

    func testStreamingReadyRuntimeReportsClipFallbackDetail() {
        let relay = RelayManager.shared
        relay.setURL("")
        defer { relay.setURL("") }

        relay.updateHueAmbienceRuntimeStatus(
            configured: true,
            renderMode: .streamingReady,
            runtimeActive: true,
            activeTargetIds: ["light-1"],
            lastFrameAt: "2026-05-12T00:00:00.000Z"
        )

        XCTAssertTrue(relay.isHueAmbienceRelayConfigured)
        XCTAssertTrue(relay.isHueAmbienceRelayEnabled)
        XCTAssertEqual(
            relay.hueAmbienceRuntimeStatus,
            .fallback("Streaming-ready via CLIP fallback")
        )
        XCTAssertEqual(
            relay.hueAmbienceRuntimeDetail,
            "NAS controls Hue Ambience while it is reachable."
        )
        XCTAssertFalse(relay.shouldDeferLocalHueAmbience)
    }
}
