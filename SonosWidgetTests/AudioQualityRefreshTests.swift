import XCTest
@testable import SonosWidget

final class AudioQualityRefreshTests: XCTestCase {
    func testLANRefreshRestoresCachedCloudQualityBeforePublishingTrackInfo() {
        let cached = AudioQuality(codec: "ALAC", sampleRate: 44_100, bitDepth: 16, channels: nil)
        let incoming = TrackInfo(
            title: "Nocturne",
            artist: "Helios",
            album: "Eingya",
            albumArtURL: "https://example.com/nocturne.jpg",
            source: .appleMusic,
            audioQuality: nil
        )

        let reconciled = SonosManager.reconciledLANTrackInfo(
            incoming,
            cachedCloudQuality: (
                trackKey: SonosManager.cloudQualityTrackKey(for: incoming)!,
                quality: cached
            ),
            cloudQualityIsAuthoritative: true
        )

        XCTAssertEqual(reconciled.audioQuality, cached)
    }

    func testLANRefreshDoesNotReuseCachedCloudQualityForDifferentTrackWithSameTitle() {
        let cached = AudioQuality(codec: "ALAC", sampleRate: 44_100, bitDepth: 16, channels: nil)
        let incoming = TrackInfo(
            title: "Intro",
            artist: "Artist B",
            album: "Album B",
            albumArtURL: "https://example.com/b.jpg",
            source: .appleMusic,
            audioQuality: nil
        )

        let reconciled = SonosManager.reconciledLANTrackInfo(
            incoming,
            cachedCloudQuality: (
                trackKey: "Intro|Artist A|https://example.com/a.jpg",
                quality: cached
            ),
            cloudQualityIsAuthoritative: true
        )

        XCTAssertNil(reconciled.audioQuality)
    }
}
