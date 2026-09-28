import Foundation
import os
import Security

/// Stores provider API tokens in the login keychain — never in UserDefaults or the repo.
enum Keychain {
    private static let service = "pl.heartmade.skryba"
    private static let groqAccount = "groq-api-key"
    private static let cloudflareAccount = "cloudflare-workers-ai-token"

    static func readGroqKey() -> String? { read(account: groqAccount) }
    static func saveGroqKey(_ value: String) -> Bool { save(value, account: groqAccount) }
    static func readCloudflareToken() -> String? { read(account: cloudflareAccount) }
    static func saveCloudflareToken(_ value: String) -> Bool { save(value, account: cloudflareAccount) }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(account: String) -> String? {
        var query = baseQuery(account: account)
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
    private static func save(_ value: String, account: String) -> Bool {
        let query = baseQuery(account: account)
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { log(status, "delete"); return false }
            return true
        }

        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
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
