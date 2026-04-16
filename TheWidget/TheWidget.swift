import AppIntents
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
    let playbackSource: PlaybackSource
    let dominantColorHex: String?

    var dominantColor: Color? { dominantColorHex.flatMap(Color.init(hex:)) }

    static var placeholder: SonosEntry {
        SonosEntry(date: .now, trackTitle: "Song Title", artist: "Artist Name",
                   album: "Album", isPlaying: true, albumArtData: nil,
                   isConfigured: true, speakerName: "Living Room",
                   playbackSource: .unknown, dominantColorHex: nil)
    }

    static var unconfigured: SonosEntry {
        SonosEntry(date: .now, trackTitle: "", artist: "", album: "",
                   isPlaying: false, albumArtData: nil,
                   isConfigured: false, speakerName: nil,
                   playbackSource: .unknown, dominantColorHex: nil)
    }
}

// MARK: - Timeline Provider

struct SonosProvider: TimelineProvider {
    func placeholder(in context: Context) -> SonosEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (SonosEntry) -> Void) {
        completion(cachedEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SonosEntry>) -> Void) {
        Task {
            let entry = await fetchLiveEntry()
            let next = Calendar.current.date(byAdding: .minute, value: 5, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func cachedEntry() -> SonosEntry {
        guard SharedStorage.speakerIP != nil else { return .unconfigured }
        let source = SharedStorage.cachedPlaybackSource.flatMap(PlaybackSource.init(rawValue:)) ?? .unknown
        return SonosEntry(
            date: .now,
            trackTitle: SharedStorage.cachedTrackTitle ?? "Not Playing",
            artist: SharedStorage.cachedArtist ?? "—",
            album: SharedStorage.cachedAlbum ?? "",
            isPlaying: SharedStorage.isPlaying,
            albumArtData: SharedStorage.albumArtData,
            isConfigured: true,
            speakerName: SharedStorage.speakerName,
            playbackSource: source,
            dominantColorHex: SharedStorage.cachedDominantColorHex
        )
    }

    private func fetchLiveEntry() async -> SonosEntry {
        let playIP = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP
        guard let ip = playIP else { return .unconfigured }

        do {
            let state = try await SonosAPI.getTransportInfo(ip: ip)
            let info = try await SonosAPI.getPositionInfo(ip: ip)

            SharedStorage.isPlaying = (state == .playing)
            SharedStorage.cachedTrackTitle = info.title
            SharedStorage.cachedArtist = info.artist
            SharedStorage.cachedAlbum = info.album
            SharedStorage.cachedAlbumArtURL = info.albumArtURL
            SharedStorage.cachedPlaybackSource = info.source.rawValue

            var artData = SharedStorage.albumArtData
            if let urlStr = info.albumArtURL, let url = URL(string: urlStr) {
                var req = URLRequest(url: url, timeoutInterval: 5)
                req.httpMethod = "GET"
                if let (data, _) = try? await URLSession.shared.data(for: req) {
                    artData = data
                    SharedStorage.albumArtData = data
                }
            }

            return SonosEntry(date: .now, trackTitle: info.title, artist: info.artist,
                              album: info.album, isPlaying: state == .playing,
                              albumArtData: artData, isConfigured: true,
                              speakerName: SharedStorage.speakerName,
                              playbackSource: info.source,
                              dominantColorHex: SharedStorage.cachedDominantColorHex)
        } catch {
            return cachedEntry()
        }
    }
}

// MARK: - Small Widget

struct SonosWidgetSmallView: View {
    let entry: SonosEntry

    var body: some View {
        if !entry.isConfigured {
            unconfiguredView
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    artThumb(size: 44)
                    Spacer()
                    if entry.playbackSource != .unknown {
                        SourceBadgeView(source: entry.playbackSource,
                                        tintColor: entry.dominantColor,
                                        compact: true)
                    }
                }

                Spacer()

                Text(entry.trackTitle)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(entry.artist)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)

                HStack(spacing: 16) {
                    Button(intent: PreviousTrackIntent()) {
                        Image(systemName: "backward.fill").font(.caption)
                    }.buttonStyle(.plain)
                    Button(intent: PlayPauseIntent()) {
                        Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill").font(.body)
                    }.buttonStyle(.plain)
                    Button(intent: NextTrackIntent()) {
                        Image(systemName: "forward.fill").font(.caption)
                    }.buttonStyle(.plain)
                }
                .foregroundStyle(.white)
            }
        }
    }

    private var unconfiguredView: some View {
        VStack(spacing: 8) {
            Image(systemName: "hifispeaker.fill").font(.title2).foregroundStyle(.secondary)
            Text("Open app to set up Sonos")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func artThumb(size: CGFloat) -> some View {
        if let data = entry.albumArtData, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.15))
                .frame(width: size, height: size)
                .overlay { Image(systemName: "music.note").font(.caption).foregroundStyle(.white.opacity(0.4)) }
        }
    }
}

// MARK: - Medium Widget

struct SonosWidgetMediumView: View {
    let entry: SonosEntry

    var body: some View {
        if !entry.isConfigured {
            unconfiguredView
        } else {
            HStack(spacing: 12) {
                albumArt

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        if let name = entry.speakerName {
                            Text(entry.isPlaying
                                 ? "NOW PLAYING ON \(name.uppercased())"
                                 : "CONTINUE ON \(name.uppercased())")
                                .font(.system(size: 8, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if entry.playbackSource != .unknown {
                            SourceBadgeView(source: entry.playbackSource,
                                            tintColor: entry.dominantColor,
                                            compact: true)
                        }
                    }

                    Spacer(minLength: 6)

                    Text(entry.trackTitle).font(.subheadline.bold()).foregroundStyle(.white).lineLimit(2)
                    Text(entry.artist).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        .padding(.top, 1)
                    Text(entry.album).font(.caption2).foregroundStyle(.white.opacity(0.45)).lineLimit(1)

                    Spacer(minLength: 6)

                    HStack(spacing: 12) {
                        Button(intent: VolumeDownIntent()) {
                            Image(systemName: "speaker.minus.fill").font(.caption2)
                        }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))

                        Spacer()

                        Button(intent: PreviousTrackIntent()) {
                            Image(systemName: "backward.fill").font(.callout)
                        }.buttonStyle(.plain)
                        Button(intent: PlayPauseIntent()) {
                            Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                        }.buttonStyle(.plain)
                        Button(intent: NextTrackIntent()) {
                            Image(systemName: "forward.fill").font(.callout)
                        }.buttonStyle(.plain)

                        Spacer()

                        Button(intent: VolumeUpIntent()) {
                            Image(systemName: "speaker.plus.fill").font(.caption2)
                        }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                    }
                    .foregroundStyle(.white)
                }
            }
        }
    }

    private var unconfiguredView: some View {
        HStack(spacing: 12) {
            Image(systemName: "hifispeaker.2.fill").font(.largeTitle).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sonos Widget").font(.headline)
                Text("Open the app to connect to your Sonos speakers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var albumArt: some View {
        if let data = entry.albumArtData, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        } else {
            RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.15))
                .frame(width: 120, height: 120)
                .overlay { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.white.opacity(0.4)) }
        }
    }
}

// MARK: - Widget Definition

struct SonosWidget: Widget {
    let kind: String = "SonosWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SonosProvider()) { entry in
            SonosWidgetContainerView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBlurredBackground(albumArtData: entry.albumArtData)
                }
        }
        .configurationDisplayName("Sonos Controller")
        .description("Control your Sonos speakers and see what's playing.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WidgetBlurredBackground: View {
    let albumArtData: Data?

    var body: some View {
        if let data = albumArtData, let img = UIImage(data: data) {
            ZStack {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 40)
                    .scaleEffect(1.5)
                    .clipped()

                LinearGradient(
                    colors: [.black.opacity(0.5), .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            Color(.systemBackground).opacity(0.3)
        }
    }
}

struct SonosWidgetContainerView: View {
    @Environment(\.widgetFamily) var family
    let entry: SonosEntry

    var body: some View {
        switch family {
        case .systemSmall: SonosWidgetSmallView(entry: entry)
        default: SonosWidgetMediumView(entry: entry)
        }
    }
}

#Preview("Small", as: .systemSmall) { SonosWidget() } timeline: { SonosEntry.placeholder }
#Preview("Medium", as: .systemMedium) { SonosWidget() } timeline: { SonosEntry.placeholder }
