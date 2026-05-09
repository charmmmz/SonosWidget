import UIKit

struct HueXYColor: Equatable, Sendable {
    var x: Double
    var y: Double
}

struct HueRGBColor: Codable, Equatable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    var brightness: Double {
        max(r, g, b)
    }

    var xy: HueXYColor {
        let red = gammaCorrect(r)
        let green = gammaCorrect(g)
        let blue = gammaCorrect(b)

        let x = red * 0.664511 + green * 0.154324 + blue * 0.162028
        let y = red * 0.283881 + green * 0.668433 + blue * 0.047685
        let z = red * 0.000088 + green * 0.072310 + blue * 0.986039
        let total = x + y + z

        guard total > 0 else {
            return HueXYColor(x: 0, y: 0)
        }

        return HueXYColor(
            x: min(max(x / total, 0), 1),
            y: min(max(y / total, 0), 1)
        )
    }

    func gammaCorrect(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        if clamped > 0.04045 {
            return pow((clamped + 0.055) / 1.055, 2.4)
        }
        return clamped / 12.92
    }
}

enum AlbumPaletteExtractor {
    static func palette(from image: UIImage, maxColors: Int = 6) -> [HueRGBColor] {
        guard maxColors > 0 else { return [] }

        let sampledColors = image.sampledHueColors()
        var buckets: [ColorBucketKey: ColorBucket] = [:]

        for color in sampledColors where color.isUsefulAlbumColor {
            let key = ColorBucketKey(color)
            buckets[key, default: ColorBucket()].add(color)
        }

        var palette: [HueRGBColor] = []
        for bucket in buckets.values.sorted(by: { $0.score > $1.score }) {
            let color = bucket.averageColor
            guard !palette.contains(where: { $0.distance(to: color) < 0.28 }) else {
                continue
            }
            palette.append(color)
            if palette.count == maxColors {
                return palette
            }
        }

        if palette.isEmpty, let fallback = image.paletteFallbackColor {
            return [fallback]
        }

        return palette
    }
}

private struct ColorBucketKey: Hashable {
    let r: Int
    let g: Int
    let b: Int

    init(_ color: HueRGBColor) {
        r = Int((color.r * 5).rounded())
        g = Int((color.g * 5).rounded())
        b = Int((color.b * 5).rounded())
    }
}

private struct ColorBucket {
    private var rTotal: Double = 0
    private var gTotal: Double = 0
    private var bTotal: Double = 0
    private var count: Double = 0
    private var saturationTotal: Double = 0

    mutating func add(_ color: HueRGBColor) {
        rTotal += color.r
        gTotal += color.g
        bTotal += color.b
        saturationTotal += color.saturation
        count += 1
    }

    var averageColor: HueRGBColor {
        guard count > 0 else {
            return HueRGBColor(r: 0, g: 0, b: 0)
        }
        return HueRGBColor(r: rTotal / count, g: gTotal / count, b: bTotal / count)
    }

    var score: Double {
        count * max(saturationTotal / max(count, 1), 0.1) * max(averageColor.brightness, 0.1)
    }
}

private extension UIImage {
    func sampledHueColors() -> [HueRGBColor] {
        guard let cgImage else { return [] }

        let size = 24
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var raw = [UInt8](repeating: 0, count: size * size * 4)

        guard let context = CGContext(
            data: &raw,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return []
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var colors: [HueRGBColor] = []
        colors.reserveCapacity(size * size)

        for index in stride(from: 0, to: raw.count, by: 4) {
            let alpha = Double(raw[index + 3]) / 255.0
            guard alpha > 0.1 else { continue }

            colors.append(HueRGBColor(
                r: Double(raw[index]) / 255.0,
                g: Double(raw[index + 1]) / 255.0,
                b: Double(raw[index + 2]) / 255.0
            ))
        }

        return colors
    }

    var paletteFallbackColor: HueRGBColor? {
        guard let hex = dominantColorHex() else { return nil }
        return HueRGBColor(hex: hex)
    }
}

private extension HueRGBColor {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6, let rgb = UInt64(value, radix: 16) else {
            return nil
        }

        r = Double((rgb >> 16) & 0xFF) / 255.0
        g = Double((rgb >> 8) & 0xFF) / 255.0
        b = Double(rgb & 0xFF) / 255.0
    }

    var saturation: Double {
        let maxComponent = max(r, g, b)
        let minComponent = min(r, g, b)
        guard maxComponent > 0 else { return 0 }
        return (maxComponent - minComponent) / maxComponent
    }

    var isUsefulAlbumColor: Bool {
        brightness >= 0.14 && saturation >= 0.22
    }

    func distance(to color: HueRGBColor) -> Double {
        let rDelta = r - color.r
        let gDelta = g - color.g
        let bDelta = b - color.b
        return sqrt(rDelta * rDelta + gDelta * gDelta + bDelta * bDelta)
    }
}
