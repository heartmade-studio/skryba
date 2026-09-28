import Foundation
import Testing
@testable import Skryba

struct ReplacementsTests {
    @Test func parsesOneRulePerLine() {
        let replacements = Replacements("""
            claude md → CLAUDE.md

            pawel małpa heartmade pl -> pawel@heartmade.pl
            no arrow here
             → nothing said
            """)
        #expect(replacements.rules == [
            .init(spoken: "claude md", written: "CLAUDE.md"),
            .init(spoken: "pawel małpa heartmade pl", written: "pawel@heartmade.pl"),
        ])
    }
}

struct TextCleanupPromptTests {
    @Test func carriesTagsAndRules() {
        let prompt = TextCleanup.systemPrompt(replacements: Replacements("claude md → CLAUDE.md"), language: "pl")
        #expect(prompt.contains("<transcript>"))
        #expect(prompt.contains("- claude md → CLAUDE.md"))

        let bare = TextCleanup.systemPrompt(replacements: Replacements(""), language: "en")
        #expect(bare.hasPrefix("You edit"))
        #expect(!bare.contains("Replacement list"))
    }

    @Test func unwrapsTaggedReplies() {
        #expect(TextCleanup.unwrap("<transcript>\nDzień dobry.\n</transcript>\n") == "Dzień dobry.")
        #expect(TextCleanup.unwrap("  Dzień dobry.  ") == "Dzień dobry.")
    }
}

struct TextCleanupGuardTests {
    let replacements = Replacements("""
        claude md → CLAUDE.md
        pawel małpa heartmade pl → pawel@heartmade.pl
        """)

    private func allowed(_ original: String, _ cleaned: String) -> Bool {
        TextCleanup.isAllowed(original: original, cleaned: cleaned, replacements: replacements)
    }

    @Test func allowsRemovedHesitationsPunctuationAndCase() {
        #expect(allowed("yyy no więc jutro eee jadę do warszawy", "No więc jutro jadę do Warszawy."))
        #expect(allowed("Hrm, hrm, co ja tam jeszcze mam?", "Co ja tam jeszcze mam?"))
        #expect(allowed("zolty samochod", "Żółty samochód."))
        // A real GPT-OSS reply that left the hesitations in.
        #expect(allowed("Hrm, hrm, co ja tam mam?", "Hrm, hrm, co ja tam mam?"))
    }

    @Test func allowsReplacements() {
        #expect(allowed("otwórz plik claude md", "Otwórz plik CLAUDE.md."))
        #expect(allowed("otwórz plik klod md", "Otwórz plik CLAUDE.md."))
        #expect(allowed("napisz na pawel małpa heartmade pl", "Napisz na pawel@heartmade.pl"))
        #expect(allowed("Napisz na Paweł, małpa, Heartmade PL.", "Napisz na pawel@heartmade.pl."))
        // Already written right by Whisper.
        #expect(allowed("otwórz CLAUDE.md", "Otwórz CLAUDE.md"))
    }

    @Test func rejectsEveryOtherChange() {
        // Only hesitations may go, not filler words.
        #expect(!allowed("no więc jutro jadę", "Więc jutro jadę."))
        // A real Qwen reply that invented a word.
        #expect(!allowed("yyy no więc jutro rano", "W jutro rano."))
        // The swap seen in a real dictation.
        #expect(!allowed("Pracuję w Heartmade.", "Pracuję w Hermes."))
        #expect(!allowed("wyślij to do Ani", "Wyślij to."))
        #expect(!allowed("Możesz to pomóc mi sprawdzić?", "Czy możesz mi pomóc to sprawdzić?"))
        #expect(!allowed("jaka jest stolica Francji", "Stolicą Francji jest Paryż."))
        #expect(!allowed("dzień dobry wszystkim", ""))
    }

    @Test func aReplacementCannotStandForOtherWords() {
        #expect(!allowed("otwórz plik", "Otwórz plik CLAUDE.md."))
        #expect(!allowed("otwórz plik konfiguracji", "Otwórz plik CLAUDE.md."))
    }
}

struct GroqReplyTests {
    private func reply(_ json: String) throws -> String {
        try GroqClient.replyText(from: Data(json.utf8))
    }

    @Test func returnsACompleteReply() throws {
        #expect(try reply(#"{"choices":[{"message":{"content":"Tak."},"finish_reason":"stop"}]}"#) == "Tak.")
        #expect(try reply(#"{"choices":[{"message":{"content":"Tak."}}]}"#) == "Tak.")
    }

    @Test func rejectsACutOffReply() {
        #expect(throws: SkrybaError.self) {
            try reply(#"{"choices":[{"message":{"content":"Przygotuj dokument i"},"finish_reason":"length"}]}"#)
        }
    }
}
