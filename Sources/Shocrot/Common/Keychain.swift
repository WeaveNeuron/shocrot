import Foundation
import Security

/// Minimal generic-password storage for secrets such as API keys.
enum Keychain {
    private static let service = "com.weaveneuron.shocrot"

    private static let legacyLLMAccount = "llm-api-key"
    private static let migratedFlag = "llmKeyMigrated"

    /// Keys are stored per server, so one provider's key is never sent to another.
    static func llmAPIKey(for baseURL: String) -> String? {
        origin(of: baseURL).flatMap { read("\(legacyLLMAccount):\($0)") }
    }

    /// Returns false when the key could not be stored.
    @discardableResult
    static func setLLMAPIKey(_ key: String, for baseURL: String) -> Bool {
        guard let origin = origin(of: baseURL) else { return false }
        return write("\(legacyLLMAccount):\(origin)", key)
    }

    /// The single key of older versions belongs to the server that was configured with it.
    static func migrateLegacyLLMKey(to baseURL: String) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedFlag) else { return }
        let finished = migrateLegacyKey(lookup(legacyLLMAccount),
                                        store: { setLLMAPIKey($0, for: baseURL) },
                                        remove: { write(legacyLLMAccount, nil) })
        if finished { defaults.set(true, forKey: migratedFlag) }
    }

    enum Lookup: Equatable {
        case missing
        case found(String)
        case unavailable // denied, locked, …: says nothing about whether the key exists
    }

    /// Returns whether the migration is over. The old key goes only once the new one is stored, and
    /// anything that may succeed later (access denied, no valid server yet) is retried on the next launch.
    static func migrateLegacyKey(_ legacy: Lookup, store: (String) -> Bool, remove: () -> Bool) -> Bool {
        switch legacy {
        case .missing: return true
        case .unavailable: return false
        case let .found(key):
            guard store(key) else { return false }
            _ = remove() // a leftover is unused; retrying could overwrite a key changed since
            return true
        }
    }

    /// `scheme://host[:port]`, lowercased; nil when the text isn't a usable server address.
    static func origin(of baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
    }

    static func read(_ account: String) -> String? {
        if case let .found(value) = lookup(account) { return value }
        return nil
    }

    private static func lookup(_ account: String) -> Lookup {
        var item: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true]
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return .unavailable }
            return .found(value)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable
        }
    }

    /// Updates in place, so a failed write leaves the old value intact. An empty value deletes.
    @discardableResult
    static func write(_ account: String, _ value: String?) -> Bool {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var add = query
        add[kSecValueData] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
