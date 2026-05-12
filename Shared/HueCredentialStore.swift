import Foundation
import Security

protocol HueCredentialStorage {
    func save(_ value: String, account: String)
    func read(account: String) -> String?
    func delete(account: String)
}

struct KeychainHueCredentialStorage: HueCredentialStorage {
    private let service = "com.charm.SonosWidget.hue"

    func save(_ value: String, account: String) {
        delete(account: account)

        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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
        storage.save(key, account: applicationKeyAccount(forBridgeID: bridgeID))
    }

    func saveStreamingClientKey(_ key: String, forBridgeID bridgeID: String) {
        storage.save(key, account: streamingClientKeyAccount(forBridgeID: bridgeID))
    }

    func saveStreamingApplicationId(_ id: String, forBridgeID bridgeID: String) {
        storage.save(id, account: streamingApplicationIdAccount(forBridgeID: bridgeID))
    }

    func applicationKey(forBridgeID bridgeID: String) -> String? {
        storage.read(account: applicationKeyAccount(forBridgeID: bridgeID))
    }

    func streamingClientKey(forBridgeID bridgeID: String) -> String? {
        storage.read(account: streamingClientKeyAccount(forBridgeID: bridgeID))
    }

    func streamingApplicationId(forBridgeID bridgeID: String) -> String? {
        storage.read(account: streamingApplicationIdAccount(forBridgeID: bridgeID))
    }

    func deleteApplicationKey(forBridgeID bridgeID: String) {
        storage.delete(account: applicationKeyAccount(forBridgeID: bridgeID))
    }

    func deleteStreamingClientKey(forBridgeID bridgeID: String) {
        storage.delete(account: streamingClientKeyAccount(forBridgeID: bridgeID))
    }

    func deleteStreamingApplicationId(forBridgeID bridgeID: String) {
        storage.delete(account: streamingApplicationIdAccount(forBridgeID: bridgeID))
    }

    private func applicationKeyAccount(forBridgeID bridgeID: String) -> String {
        "hue.applicationKey.\(bridgeID)"
    }

    private func streamingClientKeyAccount(forBridgeID bridgeID: String) -> String {
        "hue.streamingClientKey.\(bridgeID)"
    }

    private func streamingApplicationIdAccount(forBridgeID bridgeID: String) -> String {
        "hue.streamingApplicationId.\(bridgeID)"
    }
}
