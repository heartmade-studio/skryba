import Foundation
import Observation

/// User preferences. Everything lives in UserDefaults except API credentials, which go to the keychain.
@MainActor @Observable
final class Settings {
    /// Mirrors the keychain; change it only through `saveAPIKey`.
    private(set) var apiKey: String
    /// Mirrors the keychain; change it only through `saveCloudflareToken`.
    private(set) var cloudflareToken: String
    /// What turns speech into text. There is no chain between providers: one is used, plus local
    /// Whisper as an optional fallback for the cloud ones.
    var provider: TranscriptionProvider {
        didSet { defaults.set(provider.rawValue, forKey: Key.provider) }
    }
    var cloudflareAccountID: String {
        didSet { defaults.set(cloudflareAccountID, forKey: Key.cloudflareAccountID) }
    }
    /// Off by default. When on, whisper.cpp transcribes on this Mac if a cloud provider can't be
    /// reached. Irrelevant when local Whisper is the provider.
    var localWhisperEnabled: Bool {
        didSet { defaults.set(localWhisperEnabled, forKey: Key.localWhisperEnabled) }
    }
    /// Empty means Homebrew's usual location.
    var whisperExecutablePath: String {
        didSet { defaults.set(whisperExecutablePath, forKey: Key.whisperExecutablePath) }
    }
    var whisperModelPath: String {
        didSet { defaults.set(whisperModelPath, forKey: Key.whisperModelPath) }
    }
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

    enum TranscriptionProvider: String, CaseIterable, Identifiable {
        case groq, cloudflare
        /// whisper.cpp on this Mac: audio never leaves it.
        case local

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .groq: "Groq"
            case .cloudflare: "Cloudflare Workers AI"
            case .local: "Local Whisper (this Mac)"
            }
        }
    }

    /// The chosen provider has what it needs: credentials, or whisper-cli and a model.
    var isProviderConfigured: Bool {
        switch provider {
        case .groq: !apiKey.isEmpty
        case .cloudflare: CloudflareClient.isValidAccountID(cloudflare.accountID) && !cloudflareToken.isEmpty
        case .local: localWhisper.setupProblem == nil
        }
    }

    /// Local Whisper steps in for a cloud provider that can't be reached.
    var usesLocalFallback: Bool {
        provider != .local && localWhisperEnabled
    }

    /// A take can be turned into text somehow, now or later.
    var canTranscribe: Bool {
        isProviderConfigured || usesLocalFallback
    }

    /// What to tell the user when the provider isn't set up.
    var setupHint: String {
        provider == .local
            ? "Choose whisper-cli and a model in Settings → Offline."
            : "Add your \(provider.displayName) credentials in Settings."
    }

    var cloudflare: CloudflareClient {
        CloudflareClient(accountID: cloudflareAccountID.trimmingCharacters(in: .whitespacesAndNewlines), apiToken: cloudflareToken)
    }

    var localWhisper: LocalWhisper {
        LocalWhisper(executablePath: whisperExecutablePath, modelPath: whisperModelPath)
    }

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
        static let provider = "provider"
        static let cloudflareAccountID = "cloudflareAccountID"
        static let localWhisperEnabled = "localWhisperEnabled"
        static let whisperExecutablePath = "whisperExecutablePath"
        static let whisperModelPath = "whisperModelPath"
    }

    /// Returns false if the keychain refused the write; the previous key then stays in place.
    func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Keychain.save(trimmed, for: .groq) else { return false }
        apiKey = trimmed
        return true
    }

    /// Returns false if the keychain refused the write; the previous token then stays in place.
    func saveCloudflareToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Keychain.save(trimmed, for: .cloudflare) else { return false }
        cloudflareToken = trimmed
        return true
    }

    init() {
        let defaults = UserDefaults.standard
        apiKey = Keychain.read(.groq) ?? ""
        cloudflareToken = Keychain.read(.cloudflare) ?? ""
        provider = defaults.string(forKey: Key.provider).flatMap(TranscriptionProvider.init) ?? .groq
        cloudflareAccountID = defaults.string(forKey: Key.cloudflareAccountID) ?? ""
        localWhisperEnabled = defaults.bool(forKey: Key.localWhisperEnabled)
        whisperExecutablePath = defaults.string(forKey: Key.whisperExecutablePath) ?? ""
        whisperModelPath = defaults.string(forKey: Key.whisperModelPath) ?? ""
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
