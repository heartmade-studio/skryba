import Foundation
import os
import Security

/// Stores API credentials in the login keychain — never in UserDefaults or the repo.
///
/// No `kSecAttrAccessible…ThisDeviceOnly`: macOS supports it only in the data-protection keychain
/// (see SecItem.h), which needs a provisioning profile that Skryba's distribution doesn't have.
/// Without one, adding such an item fails with -34018 (tried ad-hoc and Apple Development signed).
enum Keychain {
    /// One keychain item per credential.
    enum Account: String {
        case groq = "groq-api-key"
        case cloudflare = "cloudflare-api-token"
        case openai = "openai-api-key"
    }

    private static let service = "pl.heartmade.skryba"

    private static func baseQuery(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    static func read(_ account: Account) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound { log(status, "read") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the key (an empty value deletes it). Updates in place, so a failed write never
    /// destroys the previous key. Returns false if the keychain refused.
    static func save(
        _ value: String, for account: Account,
        // Tests replace these, so they never touch a real keychain.
        update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
        add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd,
        delete: (CFDictionary) -> OSStatus = SecItemDelete
    ) -> Bool {
        let query = baseQuery(account)
        guard !value.isEmpty else {
            let status = delete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { log(status, "delete"); return false }
            return true
        }

        let data = Data(value.utf8)
        var status = update(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            status = add(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { log(status, "save"); return false }
        return true
    }

    private static func log(_ status: OSStatus, _ operation: String) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        Logger(subsystem: "pl.heartmade.skryba", category: "keychain")
            .error("\(operation, privacy: .public) failed: \(message, privacy: .public)")
    }
}
