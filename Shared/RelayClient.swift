import Foundation

/// Stateless HTTP client for the optional Sonos Live Activity relay
/// (the Node.js service we ship in `nas-relay/`). All calls use the no-proxy
/// session so a Clash / Surge running on the iPhone doesn't intercept LAN
/// traffic and bounce us through 127.0.0.1 weirdness.
///
/// Errors are intentionally **not** swallowed here — callers (RelayManager,
/// SonosManager) decide whether a failure should mark the relay unreachable
/// or just be logged.
enum RelayClient {

    // MARK: - Health probe

    struct HealthResponse: Decodable, Sendable {
        struct Group: Decodable, Sendable {
            let groupId: String
            let speakerName: String?
            let isPlaying: Bool?
            let title: String?
        }
        struct HueAmbience: Decodable, Sendable {
            let configured: Bool?
            let enabled: Bool?
            let runtimeActive: Bool?
        }
        let ok: Bool
        let groups: [Group]
        let hueAmbience: HueAmbience?
    }

    static func health(baseURL: URL) async throws -> HealthResponse {
        let url = baseURL.appendingPathComponent("/api/health")
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    // MARK: - Activity registration

    /// Sent in the JSON body of `POST /api/register-activity`.
    private struct RegisterBody: Encodable {
        let groupId: String
        let token: String
        let attributes: Attributes
        struct Attributes: Encodable { let speakerName: String }
    }

    static func registerActivity(
        baseURL: URL,
        groupId: String,
        token: String,
        speakerName: String
    ) async throws {
        let url = baseURL.appendingPathComponent("/api/register-activity")
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = RegisterBody(
            groupId: groupId,
            token: token,
            attributes: .init(speakerName: speakerName)
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await noProxySession.data(for: request)
        try validate(response)
    }

    static func unregisterActivity(baseURL: URL, token: String) async throws {
        let escaped = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token
        let url = baseURL.appendingPathComponent("/api/register-activity/\(escaped)")
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "DELETE"
        let (_, response) = try await noProxySession.data(for: request)
        try validate(response)
    }

    // MARK: - Helpers

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
    }
}
