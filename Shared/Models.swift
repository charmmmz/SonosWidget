import Foundation
import SwiftUI
import ActivityKit

// MARK: - Repeat Mode

enum RepeatMode: String, Codable, Sendable {
    case off, all, one
}

// MARK: - Playback Source

enum PlaybackSource: String, Codable, Sendable {
    case spotify
    case appleMusic
    case amazonMusic
    case tidal
    case youtubeMusic
    case neteaseMusic
    case airplay
    case radio
    case lineIn
    case library
    case unknown

    var displayName: String {
        switch self {
        case .spotify:       return "Spotify"
        case .appleMusic:    return "Apple Music"
        case .amazonMusic:   return "Amazon Music"
        case .tidal:         return "Tidal"
        case .youtubeMusic:  return "YouTube Music"
        case .neteaseMusic:  return "网易云音乐"
        case .airplay:       return "AirPlay"
        case .radio:         return "Radio"
        case .lineIn:        return "Line-In"
        case .library:       return "Library"
        case .unknown:       return ""
        }
    }

    var iconName: String {
        switch self {
        case .airplay:  return "airplayaudio"
        case .radio:    return "radio"
        case .lineIn:   return "cable.connector"
        case .library:  return "externaldrive"
        default:        return "music.note"
        }
    }

    /// Asset name in `BrandMedia` for services with bundled vector marks; otherwise `nil`.
    var brandAssetImageName: String? {
        switch self {
        case .spotify:       return "BrandSpotify"
        case .appleMusic:    return "BrandAppleMusic"
        case .amazonMusic:   return "BrandAmazonMusic"
        case .youtubeMusic:  return "BrandYouTubeMusic"
        case .neteaseMusic:  return "BrandNeteaseMusic"
        default: return nil
        }
    }

    var badgeColor: Color {
        switch self {
        case .spotify:       return Color(.sRGB, red: 0.12, green: 0.84, blue: 0.38, opacity: 1)
        case .appleMusic:    return Color(.sRGB, red: 0.98, green: 0.24, blue: 0.35, opacity: 1)
        case .amazonMusic:   return Color(.sRGB, red: 0.14, green: 0.74, blue: 0.85, opacity: 1)
        case .tidal:         return Color(.sRGB, red: 0.0, green: 0.0, blue: 0.0, opacity: 1)
        case .youtubeMusic:  return Color(.sRGB, red: 1.0, green: 0.0, blue: 0.0, opacity: 1)
        case .neteaseMusic:  return Color(.sRGB, red: 1.0, green: 0.23, blue: 0.23, opacity: 1)
        case .airplay:       return Color(.sRGB, red: 0.0, green: 0.48, blue: 1.0, opacity: 1)
        case .radio:         return Color(.sRGB, red: 1.0, green: 0.58, blue: 0.0, opacity: 1)
        case .lineIn:        return .gray
        case .library:       return .purple
        case .unknown:       return .clear
        }
    }

    var isStreamingService: Bool {
        switch self {
        case .spotify, .appleMusic, .amazonMusic, .tidal, .youtubeMusic, .neteaseMusic:
            return true
        default: return false
        }
    }

    /// Map a human-readable streaming service name (as returned by the Sonos
    /// cloud `service.name` field or by the speaker's `ListAvailableServices`)
    /// to a typed `PlaybackSource`. Intentionally lenient — we just look for
    /// brand keywords anywhere in the string because the canonical casing /
    /// wording varies between Sonos's Cloud API response and SMAPI metadata.
    nonisolated static func from(serviceName: String?) -> PlaybackSource {
        guard let raw = serviceName?.lowercased(), !raw.isEmpty else { return .unknown }
        if raw.contains("spotify")       { return .spotify }
        if raw.contains("apple")         { return .appleMusic }
        if raw.contains("amazon")        { return .amazonMusic }
        if raw.contains("tidal")         { return .tidal }
        if raw.contains("youtube")       { return .youtubeMusic }
        if raw.contains("netease") || (serviceName ?? "").contains("网易") { return .neteaseMusic }
        return .unknown
    }

    nonisolated static func from(trackURI: String) -> PlaybackSource {
        let uri = trackURI.lowercased()

        if uri.hasPrefix("x-sonos-spotify:") || uri.contains("sid=9&") || uri.hasSuffix("sid=9") {
            return .spotify
        }
        if uri.hasPrefix("x-sonosprog-http:") || uri.contains("sid=204") {
            return .appleMusic
        }
        if uri.contains("sid=203") {
            return .amazonMusic
        }
        if uri.contains("sid=174") {
            return .tidal
        }
        if uri.contains("sid=284") {
            return .youtubeMusic
        }
        if uri.hasPrefix("x-sonos-vli:") || uri.hasPrefix("x-rincon-stream:") {
            return .airplay
        }
        if uri.hasPrefix("x-sonosapi-stream:") || uri.hasPrefix("x-sonosapi-radio:")
            || uri.hasPrefix("x-rincon-mp3radio:") || uri.hasPrefix("aac:") {
            return .radio
        }
        if uri.hasPrefix("x-file-cifs:") || uri.hasPrefix("x-rincon-playlist:") {
            return .library
        }

        // Second-chance resolution: for streaming services whose local
        // Sonos `sid` varies per installation (NetEase Cloud Music etc.),
        // consult the sid → service-name map that `SearchManager` snapshots
        // into `SharedStorage` after `ListAvailableServices`. Lets us tag
        // sources correctly without hard-coding per-region sids, and gives
        // the widget / Live Activity the same enrichment main-app UI gets.
        if let sid = Self.extractSid(from: trackURI),
           let serviceName = SharedStorage.serviceNamesByLocalSid[sid] {
            let resolved = from(serviceName: serviceName)
            if resolved != .unknown { return resolved }
        }

        return .unknown
    }

    private static func extractSid(from uri: String) -> String? {
        guard let queryPart = uri.split(separator: "?").last else { return nil }
        for param in queryPart.split(separator: "&") {
            let kv = param.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0] == "sid" else { continue }
            return String(kv[1])
        }
        return nil
    }
}

// MARK: - Speaker

struct SonosPlayer: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var ipAddress: String
    var isCoordinator: Bool
    var groupId: String?
    var coordinatorIP: String?
    var isInvisible: Bool = false

    var playbackIP: String { coordinatorIP ?? ipAddress }
}

// MARK: - Transport

enum TransportState: String, Codable, Sendable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case noMedia = "NO_MEDIA_PRESENT"
    case unknown = "UNKNOWN"
}

// MARK: - Track

struct TrackInfo: Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var albumArtURL: String?
    var duration: String?
    var position: String?
    var source: PlaybackSource = .unknown
    var audioQuality: AudioQuality?
    /// Raw Sonos transport URI (for debugging/comparison).
    var trackURI: String?

    var durationSeconds: TimeInterval { SonosTime.parse(duration ?? "") }
    var positionSeconds: TimeInterval { SonosTime.parse(position ?? "") }
}

// MARK: - Audio Quality

struct AudioQuality: Codable, Equatable, Sendable {
    var codec: String
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?

    var label: String {
        if codec.lowercased().contains("atmos") || (channels ?? 0) > 2 {
            return "Dolby Atmos"
        }
        if isHiRes {
            return "Hi-Res Lossless"
        }
        if isLossless {
            return "Lossless"
        }
        return codec.uppercased()
    }

    var isAtmos: Bool {
        codec.lowercased().contains("atmos") || (channels ?? 0) > 2
    }


    var isLossless: Bool {
        let c = codec.lowercased()
        if c.contains("hi-res") || c.contains("hires") || c.contains("hi res") { return true }
        if c == "lossless" || c.contains("lossless") || c.contains("flac") || c.contains("alac") || c.contains("wav")
            || c.contains("aiff") || c.contains("pcm") {
            return true
        }
        if (c == "aac" || c.contains("mp4") || c.contains("m4a"))
            && (bitDepth != nil || sampleRate != nil) {
            return true
        }
        return false
    }

    var isHiRes: Bool {
        guard isLossless else { return false }
        return (sampleRate ?? 0) > 48000 || ((sampleRate ?? 0) >= 48000 && (bitDepth ?? 0) >= 24)
    }

    /// Marketing badge in `BrandMedia` (Dolby Atmos, Apple Lossless mark, etc.).
    /// Hi-Res Lossless uses the same mark as Lossless (`BadgeAppleLossless`).
    var badgeAssetImageName: String? {
        if isAtmos { return "BadgeDolbyAtmos" }
        if isLossless { return "BadgeAppleLossless" }
        return nil
    }

    /// Derives a badge from a display label when `AudioQuality` is not available (e.g. widget string cache).
    nonisolated static func badgeImageName(forQualityLabel label: String?) -> String? {
        guard let label else { return nil }
        let lower = label.lowercased()
        if lower.contains("atmos") { return "BadgeDolbyAtmos" }
        if lower.contains("lossless") || lower.contains("hi-res") || lower.contains("hi res")
            || lower.contains("hires") || lower.contains("hi_res") {
            return "BadgeAppleLossless"
        }
        return nil
    }

    nonisolated static func from(protocolInfo: String, sampleRate: String?, bitDepth: String?,
                                 channels: String?, streamContent: String = "",
                                 source: PlaybackSource = .unknown) -> AudioQuality? {
        let parts = protocolInfo.split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return nil }
        let mime = parts[2].lowercased()
        let sc = streamContent.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        var parsedSR = sampleRate
        var parsedBD = bitDepth

        // Parse "bitDepth/sampleRateKHz" from streamContent (e.g. "FLAC 16/44.1", "ALAC 24/96")
        if let regex = try? NSRegularExpression(pattern: "(\\d+)/(\\d+\\.?\\d*)"),
           let match = regex.firstMatch(in: streamContent, range: NSRange(streamContent.startIndex..., in: streamContent)) {
            if parsedBD == nil, let r = Range(match.range(at: 1), in: streamContent) {
                parsedBD = String(streamContent[r])
            }
            if parsedSR == nil, let r = Range(match.range(at: 2), in: streamContent) {
                let srStr = String(streamContent[r])
                if let kHz = Double(srStr), kHz < 1000 {
                    parsedSR = String(Int(kHz * 1000))
                } else {
                    parsedSR = srStr
                }
            }
        }

        // Determine codec — prefer streamContent, then MIME, then source-based heuristic
        let codec: String
        if sc.contains("flac") { codec = "FLAC" }
        else if sc.contains("alac") { codec = "ALAC" }
        else if sc.contains("pcm") { codec = "PCM" }
        else if sc.contains("aiff") { codec = "AIFF" }
        else if sc.contains("wav") { codec = "WAV" }
        else if sc.contains("dolby") || sc.contains("atmos") || sc.contains("ac3") || sc.contains("ec3") { codec = "Atmos" }
        else if sc.contains("ogg") { codec = "OGG" }
        else if mime.contains("flac") { codec = "FLAC" }
        else if mime.contains("wav") || mime.contains("wave") { codec = "WAV" }
        else if mime.contains("aiff") { codec = "AIFF" }
        else if mime.contains("mp4") || mime.contains("m4a") {
            if parsedBD != nil {
                codec = "ALAC"
            } else if parsedSR != nil {
                codec = "ALAC"
            } else {
                // UPnP doesn't expose codec detail for streaming services —
                // return nil so the UI hides the badge rather than guessing.
                return nil
            }
        }
        else if mime.contains("mp3") || mime.contains("mpeg") {
            // Local library & radio: the MIME is the real codec → show "MP3".
            // Streaming / unknown sources: UPnP often reports audio/mpeg even
            // for lossless streams → return nil so the badge stays hidden until
            // the Cloud API provides the real quality.
            if source == .library || source == .radio {
                codec = "MP3"
            } else if parsedBD != nil || parsedSR != nil {
                codec = "MP3"
            } else {
                return nil
            }
        }
        else if mime.contains("ogg") { codec = "OGG" }
        else if mime.contains("wma") { codec = "WMA" }
        else { codec = mime.replacingOccurrences(of: "audio/", with: "").uppercased() }

        return AudioQuality(
            codec: codec,
            sampleRate: parsedSR.flatMap(Int.init),
            bitDepth: parsedBD.flatMap(Int.init),
            channels: channels.flatMap(Int.init)
        )
    }

    /// Map Sonos Cloud API track quality to our local model.
    nonisolated static func from(cloudQuality q: SonosCloudAPI.CloudTrackQuality) -> AudioQuality? {
        let codec = q.codec?.lowercased() ?? ""

        let mappedCodec: String
        if q.immersive == true || codec.contains("dolby") || codec.contains("atmos")
            || codec.contains("ac3") || codec.contains("ec3") {
            mappedCodec = "Atmos"
        } else if q.lossless == true {
            if codec.contains("flac") { mappedCodec = "FLAC" }
            else if codec.contains("alac") { mappedCodec = "ALAC" }
            else if codec.isEmpty { mappedCodec = "Lossless" }
            else { mappedCodec = codec.uppercased() }
        } else if !codec.isEmpty {
            mappedCodec = codec.uppercased()
        } else {
            return nil
        }

        return AudioQuality(
            codec: mappedCodec,
            sampleRate: q.sampleRate,
            bitDepth: q.bitDepth,
            channels: nil
        )
    }
}

// MARK: - Speaker Group Status

struct SpeakerGroupStatus: Identifiable, Sendable {
    var id: String
    var coordinator: SonosPlayer
    var members: [SonosPlayer]
    var trackInfo: TrackInfo?
    var transportState: TransportState
    var volume: Int = 0
}

// MARK: - Queue

struct QueueItem: Identifiable, Codable, Sendable {
    var id: String
    var objectID: String
    var trackNumber: Int
    var title: String
    var artist: String
    var album: String
    var albumArtURL: String?
    var uri: String?
    var metaXML: String?
}

struct QueueResult: Sendable {
    var items: [QueueItem]
    var updateID: String
}

// MARK: - Browse / Search

struct BrowseItem: Identifiable, Codable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var albumArtURL: String?
    var uri: String?
    var metaXML: String?
    /// Resource metadata from Sonos Favorites (`r:resMD`), decoded DIDL-Lite.
    var resMD: String?
    var isContainer: Bool
    var serviceId: Int?
    /// Cloud API resource type: "TRACK", "ARTIST", "ALBUM", "PLAYLIST", "PROGRAM"
    var cloudType: String?
    /// Set when this `BrowseItem` was sourced from the Sonos Cloud Control API's
    /// `listFavorites` endpoint. Lets `playNow` route tap-to-play through
    /// `loadFavorite` instead of UPnP when the app is in remote mode.
    var cloudFavoriteId: String?

    var isArtist: Bool {
        if cloudType == "ARTIST" { return true }
        if let resMD, resMD.contains("musicArtist") { return true }
        if let metaXML, metaXML.contains("musicArtist") { return true }
        return false
    }

    enum FavoriteCategory: String, CaseIterable {
        case playlist = "Playlists"
        case album = "Albums"
        case song = "Songs"
        case station = "Stations"
        case artist = "Artists"
        case collection = "Collections"
    }

    var favoriteCategory: FavoriteCategory {
        // Authoritative source when present: factory-built items (from
        // `makeAlbumItem`, `makeArtistItem`, etc.) carry `cloudType` directly,
        // so we should trust that over URI / upnp:class heuristics — otherwise
        // e.g. an album with URI `x-rincon-cpcontainer:1004206c album%3A…`
        // ends up misclassified as Playlist (both share that URI scheme).
        switch cloudType {
        case "ALBUM":      return .album
        case "ARTIST":     return .artist
        case "PLAYLIST":   return .playlist
        case "TRACK":      return .song
        case "PROGRAM":    return .station
        case "COLLECTION": return .collection
        default:           break
        }

        let classStr = upnpClass
        if classStr.contains("musicArtist") { return .artist }
        if classStr.contains("musicTrack") { return .song }
        if classStr.contains("audioBroadcast") || classStr.contains("audioItem") && !classStr.contains("musicTrack") { return .station }
        if classStr.contains("musicAlbum") { return .album }
        if classStr.contains("playlistContainer") || classStr.contains("sameArtist") { return .playlist }
        // Fallback heuristics using URI scheme and metadata
        let uriSources = [uri, resMD, metaXML].compactMap { $0 }
        if uriSources.contains(where: { $0.contains("libraryfolder") }) { return .collection }
        if let uri {
            if uri.contains("x-sonosapi-radio:") || uri.contains("x-sonosapi-stream:") { return .station }
            if uri.contains("x-rincon-cpcontainer:") { return .playlist }
        }
        if uriSources.contains(where: { $0.contains("x-sonosapi-radio:") || $0.contains("x-sonosapi-stream:") }) { return .station }
        if isContainer { return .playlist }
        // Non-container favorite that didn't match any container scheme —
        // almost always a single track saved by the user.
        return .song
    }

    private var upnpClass: String {
        if let resMD, let cls = extractInlineTag("upnp:class", from: resMD) { return cls }
        if let metaXML, let cls = extractInlineTag("upnp:class", from: metaXML) { return cls }
        return ""
    }

    private func extractInlineTag(_ tag: String, from xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}

struct MusicService: Identifiable, Sendable {
    var id: Int
    var name: String
    var smapiURI: String
    var capabilitiesMask: Int
    var authType: String
    var serviceType: String = ""

    var canSearch: Bool { capabilitiesMask & 1 != 0 }
    var isAnonymous: Bool { authType == "Anonymous" }
    var needsLogin: Bool { authType == "AppLink" || authType == "DeviceLink" }
}

// MARK: - Live Activity

struct SonosActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var trackTitle: String
        var artist: String
        var album: String
        var isPlaying: Bool
        var positionSeconds: Double
        var durationSeconds: Double
        var dominantColorHex: String?
        /// When playing: Date() - positionSeconds. Used for real-time progress via timerInterval.
        var startedAt: Date?
        /// When playing: Date() + remainingSeconds. Pair with startedAt for ProgressView(timerInterval:).
        var endsAt: Date?
        /// Album art compressed to ≤15KB thumbnail, embedded directly so the Live Activity
        /// renderer (separate process) doesn't need to hit UserDefaults / app group.
        var albumArtThumbnail: Data?
        /// Number of speakers in the current group (1 = standalone).
        var groupMemberCount: Int = 1
        /// PlaybackSource raw value for displaying streaming service badge.
        var playbackSourceRaw: String? = nil
    }
    var speakerName: String
}

// MARK: - Time Helpers

enum SonosTime {
    nonisolated static func parse(_ str: String) -> TimeInterval {
        let parts = str.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return 0
        }
    }

    nonisolated static func display(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    nonisolated static func apiFormat(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
