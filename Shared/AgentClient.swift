import Foundation

/// HTTP client for the optional NAS-side Python agent (`nas-agent/`).
enum AgentClient {

    struct HealthResponse: Decodable, Sendable {
        struct RelayBlock: Decodable, Sendable {
            let ok: Bool?
            let error: String?
        }
        let ok: Bool?
        let openaiConfigured: Bool?
        let relay: RelayBlock?

        enum CodingKeys: String, CodingKey {
            case ok
            case openaiConfigured = "openai_configured"
            case relay
        }
    }

    struct ChatResponse: Decodable, Sendable {
        let reply: String
    }

    private struct ChatBody: Encodable {
        let message: String
    }

    static func health(baseURL: URL) async throws -> HealthResponse {
        let url = baseURL.appendingPathComponent("/api/health")
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    static func chat(baseURL: URL, bearerToken: String, message: String) async throws -> String {
        let url = baseURL.appendingPathComponent("/api/chat")
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ChatBody(message: message))
        let (data, response) = try await noProxySession.data(for: request)
        try validate(response)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.reply
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
    }
}
