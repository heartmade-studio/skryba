import Testing
@testable import Skryba

/// What Settings → Test shows. It has to fit the form, whatever the provider sent.
@MainActor
struct SettingsTestResultTests {
    private func shown(_ text: String) -> String {
        AppController.testResult(text, took: "1.2 sec")
    }

    @Test func aTranscriptIsShownWithItsTime() {
        #expect(shown("Dzień dobry.") == "“Dzień dobry.” · 1.2 sec")
    }

    @Test func itIsOneLineWithoutHiddenCharacters() {
        #expect(shown("Dzień\ndobry\u{202E}.") == "“Dzień dobry.” · 1.2 sec")
    }

    @Test func onlyInvisibleTextIsNothingHeard() {
        #expect(shown("\u{200B}\n") == "Heard nothing (1.2 sec). Speak while it listens.")
    }

    @Test func anOversizedReplyIsReportedAsInDictation() {
        #expect(shown(String(repeating: "a", count: 50_001)) == "The transcript was too long to be real, so it wasn't used. (1.2 sec)")
    }

    /// Within the dictation limit is still far too much for a form.
    @Test func aLongReplyIsShortened() {
        for text in [String(repeating: "słowo ", count: 5000), "a" + String(repeating: "\u{301}", count: 40_000)] {
            let result = shown(text)
            #expect(result.unicodeScalars.count < 340)
            #expect(result.hasSuffix("…” · 1.2 sec"))
        }
    }
}
