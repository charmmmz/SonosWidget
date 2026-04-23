import SwiftUI

struct SourceBadgeView: View {
    let source: PlaybackSource
    /// Retained for API compatibility — previous capsule layout used this to tint the pill.
    /// Ignored in the current bare-mark layout; brand SVGs carry their own color.
    var tintColor: Color?
    var compact: Bool = false

    private var symbolColor: Color {
        tintColor ?? .white.opacity(0.9)
    }

    var body: some View {
        if source != .unknown {
            HStack(spacing: compact ? 0 : 4) {
                if let brand = source.brandAssetImageName {
                    Image(brand)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: compact ? 12 : 14, height: compact ? 12 : 14)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                } else {
                    Image(systemName: source.iconName)
                        .font(.system(size: compact ? 10 : 12, weight: .semibold))
                        .foregroundStyle(symbolColor)
                        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                }
                if !compact {
                    Text(source.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                }
            }
        }
    }
}
