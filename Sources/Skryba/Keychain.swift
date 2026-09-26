import Foundation
import os
import Security

/// Stores the Groq API key in the login keychain — never in UserDefaults or the repo.
enum Keychain {
    private static let service = "pl.heartmade.skryba"
    private static let account = "groq-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        var query = baseQuery
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
    static func save(_ value: String) -> Bool {
        guard !value.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { log(status, "delete"); return false }
            return true
        }

        let data = Data(value.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            status = SecItemAdd(attributes as CFDictionary, nil)
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
