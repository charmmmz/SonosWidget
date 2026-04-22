import Foundation

enum SonosAPI {

    nonisolated static let port = 1400
    private nonisolated static let avTransport = "/MediaRenderer/AVTransport/Control"
    private nonisolated static let renderingControl = "/MediaRenderer/RenderingControl/Control"
    private nonisolated static let groupRenderingControl = "/MediaRenderer/GroupRenderingControl/Control"
    private nonisolated static let zoneGroupTopology = "/ZoneGroupTopology/Control"
    private nonisolated static let contentDirectory = "/MediaServer/ContentDirectory/Control"

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

    nonisolated static func getPlayMode(ip: String) async throws -> (shuffle: Bool, repeat: RepeatMode) {
        let xml = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                                 action: "GetTransportSettings", body: "<InstanceID>0</InstanceID>")
        let raw = extractTag("PlayMode", from: xml) ?? "NORMAL"
        switch raw {
        case "SHUFFLE":              return (true,  .all)
        case "SHUFFLE_NOREPEAT":     return (true,  .off)
        case "SHUFFLE_REPEAT_ONE":   return (true,  .one)
        case "REPEAT_ALL":           return (false, .all)
        case "REPEAT_ONE":           return (false, .one)
        default:                     return (false, .off)
        }
    }

    nonisolated static func setPlayMode(ip: String, shuffle: Bool, repeat repeatMode: RepeatMode) async throws {
        let mode: String
        switch (shuffle, repeatMode) {
        case (true,  .all): mode = "SHUFFLE"
        case (true,  .one): mode = "SHUFFLE_REPEAT_ONE"
        case (true,  .off): mode = "SHUFFLE_NOREPEAT"
        case (false, .all): mode = "REPEAT_ALL"
        case (false, .one): mode = "REPEAT_ONE"
        case (false, .off): mode = "NORMAL"
        }
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                           action: "SetPlayMode",
                           body: "<InstanceID>0</InstanceID><NewPlayMode>\(mode)</NewPlayMode>")
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

    nonisolated static func getMediaInfo(ip: String) async throws -> String {
        let xml = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                                 action: "GetMediaInfo", body: "<InstanceID>0</InstanceID>")
        return extractTag("CurrentURI", from: xml) ?? ""
    }

    /// Returns the raw SOAP XML from GetPositionInfo (for diagnostic use).
    nonisolated static func getRawPositionInfo(ip: String) async throws -> String {
        try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                       action: "GetPositionInfo", body: "<InstanceID>0</InstanceID>")
    }

    nonisolated static func getPositionInfo(ip: String) async throws -> TrackInfo {
        let xml = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                                 action: "GetPositionInfo", body: "<InstanceID>0</InstanceID>")

        let duration = extractTag("TrackDuration", from: xml)
        let position = extractTag("RelTime", from: xml)
        let trackURI = extractTag("TrackURI", from: xml) ?? ""

        var title = "Unknown"
        var artist = "Unknown"
        var album = "Unknown"
        var albumArtURL: String?
        var audioQuality: AudioQuality?

        let decodedURI = decodeXMLEntities(trackURI)
        let source = PlaybackSource.from(trackURI: decodedURI)

        if let raw = extractTag("TrackMetaData", from: xml) {
            let meta = decodeXMLEntities(raw)
            title = decodeXMLEntities(extractTag("dc:title", from: meta) ?? "Unknown")
            artist = decodeXMLEntities(extractTag("dc:creator", from: meta) ?? "Unknown")
            album = decodeXMLEntities(extractTag("upnp:album", from: meta) ?? "")

            // Radio streams put current track info in r:streamContent
            if let stream = extractTag("r:streamContent", from: meta), !stream.isEmpty {
                let decoded = decodeXMLEntities(stream)
                if decoded.contains("TITLE ") || decoded.contains("ARTIST ") {
                    // Pipe-delimited format: TYPE=SNG|TITLE ...|ARTIST ...|ALBUM ...
                    var fields: [String: String] = [:]
                    for segment in decoded.split(separator: "|") {
                        let s = String(segment)
                        for key in ["TITLE ", "ARTIST ", "ALBUM "] {
                            if s.hasPrefix(key) {
                                fields[key.trimmingCharacters(in: .whitespaces)] = String(s.dropFirst(key.count))
                            }
                        }
                    }
                    if let t = fields["TITLE"], !t.isEmpty { title = t }
                    if let a = fields["ARTIST"], !a.isEmpty { artist = a }
                    if let al = fields["ALBUM"], !al.isEmpty { album = al }
                } else if decoded.contains(" - ") {
                    let parts = decoded.split(separator: " - ", maxSplits: 1)
                    if parts.count == 2 {
                        artist = String(parts[0]).trimmingCharacters(in: .whitespaces)
                        title = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                } else if artist == "Unknown" || artist.isEmpty {
                    title = decoded
                }
            }

            if let artPath = extractTag("upnp:albumArtURI", from: meta) {
                var decoded = decodeXMLEntities(artPath)
                if decoded.contains("%25") {
                    decoded = decoded.removingPercentEncoding ?? decoded
                }
                albumArtURL = decoded.hasPrefix("http") ? decoded : "http://\(ip):\(port)\(decoded)"
            }
            audioQuality = parseAudioQuality(from: meta, source: source)
        }

        return TrackInfo(title: title, artist: artist, album: album,
                         albumArtURL: albumArtURL, duration: duration, position: position,
                         source: source, audioQuality: audioQuality,
                         trackURI: decodeXMLEntities(trackURI))
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

    /// Gets the group volume for a coordinator (represents all members proportionally).
    nonisolated static func getGroupVolume(ip: String) async throws -> Int {
        let xml = try await soap(ip: ip, endpoint: groupRenderingControl, service: "GroupRenderingControl",
                                 action: "GetGroupVolume",
                                 body: "<InstanceID>0</InstanceID>")
        guard let str = extractTag("CurrentVolume", from: xml), let vol = Int(str) else { return 0 }
        return vol
    }

    /// Sets volume for an entire group proportionally via GroupRenderingControl on the coordinator.
    nonisolated static func setGroupVolume(ip: String, volume: Int) async throws {
        let clamped = max(0, min(100, volume))
        _ = try await soap(ip: ip, endpoint: groupRenderingControl, service: "GroupRenderingControl",
                           action: "SetGroupVolume",
                           body: "<InstanceID>0</InstanceID><DesiredVolume>\(clamped)</DesiredVolume>")
    }

    // MARK: - Queue

    nonisolated static func getQueue(ip: String, start: Int = 0, count: Int = 500) async throws -> QueueResult {
        let body = "<ObjectID>Q:0</ObjectID>" +
            "<BrowseFlag>BrowseDirectChildren</BrowseFlag>" +
            "<Filter>*</Filter>" +
            "<StartingIndex>\(start)</StartingIndex>" +
            "<RequestedCount>\(count)</RequestedCount>" +
            "<SortCriteria></SortCriteria>"
        let xml = try await soap(ip: ip, endpoint: contentDirectory, service: "ContentDirectory",
                                 action: "Browse", body: body)
        let updateID = extractTag("UpdateID", from: xml) ?? "0"
        guard let result = extractTag("Result", from: xml) else {
            return QueueResult(items: [], updateID: updateID)
        }
        return QueueResult(items: parseQueueItems(decodeXMLEntities(result), speakerIP: ip),
                           updateID: updateID)
    }

    // MARK: - Queue Management

    @discardableResult
    nonisolated static func addURIToQueue(ip: String, uri: String, metadata: String,
                                          position: Int = 0, asNext: Bool = false) async throws -> Int {
        let escapedURI = escapeXML(uri)
        let escapedMeta = escapeXML(metadata)
        let xml = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                           action: "AddURIToQueue",
                           body: "<InstanceID>0</InstanceID>" +
                           "<EnqueuedURI>\(escapedURI)</EnqueuedURI>" +
                           "<EnqueuedURIMetaData>\(escapedMeta)</EnqueuedURIMetaData>" +
                           "<DesiredFirstTrackNumberEnqueued>\(position)</DesiredFirstTrackNumberEnqueued>" +
                           "<EnqueueAsNext>\(asNext ? 1 : 0)</EnqueueAsNext>")
        return Int(extractTag("FirstTrackNumberEnqueued", from: xml) ?? "1") ?? 1
    }

    nonisolated static func removeAllTracksFromQueue(ip: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                           action: "RemoveAllTracksFromQueue",
                           body: "<InstanceID>0</InstanceID>")
    }

    nonisolated static func removeTrackFromQueue(ip: String, objectID: String, updateID: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                           action: "RemoveTrackFromQueue",
                           body: "<InstanceID>0</InstanceID>" +
                           "<ObjectID>\(objectID)</ObjectID>" +
                           "<UpdateID>\(updateID)</UpdateID>")
    }

    nonisolated static func reorderTracksInQueue(ip: String, startIndex: Int, numTracks: Int,
                                                  insertBefore: Int, updateID: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                           action: "ReorderTracksInQueue",
                           body: "<InstanceID>0</InstanceID>" +
                           "<StartingIndex>\(startIndex)</StartingIndex>" +
                           "<NumberOfTracks>\(numTracks)</NumberOfTracks>" +
                           "<InsertBefore>\(insertBefore)</InsertBefore>" +
                           "<UpdateID>\(updateID)</UpdateID>")
    }

    nonisolated static func seekToTrack(ip: String, trackNumber: Int) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport", action: "Seek",
                           body: "<InstanceID>0</InstanceID><Unit>TRACK_NR</Unit><Target>\(trackNumber)</Target>")
    }

    nonisolated static func setAVTransportToQueue(ip: String, speakerUUID: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                           action: "SetAVTransportURI",
                           body: "<InstanceID>0</InstanceID>" +
                           "<CurrentURI>x-rincon-queue:\(speakerUUID)#0</CurrentURI>" +
                           "<CurrentURIMetaData></CurrentURIMetaData>")
    }

    nonisolated static func setAVTransportURI(ip: String, uri: String, metadata: String = "") async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                           action: "SetAVTransportURI",
                           body: "<InstanceID>0</InstanceID>" +
                           "<CurrentURI>\(escapeXML(uri))</CurrentURI>" +
                           "<CurrentURIMetaData>\(escapeXML(metadata))</CurrentURIMetaData>")
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
        let cleanIP = ip.contains(":") ? "[\(ip.split(separator: "%").first ?? Substring(ip))]" : ip
        guard let url = URL(string: "http://\(cleanIP):\(port)/xml/device_description.xml") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, _) = try await URLSession.shared.data(for: request)
        let xml = String(data: data, encoding: .utf8) ?? ""
        return extractTag("roomName", from: xml) ?? ip
    }

    // MARK: - Speaker Grouping

    nonisolated static func joinGroup(speakerIP: String, coordinatorUUID: String) async throws {
        _ = try await soap(ip: speakerIP, endpoint: avTransport, service: "AVTransport",
                           action: "SetAVTransportURI",
                           body: "<InstanceID>0</InstanceID>" +
                           "<CurrentURI>x-rincon:\(coordinatorUUID)</CurrentURI>" +
                           "<CurrentURIMetaData></CurrentURIMetaData>")
    }

    nonisolated static func leaveGroup(speakerIP: String) async throws {
        _ = try await soap(ip: speakerIP, endpoint: avTransport, service: "AVTransport",
                           action: "BecomeCoordinatorOfStandaloneGroup",
                           body: "<InstanceID>0</InstanceID>")
    }

    // MARK: - Sonos Favorites

    nonisolated static func addToFavorites(ip: String, title: String, uri: String,
                                            metadata: String, albumArtURI: String? = nil) async throws {
        var innerElements = "<dc:title>\(escapeXML(title))</dc:title>" +
            "<res>\(escapeXML(uri))</res>" +
            "<r:resMD>\(escapeXML(metadata))</r:resMD>"
        if let art = albumArtURI, !art.isEmpty {
            innerElements += "<upnp:albumArtURI>\(escapeXML(art))</upnp:albumArtURI>"
        }
        innerElements += "<upnp:class>object.item.sonos-favorite</upnp:class>"

        let didl = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" " +
            "xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" " +
            "xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">" +
            "<item id=\"\" parentID=\"FV:2\" restricted=\"false\">" +
            innerElements +
            "</item></DIDL-Lite>"

        _ = try await soap(ip: ip, endpoint: contentDirectory, service: "ContentDirectory",
                           action: "CreateObject",
                           body: "<ContainerID>FV:2</ContainerID>" +
                           "<Elements>\(escapeXML(didl))</Elements>")
    }

    nonisolated static func removeFromFavorites(ip: String, objectId: String) async throws {
        _ = try await soap(ip: ip, endpoint: contentDirectory, service: "ContentDirectory",
                           action: "DestroyObject",
                           body: "<ObjectID>\(escapeXML(objectId))</ObjectID>")
    }

    // MARK: - Browse (Content Directory)

    nonisolated static func browseFavorites(ip: String) async throws -> [BrowseItem] {
        try await browseContainer(ip: ip, objectID: "FV:2")
    }

    nonisolated static func browsePlaylists(ip: String) async throws -> [BrowseItem] {
        try await browseContainer(ip: ip, objectID: "SQ:")
    }

    nonisolated static func browseRadio(ip: String) async throws -> [BrowseItem] {
        try await browseContainer(ip: ip, objectID: "R:0/0")
    }

    private nonisolated static func browseContainer(ip: String, objectID: String, start: Int = 0,
                                                     count: Int = 100) async throws -> [BrowseItem] {
        let body = "<ObjectID>\(objectID)</ObjectID>" +
            "<BrowseFlag>BrowseDirectChildren</BrowseFlag>" +
            "<Filter>*</Filter>" +
            "<StartingIndex>\(start)</StartingIndex>" +
            "<RequestedCount>\(count)</RequestedCount>" +
            "<SortCriteria></SortCriteria>"
        let xml = try await soap(ip: ip, endpoint: contentDirectory, service: "ContentDirectory",
                                 action: "Browse", body: body)
        guard let result = extractTag("Result", from: xml) else { return [] }
        return parseBrowseItems(decodeXMLEntities(result), speakerIP: ip)
    }

    // MARK: - Music Services (SMAPI)

    nonisolated static func listMusicServices(ip: String) async throws -> [MusicService] {
        let endpoint = "/MusicServices/Control"
        let xml = try await soap(ip: ip, endpoint: endpoint, service: "MusicServices",
                                 action: "ListAvailableServices", body: "")
        guard let raw = extractTag("AvailableServiceDescriptorList", from: xml) else { return [] }
        let decoded = decodeXMLEntities(raw)

        // Parse the ServiceType mapping: "ServiceID:ServiceType,..."
        var typeToId: [String: Int] = [:]
        if let typeList = extractTag("AvailableServiceTypeList", from: xml) {
            for pair in typeList.split(separator: ",") {
                let parts = pair.split(separator: ":")
                if parts.count == 2, let sid = Int(parts[0]) {
                    typeToId[String(parts[1])] = sid
                }
            }
        }

        var services = parseMusicServices(decoded)
        // Store the reverse mapping (serviceId → serviceType) on each service
        let idToType = Dictionary(typeToId.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        for i in services.indices {
            services[i].serviceType = idToType[services[i].id] ?? ""
        }
        return services
    }

    nonisolated static func getSessionId(ip: String, serviceId: Int) async throws -> String {
        let endpoint = "/MusicServices/Control"
        let xml = try await soap(ip: ip, endpoint: endpoint, service: "MusicServices",
                                 action: "GetSessionId",
                                 body: "<ServiceId>\(serviceId)</ServiceId><Username></Username>")
        return extractTag("SessionId", from: xml) ?? ""
    }

    nonisolated static func searchMusicService(smapiURI: String, sessionId: String, serviceId: Int,
                                                searchTerm: String, category: String = "tracks") async throws -> [BrowseItem] {
        guard let url = URL(string: smapiURI) else { throw URLError(.badURL) }
        let escapedTerm = escapeXML(searchTerm)
        let soapBody = """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body><search xmlns="http://www.sonos.com/Services/1.1">\
            <id>\(category)</id><term>\(escapedTerm)</term><index>0</index><count>20</count>\
            </search></s:Body></s:Envelope>
            """
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"http://www.sonos.com/Services/1.1#search\"", forHTTPHeaderField: "SOAPACTION")
        if !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "X-Sonos-Session-Id")
        }
        request.httpBody = soapBody.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let xml = String(data: data, encoding: .utf8) ?? ""
        return parseSMAPIResults(xml, serviceId: serviceId)
    }

    /// Build DIDL-Lite metadata for a streaming service track so Sonos knows
    /// which service to use when resolving the URI.
    nonisolated static func buildDIDLMetadata(item: BrowseItem) -> String {
        guard let sid = item.serviceId else { return "" }
        return buildDIDLMetadata(
            itemId: item.id, title: item.title, artist: item.artist,
            album: item.album, albumArtURL: item.albumArtURL, serviceId: sid,
            desc: "SA_RINCON\(sid)_X_#Svc\(sid)-0-Token")
    }

    nonisolated static func buildDIDLMetadata(itemId: String, title: String, artist: String,
                                              album: String, albumArtURL: String?,
                                              serviceId: Int, desc: String) -> String {
        let t = escapeXML(title)
        let a = escapeXML(artist)
        let al = escapeXML(album)
        let art = escapeXML(albumArtURL ?? "")
        let id = escapeXML(itemId)
        return """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
        xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
        xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/">\
        <item id="\(id)" parentID="" restricted="true">\
        <dc:title>\(t)</dc:title>\
        <dc:creator>\(a)</dc:creator>\
        <upnp:album>\(al)</upnp:album>\
        <upnp:class>object.item.audioItem.musicTrack</upnp:class>\
        <upnp:albumArtURI>\(art)</upnp:albumArtURI>\
        <desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\
        \(desc)</desc>\
        </item></DIDL-Lite>
        """
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
        let cleanIP = ip.contains(":") ? "[\(ip.split(separator: "%").first ?? Substring(ip))]" : ip
        guard let url = URL(string: "http://\(cleanIP):\(port)\(endpoint)") else {
            throw URLError(.badURL)
        }
        let longActions: Set<String> = ["RemoveAllTracksFromQueue", "AddURIToQueue", "SetAVTransportURI", "Play"]
        let timeout: TimeInterval = longActions.contains(action) ? 30 : 10
        var request = URLRequest(url: url, timeoutInterval: timeout)
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
        let pattern = "<\(escaped)(?:\\s[^>]*)?>(.*?)</\(escaped)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range])
    }

    nonisolated static func decodeXMLEntities(_ text: String) -> String {
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

            var members: [(uuid: String, name: String, ip: String, invisible: Bool)] = []
            var coordIP: String?

            let memberPat = "<ZoneGroupMember[^>]*?(?:/>|>)"
            guard let memberRx = try? NSRegularExpression(pattern: memberPat, options: .dotMatchesLineSeparators) else { continue }
            for mm in memberRx.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let r = Range(mm.range, in: body) else { continue }
                let tag = String(body[r])
                let uuid = attr("UUID", in: tag) ?? UUID().uuidString
                let name = attr("ZoneName", in: tag) ?? "Unknown"
                let location = attr("Location", in: tag) ?? ""
                let invisible = attr("Invisible", in: tag) == "1"
                if let url = URL(string: location), let host = url.host {
                    members.append((uuid, name, host, invisible))
                    if uuid == coordUUID { coordIP = host }
                }
            }

            for m in members {
                let isCoord = m.uuid == coordUUID
                players.append(SonosPlayer(
                    id: m.uuid, name: m.name, ipAddress: m.ip,
                    isCoordinator: isCoord, groupId: groupId,
                    coordinatorIP: isCoord ? nil : coordIP,
                    isInvisible: m.invisible
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
        let itemPat = "<item\\s([^>]*)>(.*?)</item>"
        guard let regex = try? NSRegularExpression(pattern: itemPat, options: .dotMatchesLineSeparators) else { return [] }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        return matches.enumerated().compactMap { idx, match in
            guard let attrRange = Range(match.range(at: 1), in: xml),
                  let bodyRange = Range(match.range(at: 2), in: xml) else { return nil }
            let attrs = String(xml[attrRange])
            let item = String(xml[bodyRange])
            let objectID = attr("id", in: attrs) ?? "Q:0/\(idx)"

            let title = decodeXMLEntities(extractTag("dc:title", from: item) ?? "Unknown")
            let artist = decodeXMLEntities(extractTag("dc:creator", from: item) ?? extractTag("upnp:artist", from: item) ?? "Unknown")
            let album = decodeXMLEntities(extractTag("upnp:album", from: item) ?? "")
            let uri = extractTag("res", from: item).map { decodeXMLEntities($0) }
            var art: String?
            if let p = extractTag("upnp:albumArtURI", from: item) {
                var decoded = decodeXMLEntities(p)
                if decoded.contains("%25") {
                    decoded = decoded.removingPercentEncoding ?? decoded
                }
                art = decoded.hasPrefix("http") ? decoded : "http://\(speakerIP):\(port)\(decoded)"
            }

            let fullTag = Range(match.range, in: xml).map { String(xml[$0]) }
            return QueueItem(id: "\(idx)", objectID: objectID, trackNumber: idx + 1,
                             title: title, artist: artist, album: album, albumArtURL: art,
                             uri: uri, metaXML: fullTag)
        }
    }

    // MARK: - Browse Parsing

    private nonisolated static func parseBrowseItems(_ xml: String, speakerIP: String) -> [BrowseItem] {
        let containerPat = "<container\\s([^>]*)>(.*?)</container>"
        let itemPat = "<item\\s([^>]*)>(.*?)</item>"

        var results: [BrowseItem] = []

        for (pattern, isContainer) in [(containerPat, true), (itemPat, false)] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { continue }
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                guard let attrRange = Range(match.range(at: 1), in: xml),
                      let bodyRange = Range(match.range(at: 2), in: xml) else { continue }
                let attrs = String(xml[attrRange])
                let body = String(xml[bodyRange])
                let itemID = attr("id", in: attrs) ?? UUID().uuidString

                let title = decodeXMLEntities(extractTag("dc:title", from: body) ?? "Unknown")
                let artist = decodeXMLEntities(extractTag("dc:creator", from: body) ?? extractTag("upnp:artist", from: body) ?? "")
                let album = decodeXMLEntities(extractTag("upnp:album", from: body) ?? "")
                let uri = extractTag("res", from: body).map { decodeXMLEntities($0) }
                var art: String?
                if let p = extractTag("upnp:albumArtURI", from: body) {
                    var decoded = decodeXMLEntities(p)
                    if decoded.contains("%25") { decoded = decoded.removingPercentEncoding ?? decoded }
                    art = decoded.hasPrefix("http") ? decoded : "http://\(speakerIP):\(port)\(decoded)"
                }

                // Extract r:resMD (resource metadata for Favorites)
                var resMD: String?
                if let rawMD = extractTag("r:resMD", from: body) {
                    resMD = decodeXMLEntities(rawMD)
                }

                // If main <res> is missing, try to extract URI from resMD
                var finalURI = uri
                if (finalURI == nil || finalURI?.isEmpty == true), let md = resMD {
                    finalURI = extractTag("res", from: md).map { decodeXMLEntities($0) }
                }

                // Detect container-like URIs even when stored as <item> in Favorites
                let effectiveContainer = isContainer ||
                    (finalURI?.contains("x-rincon-cpcontainer:") == true)

                let fullTag = Range(match.range, in: xml).map { String(xml[$0]) }
                results.append(BrowseItem(id: itemID, title: title, artist: artist, album: album,
                                          albumArtURL: art, uri: finalURI, metaXML: fullTag,
                                          resMD: resMD, isContainer: effectiveContainer))
            }
        }
        return results
    }

    // MARK: - SMAPI Parsing

    private nonisolated static func parseSMAPIResults(_ xml: String, serviceId: Int) -> [BrowseItem] {
        let itemPat = "<mediaMetadata[^>]*>(.*?)</mediaMetadata>"
        guard let regex = try? NSRegularExpression(pattern: itemPat, options: .dotMatchesLineSeparators) else { return [] }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: xml) else { return nil }
            let body = String(xml[range])
            let id = extractTag("id", from: body) ?? UUID().uuidString
            let title = decodeXMLEntities(extractTag("title", from: body) ?? "Unknown")
            let artist = decodeXMLEntities(extractTag("artist", from: body) ?? "")
            let album = decodeXMLEntities(extractTag("album", from: body) ?? "")
            let art = extractTag("albumArtURI", from: body)
            let uri = extractTag("trackUri", from: body) ?? extractTag("uri", from: body)

            return BrowseItem(id: id, title: title, artist: artist, album: album,
                              albumArtURL: art, uri: uri, metaXML: nil, isContainer: false,
                              serviceId: serviceId)
        }
    }

    // MARK: - Music Service Parsing

    private nonisolated static func parseMusicServices(_ xml: String) -> [MusicService] {
        let pat = "<Service[^>]*?(?:/>|>(.*?)</Service>)"
        guard let regex = try? NSRegularExpression(pattern: pat, options: .dotMatchesLineSeparators) else { return [] }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        return matches.compactMap { match in
            guard let fullRange = Range(match.range, in: xml) else { return nil }
            let tag = String(xml[fullRange])
            guard let idStr = attr("Id", in: tag), let id = Int(idStr) else { return nil }
            let name = attr("Name", in: tag) ?? "Unknown"
            let smapiURI = attr("SecureUri", in: tag) ?? attr("Uri", in: tag) ?? ""
            let caps = Int(attr("Capabilities", in: tag) ?? "0") ?? 0
            let auth = attr("Auth", in: tag) ?? "Anonymous"
            guard !smapiURI.isEmpty else { return nil }
            return MusicService(id: id, name: name, smapiURI: smapiURI, capabilitiesMask: caps, authType: auth)
        }
    }

    // MARK: - Audio Quality Parsing

    private nonisolated static func parseAudioQuality(from meta: String, source: PlaybackSource) -> AudioQuality? {
        let resPat = "<res\\s([^>]*)>"
        guard let regex = try? NSRegularExpression(pattern: resPat, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: meta, range: NSRange(meta.startIndex..., in: meta)),
              let range = Range(match.range(at: 1), in: meta) else { return nil }
        let attrs = String(meta[range])

        guard let proto = attr("protocolInfo", in: attrs) else { return nil }
        let sr = attr("sampleFrequency", in: attrs)
        let bd = attr("bitsPerSample", in: attrs)
        let ch = attr("nrAudioChannels", in: attrs)
        let streamContent = extractTag("r:streamContent", from: meta) ?? ""

        return AudioQuality.from(protocolInfo: proto, sampleRate: sr, bitDepth: bd,
                                 channels: ch, streamContent: streamContent, source: source)
    }

    // MARK: - XML Escape

    nonisolated static func escapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&apos;")
    }
}
