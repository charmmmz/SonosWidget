import SwiftUI

enum StreamingServiceBranding {
    /// Sonos Cloud API `service-id` (e.g. `"3079"` Spotify, `"52231"` Apple Music, `"51463"` Amazon per Sonos/SMAPI lists).
    /// When the id is unknown, `displayNameHint` can still match YouTube Music / Amazon from account names.
    static func brandAssetName(cloudServiceId: String, displayNameHint: String? = nil) -> String? {
        switch cloudServiceId {
        case "3079": return "BrandSpotify"
        case "52231": return "BrandAppleMusic"
        case "51463": return "BrandAmazonMusic"
        default:
            break
        }
        let hint = (displayNameHint ?? "").lowercased()
        if hint.contains("youtube") { return "BrandYouTubeMusic" }
        if hint.contains("amazon") { return "BrandAmazonMusic" }
        return nil
    }

    static func sfSymbolName(cloudServiceId: String, displayNameHint: String? = nil) -> String {
        switch cloudServiceId {
        case "3079": return "bolt.horizontal.circle.fill"
        case "52231": return "apple.logo"
        case "51463": return "cart.fill"
        case "42247": return "cloud.fill"
        case "49671": return "waveform.circle.fill"
        case "77575": return "antenna.radiowaves.left.and.right"
        default:
            break
        }
        let hint = (displayNameHint ?? "").lowercased()
        if hint.contains("youtube") { return "play.circle.fill" }
        if hint.contains("amazon") { return "cart.fill" }
        return "music.note"
    }
}

struct CloudServiceBrandMark: View {
    let cloudServiceId: String
    var displayNameHint: String? = nil
    var dimension: CGFloat = 14
    var symbolUsesTitle3: Bool = false
    /// Service tab chip uses a white background when selected — Amazon mark is white-on-white without a pad.
    var lightChromeBackdrop: Bool = false

    private var resolvedBrand: String? {
        StreamingServiceBranding.brandAssetName(cloudServiceId: cloudServiceId, displayNameHint: displayNameHint)
    }

    var body: some View {
        if let name = resolvedBrand {
            ZStack {
                if lightChromeBackdrop, name == "BrandAmazonMusic" {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.black.opacity(0.92))
                        .frame(width: dimension * 1.55, height: dimension * 1.2)
                }
                Image(name)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: dimension, height: dimension)
            }
        } else {
            Image(systemName: StreamingServiceBranding.sfSymbolName(cloudServiceId: cloudServiceId, displayNameHint: displayNameHint))
                .font(symbolUsesTitle3 ? .title3 : .caption)
        }
    }
}

struct FavoritesStreamingGlyph: View {
    let cloudServiceId: String?
    var displayNameHint: String? = nil
    var size: CGFloat = 10

    var body: some View {
        let effectiveId = cloudServiceId ?? ""
        if let name = StreamingServiceBranding.brandAssetName(cloudServiceId: effectiveId, displayNameHint: displayNameHint) {
            Image(name)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "music.note")
                .font(.system(size: size * 0.85))
                .foregroundStyle(.secondary)
        }
    }
}
