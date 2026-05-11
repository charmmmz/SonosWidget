import XCTest
@testable import SonosWidget

final class SonosAuthConfigurationTests: XCTestCase {
    func testMissingClientIDReportsActionableMessage() {
        let message = SonosAuth.oauthConfigurationFailureMessage(
            clientID: "",
            clientSecret: "secret",
            redirectURI: "https://example.com/callback.html"
        )

        XCTAssertEqual(
            message,
            "Sonos OAuth client ID is missing. Check Config/SonosSecrets.xcconfig."
        )
    }

    func testMissingClientSecretReportsActionableMessage() {
        let message = SonosAuth.oauthConfigurationFailureMessage(
            clientID: "client",
            clientSecret: "",
            redirectURI: "https://example.com/callback.html"
        )

        XCTAssertEqual(
            message,
            "Sonos OAuth client secret is missing. Check Config/SonosSecrets.xcconfig."
        )
    }

    func testMissingRedirectURIReportsActionableMessage() {
        let message = SonosAuth.oauthConfigurationFailureMessage(
            clientID: "client",
            clientSecret: "secret",
            redirectURI: "   "
        )

        XCTAssertEqual(
            message,
            "Sonos OAuth redirect URI is missing. Check Config/SonosSecrets.xcconfig."
        )
    }

    func testInvalidRedirectURIReportsActionableMessage() {
        let message = SonosAuth.oauthConfigurationFailureMessage(
            clientID: "client",
            clientSecret: "secret",
            redirectURI: "not a url"
        )

        XCTAssertEqual(
            message,
            "Sonos OAuth redirect URI is not a valid URL. Check Config/SonosSecrets.xcconfig."
        )
    }

    func testCompleteConfigurationHasNoFailureMessage() {
        let message = SonosAuth.oauthConfigurationFailureMessage(
            clientID: "client",
            clientSecret: "secret",
            redirectURI: "https://example.com/callback.html"
        )

        XCTAssertNil(message)
    }
}
