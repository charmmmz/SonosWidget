import XCTest
@testable import SonosWidget

final class HandoffDirectionResolverTests: XCTestCase {
    func testPlayingSonosTransfersToPhone() {
        let direction = HandoffDirectionResolver.direction(forSonosState: .playing)

        XCTAssertEqual(direction, .sonosToPhone)
    }

    func testPausedSonosTransfersPhoneToSonos() {
        let direction = HandoffDirectionResolver.direction(forSonosState: .paused)

        XCTAssertEqual(direction, .phoneToSonos)
    }

    func testStoppedSonosTransfersPhoneToSonos() {
        let direction = HandoffDirectionResolver.direction(forSonosState: .stopped)

        XCTAssertEqual(direction, .phoneToSonos)
    }

    func testUnknownSonosTransfersPhoneToSonos() {
        let direction = HandoffDirectionResolver.direction(forSonosState: .unknown)

        XCTAssertEqual(direction, .phoneToSonos)
    }
}
