import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct SonosLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SonosActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    liveArt(size: 48)
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
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: PlayPauseIntent()) {
                        Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.plain)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if context.state.durationSeconds > 0 {
                            ProgressView(value: context.state.positionSeconds,
                                         total: context.state.durationSeconds)
                            .tint(.white)
                        }
                        HStack(spacing: 32) {
                            Button(intent: PreviousTrackIntent()) {
                                Image(systemName: "backward.fill")
                            }.buttonStyle(.plain)
                            Button(intent: PlayPauseIntent()) {
                                Image(systemName: context.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.title2)
                            }.buttonStyle(.plain)
                            Button(intent: NextTrackIntent()) {
                                Image(systemName: "forward.fill")
                            }.buttonStyle(.plain)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Text(context.state.trackTitle)
                    .font(.caption2)
                    .lineLimit(1)
            } minimal: {
                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption2)
            }
        }
    }

    // MARK: - Lock Screen

    private func lockScreenView(context: ActivityViewContext<SonosActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            liveArt(size: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.trackTitle)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text("\(context.state.artist) — \(context.attributes.speakerName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if context.state.durationSeconds > 0 {
                    ProgressView(value: context.state.positionSeconds,
                                 total: context.state.durationSeconds)
                    .tint(.white)
                    .padding(.top, 2)
                }
            }

            Spacer()

            HStack(spacing: 14) {
                Button(intent: PreviousTrackIntent()) {
                    Image(systemName: "backward.fill")
                }.buttonStyle(.plain)
                Button(intent: PlayPauseIntent()) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }.buttonStyle(.plain)
                Button(intent: NextTrackIntent()) {
                    Image(systemName: "forward.fill")
                }.buttonStyle(.plain)
            }
        }
        .padding()
        .activityBackgroundTint(.black.opacity(0.65))
        .activitySystemActionForegroundColor(.white)
    }

    @ViewBuilder
    private func liveArt(size: CGFloat) -> some View {
        if let data = SharedStorage.albumArtData, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
        }
    }
}
