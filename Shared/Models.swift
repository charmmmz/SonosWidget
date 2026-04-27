import Foundation
import SwiftUI
import ActivityKit

// MARK: - Repeat Mode

enum RepeatMode: String, Codable, Sendable {
    case off, all, one
}

// MARK: - Soundbar Speech Enhancement Level

/// Sonos exposes the soundbar's "Speech Enhancement" via the
/// `RenderingControl.DialogLevel` UPnP field. Older bars (Beam, original
/// Arc, Ray) only accept `0` or `1` (off / on). The Arc Ultra widened the
/// range to a 5-step scale matching the official app's "Off / Low / Medium
/// / High / Max" picker. We model all five so the UI can render the full
/// menu; on legacy bars values >1 are simply rejected by the device.
enum SpeechEnhancementLevel: Int, Codable, Sendable, CaseIterable {
    case off = 0, low = 1, medium = 2, high = 3, max = 4

    var label: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        case .max:    return "Max"
        }
    }

    /// Compact label for a card pill where space is tight ("Med" instead of
    /// "Medium"). Only applies to `.medium`; the rest already fit.
    var shortLabel: String {
        self == .medium ? "Med" : label
    }

    var isOn: Bool { self != .off }

    /// Map an arbitrary int to the closest valid level. Older bars echo back
    /// `1` as "on"; we treat that as `.low` which is functionally how the
    /// Sonos app rendered the legacy on-state when re-paired with Arc Ultra.
    static func from(rawLevel level: Int) -> SpeechEnhancementLevel {
        // `max` inside the enum scope resolves to the `.max` case, so we
        // need to namespace `Swift.max`/`Swift.min` explicitly.
        let clamped = Swift.max(0, Swift.min(4, level))
        return SpeechEnhancementLevel(rawValue: clamped) ?? .off
    }
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
    case tv          // HDMI eARC / optical / coax on a Sonos soundbar
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
        case .tv:            return "TV"
        case .library:       return "Library"
        case .unknown:       return ""
        }
    }

    var iconName: String {
        switch self {
        case .airplay:  return "airplayaudio"
        case .radio:    return "radio"
        case .lineIn:   return "cable.connector"
        case .tv:       return "tv"
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
        case .tv:            return Color(.sRGB, red: 0.30, green: 0.32, blue: 0.36, opacity: 1)
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
        if uri.hasPrefix("x-sonos-htastream:") {
            return .tv
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
    /// Decoded TV audio-input format from `DeviceProperties.GetZoneInfo`'s
    /// `HTAudioIn` field. Populated only when `source == .tv`.
    var tvFormat: TVAudioFormat?

    var durationSeconds: TimeInterval { SonosTime.parse(duration ?? "") }
    var positionSeconds: TimeInterval { SonosTime.parse(position ?? "") }

    /// True when the playing source has no fixed duration — Apple Music 1 /
    /// TuneIn live broadcasts, internet radio streams, AirPlay / line-in.
    /// Used by the player UI to swap the seek bar / skip controls for a
    /// "LIVE" pill + stop button (you can't seek or skip a live stream).
    /// TV input has its own dedicated panel (`tvFormatPanel`) and is
    /// excluded so the soundbar branch keeps its existing behavior.
    var isLiveStream: Bool {
        if source == .tv { return false }
        return durationSeconds <= 0
    }
}

// MARK: - TV Audio Format

/// Decoded soundbar audio-input format. Sourced from
/// `DeviceProperties.GetZoneInfo`'s `HTAudioIn` integer code; the lookup table
/// matches soco's `AUDIO_INPUT_FORMATS` (the same one Home Assistant exposes
/// as `sensor.<speaker>_audio_input_format`).
struct TVAudioFormat: Codable, Equatable, Sendable {
    /// Raw `HTAudioIn` code Sonos returned. Kept around for the geek view —
    /// unmapped codes still render as "Unknown (code: <n>)" instead of being
    /// silently dropped.
    var rawCode: Int
    /// Human-readable label from the Sonos format table, e.g.
    /// "Dolby Atmos (TrueHD)" / "Dolby 5.1" / "PCM 2.0" / "No input".
    var label: String

    /// Whether the soundbar is currently receiving any audio at all.
    /// "No input", "No input connected", and "No audio" all map to false.
    nonisolated var hasSignal: Bool {
        let lower = label.lowercased()
        return !(lower.contains("no input") || lower.contains("no audio"))
    }

    /// True when the bitstream is carrying Dolby Atmos object audio
    /// (over TrueHD, DD+, or MAT 2.0).
    nonisolated var isAtmos: Bool {
        label.lowercased().contains("atmos")
    }

    /// "5.1" / "7.1" / "2.0" — extracted from the label so we can render it
    /// as a separate pill in the UI. Returns nil when the label has no
    /// channel suffix (e.g. "No input"), AND for object-based Atmos streams
    /// where the "2.0" inside "MAT 2.0" is the *protocol version*, not a
    /// channel layout — Atmos is object-based so a fixed channel count is
    /// meaningless anyway.
    nonisolated var channelLayout: String? {
        if isAtmos { return nil }
        for layout in ["7.1", "5.1", "2.0"] where label.contains(layout) {
            return layout
        }
        return nil
    }

    /// Underlying Atmos transport (`TrueHD` / `DD+` / `MAT`) when this is an
    /// Atmos stream. Used for compact UI where the Dolby Atmos logo is
    /// already rendered as a badge and we don't need to repeat the words
    /// "Dolby Atmos" in text. Nil for non-Atmos formats.
    nonisolated var atmosVariant: String? {
        guard isAtmos else { return nil }
        if label.contains("TrueHD") { return "TrueHD" }
        if label.contains("DD+")    { return "DD+" }
        if label.contains("MAT")    { return "MAT" }
        return nil
    }

    /// Codec family without the channel suffix —"Dolby Atmos · TrueHD",
    /// "Dolby Digital+", "PCM" — so the UI can render codec and channel
    /// layout in separate visual slots.
    nonisolated var codec: String {
        let l = label
        if l.contains("Atmos (TrueHD)")     { return "Dolby Atmos · TrueHD" }
        if l.contains("Atmos (DD+)")        { return "Dolby Atmos · DD+" }
        if l.contains("Atmos (MAT 2.0)")    { return "Dolby Atmos · MAT" }
        if l.contains("Dolby TrueHD")       { return "Dolby TrueHD" }
        if l.contains("Dolby Digital Plus") { return "Dolby Digital+" }
        if l.contains("Dolby Multichannel PCM") { return "Multichannel PCM" }
        if l.contains("Multichannel PCM")   { return "Multichannel PCM" }
        if l.contains("Dolby")              { return "Dolby Digital" }
        if l.contains("DTS")                { return "DTS" }
        if l.hasPrefix("PCM")               { return "PCM" }
        if l == "Stereo"                    { return "Stereo PCM" }
        return l   // fall back to raw label (covers "No input", "No audio")
    }

    /// Subtitle slot text — "Live audio" when the soundbar is receiving a
    /// stream, "No signal" when it isn't. Hardware-agnostic on purpose: we
    /// can't reliably tell HDMI vs Optical (Sonos's URI is `:spdif` for
    /// both), so we describe the *state* of the input rather than the
    /// physical port.
    nonisolated var statusLabel: String {
        hasSignal ? "Live audio" : "No signal"
    }

    /// One-line geek summary used inline ("Dolby Atmos · TrueHD · 7.1").
    nonisolated var geekLabel: String {
        var parts = [codec]
        if let layout = channelLayout, !codec.contains(layout) {
            parts.append(layout)
        }
        return parts.joined(separator: " · ")
    }

    /// Map of Sonos `HTAudioIn` codes → friendly labels. Kept verbatim from
    /// soco's `AUDIO_INPUT_FORMATS` table so we benefit from the community's
    /// reverse-engineering (the bitfield encoding isn't documented by Sonos;
    /// these codes come from observation across firmware versions).
    private nonisolated static let knownFormats: [Int: String] = [
        0: "No input connected",
        2: "Stereo",
        7: "Dolby 2.0",
        18: "Dolby 5.1",
        21: "No input",
        22: "No audio",
        59: "Dolby Atmos (DD+)",
        61: "Dolby Atmos (TrueHD)",
        63: "Dolby Atmos (MAT 2.0)",
        33554434: "PCM 2.0",
        33554454: "PCM 2.0 no audio",
        33554488: "Dolby 2.0",
        33554490: "Dolby Digital Plus 2.0",
        33554492: "Dolby TrueHD 2.0",
        33554494: "Dolby Multichannel PCM 2.0",
        84934658: "Multichannel PCM 5.1",
        84934713: "Dolby 5.1",
        84934714: "Dolby Digital Plus 5.1",
        84934716: "Dolby TrueHD 5.1",
        84934718: "Dolby Multichannel PCM 5.1",
        84934721: "DTS 5.1",
        118489090: "Multichannel PCM 7.1",
        118489146: "Dolby Digital Plus 7.1",
    ]

    nonisolated static func from(htAudioInCode code: Int) -> TVAudioFormat {
        let label = knownFormats[code] ?? "Unknown (code: \(code))"
        return TVAudioFormat(rawCode: code, label: label)
    }
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

    /// Companion to `badgeImageName` — returns the text that should be
    /// rendered *next to* the badge so the badge wordmark and the text
    /// don't repeat each other. The Dolby Atmos badge is itself a
    /// "DOLBY ATMOS" wordmark, so when we'd otherwise render
    /// "Dolby Atmos · MAT" we drop the prefix and just keep "MAT" / "TrueHD"
    /// / "DD+" / "5.1". For plain "Dolby Atmos" (music tracks where we have
    /// no transport variant) we return nil so the caller can render the
    /// badge alone with no companion text.
    ///
    /// The Apple Lossless badge is a glyph-only mark with no readable
    /// "LOSSLESS" text, so its companion ("Lossless" / "Hi-Res Lossless")
    /// stays intact and we just hand the original label back.
    nonisolated static func badgeCompanionLabel(forQualityLabel label: String?) -> String? {
        guard let label else { return nil }
        let lower = label.lowercased()
        guard lower.contains("atmos") else { return label }
        // Strip the "Dolby Atmos" prefix and any " · " / " — " / "·" / "—"
        // separator that immediately followed it, leaving just the
        // transport variant ("MAT", "TrueHD", "DD+") or channel layout.
        var remainder = label
        if let range = remainder.range(of: "Dolby Atmos", options: .caseInsensitive) {
            remainder.removeSubrange(range)
        }
        let trimmed = remainder.trimmingCharacters(
            in: CharacterSet(charactersIn: " ·—-").union(.whitespacesAndNewlines)
        )
        return trimmed.isEmpty ? nil : trimmed
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
        // Generic `object.container` with no specific subtype is how Sonos
        // surfaces Apple Music "On the Air …" curated shows, third-party
        // service collections, and library folders. Without this catch-all
        // they fall through to `.song` because their `<res>` is empty and
        // they're parsed as `<item>` (so `isContainer == false`). Place
        // this AFTER the specific subclass checks so it doesn't intercept
        // album / playlist / artist classes that all start with
        // `object.container.…`.
        if classStr.contains("object.container") { return .collection }
        // Treat shortcut-type favorites with empty `<res>` as collections
        // for the same reason — Sonos uses `<r:type>shortcut</r:type>` to
        // mark navigation-only favorites (artists, collections, library
        // folders) and only artists carry a `musicArtist` upnp:class. The
        // residue here is collection-shaped.
        let metaSources = [resMD, metaXML].compactMap { $0 }
        if metaSources.contains(where: { $0.contains("<r:type>shortcut</r:type>") }) {
            return .collection
        }
        // Fallback heuristics using URI scheme and metadata
        let uriSources = [uri, resMD, metaXML].compactMap { $0 }
        if uriSources.contains(where: { $0.contains("libraryfolder") }) { return .collection }
        if let uri {
            if uri.contains("x-sonosapi-radio:") || uri.contains("x-sonosapi-stream:") { return .station }
            if uri.contains("x-rincon-cpcontainer:") { return .playlist }
        }
        if uriSources.contains(where: { $0.contains("x-sonosapi-radio:") || $0.contains("x-sonosapi-stream:") }) { return .station }
        if isContainer { return .playlist }
        // Last-resort `.song` fallback. Anything reaching here is genuinely
        // a non-container, non-streaming favorite that didn't match any
        // hint — almost always a single track the user saved.
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

extension SonosActivityAttributes.ContentState {
    /// Mirror of `TrackInfo.isLiveStream` for Live Activity rendering. We
    /// recompute from the carried fields rather than adding another
    /// stored value to keep the ActivityKit payload size unchanged.
    var isLiveStream: Bool {
        if playbackSourceRaw == PlaybackSource.tv.rawValue { return false }
        return durationSeconds <= 0
    }
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
