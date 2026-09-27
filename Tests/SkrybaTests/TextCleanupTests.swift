import Testing
@testable import Skryba

struct TextCleanupTests {
    @Test func acceptsPunctuationAndSmallFixes() {
        #expect(TextCleanup.isFaithful(
            original: "no to może zrobimy to jutro rano",
            cleaned: "No to może zrobimy to jutro rano."
        ))
        #expect(TextCleanup.isFaithful(
            original: "chciałbym z twórz nowy plik w heartmade",
            cleaned: "Chciałbym stworzyć nowy plik w Heartmade."
        ))
    }

    @Test func acceptsRemovedFillersAndFalseStarts() {
        #expect(TextCleanup.isFaithful(original: "yyy eee yyy tak", cleaned: "Tak."))
        #expect(TextCleanup.isFaithful(
            original: "wyślij to do do Ani nie do Kasi",
            cleaned: "Wyślij to do Kasi."
        ))
    }

    @Test func rejectsAnswersSummariesAndAdditions() {
        // The model answered the dictated question instead of correcting it.
        #expect(!TextCleanup.isFaithful(original: "jaka jest stolica Francji", cleaned: "Stolicą Francji jest Paryż."))
        #expect(!TextCleanup.isFaithful(
            original: "napisz maila do klienta że spotkanie jest przesunięte",
            cleaned: "Oto mail: Szanowny Panie, uprzejmie informuję, że nasze spotkanie zostało przesunięte na inny termin."
        ))
        #expect(!TextCleanup.isFaithful(original: "dzień dobry wszystkim", cleaned: ""))
    }

    @Test func systemPromptCarriesTagsAndVocabulary() {
        let prompt = TextCleanup.systemPrompt(
            instructions: "Popraw tekst.", vocabulary: Vocabulary("Heartmade, Skryba"), language: "pl"
        )
        #expect(prompt.hasPrefix("Popraw tekst."))
        #expect(prompt.contains("<transcript>"))
        #expect(prompt.contains("Heartmade, Skryba."))

        let bare = TextCleanup.systemPrompt(instructions: "Fix it.", vocabulary: Vocabulary(""), language: "en")
        #expect(!bare.contains("frequent terms"))
    }

    @Test func unwrapsTaggedReplies() {
        #expect(TextCleanup.unwrap("<transcript>\nDzień dobry.\n</transcript>\n") == "Dzień dobry.")
        #expect(TextCleanup.unwrap("  Dzień dobry.  ") == "Dzień dobry.")
    }

    @Test func defaultInstructionsFollowTheLanguage() {
        #expect(TextCleanup.defaultInstructions(language: "pl").hasPrefix("Jesteś korektorem"))
        #expect(TextCleanup.defaultInstructions(language: "en").hasPrefix("You proofread"))
        #expect(TextCleanup.defaultInstructions(language: "").hasPrefix("You proofread"))
    }
}

struct TextCleanupFillerTests {
    /// The case from a real dictation: spoken fillers removed by the model must pass the guard.
    @Test func acceptsRemovedPolishFillerWords() {
        #expect(TextCleanup.isFaithful(
            original: "Zobaczę w ogóle, ile to użyję tych, no, tych, no, tokenów.",
            cleaned: "Zobaczę w ogóle, ile zużyję tokenów."
        ))
    }
}

struct TextCleanupInsertionTests {
    let vocabulary = Vocabulary("Heartmade,Hermes,Groq,Heartman,Paweł Jurewicz")

    /// The case from a real dictation: a vocabulary term appeared where nothing was said.
    @Test func catchesAnInsertedVocabularyTerm() {
        #expect(TextCleanup.insertsVocabulary(
            original: "To jest pierwszy tekst. Materializacja pałacu w Himalajach.",
            cleaned: "To jest pierwszy tekst. Heartmade, Materializacja pałacu w Himalajach.",
            vocabulary: vocabulary
        ))
    }

    @Test func allowsFixingAMisheardTerm() {
        #expect(!TextCleanup.insertsVocabulary(
            original: "pracuję w hartmejd od lat",
            cleaned: "Pracuję w Heartmade od lat.",
            vocabulary: vocabulary
        ))
        #expect(!TextCleanup.insertsVocabulary(
            original: "yyy no pracuję w Heartmade",
            cleaned: "Pracuję w Heartmade.",
            vocabulary: vocabulary
        ))
    }

    @Test func insertedWordsFindsOnlyAdditions() {
        #expect(TextCleanup.insertedWords(["a", "b", "c"], ["a", "x", "b", "c"]) == ["x"])
        #expect(TextCleanup.insertedWords(["a", "b", "c"], ["a", "y", "c"]).isEmpty)
        #expect(TextCleanup.insertedWords([], ["a"]) == ["a"])
    }
}
