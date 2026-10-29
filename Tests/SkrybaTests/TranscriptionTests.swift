import Testing
@testable import Skryba

struct TranscriptionTests {
    @Test(arguments: [TextCleanup.Model.gptOss, .cloudflareGptOss])
    func localFallbackSkipsTheConfiguredCloudCleanup(_ model: TextCleanup.Model) {
        let result = Transcription(text: "local transcript", source: .localFallback)
        #expect(result.cleanupModel(using: model, skipLocalFallback: true) == nil)
    }

    @Test(arguments: [TextCleanup.Model.gptOss, .cloudflareGptOss])
    func cleanupAfterFallbackRequiresExplicitOptIn(_ model: TextCleanup.Model) {
        let result = Transcription(text: "local transcript", source: .localFallback)
        #expect(result.cleanupModel(using: model, skipLocalFallback: false) == model)
    }

    @Test(arguments: [true, false])
    func primaryLocalTranscriptionNeverUsesCloudCleanup(_ skip: Bool) {
        let result = Transcription(text: "local transcript", source: .local)
        #expect(result.cleanupModel(using: .gptOss, skipLocalFallback: skip) == nil)
    }

    @Test(arguments: [true, false])
    func successfulCloudTranscriptionKeepsItsCleanup(_ skip: Bool) {
        let result = Transcription(text: "cloud transcript", source: .cloud(.groq))
        #expect(result.cleanupModel(using: .gptOss, skipLocalFallback: skip) == .gptOss)
        let cloudflare = Transcription(text: "cloud transcript", source: .cloud(.cloudflare))
        #expect(cloudflare.cleanupModel(using: .cloudflareGptOss, skipLocalFallback: skip) == .cloudflareGptOss)
    }

    @Test func changingProvidersDuringATakeDoesNotSendTextToAnotherCloud() {
        let result = Transcription(text: "cloud transcript", source: .cloud(.groq))
        #expect(result.cleanupModel(using: .cloudflareGptOss, skipLocalFallback: false) == nil)
    }
}
