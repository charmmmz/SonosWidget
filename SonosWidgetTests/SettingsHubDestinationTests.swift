import XCTest
@testable import SonosWidget

final class SettingsHubDestinationTests: XCTestCase {
    func testPrimaryDestinationsKeepSettingsHubOrder() {
        XCTAssertEqual(SettingsHubDestination.primary, [
            .sonos,
            .hueAmbience,
            .localServer,
        ])
    }

    func testPrimaryDestinationsDescribeConsolidatedGroups() {
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.title),
            ["Sonos", "Hue Ambience", "Local Server"]
        )
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.subtitle),
            [
                "Account, speakers, and music services",
                "Hue Bridge, sync status, music, and game lighting",
                "Relay, Live Activity, and NAS Agent",
            ]
        )
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.systemImage),
            ["hifispeaker.2.fill", "sparkles", "server.rack"]
        )
    }
}
