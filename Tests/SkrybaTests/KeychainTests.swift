import Security
import Testing
@testable import Skryba

/// Fakes only: these never reach a real keychain.
struct KeychainTests {
    @Test func aRefusedUpdateNeverDeletesOrReplacesTheOldKey() {
        var calls: [String] = []
        let saved = Keychain.save(
            "new", for: .groq,
            update: { _, _ in calls.append("update"); return errSecAuthFailed },
            add: { _, _ in calls.append("add"); return errSecSuccess },
            delete: { _ in calls.append("delete"); return errSecSuccess }
        )
        #expect(!saved)
        #expect(calls == ["update"])
    }

    @Test func aFirstKeyIsAdded() {
        var calls: [String] = []
        let saved = Keychain.save(
            "new", for: .openai,
            update: { _, _ in calls.append("update"); return errSecItemNotFound },
            add: { _, _ in calls.append("add"); return errSecSuccess },
            delete: { _ in calls.append("delete"); return errSecSuccess }
        )
        #expect(saved)
        #expect(calls == ["update", "add"])
    }

    @Test func anEmptyValueOnlyDeletes() {
        var calls: [String] = []
        let saved = Keychain.save(
            "", for: .cloudflare,
            update: { _, _ in calls.append("update"); return errSecSuccess },
            add: { _, _ in calls.append("add"); return errSecSuccess },
            delete: { _ in calls.append("delete"); return errSecItemNotFound }
        )
        #expect(saved)
        #expect(calls == ["delete"])
    }
}
