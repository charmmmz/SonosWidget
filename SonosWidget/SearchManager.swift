import Foundation
import SwiftUI

// MARK: - Sonos UPnP magic numbers

/// `flags=8300` is the Sonos-internal "third-party streaming radio /
/// container" flag set used by the official Sonos app on radio:ra.* and
/// cpcontainer URIs. Anything else (e.g. `flags=0`) makes the speaker
/// reject the URI with SOAP fault 800/801. Verified by capturing the
/// official iOS app's traffic.
let SonosRinconRadioFlags: Int = 8300

/// Time we sleep after `setAVTransportURI` before issuing `Play`.
/// 800 ms is the empirical sweet spot — shorter and the speaker still
/// sometimes returns "transition pending" on Play.
let stationSetURISettleMs: Int = 800
/// Time we wait after Play before reading transport state to decide
/// if we need to retry. Stations resolve via the cloud and can take
/// 2-3 s before the transport leaves STOPPED.
let stationPlayConfirmMs: Int = 2500
/// Pause between retries when the first Play left us in STOPPED.
let stationRetryDelayMs: Int = 2000
/// After playNow, how long to wait before refreshing UI state so the
/// freshly-set track has propagated to the position-info endpoint.
let playbackSettleDelayMs: Int = 1500

@Observable
final class SearchManager {
    var favorites: [BrowseItem] = []
    var playlists: [BrowseItem] = []
    var radio: [BrowseItem] = []
    var searchResults: [ServiceSearchResult] = []
    var musicServices: [MusicService] = []
    var isLoadingBrowse = false
    var isSearching = false
    var hasSearched = false
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

    /// Per-service detailed results (loaded on demand when a service tab is selected).
    var serviceDetailResults: [String: ServiceSearchResult] = [:]
    var isLoadingServiceDetail = false

    /// Locally-tracked "Recently Played" list — populated whenever the user
    /// triggers playback through the app (tapping an item in search results,
    /// starting a station, etc). Capped to `recentlyPlayedLimit`, persisted
    /// across launches via UserDefaults so the Browse page shows history
    /// immediately on cold start.
    private(set) var recentlyPlayed: [BrowseItem] = []
    private static let recentlyPlayedLimit = 20

    private static let enabledKey = "SearchEnabledServices"
    private static let cachedAccountsKey = "CachedLinkedAccounts"
    /// Persisted `cloudToLocalSid` / `localToCloudSid` mapping. Built from
    /// the intersection of the Cloud API's linked-services list and the
    /// LAN `listMusicServices` catalog. Caching lets subsequent launches
    /// resolve cloud service ids from a local sid *before* the user opens
    /// Browse — the player's artist / album NavigationLinks need this
    /// mapping to render as tappable links.
    private static let sidMappingKey = "CloudLocalSidMapping"
    private static let recentlyPlayedKey = "RecentlyPlayedItems"

    private var speakerIP: String?
    private var searchTask: Task<Void, Never>?
    /// The query string that produced the most recent `searchResults` /
    /// `serviceDetailResults`. Readable from views so they can react when a
    /// new search commits (e.g. to re-fetch the selected service tab).
    private(set) var lastSearchQuery = ""
    private var hasProbed = false

    init() {
        restoreCachedAccounts()
        restoreRecentlyPlayed()
        restoreSidMapping()
    }

    func configure(speakerIP: String?) {
        self.speakerIP = speakerIP
    }

    // MARK: - Service Detection via Cloud API

    func probeLinkedServices() async {
        guard !hasProbed else { return }

        if !linkedAccounts.isEmpty {
            SonosLog.debug(.search, "Using \(linkedAccounts.count) cached linked accounts")
            await ensureMusicServicesPopulated()
            buildServiceIdMapping()
            hasProbed = true
            return
        }

        await fetchLinkedAccounts()
    }

    /// Opportunistically fetch the UPnP `listMusicServices` catalog when
    /// we have a reachable LAN IP and the catalog isn't already loaded.
    /// This is what unblocks `buildServiceIdMapping` → `localToCloudSid`
    /// on first launch (the player's artist / album links need that
    /// mapping the very first time the app is opened, before the user
    /// has ever visited the Browse tab, which is where this fetch used
    /// to be gated).
    private func ensureMusicServicesPopulated() async {
        guard musicServices.isEmpty,
              let ip = speakerIP,
              !ip.isEmpty else { return }
        if let fetched = try? await SonosAPI.listMusicServices(ip: ip), !fetched.isEmpty {
            musicServices = fetched
            SonosLog.debug(.search, "Proactively fetched \(fetched.count) music services for sid mapping")
        }
    }

    /// Network call to refresh linked accounts. Called on first launch or manual refresh.
    private func fetchLinkedAccounts() async {
        isProbing = true

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            SonosLog.info(.search, "No Sonos Cloud auth, cannot detect services")
            isProbing = false
            hasProbed = true
            return
        }

        do {
            let accounts = try await SonosCloudAPI.getMusicServiceAccounts(
                token: token, householdId: householdId)
            linkedAccounts = accounts
            persistAccounts(accounts)
            SonosLog.info(.search, "Cloud API detected \(accounts.count) linked services")
            for a in accounts {
                SonosLog.debug(.search, "  \(a.nickname ?? a.serviceId ?? "?") (service-id=\(a.serviceId ?? "?"))")
            }

            let saved = UserDefaults.standard.dictionary(forKey: Self.enabledKey) as? [String: Bool] ?? [:]
            for account in accounts {
                guard let sid = account.serviceId else { continue }
                serviceEnabled[sid] = saved[sid] ?? true
            }
        } catch {
            SonosLog.error(.search, "Cloud API detection failed: \(error)")
        }

        await ensureMusicServicesPopulated()
        buildServiceIdMapping()
        hasProbed = true
        isProbing = false
    }

    private func persistToggles() {
        UserDefaults.standard.set(serviceEnabled, forKey: Self.enabledKey)
    }

    private func persistAccounts(_ accounts: [SonosCloudAPI.CloudMusicServiceAccount]) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.cachedAccountsKey)
        }
    }

    private func restoreCachedAccounts() {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedAccountsKey),
              let accounts = try? JSONDecoder().decode([SonosCloudAPI.CloudMusicServiceAccount].self, from: data),
              !accounts.isEmpty else { return }

        linkedAccounts = accounts
        let saved = UserDefaults.standard.dictionary(forKey: Self.enabledKey) as? [String: Bool] ?? [:]
        for account in accounts {
            guard let sid = account.serviceId else { continue }
            serviceEnabled[sid] = saved[sid] ?? true
        }
        SonosLog.debug(.search, "Restored \(accounts.count) cached linked accounts")
    }

    // MARK: - Recently Played

    /// Record that the user just started playing this item. Moves the item
    /// to the front of `recentlyPlayed` (deduping), caps the list length,
    /// and persists it so the Browse page has history on next launch.
    func pushRecentlyPlayed(_ item: BrowseItem) {
        // Skip items with no id/title — placeholders / partial containers.
        guard !item.id.isEmpty, !item.title.isEmpty else { return }

        // Dedupe by id; also by title+artist as a fallback for radio stations
        // that get freshly constructed ids each playback session.
        recentlyPlayed.removeAll { existing in
            existing.id == item.id ||
            (existing.title == item.title && existing.artist == item.artist)
        }
        recentlyPlayed.insert(item, at: 0)
        if recentlyPlayed.count > Self.recentlyPlayedLimit {
            recentlyPlayed = Array(recentlyPlayed.prefix(Self.recentlyPlayedLimit))
        }
        persistRecentlyPlayed()
    }

    private func persistRecentlyPlayed() {
        if let data = try? JSONEncoder().encode(recentlyPlayed) {
            UserDefaults.standard.set(data, forKey: Self.recentlyPlayedKey)
        }
    }

    private func restoreRecentlyPlayed() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentlyPlayedKey),
              let items = try? JSONDecoder().decode([BrowseItem].self, from: data),
              !items.isEmpty else { return }
        recentlyPlayed = items
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
        cloudToLocalSid.removeAll()
        localToCloudSid.removeAll()
        cloudServiceUsername.removeAll()
    }

    /// Re-run the local-sid ↔ cloud-sid build step using the current
    /// `speakerIP`. Safe to call any number of times — no-ops when the
    /// mapping is already populated and the LAN catalog has been loaded.
    /// Used when the selected speaker's IP becomes available *after* the
    /// initial `probeLinkedServices()` run, which would otherwise leave
    /// the mapping empty until the user visits the Browse tab.
    func refreshServiceIdMappingIfNeeded() async {
        if !cloudToLocalSid.isEmpty { return }
        await ensureMusicServicesPopulated()
        buildServiceIdMapping()
    }

    func forceReprobe() async {
        hasProbed = false
        linkedAccounts = []
        UserDefaults.standard.removeObject(forKey: Self.cachedAccountsKey)
        await fetchLinkedAccounts()
    }

    // MARK: - Grouped Favorites

    struct FavoriteGroup {
        let category: BrowseItem.FavoriteCategory
        let items: [BrowseItem]
    }

    var groupedFavorites: [FavoriteGroup] {
        let order: [BrowseItem.FavoriteCategory] = [.playlist, .album, .song, .artist, .station, .collection]
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
    /// Reverse: local Sonos sid → Cloud API serviceId.
    private var localToCloudSid: [Int: String] = [:]
    /// Maps Cloud API serviceId to the account username (e.g. "X_#Svc52231-408f19a7-Token").
    private var cloudServiceUsername: [String: String] = [:]

    private func buildServiceIdMapping() {
        guard !linkedAccounts.isEmpty, !musicServices.isEmpty else { return }
        cloudToLocalSid.removeAll()
        localToCloudSid.removeAll()
        cloudServiceUsername.removeAll()

        // Also snapshot local-sid → service name into SharedStorage so
        // SonosManager (and the widget) can recognize the playing service
        // even when no active search context is around. Primary use case:
        // tagging `TrackInfo.source` for services whose local sid varies
        // per installation (NetEase, regional partners).
        var sidNameMap: [String: String] = [:]

        for account in linkedAccounts {
            guard let cloudId = account.serviceId else { continue }
            let cloudName = (account.name ?? account.nickname ?? "").lowercased()
                .trimmingCharacters(in: .whitespaces)

            if let match = musicServices.first(where: {
                $0.name.lowercased().trimmingCharacters(in: .whitespaces) == cloudName
            }) {
                cloudToLocalSid[cloudId] = match.id
                localToCloudSid[match.id] = cloudId
                sidNameMap[String(match.id)] = match.name
                SonosLog.debug(.search, "Mapped Cloud \(cloudId) (\(account.displayName)) → local sid \(match.id)")
            }

            if let username = account.username, !username.isEmpty {
                cloudServiceUsername[cloudId] = username
                SonosLog.debug(.search, "Username for \(cloudId): \(username)")
            }
        }

        if !sidNameMap.isEmpty {
            SharedStorage.serviceNamesByLocalSid = sidNameMap
        }
        persistSidMapping()
    }

    private func persistSidMapping() {
        guard !cloudToLocalSid.isEmpty else { return }
        // Shape: { "<cloudSid>": <localSid> } — identical to cloudToLocalSid,
        // just string-keyed for plist-safe UserDefaults storage.
        let encodable = Dictionary(uniqueKeysWithValues:
            cloudToLocalSid.map { ($0.key, $0.value) })
        UserDefaults.standard.set(encodable, forKey: Self.sidMappingKey)
    }

    private func restoreSidMapping() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.sidMappingKey)
                as? [String: Int], !dict.isEmpty else { return }
        cloudToLocalSid = dict
        localToCloudSid = Dictionary(uniqueKeysWithValues: dict.map { ($0.value, $0.key) })
        SonosLog.debug(.search, "Restored \(dict.count) cached sid mappings")
    }

    func localSid(forCloudServiceId cloudId: String) -> Int? {
        cloudToLocalSid[cloudId]
    }

    func cloudServiceId(forLocalSid sid: Int) -> String? {
        localToCloudSid[sid]
    }

    /// Best-effort resolution of which streaming service a favorite belongs to.
    /// `browseFavorites` does not populate `BrowseItem.serviceId`, and "shortcut"
    /// favorites (artist / library collection) often ship with an empty `<res>`
    /// and a `<desc>` that's just the plain service name — none of the full
    /// `parseCloudIds` paths (which require sid+sn+objectId) succeed on them.
    ///
    /// This resolver only needs *which service*, not a playable URI, so it
    /// tries every light signal in order:
    ///   1. `BrowseItem.serviceId` (local sid) → cloud
    ///   2. Full `parseCloudIds` path (sid+sn+objectId)
    ///   3. Lone `sid=<N>` in uri / resMD / metaXML
    ///   4. `SA_RINCON<N>_` in any DIDL text
    ///   5. Any linked account's display name appearing in resMD / metaXML
    ///      (e.g. `<r:description>Apple Music</r:description>`)
    func cloudServiceId(forFavorite item: BrowseItem) -> String? {
        if let local = item.serviceId,
           let cloud = cloudServiceId(forLocalSid: local) {
            return cloud
        }
        if let cloud = parseCloudIds(from: item)?.cloudServiceId {
            return cloud
        }
        if let sid = sniffLocalServiceId(from: item),
           let cloud = cloudServiceId(forLocalSid: sid) {
            return cloud
        }
        return sniffCloudServiceIdByAccountName(from: item)
    }

    /// Display name of the linked account for a favorite's service (e.g.
    /// "Apple Music · Charm"). Used as `displayNameHint` so YouTube Music
    /// and Amazon Music — which we recognize by name rather than service-id —
    /// pick up the right brand glyph.
    func serviceDisplayHint(forFavorite item: BrowseItem) -> String? {
        guard let cloudId = cloudServiceId(forFavorite: item) else { return nil }
        return linkedAccounts.first { $0.serviceId == cloudId }?.displayName
    }

    /// Look for a local Sonos `sid` in any DIDL-bearing field. Matches both
    /// the query-string form (`?sid=204&…`) and the SMAPI binding form
    /// (`SA_RINCON204_…`) seen in shortcut favorites' `<desc>` tag.
    private func sniffLocalServiceId(from item: BrowseItem) -> Int? {
        let sources = [item.uri, item.resMD, item.metaXML].compactMap { $0 }
        for src in sources {
            if let range = src.range(of: "[?&]sid=(\\d+)", options: .regularExpression) {
                let token = src[range]
                if let eq = token.firstIndex(of: "="),
                   let n = Int(token[token.index(after: eq)...]) {
                    return n
                }
            }
            if let range = src.range(of: "SA_RINCON(\\d+)_", options: .regularExpression) {
                let token = src[range].dropFirst("SA_RINCON".count).dropLast("_".count)
                if let n = Int(token) { return n }
            }
        }
        return nil
    }

    /// If a linked account's brand/display name (e.g. "Apple Music") appears
    /// anywhere in the favorite's metadata, treat that as the owning service.
    /// This is the final fallback for Apple Music artist / collection favorites
    /// whose DIDL often reduces to `<r:description>Apple Music</r:description>`.
    private func sniffCloudServiceIdByAccountName(from item: BrowseItem) -> String? {
        let haystack = [item.resMD, item.metaXML]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard !haystack.isEmpty else { return nil }

        for account in linkedAccounts {
            guard let cloudId = account.serviceId else { continue }
            let candidates = [account.name, account.nickname]
                .compactMap { $0?.lowercased().trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 4 } // avoid ultra-short false positives
            if candidates.contains(where: haystack.contains) {
                return cloudId
            }
        }
        return nil
    }

    /// **Prefer the typed factory methods** (`makeArtistItem`, `makeAlbumItem`,
    /// `makePlaylistItem`, `makeTrackItem`, `makeStationItem`) over calling this
    /// directly — they guarantee `uri` / `cloudType` / `isContainer` agree.
    /// This wrapper exists only for low-level callers that already have a raw
    /// `type` string (e.g. tests, dynamic dispatch, internal helpers).
    func buildPlayableURIPublic(objectId: String, serviceId: String,
                                accountId: String, type: String,
                                mimeType: String? = nil) -> String? {
        buildPlayableURI(objectId: objectId, serviceId: serviceId,
                         accountId: accountId, type: type, mimeType: mimeType)
    }

    // MARK: - Typed BrowseItem Factories
    //
    // Single source of truth: each Cloud object kind binds together its
    // `cloudType` raw string, URI scheme, metadata prefix, and `isContainer`
    // flag. Always construct navigation/playback BrowseItems through these
    // factories so the four fields can never drift apart (which previously
    // caused artist favorites to be saved with a `x-sonosapi-radio:` URI).

    /// Cloud Music API object kind. Drives URI scheme, metadata prefix, and
    /// `isContainer` for every BrowseItem we hand to playback / favorites.
    enum CloudObjectType: String {
        case artist     = "ARTIST"
        case album      = "ALBUM"
        case playlist   = "PLAYLIST"
        case track      = "TRACK"
        case program    = "PROGRAM"     // radio station
        case collection = "COLLECTION"  // library folder

        /// Whether browsing this object should expand into multiple tracks
        /// when added to the queue.
        var isContainer: Bool {
            switch self {
            case .album, .playlist, .collection: return true
            case .artist, .track, .program:      return false
            }
        }

        /// Value of `<r:type>` Sonos expects in a favorite's outer DIDL.
        /// Artists (and other pure-container "bookmark" favorites) must use
        /// `shortcut`; directly-playable items use `instantPlay`. Using the
        /// wrong value causes SOAP fault 803 — verified by dumping existing
        /// favorites added via the official Sonos app.
        var favoriteRType: String {
            switch self {
            case .artist, .collection: return "shortcut"
            case .album, .playlist, .track, .program: return "instantPlay"
            }
        }

        /// Whether the outer favorite DIDL should include a `<res>` element
        /// carrying the real URI. Artist favorites use an empty `<res></res>`
        /// (Sonos derives navigation from the inner resMD); everything else
        /// carries the real playable URI.
        var emitsFavoriteRes: Bool {
            switch self {
            case .artist, .collection: return false
            case .album, .playlist, .track, .program: return true
            }
        }
    }

    /// Build an artist BrowseItem suitable for navigation, "Add to Sonos
    /// Favorites", and `isFavorited` matching.
    func makeArtistItem(objectId: String, name: String, artURL: String? = nil,
                        cloudServiceId: String, accountId: String) -> BrowseItem {
        makeCloudItem(type: .artist, objectId: objectId, title: name,
                      artist: "", album: "", artURL: artURL,
                      mimeType: nil,
                      cloudServiceId: cloudServiceId, accountId: accountId)
    }

    func makeAlbumItem(objectId: String, title: String, artist: String,
                       artURL: String? = nil,
                       cloudServiceId: String, accountId: String) -> BrowseItem {
        makeCloudItem(type: .album, objectId: objectId, title: title,
                      artist: artist, album: title, artURL: artURL,
                      mimeType: nil,
                      cloudServiceId: cloudServiceId, accountId: accountId)
    }

    func makePlaylistItem(objectId: String, title: String, artist: String = "",
                          artURL: String? = nil,
                          cloudServiceId: String, accountId: String) -> BrowseItem {
        makeCloudItem(type: .playlist, objectId: objectId, title: title,
                      artist: artist, album: "", artURL: artURL,
                      mimeType: nil,
                      cloudServiceId: cloudServiceId, accountId: accountId)
    }

    func makeTrackItem(objectId: String, title: String, artist: String,
                       album: String = "", artURL: String? = nil,
                       mimeType: String? = nil,
                       cloudServiceId: String, accountId: String) -> BrowseItem {
        makeCloudItem(type: .track, objectId: objectId, title: title,
                      artist: artist, album: album, artURL: artURL,
                      mimeType: mimeType,
                      cloudServiceId: cloudServiceId, accountId: accountId)
    }

    /// Build a station/radio BrowseItem (e.g. an artist radio program). Use
    /// `makeArtistItem` instead if you want to navigate to the artist page.
    func makeStationItem(objectId: String, title: String, artistName: String = "",
                         artURL: String? = nil,
                         cloudServiceId: String, accountId: String) -> BrowseItem {
        makeCloudItem(type: .program, objectId: objectId, title: title,
                      artist: artistName, album: "", artURL: artURL,
                      mimeType: nil,
                      cloudServiceId: cloudServiceId, accountId: accountId)
    }

    private func makeCloudItem(type: CloudObjectType, objectId: String,
                               title: String, artist: String, album: String,
                               artURL: String?, mimeType: String?,
                               cloudServiceId: String, accountId: String) -> BrowseItem {
        let uri = buildPlayableURI(
            objectId: objectId, serviceId: cloudServiceId,
            accountId: accountId, type: type.rawValue, mimeType: mimeType)
        return BrowseItem(
            id: objectId, title: title, artist: artist, album: album,
            albumArtURL: artURL, uri: uri,
            isContainer: type.isContainer,
            serviceId: cloudToLocalSid[cloudServiceId],
            cloudType: type.rawValue)
    }

    struct FavoriteCloudIds {
        let objectId: String
        let cloudServiceId: String
        let accountId: String
    }

    /// Parse Cloud API identifiers from a Sonos Favorite item's URI or resMD.
    /// URI format: `x-rincon-cpcontainer:1004206c album%3A123?sid=204&flags=8300&sn=2`
    /// or resMD `<item id="1004206c album%3A123" ...>`
    func parseCloudIds(from item: BrowseItem) -> FavoriteCloudIds? {
        let uriSource = item.uri
            ?? item.resMD.flatMap { SonosAPI.extractTag("res", from: $0) }

        if let uri = uriSource {
            if let result = parseCloudIdsFromURI(uri) { return result }
        }

        // Fallback: extract from desc tag and item/container id attribute in resMD/metaXML
        return parseCloudIdsFromDIDLMetadata(item)
    }

    /// Primary extraction: parse sid, sn, and objectId from a URI with query params.
    private func parseCloudIdsFromURI(_ uri: String) -> FavoriteCloudIds? {
        var localSid: String?
        var sn: String?
        if let queryPart = uri.split(separator: "?").last {
            for param in queryPart.split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                if kv[0] == "sid" { localSid = String(kv[1]) }
                if kv[0] == "sn" { sn = String(kv[1]) }
            }
        }

        guard let sid = localSid, let accountId = sn else { return nil }
        guard let cloudSid = localToCloudSid[Int(sid) ?? 0] else { return nil }

        let objectId = extractObjectIdFromURI(uri)
        guard !objectId.isEmpty else { return nil }

        return FavoriteCloudIds(objectId: objectId,
                                cloudServiceId: cloudSid,
                                accountId: accountId)
    }

    /// Extract objectId from a Sonos URI by stripping the scheme and hex prefix.
    private func extractObjectIdFromURI(_ uri: String) -> String {
        let pathPart = uri.split(separator: "?").first.map(String.init) ?? uri
        var objectId: String
        if let colonRange = pathPart.range(of: ":", options: .backwards) {
            let afterScheme = String(pathPart[colonRange.upperBound...])
            if afterScheme.count > 8,
               afterScheme.prefix(8).allSatisfy({ $0.isHexDigit }) {
                objectId = String(afterScheme.dropFirst(8))
                    .trimmingCharacters(in: .whitespaces)
            } else {
                objectId = afterScheme
            }
        } else {
            objectId = pathPart
        }

        if objectId.contains("%25") {
            objectId = objectId.removingPercentEncoding ?? objectId
        }
        return objectId
    }

    /// Parses `SA_RINCON` + account token from a DIDL fragment (or full
    /// `<DIDL-Lite>`) and returns local sid, cloud service id, and optional `sn`
    /// (`#Svc…-sn-` in the same `desc` / blob).
    private func rinconBindingAndAccountSn(in xml: String) -> (Int, String, String?)? {
        // Some favorites store a full outer DIDL — prefer `<desc>`, but always
        // be able to fall back to scanning the whole `r:resMD`.
        let region: String = {
            if let d = SonosAPI.extractTag("desc", from: xml), d.contains("SA_RINCON") { return d }
            return xml
        }()
        guard let rRange = region.range(of: "SA_RINCON(\\d+)_", options: .regularExpression) else { return nil }
        let token = String(region[rRange])
        let digits: String
        if token.hasPrefix("SA_RINCON"), token.hasSuffix("_") {
            digits = String(token.dropFirst("SA_RINCON".count).dropLast(1))
        } else { return nil }
        guard let pair = localAndCloudServiceIds(fromRinconDigits: digits) else { return nil }
        let sn = extractSnFromSvcLine(in: region) ?? extractSnFromSvcLine(in: xml)
        return (pair.0, pair.1, sn)
    }

    private func localAndCloudServiceIds(fromRinconDigits digits: String) -> (Int, String)? {
        if let n = Int(digits), let cloud = localToCloudSid[n] { return (n, cloud) }
        if let local = cloudToLocalSid[digits] {
            return (local, localToCloudSid[local] ?? digits)
        }
        if let local = canonicalLocalSid(forCloudOrServiceTypeDigits: digits) {
            if let c = localToCloudSid[local] { return (local, c) }
        }
        return nil
    }

    private func extractSnFromSvcLine(in text: String) -> String? {
        guard let m = try? NSRegularExpression(pattern: "#Svc\\d+-([^-]+)-").firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Fallback: extract Cloud IDs from DIDL desc tag (SA_RINCON{sid}_{user})
    /// and item/container id attribute (prefix + objectId) when <res> is missing.
    private func parseCloudIdsFromDIDLMetadata(_ item: BrowseItem) -> FavoriteCloudIds? {
        let xmlSources = [item.resMD, item.metaXML].compactMap { $0 }
        guard !xmlSources.isEmpty else { return nil }

        // The number after `SA_RINCON` is often a **cloud** or SMAPI service id
        // (e.g. 52231 for Apple Music), not the local `sid` used in `?sid=204`.
        // Old code used `localToCloudSid[52231]` and always failed.
        var localSid: Int?
        var cloudServiceId: String?
        var extractedSn: String?
        for xml in xmlSources {
            if let (local, cloud, sn) = rinconBindingAndAccountSn(in: xml) {
                localSid = local
                cloudServiceId = cloud
                extractedSn = sn
                break
            }
        }

        guard localSid != nil, let cloudSid = cloudServiceId else {
            SonosLog.debug(.parseCloudIds, "Fallback: no RINCON / service binding from desc")
            return nil
        }

        // Extract objectId from item/container id attribute in resMD
        // Format: <item id="{8-hex-prefix}{objectId}" ...>
        var objectId: String?
        for xml in xmlSources {
            if let idVal = extractDIDLItemId(from: xml) {
                if idVal.count > 8, idVal.prefix(8).allSatisfy({ $0.isHexDigit }) {
                    var oid = String(idVal.dropFirst(8))
                    if oid.contains("%25") { oid = oid.removingPercentEncoding ?? oid }
                    if !oid.isEmpty { objectId = oid; break }
                }
            }
        }

        guard let oid = objectId else {
            SonosLog.debug(.parseCloudIds, "Fallback: no objectId from item id attribute")
            return nil
        }

        let accountId = extractedSn ?? "2"
        // Intentionally no log on success: `parseCloudIds` runs on every SwiftUI
        // body refresh for favorites rows — logging here floods the console.
        return FavoriteCloudIds(objectId: oid, cloudServiceId: cloudSid, accountId: accountId)
    }

    /// Extract the `id` attribute value from the first <item> or <container> in DIDL XML.
    private func extractDIDLItemId(from xml: String) -> String? {
        let pattern = "<(?:item|container)\\s+id=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range])
    }

    // MARK: - Browse

    /// Populate the Browse tab's Favorites / Playlists / Radio sections.
    ///
    /// When the caller hints we're in remote mode (`cloudMode == true`), the
    /// LAN UPnP `ContentDirectory/Browse` calls would just time out — instead
    /// we pull favorites from the Sonos Cloud Control API. Playlists and
    /// radio don't have first-class Cloud endpoints in the app yet, so those
    /// sections stay empty in remote mode (the UI hides them).
    func loadBrowseContent(cloudMode: Bool = false,
                           cloudContext: CloudContext? = nil) async {
        isLoadingBrowse = true
        errorMessage = nil

        if cloudMode, let ctx = cloudContext {
            // Log the failure path explicitly — silently swallowing the
            // error is why off-LAN users see a blank Browse tab with
            // zero diagnostic breadcrumbs.
            do {
                favorites = try await cloudFavoritesAsBrowseItems(context: ctx)
                SonosLog.info(.favorites, "Cloud favorites: \(favorites.count) loaded")
            } catch {
                SonosLog.error(.favorites, "Cloud favorites load failed: \(error)")
                favorites = []
            }
            playlists = []
            radio = []
        } else if let ip = speakerIP, !ip.isEmpty {
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
        }

        isLoadingBrowse = false
    }

    /// What SearchManager needs from SonosManager when in cloud / remote mode.
    /// Kept decoupled from `SonosControl.Backend` so SearchManager doesn't
    /// grow a hard dep on the router internals.
    struct CloudContext {
        let token: String
        let householdId: String
        let groupId: String
    }

    /// Fetch favorites from the Sonos Cloud Control API and convert them to
    /// the same `BrowseItem` shape the rest of the Browse UI expects. We tag
    /// each with `cloudFavoriteId` so the tap handler knows to dispatch via
    /// `SonosCloudAPI.loadFavorite` rather than UPnP.
    private func cloudFavoritesAsBrowseItems(context: CloudContext) async throws -> [BrowseItem] {
        let cloudFavs = try await SonosCloudAPI.listFavorites(
            token: context.token, householdId: context.householdId)
        return cloudFavs.map { fav in
            // Best-effort type inference from the resource metadata; the
            // per-category rendering falls back to sensible defaults when
            // the Cloud API's shape doesn't map cleanly.
            let cloudType: String? = {
                switch fav.resource?.type {
                case "album":    return "ALBUM"
                case "playlist": return "PLAYLIST"
                case "track":    return "TRACK"
                case "artist":   return "ARTIST"
                case "station":  return "PROGRAM"
                default:         return nil
                }
            }()
            let cloudServiceId = fav.service?.id?.serviceId
            let localSid = cloudServiceId.flatMap { cloudToLocalSid[$0] }
            var item = BrowseItem(
                id: fav.id, title: fav.name, artist: fav.description ?? "",
                album: "", albumArtURL: fav.imageUrl,
                uri: nil, metaXML: nil, resMD: nil,
                isContainer: cloudType == "ALBUM" || cloudType == "PLAYLIST",
                serviceId: localSid, cloudType: cloudType)
            item.cloudFavoriteId = fav.id
            return item
        }
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
            hasSearched = false
            return
        }

        hasSearched = true
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            if !hasProbed { await probeLinkedServices() }
            guard !Task.isCancelled else { return }

            // `musicServices` is the UPnP-sourced service catalog. It's
            // only needed for local-sid ↔ cloud-sid mapping (NowPlaying
            // badges, etc.) — the Cloud search endpoint itself works
            // purely off `activeServiceIds`. Skip the fetch entirely:
            // when we're off-LAN the saved IP blocks the whole search
            // for the UPnP timeout (~10s), and on LAN the Browse tab
            // already populated this table via `loadBrowseContent`.

            let serviceIds = activeServiceIds
            guard !serviceIds.isEmpty else {
                SonosLog.info(.search, "No active services to search")
                searchResults = []
                isSearching = false
                return
            }

            guard let token = await SonosAuth.shared.validAccessToken(),
                  let householdId = SonosAuth.shared.householdId else {
                SonosLog.info(.search, "No Cloud auth for search")
                searchResults = []
                isSearching = false
                return
            }

            lastSearchQuery = query
            serviceDetailResults = [:]

            do {
                let response = try await SonosCloudAPI.searchCatalog(
                    token: token, householdId: householdId,
                    term: query, serviceIds: serviceIds)

                guard !Task.isCancelled else { return }

                var results: [ServiceSearchResult] = []
                for serviceResult in response.services ?? [] {
                    guard let resources = serviceResult.resources, !resources.isEmpty else { continue }

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
                    }
                }

                let total = results.reduce(0) { $0 + $1.items.count }
                SonosLog.debug(.search, "search '\(query)' across \(serviceIds.count) services → \(total) results in \(results.count) groups")

                guard !Task.isCancelled else { return }
                searchResults = results
            } catch {
                if !Task.isCancelled {
                    SonosLog.error(.search, "Cloud search failed: \(error)")
                    searchResults = []
                }
            }

            isSearching = false
        }
    }

    /// Load full results for a specific service (albums, playlists, etc.).
    /// Called when user taps a service tab for the first time.
    func loadServiceDetail(serviceId: String) async {
        guard serviceDetailResults[serviceId] == nil,
              !isLoadingServiceDetail,
              !lastSearchQuery.isEmpty else { return }

        guard let account = linkedAccounts.first(where: { $0.serviceId == serviceId }),
              let aid = account.accountId,
              let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else { return }

        isLoadingServiceDetail = true
        defer { isLoadingServiceDetail = false }

        do {
            let response = try await SonosCloudAPI.searchService(
                token: token, householdId: householdId,
                serviceId: serviceId, accountId: aid, term: lastSearchQuery)

            let allResources = response.allResources
            let serviceName = allResources.first?.id?.serviceName ?? account.displayName
            let items = allResources.compactMap { resource -> BrowseItem? in
                convertToBrowseItem(resource, serviceId: serviceId, accountId: aid)
            }
            SonosLog.debug(.search, "detail \(serviceName) → \(items.count) results")

            serviceDetailResults[serviceId] = ServiceSearchResult(
                id: serviceId, serviceName: serviceName, items: items)
        } catch {
            SonosLog.error(.search, "Detail search failed for \(serviceId): \(error)")
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

        let mimeType = resource.defaults.flatMap { decodeMimeType(from: $0) }
        let uri = buildPlayableURI(objectId: objectId, serviceId: serviceId,
                                   accountId: accountId, type: type, mimeType: mimeType)
        let localSid = serviceId.flatMap { cloudToLocalSid[$0] }

        return BrowseItem(
            id: objectId, title: name, artist: artistName, album: albumName,
            albumArtURL: artURL, uri: uri, metaXML: nil,
            isContainer: isContainer, serviceId: localSid, cloudType: type)
    }

    private func decodeMimeType(from defaults: String) -> String? {
        guard let data = Data(base64Encoded: defaults),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["mimeType"] as? String
    }

    /// Build a URI that Sonos can play from the Cloud API objectId.
    /// Uses the local Sonos sid (mapped from Cloud serviceId) for the `sid=` parameter.
    /// URI format is service-specific (Apple Music, Spotify, etc. all need different encoding).
    private func buildPlayableURI(objectId: String, serviceId: String?,
                                  accountId: String?, type: String,
                                  mimeType: String? = nil) -> String? {
        guard let cloudSid = serviceId, let aid = accountId else { return nil }

        let localSid = cloudToLocalSid[cloudSid]
        guard let sid = localSid else {
            SonosLog.debug(.search, "No local sid mapping for Cloud serviceId \(cloudSid)")
            return nil
        }

        let encodedId = objectId.replacingOccurrences(of: ":", with: "%3a")

        switch type {
        case "TRACK":
            let (scheme, ext, flags) = trackURIComponents(localSid: sid, mimeType: mimeType)
            return "\(scheme):\(encodedId)\(ext)?sid=\(sid)&flags=\(flags)&sn=\(aid)"
        case "ALBUM":
            return "x-rincon-cpcontainer:1004206c\(encodedId)?sid=\(sid)&flags=8300&sn=\(aid)"
        case "PLAYLIST":
            return "x-rincon-cpcontainer:1006206c\(encodedId)?sid=\(sid)&flags=8300&sn=\(aid)"
        case "PROGRAM":
            return "x-sonosapi-radio:\(encodedId)?sid=\(sid)&flags=8300&sn=\(aid)"
        case "ARTIST":
            // Artist favorites use a cp-container URI with the bare object id
            // (no `10052064` prefix on the URI side — only the metadata id has it).
            return "x-rincon-cpcontainer:\(encodedId)?sid=\(sid)&flags=8300&sn=\(aid)"
        default:
            return nil
        }
    }

    /// Returns (scheme, fileExtension, flags) for track URIs.
    /// Matches official Sonos app: uses mimeType from the Cloud `defaults` field
    /// to pick extension (.mp4 for AAC) and flags; falls back to .unknown + flags=0.
    private func trackURIComponents(localSid: Int, mimeType: String?) -> (String, String, Int) {
        switch localSid {
        case 12: // Spotify
            return ("x-sonos-spotify", "", 8224)
        default:
            let (ext, flags) = extensionAndFlags(for: mimeType)
            return ("x-sonos-http", ext, flags)
        }
    }

    private func extensionAndFlags(for mimeType: String?) -> (String, Int) {
        switch mimeType {
        case "audio/aac", "audio/mp4", "audio/x-m4a": return (".mp4", 8232)
        case "audio/mpeg", "audio/mp3": return (".mp3", 8224)
        case "audio/flac": return (".flac", 8224)
        default: return (".unknown", 0)
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

        // UPnP-browsed items (Sonos system playlist children `SQ:<n>`, local
        // library, queue, etc.) ship their track-level DIDL fragment in
        // `metaXML` — title / artist / album / service `<desc>` already set
        // by Sonos. Without a `<DIDL-Lite>` envelope Sonos rejects it and
        // synthesises a bare stub from the URI, which is why individual
        // tracks from a Sonos Playlist showed up as "Unknown" on the player.
        if let metaXML = item.metaXML, !metaXML.isEmpty,
           metaXML.contains("<item") || metaXML.contains("<container") {
            return wrapInDIDLLiteIfNeeded(metaXML)
        }

        return SonosAPI.buildDIDLMetadata(item: item)
    }

    /// Add the DIDL-Lite envelope around a raw `<item>` / `<container>`
    /// fragment so Sonos will accept it as enqueue metadata.
    private func wrapInDIDLLiteIfNeeded(_ xml: String) -> String {
        if xml.contains("<DIDL-Lite") { return xml }
        return "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" " +
            "xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" " +
            "xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">" +
            xml +
            "</DIDL-Lite>"
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

    /// Build DIDL metadata for Cloud items, matching the exact field sets the
    /// official Sonos app produces for each `cloudType`. Sonos validates the
    /// inner DIDL strictly when used as `<r:resMD>` for favorites — including
    /// fields that don't belong (e.g. `<upnp:albumArtURI>` inside an ARTIST
    /// item, or empty `<dc:creator>` tags) causes SOAP fault 803.
    ///
    /// Per-type field whitelist (verified by dumping existing favorites):
    ///   - ARTIST   → title, class, desc                          (minimal)
    ///   - PROGRAM  → title, class, desc                          (radio station)
    ///   - ALBUM    → title, class, albumArtURI, creator, albumArtist, desc
    ///   - PLAYLIST → title, class, albumArtURI, creator, desc
    ///   - TRACK    → title, class, albumArtURI, creator, album, albumArtist, desc
    private func buildCloudDIDLMetadata(item: BrowseItem, localSid: Int, accountId: String) -> String {
        let cloudSid = localToCloudSid[localSid] ?? String(localSid)
        let username = cloudServiceUsername[cloudSid] ?? "X_#Svc\(cloudSid)-0-Token"
        let desc = "SA_RINCON\(cloudSid)_\(username)"

        let encodedObjId = item.id.replacingOccurrences(of: ":", with: "%3a")
        let cloudType = item.cloudType ?? "TRACK"

        let (itemId, upnpClass, xmlTag) = metadataComponents(
            cloudType: cloudType, objectId: encodedObjId, uri: item.uri)

        var inner = "<dc:title>\(SonosAPI.escapeXML(item.title))</dc:title>" +
            "<upnp:class>\(upnpClass)</upnp:class>"

        // Only TRACK/ALBUM/PLAYLIST carry rich metadata in their inner DIDL.
        // ARTIST and PROGRAM use a bare-minimum item (title + class + desc).
        let wantsRichMetadata = (cloudType == "TRACK" ||
                                 cloudType == "ALBUM" ||
                                 cloudType == "PLAYLIST")
        if wantsRichMetadata {
            if let art = item.albumArtURL, !art.isEmpty {
                inner += "<upnp:albumArtURI>\(SonosAPI.escapeXML(art))</upnp:albumArtURI>"
            }
            if !item.artist.isEmpty {
                let a = SonosAPI.escapeXML(item.artist)
                inner += "<dc:creator>\(a)</dc:creator>"
                // Tracks and albums identify their album-artist; pure playlists don't.
                if cloudType != "PLAYLIST" {
                    inner += "<r:albumArtist>\(a)</r:albumArtist>"
                }
            }
            // Only TRACK items reference their containing album by name.
            if cloudType == "TRACK", !item.album.isEmpty {
                inner += "<upnp:album>\(SonosAPI.escapeXML(item.album))</upnp:album>"
            }
        }
        inner += "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">\(desc)</desc>"

        return "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" " +
            "xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" " +
            "xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">" +
            "<\(xmlTag) id=\"\(itemId)\" parentID=\"\" restricted=\"true\">" +
            inner +
            "</\(xmlTag)></DIDL-Lite>"
    }

    /// Returns (itemId, upnpClass, xmlTag) based on cloudType.
    /// Format derived from Wireshark capture of official Sonos app.
    private func metadataComponents(cloudType: String, objectId: String,
                                    uri: String?) -> (String, String, String) {
        switch cloudType {
        case "TRACK":
            let flags = extractFlagsFromURI(uri)
            let flagsHex = String(format: "%04x", flags)
            return ("1003\(flagsHex)\(objectId)",
                    "object.item.audioItem.musicTrack",
                    "item")
        case "ALBUM":
            return ("1004206c\(objectId)",
                    "object.container.album.musicAlbum.#AlbumView",
                    "item")
        case "PLAYLIST":
            return ("1006206c\(objectId)",
                    "object.container.playlistContainer",
                    "item")
        case "PROGRAM":
            return ("000c206c\(objectId)",
                    "object.item.audioItem.audioBroadcast.#programRadio",
                    "item")
        case "ARTIST":
            // Sonos Apple Music artist favorites use prefix `10052064` and
            // wrap the metadata in <item> (not <container>) — verified by
            // dumping existing artist favorites added via the official app.
            return ("10052064\(objectId)",
                    "object.container.person.musicArtist",
                    "item")
        default:
            return (objectId, "object.item.audioItem.musicTrack", "item")
        }
    }

    private func extractFlagsFromURI(_ uri: String?) -> Int {
        guard let uri = uri,
              let range = uri.range(of: "flags=") else { return 0 }
        let after = uri[range.upperBound...]
        let flagStr: Substring
        if let ampIdx = after.firstIndex(of: "&") {
            flagStr = after[..<ampIdx]
        } else {
            flagStr = after
        }
        return Int(flagStr) ?? 0
    }

    /// Inject `upnp:albumArtURI` into DIDL metadata when not already present.
    /// Sonos Favorites store the art URL in the outer browse item, but the inner
    /// `r:resMD` DIDL often omits it — which leaves "recently played" without cover art.
    private func enrichMetadataWithArt(_ metadata: String, artURL: String?) -> String {
        guard let artURL = artURL, !artURL.isEmpty else { return metadata }
        if metadata.contains("albumArtURI") { return metadata }
        let artTag = "<upnp:albumArtURI>\(SonosAPI.escapeXML(artURL))</upnp:albumArtURI>"
        if metadata.contains("</item>") {
            return metadata.replacingOccurrences(of: "</item>", with: "\(artTag)</item>")
        }
        if metadata.contains("</container>") {
            return metadata.replacingOccurrences(of: "</container>", with: "\(artTag)</container>")
        }
        return metadata
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

        var flags = SonosRinconRadioFlags
        if itemId.count >= 8 {
            let flagsHex = String(itemId[itemId.index(itemId.startIndex, offsetBy: 4)..<itemId.index(itemId.startIndex, offsetBy: 8)])
            flags = Int(flagsHex, radix: 16) ?? SonosRinconRadioFlags
        }

        guard let params = extractServiceParams() else {
            // Fallback: bare cpcontainer URI without sid/sn — works for
            // some local sources but not third-party services.
            return "x-rincon-cpcontainer:\(itemId)"
        }

        return "x-rincon-cpcontainer:\(itemId)?sid=\(params.sid)&flags=\(flags)&sn=\(params.sn)"
    }

    func playNow(item: BrowseItem, manager: SonosManager) async {
        // Push to recents before any await so a failed play still records
        // intent (mirrors Apple Music's "attempted plays" behaviour).
        pushRecentlyPlayed(item)

        // Remote mode: if the item is a cloud-sourced favorite, use the
        // Control API's `loadFavorite` instead of the UPnP SetAVTransportURI
        // / queue path (which doesn't work off-LAN).
        if manager.transportBackend == .cloud,
           let favId = item.cloudFavoriteId,
           let token = await SonosAuth.shared.validAccessToken(),
           let gid = manager.currentCloudGroupId {
            do {
                SonosLog.debug(.playback, "remote playNow → loadFavorite(\(favId))")
                try await SonosCloudAPI.loadFavorite(token: token, groupId: gid,
                                                    favoriteId: favId)
                try? await Task.sleep(for: .milliseconds(800))
                await manager.refreshState()
            } catch {
                SonosLog.error(.playback, "loadFavorite failed: \(error)")
                errorMessage = error.localizedDescription
            }
            return
        }

        if item.isArtist {
            await startStation(item: item, manager: manager)
            return
        }

        // Everything below this line uses UPnP — gate on .cloud mode so users
        // get a friendly "Requires LAN" error instead of a silent timeout.
        if manager.transportBackend == .cloud {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Playing this item")
                .localizedDescription
            return
        }

        guard let ip = manager.selectedSpeaker?.playbackIP else {
            SonosLog.error(.playback, "playNow: no speaker IP")
            return
        }

        var playURI = item.uri
        var playMeta = playbackMetadata(for: item)

        // For favorites, the resMD DIDL often lacks albumArtURI — inject it from
        // the browse item so Sonos records proper cover art in "recently played".
        if item.id.hasPrefix("FV:") {
            playMeta = enrichMetadataWithArt(playMeta, artURL: item.albumArtURL)
        }

        if (playURI == nil || playURI?.isEmpty == true), let resMD = item.resMD {
            playURI = constructFavoriteURI(resMD: resMD)
        }

        guard let uri = playURI, !uri.isEmpty else {
            SonosLog.error(.playback, "playNow: no URI for '\(item.title)'")
            return
        }

        do {
            guard let uuid = manager.selectedSpeaker?.id else {
                SonosLog.error(.playback, "playNow: no speaker UUID")
                return
            }

            let isRadio = uri.contains("x-sonosapi-radio:")
                || uri.contains("x-sonosapi-stream:")
                || uri.contains("x-sonosapi-hls:")

            if isRadio {
                try await SonosAPI.setAVTransportURI(ip: ip, uri: uri, metadata: playMeta)
                try await SonosAPI.play(ip: ip)
                SonosLog.info(.playback, "playNow radio '\(item.title)'")
            } else {
                // Both container and single-track paths take the same shape
                // — only the source URI differs. Fold them to keep the log
                // story simple ("playNow queue → track N").
                try? await SonosAPI.removeAllTracksFromQueue(ip: ip)
                let trackNr = try await SonosAPI.addURIToQueue(ip: ip, uri: uri, metadata: playMeta)
                try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: uuid)
                try await SonosAPI.seekToTrack(ip: ip, trackNumber: trackNr)
                try await SonosAPI.play(ip: ip)
                SonosLog.info(.playback, "playNow queue '\(item.title)' → track \(trackNr)")
            }

            try? await Task.sleep(for: .milliseconds(playbackSettleDelayMs))
            await manager.refreshState()
        } catch {
            SonosLog.error(.playback, "playNow failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }


    func playNext(item: BrowseItem, manager: SonosManager) async {
        // Queue insertion is LAN-only (Cloud Control API has no per-track
        // queue API). Show a friendly message instead of a stale timeout.
        if manager.isRemoteMode {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Adding to the queue")
                .localizedDescription
            return
        }
        guard let uri = item.uri else { return }
        await manager.playNext(uri: uri, metadata: playbackMetadata(for: item))
    }

    /// Start a personalized radio station from an artist.
    /// Searches Cloud API for the artist's Apple Music ID, then constructs radio:ra.{id}
    /// — the same format the official Sonos app uses for "Start Station".
    func startStation(item: BrowseItem, manager: SonosManager) async {
        // Push to recents before network work so Browse shows the entry
        // even if cloud search below fails. Dedupes by id — safe to repeat.
        pushRecentlyPlayed(item)

        guard let ip = manager.selectedSpeaker?.playbackIP else {
            SonosLog.error(.station, "startStation: no speaker IP")
            return
        }

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            SonosLog.error(.station, "startStation: no Cloud auth")
            errorMessage = "Not logged in to Sonos Cloud"
            return
        }

        if !hasProbed { await probeLinkedServices() }
        let serviceIds = activeServiceIds
        guard !serviceIds.isEmpty else {
            SonosLog.error(.station, "startStation: no active services")
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
                            break
                        }
                    }
                    if artistId != nil { break }
                }
            }

            guard let amArtistId = artistId else {
                SonosLog.error(.station, "No artist found in search results")
                errorMessage = "Could not find artist \(item.title)"
                return
            }

            // Construct radio:ra.{artist_id} — this is the "Start Station" format
            let radioId = "radio:ra.\(amArtistId)"
            let stationName = "\(item.title) Radio"

            await playRadioStation(
                ip: ip, radioId: radioId, stationName: stationName,
                cloudServiceId: cloudServiceId, accountId: cloudAccountId,
                artURL: artistArtURL, resMD: item.resMD, manager: manager)

        } catch {
            SonosLog.error(.station, "startStation failed: \(error)")
            errorMessage = error.localizedDescription
        }
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
        let radioURI = "x-sonosapi-radio:\(encodedId)?sid=\(sid)&flags=\(SonosRinconRadioFlags)&sn=\(sn)"

        let descTag: String
        if let fromMD = extractDescTag(from: resMD ?? "") {
            descTag = fromMD
        } else if let sidInt = localSid {
            descTag = "SA_RINCON\(sidInt)_\(cloudServiceUsername[cloudServiceId ?? ""] ?? "X_#Svc\(sidInt)-\(sn)-Token")"
        } else {
            descTag = "SA_RINCON\(sid)_X_#Svc\(sid)-\(sn)-Token"
        }
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
            try await SonosAPI.setAVTransportURI(ip: ip, uri: radioURI, metadata: radioMeta)
            try? await Task.sleep(for: .milliseconds(stationSetURISettleMs))
            try await SonosAPI.play(ip: ip)

            try? await Task.sleep(for: .milliseconds(stationPlayConfirmMs))
            let state = try? await SonosAPI.getTransportInfo(ip: ip)

            if state == .stopped {
                // Some stations need a second nudge — first Play is acked
                // but Sonos sits in STOPPED until the cloud finishes resolving
                // the actual stream URL.
                SonosLog.info(.station, "still STOPPED, retrying play")
                try? await Task.sleep(for: .milliseconds(stationRetryDelayMs))
                try await SonosAPI.play(ip: ip)
                try? await Task.sleep(for: .milliseconds(stationRetryDelayMs))
            }

            SonosLog.info(.station, "playRadioStation '\(stationName)'")
            await manager.refreshState()
        } catch {
            SonosLog.error(.station, "playRadioStation failed: \(error)")
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
        if manager.isRemoteMode {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Adding to the queue")
                .localizedDescription
            return
        }
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

    /// Cloud `listFavorites` and UPnP shortcut favorites (artists, some
    /// collections) often ship **without** a top-level `<res>` URI, while
    /// `r:resMD` or DIDL `id` still has everything needed to build the
    /// `x-rincon-cpcontainer:…?sid=…&sn=…` form. `addToFavorites` and navigation
    /// into detail views need that resolved shape or the heart action fails
    /// (`guard` on `uri`) even though the entry is a valid favorite.
    func browseItemWithResolvedFavoriteURI(_ item: BrowseItem) -> BrowseItem? {
        if let u = item.uri, !u.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return item }
        guard let ids = parseCloudIds(from: item) else { return nil }
        let typeString: String? = item.cloudType ?? favoriteCategoryAsCloudType(item)
        guard let ts = typeString, let kind = CloudObjectType(rawValue: ts) else { return nil }
        let oid = ids.objectId
        let cloudSid = ids.cloudServiceId
        let aid = ids.accountId
        switch kind {
        case .artist:
            return makeArtistItem(
                objectId: oid, name: item.title, artURL: item.albumArtURL,
                cloudServiceId: cloudSid, accountId: aid)
        case .album:
            return makeAlbumItem(
                objectId: oid, title: item.title, artist: item.artist,
                artURL: item.albumArtURL,
                cloudServiceId: cloudSid, accountId: aid)
        case .playlist:
            return makePlaylistItem(
                objectId: oid, title: item.title, artist: item.artist,
                artURL: item.albumArtURL,
                cloudServiceId: cloudSid, accountId: aid)
        case .track:
            return makeTrackItem(
                objectId: oid, title: item.title, artist: item.artist,
                album: item.album, artURL: item.albumArtURL,
                mimeType: nil,
                cloudServiceId: cloudSid, accountId: aid)
        case .program:
            return makeStationItem(
                objectId: oid, title: item.title, artistName: item.artist,
                artURL: item.albumArtURL,
                cloudServiceId: cloudSid, accountId: aid)
        case .collection:
            return nil
        }
    }

    private func favoriteCategoryAsCloudType(_ item: BrowseItem) -> String? {
        switch item.favoriteCategory {
        case .artist: return "ARTIST"
        case .album: return "ALBUM"
        case .playlist: return "PLAYLIST"
        case .collection: return "COLLECTION"
        case .station: return "PROGRAM"
        case .song: return "TRACK"
        }
    }

    func addToFavorites(item: BrowseItem, manager: SonosManager) async -> Bool {
        // Sonos Cloud Control API has no endpoint to CREATE a favorite —
        // only UPnP CreateObject does that. Surface a clear message rather
        // than letting the SOAP request time out silently.
        if manager.isRemoteMode {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Adding Sonos Favorites")
                .localizedDescription
            return false
        }
        guard let ip = manager.selectedSpeaker?.playbackIP else { return false }
        guard let resolved = browseItemWithResolvedFavoriteURI(item) else { return false }
        guard let uri = resolved.uri, !uri.isEmpty else { return false }
        // Fresh inner DIDL from `resolved` avoids reusing a stale `r:resMD`
        // on an in-memory `BrowseItem` after remove → re-add.
        let meta = innerDIDLForFavoriteCreate(resolved: resolved)
        // Dispatch the correct outer-DIDL shape from `resolved` (not the
        // pre-resolution `item`) so ARTIST stays `shortcut` + empty <res>.
        let type = resolved.cloudType.flatMap { CloudObjectType(rawValue: $0) }
        let rType = type?.favoriteRType ?? "instantPlay"
        let emitRes = type?.emitsFavoriteRes ?? true
        let description: String = (type?.emitsFavoriteRes ?? true)
            ? resolved.title
            : (serviceDisplayName(for: resolved) ?? "Apple Music")

        do {
            try await SonosAPI.addToFavorites(
                ip: ip, title: resolved.title, uri: uri, metadata: meta,
                albumArtURI: resolved.albumArtURL,
                rType: rType, description: description, emitRes: emitRes)
            SonosLog.info(.favorites, "Added '\(resolved.title)' to Sonos Favorites")
            try? await Task.sleep(for: .milliseconds(500))
            await refreshFavorites(ip: ip)
            return true
        } catch {
            SonosLog.error(.favorites, "Failed to add: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Inner `r:resMD` for `ContentDirectory#CreateObject`. For cloud-typed
    /// items, always build from the resolved row so it matches a fresh add
    /// from the factory. Otherwise fall back to stored `r:resMD` / generic
    /// builders (legacy UPnP-only items).
    private func innerDIDLForFavoriteCreate(resolved: BrowseItem) -> String {
        if let ct = resolved.cloudType, !ct.isEmpty, let sid = resolved.serviceId {
            let accountId = accountIdForLocalSid(sid) ?? "0"
            return buildCloudDIDLMetadata(
                item: resolved, localSid: sid, accountId: accountId)
        }
        if let r = resolved.resMD, !r.isEmpty, resolved.cloudType == nil {
            return r
        }
        return playbackMetadata(for: resolved)
    }

    /// Display name of the music service a BrowseItem belongs to (e.g.
    /// "Apple Music", "Spotify") — used as `<r:description>` for shortcut-
    /// type favorites like artists. Returns nil if the service isn't linked.
    private func serviceDisplayName(for item: BrowseItem) -> String? {
        guard let localSid = item.serviceId else { return nil }
        return musicServices.first { $0.id == localSid }?.name
    }

    func removeFromFavorites(item: BrowseItem, manager: SonosManager) async -> Bool {
        // Cloud API has no "destroy favorite" endpoint — same UPnP-only
        // constraint as `addToFavorites`.
        if manager.isRemoteMode {
            errorMessage = SonosControlError
                .unsupportedInCloudMode(feature: "Removing Sonos Favorites")
                .localizedDescription
            return false
        }
        guard let ip = manager.selectedSpeaker?.playbackIP else { return false }
        guard let favItem = findFavorite(matching: item) else {
            SonosLog.info(.favorites, "Item '\(item.title)' not found in favorites")
            return false
        }
        do {
            try await SonosAPI.removeFromFavorites(ip: ip, objectId: favItem.id)
            SonosLog.info(.favorites, "Removed '\(item.title)' from Sonos Favorites")
            await refreshFavorites(ip: ip)
            return true
        } catch {
            SonosLog.error(.favorites, "Failed to remove: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Check if an item is already in Sonos Favorites by matching URI or
    /// title, scoped to the same streaming service. The user can favorite
    /// "Taylor Swift" from Apple Music and Spotify as two separate
    /// entries, and we must not conflate them.
    func isFavorited(_ item: BrowseItem) -> Bool {
        findFavorite(matching: item) != nil
    }

    /// Best-effort canonical service hint for a favorite or browse item,
    /// always returned in `"sid:<localSid>"` form when we can figure it out.
    ///
    /// Factory items (built via `makeArtistItem` / `makeAlbumItem` / …) carry
    /// the local sid directly. Sonos-parsed favorites lose that field and
    /// instead have one of:
    ///   * `sid=<N>` in their URI query — for instantPlay shapes (tracks,
    ///     albums, playlists). Already a local sid.
    ///   * `SA_RINCON<N>_<user>` token in `<desc>` — shortcut shape. `N`
    ///     is either a **cloud service-id** (matches `cloudToLocalSid`) or
    ///     a **SMAPI service type** (matches `musicServices[*].serviceType`).
    ///     We look up both and canonicalize to the local sid so both sides
    ///     of an equality check resolve to the same signature even when
    ///     the factory item used a cloud id and the stored favorite used
    ///     the service type.
    ///   * `id="10052064…"` hex prefix on the inner `<item>` — the middle
    ///     bytes encode the SMAPI service type (Apple Music = 52064, etc.).
    ///     Used as a last-resort fallback for shortcut favs whose `<desc>`
    ///     didn't survive the round-trip.
    ///
    /// Returns `nil` when we genuinely can't tell; callers then fall back
    /// to plain name/URI matching.
    private func serviceSignature(_ item: BrowseItem) -> String? {
        if let sid = item.serviceId { return "sid:\(sid)" }

        if let uri = item.uri, let q = uri.split(separator: "?").last {
            for param in q.split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "sid", let n = Int(kv[1]) {
                    return "sid:\(n)"
                }
            }
        }

        for blob in [item.resMD, item.metaXML].compactMap({ $0 }) {
            if let range = blob.range(of: "SA_RINCON") {
                let digits = String(blob[range.upperBound...].prefix { $0.isNumber })
                if digits.isEmpty { continue }
                if let canonical = canonicalLocalSid(forCloudOrServiceTypeDigits: digits) {
                    return "sid:\(canonical)"
                }
                // Unknown service — keep a stable fallback signature so
                // two favorites from the same unknown service still match.
                return "rincon:\(digits)"
            }
        }

        if let resMD = item.resMD, let idRange = resMD.range(of: "id=\"") {
            let digits = String(resMD[idRange.upperBound...].prefix { $0.isNumber })
            if digits.count >= 6 {
                // Prefix format appears to be `100<hex>` where the trailing
                // portion matches a SMAPI service-type. Try multiple
                // reasonable slices to recover a known service.
                let suffixes = [digits.dropFirst(2), digits.dropFirst(3), digits.dropFirst(4)]
                for sfx in suffixes {
                    if let canonical = canonicalLocalSid(forCloudOrServiceTypeDigits: String(sfx)) {
                        return "sid:\(canonical)"
                    }
                }
                return "prefix:\(digits)"
            }
        }
        return nil
    }

    /// Accepts a numeric token that might be either a Sonos *cloud service id*
    /// (key of `cloudToLocalSid`) or a SMAPI *service type* (matches
    /// `musicServices[*].serviceType`) and returns the corresponding local
    /// sid when either mapping knows about it.
    private func canonicalLocalSid(forCloudOrServiceTypeDigits digits: String) -> Int? {
        if let localSid = cloudToLocalSid[digits] { return localSid }
        if let match = musicServices.first(where: { $0.serviceType == digits }) {
            return match.id
        }
        return nil
    }

    private func findFavorite(matching item: BrowseItem) -> BrowseItem? {
        let itemSig = serviceSignature(item)
        // Service-aware predicate: if we have signatures for both sides,
        // reject mismatches outright so "Taylor Swift on Apple Music"
        // doesn't look favorited because "Taylor Swift on Spotify" is.
        // If either side lacks a signature (legacy UPnP-sourced items,
        // unknown service), don't veto — name/URI match still applies.
        let sigOK: (BrowseItem) -> Bool = { [self] fav in
            guard let a = itemSig, let b = serviceSignature(fav) else { return true }
            return a == b
        }

        if let uri = item.uri, !uri.isEmpty {
            let normalizedURI = uri.split(separator: "?").first.map(String.init) ?? uri
            if let match = favorites.first(where: { fav in
                guard sigOK(fav), let favURI = fav.uri, !favURI.isEmpty else { return false }
                let normalizedFav = favURI.split(separator: "?").first.map(String.init) ?? favURI
                return normalizedFav == normalizedURI
            }) { return match }
        }
        return favorites.first {
            sigOK($0) && $0.title == item.title && $0.artist == item.artist
        }
    }

    private func refreshFavorites(ip: String) async {
        do {
            let items = try await SonosAPI.browseFavorites(ip: ip)
            SonosLog.info(.favorites, "Refresh: \(items.count) items loaded")
            favorites = items
        } catch {
            SonosLog.error(.favorites, "Refresh failed: \(error)")
        }
    }
}
