import Foundation
import Security

/// Minimal generic-password storage for secrets such as API keys.
enum Keychain {
    private static let service = "com.weaveneuron.shocrot"

    static var llmAPIKey: String? {
        get { read("llm-api-key") }
        set { write("llm-api-key", newValue) }
    }

    static func read(_ account: String) -> String? {
        var item: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String?) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
