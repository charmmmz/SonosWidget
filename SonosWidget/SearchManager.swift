import Foundation
import SwiftUI
import AuthenticationServices

@Observable
final class SearchManager: NSObject {
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

    /// Anonymous services that can be searched without credentials.
    var anonymousServices: [MusicService] = []
    /// Services that need AppLink/DeviceLink login.
    var authServices: [MusicService] = []
    /// Services that the user has successfully linked (credentials stored).
    var linkedAuthServices: Set<Int> = []
    /// User's per-service search toggle.
    var serviceEnabled: [Int: Bool] = [:]

    /// Currently linking service state.
    var linkingService: MusicService?
    var isLinking = false
    var linkError: String?

    struct ServiceSearchResult: Identifiable {
        var id: Int { service.id }
        var service: MusicService
        var items: [BrowseItem]
    }

    private static let enabledKey = "SearchEnabledServices"
    private static let credentialsPrefix = "com.charm.SonosWidget.smapi."

    private var speakerIP: String?
    private var searchTask: Task<Void, Never>?
    private var hasProbed = false
    private var deviceId: String?
    private var householdId: String?
    private var pendingLinkCode: String?
    private var pendingLinkSmapiURI: String?

    override init() {
        super.init()
    }

    func configure(speakerIP: String?) {
        self.speakerIP = speakerIP
    }

    // MARK: - Device Identity

    private func ensureDeviceIdentity() async -> Bool {
        guard let ip = speakerIP else { return false }
        if deviceId != nil && householdId != nil { return true }
        do {
            async let did = SonosAPI.getDeviceId(ip: ip)
            async let hid = SonosAPI.getHouseholdId(ip: ip)
            deviceId = try await did
            householdId = try await hid
            print("[SMAPI] deviceId=\(deviceId ?? "?"), householdId=\(householdId ?? "?")")
            return true
        } catch {
            print("[SMAPI] Failed to get device identity: \(error)")
            return false
        }
    }

    // MARK: - Credential Storage (Keychain)

    private func saveCredentials(_ creds: SMAPICredentials, serviceId: Int) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        let account = "\(Self.credentialsPrefix)\(serviceId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
        linkedAuthServices.insert(serviceId)
    }

    private func loadCredentials(serviceId: Int) -> SMAPICredentials? {
        let account = "\(Self.credentialsPrefix)\(serviceId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let creds = try? JSONDecoder().decode(SMAPICredentials.self, from: data) else {
            return nil
        }
        return creds
    }

    func deleteCredentials(serviceId: Int) {
        let account = "\(Self.credentialsPrefix)\(serviceId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        linkedAuthServices.remove(serviceId)
    }

    // MARK: - Service Discovery

    func probeLinkedServices() async {
        guard !hasProbed, let ip = speakerIP else { return }
        isProbing = true

        if musicServices.isEmpty {
            musicServices = (try? await SonosAPI.listMusicServices(ip: ip)) ?? []
        }

        let searchable = musicServices.filter { $0.canSearch }

        var anon: [MusicService] = []
        var auth: [MusicService] = []
        var linked = Set<Int>()

        for service in searchable {
            if service.isAnonymous {
                anon.append(service)
            } else if service.needsLogin {
                auth.append(service)
                if loadCredentials(serviceId: service.id) != nil {
                    linked.insert(service.id)
                }
            }
        }

        anon.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        auth.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        anonymousServices = anon
        authServices = auth
        linkedAuthServices = linked
        hasProbed = true
        isProbing = false

        // Load saved toggle state
        let saved = UserDefaults.standard.dictionary(forKey: Self.enabledKey) as? [String: Bool] ?? [:]
        for service in anon {
            serviceEnabled[service.id] = saved[String(service.id)] ?? true
        }
        for service in auth {
            let wasLinked = linked.contains(service.id)
            serviceEnabled[service.id] = saved[String(service.id)] ?? wasLinked
        }

        // Load device identity in background for later use
        _ = await ensureDeviceIdentity()

        print("[Search] Anonymous services: \(anon.count), Auth services: \(auth.count), Linked: \(linked.count)")
        if !linked.isEmpty {
            let names = auth.filter { linked.contains($0.id) }.map(\.name)
            print("[Search] Linked auth services: \(names.joined(separator: ", "))")
        }
    }

    private func persistToggles() {
        let dict = serviceEnabled.reduce(into: [String: Bool]()) { $0[String($1.key)] = $1.value }
        UserDefaults.standard.set(dict, forKey: Self.enabledKey)
    }

    func setServiceEnabled(_ service: MusicService, enabled: Bool) {
        serviceEnabled[service.id] = enabled
        persistToggles()
    }

    /// All services enabled for search: anonymous + linked auth with toggle on.
    var activeServices: [MusicService] {
        let enabledAnon = anonymousServices.filter { serviceEnabled[$0.id] ?? true }
        let enabledAuth = authServices.filter {
            linkedAuthServices.contains($0.id) && (serviceEnabled[$0.id] ?? true)
        }
        return enabledAnon + enabledAuth
    }

    var hasFinishedProbing: Bool { hasProbed }

    func resetProbe() {
        hasProbed = false
        anonymousServices = []
        authServices = []
        deviceId = nil
        householdId = nil
    }

    func forceReprobe() async {
        hasProbed = false
        anonymousServices = []
        authServices = []
        await probeLinkedServices()
    }

    // MARK: - AppLink / DeviceLink Login

    @MainActor
    func startLinking(service: MusicService, from window: UIWindow?) async {
        guard let did = deviceId, let hid = householdId else {
            guard await ensureDeviceIdentity(), let did = deviceId, let hid = householdId else {
                linkError = "无法获取设备信息"
                return
            }
            await performLink(service: service, deviceId: did, householdId: hid, from: window)
            return
        }
        await performLink(service: service, deviceId: did, householdId: hid, from: window)
    }

    @MainActor
    private func performLink(service: MusicService, deviceId: String, householdId: String,
                             from window: UIWindow?) async {
        isLinking = true
        linkingService = service
        linkError = nil

        do {
            let result: SMAPILinkResult
            if service.authType == "AppLink" {
                result = try await SonosAPI.smapiGetAppLink(
                    smapiURI: service.smapiURI, deviceId: deviceId, householdId: householdId)
            } else {
                result = try await SonosAPI.smapiGetDeviceLinkCode(
                    smapiURI: service.smapiURI, deviceId: deviceId, householdId: householdId)
            }

            print("[SMAPI] Link \(service.name): regUrl=\(result.regUrl), linkCode=\(result.linkCode.prefix(8))…")

            pendingLinkCode = result.linkCode
            pendingLinkSmapiURI = service.smapiURI

            guard let url = URL(string: result.regUrl) else {
                linkError = "无效的登录链接"
                isLinking = false
                return
            }

            let callbackReceived = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: "sonoswidget"
                ) { _, error in
                    continuation.resume(returning: error == nil)
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                session.start()
            }

            if callbackReceived || true {
                // For most services, after login in the browser the linkCode becomes valid.
                // Try to exchange immediately.
                try await Task.sleep(for: .milliseconds(1500))
                await finishLinking(service: service)
            }
        } catch {
            print("[SMAPI] Link error: \(error)")
            linkError = "登录失败: \(error.localizedDescription)"
            isLinking = false
        }
    }

    func finishLinking(service: MusicService) async {
        guard let did = deviceId, let hid = householdId,
              let linkCode = pendingLinkCode else {
            linkError = "缺少登录信息"
            isLinking = false
            return
        }

        let smapiURI = pendingLinkSmapiURI ?? service.smapiURI

        do {
            let creds = try await SonosAPI.smapiGetDeviceAuthToken(
                smapiURI: smapiURI, deviceId: did, householdId: hid, linkCode: linkCode)
            saveCredentials(creds, serviceId: service.id)
            serviceEnabled[service.id] = true
            persistToggles()
            print("[SMAPI] ✓ Linked \(service.name), token=\(creds.token.prefix(12))…")
            linkError = nil
        } catch {
            print("[SMAPI] getDeviceAuthToken failed: \(error)")
            linkError = "授权未完成，请重试"
        }

        isLinking = false
        linkingService = nil
        pendingLinkCode = nil
        pendingLinkSmapiURI = nil
    }

    // MARK: - Browse

    func loadBrowseContent() async {
        guard let ip = speakerIP else { return }
        isLoadingBrowse = true
        errorMessage = nil

        async let favs = tryBrowse { try await SonosAPI.browseFavorites(ip: ip) }
        async let lists = tryBrowse { try await SonosAPI.browsePlaylists(ip: ip) }
        async let stations = tryBrowse { try await SonosAPI.browseRadio(ip: ip) }

        favorites = await favs
        playlists = await lists
        radio = await stations

        if musicServices.isEmpty {
            musicServices = (try? await SonosAPI.listMusicServices(ip: ip)) ?? []
        }

        isLoadingBrowse = false
    }

    private func tryBrowse(_ block: () async throws -> [BrowseItem]) async -> [BrowseItem] {
        (try? await block()) ?? []
    }

    // MARK: - Search

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

            guard let ip = speakerIP else {
                isSearching = false
                return
            }

            if !hasProbed { await probeLinkedServices() }
            guard !Task.isCancelled else { return }

            let services = activeServices
            guard !services.isEmpty else {
                print("[Search] No active services to search")
                searchResults = []
                isSearching = false
                return
            }

            print("[Search] Searching \(services.count) services for: \(query)")

            var results: [ServiceSearchResult] = []
            await withTaskGroup(of: ServiceSearchResult?.self) { group in
                for service in services {
                    group.addTask { [weak self] in
                        guard let self else { return nil }
                        return await self.searchService(service, query: query, ip: ip)
                    }
                }
                for await result in group {
                    if let r = result { results.append(r) }
                }
            }

            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        }
    }

    private func searchService(_ service: MusicService, query: String, ip: String) async -> ServiceSearchResult? {
        do {
            let items: [BrowseItem]
            if service.needsLogin, let creds = loadCredentials(serviceId: service.id),
               let did = deviceId, let hid = householdId {
                items = try await SonosAPI.searchMusicServiceAuthenticated(
                    smapiURI: service.smapiURI, serviceId: service.id, searchTerm: query,
                    deviceId: did, householdId: hid, token: creds.token, key: creds.key)
            } else {
                let sessionId = (try? await SonosAPI.getSessionId(ip: ip, serviceId: service.id)) ?? ""
                items = try await SonosAPI.searchMusicService(
                    smapiURI: service.smapiURI, sessionId: sessionId,
                    serviceId: service.id, searchTerm: query)
            }
            if !items.isEmpty {
                print("[Search] \(service.name) → \(items.count) results")
            }
            return items.isEmpty ? nil : ServiceSearchResult(service: service, items: items)
        } catch {
            if !Task.isCancelled {
                print("[Search] \(service.name) failed: \(error.localizedDescription)")
            }
            return nil
        }
    }

    // MARK: - Playback Actions

    private func playbackMetadata(for item: BrowseItem) -> String {
        if let resMD = item.resMD, !resMD.isEmpty {
            return resMD
        }
        return SonosAPI.buildDIDLMetadata(item: item)
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

        let prevTitle = manager.trackInfo?.title

        print("[Playback] ====== playNow START ======")
        print("[Playback] title=\(item.title) isContainer=\(item.isContainer) id=\(item.id)")
        print("[Playback] uri=\(uri)")

        do {
            print("[Playback] Trying SetAVTransportURI")
            try await SonosAPI.setAVTransportURI(ip: ip, uri: uri, metadata: playMeta)
            try await SonosAPI.play(ip: ip)
            print("[Playback] SetAVTransportURI + Play sent")

            try? await Task.sleep(for: .milliseconds(1000))

            let newInfo = try? await SonosAPI.getPositionInfo(ip: ip)
            let contentChanged = newInfo?.title != prevTitle || prevTitle == nil
            let state = try? await SonosAPI.getTransportInfo(ip: ip)

            if contentChanged && (state == .playing || state == .transitioning) {
                print("[Playback] SUCCESS: content changed, transport=\(state?.rawValue ?? "?")")
            } else if uri.contains("x-rincon-cpcontainer:") {
                print("[Playback] Content didn't change, trying queue approach")
                guard let uuid = manager.selectedSpeaker?.id else { return }
                try await SonosAPI.removeAllTracksFromQueue(ip: ip)
                try await SonosAPI.addURIToQueue(ip: ip, uri: uri, metadata: playMeta)
                try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: uuid)
                try await SonosAPI.play(ip: ip)
                print("[Playback] Queue fallback sent")
            }

            try? await Task.sleep(for: .milliseconds(500))
            await manager.refreshState()
        } catch {
            print("[Playback] FAILED: \(error)")
            errorMessage = error.localizedDescription
        }
        print("[Playback] ====== playNow END ======")
    }

    func playNext(item: BrowseItem, manager: SonosManager) async {
        guard let uri = item.uri else { return }
        await manager.playNext(uri: uri, metadata: playbackMetadata(for: item))
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

// MARK: - ASWebAuthenticationPresentationContextProviding

extension SearchManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}
