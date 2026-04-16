import AppIntents
import WidgetKit

struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Playback"
    static var description: IntentDescription = "Play or pause the current Sonos speaker."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.speakerIP else { return .result() }

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
        guard let ip = SharedStorage.speakerIP else { return .result() }
        try? await SonosAPI.next(ip: ip)
        try? await Task.sleep(for: .milliseconds(500))

        if let info = try? await SonosAPI.getPositionInfo(ip: ip) {
            SharedStorage.cachedTrackTitle = info.title
            SharedStorage.cachedArtist = info.artist
            SharedStorage.cachedAlbum = info.album
            SharedStorage.cachedAlbumArtURL = info.albumArtURL

            if let urlStr = info.albumArtURL, let url = URL(string: urlStr) {
                let (data, _) = try await URLSession.shared.data(from: url)
                SharedStorage.albumArtData = data
            }
        }

        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description: IntentDescription = "Go back to the previous track."

    func perform() async throws -> some IntentResult {
        guard let ip = SharedStorage.speakerIP else { return .result() }
        try? await SonosAPI.previous(ip: ip)
        try? await Task.sleep(for: .milliseconds(500))

        if let info = try? await SonosAPI.getPositionInfo(ip: ip) {
            SharedStorage.cachedTrackTitle = info.title
            SharedStorage.cachedArtist = info.artist
            SharedStorage.cachedAlbum = info.album
            SharedStorage.cachedAlbumArtURL = info.albumArtURL

            if let urlStr = info.albumArtURL, let url = URL(string: urlStr) {
                let (data, _) = try await URLSession.shared.data(from: url)
                SharedStorage.albumArtData = data
            }
        }

        WidgetCenter.shared.reloadTimelines(ofKind: "SonosWidget")
        return .result()
    }
}
