import Foundation
import Observation

protocol HueAmbienceStorage: AnyObject {
    var isEnabled: Bool { get set }
    var isCS2SyncEnabled: Bool { get set }
    var bridgeData: Data? { get set }
    var mappingsData: Data? { get set }
    var resourcesData: Data? { get set }
    var groupStrategyRaw: String? { get set }
    var stopBehaviorRaw: String? { get set }
    var motionStyleRaw: String? { get set }
    var flowSpeedRaw: String? { get set }
    var statusText: String? { get set }
}

final class HueAmbienceDefaults: HueAmbienceStorage {
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get {
            if let defaults {
                return defaults.bool(forKey: "hueAmbienceEnabled")
            }
            return SharedStorage.hueAmbienceEnabled
        }
        set {
            if let defaults {
                defaults.set(newValue, forKey: "hueAmbienceEnabled")
            } else {
                SharedStorage.hueAmbienceEnabled = newValue
            }
        }
    }

    var isCS2SyncEnabled: Bool {
        get {
            if let defaults {
                return defaults.bool(forKey: "hueCS2SyncEnabled")
            }
            return SharedStorage.hueCS2SyncEnabled
        }
        set {
            if let defaults {
                defaults.set(newValue, forKey: "hueCS2SyncEnabled")
            } else {
                SharedStorage.hueCS2SyncEnabled = newValue
            }
        }
    }

    var bridgeData: Data? {
        get {
            if let defaults {
                return defaults.data(forKey: "hueBridgeData")
            }
            return SharedStorage.hueBridgeData
        }
        set {
            if let defaults {
                updateOptional(newValue, forKey: "hueBridgeData", in: defaults)
            } else {
                SharedStorage.hueBridgeData = newValue
            }
        }
    }

    var mappingsData: Data? {
        get {
            if let defaults {
                return defaults.data(forKey: "hueMappingsData")
            }
            return SharedStorage.hueMappingsData
        }
        set {
            if let defaults {
                updateOptional(newValue, forKey: "hueMappingsData", in: defaults)
            } else {
                SharedStorage.hueMappingsData = newValue
            }
        }
    }

    var resourcesData: Data? {
        get {
            if let defaults {
                return defaults.data(forKey: "hueResourcesData")
            }
            return SharedStorage.hueResourcesData
        }
        set {
            if let defaults {
                updateOptional(newValue, forKey: "hueResourcesData", in: defaults)
            } else {
                SharedStorage.hueResourcesData = newValue
            }
        }
    }

    var groupStrategyRaw: String? {
        get {
            if let defaults {
                return defaults.string(forKey: "hueGroupStrategy")
            }
            return SharedStorage.hueGroupStrategyRaw
        }
        set {
            if let defaults {
                updateOptional(newValue, forKey: "hueGroupStrategy", in: defaults)
            } else {
                SharedStorage.hueGroupStrategyRaw = newValue
            }
        }
    }

    var stopBehaviorRaw: String? {
        get {
            if let defaults {
                return defaults.string(forKey: "hueStopBehavior")
            }
            return SharedStorage.hueStopBehaviorRaw
        }
        set {
            if let defaults {
                updateOptional(newValue, forKey: "hueStopBehavior", in: defaults)
            } else {
                SharedStorage.hueStopBehaviorRaw = newValue
            }
        }
    }

    var motionStyleRaw: String? {
        get {
            if let defaults {
                return defaults.string(forKey: "hueMotionStyle")
            }
            return SharedStorage.hueMotionStyleRaw
        }
        set {
            if let defaults {
                updateOptional(newValue, forKey: "hueMotionStyle", in: defaults)
            } else {
                SharedStorage.hueMotionStyleRaw = newValue
            }
        }
    }

    var flowSpeedRaw: String? {
        get {
            if let defaults {
                return defaults.string(forKey: "hueFlowSpeed")
            }
            return SharedStorage.hueFlowSpeedRaw
        }
        set {
            if let defaults {
                updateOptional(newValue, forKey: "hueFlowSpeed", in: defaults)
            } else {
                SharedStorage.hueFlowSpeedRaw = newValue
            }
        }
    }

    var statusText: String? {
        get {
            if let defaults {
                return defaults.string(forKey: "hueLastStatusText")
            }
            return SharedStorage.hueLastStatusText
        }
        set {
            if let defaults {
                updateOptional(newValue, forKey: "hueLastStatusText", in: defaults)
            } else {
                SharedStorage.hueLastStatusText = newValue
            }
        }
    }

    private func updateOptional(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

@MainActor
@Observable
final class HueAmbienceStore {
    static let shared = HueAmbienceStore()

    @ObservationIgnored private let storage: HueAmbienceStorage
    @ObservationIgnored private let encoder = JSONEncoder()

    var isEnabled: Bool {
        didSet {
            storage.isEnabled = isEnabled
        }
    }

    var isCS2SyncEnabled: Bool {
        didSet {
            storage.isCS2SyncEnabled = isCS2SyncEnabled
        }
    }

    var bridge: HueBridgeInfo? {
        didSet {
            if oldValue?.id != bridge?.id {
                mappings = []
                hueResources = .empty
            }
            persistBridge()
        }
    }

    var mappings: [HueSonosMapping] {
        didSet {
            persistMappings()
        }
    }

    var hueResources: HueBridgeResources {
        didSet {
            persistResources()
        }
    }

    var hueLights: [HueLightResource] {
        hueResources.lights
    }

    var hueAreas: [HueAreaResource] {
        hueResources.areas
    }

    var groupStrategy: HueGroupSyncStrategy {
        didSet {
            storage.groupStrategyRaw = groupStrategy.rawValue
        }
    }

    var stopBehavior: HueAmbienceStopBehavior {
        didSet {
            storage.stopBehaviorRaw = stopBehavior.rawValue
        }
    }

    var motionStyle: HueAmbienceMotionStyle {
        didSet {
            storage.motionStyleRaw = motionStyle.rawValue
        }
    }

    var flowSpeed: HueAmbienceFlowSpeed {
        didSet {
            storage.flowSpeedRaw = flowSpeed.rawValue
        }
    }

    var statusText: String? {
        didSet {
            storage.statusText = statusText
        }
    }

    init(storage: HueAmbienceStorage? = nil) {
        let storage = storage ?? HueAmbienceDefaults()
        self.storage = storage
        self.isEnabled = storage.isEnabled
        self.isCS2SyncEnabled = storage.isCS2SyncEnabled
        self.bridge = Self.decode(HueBridgeInfo.self, from: storage.bridgeData)
        let decodedMappings = Self.decode([HueSonosMapping].self, from: storage.mappingsData) ?? []
        let decodedResources = Self.decode(HueBridgeResources.self, from: storage.resourcesData)
        let sanitizedResources = decodedResources?.sanitizedForAmbience() ?? .empty
        self.hueResources = sanitizedResources
        if sanitizedResources.hasAssignableTargets {
            self.mappings = decodedMappings.compactMap { $0.sanitized(for: sanitizedResources) }
        } else {
            self.mappings = decodedMappings.compactMap { $0.sanitizedTargetShape() }
        }
        self.groupStrategy = storage.groupStrategyRaw
            .flatMap(HueGroupSyncStrategy.init(rawValue:)) ?? .default
        self.stopBehavior = storage.stopBehaviorRaw
            .flatMap(HueAmbienceStopBehavior.init(rawValue:)) ?? .default
        self.motionStyle = storage.motionStyleRaw
            .flatMap(HueAmbienceMotionStyle.init(rawValue:)) ?? .default
        self.flowSpeed = storage.flowSpeedRaw
            .flatMap(HueAmbienceFlowSpeed.init(rawValue:)) ?? .default
        self.statusText = storage.statusText

        if hueResources != (decodedResources ?? .empty) {
            persistResources()
        }
        if mappings != decodedMappings {
            persistMappings()
        }
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

    @discardableResult
    func assignArea(
        sonosID: String,
        sonosName: String,
        areaID: String,
        from areas: [HueAreaResource],
        lights: [HueLightResource]
    ) -> Bool {
        guard let area = areas.first(where: { $0.id == areaID }) else {
            return false
        }

        upsertMapping(HueAmbienceAreaOptions.mapping(
            sonosID: sonosID,
            sonosName: sonosName,
            selectedArea: area,
            lights: lights
        ))
        return true
    }

    func removeMapping(forSonosID sonosID: String) {
        mappings.removeAll { $0.sonosID == sonosID }
    }

    func updateResources(_ resources: HueBridgeResources) {
        let sanitizedResources = resources.sanitizedForAmbience()
        hueResources = sanitizedResources
        mappings = mappings.compactMap { $0.sanitized(for: sanitizedResources) }
    }

    func updateResources(_ resources: HueBridgeResources, forBridgeID bridgeID: String) -> Bool {
        guard bridge?.id == bridgeID else {
            return false
        }

        updateResources(resources)
        return true
    }

    func disconnectBridge() {
        isEnabled = false
        isCS2SyncEnabled = false
        bridge = nil
        mappings = []
        hueResources = .empty
        statusText = nil
    }

    private func persistBridge() {
        guard let bridge else {
            storage.bridgeData = nil
            return
        }
        storage.bridgeData = try? encoder.encode(bridge)
    }

    private func persistMappings() {
        storage.mappingsData = try? encoder.encode(mappings)
    }

    private func persistResources() {
        storage.resourcesData = try? encoder.encode(hueResources)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

private extension HueBridgeResources {
    func sanitizedForAmbience() -> HueBridgeResources {
        let validLightIDs = Set(lights.map(\.id))
        return HueBridgeResources(
            lights: lights,
            areas: areas.map { area in
                HueAreaResource(
                    id: area.id,
                    name: area.name,
                    kind: area.kind,
                    childLightIDs: area.childLightIDs.filter { validLightIDs.contains($0) },
                    childDeviceIDs: area.childDeviceIDs,
                    entertainmentChannels: area.entertainmentChannels
                )
            }
        )
    }

    func containsAssignableTarget(_ target: HueAmbienceTarget?) -> Bool {
        guard let target else {
            return false
        }

        switch target {
        case .light:
            return false
        case .entertainmentArea, .room, .zone:
            return areas.contains { $0.id == target.id && $0.ambienceTarget == target }
        }
    }

    var hasAssignableTargets: Bool {
        areas.contains { area in
            switch area.kind {
            case .entertainmentArea, .room, .zone:
                return true
            case .light:
                return false
            }
        }
    }
}

private extension HueSonosMapping {
    func sanitizedTargetShape() -> HueSonosMapping? {
        let resolvedPreferred = preferredTarget?.isLegacyDirectLightTarget == true ? nil : preferredTarget
        let resolvedFallback = fallbackTarget?.isLegacyDirectLightTarget == true ? nil : fallbackTarget

        guard let target = resolvedPreferred ?? resolvedFallback else {
            return nil
        }

        var mapping = self
        mapping.preferredTarget = target
        mapping.fallbackTarget = resolvedPreferred == nil ? nil : resolvedFallback
        if target.isEntertainmentArea {
            mapping.includedLightIDs = []
            mapping.excludedLightIDs = []
        }
        return mapping
    }

    func sanitized(for resources: HueBridgeResources) -> HueSonosMapping? {
        let validLightIDs = Set(resources.lights.map(\.id))
        let resolvedPreferred = resources.containsAssignableTarget(preferredTarget) ? preferredTarget : nil
        let resolvedFallback = resources.containsAssignableTarget(fallbackTarget) ? fallbackTarget : nil

        guard let target = resolvedPreferred ?? resolvedFallback else {
            return nil
        }

        var mapping = self
        mapping.preferredTarget = target
        mapping.fallbackTarget = resolvedPreferred == nil ? nil : resolvedFallback
        if target.isEntertainmentArea {
            mapping.includedLightIDs = []
            mapping.excludedLightIDs = []
        } else {
            mapping.includedLightIDs = includedLightIDs.intersection(validLightIDs)
            mapping.excludedLightIDs = excludedLightIDs.intersection(validLightIDs)
        }
        return mapping
    }
}
