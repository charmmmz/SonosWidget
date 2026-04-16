import Foundation

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
