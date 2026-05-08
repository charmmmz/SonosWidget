import XCTest
@testable import SonosWidget

final class SonosAppleMusicTrackResolverTests: XCTestCase {
    func testParsesStoreIDFromTrackURIWithSonosAppleMusicPrefixAndExtension() {
        let uri = "x-sonos-http:100320201234567890.mp4?sid=204&flags=8224&sn=2"

        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(uri)

        XCTAssertEqual(parsed.storeID, "1234567890")
        XCTAssertEqual(parsed.sonosTrackObjectID, "100320201234567890")
        XCTAssertEqual(parsed.localServiceID, 204)
        XCTAssertEqual(parsed.accountID, "2")
    }

    func testKeepsPureNumericStoreIDWithoutDroppingDigits() {
        let uri = "x-sonos-http:123456789012345.mp4?sid=204&flags=8224&sn=2"

        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(uri)

        XCTAssertEqual(parsed.storeID, "123456789012345")
        XCTAssertEqual(parsed.sonosTrackObjectID, "123456789012345")
    }

    func testDecodesPercentEscapedObjectIDButRejectsNonNumericPlaybackID() {
        let uri = "x-sonos-http:track%3Aabc123.unknown?sid=204&sn=2"

        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(uri)

        XCTAssertNil(parsed.storeID)
        XCTAssertEqual(parsed.sonosTrackObjectID, "track:abc123")
        XCTAssertEqual(parsed.localServiceID, 204)
        XCTAssertEqual(parsed.accountID, "2")
    }

    func testCloudTrackObjectIDForNowPlayingStripsKnownAppleMusicPrefix() {
        let uri = "x-sonos-http:1003206ctrack%3Aabc123.unknown?sid=204&sn=2"

        let objectID = SonosAppleMusicTrackResolver
            .cloudTrackObjectIDForNowPlaying(fromTrackURI: uri)

        XCTAssertEqual(objectID, "track:abc123")
    }

    func testCloudTrackObjectIDForNowPlayingKeepsPureNumericID() {
        let uri = "x-sonos-http:123456789012345.mp4?sid=204&sn=2"

        let objectID = SonosAppleMusicTrackResolver
            .cloudTrackObjectIDForNowPlaying(fromTrackURI: uri)

        XCTAssertEqual(objectID, "123456789012345")
    }

    func testStoreIDFromTrackURIHandlesUppercaseKnownAppleMusicPrefix() {
        let uri = "x-sonos-http:1003206C1234567890.mp4?sid=204&sn=2"

        let storeID = SonosAppleMusicTrackResolver.storeID(fromTrackURI: uri)

        XCTAssertEqual(storeID, "1234567890")
    }

    func testStoreIDFromNamespacedNumericObjectID() {
        XCTAssertEqual(
            SonosAppleMusicTrackResolver.storeID(fromObjectID: "song:1440857049"),
            "1440857049")
        XCTAssertEqual(
            SonosAppleMusicTrackResolver.storeID(fromObjectID: "track:1440857049"),
            "1440857049")
    }

    func testStoreIDFromBrowseItemPrefersItemID() {
        let item = BrowseItem(
            id: "100320209876543210",
            title: "Dark Dune",
            artist: "Demuja",
            album: "Dark Dune",
            uri: "x-sonos-http:100320201234567890.mp4?sid=204&sn=2",
            duration: 241,
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK")

        let storeID = SonosAppleMusicTrackResolver.storeID(fromBrowseItem: item)

        XCTAssertEqual(storeID, "9876543210")
    }

    func testStoreIDFromBrowseItemFallsBackToURI() {
        let item = BrowseItem(
            id: "track:abc123",
            title: "Dark Dune",
            artist: "Demuja",
            album: "Dark Dune",
            uri: "x-sonos-http:100320201234567890.mp4?sid=204&sn=2",
            duration: 241,
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK")

        let storeID = SonosAppleMusicTrackResolver.storeID(fromBrowseItem: item)

        XCTAssertEqual(storeID, "1234567890")
    }

    func testEmptyURIProducesEmptyParsedValues() {
        let parsed = SonosAppleMusicTrackResolver.parseTrackURI("   ")

        XCTAssertNil(parsed.storeID)
        XCTAssertNil(parsed.sonosTrackObjectID)
        XCTAssertNil(parsed.localServiceID)
        XCTAssertNil(parsed.accountID)
    }
}
