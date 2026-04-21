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
    case airplay
    case radio
    case lineIn
    case library
    case unknown

    var displayName: String {
        switch self {
        case .spotify:      return "Spotify"
        case .appleMusic:   return "Apple Music"
        case .amazonMusic:  return "Amazon Music"
        case .tidal:        return "Tidal"
        case .youtubeMusic: return "YouTube Music"
        case .airplay:      return "AirPlay"
        case .radio:        return "Radio"
        case .lineIn:       return "Line-In"
        case .library:      return "Library"
        case .unknown:      return ""
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

    var badgeColor: Color {
        switch self {
        case .spotify:      return Color(.sRGB, red: 0.12, green: 0.84, blue: 0.38, opacity: 1)
        case .appleMusic:   return Color(.sRGB, red: 0.98, green: 0.24, blue: 0.35, opacity: 1)
        case .amazonMusic:  return Color(.sRGB, red: 0.14, green: 0.74, blue: 0.85, opacity: 1)
        case .tidal:        return Color(.sRGB, red: 0.0, green: 0.0, blue: 0.0, opacity: 1)
        case .youtubeMusic: return Color(.sRGB, red: 1.0, green: 0.0, blue: 0.0, opacity: 1)
        case .airplay:      return Color(.sRGB, red: 0.0, green: 0.48, blue: 1.0, opacity: 1)
        case .radio:        return Color(.sRGB, red: 1.0, green: 0.58, blue: 0.0, opacity: 1)
        case .lineIn:       return .gray
        case .library:      return .purple
        case .unknown:      return .clear
        }
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
        return .unknown
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
        if c == "lossless" || c.contains("flac") || c.contains("alac") || c.contains("wav")
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
        else if mime.contains("mp3") || mime.contains("mpeg") { codec = "MP3" }
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

// MARK: - SMAPI Credentials

struct SMAPICredentials: Codable, Sendable {
    var token: String
    var key: String
}

struct SMAPILinkResult: Sendable {
    var regUrl: String
    var linkCode: String
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
