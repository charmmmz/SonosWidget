import Foundation

struct HueResolvedAmbienceTarget: Equatable, Sendable {
    var areaID: String
    var lightIDs: [String]
    var lightsByID: [String: HueLightResource]
}

protocol HueAmbienceRendering {
    func apply(
        palette: [HueRGBColor],
        to targets: [HueResolvedAmbienceTarget],
        transitionSeconds: Double
    ) async throws
    func stop(targets: [HueResolvedAmbienceTarget], behavior: HueAmbienceStopBehavior) async throws
}

protocol HueTargetResolving {
    func resolveTargets(for mappings: [HueSonosMapping]) -> [HueResolvedAmbienceTarget]
}

struct StoredHueTargetResolver: HueTargetResolving {
    var areas: [HueAreaResource]
    var lights: [HueLightResource]

    func resolveTargets(for mappings: [HueSonosMapping]) -> [HueResolvedAmbienceTarget] {
        let lightsByID = Self.lightsByID(from: lights)
        var seenAreaIDs = Set<String>()

        return mappings.compactMap { mapping in
            for target in [mapping.preferredTarget, mapping.fallbackTarget].compactMap({ $0 }) {
                guard let area = area(for: target) else {
                    continue
                }

                let usesEntertainmentPolicy = target.usesEntertainmentAreaTargetPolicy
                let lightIDs = area.childLightIDs.filter { lightID in
                    guard let light = lightsByID[lightID], light.supportsColor else {
                        return false
                    }
                    guard Self.area(
                        area,
                        canUse: light,
                        mapping: mapping,
                        usesEntertainmentPolicy: usesEntertainmentPolicy
                    ) else {
                        return false
                    }
                    if usesEntertainmentPolicy {
                        return true
                    }
                    guard !mapping.excludedLightIDs.contains(lightID) else {
                        return false
                    }

                    return area.kind == .light
                        || light.participatesInAmbienceByDefault
                        || mapping.includedLightIDs.contains(lightID)
                }
                guard !lightIDs.isEmpty else {
                    return nil
                }
                guard seenAreaIDs.insert(area.id).inserted else {
                    return nil
                }

                return HueResolvedAmbienceTarget(
                    areaID: area.id,
                    lightIDs: lightIDs,
                    lightsByID: lightsByID
                )
            }

            return nil
        }
    }

    private static func area(
        _ area: HueAreaResource,
        canUse light: HueLightResource,
        mapping: HueSonosMapping,
        usesEntertainmentPolicy: Bool
    ) -> Bool {
        if usesEntertainmentPolicy {
            return true
        }

        if area.kind == .light || mapping.includedLightIDs.contains(light.id) {
            return true
        }

        guard !area.childDeviceIDs.isEmpty else {
            return light.ownerID == nil
        }

        guard let ownerID = light.ownerID else {
            return false
        }

        return area.childDeviceIDs.contains(ownerID)
    }

    private func area(for target: HueAmbienceTarget) -> HueAreaResource? {
        if case .light(let id) = target, let light = lights.first(where: { $0.id == id }) {
            return HueAreaResource(
                id: light.id,
                name: light.name,
                kind: .light,
                childLightIDs: [light.id],
                childDeviceIDs: light.ownerID.map { [$0] } ?? []
            )
        }

        return areas.first { area in
            area.id == target.id && area.kind.matches(target)
        } ?? areas.first { area in
            area.id == target.id
        }
    }

    private static func lightsByID(from lights: [HueLightResource]) -> [String: HueLightResource] {
        lights.reduce(into: [String: HueLightResource]()) { result, light in
            result[light.id] = light
        }
    }
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

    func stop(targets: [HueResolvedAmbienceTarget], behavior: HueAmbienceStopBehavior) async throws {
        guard behavior == .turnOff else {
            return
        }

        for target in targets {
            for lightID in target.lightIDs {
                guard let light = target.lightsByID[lightID], light.supportsColor else {
                    continue
                }

                try await lightClient.updateLight(
                    id: lightID,
                    body: [
                        "on": .object(["on": .bool(false)]),
                        "dynamics": .object(["duration": .number(1_200)])
                    ]
                )
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

extension HueAmbienceRenderer: HueAmbienceRendering {}

private extension HueAreaResource.Kind {
    func matches(_ target: HueAmbienceTarget) -> Bool {
        switch (self, target) {
        case (.entertainmentArea, .entertainmentArea),
             (.room, .room),
             (.zone, .zone),
             (.light, .light):
            return true
        default:
            return false
        }
    }
}
