import Foundation

/// Align a suffix with a prefix, independent of Whisper's sometimes drifting word timestamps.
/// Matching uses lowercase lexical words; output is sliced from the untouched Unicode strings.
enum TranscriptJoiner {
    /// Counts and a fixed reason only. This may be logged; the text must never be logged.
    struct Analysis {
        let text: String?
        let reason: String
        let leftTokens: Int
        let rightTokens: Int
        let score: Int
        let matches: Int
        let edits: Int
        let partials: Int

        var summary: String {
            "reason=\(reason) left_tokens=\(leftTokens) right_tokens=\(rightTokens) score=\(score) matches=\(matches) edits=\(edits) partials=\(partials)"
        }
    }

    private struct Candidate {
        let score: Int
        let pairs: [(Int, Int)]
        let edits: Int
        let partials: Int
        let reason: String
    }
    private struct Token {
        let key: String
        let range: Range<String.Index>
    }

    private struct Cell {
        var score: Int
        var step: Step
    }

    private enum Step { case match, partial, substitute, left, right, start }

    private static func tokens(_ text: String) -> [Token] {
        text.ranges(of: #/[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*/#).map {
            Token(key: text[$0].lowercased().replacingOccurrences(of: "’", with: "'"), range: $0)
        }
    }

    /// A six-second audio overlap normally contains several matching words. Allow one recognition
    /// error only when at least three exact matches corroborate it. A lone repeated word is ambiguous.
    static func join(_ left: String, _ right: String) -> String? {
        analyze(left, right).text
    }

    static func analyze(_ left: String, _ right: String) -> Analysis {
        let a = Array(tokens(left).suffix(32))
        let b = Array(tokens(right).prefix(32))
        func report(_ text: String?, _ candidate: Candidate?, reason: String? = nil) -> Analysis {
            Analysis(text: text, reason: reason ?? candidate?.reason ?? "no_positive_alignment",
                     leftTokens: a.count, rightTokens: b.count, score: candidate?.score ?? 0,
                     matches: candidate?.pairs.count ?? 0, edits: candidate?.edits ?? 0, partials: candidate?.partials ?? 0)
        }
        guard !a.isEmpty, !b.isEmpty else { return report(nil, nil, reason: "empty_side") }
        var table = Array(repeating: Array(repeating: Cell(score: 0, step: .start), count: b.count + 1), count: a.count + 1)
        // Free leading words on the left; every word at the beginning of the right must be accounted for.
        for j in 1...b.count { table[0][j] = Cell(score: -4 * j, step: .right) }
        for i in 1...a.count {
            for j in 1...b.count {
                let equal = a[i - 1].key == b[j - 1].key
                // Only an audio edge may contain a cut-off word. Keep the complete spelling on
                // the other side by choosing an exact neighbouring word as the final splice.
                let partial = !equal && (
                    (i == a.count && a[i - 1].key.count >= 2 && b[j - 1].key.hasPrefix(a[i - 1].key))
                    || (j == 1 && b[j - 1].key.count >= 2 && a[i - 1].key.hasSuffix(b[j - 1].key))
                )
                var best = Cell(score: table[i - 1][j - 1].score + (equal ? 3 : partial ? 1 : -4),
                                step: equal ? .match : partial ? .partial : .substitute)
                if table[i - 1][j].score - 4 > best.score {
                    best = Cell(score: table[i - 1][j].score - 4, step: .left)
                }
                if table[i][j - 1].score - 4 > best.score {
                    best = Cell(score: table[i][j - 1].score - 4, step: .right)
                }
                table[i][j] = best
            }
        }

        var selected: Candidate?
        var bestRejected: Candidate?
        // The alignment must reach the end of the left, and may consume only a prefix of the right.
        for end in 1...b.count where table[a.count][end].score > 0 {
            var i = a.count
            var j = end
            var pairs: [(Int, Int)] = []
            var edits = 0
            var partials = 0
            while j > 0 {
                switch table[i][j].step {
                case .match: pairs.append((i - 1, j - 1)); i -= 1; j -= 1
                case .partial: partials += 1; i -= 1; j -= 1
                case .substitute: edits += 1; i -= 1; j -= 1
                case .left: edits += 1; i -= 1
                case .right: edits += 1; j -= 1
                case .start: j = 0
                }
            }
            pairs.reverse()
            let distinct = Set(pairs.map { a[$0.0].key })
            let corroborated = pairs.count >= 2 && distinct.count >= 2
            let single = pairs.count == 1 && edits == 0 && partials == 0
                && a[pairs[0].0].key.count >= 4
                && a.count { $0.key == a[pairs[0].0].key } == 1
                && b.count { $0.key == a[pairs[0].0].key } == 1
            let score = table[a.count][end].score
            let reason: String
            if !corroborated && !single {
                reason = pairs.count >= 2 && distinct.count < 2 ? "ambiguous_repeated_words" : "insufficient_matches"
            } else if partials > 1 {
                reason = "multiple_partial_words"
            } else if !(edits == 0 || (pairs.count >= 3 && edits <= max(1, pairs.count / 6))) {
                reason = "too_many_edits"
            } else {
                reason = "accepted"
            }
            let candidate = Candidate(score: score, pairs: pairs, edits: edits, partials: partials, reason: reason)
            if reason == "accepted" {
                if selected == nil || score > selected!.score { selected = candidate }
            } else if bestRejected == nil || score > bestRejected!.score {
                bestRejected = candidate
            }
        }
        guard let selected else { return report(nil, bestRejected) }
        let anchor = selected.pairs[selected.pairs.count / 2]
        // Keep the original separator too: inserting a space here would turn CLAUDE.md into
        // CLAUDE. md if the anchor happens to be the second lexical token of an identifier.
        let prefix = left[..<a[anchor.0].range.lowerBound]
        let suffix = right[b[anchor.1].range.lowerBound...]
        return report((prefix + suffix).trimmingCharacters(in: .whitespacesAndNewlines), selected)
    }
}
