import Foundation

enum SonosAPI {

    static let port = 1400
    private static let avTransport = "/MediaRenderer/AVTransport/Control"
    private static let renderingControl = "/MediaRenderer/RenderingControl/Control"
    private static let zoneGroupTopology = "/ZoneGroupTopology/Control"
    private static let contentDirectory = "/MediaServer/ContentDirectory/Control"

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

    nonisolated static func seek(ip: String, position: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport", action: "Seek",
                           body: "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(position)</Target>")
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

    // MARK: - Queue

    nonisolated static func getQueue(ip: String, start: Int = 0, count: Int = 100) async throws -> [QueueItem] {
        let body = "<ObjectID>Q:0</ObjectID>" +
            "<BrowseFlag>BrowseDirectChildren</BrowseFlag>" +
            "<Filter>dc:title,res,dc:creator,upnp:artist,upnp:album,upnp:albumArtURI</Filter>" +
            "<StartingIndex>\(start)</StartingIndex>" +
            "<RequestedCount>\(count)</RequestedCount>" +
            "<SortCriteria></SortCriteria>"
        let xml = try await soap(ip: ip, endpoint: contentDirectory, service: "ContentDirectory",
                                 action: "Browse", body: body)
        guard let result = extractTag("Result", from: xml) else { return [] }
        return parseQueueItems(decodeXMLEntities(result), speakerIP: ip)
    }

    // MARK: - Discovery

    nonisolated static func getZoneGroupState(ip: String) async throws -> [SonosPlayer] {
        let xml = try await soap(ip: ip, endpoint: zoneGroupTopology, service: "ZoneGroupTopology",
                                 action: "GetZoneGroupState", body: "")
        guard let raw = extractTag("ZoneGroupState", from: xml) else { return [] }
        let decoded = decodeXMLEntities(raw)
        let grouped = parseZoneGroups(decoded)
        return grouped.isEmpty ? parseZoneMembersFlat(decoded) : grouped
    }

    nonisolated static func getDeviceName(ip: String) async throws -> String {
        let url = URL(string: "http://\(ip):\(port)/xml/device_description.xml")!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, _) = try await URLSession.shared.data(for: request)
        let xml = String(data: data, encoding: .utf8) ?? ""
        return extractTag("roomName", from: xml) ?? ip
    }

    // MARK: - Retry Helper

    nonisolated static func withRetry<T>(attempts: Int = 2, _ block: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<attempts {
            do { return try await block() }
            catch {
                lastError = error
                if attempt < attempts - 1 { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
        throw lastError ?? URLError(.unknown)
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

    private nonisolated static func attr(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    // MARK: - Zone Group Parsing (with group info)

    private nonisolated static func parseZoneGroups(_ xml: String) -> [SonosPlayer] {
        let groupPat = "<ZoneGroup\\s[^>]*Coordinator=\"([^\"]*)\"[^>]*ID=\"([^\"]*)\"[^>]*>(.*?)</ZoneGroup>"
        guard let groupRx = try? NSRegularExpression(pattern: groupPat, options: .dotMatchesLineSeparators) else { return [] }
        let groupMatches = groupRx.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        var players: [SonosPlayer] = []

        for gm in groupMatches {
            guard let coordRange = Range(gm.range(at: 1), in: xml),
                  let idRange = Range(gm.range(at: 2), in: xml),
                  let bodyRange = Range(gm.range(at: 3), in: xml) else { continue }

            let coordUUID = String(xml[coordRange])
            let groupId = String(xml[idRange])
            let body = String(xml[bodyRange])

            var members: [(uuid: String, name: String, ip: String)] = []
            var coordIP: String?

            let memberPat = "<ZoneGroupMember[^>]*?(?:/>|>)"
            guard let memberRx = try? NSRegularExpression(pattern: memberPat, options: .dotMatchesLineSeparators) else { continue }
            for mm in memberRx.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let r = Range(mm.range, in: body) else { continue }
                let tag = String(body[r])
                let uuid = attr("UUID", in: tag) ?? UUID().uuidString
                let name = attr("ZoneName", in: tag) ?? "Unknown"
                let location = attr("Location", in: tag) ?? ""
                if let url = URL(string: location), let host = url.host {
                    members.append((uuid, name, host))
                    if uuid == coordUUID { coordIP = host }
                }
            }

            for m in members {
                let isCoord = m.uuid == coordUUID
                players.append(SonosPlayer(
                    id: m.uuid, name: m.name, ipAddress: m.ip,
                    isCoordinator: isCoord, groupId: groupId,
                    coordinatorIP: isCoord ? nil : coordIP
                ))
            }
        }
        return players
    }

    private nonisolated static func parseZoneMembersFlat(_ xml: String) -> [SonosPlayer] {
        let patterns = ["<ZoneGroupMember[^/]*?/>", "<ZoneGroupMember[^>]*?>"]
        for pat in patterns {
            guard let regex = try? NSRegularExpression(pattern: pat, options: .dotMatchesLineSeparators) else { continue }
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            var players: [SonosPlayer] = []
            for match in matches {
                guard let range = Range(match.range, in: xml) else { continue }
                let tag = String(xml[range])
                let uuid = attr("UUID", in: tag) ?? UUID().uuidString
                let name = attr("ZoneName", in: tag) ?? "Unknown"
                let location = attr("Location", in: tag) ?? ""
                if let url = URL(string: location), let host = url.host {
                    players.append(SonosPlayer(id: uuid, name: name, ipAddress: host, isCoordinator: true))
                }
            }
            if !players.isEmpty { return players }
        }
        return []
    }

    // MARK: - Queue Parsing

    private nonisolated static func parseQueueItems(_ xml: String, speakerIP: String) -> [QueueItem] {
        let itemPat = "<item[^>]*>(.*?)</item>"
        guard let regex = try? NSRegularExpression(pattern: itemPat, options: .dotMatchesLineSeparators) else { return [] }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        return matches.enumerated().compactMap { idx, match in
            guard let range = Range(match.range(at: 1), in: xml) else { return nil }
            let item = String(xml[range])

            let title = extractTag("dc:title", from: item) ?? "Unknown"
            let artist = extractTag("dc:creator", from: item) ?? extractTag("upnp:artist", from: item) ?? "Unknown"
            let album = extractTag("upnp:album", from: item) ?? ""
            var art: String?
            if let p = extractTag("upnp:albumArtURI", from: item) {
                art = p.hasPrefix("http") ? p : "http://\(speakerIP):\(port)\(p)"
            }
            return QueueItem(id: "\(idx)", title: title, artist: artist, album: album, albumArtURL: art)
        }
    }
}
