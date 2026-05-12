import Foundation
import Darwin
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

struct HueBridgeResponse: Equatable, Sendable {
    var data: Data
    var headers: [String: String]

    func headerValue(named name: String) -> String? {
        headers[name.lowercased()]
    }
}

protocol HueBridgeTransport: AnyObject {
    func send(_ request: HueBridgeRequest) async throws -> Data
    func sendResponse(_ request: HueBridgeRequest) async throws -> HueBridgeResponse
}

extension HueBridgeTransport {
    func sendResponse(_ request: HueBridgeRequest) async throws -> HueBridgeResponse {
        HueBridgeResponse(data: try await send(request), headers: [:])
    }
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
        try await sendResponse(request).data
    }

    func sendResponse(_ request: HueBridgeRequest) async throws -> HueBridgeResponse {
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

        let headers = (response as? HTTPURLResponse)?.allHeaderFields.reduce(
            into: [String: String]()
        ) { result, entry in
            guard let name = entry.key as? String else { return }
            result[name.lowercased()] = "\(entry.value)"
        } ?? [:]

        return HueBridgeResponse(data: data, headers: headers)
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

struct HueBridgeResources: Codable, Equatable, Sendable {
    var lights: [HueLightResource]
    var areas: [HueAreaResource]

    static let empty = HueBridgeResources(lights: [], areas: [])

    var needsFunctionMetadataRefresh: Bool {
        lights.contains { !$0.functionMetadataResolved }
    }
}

struct HueLocalBridgeRecord: Equatable, Sendable {
    var name: String
    var hostName: String?
    var ipAddresses: [String]
}

@MainActor
protocol HueLocalBridgeBrowsing {
    func discover(timeout: TimeInterval) async -> [HueLocalBridgeRecord]
}

@MainActor
final class NetServiceHueLocalBridgeBrowser: NSObject, HueLocalBridgeBrowsing {
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var records: [HueLocalBridgeRecord] = []
    private var continuation: CheckedContinuation<[HueLocalBridgeRecord], Never>?
    private var isFinished = false

    func discover(timeout: TimeInterval) async -> [HueLocalBridgeRecord] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.isFinished = false
            self.records = []
            self.services = []

            let browser = NetServiceBrowser()
            browser.delegate = self
            self.browser = browser
            browser.searchForServices(ofType: "_hue._tcp.", inDomain: "local.")

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish()
            }
        }
    }

    private func finish() {
        guard !isFinished else {
            return
        }

        isFinished = true
        browser?.stop()
        services.forEach { $0.stop() }
        continuation?.resume(returning: records)
        continuation = nil
        browser = nil
        services = []
    }
}

extension NetServiceHueLocalBridgeBrowser: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 2)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let record = HueLocalBridgeRecord(
            name: sender.name,
            hostName: sender.hostName,
            ipAddresses: sender.ipv4Addresses
        )
        if !record.ipAddresses.isEmpty {
            records.append(record)
        }
    }
}

private extension NetService {
    nonisolated var ipv4Addresses: [String] {
        addresses?.compactMap(Self.ipv4Address(from:)) ?? []
    }

    nonisolated static func ipv4Address(from data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer -> String? in
            guard let baseAddress = rawBuffer.baseAddress else {
                return nil
            }

            let socketAddress = baseAddress.assumingMemoryBound(to: sockaddr.self)
            guard socketAddress.pointee.sa_family == sa_family_t(AF_INET) else {
                return nil
            }

            var internetAddress = baseAddress
                .assumingMemoryBound(to: sockaddr_in.self)
                .pointee
                .sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard let cString = inet_ntop(AF_INET, &internetAddress, &buffer, socklen_t(INET_ADDRSTRLEN)) else {
                return nil
            }

            return String(cString: cString)
        }
    }
}

enum HueBridgeDiscovery {
    @MainActor
    static func discoverLocal(
        browser: HueLocalBridgeBrowsing? = nil,
        timeout: TimeInterval = 4
    ) async -> [HueBridgeInfo] {
        let browser = browser ?? NetServiceHueLocalBridgeBrowser()
        let records = await browser.discover(timeout: timeout)
        return bridgeInfos(fromLocalRecords: records)
    }

    static func bridgeInfos(fromLocalRecords records: [HueLocalBridgeRecord]) -> [HueBridgeInfo] {
        var seenIPs = Set<String>()
        return records.compactMap { record in
            guard let ipAddress = record.ipAddresses.first,
                  seenIPs.insert(ipAddress).inserted else {
                return nil
            }

            return HueBridgeInfo(
                id: localBridgeID(from: record, ipAddress: ipAddress),
                ipAddress: ipAddress,
                name: localBridgeName(from: record)
            )
        }
    }

    private static func localBridgeID(from record: HueLocalBridgeRecord, ipAddress: String) -> String {
        let normalizedName = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedName = normalizedName.lowercased()
        if lowercasedName.hasPrefix("philips hue - ") {
            return String(normalizedName.dropFirst("Philips hue - ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        if let hostName = record.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
           !hostName.isEmpty {
            return hostName.lowercased()
        }

        return ipAddress
    }

    private static func localBridgeName(from record: HueLocalBridgeRecord) -> String {
        let normalizedName = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.lowercased().hasPrefix("philips hue - ") {
            return "Philips hue"
        }

        return normalizedName.isEmpty ? "Hue Bridge" : normalizedName
    }
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
        let body = try JSONSerialization.data(withJSONObject: [
            "devicetype": deviceType,
            "generateclientkey": true,
        ])
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
        if let clientKey = response.compactMap(\.success?.clientKey).first, !clientKey.isEmpty {
            credentialStore.saveStreamingClientKey(clientKey, forBridgeID: bridge.id)
        }
        if let applicationID = try await fetchStreamingApplicationID(applicationKey: applicationKey),
           !applicationID.isEmpty {
            credentialStore.saveStreamingApplicationId(applicationID, forBridgeID: bridge.id)
        }
        return applicationKey
    }

    func fetchResources() async throws -> HueBridgeResources {
        let lightEnvelope: HueV2Envelope<HueLightDTO> = try await sendAuthenticatedGET(
            path: "/clip/v2/resource/light"
        )
        let deviceEnvelope: HueV2Envelope<HueDeviceDTO> = try await sendAuthenticatedGET(
            path: "/clip/v2/resource/device"
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

        var serviceToLightID = lightEnvelope.data.reduce(into: [String: String]()) { result, light in
            result[light.id] = light.id
            light.services?.forEach { service in
                result[service.rid] = light.id
            }
        }
        let deviceLightIDsByID = deviceEnvelope.data.reduce(into: [String: [String]]()) { result, device in
            result[device.id] = device.lightIDs(serviceToLightID: serviceToLightID)
        }
        deviceEnvelope.data.forEach { device in
            guard let lightIDs = deviceLightIDsByID[device.id],
                  lightIDs.count == 1,
                  let lightID = lightIDs.first else {
                return
            }

            device.services?.forEach { service in
                if serviceToLightID[service.rid] == nil {
                    serviceToLightID[service.rid] = lightID
                }
            }
        }
        let lightDeviceIDsByID = lightEnvelope.data.reduce(into: [String: String]()) { result, light in
            if light.owner?.rtype == "device" {
                result[light.id] = light.owner?.rid
            }
        }
        let entertainmentAreas = entertainmentEnvelope.data.map {
            $0.resource(
                kind: .entertainmentArea,
                serviceToLightID: serviceToLightID,
                lightDeviceIDsByID: lightDeviceIDsByID
            )
        }
        let rooms = roomEnvelope.data.map {
            $0.resource(
                kind: .room,
                deviceLightIDsByID: deviceLightIDsByID
            )
        }
        let roomLightIDsByID = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0.childLightIDs) })
        let roomDeviceIDsByID = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0.childDeviceIDs) })
        let zones = zoneEnvelope.data.map {
            $0.resource(
                kind: .zone,
                deviceLightIDsByID: deviceLightIDsByID,
                roomLightIDsByID: roomLightIDsByID,
                roomDeviceIDsByID: roomDeviceIDsByID
            )
        }

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

    private func fetchStreamingApplicationID(applicationKey: String) async throws -> String? {
        let request = HueBridgeRequest(
            method: "GET",
            path: "/auth/v1",
            headers: [
                "Content-Type": "application/json",
                "hue-application-key": applicationKey
            ]
        )
        let response = try await resolvedTransport().sendResponse(request)
        return response.headerValue(named: "hue-application-id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    var clientKey: String?

    private enum CodingKeys: String, CodingKey {
        case username
        case clientKey = "clientkey"
    }
}

private struct HuePairingError: Decodable {
    var type: Int
}

private struct HueV2Envelope<Resource: Decodable>: Decodable {
    var data: [Resource]
}

private struct HueMetadataDTO: Decodable {
    var name: String?
    var function: String?
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
            supportsEntertainment: true,
            function: HueLightFunction(apiValue: metadata?.function),
            functionMetadataResolved: true
        )
    }
}

private struct HueDeviceDTO: Decodable {
    var id: String
    var services: [HueResourceReferenceDTO]?

    func lightIDs(serviceToLightID: [String: String]) -> [String] {
        let lightIDs = services?.compactMap { service -> String? in
            if service.rtype == "light" {
                return service.rid
            }

            return serviceToLightID[service.rid]
        } ?? []

        return Self.unique(lightIDs)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private struct HueAreaDTO: Decodable {
    var id: String
    var metadata: HueMetadataDTO?
    var children: [HueResourceReferenceDTO]?

    func resource(
        kind: HueAreaResource.Kind,
        deviceLightIDsByID: [String: [String]] = [:],
        roomLightIDsByID: [String: [String]] = [:],
        roomDeviceIDsByID: [String: [String]] = [:]
    ) -> HueAreaResource {
        var lightIDs: [String] = []
        var deviceIDs: [String] = []
        children?.forEach { child in
            switch child.rtype {
            case "light":
                lightIDs.append(child.rid)
            case "device":
                deviceIDs.append(child.rid)
                lightIDs.append(contentsOf: deviceLightIDsByID[child.rid] ?? [])
            case "room":
                lightIDs.append(contentsOf: roomLightIDsByID[child.rid] ?? [])
                deviceIDs.append(contentsOf: roomDeviceIDsByID[child.rid] ?? [])
            default:
                break
            }
        }

        return HueAreaResource(
            id: id,
            name: metadata?.name ?? id,
            kind: kind,
            childLightIDs: Self.unique(lightIDs),
            childDeviceIDs: Self.unique(deviceIDs)
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
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
        serviceToLightID: [String: String] = [:],
        lightDeviceIDsByID: [String: String] = [:]
    ) -> HueAreaResource {
        let entertainmentChannels = (channels ?? []).enumerated().compactMap { index, channel -> HueEntertainmentChannelResource? in
            let service = channel.members?.compactMap(\.service).first
            let lightID = service.flatMap { reference -> String? in
                if reference.rtype == "light" {
                    return reference.rid
                }

                return serviceToLightID[reference.rid]
            }

            return HueEntertainmentChannelResource(
                id: channel.resourceID(fallbackIndex: index),
                lightID: lightID,
                serviceID: service?.rid,
                position: channel.position?.resource
            )
        }
        let channelServices = channels?
            .flatMap { $0.members ?? [] }
            .compactMap(\.service) ?? []
        let serviceReferences = (lightServices ?? []) + channelServices
        let lightIDs = serviceReferences.compactMap { service -> String? in
            if service.rtype == "light" {
                return service.rid
            }

            return serviceToLightID[service.rid]
        }
        let uniqueLightIDs = Self.unique(lightIDs)
        let deviceIDs = uniqueLightIDs.compactMap { lightDeviceIDsByID[$0] }

        return HueAreaResource(
            id: id,
            name: metadata?.name ?? id,
            kind: kind,
            childLightIDs: uniqueLightIDs,
            childDeviceIDs: Self.unique(deviceIDs),
            entertainmentChannels: entertainmentChannels
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private struct HueEntertainmentChannelDTO: Decodable {
    var id: String?
    var channelID: Int?
    var position: HueEntertainmentPositionDTO?
    var members: [HueEntertainmentMemberDTO]?

    private enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
        case position
        case members
    }

    func resourceID(fallbackIndex: Int) -> String {
        if let id, !id.isEmpty {
            return id
        }
        if let channelID {
            return String(channelID)
        }

        return String(fallbackIndex)
    }
}

private struct HueEntertainmentPositionDTO: Decodable {
    var x: Double?
    var y: Double?
    var z: Double?

    var resource: HueEntertainmentChannelPosition? {
        guard let x, let y, let z else {
            return nil
        }

        return HueEntertainmentChannelPosition(x: x, y: y, z: z)
    }
}

private struct HueEntertainmentMemberDTO: Decodable {
    var service: HueResourceReferenceDTO?
}
