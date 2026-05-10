import UIKit
import XCTest
@testable import SonosWidget

final class MusicAmbienceManagerTests: XCTestCase {
    func testAllMappedRoomsStrategyResolvesEveryGroupMemberMapping() {
        let store = makeStore()
        store.isEnabled = true
        store.upsertMapping(HueSonosMapping(
            sonosID: "living",
            sonosName: "Living",
            preferredTarget: .entertainmentArea("ent-living")
        ))
        store.upsertMapping(HueSonosMapping(
            sonosID: "kitchen",
            sonosName: "Kitchen",
            preferredTarget: .entertainmentArea("ent-kitchen")
        ))
        store.groupStrategy = .allMappedRooms

        let manager = MusicAmbienceManager(store: store)
        let snapshot = HueAmbiencePlaybackSnapshot(
            selectedSonosID: "living",
            selectedSonosName: "Living",
            groupMemberIDs: ["living", "kitchen"],
            groupMemberNamesByID: ["living": "Living", "kitchen": "Kitchen"],
            trackTitle: "Song",
            artist: "Artist",
            albumArtURL: "art",
            isPlaying: true,
            albumArtImage: nil
        )

        let targets = manager.mappingsForCurrentPlayback(snapshot)

        XCTAssertEqual(
            targets.map(\.preferredTarget),
            [.entertainmentArea("ent-living"), .entertainmentArea("ent-kitchen")]
        )
    }

    func testCoordinatorOnlyStrategyResolvesSelectedMapping() {
        let store = makeStore()
        store.isEnabled = true
        store.upsertMapping(HueSonosMapping(
            sonosID: "living",
            sonosName: "Living",
            preferredTarget: .entertainmentArea("ent-living")
        ))
        store.upsertMapping(HueSonosMapping(
            sonosID: "kitchen",
            sonosName: "Kitchen",
            preferredTarget: .entertainmentArea("ent-kitchen")
        ))
        store.groupStrategy = .coordinatorOnly

        let manager = MusicAmbienceManager(store: store)
        let snapshot = HueAmbiencePlaybackSnapshot(
            selectedSonosID: "living",
            selectedSonosName: "Living",
            groupMemberIDs: ["living", "kitchen"],
            groupMemberNamesByID: [:],
            trackTitle: "Song",
            artist: "Artist",
            albumArtURL: "art",
            isPlaying: true,
            albumArtImage: nil
        )

        XCTAssertEqual(manager.mappingsForCurrentPlayback(snapshot).map(\.sonosID), ["living"])
    }

    func testSnapshotUsesSelectedSpeakerAndVisibleGroupMembers() {
        let selected = SonosPlayer(
            id: "living",
            name: "Living",
            ipAddress: "192.168.1.10",
            isCoordinator: true,
            groupId: "group-1"
        )
        let kitchen = SonosPlayer(
            id: "kitchen",
            name: "Kitchen",
            ipAddress: "192.168.1.11",
            isCoordinator: false,
            groupId: "group-1"
        )
        let info = TrackInfo(
            title: "Song",
            artist: "Artist",
            album: "Album",
            albumArtURL: "https://example.com/art.jpg"
        )

        let snapshot = SonosManager.musicAmbienceSnapshot(
            selectedSpeaker: selected,
            currentGroupMembers: [selected, kitchen],
            trackInfo: info,
            isPlaying: true,
            albumArtData: Data([1, 2, 3])
        )

        XCTAssertEqual(snapshot.selectedSonosID, "living")
        XCTAssertEqual(snapshot.selectedSonosName, "Living")
        XCTAssertEqual(snapshot.groupMemberIDs, ["living", "kitchen"])
        XCTAssertEqual(snapshot.groupMemberNamesByID["kitchen"], "Kitchen")
        XCTAssertEqual(snapshot.trackTitle, "Song")
        XCTAssertEqual(snapshot.artist, "Artist")
        XCTAssertEqual(snapshot.albumArtURL, "https://example.com/art.jpg")
        XCTAssertTrue(snapshot.isPlaying)
        XCTAssertEqual(snapshot.albumArtImage, Data([1, 2, 3]))
    }

    func testAreaOptionsPreferEntertainmentAreasOverRoomsAndZones() {
        let areas = [
            HueAreaResource(id: "room-1", name: "Living Room", kind: .room, childLightIDs: ["light-1"]),
            HueAreaResource(id: "ent-1", name: "Living Sync", kind: .entertainmentArea, childLightIDs: ["light-1"]),
            HueAreaResource(id: "zone-1", name: "Downstairs", kind: .zone, childLightIDs: ["light-2"])
        ]

        let options = HueAmbienceAreaOptions.displayAreas(from: areas)

        XCTAssertEqual(options.map(\.id), ["ent-1"])
    }

    func testAreaOptionsCreateRoomMappingWithGradientCapability() {
        let room = HueAreaResource(id: "room-1", name: "Living Room", kind: .room, childLightIDs: ["light-1"])
        let lights = [
            HueLightResource(
                id: "light-1",
                name: "Gradient Strip",
                ownerID: "room-1",
                supportsColor: true,
                supportsGradient: true,
                supportsEntertainment: true
            )
        ]

        let mapping = HueAmbienceAreaOptions.mapping(
            sonosID: "living",
            sonosName: "Living",
            selectedArea: room,
            lights: lights
        )

        XCTAssertEqual(mapping.preferredTarget, .room("room-1"))
        XCTAssertEqual(mapping.capability, .gradientReady)
    }

    func testReceiveAppliesPaletteWhenPlayingAndMapped() async {
        let store = makeStore()
        store.isEnabled = true
        store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue")
        store.upsertMapping(HueSonosMapping(
            sonosID: "living",
            sonosName: "Living",
            preferredTarget: .room("room-1")
        ))

        let applyExpectation = expectation(description: "renderer applies palette")
        let renderer = RecordingAmbienceRendering(applyExpectation: applyExpectation)
        let resolver = StaticHueTargetResolving(targets: [
            HueResolvedAmbienceTarget(
                areaID: "room-1",
                lightIDs: ["light-1"],
                lightsByID: [
                    "light-1": HueLightResource(
                        id: "light-1",
                        name: "Lamp",
                        ownerID: nil,
                        supportsColor: true,
                        supportsGradient: false,
                        supportsEntertainment: false
                    )
                ]
            )
        ])
        let manager = MusicAmbienceManager(
            store: store,
            renderer: renderer,
            targetResolver: resolver
        )

        manager.receive(snapshot: HueAmbiencePlaybackSnapshot(
            selectedSonosID: "living",
            selectedSonosName: "Living",
            groupMemberIDs: ["living"],
            groupMemberNamesByID: ["living": "Living"],
            trackTitle: "Song",
            artist: "Artist",
            albumArtURL: "art",
            isPlaying: true,
            albumArtImage: makeRedImageData()
        ))

        await fulfillment(of: [applyExpectation], timeout: 1)
        XCTAssertEqual(renderer.applyCount, 1)
        XCTAssertEqual(renderer.lastTargets.map(\.areaID), ["room-1"])
    }

    func testReceiveDoesNotReapplySameTrackPaletteAndTargets() async {
        let store = makeStore()
        store.isEnabled = true
        store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue")
        store.upsertMapping(HueSonosMapping(
            sonosID: "living",
            sonosName: "Living",
            preferredTarget: .room("room-1")
        ))

        let applyExpectation = expectation(description: "renderer applies once")
        applyExpectation.assertForOverFulfill = true
        let renderer = RecordingAmbienceRendering(applyExpectation: applyExpectation)
        let manager = MusicAmbienceManager(
            store: store,
            renderer: renderer,
            targetResolver: StaticHueTargetResolving(targets: [makeTarget()])
        )
        let snapshot = makePlayingSnapshot(trackTitle: "Song")

        manager.receive(snapshot: snapshot)
        await fulfillment(of: [applyExpectation], timeout: 1)
        manager.receive(snapshot: snapshot)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(renderer.applyCount, 1)
    }

    func testReceiveStopsActiveAmbienceWhenPlaybackStops() async {
        let store = makeStore()
        store.isEnabled = true
        store.stopBehavior = .turnOff
        store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue")
        store.upsertMapping(HueSonosMapping(
            sonosID: "living",
            sonosName: "Living",
            preferredTarget: .room("room-1")
        ))

        let applyExpectation = expectation(description: "renderer applies palette")
        let stopExpectation = expectation(description: "renderer stops active ambience")
        let target = makeTarget()
        let renderer = RecordingAmbienceRendering(
            applyExpectation: applyExpectation,
            stopExpectation: stopExpectation
        )
        let manager = MusicAmbienceManager(
            store: store,
            renderer: renderer,
            targetResolver: StaticHueTargetResolving(targets: [target])
        )

        manager.receive(snapshot: makePlayingSnapshot(trackTitle: "Song"))
        await fulfillment(of: [applyExpectation], timeout: 1)

        var stoppedSnapshot = makePlayingSnapshot(trackTitle: "Song")
        stoppedSnapshot.isPlaying = false
        manager.receive(snapshot: stoppedSnapshot)

        await fulfillment(of: [stopExpectation], timeout: 1)
        XCTAssertEqual(renderer.stopCount, 1)
        XCTAssertEqual(renderer.lastStopTargets, [target])
        XCTAssertEqual(renderer.lastStopBehavior, .turnOff)
    }

    func testStaleRenderErrorDoesNotOverrideNewerSyncStatus() async {
        let store = makeStore()
        store.isEnabled = true
        store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue")
        store.upsertMapping(HueSonosMapping(
            sonosID: "living",
            sonosName: "Living",
            preferredTarget: .room("room-1")
        ))

        let firstStarted = expectation(description: "first render started")
        let secondStarted = expectation(description: "second render started")
        let renderer = StaleFailingAmbienceRendering(
            firstStarted: firstStarted,
            secondStarted: secondStarted
        )
        let manager = MusicAmbienceManager(
            store: store,
            renderer: renderer,
            targetResolver: StaticHueTargetResolving(targets: [makeTarget()])
        )

        manager.receive(snapshot: makePlayingSnapshot(trackTitle: "Song One"))
        await fulfillment(of: [firstStarted], timeout: 1)
        manager.receive(snapshot: makePlayingSnapshot(trackTitle: "Song Two"))
        await fulfillment(of: [secondStarted], timeout: 1)
        renderer.releaseFirstRender()
        try? await Task.sleep(nanoseconds: 100_000_000)

        if case .error = manager.status {
            XCTFail("Stale render errors should not replace a newer syncing status")
        }
    }

    func testStoredResolverUsesPreferredTargetAndExclusions() {
        let resolver = StoredHueTargetResolver(
            areas: [
                HueAreaResource(
                    id: "room-1",
                    name: "Living Room",
                    kind: .room,
                    childLightIDs: ["light-1", "light-2"]
                )
            ],
            lights: [
                HueLightResource(
                    id: "light-1",
                    name: "Gradient Strip",
                    ownerID: "room-1",
                    supportsColor: true,
                    supportsGradient: true,
                    supportsEntertainment: true
                ),
                HueLightResource(
                    id: "light-2",
                    name: "Lamp",
                    ownerID: "room-1",
                    supportsColor: true,
                    supportsGradient: false,
                    supportsEntertainment: false
                )
            ]
        )
        let mapping = HueSonosMapping(
            sonosID: "living",
            sonosName: "Living",
            preferredTarget: .room("room-1"),
            excludedLightIDs: ["light-2"]
        )

        let targets = resolver.resolveTargets(for: [mapping])

        XCTAssertEqual(targets.map(\.areaID), ["room-1"])
        XCTAssertEqual(targets.first?.lightIDs, ["light-1"])
        XCTAssertEqual(targets.first?.lightsByID["light-1"]?.supportsGradient, true)
    }

    private func makeTarget() -> HueResolvedAmbienceTarget {
        HueResolvedAmbienceTarget(
            areaID: "room-1",
            lightIDs: ["light-1"],
            lightsByID: [
                "light-1": HueLightResource(
                    id: "light-1",
                    name: "Lamp",
                    ownerID: nil,
                    supportsColor: true,
                    supportsGradient: false,
                    supportsEntertainment: false
                )
            ]
        )
    }

    private func makePlayingSnapshot(trackTitle: String) -> HueAmbiencePlaybackSnapshot {
        HueAmbiencePlaybackSnapshot(
            selectedSonosID: "living",
            selectedSonosName: "Living",
            groupMemberIDs: ["living"],
            groupMemberNamesByID: ["living": "Living"],
            trackTitle: trackTitle,
            artist: "Artist",
            albumArtURL: "art-\(trackTitle)",
            isPlaying: true,
            albumArtImage: makeRedImageData()
        )
    }

    private func makeStore() -> HueAmbienceStore {
        let suiteName = "MusicAmbienceManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return HueAmbienceStore(storage: HueAmbienceDefaults(defaults: defaults))
    }

    private func makeRedImageData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        return image.pngData()!
    }
}

private final class RecordingAmbienceRendering: HueAmbienceRendering {
    private let applyExpectation: XCTestExpectation?
    private let stopExpectation: XCTestExpectation?
    private(set) var applyCount = 0
    private(set) var stopCount = 0
    private(set) var lastTargets: [HueResolvedAmbienceTarget] = []
    private(set) var lastStopTargets: [HueResolvedAmbienceTarget] = []
    private(set) var lastStopBehavior: HueAmbienceStopBehavior?

    init(
        applyExpectation: XCTestExpectation? = nil,
        stopExpectation: XCTestExpectation? = nil
    ) {
        self.applyExpectation = applyExpectation
        self.stopExpectation = stopExpectation
    }

    func apply(
        palette: [HueRGBColor],
        to targets: [HueResolvedAmbienceTarget],
        transitionSeconds: Double
    ) async throws {
        applyCount += 1
        lastTargets = targets
        applyExpectation?.fulfill()
    }

    func stop(targets: [HueResolvedAmbienceTarget], behavior: HueAmbienceStopBehavior) async throws {
        stopCount += 1
        lastStopTargets = targets
        lastStopBehavior = behavior
        stopExpectation?.fulfill()
    }
}

private struct StaticHueTargetResolving: HueTargetResolving {
    var targets: [HueResolvedAmbienceTarget]

    func resolveTargets(for mappings: [HueSonosMapping]) -> [HueResolvedAmbienceTarget] {
        targets
    }
}

private final class StaleFailingAmbienceRendering: HueAmbienceRendering {
    private let firstStarted: XCTestExpectation
    private let secondStarted: XCTestExpectation
    private var applyCount = 0
    private var firstRenderContinuation: CheckedContinuation<Void, Never>?

    init(firstStarted: XCTestExpectation, secondStarted: XCTestExpectation) {
        self.firstStarted = firstStarted
        self.secondStarted = secondStarted
    }

    func apply(
        palette: [HueRGBColor],
        to targets: [HueResolvedAmbienceTarget],
        transitionSeconds: Double
    ) async throws {
        applyCount += 1

        if applyCount == 1 {
            firstStarted.fulfill()
            await withCheckedContinuation { continuation in
                firstRenderContinuation = continuation
            }
            throw StaleRenderError.failure
        }

        secondStarted.fulfill()
    }

    func stop(targets: [HueResolvedAmbienceTarget], behavior: HueAmbienceStopBehavior) async throws {}

    func releaseFirstRender() {
        firstRenderContinuation?.resume()
        firstRenderContinuation = nil
    }
}

private enum StaleRenderError: Error {
    case failure
}
