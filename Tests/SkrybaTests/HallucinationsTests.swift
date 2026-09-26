import Testing
@testable import Skryba

struct HallucinationsTests {
    let prompt = Vocabulary("Heartmade").prompt

    @Test func dropsStockPhrasesFromNearSilentClips() {
        #expect(Hallucinations.isLikely("Dziękuję za uwagę!", prompt: "", voicedDuration: 0.3))
        #expect(Hallucinations.isLikely("Napisy stworzone przez społeczność Amara.org", prompt: "", voicedDuration: 0.5))
        #expect(Hallucinations.isLikely("Thanks for watching.", prompt: "", voicedDuration: 0.2))
    }

    @Test func keepsStockPhrasesThatWereActuallySpoken() {
        #expect(!Hallucinations.isLikely("Dziękuję za uwagę!", prompt: "", voicedDuration: 1.4))
        #expect(!Hallucinations.isLikely("Thank you for watching.", prompt: "", voicedDuration: 1.1))
    }

    @Test func dropsAnEchoedPromptOnlyFromNearSilentClips() {
        #expect(Hallucinations.isLikely("Heartmade.", prompt: prompt, voicedDuration: 0.3))
        #expect(!Hallucinations.isLikely("Heartmade.", prompt: prompt, voicedDuration: 0.9))
    }

    @Test func keepsOrdinaryText() {
        #expect(!Hallucinations.isLikely("To jest zwykłe zdanie.", prompt: prompt, voicedDuration: 0.3))
        #expect(!Hallucinations.isLikely("Dziękuję za uwagę, Aniu, i do jutra.", prompt: "", voicedDuration: 0.3))
    }
}
