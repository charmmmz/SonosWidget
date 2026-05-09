import Foundation
import Security

struct HueBridgeRequest: Equatable, Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data?

    init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

protocol HueBridgeTransport: AnyObject {
    func send(_ request: HueBridgeRequest) async throws -> Data
}

enum HueBridgeError: Error, LocalizedError, Equatable {
    case bridgeURLUnavailable
    case linkButtonNotPressed
    case missingApplicationKey
    case httpStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .bridgeURLUnavailable:
            return "Hue bridge URL is unavailable."
        case .linkButtonNotPressed:
            return "Press the Hue Bridge link button and try again."
        case .missingApplicationKey:
            return "Hue bridge application key is missing."
        case .httpStatus(let statusCode):
            return "Hue bridge request failed with HTTP status \(statusCode)."
        case .emptyResponse:
            return "Hue bridge returned an empty response."
        }
    }
}

final class URLSessionHueBridgeTransport: NSObject, HueBridgeTransport, URLSessionDelegate {
    private let baseURL: URL
    private var session: URLSession!

    init(baseURL: URL) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        super.init()

        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func send(_ request: HueBridgeRequest) async throws -> Data {
        guard let url = URL(string: request.path, relativeTo: baseURL)?.absoluteURL else {
            throw HueBridgeError.bridgeURLUnavailable
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: urlRequest)
        if let httpResponse = response as? HTTPURLResponse,
           !(200 ... 299).contains(httpResponse.statusCode) {
            throw HueBridgeError.httpStatus(httpResponse.statusCode)
        }

        return data
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard challenge.protectionSpace.host.matchesHueBridgeHost(baseURL.host) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if SecTrustEvaluateWithError(serverTrust, nil) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        if challenge.protectionSpace.host.isLocalHueBridgeHost {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private final class UnavailableHueBridgeTransport: HueBridgeTransport {
    func send(_ request: HueBridgeRequest) async throws -> Data {
        throw HueBridgeError.bridgeURLUnavailable
    }
}

struct HueBridgeResources: Equatable, Sendable {
    var lights: [HueLightResource]
    var areas: [HueAreaResource]
}

protocol HueLightUpdating {
    func updateLight(id: String, body: [String: HueJSONValue]) async throws
}

struct HueBridgeClient {
    private let bridge: HueBridgeInfo
    private let credentialStore: HueCredentialStore
    private let transport: HueBridgeTransport
    private let applicationKeyProvider: (() -> String?)?

    init(
        bridge: HueBridgeInfo,
        credentialStore: HueCredentialStore = HueCredentialStore(),
        transport: HueBridgeTransport? = nil,
        applicationKeyProvider: (() -> String?)? = nil
    ) {
        self.bridge = bridge
        self.credentialStore = credentialStore
        if let transport {
            self.transport = transport
        } else if let baseURL = bridge.baseURL {
            self.transport = URLSessionHueBridgeTransport(baseURL: baseURL)
        } else {
            self.transport = UnavailableHueBridgeTransport()
        }
        self.applicationKeyProvider = applicationKeyProvider
    }

    func pairBridge(deviceType: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["devicetype": deviceType])
        let request = HueBridgeRequest(
            method: "POST",
            path: "/api",
            headers: ["Content-Type": "application/json"],
            body: body
        )

        let data = try await resolvedTransport().send(request)
        let response = try JSONDecoder().decode([HuePairingResponse].self, from: data)

        if response.contains(where: { $0.error?.type == 101 }) {
            throw HueBridgeError.linkButtonNotPressed
        }

        guard let applicationKey = response.compactMap(\.success?.username).first else {
            throw HueBridgeError.emptyResponse
        }

        credentialStore.saveApplicationKey(applicationKey, forBridgeID: bridge.id)
        return applicationKey
    }

    func fetchResources() async throws -> HueBridgeResources {
        let lightEnvelope: HueV2Envelope<HueLightDTO> = try await sendAuthenticatedGET(
            path: "/clip/v2/resource/light"
        )
        let roomEnvelope: HueV2Envelope<HueAreaDTO> = try await sendAuthenticatedGET(
            path: "/clip/v2/resource/room"
        )
        let zoneEnvelope: HueV2Envelope<HueAreaDTO> = try await sendAuthenticatedGET(
            path: "/clip/v2/resource/zone"
        )
        let entertainmentEnvelope: HueV2Envelope<HueEntertainmentConfigurationDTO> = try await sendAuthenticatedGET(
            path: "/clip/v2/resource/entertainment_configuration"
        )

        let serviceToLightID = lightEnvelope.data.reduce(into: [String: String]()) { result, light in
            light.services?.forEach { service in
                result[service.rid] = light.id
            }
        }
        let entertainmentAreas = entertainmentEnvelope.data.map {
            $0.resource(kind: .entertainmentArea, serviceToLightID: serviceToLightID)
        }
        let rooms = roomEnvelope.data.map { $0.resource(kind: .room) }
        let zones = zoneEnvelope.data.map { $0.resource(kind: .zone) }

        return HueBridgeResources(
            lights: lightEnvelope.data.map(\.resource),
            areas: entertainmentAreas + rooms + zones
        )
    }

    func updateLight(id: String, body: [String: HueJSONValue]) async throws {
        let jsonBody = try JSONSerialization.data(
            withJSONObject: body.mapValues(\.jsonSerializationValue)
        )
        let request = try authenticatedRequest(
            method: "PUT",
            path: "/clip/v2/resource/light/\(id)",
            body: jsonBody
        )

        _ = try await resolvedTransport().send(request)
    }

    private func sendAuthenticatedGET<T: Decodable>(path: String) async throws -> T {
        let request = try authenticatedRequest(method: "GET", path: path)
        let data = try await resolvedTransport().send(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func authenticatedRequest(method: String, path: String, body: Data? = nil) throws -> HueBridgeRequest {
        guard let applicationKey = applicationKeyProvider?() ?? credentialStore.applicationKey(forBridgeID: bridge.id),
              !applicationKey.isEmpty else {
            throw HueBridgeError.missingApplicationKey
        }

        return HueBridgeRequest(
            method: method,
            path: path,
            headers: [
                "Content-Type": "application/json",
                "hue-application-key": applicationKey
            ],
            body: body
        )
    }

    private func resolvedTransport() throws -> HueBridgeTransport {
        transport
    }
}

extension HueBridgeClient: HueLightUpdating {}

private extension String {
    func matchesHueBridgeHost(_ configuredHost: String?) -> Bool {
        guard let configuredHost else {
            return false
        }

        return normalizedHueBridgeHost == configuredHost.normalizedHueBridgeHost
    }

    var isLocalHueBridgeHost: Bool {
        let host = normalizedHueBridgeHost
        if host == "localhost" || host == "::1" {
            return true
        }
        if host.hasSuffix(".local") {
            return true
        }
        if !host.contains(".") && !host.contains(":") {
            return true
        }

        return host.isPrivateOrLoopbackIPv4Address
    }

    private var normalizedHueBridgeHost: String {
        lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private var isPrivateOrLoopbackIPv4Address: Bool {
        let octets = split(separator: ".")
        guard octets.count == 4,
              let first = UInt8(octets[0]),
              let second = UInt8(octets[1]),
              octets.dropFirst(2).allSatisfy({ UInt8($0) != nil }) else {
            return false
        }

        return first == 10
            || first == 127
            || (first == 172 && (16 ... 31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
    }
}

enum HueJSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([HueJSONValue])
    case object([String: HueJSONValue])

    var jsonSerializationValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .array(let values):
            return values.map(\.jsonSerializationValue)
        case .object(let values):
            return values.mapValues(\.jsonSerializationValue)
        }
    }
}

private struct HuePairingResponse: Decodable {
    var success: HuePairingSuccess?
    var error: HuePairingError?
}

private struct HuePairingSuccess: Decodable {
    var username: String
}

private struct HuePairingError: Decodable {
    var type: Int
}

private struct HueV2Envelope<Resource: Decodable>: Decodable {
    var data: [Resource]
}

private struct HueMetadataDTO: Decodable {
    var name: String?
}

private struct HueResourceReferenceDTO: Decodable {
    var rid: String
    var rtype: String
}

private struct HueGradientDTO: Decodable {
    var pointsCapable: Int?

    private enum CodingKeys: String, CodingKey {
        case pointsCapable = "points_capable"
    }
}

private struct HueJSONPresenceDTO: Decodable {}

private struct HueLightDTO: Decodable {
    var id: String
    var metadata: HueMetadataDTO?
    var owner: HueResourceReferenceDTO?
    var services: [HueResourceReferenceDTO]?
    var color: HueJSONPresenceDTO?
    var gradient: HueGradientDTO?
    var mode: String?

    var resource: HueLightResource {
        HueLightResource(
            id: id,
            name: metadata?.name ?? id,
            ownerID: owner?.rid,
            supportsColor: color != nil,
            supportsGradient: (gradient?.pointsCapable ?? 0) > 1,
            supportsEntertainment: true
        )
    }
}

private struct HueAreaDTO: Decodable {
    var id: String
    var metadata: HueMetadataDTO?
    var children: [HueResourceReferenceDTO]?

    func resource(kind: HueAreaResource.Kind) -> HueAreaResource {
        HueAreaResource(
            id: id,
            name: metadata?.name ?? id,
            kind: kind,
            childLightIDs: children?.compactMap { $0.rtype == "light" ? $0.rid : nil } ?? []
        )
    }
}

private struct HueEntertainmentConfigurationDTO: Decodable {
    var id: String
    var metadata: HueMetadataDTO?
    var lightServices: [HueResourceReferenceDTO]?
    var channels: [HueEntertainmentChannelDTO]?

    private enum CodingKeys: String, CodingKey {
        case id
        case metadata
        case lightServices = "light_services"
        case channels
    }

    func resource(
        kind: HueAreaResource.Kind,
        serviceToLightID: [String: String] = [:]
    ) -> HueAreaResource {
        var seenLightIDs = Set<String>()
        let channelServices = channels?
            .flatMap { $0.members ?? [] }
            .compactMap(\.service) ?? []
        let serviceReferences = (lightServices ?? []) + channelServices
        let lightIDs = serviceReferences.compactMap { service -> String? in
            let lightID: String?
            if service.rtype == "light" {
                lightID = service.rid
            } else {
                lightID = serviceToLightID[service.rid]
            }

            guard let lightID, !seenLightIDs.contains(lightID) else {
                return nil
            }

            seenLightIDs.insert(lightID)
            return lightID
        }

        return HueAreaResource(
            id: id,
            name: metadata?.name ?? id,
            kind: kind,
            childLightIDs: lightIDs
        )
    }
}

private struct HueEntertainmentChannelDTO: Decodable {
    var members: [HueEntertainmentMemberDTO]?
}

private struct HueEntertainmentMemberDTO: Decodable {
    var service: HueResourceReferenceDTO?
}
