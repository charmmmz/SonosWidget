import SwiftUI

struct SourceBadgeView: View {
    let source: PlaybackSource
    var tintColor: Color?
    var compact: Bool = false

    private var resolvedColor: Color {
        tintColor ?? source.badgeColor
    }

    var body: some View {
        if source != .unknown {
            HStack(spacing: compact ? 0 : 3) {
                if let brand = source.brandAssetImageName {
                    Image(brand)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: compact ? 9 : 11, height: compact ? 9 : 11)
                } else {
                    Image(systemName: source.iconName)
                        .font(.system(size: compact ? 8 : 10, weight: .semibold))
                }
                if !compact {
                    Text(source.displayName)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, 3)
            .background(resolvedColor.opacity(0.85))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
    }
}
