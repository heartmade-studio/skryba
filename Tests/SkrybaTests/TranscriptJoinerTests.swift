import Testing
@testable import Skryba

struct TranscriptJoinerTests {
    @Test func preservesPolishLettersAndOriginalPunctuation() {
        #expect(TranscriptJoiner.join("To już działa, żółć!", "już działa, żółć! Dalej.")
                == "To już działa, żółć! Dalej.")
    }

    @Test func aCutOffTrailingWordIsTakenWholeFromTheNextPart() {
        #expect(TranscriptJoiner.join("Dziś rano już dzia", "rano już działa, żółć!")
                == "Dziś rano już działa, żółć!")
    }

    @Test func aCutOffLeadingWordIsTakenWholeFromThePreviousPart() {
        #expect(TranscriptJoiner.join("Dziś rano już działa, żółć!", "ano już działa, żółć! Dalej.")
                == "Dziś rano już działa, żółć! Dalej.")
    }

    @Test func oneMisheardWordNeedsSeveralExactMatchesAroundIt() {
        #expect(TranscriptJoiner.join("To bardzo ważne spotkanie dziś rano.", "ważne zebranie dziś rano. Już czekam.")
                == "To bardzo ważne spotkanie dziś rano. Już czekam.")
    }

    @Test func repeatedWordsArePreservedWithTheirContext() {
        #expect(TranscriptJoiner.join("Zrób to teraz, teraz, proszę.", "teraz, proszę. Już gotowe.")
                == "Zrób to teraz, teraz, proszę. Już gotowe.")
        #expect(TranscriptJoiner.join("Tak, tak, tak.", "tak, tak, tak.") == nil)
    }

    @Test func unrelatedOrAccentStrippedTextIsNotSilentlySpliced() {
        #expect(TranscriptJoiner.join("To już działa.", "Inne zdanie na jutro.") == nil)
        #expect(TranscriptJoiner.join("Żółć już działa.", "zolc juz dziala.") == nil)
        #expect(TranscriptJoiner.join("To ju", "już działa.") == nil)
    }

    @Test func anAnchorInsideAFileNameOrAddressDoesNotIntroduceSpaces() {
        #expect(TranscriptJoiner.join("Otwórz plik CLAUDE.md", "CLAUDE.md, potem sprawdź.")
                == "Otwórz plik CLAUDE.md, potem sprawdź.")
        #expect(TranscriptJoiner.join("Wyślij do pawel@example.com", "pawel@example.com dziś.")
                == "Wyślij do pawel@example.com dziś.")
    }

    @Test func distantSharedWordsAreNotEnoughToRemoveInterveningText() {
        #expect(TranscriptJoiner.join("To ważne. Potem omawiamy zupełnie inny temat.",
                                     "To ważne. Teraz rozpoczynamy spotkanie.") == nil)
    }

    @Test func diagnosticsExplainRejectionWithoutIncludingAnyTranscript() {
        let result = TranscriptJoiner.analyze("Tak, tak, tak.", "tak, tak, tak.")
        #expect(result.reason == "ambiguous_repeated_words")
        #expect(result.matches == 3)
        #expect(result.text == nil)
        #expect(!result.summary.lowercased().contains("tak"))
        let unrelated = TranscriptJoiner.analyze("Pierwsza wypowiedź.", "Ostatnie zakończenie.")
        #expect(unrelated.reason == "no_positive_alignment")
        #expect(!unrelated.summary.contains("wypowiedź"))
    }
}
