import Foundation
import AuthenticationServices

@Observable
final class SonosAuth: NSObject {

    static let shared = SonosAuth()

    enum SessionState: String {
        case disconnected
        case checking
        case connected
        case expired
    }
    private static let sessionStateKey = "com.charm.SonosWidget.sessionState"

    /// Values come from `Config/SonosOAuth.xcconfig` → merged Info.plist (`SonosOAuth*` keys).
    /// Copy `Config/SonosSecrets.example.xcconfig` to `Config/SonosSecrets.xcconfig` and fill in.
    static var clientID: String { Self.infoPlistString("SonosOAuthClientID") }
    static var clientSecret: String { Self.infoPlistString("SonosOAuthClientSecret") }
    static var redirectURI: String { Self.infoPlistString("SonosOAuthRedirectURI") }

    private static func infoPlistString(_ key: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var sessionState: SessionState = .disconnected {
        didSet { persistSessionState() }
    }
    var lastErrorMessage: String?
    var hasStoredCredentials: Bool {
        readKeychain(.accessToken) != nil || readKeychain(.refreshToken) != nil
    }
    var isLoggedIn: Bool { hasStoredCredentials && sessionState != .expired }
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
    private var authSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
        sessionState = Self.restoredSessionState(hasStoredCredentials: hasStoredCredentials)
    }

    // MARK: - Login

    @MainActor
    func startLogin(from window: UIWindow?) async -> Bool {
        lastErrorMessage = nil
        if let configurationFailure = Self.oauthConfigurationFailureMessage() {
            recordFailure(configurationFailure)
            return false
        }
        guard let window else {
            recordFailure("Could not find an active app window to present Sonos sign-in. Try again with the app in the foreground.")
            return false
        }

        SonosLog.info(.sonosAuth, "startLogin")
        let stateBeforeLogin = sessionState
        sessionState = .checking

        var components = URLComponents(string: "https://api.sonos.com/login/v3/oauth")!
        components.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "state", value: UUID().uuidString),
            .init(name: "scope", value: "playback-control-all"),
            .init(name: "redirect_uri", value: Self.redirectURI),
        ]

        guard let authURL = components.url else {
            recordFailure("Could not build the Sonos authorization URL. Check Config/SonosSecrets.xcconfig.")
            restoreStateAfterLoginCancellation(previousState: stateBeforeLogin)
            return false
        }
        presentationAnchor = window
        SonosLog.info(.sonosAuth, "opening OAuth session; redirect host=\(URL(string: Self.redirectURI)?.host ?? "unknown")")

        return await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "sonoswidget"
            ) { [weak self] callbackURL, error in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                self.authSession = nil
                guard let callbackURL, error == nil else {
                    let detail = error?.localizedDescription ?? "missing callback URL"
                    SonosLog.info(.sonosAuth, "login cancelled or failed: \(detail)")
                    self.lastErrorMessage = Self.loginFailureMessage(error: error)
                    self.restoreStateAfterLoginCancellation(previousState: stateBeforeLogin)
                    continuation.resume(returning: false)
                    return
                }
                SonosLog.info(.sonosAuth, "received OAuth callback")
                Task {
                    let success = await self.handleCallback(url: callbackURL)
                    continuation.resume(returning: success)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            authSession = session
            guard session.start() else {
                recordFailure("Could not open Sonos sign-in. Try again from the foreground app window.")
                authSession = nil
                restoreStateAfterLoginCancellation(previousState: stateBeforeLogin)
                continuation.resume(returning: false)
                return
            }
            SonosLog.debug(.sonosAuth, "ASWebAuthenticationSession started")
        }
    }

    @MainActor
    func reconnect(from window: UIWindow?) async -> Bool {
        SonosLog.info(.sonosAuth, "reconnect")
        return await startLogin(from: window)
    }

    @discardableResult
    func handleCallback(url: URL) async -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            lastErrorMessage = "Sonos sign-in returned without an authorization code. Check the redirect page and try reconnecting."
            SonosLog.error(.sonosAuth, lastErrorMessage ?? "OAuth callback missing code")
            restoreStateAfterFailedTokenRequest()
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

        let success = await tokenRequest(bodyString: body.query ?? "")
        if !success { restoreStateAfterFailedTokenRequest() }
        return success
    }

    func refreshAccessToken() async -> Bool {
        guard let refreshToken = readKeychain(.refreshToken) else {
            lastErrorMessage = "Sonos refresh token is missing. Reconnect your Sonos account."
            SonosLog.error(.sonosAuth, lastErrorMessage ?? "refresh token missing")
            markSessionExpired()
            return false
        }
        sessionState = .checking

        var body = URLComponents()
        body.queryItems = [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refreshToken),
        ]

        let success = await tokenRequest(bodyString: body.query ?? "")
        if !success { markSessionExpired() }
        return success
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
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                SonosLog.error(.sonosAuth, "token request HTTP \(status): \(body.prefix(500))")
                lastErrorMessage = "Sonos token exchange failed (HTTP \(status)). Check the OAuth redirect URI and client secret, then reconnect."
                return false
            }

            let json = try JSONDecoder().decode(TokenResponse.self, from: data)
            saveKeychain(.accessToken, json.access_token)
            saveKeychain(.refreshToken, json.refresh_token)
            let expiry = Date().addingTimeInterval(TimeInterval(json.expires_in - 60))
            saveKeychain(.tokenExpiry, expiry.timeIntervalSince1970.description)
            // Mirror token to SharedStorage so widget extension can access it.
            SharedStorage.cloudAccessToken = json.access_token
            SharedStorage.cloudTokenExpiry = expiry
            sessionState = .connected
            lastErrorMessage = nil
            SonosLog.info(.sonosAuth, "token request succeeded; expires in \(json.expires_in)s")
            return true
        } catch {
            SonosLog.error(.sonosAuth, "token request failed: \(error)")
            lastErrorMessage = "Sonos token exchange failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Access Token (auto-refresh)

    func validAccessToken() async -> String? {
        if sessionState == .expired { return nil }

        guard let token = readKeychain(.accessToken) else {
            sessionState = .disconnected
            return nil
        }

        if let expiryStr = readKeychain(.tokenExpiry),
           let expiry = Double(expiryStr),
           Date().timeIntervalSince1970 < expiry {
            // Mirror to SharedStorage every time so the widget extension always has a fresh copy.
            SharedStorage.cloudAccessToken = token
            SharedStorage.cloudTokenExpiry = Date(timeIntervalSince1970: expiry)
            sessionState = .connected
            lastErrorMessage = nil
            return token
        }

        let refreshed = await refreshAccessToken()
        return refreshed ? readKeychain(.accessToken) : nil
    }

    // MARK: - Logout

    func logout() {
        for key in KeychainKey.allCases { deleteKeychain(key) }
        SharedStorage.cloudAccessToken = nil
        SharedStorage.cloudTokenExpiry = .distantPast
        sessionState = .disconnected
        lastErrorMessage = nil
    }

    func markSessionExpired() {
        guard hasStoredCredentials else {
            sessionState = .disconnected
            lastErrorMessage = nil
            return
        }
        SharedStorage.cloudAccessToken = nil
        SharedStorage.cloudTokenExpiry = .distantPast
        sessionState = .expired
        lastErrorMessage = "Sonos Cloud session expired. Reconnect your Sonos account."
    }

    private func restoreStateAfterLoginCancellation(previousState: SessionState) {
        guard hasStoredCredentials else {
            sessionState = .disconnected
            return
        }
        sessionState = previousState == .checking ? .connected : previousState
    }

    private func restoreStateAfterFailedTokenRequest() {
        sessionState = hasStoredCredentials ? .expired : .disconnected
    }

    private static func restoredSessionState(hasStoredCredentials: Bool) -> SessionState {
        guard hasStoredCredentials else { return .disconnected }
        guard let raw = UserDefaults.standard.string(forKey: sessionStateKey),
              let state = SessionState(rawValue: raw) else {
            return .connected
        }
        return state == .checking ? .connected : state
    }

    private func persistSessionState() {
        UserDefaults.standard.set(sessionState.rawValue, forKey: Self.sessionStateKey)
    }

    static func oauthConfigurationFailureMessage(
        clientID: String = SonosAuth.clientID,
        clientSecret: String = SonosAuth.clientSecret,
        redirectURI: String = SonosAuth.redirectURI
    ) -> String? {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRedirectURI = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedClientID.isEmpty {
            return "Sonos OAuth client ID is missing. Check Config/SonosSecrets.xcconfig."
        }
        if trimmedClientSecret.isEmpty {
            return "Sonos OAuth client secret is missing. Check Config/SonosSecrets.xcconfig."
        }
        if trimmedRedirectURI.isEmpty {
            return "Sonos OAuth redirect URI is missing. Check Config/SonosSecrets.xcconfig."
        }
        guard let url = URL(string: trimmedRedirectURI),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return "Sonos OAuth redirect URI is not a valid URL. Check Config/SonosSecrets.xcconfig."
        }
        return nil
    }

    private static func loginFailureMessage(error: Error?) -> String {
        guard let error else {
            return "Sonos sign-in did not return to the app. Check that the OAuth redirect page opens sonoswidget://callback."
        }
        if let authError = error as? ASWebAuthenticationSessionError {
            switch authError.code {
            case .canceledLogin:
                return "Sonos sign-in was cancelled before the app received a callback."
            case .presentationContextInvalid, .presentationContextNotProvided:
                return "Could not present Sonos sign-in. Try again from the foreground app window."
            @unknown default:
                break
            }
        }
        return "Sonos sign-in failed: \(error.localizedDescription)"
    }

    private func recordFailure(_ message: String) {
        lastErrorMessage = message
        SonosLog.error(.sonosAuth, message)
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
