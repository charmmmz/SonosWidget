import Foundation

/// URLSession that bypasses any local HTTP proxy (e.g. Clash/Surge on the same network).
let noProxySession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = [:]
    return URLSession(configuration: config)
}()

enum SharedStorage {

    nonisolated static let appGroupID = "group.com.charm.SonosWidget"

    private nonisolated static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    private nonisolated static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    // MARK: - Speaker

    nonisolated static var speakerIP: String? {
        get { defaults.string(forKey: "speakerIP") }
        set { defaults.set(newValue, forKey: "speakerIP") }
    }

    nonisolated static var speakerName: String? {
        get { defaults.string(forKey: "speakerName") }
        set { defaults.set(newValue, forKey: "speakerName") }
    }

    nonisolated static var coordinatorIP: String? {
        get { defaults.string(forKey: "coordinatorIP") }
        set { defaults.set(newValue, forKey: "coordinatorIP") }
    }

    // MARK: - Cached Playback State

    nonisolated static var isPlaying: Bool {
        get { defaults.bool(forKey: "isPlaying") }
        set { defaults.set(newValue, forKey: "isPlaying") }
    }

    nonisolated static var cachedTrackTitle: String? {
        get { defaults.string(forKey: "trackTitle") }
        set { defaults.set(newValue, forKey: "trackTitle") }
    }

    nonisolated static var cachedArtist: String? {
        get { defaults.string(forKey: "artist") }
        set { defaults.set(newValue, forKey: "artist") }
    }

    nonisolated static var cachedAlbum: String? {
        get { defaults.string(forKey: "album") }
        set { defaults.set(newValue, forKey: "album") }
    }

    nonisolated static var cachedAlbumArtURL: String? {
        get { defaults.string(forKey: "albumArtURL") }
        set { defaults.set(newValue, forKey: "albumArtURL") }
    }

    nonisolated static var cachedVolume: Int {
        get { defaults.integer(forKey: "volume") }
        set { defaults.set(newValue, forKey: "volume") }
    }

    nonisolated static var cachedPlaybackSource: String? {
        get { defaults.string(forKey: "playbackSource") }
        set { defaults.set(newValue, forKey: "playbackSource") }
    }

    nonisolated static var cachedDominantColorHex: String? {
        get { defaults.string(forKey: "dominantColorHex") }
        set { defaults.set(newValue, forKey: "dominantColorHex") }
    }

    nonisolated static var cachedAudioQualityLabel: String? {
        get { defaults.string(forKey: "audioQualityLabel") }
        set { defaults.set(newValue, forKey: "audioQualityLabel") }
    }

    /// Timestamp after which fetchLiveEntry may overwrite isPlaying from the device.
    /// Set by PlayPauseIntent to prevent the live fetch from reverting the optimistic update.
    nonisolated static var playStateLockUntil: Date {
        get {
            let ts = defaults.double(forKey: "playStateLockUntil")
            return ts == 0 ? .distantPast : Date(timeIntervalSince1970: ts)
        }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "playStateLockUntil") }
    }

    // MARK: - Sonos Cloud API (shared with widget extension)

    /// OAuth access token — mirrored here so widget extension can call Cloud API without Keychain sharing.
    nonisolated static var cloudAccessToken: String? {
        get { defaults.string(forKey: "cloudAccessToken") }
        set { defaults.set(newValue, forKey: "cloudAccessToken") }
    }

    nonisolated static var cloudTokenExpiry: Date {
        get {
            let ts = defaults.double(forKey: "cloudTokenExpiry")
            return ts == 0 ? .distantPast : Date(timeIntervalSince1970: ts)
        }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "cloudTokenExpiry") }
    }

    /// Cloud group ID for the currently selected speaker's group.
    nonisolated static var cloudGroupId: String? {
        get { defaults.string(forKey: "cloudGroupId") }
        set { defaults.set(newValue, forKey: "cloudGroupId") }
    }

    /// Total visible speakers in the currently playing group (including coordinator).
    nonisolated static var cachedGroupMemberCount: Int {
        get { defaults.integer(forKey: "groupMemberCount") }
        set { defaults.set(newValue, forKey: "groupMemberCount") }
    }

    // MARK: - Album Art File

    nonisolated static var albumArtData: Data? {
        get {
            guard let url = containerURL?.appendingPathComponent("albumArt.jpg") else { return nil }
            return try? Data(contentsOf: url)
        }
        set {
            guard let url = containerURL?.appendingPathComponent("albumArt.jpg") else { return }
            if let data = newValue {
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Saved Speakers

    nonisolated static var savedSpeakers: [SonosPlayer] {
        get {
            guard let data = defaults.data(forKey: "savedSpeakers"),
                  let speakers = try? JSONDecoder().decode([SonosPlayer].self, from: data) else { return [] }
            return speakers
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: "savedSpeakers")
        }
    }
}
