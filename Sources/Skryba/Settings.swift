import Foundation
import Observation

/// User preferences. Everything lives in UserDefaults except the API key, which goes to the keychain.
@MainActor @Observable
final class Settings {
    /// Mirrors the keychain; change it only through `saveAPIKey`.
    private(set) var apiKey: String
    private(set) var cloudflareToken: String
    var primaryTranscriptionProvider: TranscriptionProvider {
        didSet { defaults.set(primaryTranscriptionProvider.rawValue, forKey: Key.primaryTranscriptionProvider) }
    }
    var localFallbackEnabled: Bool {
        didSet { defaults.set(localFallbackEnabled, forKey: Key.localFallbackEnabled) }
    }
    var allowCloudFallbackWhenLocal: Bool {
        didSet { defaults.set(allowCloudFallbackWhenLocal, forKey: Key.allowCloudFallbackWhenLocal) }
    }
    var whisperCLIPath: String {
        didSet { defaults.set(whisperCLIPath, forKey: Key.whisperCLIPath) }
    }
    var ffmpegPath: String {
        didSet { defaults.set(ffmpegPath, forKey: Key.ffmpegPath) }
    }
    var whisperModelPath: String {
        didSet { defaults.set(whisperModelPath, forKey: Key.whisperModelPath) }
    }
    var cloudflareAccountID: String {
        didSet { defaults.set(cloudflareAccountID, forKey: Key.cloudflareAccountID) }
    }
    var cloudflareFallbackEnabled: Bool {
        didSet { defaults.set(cloudflareFallbackEnabled, forKey: Key.cloudflareFallbackEnabled) }
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

    var providerSummary: String {
        let cloudflare: String
        if !cloudflareFallbackEnabled {
            cloudflare = "Cloudflare fallback off"
        } else if isCloudflareConfigured {
            cloudflare = "Cloudflare fallback enabled"
        } else {
            cloudflare = "Cloudflare fallback needs Account ID and token"
        }
        let primary = primaryTranscriptionProvider == .groq ? "Groq" : "Local Whisper"
        return "Primary: \(primary) · \(cloudflare)"
    }

    var localWhisperStatus: String {
        LocalWhisperTranscriber.preflight(cliPath: whisperCLIPath, ffmpegPath: ffmpegPath, modelPath: whisperModelPath)
    }

    var localWhisperReady: Bool { localWhisperStatus.hasPrefix("Ready") }

    var configuredTranscriptionRoutes: [TranscriptionRoute] {
        TranscriptionRouting.providers(
            primary: primaryTranscriptionProvider,
            groqConfigured: !apiKey.isEmpty,
            localFallbackEnabled: localFallbackEnabled && localWhisperReady,
            cloudflareEnabled: cloudflareFallbackEnabled,
            cloudflareConfigured: isCloudflareConfigured,
            allowCloudFallbackWhenLocal: allowCloudFallbackWhenLocal
        )
    }

    var canStartTranscription: Bool {
        if primaryTranscriptionProvider == .localWhisper, !localWhisperReady {
            return allowCloudFallbackWhenLocal && ( !apiKey.isEmpty || (cloudflareFallbackEnabled && isCloudflareConfigured) )
        }
        return !configuredTranscriptionRoutes.isEmpty
    }

    var isCloudflareConfigured: Bool {
        let id = cloudflareAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil && !cloudflareToken.isEmpty
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
        static let cloudflareAccountID = "cloudflareAccountID"
        static let cloudflareFallbackEnabled = "cloudflareFallbackEnabled"
        static let primaryTranscriptionProvider = "primaryTranscriptionProvider"
        static let localFallbackEnabled = "localFallbackEnabled"
        static let allowCloudFallbackWhenLocal = "allowCloudFallbackWhenLocal"
        static let whisperCLIPath = "whisperCLIPath"
        static let ffmpegPath = "ffmpegPath"
        static let whisperModelPath = "whisperModelPath"
    }

    /// Returns false if the keychain refused the write; the previous key then stays in place.
    func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Keychain.saveGroqKey(trimmed) else { return false }
        apiKey = trimmed
        return true
    }

    func saveCloudflareToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Keychain.saveCloudflareToken(trimmed) else { return false }
        cloudflareToken = trimmed
        return true
    }

    init() {
        let defaults = UserDefaults.standard
        apiKey = Keychain.readGroqKey() ?? ""
        cloudflareToken = Keychain.readCloudflareToken() ?? ""
        primaryTranscriptionProvider = defaults.string(forKey: Key.primaryTranscriptionProvider)
            .flatMap(TranscriptionProvider.init(rawValue:)) ?? .groq
        localFallbackEnabled = defaults.object(forKey: Key.localFallbackEnabled) as? Bool ?? true
        allowCloudFallbackWhenLocal = defaults.bool(forKey: Key.allowCloudFallbackWhenLocal)
        whisperCLIPath = defaults.string(forKey: Key.whisperCLIPath) ?? LocalWhisperTranscriber.defaultCLIPath()
        ffmpegPath = defaults.string(forKey: Key.ffmpegPath) ?? LocalWhisperTranscriber.defaultFFmpegPath()
        whisperModelPath = defaults.string(forKey: Key.whisperModelPath) ?? LocalWhisperTranscriber.defaultModelPath()
        cloudflareAccountID = defaults.string(forKey: Key.cloudflareAccountID) ?? ""
        cloudflareFallbackEnabled = defaults.bool(forKey: Key.cloudflareFallbackEnabled)
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
