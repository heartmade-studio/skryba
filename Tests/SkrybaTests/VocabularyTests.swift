import Testing
@testable import Skryba

struct VocabularyTests {
    let vocabulary = Vocabulary("Heartmade,Hermes,Groq,Heartman,Paweł Jurewicz")

    @Test func parsesCommaSeparatedTermsIntoANaturalPrompt() {
        #expect(vocabulary.terms == ["Heartmade", "Hermes", "Groq", "Heartman", "Paweł Jurewicz"])
        #expect(vocabulary.prompt == "Heartmade, Hermes, Groq, Heartman, Paweł Jurewicz.")
        #expect(Vocabulary("  ").prompt == "")
    }

    @Test func fixesNearMisses() {
        #expect(vocabulary.correct("Pracuję w Hrtmade od lat.") == "Pracuję w Heartmade od lat.")
        #expect(vocabulary.correct("hertmade") == "Heartmade")
        #expect(vocabulary.correct("Hermez działa.") == "Hermes działa.")
    }

    @Test func keepsPolishCaseEndings() {
        #expect(vocabulary.correct("Rozmawiałem z Hrtmadem.") == "Rozmawiałem z Heartmadem.")
    }

    @Test func fixesMultiWordTerms() {
        #expect(vocabulary.correct("Nazywam się Paweł Jurewic.") == "Nazywam się Paweł Jurewicz.")
    }

    @Test func leavesCorrectAndInflectedTermsAlone() {
        #expect(vocabulary.correct("Heartman i Heartmade") == "Heartman i Heartmade")
        #expect(vocabulary.correct("Dzięki Heartmanowi") == "Dzięki Heartmanowi")
    }

    @Test func leavesUnrelatedWordsAlone() {
        let text = "Grok to nie Groq, a herbata to nie Hermes. Mam hart ducha."
        #expect(vocabulary.correct(text) == text)
    }

    @Test func editDistance() {
        #expect(Vocabulary.editDistance("hrtmade", "heartmade") == 2)
        #expect(Vocabulary.editDistance("", "abc") == 3)
        #expect(Vocabulary.editDistance("same", "same") == 0)
    }
}
