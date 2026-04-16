import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct SonosEntry: TimelineEntry {
    let date: Date
    let trackTitle: String
    let artist: String
    let album: String
    let isPlaying: Bool
    let albumArtData: Data?
    let isConfigured: Bool
    let speakerName: String?

    static var placeholder: SonosEntry {
        SonosEntry(date: .now, trackTitle: "Song Title", artist: "Artist Name",
                   album: "Album", isPlaying: true, albumArtData: nil,
                   isConfigured: true, speakerName: "Living Room")
    }

    static var unconfigured: SonosEntry {
        SonosEntry(date: .now, trackTitle: "", artist: "", album: "",
                   isPlaying: false, albumArtData: nil,
                   isConfigured: false, speakerName: nil)
    }
}

// MARK: - Timeline Provider

struct SonosProvider: TimelineProvider {
    func placeholder(in context: Context) -> SonosEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (SonosEntry) -> Void) {
        completion(cachedEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SonosEntry>) -> Void) {
        Task {
            let entry = await fetchLiveEntry()
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 10, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }
    }

    private func cachedEntry() -> SonosEntry {
        guard SharedStorage.speakerIP != nil else { return .unconfigured }
        return SonosEntry(
            date: .now,
            trackTitle: SharedStorage.cachedTrackTitle ?? "Not Playing",
            artist: SharedStorage.cachedArtist ?? "—",
            album: SharedStorage.cachedAlbum ?? "",
            isPlaying: SharedStorage.isPlaying,
            albumArtData: SharedStorage.albumArtData,
            isConfigured: true,
            speakerName: SharedStorage.speakerName
        )
    }

    private func fetchLiveEntry() async -> SonosEntry {
        guard let ip = SharedStorage.speakerIP else { return .unconfigured }

        do {
            let state = try await SonosAPI.getTransportInfo(ip: ip)
            let info = try await SonosAPI.getPositionInfo(ip: ip)

            SharedStorage.isPlaying = (state == .playing)
            SharedStorage.cachedTrackTitle = info.title
            SharedStorage.cachedArtist = info.artist
            SharedStorage.cachedAlbum = info.album
            SharedStorage.cachedAlbumArtURL = info.albumArtURL

            var artData = SharedStorage.albumArtData
            if let urlStr = info.albumArtURL, let url = URL(string: urlStr) {
                if let (data, _) = try? await URLSession.shared.data(from: url) {
                    artData = data
                    SharedStorage.albumArtData = data
                }
            }

            return SonosEntry(
                date: .now,
                trackTitle: info.title,
                artist: info.artist,
                album: info.album,
                isPlaying: state == .playing,
                albumArtData: artData,
                isConfigured: true,
                speakerName: SharedStorage.speakerName
            )
        } catch {
            return cachedEntry()
        }
    }
}

// MARK: - Widget Views

struct SonosWidgetSmallView: View {
    let entry: SonosEntry

    var body: some View {
        if !entry.isConfigured {
            unconfiguredView
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    albumArtThumb(size: 44)
                    Spacer()
                    if let name = entry.speakerName {
                        Text(name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(entry.trackTitle)
                    .font(.caption.bold())
                    .lineLimit(2)

                Text(entry.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 16) {
                    Button(intent: PreviousTrackIntent()) {
                        Image(systemName: "backward.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)

                    Button(intent: PlayPauseIntent()) {
                        Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill")
                            .font(.body)
                    }
                    .buttonStyle(.plain)

                    Button(intent: NextTrackIntent()) {
                        Image(systemName: "forward.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var unconfiguredView: some View {
        VStack(spacing: 8) {
            Image(systemName: "hifispeaker.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open app to set up Sonos")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func albumArtThumb(size: CGFloat) -> some View {
        if let data = entry.albumArtData, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
        }
    }
}

struct SonosWidgetMediumView: View {
    let entry: SonosEntry

    var body: some View {
        if !entry.isConfigured {
            unconfiguredView
        } else {
            HStack(spacing: 12) {
                albumArt

                VStack(alignment: .leading, spacing: 4) {
                    if let name = entry.speakerName {
                        Text(name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(entry.trackTitle)
                        .font(.subheadline.bold())
                        .lineLimit(2)

                    Text(entry.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(entry.album)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Spacer()

                    HStack(spacing: 20) {
                        Button(intent: PreviousTrackIntent()) {
                            Image(systemName: "backward.fill")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)

                        Button(intent: PlayPauseIntent()) {
                            Image(systemName: entry.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)

                        Button(intent: NextTrackIntent()) {
                            Image(systemName: "forward.fill")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var unconfiguredView: some View {
        HStack(spacing: 12) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sonos Widget")
                    .font(.headline)
                Text("Open the app to connect to your Sonos speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var albumArt: some View {
        if let data = entry.albumArtData, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .frame(width: 120, height: 120)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
        }
    }
}

// MARK: - Widget Definition

struct SonosWidget: Widget {
    let kind: String = "SonosWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SonosProvider()) { entry in
            Group {
                if #available(iOSApplicationExtension 17.0, *) {
                    SonosWidgetContainerView(entry: entry)
                        .containerBackground(.fill.tertiary, for: .widget)
                } else {
                    SonosWidgetContainerView(entry: entry)
                        .padding()
                        .background()
                }
            }
        }
        .configurationDisplayName("Sonos Controller")
        .description("Control your Sonos speakers and see what's playing.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SonosWidgetContainerView: View {
    @Environment(\.widgetFamily) var family
    let entry: SonosEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SonosWidgetSmallView(entry: entry)
        case .systemMedium:
            SonosWidgetMediumView(entry: entry)
        default:
            SonosWidgetMediumView(entry: entry)
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    SonosWidget()
} timeline: {
    SonosEntry.placeholder
}

#Preview("Medium", as: .systemMedium) {
    SonosWidget()
} timeline: {
    SonosEntry.placeholder
}
