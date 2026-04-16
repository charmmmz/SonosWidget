import Foundation
import ActivityKit

// MARK: - Speaker

struct SonosPlayer: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var ipAddress: String
    var isCoordinator: Bool
    var groupId: String?
    var coordinatorIP: String?

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

    var durationSeconds: TimeInterval { SonosTime.parse(duration ?? "") }
    var positionSeconds: TimeInterval { SonosTime.parse(position ?? "") }
}

// MARK: - Queue

struct QueueItem: Identifiable, Codable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var albumArtURL: String?
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
