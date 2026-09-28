import Foundation
import Testing
@testable import Skryba

struct TranscriptionRoutingTests {
    @MainActor @Test func failoverExecutorMeasuresProviderAttemptOverhead() async throws {
        enum ProviderFailure: Error { case unavailable }

        var samples: [Double] = []
        for _ in 0..<25 {
            let start = ContinuousClock.now
            let result = await TranscriptionRouting.firstSuccessful(
                routes: [.groq, .localWhisper],
                operation: { route in
                    if route == .groq { throw ProviderFailure.unavailable }
                    return "synthetic transcript"
                },
                accepts: { !$0.isEmpty }
            )
            let duration = start.duration(to: .now)
            let components = duration.components
            samples.append(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
            #expect(result?.route == .localWhisper)
            #expect(result?.value == "synthetic transcript")
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        print(String(format: "PERF fallback executor: n=%d median=%.3fms p95=%.3fms; injected primary failure + successful local provider", samples.count, median, p95))
        #expect(p95 < 1000, "Injected failover execution should not add a perceptible one-second delay")
    }

    @Test func groqPrimaryFallsBackLocallyThenToConfiguredCloudflare() {
        #expect(TranscriptionRouting.providers(
            primary: .groq,
            groqConfigured: true,
            localFallbackEnabled: true,
            cloudflareEnabled: true,
            cloudflareConfigured: true,
            allowCloudFallbackWhenLocal: false
        ) == [.groq, .localWhisper, .cloudflare])
        #expect(TranscriptionRouting.providers(
            primary: .groq,
            groqConfigured: true,
            localFallbackEnabled: false,
            cloudflareEnabled: false,
            cloudflareConfigured: true,
            allowCloudFallbackWhenLocal: false
        ) == [.groq])
        #expect(TranscriptionRouting.providers(
            primary: .groq,
            groqConfigured: true,
            localFallbackEnabled: false,
            cloudflareEnabled: true,
            cloudflareConfigured: false,
            allowCloudFallbackWhenLocal: false
        ) == [.groq])
    }

    @Test func localPrimaryStaysLocalUnlessCloudFallbackIsExplicitlyAllowed() {
        #expect(TranscriptionRouting.providers(
            primary: .localWhisper,
            groqConfigured: true,
            localFallbackEnabled: false,
            cloudflareEnabled: true,
            cloudflareConfigured: true,
            allowCloudFallbackWhenLocal: false
        ) == [.localWhisper])
        #expect(TranscriptionRouting.providers(
            primary: .localWhisper,
            groqConfigured: true,
            localFallbackEnabled: false,
            cloudflareEnabled: true,
            cloudflareConfigured: true,
            allowCloudFallbackWhenLocal: true
        ) == [.localWhisper, .groq, .cloudflare])
        #expect(TranscriptionRouting.providers(
            primary: .localWhisper,
            groqConfigured: false,
            localFallbackEnabled: false,
            cloudflareEnabled: false,
            cloudflareConfigured: true,
            allowCloudFallbackWhenLocal: true
        ) == [.localWhisper])
    }

    @Test func commandArgumentsKeepPathsAsArgumentsWithoutShellParsing() {
        let model = URL(fileURLWithPath: "/Models/My multilingual model.bin")
        let audio = URL(fileURLWithPath: "/tmp/clip with spaces.wav")
        let output = URL(fileURLWithPath: "/tmp/private output/transcript")
        let args = LocalWhisperTranscriber.whisperArguments(
            model: model, audio: audio, language: "auto", prompt: "names here", outputBase: output
        )
        #expect(args.contains("/Models/My multilingual model.bin"))
        #expect(args.contains("/tmp/clip with spaces.wav"))
        #expect(args.contains("/tmp/private output/transcript"))
        #expect(args.contains("names here"))
    }

    @Test func cloudflareDecodesNestedTextAndRejectsUnsuccessfulResponses() throws {
        let valid = Data(#"{"success":true,"result":{"text":"hello"}}"#.utf8)
        #expect(try CloudflareTranscriber.decodeResponse(valid) == "hello")

        let failed = Data(#"{"success":false,"result":{"text":""}}"#.utf8)
        #expect(throws: (any Error).self) { try CloudflareTranscriber.decodeResponse(failed) }
    }
}
