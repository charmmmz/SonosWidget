import Foundation
import SwiftUI

@Observable
final class SearchManager {
    var favorites: [BrowseItem] = []
    var playlists: [BrowseItem] = []
    var radio: [BrowseItem] = []
    var searchResults: [ServiceSearchResult] = []
    var musicServices: [MusicService] = []
    var isLoadingBrowse = false
    var isSearching = false
    var isProbing = false
    var searchQuery = ""
    var errorMessage: String?

    // Station picker state
    struct RadioStationOption: Identifiable {
        let id: String // objectId e.g. "radio:ra.137938148"
        let name: String
        let artURL: String?
        let cloudServiceId: String?
        let accountId: String?
        let resMD: String?
    }
    var stationOptions: [RadioStationOption] = []
    var showStationPicker = false
    var pendingStationManager: SonosManager?

    /// Accounts detected via Sonos Cloud API.
    var linkedAccounts: [SonosCloudAPI.CloudMusicServiceAccount] = []
    /// User's per-service search toggle. Key = Cloud serviceId string.
    var serviceEnabled: [String: Bool] = [:]

    struct ServiceSearchResult: Identifiable {
        let id: String
        let serviceName: String
        var items: [BrowseItem]
    }

    private static let enabledKey = "SearchEnabledServices"

    private var speakerIP: String?
    private var searchTask: Task<Void, Never>?
    private var hasProbed = false
    /// Cached Cloud API favorites list for matching UPnP favorites to Cloud IDs.
    private var cloudFavorites: [SonosCloudAPI.CloudFavorite]?

    func configure(speakerIP: String?) {
        self.speakerIP = speakerIP
    }

    // MARK: - Service Detection via Cloud API

    func probeLinkedServices() async {
        guard !hasProbed else { return }
        isProbing = true

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            print("[Search] No Sonos Cloud auth, cannot detect services")
            isProbing = false
            hasProbed = true
            return
        }

        do {
            let accounts = try await SonosCloudAPI.getMusicServiceAccounts(
                token: token, householdId: householdId)
            linkedAccounts = accounts
            print("[Search] Cloud API detected \(accounts.count) linked services:")
            for a in accounts {
                print("[Search]   \(a.nickname ?? a.serviceId ?? "?") (service-id=\(a.serviceId ?? "?"))")
            }

            // Load saved toggle state, default all detected to enabled
            let saved = UserDefaults.standard.dictionary(forKey: Self.enabledKey) as? [String: Bool] ?? [:]
            for account in accounts {
                guard let sid = account.serviceId else { continue }
                serviceEnabled[sid] = saved[sid] ?? true
            }
        } catch {
            print("[Search] Cloud API detection failed: \(error)")
        }

        buildServiceIdMapping()
        hasProbed = true
        isProbing = false
    }

    private func persistToggles() {
        UserDefaults.standard.set(serviceEnabled, forKey: Self.enabledKey)
    }

    func setServiceEnabled(serviceId: String, enabled: Bool) {
        serviceEnabled[serviceId] = enabled
        persistToggles()
    }

    /// Service IDs enabled for search.
    var activeServiceIds: [String] {
        linkedAccounts.compactMap { account in
            guard let sid = account.serviceId,
                  serviceEnabled[sid] ?? true else { return nil }
            return sid
        }
    }

    var hasFinishedProbing: Bool { hasProbed }

    func resetProbe() {
        hasProbed = false
        linkedAccounts = []
    }

    func forceReprobe() async {
        hasProbed = false
        linkedAccounts = []
        await probeLinkedServices()
    }

    // MARK: - Grouped Favorites

    struct FavoriteGroup {
        let category: BrowseItem.FavoriteCategory
        let items: [BrowseItem]
    }

    var groupedFavorites: [FavoriteGroup] {
        let order: [BrowseItem.FavoriteCategory] = [.playlist, .album, .artist, .station, .other]
        var dict: [BrowseItem.FavoriteCategory: [BrowseItem]] = [:]
        for item in favorites {
            let cat = item.favoriteCategory
            dict[cat, default: []].append(item)
        }
        return order.compactMap { cat in
            guard let items = dict[cat], !items.isEmpty else { return nil }
            return FavoriteGroup(category: cat, items: items)
        }
    }

    // MARK: - Cloud → Local Service ID Mapping

    /// Maps Cloud API serviceId (e.g. "52231") to local Sonos sid (e.g. 204).
    private var cloudToLocalSid: [String: Int] = [:]
    /// Maps Cloud API serviceId to the account username (e.g. "X_#Svc52231-408f19a7-Token").
    private var cloudServiceUsername: [String: String] = [:]

    private func buildServiceIdMapping() {
        guard !linkedAccounts.isEmpty, !musicServices.isEmpty else { return }
        cloudToLocalSid.removeAll()
        cloudServiceUsername.removeAll()

        for account in linkedAccounts {
            guard let cloudId = account.serviceId else { continue }
            let cloudName = (account.name ?? account.nickname ?? "").lowercased()
                .trimmingCharacters(in: .whitespaces)

            if let match = musicServices.first(where: {
                $0.name.lowercased().trimmingCharacters(in: .whitespaces) == cloudName
            }) {
                cloudToLocalSid[cloudId] = match.id
                print("[Search] Mapped Cloud \(cloudId) (\(account.displayName)) → local sid \(match.id)")
            }

            // Store the account username for DIDL metadata
            if let username = account.username, !username.isEmpty {
                cloudServiceUsername[cloudId] = username
                print("[Search] Username for \(cloudId): \(username)")
            }
        }
    }

    func localSid(forCloudServiceId cloudId: String) -> Int? {
        cloudToLocalSid[cloudId]
    }

    // MARK: - Browse

    func loadBrowseContent() async {
        guard let ip = speakerIP else { return }
        isLoadingBrowse = true
        errorMessage = nil
        cloudFavorites = nil

        async let favs = tryBrowse { try await SonosAPI.browseFavorites(ip: ip) }
        async let lists = tryBrowse { try await SonosAPI.browsePlaylists(ip: ip) }
        async let stations = tryBrowse { try await SonosAPI.browseRadio(ip: ip) }

        favorites = await favs
        playlists = await lists
        radio = await stations

        if musicServices.isEmpty {
            musicServices = (try? await SonosAPI.listMusicServices(ip: ip)) ?? []
            buildServiceIdMapping()
        }

        isLoadingBrowse = false
    }

    private func tryBrowse(_ block: () async throws -> [BrowseItem]) async -> [BrowseItem] {
        (try? await block()) ?? []
    }

    // MARK: - Search via Cloud API

    func search(query: String) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            if !hasProbed { await probeLinkedServices() }
            guard !Task.isCancelled else { return }

            // Ensure local music services are loaded for sid mapping
            if musicServices.isEmpty, let ip = speakerIP {
                musicServices = (try? await SonosAPI.listMusicServices(ip: ip)) ?? []
                buildServiceIdMapping()
            }

            let serviceIds = activeServiceIds
            guard !serviceIds.isEmpty else {
                print("[Search] No active services to search")
                searchResults = []
                isSearching = false
                return
            }

            guard let token = await SonosAuth.shared.validAccessToken(),
                  let householdId = SonosAuth.shared.householdId else {
                print("[Search] No Cloud auth for search")
                searchResults = []
                isSearching = false
                return
            }

            print("[Search] Searching \(serviceIds.count) services for: \(query)")

            do {
                let response = try await SonosCloudAPI.searchCatalog(
                    token: token, householdId: householdId,
                    term: query, serviceIds: serviceIds)

                guard !Task.isCancelled else { return }

                var results: [ServiceSearchResult] = []
                for serviceResult in response.services ?? [] {
                    guard let resources = serviceResult.resources, !resources.isEmpty else { continue }

                    // Determine service name from first resource or from account list
                    let serviceName = resources.first?.id?.serviceName
                        ?? accountName(for: serviceResult.serviceId)
                        ?? "Unknown"

                    let items = resources.compactMap { resource -> BrowseItem? in
                        convertToBrowseItem(resource, serviceId: serviceResult.serviceId,
                                            accountId: serviceResult.accountId)
                    }

                    if !items.isEmpty {
                        let sid = serviceResult.serviceId ?? UUID().uuidString
                        results.append(ServiceSearchResult(
                            id: sid, serviceName: serviceName, items: items))
                        print("[Search] \(serviceName) → \(items.count) results")
                    }

                    // Log errors
                    for err in serviceResult.errors ?? [] {
                        print("[Search] \(serviceName) error: \(err.errorCode ?? "?") - \(err.reason ?? "?")")
                    }
                }

                guard !Task.isCancelled else { return }
                searchResults = results
            } catch {
                if !Task.isCancelled {
                    print("[Search] Cloud search failed: \(error)")
                    searchResults = []
                }
            }

            isSearching = false
        }
    }

    private func accountName(for serviceId: String?) -> String? {
        guard let sid = serviceId else { return nil }
        return linkedAccounts.first { $0.serviceId == sid }?.displayName
    }

    /// Convert a Cloud API resource into a BrowseItem for playback.
    private func convertToBrowseItem(_ resource: SonosCloudAPI.CloudResource,
                                     serviceId: String?,
                                     accountId: String?) -> BrowseItem? {
        guard let name = resource.name else { return nil }
        let type = resource.type ?? ""

        let supportedTypes: Set<String> = ["TRACK", "ARTIST", "ALBUM", "PLAYLIST", "PROGRAM"]
        guard supportedTypes.contains(type) else { return nil }

        let objectId = resource.id?.objectId ?? UUID().uuidString
        let artistName = resource.artists?.first?.name ?? resource.summary?.content ?? ""
        let albumName = resource.container?.name ?? ""
        let artURL = resource.images?.first?.url ?? resource.container?.images?.first?.url
        let isContainer = type == "ALBUM" || type == "PLAYLIST"

        let uri = buildPlayableURI(objectId: objectId, serviceId: serviceId, accountId: accountId, type: type)
        let localSid = serviceId.flatMap { cloudToLocalSid[$0] }

        return BrowseItem(
            id: objectId, title: name, artist: artistName, album: albumName,
            albumArtURL: artURL, uri: uri, metaXML: nil,
            isContainer: isContainer, serviceId: localSid, cloudType: type)
    }

    /// Build a URI that Sonos can play from the Cloud API objectId.
    /// Uses the local Sonos sid (mapped from Cloud serviceId) for the `sid=` parameter.
    /// URI format is service-specific (Apple Music, Spotify, etc. all need different encoding).
    private func buildPlayableURI(objectId: String, serviceId: String?,
                                  accountId: String?, type: String) -> String? {
        guard let cloudSid = serviceId, let aid = accountId else { return nil }

        let localSid = cloudToLocalSid[cloudSid]
        guard let sid = localSid else {
            print("[Search] No local sid mapping for Cloud serviceId \(cloudSid)")
            return nil
        }

        // URL-encode colons in the objectId (song:123 → song%3a123)
        let encodedId = objectId.replacingOccurrences(of: ":", with: "%3a")

        switch type {
        case "TRACK":
            let (scheme, suffix, flags) = trackURIComponents(localSid: sid, objectId: objectId)
            return "\(scheme):\(encodedId)\(suffix)?sid=\(sid)&flags=\(flags)&sn=\(aid)"
        case "ALBUM", "PLAYLIST":
            return "x-rincon-cpcontainer:\(encodedId)?sid=\(sid)&flags=8300&sn=\(aid)"
        case "PROGRAM":
            return "x-sonosapi-radio:\(encodedId)?sid=\(sid)&flags=8300&sn=\(aid)"
        default:
            return nil
        }
    }

    /// Returns (uriScheme, fileSuffix, flags) for track URIs based on the local service ID.
    private func trackURIComponents(localSid: Int, objectId: String) -> (String, String, Int) {
        switch localSid {
        case 204:  // Apple Music
            return ("x-sonos-http", ".unknown", 0)
        case 12:   // Spotify
            return ("x-sonos-spotify", "", 8224)
        case 165:  // 网易云音乐
            return ("x-sonos-http", ".unknown", 0)
        default:
            return ("x-sonos-http", "", 8224)
        }
    }

    // MARK: - Playback Actions

    private func playbackMetadata(for item: BrowseItem) -> String {
        if let resMD = item.resMD, !resMD.isEmpty {
            return resMD
        }

        // For Cloud search results, build metadata with correct service account
        if item.cloudType != nil, let sid = item.serviceId {
            let accountId = accountIdForLocalSid(sid) ?? "0"
            return buildCloudDIDLMetadata(item: item, localSid: sid, accountId: accountId)
        }
        return SonosAPI.buildDIDLMetadata(item: item)
    }

    /// Find the Cloud account-id (sn) for a given local service ID.
    private func accountIdForLocalSid(_ localSid: Int) -> String? {
        for (cloudId, sid) in cloudToLocalSid {
            if sid == localSid {
                return linkedAccounts.first { $0.serviceId == cloudId }?.accountId
            }
        }
        return nil
    }

    /// Build DIDL metadata for Cloud search results with the correct service account.
    /// Matches Sonos's own metadata format: item id="-1", includes <res>, correct desc serial.
    private func buildCloudDIDLMetadata(item: BrowseItem, localSid: Int, accountId: String) -> String {
        let title = SonosAPI.escapeXML(item.title)
        let artist = SonosAPI.escapeXML(item.artist)
        let album = SonosAPI.escapeXML(item.album)
        let art = SonosAPI.escapeXML(item.albumArtURL ?? "")

        let encodedObjId = item.id.replacingOccurrences(of: ":", with: "%3a")
        let (scheme, suffix, flags) = trackURIComponents(localSid: localSid, objectId: item.id)
        let resURI = SonosAPI.escapeXML(
            "\(scheme):\(encodedObjId)\(suffix)?sid=\(localSid)&flags=\(flags)&sn=\(accountId)")

        // desc format: SA_RINCON{localSid}_X_#Svc{localSid}-{accountId}-Token
        let desc = "SA_RINCON\(localSid)_X_#Svc\(localSid)-\(accountId)-Token"

        print("[Playback] desc=\(desc)")

        return """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
        xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" \
        xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
        <item id="-1" parentID="-1" restricted="true">\
        <res protocolInfo="sonos.com-http:*:application/octet-stream:*">\(resURI)</res>\
        <r:streamContent></r:streamContent>\
        <dc:title>\(title)</dc:title>\
        <upnp:class>object.item.audioItem.musicTrack</upnp:class>\
        <dc:creator>\(artist)</dc:creator>\
        <upnp:album>\(album)</upnp:album>\
        <upnp:albumArtURI>\(art)</upnp:albumArtURI>\
        <desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\
        \(desc)</desc>\
        </item></DIDL-Lite>
        """
    }

    private func extractItemId(from resMD: String) -> String? {
        let pattern = #"<item\s+id="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: resMD, range: NSRange(resMD.startIndex..., in: resMD)),
              let range = Range(match.range(at: 1), in: resMD) else { return nil }
        return String(resMD[range])
    }

    private func extractServiceParams() -> (sid: String, flags: String, sn: String)? {
        let allItems = favorites + radio
        for item in allItems {
            guard let uri = item.uri, uri.contains("sid="), uri.contains("sn=") else { continue }
            var sid: String?
            var sn: String?
            for part in uri.split(separator: "?").last?.split(separator: "&") ?? [] {
                let kv = part.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                if kv[0] == "sid" { sid = String(kv[1]) }
                if kv[0] == "sn" { sn = String(kv[1]) }
            }
            if let sid, let sn {
                return (sid: sid, flags: "8300", sn: sn)
            }
        }
        return nil
    }

    private func constructFavoriteURI(resMD: String) -> String? {
        guard let itemId = extractItemId(from: resMD) else { return nil }

        var flags = 8300
        if itemId.count >= 8 {
            let flagsHex = String(itemId[itemId.index(itemId.startIndex, offsetBy: 4)..<itemId.index(itemId.startIndex, offsetBy: 8)])
            flags = Int(flagsHex, radix: 16) ?? 8300
        }

        guard let params = extractServiceParams() else {
            print("[Playback] Could not find service params from existing favorites")
            return "x-rincon-cpcontainer:\(itemId)"
        }

        let uri = "x-rincon-cpcontainer:\(itemId)?sid=\(params.sid)&flags=\(flags)&sn=\(params.sn)"
        print("[Playback] Constructed full URI: \(uri)")
        return uri
    }

    func playNow(item: BrowseItem, manager: SonosManager) async {
        if item.isArtist {
            await startStation(item: item, manager: manager)
            return
        }

        print("[Playback] ====== playNow START ======")
        print("[Playback] title=\(item.title) isContainer=\(item.isContainer) id=\(item.id)")

        // For Sonos Favorites, try Cloud API first (better metadata/art in recently played)
        if item.id.hasPrefix("FV:"), await tryCloudFavorite(item: item, manager: manager) {
            print("[Playback] ====== playNow END (Cloud) ======")
            return
        }

        guard let ip = manager.selectedSpeaker?.playbackIP else {
            print("[Playback] ABORT: no speaker IP")
            return
        }

        var playURI = item.uri
        let playMeta = playbackMetadata(for: item)

        if (playURI == nil || playURI?.isEmpty == true), let resMD = item.resMD {
            playURI = constructFavoriteURI(resMD: resMD)
        }

        guard let uri = playURI, !uri.isEmpty else {
            print("[Playback] ABORT: no URI. metaXML=\(item.metaXML ?? "nil")")
            return
        }

        print("[Playback] uri=\(uri)")
        print("[Playback] metadata=\(playMeta.prefix(300))")

        // Diagnostic: capture full metadata of the currently playing track for comparison
        if let rawXml = try? await SonosAPI.getRawPositionInfo(ip: ip) {
            if let metaRaw = SonosAPI.extractTag("TrackMetaData", from: rawXml) {
                let meta = SonosAPI.decodeXMLEntities(metaRaw)
                print("[Playback] DIAGNOSTIC currentMeta=\(meta.prefix(800))")
            }
            if let uri = SonosAPI.extractTag("TrackURI", from: rawXml) {
                print("[Playback] DIAGNOSTIC currentURI=\(SonosAPI.decodeXMLEntities(uri))")
            }
        }

        do {
            if item.isContainer || uri.contains("x-rincon-cpcontainer:") {
                guard let uuid = manager.selectedSpeaker?.id else {
                    print("[Playback] ABORT: no speaker UUID")
                    return
                }
                print("[Playback] → Queue approach (container)")
                try? await SonosAPI.removeAllTracksFromQueue(ip: ip)
                let trackNr = try await SonosAPI.addURIToQueue(ip: ip, uri: uri, metadata: playMeta)
                try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: uuid)
                try await SonosAPI.seekToTrack(ip: ip, trackNumber: trackNr)
                try await SonosAPI.play(ip: ip)
                print("[Playback] Queue playback started at track \(trackNr)")
            } else {
                print("[Playback] → SetAVTransportURI (direct)")
                try await SonosAPI.setAVTransportURI(ip: ip, uri: uri, metadata: playMeta)
                try await SonosAPI.play(ip: ip)
            }

            try? await Task.sleep(for: .milliseconds(1500))
            await manager.refreshState()

            // If Sonos couldn't resolve metadata (shows "Unknown"), patch from our search data
            if manager.trackInfo?.title == "Unknown" || manager.trackInfo?.title == nil {
                print("[Playback] Sonos returned Unknown → patching from search result")
                manager.patchTrackInfo(
                    title: item.title,
                    artist: item.artist,
                    album: item.album,
                    albumArtURL: item.albumArtURL
                )
            }
        } catch {
            print("[Playback] FAILED: \(error)")
            errorMessage = error.localizedDescription
        }
        print("[Playback] ====== playNow END ======")
    }

    /// Try to play a favorite via the Sonos Cloud API. Returns true if successful.
    private func tryCloudFavorite(item: BrowseItem, manager: SonosManager) async -> Bool {
        guard let groupId = manager.currentCloudGroupId,
              let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else { return false }

        do {
            // Cache the favorites list to avoid repeated calls
            if cloudFavorites == nil {
                cloudFavorites = try await SonosCloudAPI.getFavorites(
                    token: token, householdId: householdId)
            }

            guard let match = cloudFavorites?.first(where: {
                ($0.name ?? "").localizedCaseInsensitiveCompare(item.title) == .orderedSame
            }) else {
                print("[Playback] No Cloud favorite match for \"\(item.title)\"")
                return false
            }

            print("[Playback] → Cloud loadFavorite (id=\(match.id), name=\"\(match.name ?? "")\")")
            try await SonosCloudAPI.loadFavorite(
                token: token, groupId: groupId, favoriteId: match.id)

            try? await Task.sleep(for: .milliseconds(1000))
            await manager.refreshState()
            return true
        } catch {
            print("[Playback] Cloud favorite failed: \(error)")
            return false
        }
    }

    func playNext(item: BrowseItem, manager: SonosManager) async {
        guard let uri = item.uri else { return }
        await manager.playNext(uri: uri, metadata: playbackMetadata(for: item))
    }

    /// Start a personalized radio station from an artist.
    /// Searches Cloud API for the artist's Apple Music ID, then constructs radio:ra.{id}
    /// — the same format the official Sonos app uses for "Start Station".
    func startStation(item: BrowseItem, manager: SonosManager) async {
        print("[Station] ====== startStation START ======")
        print("[Station] title=\"\(item.title)\" id=\(item.id)")

        guard let ip = manager.selectedSpeaker?.playbackIP else {
            print("[Station] ABORT: no speaker IP")
            return
        }

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            print("[Station] ABORT: no Cloud auth")
            errorMessage = "Not logged in to Sonos Cloud"
            return
        }

        if !hasProbed { await probeLinkedServices() }
        let serviceIds = activeServiceIds
        guard !serviceIds.isEmpty else {
            print("[Station] ABORT: no active services")
            errorMessage = "No music services linked"
            return
        }

        do {
            let response = try await SonosCloudAPI.searchCatalog(
                token: token, householdId: householdId,
                term: item.title, serviceIds: serviceIds)

            // Find the ARTIST result to get the Apple Music artist ID
            var artistId: String?
            var cloudServiceId: String?
            var cloudAccountId: String?
            var artistArtURL: String?

            for svc in response.services ?? [] {
                for resource in svc.resources ?? [] {
                    let type = resource.type ?? ""
                    let objId = resource.id?.objectId ?? ""
                    let name = resource.name ?? ""

                    if type == "ARTIST" && name.localizedCaseInsensitiveCompare(item.title) == .orderedSame {
                        // Extract the numeric ID: "artist:137938148" → "137938148"
                        artistId = objId.replacingOccurrences(of: "artist:", with: "")
                        cloudServiceId = svc.serviceId
                        cloudAccountId = svc.accountId
                        artistArtURL = resource.images?.first?.url ?? item.albumArtURL
                        print("[Station] Matched artist: \(name), id=\(objId)")
                        break
                    }
                }
                if artistId != nil { break }
            }

            // Fallback: take any ARTIST result if exact name match failed
            if artistId == nil {
                for svc in response.services ?? [] {
                    for resource in svc.resources ?? [] {
                        if resource.type == "ARTIST", let objId = resource.id?.objectId,
                           objId.hasPrefix("artist:") {
                            artistId = objId.replacingOccurrences(of: "artist:", with: "")
                            cloudServiceId = svc.serviceId
                            cloudAccountId = svc.accountId
                            artistArtURL = resource.images?.first?.url ?? item.albumArtURL
                            print("[Station] Fallback artist: \(resource.name ?? "?"), id=\(objId)")
                            break
                        }
                    }
                    if artistId != nil { break }
                }
            }

            guard let amArtistId = artistId else {
                print("[Station] No artist found in search results")
                errorMessage = "Could not find artist \(item.title)"
                return
            }

            // Construct radio:ra.{artist_id} — this is the "Start Station" format
            let radioId = "radio:ra.\(amArtistId)"
            let stationName = "\(item.title) Radio"
            print("[Station] Constructed radioId=\(radioId) name=\"\(stationName)\"")

            await playRadioStation(
                ip: ip, radioId: radioId, stationName: stationName,
                cloudServiceId: cloudServiceId, accountId: cloudAccountId,
                artURL: artistArtURL, resMD: item.resMD, manager: manager)

        } catch {
            print("[Station] Failed: \(error)")
            errorMessage = error.localizedDescription
        }
        print("[Station] ====== startStation END ======")
    }

    /// Play a selected radio station option (from station picker).
    func playStationOption(_ option: RadioStationOption, manager: SonosManager) async {
        guard let ip = manager.selectedSpeaker?.playbackIP else { return }
        await playRadioStation(
            ip: ip, radioId: option.id, stationName: option.name,
            cloudServiceId: option.cloudServiceId, accountId: option.accountId,
            artURL: option.artURL, resMD: option.resMD, manager: manager)
    }

    /// Play a resolved radio station via UPnP.
    private func playRadioStation(ip: String, radioId: String, stationName: String,
                                  cloudServiceId: String?, accountId: String?,
                                  artURL: String?, resMD: String?,
                                  manager: SonosManager) async {
        let localSid = cloudServiceId.flatMap { cloudToLocalSid[$0] }
        let params = extractServiceParams()
        let sid = localSid.map(String.init) ?? params?.sid ?? "204"
        let sn = accountId ?? params?.sn ?? "0"

        let encodedId = radioId.replacingOccurrences(of: ":", with: "%3a")
        let radioURI = "x-sonosapi-radio:\(encodedId)?sid=\(sid)&flags=8300&sn=\(sn)"
        print("[Station] radioURI=\(radioURI)")

        let descTag = extractDescTag(from: resMD ?? "") ?? "SA_RINCON52231_X_#Svc52231-408f19a7-Token"
        let artTag = artURL.map { "<upnp:albumArtURI>\(SonosAPI.escapeXML($0))</upnp:albumArtURI>" } ?? ""
        let radioMeta = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" " +
            "xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" " +
            "xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">" +
            "<item id=\"100c206c\(SonosAPI.escapeXML(encodedId))\" " +
            "parentID=\"00081024\(SonosAPI.escapeXML(encodedId))\" restricted=\"true\">" +
            "<dc:title>\(SonosAPI.escapeXML(stationName))</dc:title>" +
            "<upnp:class>object.item.audioItem.audioBroadcast</upnp:class>" +
            artTag +
            "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">" +
            "\(descTag)</desc></item></DIDL-Lite>"

        do {
            print("[Station] → SetAVTransportURI...")
            try await SonosAPI.setAVTransportURI(ip: ip, uri: radioURI, metadata: radioMeta)
            print("[Station] → Play...")
            try await SonosAPI.play(ip: ip)

            try? await Task.sleep(for: .milliseconds(2000))
            let state = try? await SonosAPI.getTransportInfo(ip: ip)
            let newInfo = try? await SonosAPI.getPositionInfo(ip: ip)
            print("[Station] after: transport=\(state?.rawValue ?? "nil") title=\"\(newInfo?.title ?? "nil")\"")

            await manager.refreshState()
        } catch {
            print("[Station] UPnP playback FAILED: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    private func extractDescTag(from xml: String) -> String? {
        guard let start = xml.range(of: "<desc"),
              let contentStart = xml.range(of: ">", range: start.upperBound..<xml.endIndex),
              let end = xml.range(of: "</desc>", range: contentStart.upperBound..<xml.endIndex) else { return nil }
        return String(xml[contentStart.upperBound..<end.lowerBound])
    }

    func addToQueue(item: BrowseItem, manager: SonosManager) async {
        guard let ip = manager.selectedSpeaker?.playbackIP,
              let uri = item.uri else { return }
        let meta = playbackMetadata(for: item)
        do {
            try await SonosAPI.addURIToQueue(ip: ip, uri: uri, metadata: meta)
            await manager.loadQueue()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
