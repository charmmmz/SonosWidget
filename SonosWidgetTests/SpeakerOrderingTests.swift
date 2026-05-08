import XCTest
@testable import SonosWidget

final class SpeakerOrderingTests: XCTestCase {
    override func tearDown() {
        SharedStorage.homeSpeakerGroupOrder = []
        super.tearDown()
    }

    func testCustomOrderIsAppliedAheadOfAlphabeticalFallback() {
        let statuses = [
            makeStatus(id: "kitchen", name: "Kitchen"),
            makeStatus(id: "living", name: "Living Room"),
            makeStatus(id: "bedroom", name: "Bedroom")
        ]

        let sorted = SonosManager.sortedSpeakerGroups(
            statuses,
            preferredOrder: ["living", "missing", "bedroom"]
        )

        XCTAssertEqual(sorted.map(\.id), ["living", "bedroom", "kitchen"])
    }

    func testMovingSpeakerGroupPersistsNewOrderAndReordersCurrentStatuses() {
        let manager = SonosManager()
        manager.groupStatuses = [
            makeStatus(id: "kitchen", name: "Kitchen"),
            makeStatus(id: "living", name: "Living Room"),
            makeStatus(id: "bedroom", name: "Bedroom")
        ]

        manager.moveSpeakerGroup(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(manager.groupStatuses.map(\.id), ["bedroom", "kitchen", "living"])
        XCTAssertEqual(SharedStorage.homeSpeakerGroupOrder, ["bedroom", "kitchen", "living"])
    }

    func testDropIntentUsesEdgesForReorderAndCenterForGrouping() {
        XCTAssertEqual(
            SonosManager.speakerGroupDropIntent(locationY: 8, targetHeight: 100),
            .reorderBefore
        )
        XCTAssertEqual(
            SonosManager.speakerGroupDropIntent(locationY: 50, targetHeight: 100),
            .merge
        )
        XCTAssertEqual(
            SonosManager.speakerGroupDropIntent(locationY: 92, targetHeight: 100),
            .reorderAfter
        )
    }

    func testReorderingRelativeToTargetPersistsNewOrder() {
        let manager = SonosManager()
        manager.groupStatuses = [
            makeStatus(id: "kitchen", name: "Kitchen"),
            makeStatus(id: "living", name: "Living Room"),
            makeStatus(id: "bedroom", name: "Bedroom")
        ]

        manager.reorderSpeakerGroup(
            sourceID: "bedroom",
            relativeTo: "kitchen",
            placement: .before
        )

        XCTAssertEqual(manager.groupStatuses.map(\.id), ["bedroom", "kitchen", "living"])
        XCTAssertEqual(SharedStorage.homeSpeakerGroupOrder, ["bedroom", "kitchen", "living"])
    }

    private func makeStatus(id: String, name: String) -> SpeakerGroupStatus {
        let player = SonosPlayer(
            id: id,
            name: name,
            ipAddress: "192.168.1.\(abs(id.hashValue % 200) + 20)",
            isCoordinator: true,
            groupId: id
        )
        return SpeakerGroupStatus(
            id: id,
            coordinator: player,
            members: [player],
            trackInfo: nil,
            transportState: .stopped,
            volume: 0
        )
    }
}
