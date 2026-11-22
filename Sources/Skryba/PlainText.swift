import Foundation

/// Text from outside Skryba (a provider's reply, whisper-cli's output), made safe to paste.
enum PlainText {
    /// One line, without invisible control characters.
    ///
    /// A pasted line break runs the line as a command in a shell without bracketed paste, and
    /// whisper-cli puts one after every segment, so a break here is never something the user said.
    /// Escape sequences, direction overrides and invisible "tag" letters can hide what is pasted.
    /// The joiners that emoji, Persian and Indic scripts need are kept.
    static func singleLine(_ text: String) -> String {
        var visible = String.UnicodeScalarView()
        visible.append(contentsOf: text.unicodeScalars.filter { !isHidden($0) })
        return String(visible)
            .split { $0.isNewline || $0 == "\t" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x85: false // tab and line breaks; they become spaces
        case 0x00...0x1F, 0x7F...0x9F: true // controls, including Escape
        case 0x202A...0x202E, 0x2066...0x2069: true // direction overrides
        case 0x200B, 0x2060...0x2064, 0xFEFF: true // zero width
        case 0xE0000...0xE007F: true // invisible tag letters
        default: false
        }
    }
}
