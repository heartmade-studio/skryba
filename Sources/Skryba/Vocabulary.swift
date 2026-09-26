import Foundation

/// The user's list of names and terms, used in two ways:
///
/// 1. As Whisper's `prompt`. Whisper reads it as "text that came before", so it is only a soft nudge
///    toward those spellings (and a weak one in the turbo model).
/// 2. As a deterministic fix-up afterwards: words that are a near miss for a term ("Hrtmade") are
///    replaced by it, keeping Polish case endings ("Hrtmadem" → "Heartmadem").
struct Vocabulary {
    let terms: [String]

    init(_ raw: String) {
        terms = raw
            .split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A plain enumeration reads to Whisper like natural preceding text.
    var prompt: String {
        terms.isEmpty ? "" : terms.joined(separator: ", ") + "."
    }

    /// Terms shorter than this are skipped by `correct`: too many real words sit one letter away ("Groq"/"Grok").
    private static let minimumTermLength = 5
    /// Inflection endings tolerated after a term, e.g. -u, -em, -owi.
    private static let maximumSuffixLength = 3

    func correct(_ text: String) -> String {
        let candidates = terms.filter { $0.count >= Self.minimumTermLength }
        guard !candidates.isEmpty else { return text }

        let words = text.ranges(of: #/\p{L}+/#)
        var result = ""
        var cursor = text.startIndex
        var index = 0
        while index < words.count {
            if let match = bestMatch(at: index, words: words, in: text, candidates: candidates) {
                result += text[cursor..<words[index].lowerBound] + match.term
                cursor = match.stemEnd // any case ending after the stem is kept as spoken
                index += match.wordCount
            } else {
                index += 1
            }
        }
        return result + text[cursor...]
    }

    private struct Match {
        let term: String
        let wordCount: Int
        let stemEnd: String.Index
        let distance: Int
    }

    private func bestMatch(
        at index: Int, words: [Range<String.Index>], in text: String, candidates: [String]
    ) -> Match? {
        var best: Match?
        for term in candidates {
            let wordCount = term.split(separator: " ").count
            guard index + wordCount <= words.count else { continue }
            // A multi-word term must match consecutive words separated only by spaces.
            let gaps = (index..<index + wordCount - 1).map { text[words[$0].upperBound..<words[$0 + 1].lowerBound] }
            guard gaps.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) else { continue }

            let start = words[index].lowerBound
            let end = words[index + wordCount - 1].upperBound
            let lastWordLength = text[words[index + wordCount - 1]].count
            for suffix in 0...min(Self.maximumSuffixLength, lastWordLength - 1) {
                let stemEnd = text.index(end, offsetBy: -suffix)
                let stem = String(text[start..<stemEnd]).lowercased()
                let target = term.lowercased()
                let distance = Self.editDistance(stem, target)
                // Already correct (possibly inflected) or another term entirely: leave the words alone.
                if distance == 0 { return nil }
                guard distance <= Self.allowedDistance(for: term), stem.first == target.first else { continue }
                if best == nil || distance < best!.distance {
                    best = Match(term: term, wordCount: wordCount, stemEnd: stemEnd, distance: distance)
                }
            }
        }
        return best
    }

    private static func allowedDistance(for term: String) -> Int {
        term.count >= 8 ? 2 : 1
    }

    /// Levenshtein distance: the number of single-character edits turning `a` into `b`.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            previous = current
        }
        return previous[b.count]
    }
}
