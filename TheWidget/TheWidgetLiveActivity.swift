import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct SonosLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SonosActivityAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ArtView(data: context.state.albumArtThumbnail, size: 52)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.trackTitle)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(context.attributes.speakerName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(spacing: 6) {
                        Button(intent: PlayPauseIntent()) {
                            Image(systemName: context.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(themeColor(from: context.state.dominantColorHex))
                        }
                        .buttonStyle(.plain)
                        if context.state.isPlaying {
                            AnimatedWaveform(accent: themeColor(from: context.state.dominantColorHex),
                                            barCount: 3, height: 10)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        LiveProgressView(state: context.state)
                        HStack(spacing: 36) {
                            Button(intent: PreviousTrackIntent()) {
                                Image(systemName: "backward.fill").font(.body)
                            }.buttonStyle(.plain)

                            Button(intent: PlayPauseIntent()) {
                                Image(systemName: context.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(themeColor(from: context.state.dominantColorHex))
                            }.buttonStyle(.plain)

                            Button(intent: NextTrackIntent()) {
                                Image(systemName: "forward.fill").font(.body)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                // Compact/minimal views are static-only per Apple docs — no animation supported.
                ArtView(data: context.state.albumArtThumbnail, size: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } compactTrailing: {
                // Compact/minimal regions are static-only — no animation supported by Apple.
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: context.state.isPlaying ? 12 : 10, weight: .medium))
                    .foregroundStyle(themeColor(from: context.state.dominantColorHex))
                    .padding(.trailing, 4)
            } minimal: {
                ArtView(data: context.state.albumArtThumbnail, size: 20)
                    .clipShape(Circle())
            }
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let context: ActivityViewContext<SonosActivityAttributes>

    var body: some View {
        let accent = themeColor(from: context.state.dominantColorHex)

        ZStack {
            // ── Blurred album art background ──
            if let data = context.state.albumArtThumbnail,
               let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 40)
                    .scaleEffect(1.5)
                    .clipped()
            }
            // Dark overlay so text stays readable
            LinearGradient(
                colors: [.black.opacity(0.55), .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )

            // ── Content ──
            HStack(spacing: 14) {
                ArtView(data: context.state.albumArtThumbnail, size: 60)

                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.trackTitle)
                        .font(.subheadline.bold())
                        .lineLimit(1)

                    Text(context.state.artist)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("ON \(context.attributes.speakerName.uppercased())")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(accent.opacity(0.8))

                        if context.state.isPlaying {
                            AnimatedWaveform(accent: accent, barCount: 4, height: 8)
                        }
                    }
                    .padding(.top, 1)

                    LiveProgressView(state: context.state)
                        .padding(.top, 2)
                }

                Spacer(minLength: 0)

                HStack(spacing: 16) {
                    Button(intent: PreviousTrackIntent()) {
                        Image(systemName: "backward.fill").font(.callout)
                    }.buttonStyle(.plain)

                    Button(intent: PlayPauseIntent()) {
                        Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(accent)
                    }.buttonStyle(.plain)

                    Button(intent: NextTrackIntent()) {
                        Image(systemName: "forward.fill").font(.callout)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .activityBackgroundTint(.clear)
        .activitySystemActionForegroundColor(.white)
    }
}

// MARK: - Animated Waveform (lock screen + expanded DI only)
// Compact/minimal Dynamic Island does NOT support animation.
//
// SF Symbol system animations are driven by the OS renderer — the only reliable way
// to get continuous animation in a Live Activity extension process.

private struct AnimatedWaveform: View {
    let accent: Color
    var barCount: Int = 4
    var height: CGFloat = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    let h = 0.25 + 0.75 * abs(sin(t * 5.0 + Double(i) * 1.3))
                    Capsule()
                        .frame(width: 2, height: height * h)
                }
            }
            .frame(height: height)
            .foregroundStyle(accent)
        }
    }
}

// MARK: - Real-time Progress

private struct LiveProgressView: View {
    let state: SonosActivityAttributes.ContentState

    var body: some View {
        let accent = themeColor(from: state.dominantColorHex)

        if state.isPlaying,
           let start = state.startedAt,
           let end = state.endsAt,
           end > Date() {
            ProgressView(timerInterval: start...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(accent)
        } else if state.durationSeconds > 0 {
            ProgressView(value: state.positionSeconds, total: state.durationSeconds)
                .progressViewStyle(.linear)
                .tint(accent)
        }
    }
}

// MARK: - Album Art

private struct ArtView: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        if let data, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        } else {
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(Color.white.opacity(0.15))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.38))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

// MARK: - Helpers

private func themeColor(from hex: String?) -> Color {
    hex.flatMap { Color(hex: $0) } ?? .white
}
