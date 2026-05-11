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
    }

    func testDisabledHueAmbienceConfigStillReportsSynced() {
        let relay = RelayManager.shared
        relay.setURL("")
        defer { relay.setURL("") }

        relay.updateHueAmbienceRuntimeStatus(configured: true, enabled: false)

        XCTAssertTrue(relay.isHueAmbienceRelayConfigured)
        guard case .synced = relay.hueAmbienceSyncStatus else {
            return XCTFail("Disabled Hue config should still be marked as synced to NAS")
        }
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
            "NAS controls Music Ambience while it is reachable."
        )
        XCTAssertFalse(relay.shouldDeferLocalHueAmbience)
    }
}
