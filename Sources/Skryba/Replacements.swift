import Foundation

/// The user's rewrite rules for AI cleanup, one per line: how a phrase is said, and how it should be
/// written.
///
///     claude md → CLAUDE.md
///     pawel małpa heartmade pl -> pawel@heartmade.pl
///
/// The model applies them, so it also catches variants that speech recognition spelled differently
/// ("klod md"). The guard in `TextCleanup` allows exactly these rewrites and nothing else.
struct Replacements {
    struct Rule: Equatable {
        let spoken: String
        let written: String
    }

    let rules: [Rule]

    init(_ raw: String) {
        rules = raw.split(whereSeparator: \.isNewline).compactMap { line in
            guard let arrow = line.range(of: "→") ?? line.range(of: "->") else { return nil }
            let spoken = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let written = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            return spoken.isEmpty || written.isEmpty ? nil : Rule(spoken: spoken, written: written)
        }
    }
}
