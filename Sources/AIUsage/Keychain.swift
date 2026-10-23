import Foundation
import Security

/// API keys live in the login Keychain, never in plain files.
enum Keychain {
    private static let service = "com.local.aiusage"

    enum Key: String, CaseIterable {
        case anthropicAdmin, openAIAdmin, deepSeek, claudeSessionKey
        case claudeOAuth   // the app's own copy of the Claude Code login (JSON)
    }

    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)
        return value?.isEmpty == true ? nil : value
    }

    static func set(_ key: Key, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
