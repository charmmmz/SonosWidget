import AppIntents
import WidgetKit
import SwiftUI
import UIKit

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
    let groupMemberCount: Int
    let playbackSource: PlaybackSource
    let dominantColorHex: String?
    let audioQualityLabel: String?

    var dominantColor: Color? { dominantColorHex.flatMap(Color.init(hex:)) }

    static var placeholder: SonosEntry {
        SonosEntry(date: .now, trackTitle: "Song Title", artist: "Artist Name",
                   album: "Album", isPlaying: true, albumArtData: nil,
                   isConfigured: true, speakerName: "Living Room", groupMemberCount: 1,
                   playbackSource: .unknown, dominantColorHex: nil,
                   audioQualityLabel: "Lossless")
    }

    static var unconfigured: SonosEntry {
        SonosEntry(date: .now, trackTitle: "", artist: "", album: "",
                   isPlaying: false, albumArtData: nil,
                   isConfigured: false, speakerName: nil, groupMemberCount: 1,
                   playbackSource: .unknown, dominantColorHex: nil,
                   audioQualityLabel: nil)
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

            // If a song is playing, schedule a refresh right when it should end.
            // This gives WidgetKit a concrete deadline to honor rather than a vague "2 minutes".
            // Fall back to 2 minutes if no duration info is available.
            let fallback = Date().addingTimeInterval(2 * 60)
            var nextRefresh = fallback

            if SharedStorage.isPlaying,
               let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP,
               let info = try? await SonosAPI.getPositionInfo(ip: ip) {
                let remaining = info.durationSeconds - info.positionSeconds
                if remaining > 5 && remaining < 20 * 60 {
                    // Refresh 2s after the song ends so the next song has started.
                    nextRefresh = Date().addingTimeInterval(remaining + 2)
                }
            }

            // Always cap at 2 minutes so we don't wait too long for short/unknown tracks.
            nextRefresh = min(nextRefresh, fallback)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
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
            groupMemberCount: SharedStorage.cachedGroupMemberCount,
            playbackSource: source,
            dominantColorHex: SharedStorage.cachedDominantColorHex,
            audioQualityLabel: SharedStorage.cachedAudioQualityLabel
        )
    }

    private func fetchLiveEntry() async -> SonosEntry {
        let playIP = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP
        guard let ip = playIP else { return .unconfigured }

        do {
            async let stateTask = SonosAPI.getTransportInfo(ip: ip)
            async let infoTask = SonosAPI.getPositionInfo(ip: ip)
            let state = try await stateTask
            let info = try await infoTask

            // Only overwrite isPlaying if no intent recently set it (prevents flicker).
            if Date() > SharedStorage.playStateLockUntil {
                SharedStorage.isPlaying = (state == .playing)
            }
            let isPlaying = SharedStorage.isPlaying
            SharedStorage.cachedTrackTitle = info.title
            SharedStorage.cachedArtist = info.artist
            SharedStorage.cachedAlbum = info.album
            SharedStorage.cachedAlbumArtURL = info.albumArtURL
            SharedStorage.cachedPlaybackSource = info.source.rawValue

            // Album art — extract dominant color if track changed.
            var artData = SharedStorage.albumArtData
            if let urlStr = info.albumArtURL, let url = URL(string: urlStr) {
                var req = URLRequest(url: url, timeoutInterval: 5)
                req.httpMethod = "GET"
                if let (data, _) = try? await noProxySession.data(for: req) {
                    artData = data
                    SharedStorage.albumArtData = data
                    if let uiImage = UIImage(data: data) {
                        SharedStorage.cachedDominantColorHex = uiImage.dominantColorHex()
                    }
                }
            }

            // Audio quality — try Cloud API if UPnP didn't provide codec info.
            var audioQualityLabel = info.audioQuality?.label ?? SharedStorage.cachedAudioQualityLabel
            if info.audioQuality == nil,
               let groupId = SharedStorage.cloudGroupId,
               let token = SharedStorage.cloudAccessToken,
               Date() < SharedStorage.cloudTokenExpiry {
                if let metadata = try? await SonosCloudAPI.getPlaybackMetadata(token: token, groupId: groupId),
                   let quality = metadata.currentItem?.track?.quality,
                   let mapped = AudioQuality.from(cloudQuality: quality) {
                    audioQualityLabel = mapped.label
                    SharedStorage.cachedAudioQualityLabel = mapped.label
                }
            }

            return SonosEntry(date: .now, trackTitle: info.title, artist: info.artist,
                              album: info.album, isPlaying: isPlaying,
                              albumArtData: artData, isConfigured: true,
                              speakerName: SharedStorage.speakerName,
                              groupMemberCount: SharedStorage.cachedGroupMemberCount,
                              playbackSource: info.source,
                              dominantColorHex: SharedStorage.cachedDominantColorHex,
                              audioQualityLabel: audioQualityLabel)
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
                        VStack(alignment: .leading, spacing: 2) {
                            if let name = entry.speakerName {
                                let extra = entry.groupMemberCount > 1
                                    ? " + \(entry.groupMemberCount - 1)" : ""
                                Text(entry.isPlaying
                                     ? "NOW PLAYING ON \(name.uppercased())\(extra)"
                                     : "CONTINUE ON \(name.uppercased())\(extra)")
                                    .font(.system(size: 8, weight: .semibold))
                                    .tracking(0.5)
                                    .foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(1)
                            }
                            if let quality = entry.audioQualityLabel {
                                HStack(alignment: .center, spacing: 4) {
                                    Text("IN")
                                        .font(.system(size: 7, weight: .bold))
                                        .tracking(0.8)
                                        .foregroundStyle(.white.opacity(0.3))
                                    if let badge = AudioQuality.badgeImageName(forQualityLabel: quality) {
                                        Image(badge)
                                            .resizable()
                                            .renderingMode(.template)
                                            .foregroundStyle(.white.opacity(0.45))
                                            .scaledToFit()
                                            .frame(height: 8)
                                            .accessibilityHidden(true)
                                    }
                                    Text(quality.uppercased())
                                        .font(.system(size: 7, weight: .bold))
                                        .tracking(0.8)
                                        .foregroundStyle(.white.opacity(0.3))
                                        .lineLimit(1)
                                }
                            }
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
