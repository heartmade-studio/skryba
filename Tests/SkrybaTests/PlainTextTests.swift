import Testing
@testable import Skryba

struct PlainTextTests {
    /// Regression: whisper-cli ends every segment with a line break, which a terminal may run.
    @Test func lineBreaksBecomeSpaces() {
        #expect(PlainText.singleLine("Pierwsze zdanie.\n Drugie zdanie.\n") == "Pierwsze zdanie. Drugie zdanie.")
        for separator in ["\r", "\r\n", "\n\n", "\t", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            #expect(PlainText.singleLine("a\(separator)b") == "a b", "separator: \(separator.unicodeScalars.map(\.value))")
        }
        #expect(PlainText.singleLine(" \n\r\n\t ") == "")
    }

    @Test func hiddenControlsAreRemoved() {
        #expect(PlainText.singleLine("a\u{1B}[201~b") == "a[201~b")
        #expect(PlainText.singleLine("a\u{03}\u{00}\u{7F}\u{9B}b") == "ab")
        #expect(PlainText.singleLine("a\u{202E}\u{2066}\u{200B}\u{FEFF}\u{E0041}b") == "ab")
    }

    @Test func ordinaryWritingIsUntouched() {
        for text in [
            "Zażółć gęślą jaźń: „tak”, powiedział.", "e\u{301}", "👩‍💻 ❤️ 🇵🇱",
            "می\u{200C}خواهم", "two  spaces", "x = a | b; echo $HOME",
        ] {
            #expect(Array(PlainText.singleLine(text).unicodeScalars) == Array(text.unicodeScalars))
        }
    }

    @Test func aPreviewIsBoundedInScalars() {
        #expect(PlainText.preview("Zażółć", limit: 40) == "Zażółć")
        #expect(PlainText.preview("abcdef", limit: 3) == "abc…")
        #expect(PlainText.preview("a" + String(repeating: "\u{301}", count: 10_000), limit: 40).unicodeScalars.count == 41)
    }

    /// The guard judges the text that is pasted, so cleaning it again at the paste must change nothing.
    @Test func cleaningTwiceChangesNothingMore() {
        for text in ["a \u{200B}\nb", "\u{200B} a \n", "a\r\u{200B}\nb"] {
            let once = PlainText.singleLine(text)
            #expect(PlainText.singleLine(once) == once)
        }
    }
}
