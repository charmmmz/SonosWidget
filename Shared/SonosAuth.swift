import Foundation
import AuthenticationServices

@Observable
final class SonosAuth: NSObject {

    static let shared = SonosAuth()

    // ── Configure these after registering at integration.sonos.com ──
    static var clientID    = "37db4b81-bf96-41b0-8240-6d271fa255c1"
    static var clientSecret = "7d6f7be8-d8e3-4c51-9281-def62aeba045"
    static var redirectURI  = "https://charmmmz.github.io/SonosWidget/callback.html"

    var isLoggedIn: Bool { readKeychain(.accessToken) != nil }
    var householdId: String? {
        get { readKeychain(.householdId) }
        set { if let v = newValue { saveKeychain(.householdId, v) } else { deleteKeychain(.householdId) } }
    }

    /// Synchronous read of the stored access token — no refresh attempt.
    /// Callers that can tolerate the async refresh path should still prefer
    /// `validAccessToken()`. Used by `SonosManager.currentControlBackend()`
    /// where we need to synthesize a `Backend` without hopping to async.
    var cachedAccessToken: String? { readKeychain(.accessToken) }

    private var presentationAnchor: ASPresentationAnchor?

    private override init() { super.init() }

    // MARK: - Login

    @MainActor
    func startLogin(from window: UIWindow?) async -> Bool {
        guard !Self.clientID.isEmpty else {
            SonosLog.error(.sonosAuth, "clientID not configured")
            return false
        }

        var components = URLComponents(string: "https://api.sonos.com/login/v3/oauth")!
        components.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "state", value: UUID().uuidString),
            .init(name: "scope", value: "playback-control-all"),
            .init(name: "redirect_uri", value: Self.redirectURI),
        ]

        guard let authURL = components.url else { return false }
        presentationAnchor = window

        return await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "sonoswidget"
            ) { [weak self] callbackURL, error in
                guard let self, let callbackURL, error == nil else {
                    continuation.resume(returning: false)
                    return
                }
                Task {
                    let success = await self.handleCallback(url: callbackURL)
                    continuation.resume(returning: success)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }

    @discardableResult
    func handleCallback(url: URL) async -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            return false
        }
        return await exchangeCodeForToken(code: code)
    }

    // MARK: - Token Exchange

    private func exchangeCodeForToken(code: String) async -> Bool {
        var body = URLComponents()
        body.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: Self.redirectURI),
        ]

        return await tokenRequest(bodyString: body.query ?? "")
    }

    func refreshAccessToken() async -> Bool {
        guard let refreshToken = readKeychain(.refreshToken) else { return false }

        var body = URLComponents()
        body.queryItems = [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refreshToken),
        ]

        return await tokenRequest(bodyString: body.query ?? "")
    }

    private func tokenRequest(bodyString: String) async -> Bool {
        guard let url = URL(string: "https://api.sonos.com/login/v3/oauth/access") else { return false }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")

        let credentials = "\(Self.clientID):\(Self.clientSecret)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyString.data(using: .utf8)

        do {
            let (data, response) = try await noProxySession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }

            let json = try JSONDecoder().decode(TokenResponse.self, from: data)
            saveKeychain(.accessToken, json.access_token)
            saveKeychain(.refreshToken, json.refresh_token)
            let expiry = Date().addingTimeInterval(TimeInterval(json.expires_in - 60))
            saveKeychain(.tokenExpiry, expiry.timeIntervalSince1970.description)
            // Mirror token to SharedStorage so widget extension can access it.
            SharedStorage.cloudAccessToken = json.access_token
            SharedStorage.cloudTokenExpiry = expiry
            return true
        } catch {
            SonosLog.error(.sonosAuth, "token request failed: \(error)")
            return false
        }
    }

    // MARK: - Access Token (auto-refresh)

    func validAccessToken() async -> String? {
        guard let token = readKeychain(.accessToken) else { return nil }

        if let expiryStr = readKeychain(.tokenExpiry),
           let expiry = Double(expiryStr),
           Date().timeIntervalSince1970 < expiry {
            // Mirror to SharedStorage every time so the widget extension always has a fresh copy.
            SharedStorage.cloudAccessToken = token
            SharedStorage.cloudTokenExpiry = Date(timeIntervalSince1970: expiry)
            return token
        }

        let refreshed = await refreshAccessToken()
        return refreshed ? readKeychain(.accessToken) : nil
    }

    // MARK: - Logout

    func logout() {
        for key in KeychainKey.allCases { deleteKeychain(key) }
    }

    // MARK: - Keychain

    private enum KeychainKey: String, CaseIterable {
        case accessToken  = "com.charm.SonosWidget.accessToken"
        case refreshToken = "com.charm.SonosWidget.refreshToken"
        case tokenExpiry  = "com.charm.SonosWidget.tokenExpiry"
        case householdId  = "com.charm.SonosWidget.householdId"
    }

    private func saveKeychain(_ key: KeychainKey, _ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    private func readKeychain(_ key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychain(_ key: KeychainKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension SonosAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationAnchor ?? ASPresentationAnchor()
    }
}

// MARK: - Token Response

private struct TokenResponse: Decodable {
    let access_token: String
    let token_type: String
    let expires_in: Int
    let refresh_token: String
    let scope: String
}
