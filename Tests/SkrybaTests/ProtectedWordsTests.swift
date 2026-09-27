import Testing
@testable import Skryba

struct ProtectedWordsTests {
    private func check(_ original: String, _ cleaned: String, language: String = "pl",
                       allowedNames: Set<String> = []) -> ProtectedWords.Violation? {
        ProtectedWords.violation(original: original, cleaned: cleaned, language: language, allowedNames: allowedNames)
    }

    // The four cases from the audit, all accepted by the word-count check alone.

    @Test func rejectsADroppedNegation() {
        #expect(check("Nie wysyłaj dokumentu do klienta.", "Wysyłaj dokument do klienta.") == .negation)
    }

    @Test func rejectsAChangedAmount() {
        #expect(check("Przelej 100 złotych na konto firmy.", "Przelej 900 złotych na konto firmy.") == .number)
    }

    @Test func rejectsAFlippedSign() {
        #expect(check("Wartość wynosi -5.", "Wartość wynosi 5.") == .number)
        #expect(check("Wartość wynosi 5.", "Wartość wynosi −5.") == .number)
    }

    @Test func rejectsASwappedName() {
        #expect(check("Wyślij ofertę do Ani jutro rano.", "Wyślij ofertę do Kasi jutro rano.") == .name)
    }

    // What cleanup is for must still pass.

    @Test func acceptsPunctuationCapitalisationAndFillers() {
        #expect(check("yyy nie wysyłaj tego do ani", "Nie wysyłaj tego do Ani.") == nil)
        #expect(check("przelej 100 zł, eee, do piątku", "Przelej 100 zł do piątku.") == nil)
    }

    @Test func acceptsASelfCorrection() {
        // Names and numbers may be dropped; a comma-set-off "nie" only marks the correction.
        #expect(check("Wyślij to do Ani, nie, do Kasi.", "Wyślij to do Kasi.") == nil)
        #expect(check("Przelej 100, nie, 200 złotych.", "Przelej 200 złotych.") == nil)
    }

    @Test func aBareCorrectionMarkerStaysProtected() {
        // Without commas the "nie" can't be told apart from a real negation, so the plain transcript wins.
        #expect(check("wyślij to do Ani nie do Kasi", "Wyślij to do Kasi.") == .negation)
    }

    @Test func aStutteredNegationCountsOnce() {
        #expect(check("nie nie wysyłaj tego", "Nie wysyłaj tego.") == nil)
        #expect(check("Nie, nie wysyłaj tego.", "Nie wysyłaj tego.") == nil)
    }

    @Test func rejectsAnAddedNegation() {
        #expect(check("Wysyłaj dokument.", "Nie wysyłaj dokumentu.") == .negation)
        #expect(check("I will send it.", "I won't send it.", language: "en") == .negation)
    }

    @Test func negationsDependOnTheLanguage() {
        // Polish "no" is a filler; English "no" is a negation.
        #expect(check("no to wysyłaj", "To wysyłaj.") == nil)
        #expect(check("There is no problem.", "There is a problem.", language: "en") == .negation)
        #expect(check("There is no problem.", "There is a problem.", language: "") == .negation)
    }

    @Test func rangesAndHyphensAreNotSigns() {
        #expect(check("od 5-10 osób", "Od 5-10 osób.") == nil)
        #expect(check("wariant COVID-19", "Wariant COVID-19.") == nil)
    }

    @Test func namesFromVocabularyOrInstructionsAreAllowed() {
        #expect(check("pracuję w hartmejd", "Pracuję w Heartmade.", allowedNames: ["heartmade"]) == nil)
        #expect(check("pracuję w hartmejd", "Pracuję w Heartmade.") == .name)
    }

    @Test func capitalisedSentenceStartsPass() {
        #expect(check("dobrze. jutro wyślę", "Dobrze. Jutro wyślę.") == nil)
        #expect(check("zolty samochod", "Żółty samochód.") == nil)
    }

    // The second audit: meaning changes that kept every protected word, just not in its place.

    @Test func rejectsSwappedAmounts() {
        #expect(check("Przelej 100 zł Ani i 900 zł Kasi.", "Przelej 900 zł Ani i 100 zł Kasi.") == .number)
    }

    @Test func rejectsSwappedNames() {
        #expect(check("Wyślij dokument Ani, a kopię Kasi.", "Wyślij dokument Kasi, a kopię Ani.") == .name)
    }

    @Test func rejectsANameChangedAtTheStartOfASentence() {
        #expect(check("Ania wysłała dokument do klienta.", "Kasia wysłała dokument do klienta.") == .name)
    }

    @Test func rejectsAChangedNumberWord() {
        #expect(check("Przelej sto złotych na konto firmy.", "Przelej dziewięćset złotych na konto firmy.") == .number)
        #expect(check("Send two copies.", "Send three copies.", language: "en") == .number)
    }

    @Test func rejectsDroppedNamesAndNumbersWithoutACorrection() {
        #expect(check("Wyślij ofertę do Ani i Kasi jutro rano.", "Wyślij ofertę do Ani jutro rano.") == .name)
        #expect(check("Przelej 100 zł i 200 zł.", "Przelej 100 zł.") == .number)
    }

    @Test func acceptsOtherSelfCorrectionsAndRepeats() {
        #expect(check("Przelej 100 znaczy 200 zł.", "Przelej 200 zł.") == nil)
        #expect(check("przelej sto, nie, dwieście złotych", "Przelej dwieście złotych.") == nil)
        #expect(check("wyślij to do Ani Ani jutro", "Wyślij to do Ani jutro.") == nil)
    }

    @Test func aNameCleanupLowercasedIsNotDropped() {
        #expect(check("wyślij to do Pana Kowalskiego", "Wyślij to do pana Kowalskiego.") == nil)
    }

    @Test func aFixedWordAtASentenceStartFallsBack() {
        // Indistinguishable from a changed name, so the plain transcript wins (the documented trade-off).
        #expect(check("morze to zrobię jutro", "Może to zrobię jutro.") == .name)
    }
}
