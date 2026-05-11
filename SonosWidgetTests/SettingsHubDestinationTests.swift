import XCTest
@testable import SonosWidget

final class SettingsHubDestinationTests: XCTestCase {
    func testPrimaryDestinationsKeepSettingsHubOrder() {
        XCTAssertEqual(SettingsHubDestination.primary, [
            .sonos,
            .musicAmbience,
            .localServer,
        ])
    }

    func testPrimaryDestinationsDescribeConsolidatedGroups() {
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.title),
            ["Sonos", "Music Ambience", "Local Server"]
        )
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.subtitle),
            [
                "Account, speakers, and music services",
                "Hue Bridge, assignments, and light behavior",
                "Relay, Live Activity, and NAS Agent",
            ]
        )
        XCTAssertEqual(
            SettingsHubDestination.primary.map(\.systemImage),
            ["hifispeaker.2.fill", "sparkles", "server.rack"]
        )
    }
}
