import XCTest
@testable import SonosWidget

final class HueAmbienceRendererTests: XCTestCase {
    func testRendererSendsGradientPointsForGradientLights() async throws {
        let client = RecordingHueLightClient()
        let renderer = HueAmbienceRenderer(lightClient: client)
        let target = HueResolvedAmbienceTarget(
            areaID: "ent-1",
            lightIDs: ["light-1"],
            lightsByID: [
                "light-1": makeLight(id: "light-1", supportsGradient: true, supportsEntertainment: true)
            ]
        )

        try await renderer.apply(
            palette: [.red, .green, .blue],
            to: [target],
            transitionSeconds: 4
        )

        let updates = await client.snapshot()
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.id, "light-1")
        XCTAssertNotNil(updates.first?.body["gradient"])
        XCTAssertEqual(updates.first?.body["dynamics"], .object(["duration": .number(4_000)]))
    }

    func testRendererSendsSingleColorForBasicLights() async throws {
        let client = RecordingHueLightClient()
        let renderer = HueAmbienceRenderer(lightClient: client)
        let target = HueResolvedAmbienceTarget(
            areaID: "room-1",
            lightIDs: ["light-1"],
            lightsByID: [
                "light-1": makeLight(id: "light-1", supportsGradient: false)
            ]
        )

        try await renderer.apply(
            palette: [.red],
            to: [target],
            transitionSeconds: 2
        )

        let updates = await client.snapshot()
        let body = try XCTUnwrap(updates.first?.body)
        XCTAssertNotNil(body["color"])
        XCTAssertNil(body["gradient"])
        XCTAssertEqual(body["dynamics"], .object(["duration": .number(2_000)]))
    }

    func testRendererSkipsNonColorLights() async throws {
        let client = RecordingHueLightClient()
        let renderer = HueAmbienceRenderer(lightClient: client)
        let target = HueResolvedAmbienceTarget(
            areaID: "room-1",
            lightIDs: ["light-1"],
            lightsByID: [
                "light-1": makeLight(id: "light-1", supportsColor: false)
            ]
        )

        try await renderer.apply(palette: [.red], to: [target], transitionSeconds: 1)

        let updates = await client.snapshot()
        XCTAssertEqual(updates.count, 0)
    }

    func testRendererCapsGradientPointsAtFive() async throws {
        let client = RecordingHueLightClient()
        let renderer = HueAmbienceRenderer(lightClient: client)
        let target = HueResolvedAmbienceTarget(
            areaID: "ent-1",
            lightIDs: ["light-1"],
            lightsByID: [
                "light-1": makeLight(id: "light-1", supportsGradient: true, supportsEntertainment: true)
            ]
        )

        try await renderer.apply(
            palette: [.red, .green, .blue, .yellow, .magenta, .cyan],
            to: [target],
            transitionSeconds: 1
        )

        let updates = await client.snapshot()
        let body = try XCTUnwrap(updates.first?.body)
        let gradient = try XCTUnwrap(body["gradient"])
        XCTAssertEqual(gradient.points?.count, 5)
    }

    func testRendererRotatesPalettesPerLight() async throws {
        let client = RecordingHueLightClient()
        let renderer = HueAmbienceRenderer(lightClient: client)
        let target = HueResolvedAmbienceTarget(
            areaID: "room-1",
            lightIDs: ["light-1", "light-2"],
            lightsByID: [
                "light-1": makeLight(id: "light-1"),
                "light-2": makeLight(id: "light-2")
            ]
        )

        try await renderer.apply(
            palette: [.red, .green],
            to: [target],
            transitionSeconds: 1
        )

        let updates = await client.snapshot()
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0].body["color"]?.xy, HueRGBColor.red.xy)
        XCTAssertEqual(updates[1].body["color"]?.xy, HueRGBColor.green.xy)
    }

    private func makeLight(
        id: String,
        supportsColor: Bool = true,
        supportsGradient: Bool = false,
        supportsEntertainment: Bool = false
    ) -> HueLightResource {
        HueLightResource(
            id: id,
            name: id,
            ownerID: nil,
            supportsColor: supportsColor,
            supportsGradient: supportsGradient,
            supportsEntertainment: supportsEntertainment
        )
    }
}

private actor RecordingHueLightClient: HueLightUpdating {
    private(set) var updates: [(id: String, body: [String: HueJSONValue])] = []

    func updateLight(id: String, body: [String: HueJSONValue]) async throws {
        updates.append((id: id, body: body))
    }

    func snapshot() -> [(id: String, body: [String: HueJSONValue])] {
        updates
    }
}

private extension HueRGBColor {
    static let red = HueRGBColor(r: 1, g: 0, b: 0)
    static let green = HueRGBColor(r: 0, g: 1, b: 0)
    static let blue = HueRGBColor(r: 0, g: 0, b: 1)
    static let yellow = HueRGBColor(r: 1, g: 1, b: 0)
    static let magenta = HueRGBColor(r: 1, g: 0, b: 1)
    static let cyan = HueRGBColor(r: 0, g: 1, b: 1)
}

private extension HueJSONValue {
    var xy: HueXYColor? {
        guard case .object(let color) = self,
              case .object(let xy) = color["xy"],
              case .number(let x) = xy["x"],
              case .number(let y) = xy["y"] else {
            return nil
        }

        return HueXYColor(x: x, y: y)
    }

    var points: [HueJSONValue]? {
        guard case .object(let gradient) = self,
              case .array(let points) = gradient["points"] else {
            return nil
        }

        return points
    }
}
