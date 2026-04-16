import Foundation

enum SonosAPI {

    static let port = 1400
    private static let avTransport = "/MediaRenderer/AVTransport/Control"
    private static let renderingControl = "/MediaRenderer/RenderingControl/Control"
    private static let zoneGroupTopology = "/ZoneGroupTopology/Control"

    // MARK: - Playback Controls

    nonisolated static func play(ip: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport", action: "Play",
                           body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    nonisolated static func pause(ip: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport", action: "Pause",
                           body: "<InstanceID>0</InstanceID>")
    }

    nonisolated static func next(ip: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport", action: "Next",
                           body: "<InstanceID>0</InstanceID>")
    }

    nonisolated static func previous(ip: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport", action: "Previous",
                           body: "<InstanceID>0</InstanceID>")
    }

    // MARK: - State Queries

    nonisolated static func getTransportInfo(ip: String) async throws -> TransportState {
        let xml = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                                 action: "GetTransportInfo", body: "<InstanceID>0</InstanceID>")
        let raw = extractTag("CurrentTransportState", from: xml) ?? "UNKNOWN"
        return TransportState(rawValue: raw) ?? .unknown
    }

    nonisolated static func getPositionInfo(ip: String) async throws -> TrackInfo {
        let xml = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                                 action: "GetPositionInfo", body: "<InstanceID>0</InstanceID>")

        let duration = extractTag("TrackDuration", from: xml)
        let position = extractTag("RelTime", from: xml)

        var title = "Unknown"
        var artist = "Unknown"
        var album = "Unknown"
        var albumArtURL: String?

        if let raw = extractTag("TrackMetaData", from: xml) {
            let meta = decodeXMLEntities(raw)
            title = extractTag("dc:title", from: meta) ?? "Unknown"
            artist = extractTag("dc:creator", from: meta) ?? "Unknown"
            album = extractTag("upnp:album", from: meta) ?? "Unknown"
            if let artPath = extractTag("upnp:albumArtURI", from: meta) {
                albumArtURL = artPath.hasPrefix("http") ? artPath : "http://\(ip):\(port)\(artPath)"
            }
        }

        return TrackInfo(title: title, artist: artist, album: album,
                         albumArtURL: albumArtURL, duration: duration, position: position)
    }

    // MARK: - Volume

    nonisolated static func getVolume(ip: String) async throws -> Int {
        let xml = try await soap(ip: ip, endpoint: renderingControl, service: "RenderingControl",
                                 action: "GetVolume",
                                 body: "<InstanceID>0</InstanceID><Channel>Master</Channel>")
        guard let str = extractTag("CurrentVolume", from: xml), let vol = Int(str) else { return 0 }
        return vol
    }

    nonisolated static func setVolume(ip: String, volume: Int) async throws {
        let clamped = max(0, min(100, volume))
        _ = try await soap(ip: ip, endpoint: renderingControl, service: "RenderingControl",
                           action: "SetVolume",
                           body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(clamped)</DesiredVolume>")
    }

    // MARK: - Discovery (via one known speaker)

    nonisolated static func getZoneGroupState(ip: String) async throws -> [SonosPlayer] {
        let xml = try await soap(ip: ip, endpoint: zoneGroupTopology, service: "ZoneGroupTopology",
                                 action: "GetZoneGroupState", body: "")
        guard let raw = extractTag("ZoneGroupState", from: xml) else { return [] }
        let decoded = decodeXMLEntities(raw)
        return parseZoneMembers(decoded)
    }

    nonisolated static func getDeviceName(ip: String) async throws -> String {
        let url = URL(string: "http://\(ip):\(port)/xml/device_description.xml")!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, _) = try await URLSession.shared.data(for: request)
        let xml = String(data: data, encoding: .utf8) ?? ""
        return extractTag("roomName", from: xml) ?? ip
    }

    // MARK: - SOAP Internals

    private nonisolated static func soap(ip: String, endpoint: String, service: String,
                                         action: String, body: String) async throws -> String {
        let url = URL(string: "http://\(ip):\(port)\(endpoint)")!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = envelope(service: service, action: action, body: body).data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private nonisolated static func envelope(service: String, action: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:\(service):1">\
        \(body)</u:\(action)></s:Body></s:Envelope>
        """
    }

    // MARK: - XML Helpers

    nonisolated static func extractTag(_ tag: String, from xml: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escaped)[^>]*>(.*?)</\(escaped)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range])
    }

    private nonisolated static func decodeXMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private nonisolated static func parseZoneMembers(_ xml: String) -> [SonosPlayer] {
        let pattern = "<ZoneGroupMember[^/]*?/>"  // self-closing tags
        let patternOpen = "<ZoneGroupMember[^>]*?>"  // or open tags
        var players: [SonosPlayer] = []

        for pat in [pattern, patternOpen] {
            guard let regex = try? NSRegularExpression(pattern: pat, options: .dotMatchesLineSeparators) else { continue }
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                guard let range = Range(match.range, in: xml) else { continue }
                let tag = String(xml[range])

                let uuid = attr("UUID", in: tag) ?? UUID().uuidString
                let name = attr("ZoneName", in: tag) ?? "Unknown"
                let location = attr("Location", in: tag) ?? ""

                if let url = URL(string: location), let host = url.host {
                    let isCoord = tag.contains("Coordinator")
                    players.append(SonosPlayer(id: uuid, name: name, ipAddress: host, isCoordinator: isCoord))
                }
            }
            if !players.isEmpty { break }
        }

        return players
    }

    private nonisolated static func attr(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }
}
