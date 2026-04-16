import AppIntents
import WidgetKit
import Foundation

// MARK: - Playback Intents

struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Playback"
    static var description: IntentDescription = "Play or pause the current Sonos speaker."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP else { return .result() }

        let state = try? await SonosAPI.getTransportInfo(ip: ip)
        if state == .playing {
            try? await SonosAPI.pause(ip: ip)
            SharedStorage.isPlaying = false
        } else {
            try? await SonosAPI.play(ip: ip)
            SharedStorage.isPlaying = true
        }

        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description: IntentDescription = "Skip to the next track."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP else { return .result() }
        try? await SonosAPI.next(ip: ip)
        try? await Task.sleep(for: .milliseconds(500))
        await IntentHelper.refreshCache(playbackIP: ip)
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description: IntentDescription = "Go back to the previous track."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP else { return .result() }
        try? await SonosAPI.previous(ip: ip)
        try? await Task.sleep(for: .milliseconds(500))
        await IntentHelper.refreshCache(playbackIP: ip)
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

// MARK: - Volume Intents

struct VolumeUpIntent: AppIntent {
    static var title: LocalizedStringResource = "Volume Up"
    static var description: IntentDescription = "Increase volume by 5."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.speakerIP else { return .result() }
        let current = (try? await SonosAPI.getVolume(ip: ip)) ?? SharedStorage.cachedVolume
        let newVol = min(100, current + 5)
        try? await SonosAPI.setVolume(ip: ip, volume: newVol)
        SharedStorage.cachedVolume = newVol
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

struct VolumeDownIntent: AppIntent {
    static var title: LocalizedStringResource = "Volume Down"
    static var description: IntentDescription = "Decrease volume by 5."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.speakerIP else { return .result() }
        let current = (try? await SonosAPI.getVolume(ip: ip)) ?? SharedStorage.cachedVolume
        let newVol = max(0, current - 5)
        try? await SonosAPI.setVolume(ip: ip, volume: newVol)
        SharedStorage.cachedVolume = newVol
        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

// MARK: - Shared Helper

enum IntentHelper {
    static func refreshCache(playbackIP ip: String) async {
        if let info = try? await SonosAPI.getPositionInfo(ip: ip) {
            SharedStorage.cachedTrackTitle = info.title
            SharedStorage.cachedArtist = info.artist
            SharedStorage.cachedAlbum = info.album
            SharedStorage.cachedAlbumArtURL = info.albumArtURL

            if let urlStr = info.albumArtURL, let url = URL(string: urlStr),
               let (data, _) = try? await URLSession.shared.data(from: url) {
                SharedStorage.albumArtData = data
            }
        }
    }
}
