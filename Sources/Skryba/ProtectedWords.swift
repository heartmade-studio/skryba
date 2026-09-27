import Foundation

/// Words where a single change flips the meaning of a sentence: numbers, negations and names.
///
/// The word-count check in `TextCleanup.isFaithful` can't see these: "Nie wysyłaj" → "Wysyłaj",
/// "100 zł" → "900 zł" or "do Ani" → "do Kasi" each change just one word. So AI cleanup gets
/// stricter rules for them:
///
/// - **Numbers** may be dropped (a self-correction removes the wrong one) but never added or changed,
///   including the sign: `-5` → `5` is rejected.
/// - **Negations** must stay exactly as many. A stutter ("nie nie") counts once, and a "nie"/"no" that
///   only marks a self-correction (", nie, do Kasi") doesn't count.
/// - **Names** (capitalised words mid-sentence) may be dropped but never introduced, unless they come
///   from the user's vocabulary or cleanup instructions.
enum ProtectedWords {
    enum Violation: String {
        case number, negation, name
    }

    /// The first rule `cleaned` breaks, or nil if it keeps every protected word.
    static func violation(
        original: String, cleaned: String, language: String, allowedNames: Set<String>
    ) -> Violation? {
        let before = tokens(original), after = tokens(cleaned)

        let originalNumbers = counts(before.filter(\.isNumber).map(\.text))
        for (number, count) in counts(after.filter(\.isNumber).map(\.text))
        where count > originalNumbers[number, default: 0] {
            return .number
        }

        // "ani" is a negation, "Ani" a name (Ania). A word used as a name in either text is left out.
        let names = Set((before + after).filter(\.isName).map { $0.text.lowercased() })
        let negationWords = negations(for: language).subtracting(names)
        if negationCount(before, negationWords) != negationCount(after, negationWords) {
            return .negation
        }

        let knownWords = Set(before.map { $0.text.lowercased() }).union(allowedNames)
        for token in after where token.isName && !knownWords.contains(token.text.lowercased()) {
            return .name
        }
        return nil
    }

    // MARK: Tokens

    struct Token {
        let text: String
        let isNumber: Bool
        /// Punctuation and spaces between the previous token and this one.
        let gapBefore: Substring
        var gapAfter: Substring = ""

        var isName: Bool {
            guard !isNumber, text.count > 1, let first = text.first, first.isUppercase else { return false }
            return !isSentenceStart
        }

        var isSentenceStart: Bool {
            gapBefore.isEmpty || gapBefore.contains(where: { ".!?…:\n".contains($0) })
        }
    }

    static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var cursor = text.startIndex
        for match in text.matches(of: #/[-−]?\d+(?:[.,]\d+)*|\p{L}+(?:['’]\p{L}+)*/#) {
            let gap = text[cursor..<match.range.lowerBound]
            var word = String(text[match.range])
            let isNumber = word.last?.isNumber ?? false
            if isNumber {
                word = word.replacingOccurrences(of: "−", with: "-")
                // A dash glued to the previous word is a hyphen or range ("5-10", "COVID-19"), not a sign.
                if word.hasPrefix("-"), gap.isEmpty, !result.isEmpty {
                    word.removeFirst()
                }
            }
            if !result.isEmpty { result[result.count - 1].gapAfter = gap }
            result.append(Token(text: word, isNumber: isNumber, gapBefore: result.isEmpty ? "" : gap))
            cursor = match.range.upperBound
        }
        if !result.isEmpty { result[result.count - 1].gapAfter = text[cursor...] }
        return result
    }

    private static func counts(_ items: [String]) -> [String: Int] {
        items.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    // MARK: Negations

    private static func negationCount(_ tokens: [Token], _ words: Set<String>) -> Int {
        var count = 0
        var previous: String?
        for token in tokens {
            let word = token.text.lowercased()
            defer { previous = word }
            guard isNegation(word, words) else { continue }
            // "nie, nie wysyłaj": a repeated negation is one negation.
            if word == previous, token.gapBefore.allSatisfy({ $0.isWhitespace || $0 == "," }) { continue }
            // "do Ani, nie, do Kasi": a negation set off on both sides only marks a self-correction.
            if isSetOff(token.gapBefore), isSetOff(token.gapAfter) { continue }
            count += 1
        }
        return count
    }

    private static func isSetOff(_ gap: Substring) -> Bool {
        gap.contains(where: { ",;–—-".contains($0) })
    }

    private static func isNegation(_ word: String, _ words: Set<String>) -> Bool {
        words.contains(word) || (words.contains("not") && (word.hasSuffix("n't") || word.hasSuffix("n’t")))
    }

    static func negations(for language: String) -> Set<String> {
        negationsByLanguage[language] ?? negationsByLanguage.values.reduce(into: Set()) { $0.formUnion($1) }
    }

    /// Per language, because a negation in one is a filler in another: English "no" vs Polish "no".
    private static let negationsByLanguage: [String: Set<String>] = [
        "pl": ["nie", "ani", "nigdy", "nic", "niczego", "nikt", "nikogo", "żaden", "żadna", "żadne",
               "żadnego", "żadnej", "żadnych", "bez"],
        "en": ["not", "no", "never", "none", "nothing", "nobody", "neither", "nor", "without", "cannot"],
        "de": ["nicht", "kein", "keine", "keinen", "keinem", "keiner", "nie", "niemals", "nichts",
               "niemand", "ohne"],
        "es": ["no", "nunca", "nada", "nadie", "ni", "sin", "jamás"],
        "fr": ["ne", "pas", "jamais", "rien", "personne", "sans", "aucun", "aucune"],
        "it": ["non", "mai", "niente", "nulla", "nessuno", "senza", "né"],
        "uk": ["не", "ні", "ніколи", "нічого", "ніхто", "без"],
    ]
}
