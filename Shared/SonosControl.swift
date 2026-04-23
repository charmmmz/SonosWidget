import Foundation

/// Error thrown when the current `SonosControl.Backend` doesn't have a path
/// for the requested verb — most commonly when the user is off-LAN and the
/// Sonos Cloud API simply doesn't expose the operation (queue mutations,
/// per-speaker CreateObject for favorites, etc.).
enum SonosControlError: Error, LocalizedError {
    case unsupportedInCloudMode(feature: String)
    case noBackend

    var errorDescription: String? {
        switch self {
        case .unsupportedInCloudMode(let feature):
            return "\(feature) requires being on the same network as the speakers."
        case .noBackend:
            return "Speaker unreachable — pull to refresh."
        }
    }
}

/// Façade that routes a control verb (play, pause, setVolume, …) to either
/// the LAN UPnP stack (`SonosAPI` on port 1400) or the Sonos Cloud Control
/// API (`SonosCloudAPI` on `api.ws.sonos.com`). `SonosManager` picks a
/// `Backend` once per "session" via its probe logic and passes it here for
/// every command — individual verbs never care which one they got.
///
/// Design rule: verbs that have no cloud equivalent (queue mutations,
/// `CreateObject`-based favorite editing, `SetAVTransportURI` for arbitrary
/// SMAPI URIs) throw `.unsupportedInCloudMode` when invoked on `.cloud`.
/// Callers are expected to guard with the UI (disable the button) *and* be
/// ready to surface the error if the user still reaches it (e.g. via a
/// stale control from a shortcut).
enum SonosControl {

    /// Everything the router needs to execute a command. Packaged once by
    /// `SonosManager.currentControlBackend()` so downstream sites don't
    /// need to know what kind of "session" the user is in.
    enum Backend {
        case lan(ip: String, volumeIP: String, speakerUUID: String)
        case cloud(groupId: String, token: String, householdId: String, playerId: String?)
    }

    // MARK: - Transport

    static func play(_ backend: Backend) async throws {
        switch backend {
        case .lan(let ip, _, _):
            try await SonosAPI.play(ip: ip)
        case .cloud(let groupId, let token, _, _):
            try await SonosCloudAPI.play(token: token, groupId: groupId)
        }
    }

    static func pause(_ backend: Backend) async throws {
        switch backend {
        case .lan(let ip, _, _):
            try await SonosAPI.pause(ip: ip)
        case .cloud(let groupId, let token, _, _):
            try await SonosCloudAPI.pause(token: token, groupId: groupId)
        }
    }

    static func togglePlayPause(_ backend: Backend, currentlyPlaying: Bool) async throws {
        switch backend {
        case .lan(let ip, _, _):
            if currentlyPlaying { try await SonosAPI.pause(ip: ip) }
            else { try await SonosAPI.play(ip: ip) }
        case .cloud(let groupId, let token, _, _):
            try await SonosCloudAPI.togglePlayPause(token: token, groupId: groupId)
        }
    }

    static func next(_ backend: Backend) async throws {
        switch backend {
        case .lan(let ip, _, _):
            try await SonosAPI.next(ip: ip)
        case .cloud(let groupId, let token, _, _):
            try await SonosCloudAPI.skipToNextTrack(token: token, groupId: groupId)
        }
    }

    static func previous(_ backend: Backend) async throws {
        switch backend {
        case .lan(let ip, _, _):
            try await SonosAPI.previous(ip: ip)
        case .cloud(let groupId, let token, _, _):
            try await SonosCloudAPI.skipToPreviousTrack(token: token, groupId: groupId)
        }
    }

    /// Seek to an absolute position within the current track. LAN uses a
    /// `H:MM:SS` REL_TIME string; Cloud takes milliseconds — we accept a
    /// `TimeInterval` and translate.
    static func seek(_ backend: Backend, to seconds: TimeInterval) async throws {
        switch backend {
        case .lan(let ip, _, _):
            try await SonosAPI.seek(ip: ip, position: SonosTime.apiFormat(seconds))
        case .cloud(let groupId, let token, _, _):
            try await SonosCloudAPI.seek(
                token: token, groupId: groupId,
                positionMillis: Int((seconds * 1000.0).rounded()))
        }
    }

    // MARK: - Volume

    /// Set the volume for the individual speaker (or the coordinator's own
    /// volume on LAN). On cloud, we use `setPlayerVolume` if we have a
    /// `playerId`; otherwise we fall back to `setGroupVolume`.
    static func setVolume(_ backend: Backend, _ volume: Int) async throws {
        switch backend {
        case .lan(_, let volumeIP, _):
            try await SonosAPI.setVolume(ip: volumeIP, volume: volume)
        case .cloud(let groupId, let token, _, let playerId):
            if let playerId {
                try await SonosCloudAPI.setPlayerVolume(
                    token: token, playerId: playerId, volume: volume)
            } else {
                try await SonosCloudAPI.setGroupVolume(
                    token: token, groupId: groupId, volume: volume)
            }
        }
    }

    static func setGroupVolume(_ backend: Backend, _ volume: Int) async throws {
        switch backend {
        case .lan(let ip, _, _):
            try await SonosAPI.setGroupVolume(ip: ip, volume: volume)
        case .cloud(let groupId, let token, _, _):
            try await SonosCloudAPI.setGroupVolume(
                token: token, groupId: groupId, volume: volume)
        }
    }

    // MARK: - Play modes (LAN-only for now)

    static func setPlayMode(_ backend: Backend,
                            shuffle: Bool, repeatMode: RepeatMode) async throws {
        switch backend {
        case .lan(let ip, _, _):
            try await SonosAPI.setPlayMode(ip: ip, shuffle: shuffle, repeat: repeatMode)
        case .cloud:
            throw SonosControlError.unsupportedInCloudMode(feature: "Changing play mode")
        }
    }

    // MARK: - Queue mutations (LAN-only — cloud has no per-track queue edit)

    @discardableResult
    static func addURIToQueue(_ backend: Backend, uri: String, metadata: String,
                              asNext: Bool = false) async throws -> Int {
        switch backend {
        case .lan(let ip, _, _):
            return try await SonosAPI.addURIToQueue(
                ip: ip, uri: uri, metadata: metadata, asNext: asNext)
        case .cloud:
            throw SonosControlError.unsupportedInCloudMode(feature: "Adding to the queue")
        }
    }

    static func removeTrackFromQueue(_ backend: Backend,
                                     objectID: String, updateID: String) async throws {
        switch backend {
        case .lan(let ip, _, _):
            try await SonosAPI.removeTrackFromQueue(
                ip: ip, objectID: objectID, updateID: updateID)
        case .cloud:
            throw SonosControlError.unsupportedInCloudMode(feature: "Removing queue items")
        }
    }

    static func reorderTracksInQueue(_ backend: Backend,
                                     startIndex: Int, numTracks: Int,
                                     insertBefore: Int, updateID: String) async throws {
        switch backend {
        case .lan(let ip, _, _):
            try await SonosAPI.reorderTracksInQueue(
                ip: ip, startIndex: startIndex, numTracks: numTracks,
                insertBefore: insertBefore, updateID: updateID)
        case .cloud:
            throw SonosControlError.unsupportedInCloudMode(feature: "Reordering the queue")
        }
    }

    static func removeAllTracksFromQueue(_ backend: Backend) async throws {
        switch backend {
        case .lan(let ip, _, _):
            try await SonosAPI.removeAllTracksFromQueue(ip: ip)
        case .cloud:
            throw SonosControlError.unsupportedInCloudMode(feature: "Clearing the queue")
        }
    }

    static func setAVTransportToQueue(_ backend: Backend) async throws {
        switch backend {
        case .lan(let ip, _, let uuid):
            try await SonosAPI.setAVTransportToQueue(ip: ip, speakerUUID: uuid)
        case .cloud:
            throw SonosControlError.unsupportedInCloudMode(feature: "Switching to the queue")
        }
    }

    static func seekToTrack(_ backend: Backend, trackNumber: Int) async throws {
        switch backend {
        case .lan(let ip, _, _):
            try await SonosAPI.seekToTrack(ip: ip, trackNumber: trackNumber)
        case .cloud:
            throw SonosControlError.unsupportedInCloudMode(feature: "Jumping to a queue track")
        }
    }

    static func setAVTransportURI(_ backend: Backend,
                                  uri: String, metadata: String = "") async throws {
        switch backend {
        case .lan(let ip, _, _):
            try await SonosAPI.setAVTransportURI(ip: ip, uri: uri, metadata: metadata)
        case .cloud(let groupId, let token, _, _):
            // Best-effort: try the Control API's loadStreamUrl. Sonos may
            // refuse non-HTTP schemes (e.g. `x-sonosapi-radio:`) — the
            // caller should be prepared to fail gracefully.
            try await SonosCloudAPI.loadStreamUrl(
                token: token, groupId: groupId, streamUrl: uri)
        }
    }

    // MARK: - Grouping (LAN-only for now)

    static func joinGroup(_ backend: Backend, speakerIP: String,
                          coordinatorUUID: String) async throws {
        switch backend {
        case .lan:
            try await SonosAPI.joinGroup(
                speakerIP: speakerIP, coordinatorUUID: coordinatorUUID)
        case .cloud:
            throw SonosControlError.unsupportedInCloudMode(feature: "Joining speaker groups")
        }
    }

    static func leaveGroup(_ backend: Backend, speakerIP: String) async throws {
        switch backend {
        case .lan:
            try await SonosAPI.leaveGroup(speakerIP: speakerIP)
        case .cloud:
            throw SonosControlError.unsupportedInCloudMode(feature: "Leaving speaker groups")
        }
    }
}
