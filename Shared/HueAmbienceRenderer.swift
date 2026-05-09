import Foundation

struct HueResolvedAmbienceTarget: Equatable, Sendable {
    var areaID: String
    var lightIDs: [String]
    var lightsByID: [String: HueLightResource]
}

struct HueAmbienceRenderer {
    private let lightClient: HueLightUpdating

    init(lightClient: HueLightUpdating) {
        self.lightClient = lightClient
    }

    func apply(
        palette: [HueRGBColor],
        to targets: [HueResolvedAmbienceTarget],
        transitionSeconds: Double
    ) async throws {
        guard !palette.isEmpty else { return }

        var lightOffset = 0
        for target in targets {
            for lightID in target.lightIDs {
                guard let light = target.lightsByID[lightID], light.supportsColor else {
                    continue
                }

                let rotatedPalette = Self.rotated(palette, by: lightOffset)
                let body: [String: HueJSONValue]
                if light.supportsGradient, rotatedPalette.count > 1 {
                    body = Self.gradientBody(
                        palette: rotatedPalette,
                        transitionSeconds: transitionSeconds
                    )
                } else {
                    body = Self.colorBody(
                        color: rotatedPalette[0],
                        transitionSeconds: transitionSeconds
                    )
                }

                try await lightClient.updateLight(id: lightID, body: body)
                lightOffset += 1
            }
        }
    }

    private static func colorBody(
        color: HueRGBColor,
        transitionSeconds: Double
    ) -> [String: HueJSONValue] {
        [
            "on": .object(["on": .bool(true)]),
            "dimming": .object(["brightness": .number(color.brightness * 100)]),
            "color": colorJSON(color),
            "dynamics": .object(["duration": .number(transitionSeconds * 1_000)])
        ]
    }

    private static func gradientBody(
        palette: [HueRGBColor],
        transitionSeconds: Double
    ) -> [String: HueJSONValue] {
        let points = palette.prefix(5).map { color in
            HueJSONValue.object(["color": colorJSON(color)])
        }
        let maxBrightness = palette.map(\.brightness).max() ?? 0

        return [
            "on": .object(["on": .bool(true)]),
            "dimming": .object(["brightness": .number(maxBrightness * 100)]),
            "gradient": .object(["points": .array(points)]),
            "dynamics": .object(["duration": .number(transitionSeconds * 1_000)])
        ]
    }

    private static func colorJSON(_ color: HueRGBColor) -> HueJSONValue {
        let xy = color.xy
        return .object([
            "xy": .object([
                "x": .number(xy.x),
                "y": .number(xy.y)
            ])
        ])
    }

    private static func rotated(_ palette: [HueRGBColor], by offset: Int) -> [HueRGBColor] {
        guard !palette.isEmpty else { return [] }
        let shift = offset % palette.count
        return Array(palette[shift...] + palette[..<shift])
    }
}
