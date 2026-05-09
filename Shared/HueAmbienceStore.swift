import Foundation
import Observation

protocol HueAmbienceStorage: AnyObject {
    var isEnabled: Bool { get set }
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

    var bridge: HueBridgeInfo? {
        didSet {
            persistBridge()
        }
    }

    var mappings: [HueSonosMapping] {
        didSet {
            persistMappings()
        }
    }

    var groupStrategy: HueGroupSyncStrategy {
        didSet {
            storage.groupStrategyRaw = groupStrategy.rawValue
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
        self.bridge = Self.decode(HueBridgeInfo.self, from: storage.bridgeData)
        self.mappings = Self.decode([HueSonosMapping].self, from: storage.mappingsData) ?? []
        self.groupStrategy = storage.groupStrategyRaw
            .flatMap(HueGroupSyncStrategy.init(rawValue:)) ?? .default
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
        guard let bridge else {
            storage.bridgeData = nil
            return
        }
        storage.bridgeData = try? encoder.encode(bridge)
    }

    private func persistMappings() {
        storage.mappingsData = try? encoder.encode(mappings)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
