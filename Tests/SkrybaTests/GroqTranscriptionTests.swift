import Foundation
import Testing
@testable import Skryba

struct GroqTranscriptionTests {
    /// A `verbose_json` reply with one segment per (text, avg_logprob, compression_ratio, no_speech_prob).
    func reply(_ segments: [(String, Double, Double, Double)]) throws -> GroqClient.Transcription {
        let items = segments.map { text, logprob, ratio, noSpeech in
            ["text": text, "avg_logprob": logprob, "compression_ratio": ratio, "no_speech_prob": noSpeech] as [String: Any]
        }
        let json = ["text": segments.map(\.0).joined(), "segments": items] as [String: Any]
        return try GroqClient.Transcription.decode(JSONSerialization.data(withJSONObject: json))
    }

    @Test func confidentSegmentsAreNotDoubtful() throws {
        let transcript = try reply([(" Dzień dobry.", -0.2, 1.3, 0.01), (" Co słychać?", -0.4, 1.1, 0.02)])
        #expect(transcript.doubtfulSegments == 0)
        #expect(transcript.speechText == "Dzień dobry. Co słychać?")
    }

    @Test func lowConfidenceOrRepetitionIsDoubtful() throws {
        let unsure = try reply([(" zastanawiam si czy", -1.3, 1.4, 0.05)])
        let looping = try reply([(" tak tak tak tak tak", -0.3, 3.1, 0.05)])
        #expect(unsure.doubtfulSegments == 1)
        #expect(looping.doubtfulSegments == 1)
    }

    @Test func silenceIsDroppedNotRetried() throws {
        let transcript = try reply([(" Dzień dobry.", -0.2, 1.3, 0.01), (" Dziękuję za uwagę.", -1.4, 1.0, 0.9)])
        #expect(transcript.doubtfulSegments == 0)
        #expect(transcript.speechText == "Dzień dobry.")
    }

    @Test func keepsTheTranscriptWithFewerDoubtfulSegments() throws {
        let first = try reply([(" a", -0.2, 1.2, 0), (" b", -1.4, 1.2, 0)])
        let fixed = try reply([(" a", -0.3, 1.2, 0), (" b", -0.5, 1.2, 0)])
        let worse = try reply([(" a", -1.1, 1.2, 0), (" b", -1.2, 1.2, 0)])
        #expect(GroqClient.Transcription.better(first, fixed) === fixed)
        #expect(GroqClient.Transcription.better(first, worse) === first)
    }

    @Test func aTieGoesToTheHigherWorstSegmentThenToTheFirst() throws {
        let first = try reply([(" a", -1.6, 1.2, 0)])
        let less = try reply([(" a", -1.2, 1.2, 0)])
        let same = try reply([(" a", -1.6, 1.2, 0)])
        #expect(GroqClient.Transcription.better(first, less) === less)
        #expect(GroqClient.Transcription.better(first, same) === first)
    }

    @Test func summaryHasNumbersButNoWords() throws {
        let transcript = try reply([(" tajne słowa", -1.25, 2.5, 0.1)])
        #expect(transcript.confidenceSummary == "count=1 doubtful=1 lowest_avg_logprob=-1.25 highest_compression_ratio=2.50")
    }

    @Test func replyWithoutSegmentsFallsBackToText() throws {
        let data = Data(#"{"text": "  Krótko. "}"#.utf8)
        let transcript = try GroqClient.Transcription.decode(data)
        #expect(transcript.speechText == "Krótko.")
        #expect(transcript.doubtfulSegments == 0)
    }
}
