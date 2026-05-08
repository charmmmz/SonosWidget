import XCTest
@testable import SonosWidget

final class HandoffMatcherTests: XCTestCase {
    func testExactTitleArtistAlbumAndDurationMatchWins() {
        let source = AppleMusicHandoffTrack(
            title: "Dark Dune",
            artist: "Demuja",
            album: "Dark Dune",
            duration: 241,
            position: 81,
            playbackStoreID: nil,
            persistentID: nil
        )
        let candidates = [
            makeItem(title: "Dark Dune", artist: "Demuja", album: "Dark Dune", duration: 240),
            makeItem(title: "Dark Dune", artist: "Someone Else", album: "Dark Dune", duration: 240)
        ]

        let match = HandoffMatcher.bestMatch(for: source, candidates: candidates)

        XCTAssertEqual(match?.item.artist, "Demuja")
        XCTAssertGreaterThanOrEqual(match?.score ?? 0, HandoffMatcher.minimumConfidence)
    }

    func testPunctuationAndCaseDoNotPreventMatch() {
        let source = AppleMusicHandoffTrack(
            title: "Josephine (feat. Lisa Hannigan)",
            artist: "RITUAL",
            album: nil,
            duration: 190,
            position: 30,
            playbackStoreID: nil,
            persistentID: nil
        )
        let candidates = [
            makeItem(title: "josephine feat lisa hannigan", artist: "Ritual", album: "", duration: 191)
        ]

        let match = HandoffMatcher.bestMatch(for: source, candidates: candidates)

        XCTAssertNotNil(match)
    }

    func testNonLatinTitleAndArtistCanMatch() {
        let source = AppleMusicHandoffTrack(
            title: "夜に駆ける",
            artist: "YOASOBI",
            album: "夜に駆ける",
            duration: 261,
            position: 18,
            playbackStoreID: nil,
            persistentID: nil
        )
        let candidates = [
            makeItem(title: "夜に駆ける", artist: "YOASOBI", album: "夜に駆ける", duration: 260)
        ]

        let match = HandoffMatcher.bestMatch(for: source, candidates: candidates)

        XCTAssertNotNil(match)
    }

    func testRemasterSuffixCanStillMatchWhenArtistAndDurationMatch() {
        let source = AppleMusicHandoffTrack(
            title: "Blue Monday",
            artist: "New Order",
            album: "Power Corruption & Lies",
            duration: 449,
            position: 12,
            playbackStoreID: nil,
            persistentID: nil
        )
        let candidates = [
            makeItem(title: "Blue Monday - 2015 Remaster", artist: "New Order", album: "Power Corruption & Lies", duration: 450)
        ]

        let match = HandoffMatcher.bestMatch(for: source, candidates: candidates)

        XCTAssertNotNil(match)
    }

    func testWrongArtistDoesNotCrossThreshold() {
        let source = AppleMusicHandoffTrack(
            title: "Intro",
            artist: "The xx",
            album: "xx",
            duration: 127,
            position: 4,
            playbackStoreID: nil,
            persistentID: nil
        )
        let candidates = [
            makeItem(title: "Intro", artist: "M83", album: "Hurry Up, We're Dreaming", duration: 127)
        ]

        let match = HandoffMatcher.bestMatch(for: source, candidates: candidates)

        XCTAssertNil(match)
    }

    func testLargeDurationMismatchDoesNotCrossThreshold() {
        let source = AppleMusicHandoffTrack(
            title: "Nights",
            artist: "Frank Ocean",
            album: "Blonde",
            duration: 307,
            position: 64,
            playbackStoreID: nil,
            persistentID: nil
        )
        let candidates = [
            makeItem(title: "Nights", artist: "Frank Ocean", album: "Blonde", duration: 90)
        ]

        let match = HandoffMatcher.bestMatch(for: source, candidates: candidates)

        XCTAssertNil(match)
    }

    func testShortTitleDoesNotMatchInsideLongerWord() {
        let source = AppleMusicHandoffTrack(
            title: "Intro",
            artist: "The xx",
            album: "xx",
            duration: 127,
            position: 4,
            playbackStoreID: nil,
            persistentID: nil
        )
        let candidates = [
            makeItem(title: "Introvert", artist: "The xx", album: "xx", duration: 127)
        ]

        let match = HandoffMatcher.bestMatch(for: source, candidates: candidates)

        XCTAssertNil(match)
    }

    func testExactTitleOutranksPartialTitleWithMoreMetadata() {
        let source = AppleMusicHandoffTrack(
            title: "Intro",
            artist: "The xx",
            album: "xx",
            duration: 127,
            position: 4,
            playbackStoreID: nil,
            persistentID: nil
        )
        let exactTitle = makeItem(title: "Intro", artist: "The xx", album: "", duration: 0)
        let partialTitle = makeItem(title: "Intro - Live", artist: "The xx", album: "xx", duration: 127)

        let match = HandoffMatcher.bestMatch(for: source, candidates: [partialTitle, exactTitle])

        XCTAssertEqual(match?.item.title, "Intro")
    }

    func testBrowseItemDecodesMissingDurationAsZero() throws {
        let json = """
        {
          "id": "track-1",
          "title": "Intro",
          "artist": "The xx",
          "album": "xx",
          "albumArtURL": null,
          "uri": "x-sonos-http:test.mp4?sid=204&flags=8232&sn=1",
          "metaXML": null,
          "isContainer": false,
          "serviceId": 204,
          "cloudType": "TRACK"
        }
        """

        let item = try JSONDecoder().decode(BrowseItem.self, from: Data(json.utf8))

        XCTAssertEqual(item.duration, 0)
    }

    private func makeItem(title: String, artist: String, album: String, duration: TimeInterval) -> BrowseItem {
        BrowseItem(
            id: UUID().uuidString,
            title: title,
            artist: artist,
            album: album,
            albumArtURL: nil,
            uri: "x-sonos-http:test.mp4?sid=204&flags=8232&sn=1",
            metaXML: nil,
            duration: duration,
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK"
        )
    }
}
