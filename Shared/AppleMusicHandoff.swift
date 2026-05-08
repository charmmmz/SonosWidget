import Foundation
import MediaPlayer

struct AppleMusicHandoffTrack: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval?
    let position: TimeInterval
    let playbackStoreID: String?
    let persistentID: UInt64?
}

enum AppleMusicHandoffError: LocalizedError, Equatable {
    case mediaAccessDenied
    case notPlayingAppleMusic
    case missingTrackMetadata
    case missingPlaybackStoreID
    case phonePlaybackFailed

    var errorDescription: String? {
        switch self {
        case .mediaAccessDenied:
            return "Apple Music access is not allowed."
        case .notPlayingAppleMusic:
            return "Nothing is currently playing in Apple Music."
        case .missingTrackMetadata:
            return "The current Apple Music track could not be identified."
        case .missingPlaybackStoreID:
            return "The Apple Music track could not be opened on this iPhone."
        case .phonePlaybackFailed:
            return "Apple Music did not start playback on this iPhone."
        }
    }
}

@MainActor
final class AppleMusicHandoffManager {
    static let shared = AppleMusicHandoffManager()

    private let player = MPMusicPlayerController.systemMusicPlayer

    private init() {}

    func currentAppleMusicTrack() async throws -> AppleMusicHandoffTrack {
        let status = await mediaLibraryAuthorizationStatus()
        guard status == .authorized else {
            throw AppleMusicHandoffError.mediaAccessDenied
        }

        guard player.playbackState == .playing else {
            throw AppleMusicHandoffError.notPlayingAppleMusic
        }
        guard let item = player.nowPlayingItem else {
            throw AppleMusicHandoffError.notPlayingAppleMusic
        }

        let title = trimmed(item.title)
        let artist = trimmed(item.artist)
        guard !title.isEmpty, !artist.isEmpty else {
            throw AppleMusicHandoffError.missingTrackMetadata
        }

        let album = trimmed(item.albumTitle)
        let duration = item.playbackDuration > 0 ? item.playbackDuration : nil
        return AppleMusicHandoffTrack(
            title: title,
            artist: artist,
            album: album.isEmpty ? nil : album,
            duration: duration,
            position: max(0, player.currentPlaybackTime),
            playbackStoreID: item.playbackStoreID.isEmpty ? nil : item.playbackStoreID,
            persistentID: item.persistentID == 0 ? nil : item.persistentID
        )
    }

    func playAppleMusicTrack(storeID: String, position: TimeInterval?) async throws {
        let status = await mediaLibraryAuthorizationStatus()
        guard status == .authorized else {
            throw AppleMusicHandoffError.mediaAccessDenied
        }

        let trimmedStoreID = storeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStoreID.isEmpty else {
            throw AppleMusicHandoffError.missingPlaybackStoreID
        }

        player.setQueue(with: [trimmedStoreID])
        try await prepareToPlay()
        player.play()

        if let position, position > 3 {
            player.currentPlaybackTime = max(0, position)
        }

        try await Task.sleep(for: .milliseconds(700))
        guard let item = player.nowPlayingItem else {
            throw AppleMusicHandoffError.phonePlaybackFailed
        }
        let currentStoreID = item.playbackStoreID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentStoreID.isEmpty, currentStoreID != trimmedStoreID {
            throw AppleMusicHandoffError.phonePlaybackFailed
        }
        guard player.playbackState == .playing || !currentStoreID.isEmpty else {
            throw AppleMusicHandoffError.phonePlaybackFailed
        }
    }

    func pausePhonePlayback() {
        player.pause()
    }

    private func prepareToPlay() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            player.prepareToPlay { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func mediaLibraryAuthorizationStatus() async -> MPMediaLibraryAuthorizationStatus {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            return .authorized
        case .notDetermined:
            return await MPMediaLibrary.requestAuthorization()
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }

    private func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
