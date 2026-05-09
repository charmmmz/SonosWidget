# Music Ambience Hue Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first Music Ambience release: Hue Bridge pairing, Entertainment-first Sonos-to-Hue mappings, album-art palette ambience, app-only basic/gradient-ready light control, and clear NAS/Live Entertainment upgrade status.

**Architecture:** Keep Hue code out of `SonosManager` by adding focused shared models, a Hue client, a persisted store, a palette extractor, a renderer, and a `MusicAmbienceManager` that consumes narrow Sonos playback snapshots. Settings gets a guided setup sheet plus detail rows. True Hue Entertainment DTLS streaming is represented by an adapter/status boundary because this repo does not currently contain the Hue EDK or a DTLS dependency; the first release must not fake live streaming.

**Tech Stack:** Swift 6 / SwiftUI / Observation, XCTest, App Group `UserDefaults`, Keychain, Hue Bridge local HTTPS V2 API, Hue V1 pairing endpoint, existing `SonosManager` polling snapshots.

---

## References

- Approved design spec: `docs/superpowers/specs/2026-05-10-music-ambience-hue-sync-design.md`
- Hue getting started and pairing/discovery guidance: https://developers.meethue.com/develop/get-started-2/
- Hue V2 / Entertainment guidance: https://developers.meethue.com/new-hue-api/
- Existing app settings: `SonosWidget/SettingsView.swift`
- Existing shared storage pattern: `Shared/SharedStorage.swift`
- Existing Keychain pattern: `Shared/SonosAuth.swift`
- Existing album color extraction: `Shared/DominantColor.swift`

## File Structure

Create these files:

- `Shared/HueAmbienceModels.swift`: Codable Hue Bridge, resource, mapping, capability, group strategy, and Sonos snapshot models.
- `Shared/HueAmbienceStore.swift`: `@MainActor @Observable` persisted Music Ambience state, mapping CRUD, enable flags, and Bridge metadata.
- `Shared/HueCredentialStore.swift`: injectable Keychain wrapper for Hue application keys.
- `Shared/AlbumPaletteExtractor.swift`: multi-color album-art palette extraction plus RGB/XY helpers for Hue output.
- `Shared/HueBridgeClient.swift`: V1 pairing, V2 resource fetch, and light update client behind an injectable transport.
- `Shared/HueAmbienceRenderer.swift`: converts a palette and resolved Hue targets into basic REST updates, including gradient points where supported.
- `Shared/MusicAmbienceManager.swift`: Sonos snapshot lifecycle, mapping resolution, renderer orchestration, and user-visible sync status.
- `SonosWidget/MusicAmbienceSettingsView.swift`: guided setup sheet, Bridge status, mapping rows, group strategy, and fallback/NAS status UI.
- `SonosWidgetTests/HueAmbienceStoreTests.swift`
- `SonosWidgetTests/AlbumPaletteExtractorTests.swift`
- `SonosWidgetTests/HueBridgeClientTests.swift`
- `SonosWidgetTests/HueAmbienceRendererTests.swift`
- `SonosWidgetTests/MusicAmbienceManagerTests.swift`

Modify these files:

- `Shared/SharedStorage.swift`: add App Group keys for non-secret Hue state.
- `SonosWidget/SettingsView.swift`: add Hue Music Ambience section and sheet entry point.
- `SonosWidget/SonosManager.swift`: expose a narrow `musicAmbienceSnapshot()` and notify `MusicAmbienceManager` after state refreshes.
- `SonosWidget/ContentView.swift`: keep `MusicAmbienceManager.shared` lifecycle warm with the app.
- `SonosWidget/Info.plist`: add `_hue._tcp` to `NSBonjourServices` and update local-network usage copy to mention Hue Bridge.
- `SonosWidget.xcodeproj/project.pbxproj`: add new Shared files to the filesystem-synchronized exception lists for `TheWidgetExtension` and `SonosWidgetTests` unless a file is intentionally needed by those targets. Keep existing user changes.

---

### Task 1: Hue Models And Mapping Resolution Types

**Files:**
- Create: `Shared/HueAmbienceModels.swift`
- Test: `SonosWidgetTests/HueAmbienceStoreTests.swift`
- Modify: `SonosWidget.xcodeproj/project.pbxproj` exception lists for new Shared file

- [ ] **Step 1: Write the failing model/storage-shape tests**

Add `SonosWidgetTests/HueAmbienceStoreTests.swift`:

```swift
import XCTest
@testable import SonosWidget

final class HueAmbienceStoreTests: XCTestCase {
    func testMappingPrefersEntertainmentAreaAndKeepsFallback() throws {
        let mapping = HueSonosMapping(
            sonosID: "RINCON_living",
            sonosName: "Living Room",
            preferredTarget: .entertainmentArea("ent-1"),
            fallbackTarget: .room("room-1"),
            excludedLightIDs: ["light-2"],
            capability: .liveEntertainment
        )

        let data = try JSONEncoder().encode(mapping)
        let decoded = try JSONDecoder().decode(HueSonosMapping.self, from: data)

        XCTAssertEqual(decoded.sonosID, "RINCON_living")
        XCTAssertEqual(decoded.preferredTarget, .entertainmentArea("ent-1"))
        XCTAssertEqual(decoded.fallbackTarget, .room("room-1"))
        XCTAssertEqual(decoded.excludedLightIDs, ["light-2"])
        XCTAssertEqual(decoded.capability, .liveEntertainment)
    }

    func testGroupStrategyDefaultsToAllMappedRooms() {
        XCTAssertEqual(HueGroupSyncStrategy.default, .allMappedRooms)
    }

    func testStopBehaviorDefaultsToLeaveCurrent() {
        XCTAssertEqual(HueAmbienceStopBehavior.default, .leaveCurrent)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueAmbienceStoreTests
```

Expected: FAIL because `HueSonosMapping`, `HueAmbienceTarget`, `HueGroupSyncStrategy`, and `HueAmbienceStopBehavior` do not exist.

- [ ] **Step 3: Add the model file**

Create `Shared/HueAmbienceModels.swift`:

```swift
import Foundation

struct HueBridgeInfo: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var ipAddress: String
    var name: String

    var baseURL: URL? {
        URL(string: "https://\(ipAddress)")
    }
}

enum HueAmbienceTarget: Codable, Equatable, Hashable, Sendable {
    case entertainmentArea(String)
    case room(String)
    case zone(String)

    var id: String {
        switch self {
        case .entertainmentArea(let id), .room(let id), .zone(let id):
            return id
        }
    }

    var isEntertainmentArea: Bool {
        if case .entertainmentArea = self { return true }
        return false
    }
}

enum HueAmbienceCapability: String, Codable, Equatable, Sendable, CaseIterable {
    case basic
    case gradientReady
    case liveEntertainment

    var label: String {
        switch self {
        case .basic: return "Basic"
        case .gradientReady: return "Gradient Ready"
        case .liveEntertainment: return "Live Entertainment"
        }
    }
}

enum HueGroupSyncStrategy: String, Codable, Equatable, Sendable, CaseIterable {
    case allMappedRooms
    case coordinatorOnly

    static let `default`: HueGroupSyncStrategy = .allMappedRooms

    var label: String {
        switch self {
        case .allMappedRooms: return "All mapped rooms"
        case .coordinatorOnly: return "Coordinator only"
        }
    }
}

enum HueAmbienceStopBehavior: String, Codable, Equatable, Sendable, CaseIterable {
    case leaveCurrent
    case turnOff

    static let `default`: HueAmbienceStopBehavior = .leaveCurrent

    var label: String {
        switch self {
        case .leaveCurrent: return "Leave ambience"
        case .turnOff: return "Turn off synced lights"
        }
    }
}

struct HueSonosMapping: Codable, Equatable, Identifiable, Sendable {
    var id: String { sonosID }
    var sonosID: String
    var sonosName: String
    var preferredTarget: HueAmbienceTarget?
    var fallbackTarget: HueAmbienceTarget?
    var excludedLightIDs: Set<String>
    var capability: HueAmbienceCapability

    init(
        sonosID: String,
        sonosName: String,
        preferredTarget: HueAmbienceTarget? = nil,
        fallbackTarget: HueAmbienceTarget? = nil,
        excludedLightIDs: Set<String> = [],
        capability: HueAmbienceCapability = .basic
    ) {
        self.sonosID = sonosID
        self.sonosName = sonosName
        self.preferredTarget = preferredTarget
        self.fallbackTarget = fallbackTarget
        self.excludedLightIDs = excludedLightIDs
        self.capability = capability
    }
}

struct HueAmbiencePlaybackSnapshot: Equatable, Sendable {
    var selectedSonosID: String?
    var selectedSonosName: String?
    var groupMemberIDs: [String]
    var groupMemberNamesByID: [String: String]
    var trackTitle: String?
    var artist: String?
    var albumArtURL: String?
    var isPlaying: Bool
    var albumArtImage: Data?
}

struct HueLightResource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var ownerID: String?
    var supportsColor: Bool
    var supportsGradient: Bool
    var supportsEntertainment: Bool
}

struct HueAreaResource: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case entertainmentArea
        case room
        case zone
    }

    let id: String
    var name: String
    var kind: Kind
    var childLightIDs: [String]
}
```

- [ ] **Step 4: Keep new Shared file out of widget/test direct compilation**

Open `SonosWidget.xcodeproj/project.pbxproj` and add `HueAmbienceModels.swift` to:

```text
Exceptions for "Shared" folder in "TheWidgetExtension" target
Exceptions for "Shared" folder in "SonosWidgetTests" target
```

The app target still compiles the file through the synchronized Shared root group; tests access it through `@testable import SonosWidget`.

- [ ] **Step 5: Run test to verify it passes**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueAmbienceStoreTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Shared/HueAmbienceModels.swift SonosWidgetTests/HueAmbienceStoreTests.swift SonosWidget.xcodeproj/project.pbxproj
git commit -m "feat: add hue ambience mapping models"
```

---

### Task 2: Persist Music Ambience State

**Files:**
- Create: `Shared/HueAmbienceStore.swift`
- Modify: `Shared/SharedStorage.swift`
- Test: `SonosWidgetTests/HueAmbienceStoreTests.swift`
- Modify: `SonosWidget.xcodeproj/project.pbxproj` exception lists for new Shared file

- [ ] **Step 1: Add failing persistence tests**

Append to `HueAmbienceStoreTests`:

```swift
func testStorePersistsEnabledBridgeMappingsAndStrategy() {
    let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let storage = HueAmbienceDefaults(defaults: defaults)
    let store = HueAmbienceStore(storage: storage)

    store.isEnabled = true
    store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue")
    store.groupStrategy = .coordinatorOnly
    store.upsertMapping(HueSonosMapping(
        sonosID: "RINCON_kitchen",
        sonosName: "Kitchen",
        preferredTarget: .entertainmentArea("ent-kitchen"),
        fallbackTarget: .zone("zone-kitchen"),
        capability: .gradientReady
    ))

    let restored = HueAmbienceStore(storage: storage)

    XCTAssertTrue(restored.isEnabled)
    XCTAssertEqual(restored.bridge?.id, "bridge-1")
    XCTAssertEqual(restored.groupStrategy, .coordinatorOnly)
    XCTAssertEqual(restored.mapping(forSonosID: "RINCON_kitchen")?.preferredTarget, .entertainmentArea("ent-kitchen"))
}

func testRemovingBridgeClearsMappingsAndDisablesSync() {
    let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = HueAmbienceStore(storage: HueAmbienceDefaults(defaults: defaults))
    store.isEnabled = true
    store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue")
    store.upsertMapping(HueSonosMapping(sonosID: "RINCON_living", sonosName: "Living Room"))

    store.disconnectBridge()

    XCTAssertFalse(store.isEnabled)
    XCTAssertNil(store.bridge)
    XCTAssertTrue(store.mappings.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueAmbienceStoreTests
```

Expected: FAIL because `HueAmbienceStore` and `HueAmbienceDefaults` do not exist.

- [ ] **Step 3: Add App Group storage helpers**

Modify `Shared/SharedStorage.swift` after `agentTokenString`:

```swift
    // MARK: - Hue Music Ambience

    nonisolated static var hueAmbienceEnabled: Bool {
        get { defaults.bool(forKey: "hueAmbienceEnabled") }
        set { defaults.set(newValue, forKey: "hueAmbienceEnabled") }
    }

    nonisolated static var hueBridgeData: Data? {
        get { defaults.data(forKey: "hueBridgeData") }
        set { defaults.set(newValue, forKey: "hueBridgeData") }
    }

    nonisolated static var hueMappingsData: Data? {
        get { defaults.data(forKey: "hueMappingsData") }
        set { defaults.set(newValue, forKey: "hueMappingsData") }
    }

    nonisolated static var hueGroupStrategyRaw: String? {
        get { defaults.string(forKey: "hueGroupStrategy") }
        set { defaults.set(newValue, forKey: "hueGroupStrategy") }
    }

    nonisolated static var hueLastStatusText: String? {
        get { defaults.string(forKey: "hueLastStatusText") }
        set { defaults.set(newValue, forKey: "hueLastStatusText") }
    }
```

- [ ] **Step 4: Add the store**

Create `Shared/HueAmbienceStore.swift`:

```swift
import Foundation
import Observation

protocol HueAmbienceStorage: AnyObject {
    var enabled: Bool { get set }
    var bridgeData: Data? { get set }
    var mappingsData: Data? { get set }
    var groupStrategyRaw: String? { get set }
    var statusText: String? { get set }
}

final class HueAmbienceDefaults: HueAmbienceStorage {
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    var enabled: Bool {
        get { defaults?.bool(forKey: "hueAmbienceEnabled") ?? SharedStorage.hueAmbienceEnabled }
        set {
            if let defaults { defaults.set(newValue, forKey: "hueAmbienceEnabled") }
            else { SharedStorage.hueAmbienceEnabled = newValue }
        }
    }

    var bridgeData: Data? {
        get { defaults?.data(forKey: "hueBridgeData") ?? SharedStorage.hueBridgeData }
        set {
            if let defaults { defaults.set(newValue, forKey: "hueBridgeData") }
            else { SharedStorage.hueBridgeData = newValue }
        }
    }

    var mappingsData: Data? {
        get { defaults?.data(forKey: "hueMappingsData") ?? SharedStorage.hueMappingsData }
        set {
            if let defaults { defaults.set(newValue, forKey: "hueMappingsData") }
            else { SharedStorage.hueMappingsData = newValue }
        }
    }

    var groupStrategyRaw: String? {
        get { defaults?.string(forKey: "hueGroupStrategy") ?? SharedStorage.hueGroupStrategyRaw }
        set {
            if let defaults { defaults.set(newValue, forKey: "hueGroupStrategy") }
            else { SharedStorage.hueGroupStrategyRaw = newValue }
        }
    }

    var statusText: String? {
        get { defaults?.string(forKey: "hueLastStatusText") ?? SharedStorage.hueLastStatusText }
        set {
            if let defaults { defaults.set(newValue, forKey: "hueLastStatusText") }
            else { SharedStorage.hueLastStatusText = newValue }
        }
    }
}

@MainActor
@Observable
final class HueAmbienceStore {
    static let shared = HueAmbienceStore()

    var isEnabled: Bool { didSet { storage.enabled = isEnabled } }
    var bridge: HueBridgeInfo? { didSet { persistBridge() } }
    var mappings: [HueSonosMapping] { didSet { persistMappings() } }
    var groupStrategy: HueGroupSyncStrategy { didSet { storage.groupStrategyRaw = groupStrategy.rawValue } }
    var statusText: String? { didSet { storage.statusText = statusText } }

    @ObservationIgnored private let storage: HueAmbienceStorage
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    init(storage: HueAmbienceStorage = HueAmbienceDefaults()) {
        self.storage = storage
        self.isEnabled = storage.enabled
        self.bridge = storage.bridgeData.flatMap { try? decoder.decode(HueBridgeInfo.self, from: $0) }
        self.mappings = storage.mappingsData.flatMap { try? decoder.decode([HueSonosMapping].self, from: $0) } ?? []
        self.groupStrategy = storage.groupStrategyRaw.flatMap(HueGroupSyncStrategy.init(rawValue:)) ?? .default
        self.statusText = storage.statusText
    }

    func mapping(forSonosID sonosID: String) -> HueSonosMapping? {
        mappings.first { $0.sonosID == sonosID }
    }

    func upsertMapping(_ mapping: HueSonosMapping) {
        if let index = mappings.firstIndex(where: { $0.sonosID == mapping.sonosID }) {
            mappings[index] = mapping
        } else {
            mappings.append(mapping)
        }
    }

    func removeMapping(forSonosID sonosID: String) {
        mappings.removeAll { $0.sonosID == sonosID }
    }

    func disconnectBridge() {
        isEnabled = false
        bridge = nil
        mappings = []
        statusText = nil
    }

    private func persistBridge() {
        storage.bridgeData = bridge.flatMap { try? encoder.encode($0) }
    }

    private func persistMappings() {
        storage.mappingsData = try? encoder.encode(mappings)
    }
}
```

- [ ] **Step 5: Update project exceptions**

Add `HueAmbienceStore.swift` to Shared exceptions for `TheWidgetExtension` and `SonosWidgetTests`.

- [ ] **Step 6: Run tests to verify pass**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueAmbienceStoreTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Shared/SharedStorage.swift Shared/HueAmbienceStore.swift SonosWidgetTests/HueAmbienceStoreTests.swift SonosWidget.xcodeproj/project.pbxproj
git commit -m "feat: persist hue ambience settings"
```

---

### Task 3: Album Palette Extraction

**Files:**
- Create: `Shared/AlbumPaletteExtractor.swift`
- Test: `SonosWidgetTests/AlbumPaletteExtractorTests.swift`
- Modify: `SonosWidget.xcodeproj/project.pbxproj` exception lists for new Shared file

- [ ] **Step 1: Write failing palette tests**

Create `SonosWidgetTests/AlbumPaletteExtractorTests.swift`:

```swift
import XCTest
import UIKit
@testable import SonosWidget

final class AlbumPaletteExtractorTests: XCTestCase {
    func testExtractsMultipleDistinctColorsFromStripedArtwork() throws {
        let image = makeStripedImage(colors: [.red, .green, .blue, .yellow], size: CGSize(width: 80, height: 40))

        let palette = AlbumPaletteExtractor.palette(from: image, maxColors: 4)

        XCTAssertEqual(palette.count, 4)
        XCTAssertTrue(palette.contains { $0.r > 0.8 && $0.g < 0.3 && $0.b < 0.3 })
        XCTAssertTrue(palette.contains { $0.g > 0.6 && $0.r < 0.4 && $0.b < 0.4 })
        XCTAssertTrue(palette.contains { $0.b > 0.6 && $0.r < 0.4 && $0.g < 0.4 })
    }

    func testHueXYConversionKeepsValuesInsideBridgeRange() {
        let xy = HueRGBColor(r: 1, g: 0.2, b: 0.1).xy

        XCTAssertGreaterThanOrEqual(xy.x, 0)
        XCTAssertLessThanOrEqual(xy.x, 1)
        XCTAssertGreaterThanOrEqual(xy.y, 0)
        XCTAssertLessThanOrEqual(xy.y, 1)
    }

    private func makeStripedImage(colors: [UIColor], size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let stripeWidth = size.width / CGFloat(colors.count)
            for (index, color) in colors.enumerated() {
                color.setFill()
                context.fill(CGRect(x: CGFloat(index) * stripeWidth, y: 0, width: stripeWidth, height: size.height))
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/AlbumPaletteExtractorTests
```

Expected: FAIL because `AlbumPaletteExtractor` and `HueRGBColor` do not exist.

- [ ] **Step 3: Add palette extractor**

Create `Shared/AlbumPaletteExtractor.swift`:

```swift
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
        max(0.05, min(1.0, max(r, max(g, b))))
    }

    var xy: HueXYColor {
        let red = gammaCorrect(r)
        let green = gammaCorrect(g)
        let blue = gammaCorrect(b)

        let x = red * 0.664511 + green * 0.154324 + blue * 0.162028
        let y = red * 0.283881 + green * 0.668433 + blue * 0.047685
        let z = red * 0.000088 + green * 0.072310 + blue * 0.986039
        let total = x + y + z
        guard total > 0 else { return HueXYColor(x: 0.3227, y: 0.3290) }
        return HueXYColor(x: min(max(x / total, 0), 1), y: min(max(y / total, 0), 1))
    }

    private func gammaCorrect(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        if clamped > 0.04045 {
            return pow((clamped + 0.055) / 1.055, 2.4)
        }
        return clamped / 12.92
    }
}

enum AlbumPaletteExtractor {
    static func palette(from image: UIImage, maxColors: Int = 6) -> [HueRGBColor] {
        guard maxColors > 0,
              let cgImage = image.cgImage else { return [] }

        let sampleSize = 24
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var raw = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        guard let context = CGContext(
            data: &raw,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        var buckets: [String: (color: HueRGBColor, count: Int, score: Double)] = [:]
        for offset in stride(from: 0, to: raw.count, by: 4) {
            let r = Double(raw[offset]) / 255.0
            let g = Double(raw[offset + 1]) / 255.0
            let b = Double(raw[offset + 2]) / 255.0
            let maxChannel = max(r, max(g, b))
            let minChannel = min(r, min(g, b))
            let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
            let brightness = maxChannel
            guard brightness > 0.08, brightness < 0.98, saturation > 0.08 else { continue }

            let rq = Int((r * 5).rounded())
            let gq = Int((g * 5).rounded())
            let bq = Int((b * 5).rounded())
            let key = "\(rq)-\(gq)-\(bq)"
            let color = HueRGBColor(r: r, g: g, b: b)
            let score = saturation * 2.0 + brightness

            if let existing = buckets[key] {
                let count = existing.count + 1
                let averaged = HueRGBColor(
                    r: (existing.color.r * Double(existing.count) + r) / Double(count),
                    g: (existing.color.g * Double(existing.count) + g) / Double(count),
                    b: (existing.color.b * Double(existing.count) + b) / Double(count)
                )
                buckets[key] = (averaged, count, existing.score + score)
            } else {
                buckets[key] = (color, 1, score)
            }
        }

        let sorted = buckets.values.sorted { lhs, rhs in
            (lhs.score * Double(lhs.count)) > (rhs.score * Double(rhs.count))
        }

        var result: [HueRGBColor] = []
        for bucket in sorted {
            guard result.allSatisfy({ distance($0, bucket.color) > 0.22 }) else { continue }
            result.append(bucket.color)
            if result.count == maxColors { break }
        }

        if result.isEmpty, let fallback = image.dominantRGBForAmbience() {
            return [fallback]
        }
        return result
    }

    private static func distance(_ lhs: HueRGBColor, _ rhs: HueRGBColor) -> Double {
        let dr = lhs.r - rhs.r
        let dg = lhs.g - rhs.g
        let db = lhs.b - rhs.b
        return sqrt(dr * dr + dg * dg + db * db)
    }
}

private extension UIImage {
    func dominantRGBForAmbience() -> HueRGBColor? {
        guard let hex = dominantColorHex() else { return nil }
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let raw = UInt64(value, radix: 16) else { return nil }
        return HueRGBColor(
            r: Double((raw >> 16) & 0xFF) / 255.0,
            g: Double((raw >> 8) & 0xFF) / 255.0,
            b: Double(raw & 0xFF) / 255.0
        )
    }
}
```

- [ ] **Step 4: Update project exceptions**

Add `AlbumPaletteExtractor.swift` to Shared exceptions for `TheWidgetExtension` and `SonosWidgetTests`.

- [ ] **Step 5: Run tests to verify pass**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/AlbumPaletteExtractorTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Shared/AlbumPaletteExtractor.swift SonosWidgetTests/AlbumPaletteExtractorTests.swift SonosWidget.xcodeproj/project.pbxproj
git commit -m "feat: extract music ambience palettes"
```

---

### Task 4: Hue Credentials

**Files:**
- Create: `Shared/HueCredentialStore.swift`
- Test: `SonosWidgetTests/HueBridgeClientTests.swift`
- Modify: `SonosWidget.xcodeproj/project.pbxproj` exception lists for new Shared file

- [ ] **Step 1: Write failing credential tests**

Create `SonosWidgetTests/HueBridgeClientTests.swift`:

```swift
import XCTest
@testable import SonosWidget

final class HueBridgeClientTests: XCTestCase {
    func testCredentialStoreSavesReadsAndDeletesApplicationKey() {
        let storage = InMemoryHueCredentialStorage()
        let store = HueCredentialStore(storage: storage)

        store.saveApplicationKey("app-key-1", forBridgeID: "bridge-1")

        XCTAssertEqual(store.applicationKey(forBridgeID: "bridge-1"), "app-key-1")

        store.deleteApplicationKey(forBridgeID: "bridge-1")

        XCTAssertNil(store.applicationKey(forBridgeID: "bridge-1"))
    }
}

private final class InMemoryHueCredentialStorage: HueCredentialStorage {
    var values: [String: String] = [:]

    func save(_ value: String, account: String) {
        values[account] = value
    }

    func read(account: String) -> String? {
        values[account]
    }

    func delete(account: String) {
        values.removeValue(forKey: account)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueBridgeClientTests/testCredentialStoreSavesReadsAndDeletesApplicationKey
```

Expected: FAIL because `HueCredentialStore` and `HueCredentialStorage` do not exist.

- [ ] **Step 3: Add Keychain-backed credential store**

Create `Shared/HueCredentialStore.swift`:

```swift
import Foundation
import Security

protocol HueCredentialStorage {
    func save(_ value: String, account: String)
    func read(account: String) -> String?
    func delete(account: String)
}

struct KeychainHueCredentialStorage: HueCredentialStorage {
    func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.charm.SonosWidget.hue",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.charm.SonosWidget.hue",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.charm.SonosWidget.hue",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct HueCredentialStore {
    private let storage: HueCredentialStorage

    init(storage: HueCredentialStorage = KeychainHueCredentialStorage()) {
        self.storage = storage
    }

    func saveApplicationKey(_ key: String, forBridgeID bridgeID: String) {
        storage.save(key, account: account(forBridgeID: bridgeID))
    }

    func applicationKey(forBridgeID bridgeID: String) -> String? {
        storage.read(account: account(forBridgeID: bridgeID))
    }

    func deleteApplicationKey(forBridgeID bridgeID: String) {
        storage.delete(account: account(forBridgeID: bridgeID))
    }

    private func account(forBridgeID bridgeID: String) -> String {
        "hue.applicationKey.\(bridgeID)"
    }
}
```

- [ ] **Step 4: Update project exceptions**

Add `HueCredentialStore.swift` to Shared exceptions for `TheWidgetExtension` and `SonosWidgetTests`.

- [ ] **Step 5: Run test to verify pass**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueBridgeClientTests/testCredentialStoreSavesReadsAndDeletesApplicationKey
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Shared/HueCredentialStore.swift SonosWidgetTests/HueBridgeClientTests.swift SonosWidget.xcodeproj/project.pbxproj
git commit -m "feat: store hue bridge credentials"
```

---

### Task 5: Hue Bridge Client Pairing And Resource Fetch

**Files:**
- Create: `Shared/HueBridgeClient.swift`
- Test: `SonosWidgetTests/HueBridgeClientTests.swift`
- Modify: `SonosWidget.xcodeproj/project.pbxproj` exception lists for new Shared file

- [ ] **Step 1: Add failing client tests**

Append to `HueBridgeClientTests`:

```swift
func testPairBridgeStoresApplicationKeyFromLinkButtonResponse() async throws {
    let transport = MockHueTransport()
    transport.responses[MockHueTransport.Key(method: "POST", path: "/api")] = Data("""
    [
      { "success": { "username": "generated-key" } }
    ]
    """.utf8)
    let credentials = InMemoryHueCredentialStorage()
    let client = HueBridgeClient(
        bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
        credentialStore: HueCredentialStore(storage: credentials),
        transport: transport
    )

    let key = try await client.pairBridge(deviceType: "Charm Player#iPhone")

    XCTAssertEqual(key, "generated-key")
    XCTAssertEqual(credentials.values["hue.applicationKey.bridge-1"], "generated-key")
}

func testFetchResourcesDecodesEntertainmentAreasRoomsZonesAndLights() async throws {
    let transport = MockHueTransport()
    transport.responses[MockHueTransport.Key(method: "GET", path: "/clip/v2/resource/light")] = Data("""
    {
      "data": [
        {
          "id": "light-1",
          "metadata": { "name": "Gradient Strip" },
          "owner": { "rid": "room-1" },
          "color": {},
          "gradient": { "points_capable": 5 },
          "mode": "normal"
        }
      ],
      "errors": []
    }
    """.utf8)
    transport.responses[MockHueTransport.Key(method: "GET", path: "/clip/v2/resource/room")] = Data("""
    { "data": [ { "id": "room-1", "metadata": { "name": "Living Room" }, "children": [ { "rid": "light-1", "rtype": "light" } ] } ], "errors": [] }
    """.utf8)
    transport.responses[MockHueTransport.Key(method: "GET", path: "/clip/v2/resource/zone")] = Data("""{ "data": [], "errors": [] }""".utf8)
    transport.responses[MockHueTransport.Key(method: "GET", path: "/clip/v2/resource/entertainment_configuration")] = Data("""
    { "data": [ { "id": "ent-1", "metadata": { "name": "Living Sync" }, "channels": [ { "members": [ { "service": { "rid": "light-1", "rtype": "light" } } ] } ] } ], "errors": [] }
    """.utf8)

    let client = HueBridgeClient(
        bridge: HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue"),
        credentialStore: HueCredentialStore(storage: InMemoryHueCredentialStorage()),
        transport: transport,
        applicationKeyProvider: { "generated-key" }
    )

    let resources = try await client.fetchResources()

    XCTAssertEqual(resources.lights.first?.supportsGradient, true)
    XCTAssertEqual(resources.areas.first(where: { $0.kind == .entertainmentArea })?.childLightIDs, ["light-1"])
}

private final class MockHueTransport: HueBridgeTransport {
    struct Key: Hashable {
        var method: String
        var path: String
    }

    var responses: [Key: Data] = [:]
    var requests: [HueBridgeRequest] = []

    func send(_ request: HueBridgeRequest) async throws -> Data {
        requests.append(request)
        let key = Key(method: request.method, path: request.path)
        guard let data = responses[key] else {
            throw HueBridgeError.httpStatus(404)
        }
        return data
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueBridgeClientTests
```

Expected: FAIL because `HueBridgeClient`, `HueBridgeTransport`, and related types do not exist.

- [ ] **Step 3: Add the Hue Bridge client**

Create `Shared/HueBridgeClient.swift`:

```swift
import Foundation

struct HueBridgeRequest: Equatable, Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data?
}

protocol HueBridgeTransport: AnyObject {
    func send(_ request: HueBridgeRequest) async throws -> Data
}

enum HueBridgeError: Error, LocalizedError, Equatable {
    case bridgeURLUnavailable
    case linkButtonNotPressed
    case missingApplicationKey
    case httpStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .bridgeURLUnavailable: return "Hue Bridge address is unavailable."
        case .linkButtonNotPressed: return "Press the Hue Bridge link button, then try again."
        case .missingApplicationKey: return "Hue Bridge is not paired."
        case .httpStatus(let code): return "Hue Bridge returned HTTP \(code)."
        case .emptyResponse: return "Hue Bridge returned an empty response."
        }
    }
}

final class URLSessionHueBridgeTransport: NSObject, HueBridgeTransport, URLSessionDelegate {
    private let baseURL: URL
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 12
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func send(_ request: HueBridgeRequest) async throws -> Data {
        let url = baseURL.appending(path: request.path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body
        let (data, response) = try await session.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HueBridgeError.httpStatus(http.statusCode)
        }
        return data
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

struct HueBridgeResources: Equatable, Sendable {
    var lights: [HueLightResource]
    var areas: [HueAreaResource]
}

struct HueBridgeClient {
    private let bridge: HueBridgeInfo
    private let credentialStore: HueCredentialStore
    private let transport: HueBridgeTransport
    private let applicationKeyProvider: () -> String?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        bridge: HueBridgeInfo,
        credentialStore: HueCredentialStore = HueCredentialStore(),
        transport: HueBridgeTransport? = nil,
        applicationKeyProvider: (() -> String?)? = nil
    ) {
        self.bridge = bridge
        self.credentialStore = credentialStore
        let resolvedTransport: HueBridgeTransport
        if let transport {
            resolvedTransport = transport
        } else {
            resolvedTransport = URLSessionHueBridgeTransport(baseURL: bridge.baseURL ?? URL(string: "https://0.0.0.0")!)
        }
        self.transport = resolvedTransport
        self.applicationKeyProvider = applicationKeyProvider ?? {
            credentialStore.applicationKey(forBridgeID: bridge.id)
        }
    }

    func pairBridge(deviceType: String) async throws -> String {
        let body = try encoder.encode(["devicetype": deviceType])
        let data = try await transport.send(HueBridgeRequest(
            method: "POST",
            path: "/api",
            headers: ["Content-Type": "application/json"],
            body: body
        ))
        let entries = try decoder.decode([HuePairingEntry].self, from: data)
        if entries.contains(where: { $0.error?.type == 101 }) {
            throw HueBridgeError.linkButtonNotPressed
        }
        guard let username = entries.compactMap(\.success?.username).first else {
            throw HueBridgeError.emptyResponse
        }
        credentialStore.saveApplicationKey(username, forBridgeID: bridge.id)
        return username
    }

    func fetchResources() async throws -> HueBridgeResources {
        async let lights = fetchLights()
        async let rooms = fetchAreas(path: "/clip/v2/resource/room", kind: HueAreaResource.Kind.room)
        async let zones = fetchAreas(path: "/clip/v2/resource/zone", kind: HueAreaResource.Kind.zone)
        async let entertainment = fetchEntertainmentAreas()
        return try await HueBridgeResources(
            lights: lights,
            areas: entertainment + rooms + zones
        )
    }

    func updateLight(id: String, body: [String: HueJSONValue]) async throws {
        let data = try JSONSerialization.data(withJSONObject: body.mapValues(\.value), options: [])
        _ = try await authenticated("PUT", path: "/clip/v2/resource/light/\(id)", body: data)
    }

    private func fetchLights() async throws -> [HueLightResource] {
        let data = try await authenticated("GET", path: "/clip/v2/resource/light")
        let envelope = try decoder.decode(HueEnvelope<[HueLightDTO]>.self, from: data)
        return envelope.data.map {
            HueLightResource(
                id: $0.id,
                name: $0.metadata?.name ?? $0.id,
                ownerID: $0.owner?.rid,
                supportsColor: $0.color != nil,
                supportsGradient: ($0.gradient?.pointsCapable ?? 0) > 1,
                supportsEntertainment: true
            )
        }
    }

    private func fetchAreas(path: String, kind: HueAreaResource.Kind) async throws -> [HueAreaResource] {
        let data = try await authenticated("GET", path: path)
        let envelope = try decoder.decode(HueEnvelope<[HueAreaDTO]>.self, from: data)
        return envelope.data.map {
            HueAreaResource(
                id: $0.id,
                name: $0.metadata?.name ?? $0.id,
                kind: kind,
                childLightIDs: $0.children?.filter { $0.rtype == "light" }.map(\.rid) ?? []
            )
        }
    }

    private func fetchEntertainmentAreas() async throws -> [HueAreaResource] {
        let data = try await authenticated("GET", path: "/clip/v2/resource/entertainment_configuration")
        let envelope = try decoder.decode(HueEnvelope<[HueEntertainmentDTO]>.self, from: data)
        return envelope.data.map { config in
            let lightIDs = config.channels.flatMap { channel in
                channel.members.compactMap { member in
                    member.service.rtype == "light" ? member.service.rid : nil
                }
            }
            var seen = Set<String>()
            return HueAreaResource(
                id: config.id,
                name: config.metadata?.name ?? config.id,
                kind: .entertainmentArea,
                childLightIDs: lightIDs.filter { seen.insert($0).inserted }
            )
        }
    }

    private func authenticated(_ method: String, path: String, body: Data? = nil) async throws -> Data {
        guard let key = applicationKeyProvider() else {
            throw HueBridgeError.missingApplicationKey
        }
        return try await transport.send(HueBridgeRequest(
            method: method,
            path: path,
            headers: [
                "Content-Type": "application/json",
                "hue-application-key": key
            ],
            body: body
        ))
    }
}

enum HueJSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([HueJSONValue])
    case object([String: HueJSONValue])

    var value: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .array(let values): return values.map(\.value)
        case .object(let values): return values.mapValues(\.value)
        }
    }
}

private struct HuePairingEntry: Decodable {
    struct Success: Decodable { let username: String }
    struct Failure: Decodable { let type: Int }
    let success: Success?
    let error: Failure?
}

private struct HueEnvelope<T: Decodable>: Decodable {
    let data: T
}

private struct HueMetadataDTO: Decodable {
    let name: String?
}

private struct HueOwnerDTO: Decodable {
    let rid: String
}

private struct HueChildDTO: Decodable {
    let rid: String
    let rtype: String
}

private struct HueGradientDTO: Decodable {
    let pointsCapable: Int?

    enum CodingKeys: String, CodingKey {
        case pointsCapable = "points_capable"
    }
}

private struct HueLightDTO: Decodable {
    let id: String
    let metadata: HueMetadataDTO?
    let owner: HueOwnerDTO?
    let color: [String: String]?
    let gradient: HueGradientDTO?
}

private struct HueAreaDTO: Decodable {
    let id: String
    let metadata: HueMetadataDTO?
    let children: [HueChildDTO]?
}

private struct HueEntertainmentDTO: Decodable {
    struct Channel: Decodable {
        struct Member: Decodable {
            let service: HueChildDTO
        }

        let members: [Member]
    }

    let id: String
    let metadata: HueMetadataDTO?
    let channels: [Channel]
}
```

- [ ] **Step 4: Update project exceptions**

Add `HueBridgeClient.swift` to Shared exceptions for `TheWidgetExtension` and `SonosWidgetTests`.

- [ ] **Step 5: Run tests to verify pass**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueBridgeClientTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Shared/HueBridgeClient.swift SonosWidgetTests/HueBridgeClientTests.swift SonosWidget.xcodeproj/project.pbxproj
git commit -m "feat: add hue bridge client"
```

---

### Task 6: Basic And Gradient-Ready REST Renderer

**Files:**
- Create: `Shared/HueAmbienceRenderer.swift`
- Test: `SonosWidgetTests/HueAmbienceRendererTests.swift`
- Modify: `SonosWidget.xcodeproj/project.pbxproj` exception lists for new Shared file

- [ ] **Step 1: Write failing renderer tests**

Create `SonosWidgetTests/HueAmbienceRendererTests.swift`:

```swift
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
                "light-1": HueLightResource(
                    id: "light-1",
                    name: "Gradient Strip",
                    ownerID: nil,
                    supportsColor: true,
                    supportsGradient: true,
                    supportsEntertainment: true
                )
            ]
        )

        try await renderer.apply(
            palette: [
                HueRGBColor(r: 1, g: 0, b: 0),
                HueRGBColor(r: 0, g: 1, b: 0),
                HueRGBColor(r: 0, g: 0, b: 1)
            ],
            to: [target],
            transitionSeconds: 4
        )

        XCTAssertEqual(client.updates.count, 1)
        XCTAssertNotNil(client.updates[0].body["gradient"])
    }

    func testRendererSendsSingleColorForBasicLights() async throws {
        let client = RecordingHueLightClient()
        let renderer = HueAmbienceRenderer(lightClient: client)
        let target = HueResolvedAmbienceTarget(
            areaID: "room-1",
            lightIDs: ["light-1"],
            lightsByID: [
                "light-1": HueLightResource(
                    id: "light-1",
                    name: "Table Lamp",
                    ownerID: nil,
                    supportsColor: true,
                    supportsGradient: false,
                    supportsEntertainment: false
                )
            ]
        )

        try await renderer.apply(
            palette: [HueRGBColor(r: 1, g: 0.2, b: 0.1)],
            to: [target],
            transitionSeconds: 4
        )

        XCTAssertEqual(client.updates.count, 1)
        XCTAssertNotNil(client.updates[0].body["color"])
        XCTAssertNil(client.updates[0].body["gradient"])
    }
}

private final class RecordingHueLightClient: HueLightUpdating {
    struct Update {
        var id: String
        var body: [String: HueJSONValue]
    }

    var updates: [Update] = []

    func updateLight(id: String, body: [String: HueJSONValue]) async throws {
        updates.append(Update(id: id, body: body))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueAmbienceRendererTests
```

Expected: FAIL because renderer types do not exist.

- [ ] **Step 3: Add renderer protocol conformance to client**

In `Shared/HueBridgeClient.swift`, add:

```swift
protocol HueLightUpdating {
    func updateLight(id: String, body: [String: HueJSONValue]) async throws
}

extension HueBridgeClient: HueLightUpdating {}
```

- [ ] **Step 4: Add renderer**

Create `Shared/HueAmbienceRenderer.swift`:

```swift
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
        for target in targets {
            for (offset, lightID) in target.lightIDs.enumerated() {
                guard let light = target.lightsByID[lightID], light.supportsColor else { continue }
                let rotated = rotatedPalette(palette, by: offset)
                if light.supportsGradient, rotated.count > 1 {
                    try await lightClient.updateLight(
                        id: lightID,
                        body: gradientBody(colors: rotated, transitionSeconds: transitionSeconds)
                    )
                } else {
                    try await lightClient.updateLight(
                        id: lightID,
                        body: colorBody(color: rotated[0], transitionSeconds: transitionSeconds)
                    )
                }
            }
        }
    }

    private func rotatedPalette(_ palette: [HueRGBColor], by offset: Int) -> [HueRGBColor] {
        guard !palette.isEmpty else { return [] }
        return palette.indices.map { palette[($0 + offset) % palette.count] }
    }

    private func colorBody(color: HueRGBColor, transitionSeconds: Double) -> [String: HueJSONValue] {
        let xy = color.xy
        return [
            "on": .object(["on": .bool(true)]),
            "dimming": .object(["brightness": .number(color.brightness * 100)]),
            "color": .object([
                "xy": .object([
                    "x": .number(xy.x),
                    "y": .number(xy.y)
                ])
            ]),
            "dynamics": .object(["duration": .number(transitionSeconds * 1000)])
        ]
    }

    private func gradientBody(colors: [HueRGBColor], transitionSeconds: Double) -> [String: HueJSONValue] {
        let points = colors.prefix(5).map { color -> HueJSONValue in
            let xy = color.xy
            return .object([
                "color": .object([
                    "xy": .object([
                        "x": .number(xy.x),
                        "y": .number(xy.y)
                    ])
                ])
            ])
        }
        return [
            "on": .object(["on": .bool(true)]),
            "dimming": .object(["brightness": .number((colors.map(\.brightness).max() ?? 0.65) * 100)]),
            "gradient": .object(["points": .array(points)]),
            "dynamics": .object(["duration": .number(transitionSeconds * 1000)])
        ]
    }
}
```

- [ ] **Step 5: Update project exceptions**

Add `HueAmbienceRenderer.swift` to Shared exceptions for `TheWidgetExtension` and `SonosWidgetTests`.

- [ ] **Step 6: Run renderer tests to verify pass**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueAmbienceRendererTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Shared/HueAmbienceRenderer.swift Shared/HueBridgeClient.swift SonosWidgetTests/HueAmbienceRendererTests.swift SonosWidget.xcodeproj/project.pbxproj
git commit -m "feat: render hue music ambience colors"
```

---

### Task 7: Mapping Resolution And Music Ambience Manager

**Files:**
- Create: `Shared/MusicAmbienceManager.swift`
- Test: `SonosWidgetTests/MusicAmbienceManagerTests.swift`
- Modify: `SonosWidget.xcodeproj/project.pbxproj` exception lists for new Shared file

- [ ] **Step 1: Write failing manager tests**

Create `SonosWidgetTests/MusicAmbienceManagerTests.swift`:

```swift
import XCTest
@testable import SonosWidget

final class MusicAmbienceManagerTests: XCTestCase {
    func testAllMappedRoomsStrategyResolvesEveryGroupMemberMapping() {
        let store = HueAmbienceStore(storage: HueAmbienceDefaults(defaults: UserDefaults(suiteName: "MusicAmbienceManagerTests.\(UUID().uuidString)")!))
        store.isEnabled = true
        store.upsertMapping(HueSonosMapping(sonosID: "living", sonosName: "Living", preferredTarget: .entertainmentArea("ent-living")))
        store.upsertMapping(HueSonosMapping(sonosID: "kitchen", sonosName: "Kitchen", preferredTarget: .entertainmentArea("ent-kitchen")))
        store.groupStrategy = .allMappedRooms

        let manager = MusicAmbienceManager(store: store)
        let snapshot = HueAmbiencePlaybackSnapshot(
            selectedSonosID: "living",
            selectedSonosName: "Living",
            groupMemberIDs: ["living", "kitchen"],
            groupMemberNamesByID: ["living": "Living", "kitchen": "Kitchen"],
            trackTitle: "Song",
            artist: "Artist",
            albumArtURL: "art",
            isPlaying: true,
            albumArtImage: nil
        )

        let targets = manager.mappingsForCurrentPlayback(snapshot)

        XCTAssertEqual(targets.map(\.preferredTarget), [.entertainmentArea("ent-living"), .entertainmentArea("ent-kitchen")])
    }

    func testCoordinatorOnlyStrategyResolvesSelectedMapping() {
        let store = HueAmbienceStore(storage: HueAmbienceDefaults(defaults: UserDefaults(suiteName: "MusicAmbienceManagerTests.\(UUID().uuidString)")!))
        store.isEnabled = true
        store.upsertMapping(HueSonosMapping(sonosID: "living", sonosName: "Living", preferredTarget: .entertainmentArea("ent-living")))
        store.upsertMapping(HueSonosMapping(sonosID: "kitchen", sonosName: "Kitchen", preferredTarget: .entertainmentArea("ent-kitchen")))
        store.groupStrategy = .coordinatorOnly

        let manager = MusicAmbienceManager(store: store)
        let snapshot = HueAmbiencePlaybackSnapshot(
            selectedSonosID: "living",
            selectedSonosName: "Living",
            groupMemberIDs: ["living", "kitchen"],
            groupMemberNamesByID: [:],
            trackTitle: "Song",
            artist: "Artist",
            albumArtURL: "art",
            isPlaying: true,
            albumArtImage: nil
        )

        XCTAssertEqual(manager.mappingsForCurrentPlayback(snapshot).map(\.sonosID), ["living"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/MusicAmbienceManagerTests
```

Expected: FAIL because `MusicAmbienceManager` does not exist.

- [ ] **Step 3: Add manager**

Create `Shared/MusicAmbienceManager.swift`:

```swift
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class MusicAmbienceManager {
    static let shared = MusicAmbienceManager()

    enum Status: Equatable {
        case disabled
        case unconfigured
        case idle
        case syncing(String)
        case paused(String)
        case error(String)

        var title: String {
            switch self {
            case .disabled: return "Disabled"
            case .unconfigured: return "Set Up Music Ambience"
            case .idle: return "Ready"
            case .syncing(let detail): return detail
            case .paused(let detail): return detail
            case .error(let message): return message
            }
        }
    }

    private(set) var status: Status = .unconfigured

    private let store: HueAmbienceStore
    private var lastTrackKey: String?
    private var lastPalette: [HueRGBColor] = []

    init(store: HueAmbienceStore = .shared) {
        self.store = store
        refreshStatus()
    }

    func refreshStatus() {
        if !store.isEnabled {
            status = .disabled
        } else if store.bridge == nil || store.mappings.isEmpty {
            status = .unconfigured
        } else {
            status = .idle
        }
        store.statusText = status.title
    }

    func mappingsForCurrentPlayback(_ snapshot: HueAmbiencePlaybackSnapshot) -> [HueSonosMapping] {
        guard store.isEnabled else { return [] }
        let ids: [String]
        switch store.groupStrategy {
        case .allMappedRooms:
            ids = snapshot.groupMemberIDs.isEmpty
                ? snapshot.selectedSonosID.map { [$0] } ?? []
                : snapshot.groupMemberIDs
        case .coordinatorOnly:
            ids = snapshot.selectedSonosID.map { [$0] } ?? []
        }

        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return store.mapping(forSonosID: id)
        }
    }

    func receive(snapshot: HueAmbiencePlaybackSnapshot) {
        guard store.isEnabled else {
            status = .disabled
            return
        }
        guard store.bridge != nil else {
            status = .unconfigured
            return
        }
        guard snapshot.isPlaying else {
            status = .idle
            return
        }
        let mappings = mappingsForCurrentPlayback(snapshot)
        guard !mappings.isEmpty else {
            status = .paused("No Hue area mapped")
            return
        }
        let trackKey = [snapshot.trackTitle, snapshot.artist, snapshot.albumArtURL]
            .compactMap { $0 }
            .joined(separator: "|")
        if trackKey != lastTrackKey {
            lastTrackKey = trackKey
            if let data = snapshot.albumArtImage, let image = UIImage(data: data) {
                lastPalette = AlbumPaletteExtractor.palette(from: image)
            }
        }
        status = .syncing("Syncing \(mappings.count) Hue area\(mappings.count == 1 ? "" : "s")")
        store.statusText = status.title
    }
}
```

- [ ] **Step 4: Update project exceptions**

Add `MusicAmbienceManager.swift` to Shared exceptions for `TheWidgetExtension` and `SonosWidgetTests`.

- [ ] **Step 5: Run tests to verify pass**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/MusicAmbienceManagerTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Shared/MusicAmbienceManager.swift SonosWidgetTests/MusicAmbienceManagerTests.swift SonosWidget.xcodeproj/project.pbxproj
git commit -m "feat: resolve music ambience mappings"
```

---

### Task 8: Wire Sonos Snapshots Into Music Ambience

**Files:**
- Modify: `SonosWidget/SonosManager.swift`
- Modify: `SonosWidget/ContentView.swift`
- Test: extend `SonosWidgetTests/MusicAmbienceManagerTests.swift` if new snapshot helper is pure

- [ ] **Step 1: Add failing snapshot helper test**

Append to `MusicAmbienceManagerTests`:

```swift
func testSnapshotUsesSelectedSpeakerAndVisibleGroupMembers() {
    let selected = SonosPlayer(
        id: "living",
        name: "Living",
        ipAddress: "192.168.1.10",
        isCoordinator: true,
        groupId: "group-1"
    )
    let kitchen = SonosPlayer(
        id: "kitchen",
        name: "Kitchen",
        ipAddress: "192.168.1.11",
        isCoordinator: false,
        groupId: "group-1"
    )
    let info = TrackInfo(title: "Song", artist: "Artist", album: "Album", albumArtURL: "https://example.com/art.jpg")

    let snapshot = SonosManager.musicAmbienceSnapshot(
        selectedSpeaker: selected,
        currentGroupMembers: [selected, kitchen],
        trackInfo: info,
        isPlaying: true,
        albumArtData: Data([1, 2, 3])
    )

    XCTAssertEqual(snapshot.selectedSonosID, "living")
    XCTAssertEqual(snapshot.groupMemberIDs, ["living", "kitchen"])
    XCTAssertEqual(snapshot.trackTitle, "Song")
    XCTAssertTrue(snapshot.isPlaying)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/MusicAmbienceManagerTests/testSnapshotUsesSelectedSpeakerAndVisibleGroupMembers
```

Expected: FAIL because snapshot helper does not exist.

- [ ] **Step 3: Add pure snapshot builder to `SonosManager`**

In `SonosWidget/SonosManager.swift`, add near other `nonisolated static` helpers:

```swift
    nonisolated static func musicAmbienceSnapshot(
        selectedSpeaker: SonosPlayer?,
        currentGroupMembers: [SonosPlayer],
        trackInfo: TrackInfo?,
        isPlaying: Bool,
        albumArtData: Data?
    ) -> HueAmbiencePlaybackSnapshot {
        let visibleMembers = currentGroupMembers.filter { !$0.isInvisible }
        let members = visibleMembers.isEmpty
            ? selectedSpeaker.map { [$0] } ?? []
            : visibleMembers
        return HueAmbiencePlaybackSnapshot(
            selectedSonosID: selectedSpeaker?.id,
            selectedSonosName: selectedSpeaker?.name,
            groupMemberIDs: members.map(\.id),
            groupMemberNamesByID: Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.name) }),
            trackTitle: trackInfo?.title,
            artist: trackInfo?.artist,
            albumArtURL: trackInfo?.albumArtURL,
            isPlaying: isPlaying,
            albumArtImage: albumArtData
        )
    }

    func musicAmbienceSnapshot() -> HueAmbiencePlaybackSnapshot {
        Self.musicAmbienceSnapshot(
            selectedSpeaker: selectedSpeaker,
            currentGroupMembers: currentGroupMembers,
            trackInfo: trackInfo,
            isPlaying: isPlaying,
            albumArtData: albumArtImage?.jpegData(compressionQuality: 0.85)
        )
    }
```

- [ ] **Step 4: Notify manager after playback state refresh**

In `refreshStateLAN()` and `refreshStateCloud()`, after `await loadAlbumArt()` and before `managePositionTimer()`, add:

```swift
            MusicAmbienceManager.shared.receive(snapshot: musicAmbienceSnapshot())
```

In the not-playing branch where Live Activity is stopped, `receive(snapshot:)` will set Music Ambience to idle.

- [ ] **Step 5: Warm manager lifecycle from ContentView**

In `SonosWidget/ContentView.swift`, inside `.onAppear`, after `RelayManager.shared.startPeriodicProbe()` add:

```swift
            MusicAmbienceManager.shared.refreshStatus()
```

- [ ] **Step 6: Run targeted tests**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/MusicAmbienceManagerTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add SonosWidget/SonosManager.swift SonosWidget/ContentView.swift SonosWidgetTests/MusicAmbienceManagerTests.swift
git commit -m "feat: feed sonos playback to music ambience"
```

---

### Task 9: Settings Guided Setup UI

**Files:**
- Create: `SonosWidget/MusicAmbienceSettingsView.swift`
- Modify: `SonosWidget/SettingsView.swift`
- Modify: `SonosWidget/Info.plist`

- [ ] **Step 1: Add Info.plist local network support**

Modify `SonosWidget/Info.plist`:

```xml
<key>NSBonjourServices</key>
<array>
    <string>_sonos._tcp</string>
    <string>_hue._tcp</string>
</array>
<key>NSLocalNetworkUsageDescription</key>
<string>Charm Player needs to access your local network to discover and control Sonos speakers and your Hue Bridge.</string>
```

- [ ] **Step 2: Create settings view**

Create `SonosWidget/MusicAmbienceSettingsView.swift`:

```swift
import SwiftUI

struct MusicAmbienceSettingsView: View {
    @Bindable var store: HueAmbienceStore
    @Bindable var manager: MusicAmbienceManager
    let sonosSpeakers: [SonosPlayer]

    @State private var showingSetup = false

    var body: some View {
        Section {
            statusRow

            Toggle("Enable Music Ambience", isOn: $store.isEnabled)
                .disabled(store.bridge == nil || store.mappings.isEmpty)

            Button {
                showingSetup = true
            } label: {
                Label(store.bridge == nil ? "Set Up Hue Bridge" : "Edit Hue Assignments",
                      systemImage: "sparkles")
            }

            if store.bridge != nil {
                Picker("Group Playback", selection: $store.groupStrategy) {
                    ForEach(HueGroupSyncStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.label).tag(strategy)
                    }
                }
            }
        } header: {
            Text("Hue Music Ambience")
        } footer: {
            Text("Uses album artwork colors for Hue ambience. Without a NAS, continuous background syncing is limited by iOS.")
        }
        .sheet(isPresented: $showingSetup) {
            HueAmbienceSetupSheet(store: store, sonosSpeakers: sonosSpeakers)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title3)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.status.title)
                    .font(.subheadline.weight(.semibold))
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusIcon: String {
        switch manager.status {
        case .disabled: return "lightswitch.off"
        case .unconfigured: return "link.badge.plus"
        case .idle: return "checkmark.circle.fill"
        case .syncing: return "sparkles"
        case .paused: return "pause.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch manager.status {
        case .syncing, .idle: return .green
        case .paused, .unconfigured: return .orange
        case .error: return .red
        case .disabled: return .secondary
        }
    }

    private var statusSubtitle: String {
        if let bridge = store.bridge {
            return "\(bridge.name) · \(store.mappings.count) assignment\(store.mappings.count == 1 ? "" : "s")"
        }
        return "Pair a Hue Bridge and assign Entertainment Areas to Sonos rooms."
    }
}

private struct HueAmbienceSetupSheet: View {
    @Bindable var store: HueAmbienceStore
    let sonosSpeakers: [SonosPlayer]
    @Environment(\.dismiss) private var dismiss

    @State private var bridgeIP = ""
    @State private var bridgeName = "Hue Bridge"

    var body: some View {
        NavigationStack {
            Form {
                Section("Bridge") {
                    TextField("192.168.1.20", text: $bridgeIP)
                        .keyboardType(.decimalPad)
                    TextField("Hue Bridge", text: $bridgeName)
                    Button("Save Bridge") {
                        let id = bridgeIP.replacingOccurrences(of: ".", with: "-")
                        store.bridge = HueBridgeInfo(id: id, ipAddress: bridgeIP, name: bridgeName)
                    }
                    .disabled(bridgeIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Assignments") {
                    if sonosSpeakers.isEmpty {
                        Text("Connect Sonos speakers before assigning Hue areas.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sonosSpeakers) { speaker in
                            HueMappingRow(store: store, speaker: speaker)
                        }
                    }
                }

                Section("NAS Enhanced") {
                    LabeledContent("Live Entertainment", value: "Available after NAS/streaming runtime is configured")
                }
            }
            .navigationTitle("Music Ambience")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct HueMappingRow: View {
    @Bindable var store: HueAmbienceStore
    let speaker: SonosPlayer

    @State private var areaID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(speaker.name)
                .font(.subheadline.weight(.semibold))
            TextField("Entertainment Area ID", text: $areaID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save Assignment") {
                store.upsertMapping(HueSonosMapping(
                    sonosID: speaker.id,
                    sonosName: speaker.name,
                    preferredTarget: .entertainmentArea(areaID),
                    fallbackTarget: nil,
                    capability: .liveEntertainment
                ))
            }
            .disabled(areaID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear {
            if case .entertainmentArea(let id) = store.mapping(forSonosID: speaker.id)?.preferredTarget {
                areaID = id
            }
        }
    }
}
```

This first UI uses manual Bridge IP and Entertainment Area ID as a working vertical slice. Task 11 replaces the manual resource entry with fetched Hue resources.

- [ ] **Step 3: Add section to existing Settings**

In `SonosWidget/SettingsView.swift`, add properties:

```swift
    @Bindable private var hueStore = HueAmbienceStore.shared
    @Bindable private var ambience = MusicAmbienceManager.shared
```

Inside `Form`, after `speakersSection`, add:

```swift
                MusicAmbienceSettingsView(
                    store: hueStore,
                    manager: ambience,
                    sonosSpeakers: displayedSpeakers
                )
```

- [ ] **Step 4: Build**

Run:

```bash
xcodebuild build -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add SonosWidget/MusicAmbienceSettingsView.swift SonosWidget/SettingsView.swift SonosWidget/Info.plist
git commit -m "feat: add music ambience settings"
```

---

### Task 10: Bridge Pairing And Resource-Driven Setup

**Files:**
- Modify: `Shared/HueBridgeClient.swift`
- Modify: `SonosWidget/MusicAmbienceSettingsView.swift`
- Test: `SonosWidgetTests/HueBridgeClientTests.swift`

- [ ] **Step 1: Add client discovery test for broker response**

Append to `HueBridgeClientTests`:

```swift
func testDiscoveryResponseDecodesBridgeIPAndID() throws {
    let data = Data("""
    [
      { "id": "001788fffe123456", "internalipaddress": "192.168.1.20", "port": 443 }
    ]
    """.utf8)

    let bridges = try HueBridgeDiscoveryResult.decode(data)

    XCTAssertEqual(bridges.first?.id, "001788fffe123456")
    XCTAssertEqual(bridges.first?.ipAddress, "192.168.1.20")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueBridgeClientTests/testDiscoveryResponseDecodesBridgeIPAndID
```

Expected: FAIL because `HueBridgeDiscoveryResult` does not exist.

- [ ] **Step 3: Add discovery decoder and broker call**

Add to `Shared/HueBridgeClient.swift`:

```swift
struct HueBridgeDiscoveryResult: Decodable, Equatable, Sendable {
    let id: String
    let internalipaddress: String
    let port: Int?

    var ipAddress: String { internalipaddress }

    static func decode(_ data: Data) throws -> [HueBridgeDiscoveryResult] {
        try JSONDecoder().decode([HueBridgeDiscoveryResult].self, from: data)
    }
}

enum HueBridgeDiscovery {
    static func discoverViaBroker(session: URLSession = .shared) async throws -> [HueBridgeInfo] {
        let url = URL(string: "https://discovery.meethue.com/")!
        let (data, _) = try await session.data(from: url)
        return try HueBridgeDiscoveryResult.decode(data).map {
            HueBridgeInfo(id: $0.id, ipAddress: $0.ipAddress, name: "Hue Bridge")
        }
    }
}
```

- [ ] **Step 4: Replace manual setup sheet with pair/fetch flow**

In `HueAmbienceSetupSheet`, add state:

```swift
    @State private var discovered: [HueBridgeInfo] = []
    @State private var selectedBridge: HueBridgeInfo?
    @State private var areas: [HueAreaResource] = []
    @State private var lights: [HueLightResource] = []
    @State private var setupError: String?
    @State private var isBusy = false
```

Add buttons:

```swift
Button("Find Hue Bridge") {
    Task {
        isBusy = true
        defer { isBusy = false }
        do {
            discovered = try await HueBridgeDiscovery.discoverViaBroker()
            selectedBridge = discovered.first
        } catch {
            setupError = error.localizedDescription
        }
    }
}

Button("Pair Selected Bridge") {
    guard let bridge = selectedBridge else { return }
    Task {
        isBusy = true
        defer { isBusy = false }
        do {
            let client = HueBridgeClient(bridge: bridge)
            _ = try await client.pairBridge(deviceType: "Charm Player#iPhone")
            store.bridge = bridge
            let resources = try await client.fetchResources()
            areas = resources.areas
            lights = resources.lights
        } catch {
            setupError = error.localizedDescription
        }
    }
}
```

Replace `HueMappingRow`'s `TextField("Entertainment Area ID")` with a `Picker` over `areas.filter { $0.kind == .entertainmentArea }`, falling back to Rooms/Zones when none exist.

- [ ] **Step 5: Run tests and build**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueBridgeClientTests
xcodebuild build -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: Tests pass and build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Shared/HueBridgeClient.swift SonosWidget/MusicAmbienceSettingsView.swift SonosWidgetTests/HueBridgeClientTests.swift
git commit -m "feat: pair hue bridge from music ambience setup"
```

---

### Task 11: Connect Renderer To Manager

**Files:**
- Modify: `Shared/MusicAmbienceManager.swift`
- Modify: `Shared/HueAmbienceStore.swift`
- Test: `SonosWidgetTests/MusicAmbienceManagerTests.swift`

- [ ] **Step 1: Add failing manager rendering test**

Append to `MusicAmbienceManagerTests`:

```swift
func testReceiveAppliesPaletteWhenPlayingAndMapped() async {
    let defaults = UserDefaults(suiteName: "MusicAmbienceManagerTests.\(UUID().uuidString)")!
    let store = HueAmbienceStore(storage: HueAmbienceDefaults(defaults: defaults))
    store.isEnabled = true
    store.bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.20", name: "Home Hue")
    store.upsertMapping(HueSonosMapping(sonosID: "living", sonosName: "Living", preferredTarget: .room("room-1")))

    let renderer = RecordingAmbienceRendering()
    let resolver = StaticHueTargetResolving(targets: [
        HueResolvedAmbienceTarget(
            areaID: "room-1",
            lightIDs: ["light-1"],
            lightsByID: [
                "light-1": HueLightResource(id: "light-1", name: "Lamp", ownerID: nil, supportsColor: true, supportsGradient: false, supportsEntertainment: false)
            ]
        )
    ])
    let manager = MusicAmbienceManager(store: store, renderer: renderer, targetResolver: resolver)

    manager.receive(snapshot: HueAmbiencePlaybackSnapshot(
        selectedSonosID: "living",
        selectedSonosName: "Living",
        groupMemberIDs: ["living"],
        groupMemberNamesByID: ["living": "Living"],
        trackTitle: "Song",
        artist: "Artist",
        albumArtURL: "art",
        isPlaying: true,
        albumArtImage: makeRedImageData()
    ))

    XCTAssertEqual(renderer.applyCount, 1)
}

private final class RecordingAmbienceRendering: HueAmbienceRendering {
    var applyCount = 0
    func apply(palette: [HueRGBColor], to targets: [HueResolvedAmbienceTarget], transitionSeconds: Double) async throws {
        applyCount += 1
    }
}

private struct StaticHueTargetResolving: HueTargetResolving {
    var targets: [HueResolvedAmbienceTarget]
    func resolveTargets(for mappings: [HueSonosMapping]) -> [HueResolvedAmbienceTarget] { targets }
}

private func makeRedImageData() -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
    let image = renderer.image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    }
    return image.pngData()!
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/MusicAmbienceManagerTests/testReceiveAppliesPaletteWhenPlayingAndMapped
```

Expected: FAIL because renderer/target resolver injection does not exist.

- [ ] **Step 3: Add rendering protocols**

In `Shared/HueAmbienceRenderer.swift`, add:

```swift
protocol HueAmbienceRendering {
    func apply(palette: [HueRGBColor], to targets: [HueResolvedAmbienceTarget], transitionSeconds: Double) async throws
}

extension HueAmbienceRenderer: HueAmbienceRendering {}

protocol HueTargetResolving {
    func resolveTargets(for mappings: [HueSonosMapping]) -> [HueResolvedAmbienceTarget]
}
```

Add a production resolver:

```swift
struct StoredHueTargetResolver: HueTargetResolving {
    var areas: [HueAreaResource]
    var lights: [HueLightResource]

    func resolveTargets(for mappings: [HueSonosMapping]) -> [HueResolvedAmbienceTarget] {
        let lightsByID = Dictionary(uniqueKeysWithValues: lights.map { ($0.id, $0) })
        return mappings.compactMap { mapping in
            guard let target = mapping.preferredTarget ?? mapping.fallbackTarget,
                  let area = areas.first(where: { $0.id == target.id }) else { return nil }
            let filtered = area.childLightIDs.filter { !mapping.excludedLightIDs.contains($0) }
            return HueResolvedAmbienceTarget(areaID: area.id, lightIDs: filtered, lightsByID: lightsByID)
        }
    }
}
```

- [ ] **Step 4: Inject renderer/resolver into manager**

Modify `MusicAmbienceManager` initializer:

```swift
    private let renderer: HueAmbienceRendering?
    private let targetResolver: HueTargetResolving?

    init(
        store: HueAmbienceStore = .shared,
        renderer: HueAmbienceRendering? = nil,
        targetResolver: HueTargetResolving? = nil
    ) {
        self.store = store
        self.renderer = renderer
        self.targetResolver = targetResolver
        refreshStatus()
    }
```

At the end of `receive(snapshot:)`, after setting `.syncing`, add:

```swift
        guard let renderer, let targetResolver else { return }
        let targets = targetResolver.resolveTargets(for: mappings)
        guard !targets.isEmpty, !lastPalette.isEmpty else { return }
        Task {
            do {
                try await renderer.apply(palette: lastPalette, to: targets, transitionSeconds: 4)
            } catch {
                await MainActor.run {
                    self.status = .error(error.localizedDescription)
                    self.store.statusText = self.status.title
                }
            }
        }
```

- [ ] **Step 5: Run manager tests**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/MusicAmbienceManagerTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Shared/MusicAmbienceManager.swift Shared/HueAmbienceRenderer.swift SonosWidgetTests/MusicAmbienceManagerTests.swift
git commit -m "feat: apply hue ambience from sonos playback"
```

---

### Task 12: Stop Behavior And Preview Cleanup

**Files:**
- Modify: `Shared/SharedStorage.swift`
- Modify: `Shared/HueAmbienceStore.swift`
- Modify: `Shared/HueAmbienceRenderer.swift`
- Modify: `Shared/MusicAmbienceManager.swift`
- Modify: `SonosWidget/MusicAmbienceSettingsView.swift`
- Test: `SonosWidgetTests/HueAmbienceStoreTests.swift`
- Test: `SonosWidgetTests/HueAmbienceRendererTests.swift`

- [ ] **Step 1: Add failing persistence test for stop behavior**

Append to `HueAmbienceStoreTests`:

```swift
func testStorePersistsStopBehavior() {
    let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let storage = HueAmbienceDefaults(defaults: defaults)
    let store = HueAmbienceStore(storage: storage)

    store.stopBehavior = .turnOff

    let restored = HueAmbienceStore(storage: storage)

    XCTAssertEqual(restored.stopBehavior, .turnOff)
}
```

- [ ] **Step 2: Add failing renderer stop test**

Append to `HueAmbienceRendererTests`:

```swift
func testStopTurnsOffSyncedLightsWhenConfigured() async throws {
    let client = RecordingHueLightClient()
    let renderer = HueAmbienceRenderer(lightClient: client)
    let target = HueResolvedAmbienceTarget(
        areaID: "room-1",
        lightIDs: ["light-1"],
        lightsByID: [
            "light-1": HueLightResource(
                id: "light-1",
                name: "Lamp",
                ownerID: nil,
                supportsColor: true,
                supportsGradient: false,
                supportsEntertainment: false
            )
        ]
    )

    try await renderer.stop(targets: [target], behavior: .turnOff)

    XCTAssertEqual(client.updates.count, 1)
    XCTAssertEqual(client.updates[0].body["on"], .object(["on": .bool(false)]))
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueAmbienceStoreTests/testStorePersistsStopBehavior -only-testing:SonosWidgetTests/HueAmbienceRendererTests/testStopTurnsOffSyncedLightsWhenConfigured
```

Expected: FAIL because store stop behavior and renderer stop are not implemented.

- [ ] **Step 4: Persist stop behavior**

Modify `Shared/SharedStorage.swift` Hue Music Ambience section:

```swift
    nonisolated static var hueStopBehaviorRaw: String? {
        get { defaults.string(forKey: "hueStopBehavior") }
        set { defaults.set(newValue, forKey: "hueStopBehavior") }
    }
```

Modify `HueAmbienceStorage` in `Shared/HueAmbienceStore.swift`:

```swift
    var stopBehaviorRaw: String? { get set }
```

Modify `HueAmbienceDefaults`:

```swift
    var stopBehaviorRaw: String? {
        get { defaults?.string(forKey: "hueStopBehavior") ?? SharedStorage.hueStopBehaviorRaw }
        set {
            if let defaults { defaults.set(newValue, forKey: "hueStopBehavior") }
            else { SharedStorage.hueStopBehaviorRaw = newValue }
        }
    }
```

Modify `HueAmbienceStore` properties:

```swift
    var stopBehavior: HueAmbienceStopBehavior { didSet { storage.stopBehaviorRaw = stopBehavior.rawValue } }
```

Modify `HueAmbienceStore.init`:

```swift
        self.stopBehavior = storage.stopBehaviorRaw.flatMap(HueAmbienceStopBehavior.init(rawValue:)) ?? .default
```

- [ ] **Step 5: Add stop rendering**

Extend `HueAmbienceRendering` in `Shared/HueAmbienceRenderer.swift`:

```swift
protocol HueAmbienceRendering {
    func apply(palette: [HueRGBColor], to targets: [HueResolvedAmbienceTarget], transitionSeconds: Double) async throws
    func stop(targets: [HueResolvedAmbienceTarget], behavior: HueAmbienceStopBehavior) async throws
}
```

Add to `HueAmbienceRenderer`:

```swift
    func stop(targets: [HueResolvedAmbienceTarget], behavior: HueAmbienceStopBehavior) async throws {
        guard behavior == .turnOff else { return }
        for target in targets {
            for lightID in target.lightIDs {
                try await lightClient.updateLight(
                    id: lightID,
                    body: [
                        "on": .object(["on": .bool(false)]),
                        "dynamics": .object(["duration": .number(1200)])
                    ]
                )
            }
        }
    }
```

Update test helper `RecordingAmbienceRendering`:

```swift
    var stopCount = 0
    func stop(targets: [HueResolvedAmbienceTarget], behavior: HueAmbienceStopBehavior) async throws {
        stopCount += 1
    }
```

- [ ] **Step 6: Stop when playback stops or sync is disabled**

In `MusicAmbienceManager`, add:

```swift
    private var lastResolvedTargets: [HueResolvedAmbienceTarget] = []
```

When applying playback in `receive(snapshot:)`, after resolving targets:

```swift
        lastResolvedTargets = targets
```

Before returning on disabled or non-playing snapshots:

```swift
            stopActiveAmbience()
```

Add method:

```swift
    private func stopActiveAmbience() {
        guard !lastResolvedTargets.isEmpty, let renderer else { return }
        let targets = lastResolvedTargets
        lastResolvedTargets = []
        Task {
            try? await renderer.stop(targets: targets, behavior: store.stopBehavior)
        }
    }
```

- [ ] **Step 7: Add UI picker**

In `MusicAmbienceSettingsView`, under group playback picker, add:

```swift
                Picker("When Playback Stops", selection: $store.stopBehavior) {
                    ForEach(HueAmbienceStopBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
```

- [ ] **Step 8: Run stop behavior tests**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueAmbienceStoreTests/testStorePersistsStopBehavior -only-testing:SonosWidgetTests/HueAmbienceRendererTests/testStopTurnsOffSyncedLightsWhenConfigured
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Shared/SharedStorage.swift Shared/HueAmbienceStore.swift Shared/HueAmbienceRenderer.swift Shared/MusicAmbienceManager.swift SonosWidget/MusicAmbienceSettingsView.swift SonosWidgetTests/HueAmbienceStoreTests.swift SonosWidgetTests/HueAmbienceRendererTests.swift
git commit -m "feat: add hue ambience stop behavior"
```

---

### Task 13: Live Entertainment Boundary And NAS Status

**Files:**
- Modify: `Shared/HueAmbienceModels.swift`
- Modify: `SonosWidget/MusicAmbienceSettingsView.swift`
- Test: `SonosWidgetTests/HueAmbienceStoreTests.swift`

- [ ] **Step 1: Add failing status label test**

Append to `HueAmbienceStoreTests`:

```swift
func testLiveEntertainmentWithoutRuntimeUsesClearUnavailableStatus() {
    XCTAssertEqual(HueLiveEntertainmentRuntimeStatus.unavailable.reason, "Requires NAS/Entertainment streaming runtime")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueAmbienceStoreTests/testLiveEntertainmentWithoutRuntimeUsesClearUnavailableStatus
```

Expected: FAIL because `HueLiveEntertainmentRuntimeStatus` does not exist.

- [ ] **Step 3: Add runtime status model**

In `Shared/HueAmbienceModels.swift`, add:

```swift
enum HueLiveEntertainmentRuntimeStatus: Equatable, Sendable {
    case unavailable
    case available
    case streaming
    case conflict

    var reason: String {
        switch self {
        case .unavailable: return "Requires NAS/Entertainment streaming runtime"
        case .available: return "Ready for Live Entertainment"
        case .streaming: return "Live Entertainment streaming"
        case .conflict: return "Another Hue app is using this Entertainment Area"
        }
    }
}
```

- [ ] **Step 4: Surface status in UI**

In `MusicAmbienceSettingsView`, change NAS row:

```swift
Section("NAS Enhanced") {
    LabeledContent("Live Entertainment", value: HueLiveEntertainmentRuntimeStatus.unavailable.reason)
    Text("App-only mode can still apply album colors and gradient-ready updates while Charm Player is active.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

- [ ] **Step 5: Run tests/build**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HueAmbienceStoreTests
xcodebuild build -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Shared/HueAmbienceModels.swift SonosWidget/MusicAmbienceSettingsView.swift SonosWidgetTests/HueAmbienceStoreTests.swift
git commit -m "feat: label hue live entertainment runtime"
```

---

### Task 14: Final Verification

**Files:**
- All files touched above

- [ ] **Step 1: Run full test suite**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: all tests pass.

- [ ] **Step 2: Build app**

Run:

```bash
xcodebuild build -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual smoke test on device or simulator**

Run the app and check:

```text
Settings -> Hue Music Ambience appears.
Tapping setup opens Music Ambience sheet.
Bridge IP/manual setup path saves Bridge metadata.
Sonos speakers appear in assignment rows.
Saved assignments remain after app relaunch.
Enable toggle is disabled until Bridge + at least one assignment exist.
Group strategy picker persists.
Live Entertainment row says it requires NAS/Entertainment streaming runtime.
```

- [ ] **Step 4: Check git diff**

Run:

```bash
git status --short
git diff --check
```

Expected: only intended files changed, no whitespace errors.

- [ ] **Step 5: Commit final polish if needed**

```bash
git add Shared SonosWidget SonosWidgetTests SonosWidget.xcodeproj/project.pbxproj
git commit -m "feat: complete music ambience hue sync"
```
