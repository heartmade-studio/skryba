import Foundation

/// Catches text Whisper invents when it hears (almost) nothing.
///
/// Whisper learned from subtitled video, so on near-silence it tends to produce subtitle outros
/// ("Dziękuję za uwagę!", "Thanks for watching") or to echo its prompt back. The same words can also be
/// said on purpose, so a match counts only when the clip held little actual voice.
enum Hallucinations {
    /// Saying one of these phrases deliberately takes longer than this; invented ones come from
    /// clips with a cough, a click or background noise.
    static let voicedDurationLimit: TimeInterval = 0.8

    private static let stockPhrases: Set<String> = [
        "dziękuję za uwagę",
        "dziękuję za obejrzenie",
        "dzięki za obejrzenie",
        "napisy stworzone przez społeczność amaraorg",
        "thank you for watching",
        "thanks for watching",
        "subtitles by the amaraorg community",
    ]

    static func isLikely(_ text: String, prompt: String, voicedDuration: TimeInterval) -> Bool {
        guard voicedDuration < voicedDurationLimit else { return false }
        let normalized = normalize(text)
        return stockPhrases.contains(normalized) || (!prompt.isEmpty && normalized == normalize(prompt))
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
