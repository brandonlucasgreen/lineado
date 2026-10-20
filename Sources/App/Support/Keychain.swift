import Foundation
import Security

/// The login keychain, for the one secret this app holds.
///
/// Read-through cached because the client reads the key on every request, and
/// an uncached `SecItemCopyMatching` per poll is both slow and a reason for
/// macOS to re-prompt.
enum Keychain {
    static let service = "lol.bgreen.lineado"
    static let apiKeyAccount = "linear.apiKey"

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String?] = [:]

        func value(for account: String, load: () -> String?) -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[account] { return cached }
            let loaded = load()
            storage[account] = loaded
            return loaded
        }

        func invalidate(_ account: String) {
            lock.lock()
            defer { lock.unlock() }
            storage[account] = nil
            storage.removeValue(forKey: account)
        }
    }

    static func get(_ account: String) -> String? {
        cache.value(for: account) { read(account) }
    }

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        defer { cache.invalidate(account) }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(value.utf8)
        // Update first, add on miss: SecItemAdd on an existing account returns
        // errSecDuplicateItem rather than replacing, which looks like a save
        // that worked and did not.
        let updated = SecItemUpdate(
            base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }

        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func hasAPIKey() -> Bool {
        guard let key = get(apiKeyAccount) else { return false }
        return !key.isEmpty
    }
}
