import XCTest
@testable import SonosWidget

final class AppleMusicQueueHandoffPlannerTests: XCTestCase {
    func testPlanStartsAtCurrentTrackNumberAndKeepsResolvableQueueOrder() {
        let queue = [
            makeQueueItem(title: "Before", artist: "Artist", storeID: "111"),
            makeQueueItem(title: "Current", artist: "Artist", storeID: "wrong"),
            makeQueueItem(title: "Next", artist: "Artist", storeID: "333")
        ]
        let current = makeTrackInfo(title: "Current", artist: "Artist")

        let plan = AppleMusicQueueHandoffPlanner.makePlan(
            queue: queue,
            currentTrackNumber: 2,
            currentTrackInfo: current,
            currentStoreID: "222")

        XCTAssertEqual(plan?.storeIDs, ["222", "333"])
        XCTAssertEqual(plan?.skippedUnsupportedItemCount, 0)
    }

    func testPlanSkipsUnsupportedQueueItemsAfterCurrentTrack() {
        let queue = [
            makeQueueItem(title: "Current", artist: "Artist", storeID: "111"),
            makeQueueItem(title: "Radio Break", artist: "Station", storeID: nil),
            makeQueueItem(title: "Next", artist: "Artist", storeID: "333")
        ]
        let current = makeTrackInfo(title: "Current", artist: "Artist")

        let plan = AppleMusicQueueHandoffPlanner.makePlan(
            queue: queue,
            currentTrackNumber: 1,
            currentTrackInfo: current,
            currentStoreID: "111")

        XCTAssertEqual(plan?.storeIDs, ["111", "333"])
        XCTAssertEqual(plan?.skippedUnsupportedItemCount, 1)
    }

    func testPlanFallsBackToTitleArtistWhenTrackNumberIsUnavailable() {
        let queue = [
            makeQueueItem(title: "Before", artist: "Artist", storeID: "111"),
            makeQueueItem(title: "Current", artist: "Artist", storeID: "222"),
            makeQueueItem(title: "Next", artist: "Artist", storeID: "333")
        ]
        let current = makeTrackInfo(title: "Current", artist: "Artist")

        let plan = AppleMusicQueueHandoffPlanner.makePlan(
            queue: queue,
            currentTrackNumber: nil,
            currentTrackInfo: current,
            currentStoreID: "222")

        XCTAssertEqual(plan?.storeIDs, ["222", "333"])
        XCTAssertEqual(plan?.skippedUnsupportedItemCount, 0)
    }

    func testPlanFallsBackToSingleTrackWhenQueueStartCannotBeIdentified() {
        let queue = [
            makeQueueItem(title: "Different", artist: "Artist", storeID: "111"),
            makeQueueItem(title: "Another", artist: "Artist", storeID: "222")
        ]
        let current = makeTrackInfo(title: "Current", artist: "Artist")

        let plan = AppleMusicQueueHandoffPlanner.makePlan(
            queue: queue,
            currentTrackNumber: nil,
            currentTrackInfo: current,
            currentStoreID: "999")

        XCTAssertEqual(plan?.storeIDs, ["999"])
        XCTAssertEqual(plan?.skippedUnsupportedItemCount, 0)
    }

    private func makeQueueItem(
        title: String,
        artist: String,
        storeID: String?
    ) -> QueueItem {
        QueueItem(
            id: title,
            objectID: "Q:0/\(title)",
            trackNumber: 1,
            title: title,
            artist: artist,
            album: "Album",
            albumArtURL: nil,
            uri: storeID.map { "x-sonos-http:10032020\($0).mp4?sid=204&flags=8224&sn=2" },
            metaXML: nil)
    }

    private func makeTrackInfo(title: String, artist: String) -> TrackInfo {
        TrackInfo(
            title: title,
            artist: artist,
            album: "Album",
            source: .appleMusic)
    }
}
