import Foundation
import Observation

/// User preferences. Everything lives in UserDefaults except the API key, which goes to the keychain.
@MainActor @Observable
final class Settings {
    /// Mirrors the keychain; change it only through `saveAPIKey`.
    private(set) var apiKey: String
    var trigger: Trigger {
        didSet { defaults.set(trigger.rawValue, forKey: Key.trigger) }
    }
    var shortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: Key.shortcut) }
    }
    /// ISO-639-1 code, or empty for Whisper's auto-detection.
    var language: String {
        didSet { defaults.set(language, forKey: Key.language) }
    }
    /// Comma-separated names and terms; see `Vocabulary`. Whisper's prompt limit is ~224 tokens.
    var vocabulary: String {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary) }
    }
    var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Key.playSounds) }
    }
    /// Off by default: it adds a second request per dictation, so it's slower and costs a little more.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled) }
    }
    var cleanupModel: TextCleanup.Model {
        didSet { defaults.set(cleanupModel.rawValue, forKey: Key.cleanupModel) }
    }
    /// Rewrite rules for AI cleanup, one per line; see `Replacements`.
    var replacements: String {
        didSet { defaults.set(replacements, forKey: Key.replacements) }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// What you hold to dictate.
    enum Trigger: String, CaseIterable {
        case fn, shortcut
    }

    static let languages: [(code: String, name: String)] = [
        ("", "Auto-detect"),
        ("pl", "Polish"),
        ("en", "English"),
        ("de", "German"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("it", "Italian"),
        ("uk", "Ukrainian"),
    ]

    private enum Key {
        static let trigger = "trigger"
        static let shortcut = "shortcut"
        static let language = "language"
        static let vocabulary = "vocabulary"
        static let playSounds = "playSounds"
        static let cleanupEnabled = "cleanupEnabled"
        static let cleanupModel = "cleanupModel"
        static let replacements = "replacements"
    }

    /// Returns false if the keychain refused the write; the previous key then stays in place.
    func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Keychain.save(trimmed) else { return false }
        apiKey = trimmed
        return true
    }

    init() {
        let defaults = UserDefaults.standard
        apiKey = Keychain.read() ?? ""
        trigger = defaults.string(forKey: Key.trigger).flatMap(Trigger.init) ?? .fn
        shortcut = defaults.data(forKey: Key.shortcut)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        language = defaults.string(forKey: Key.language) ?? Self.systemLanguage
        vocabulary = defaults.string(forKey: Key.vocabulary) ?? ""
        playSounds = defaults.object(forKey: Key.playSounds) as? Bool ?? true
        cleanupEnabled = defaults.bool(forKey: Key.cleanupEnabled)
        cleanupModel = defaults.string(forKey: Key.cleanupModel).flatMap(TextCleanup.Model.init) ?? .gptOss
        replacements = defaults.string(forKey: Key.replacements) ?? ""
    }

    /// Defaults to the Mac's language when Skryba lists it; otherwise lets Whisper detect it.
    private static var systemLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? ""
        return languages.contains { $0.code == code } ? code : ""
    }
}
