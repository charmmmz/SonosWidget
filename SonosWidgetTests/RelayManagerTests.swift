import XCTest
@testable import SonosWidget

@MainActor
final class RelayManagerTests: XCTestCase {
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
}
