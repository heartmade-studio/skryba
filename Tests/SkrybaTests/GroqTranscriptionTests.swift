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

    @Test func anEmptyRetryCannotReplaceADoubtfulButUsableTranscript() throws {
        let first = try reply([("Już działa.", -1.2, 1.2, 0)])
        let empty = try reply([])
        #expect(GroqClient.Transcription.better(first, empty) === first)
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

    private func timedReply(_ text: String, _ words: [(String, Double, Double)]) throws -> GroqClient.Transcription {
        let items = words.map { ["word": $0.0, "start": $0.1, "end": $0.2] as [String: Any] }
        let json = ["text": text, "words": items, "language": "polish"] as [String: Any]
        return try GroqClient.Transcription.decode(JSONSerialization.data(withJSONObject: json))
    }

    @Test(arguments: [(23.9, 1.1), (24.1, 0.9), (0.0, 0.0), (10.0, 8.0)])
    func joiningUsesWordsRatherThanIndependentOrZeroDurationClocks(_ times: (Double, Double)) throws {
        let left = try timedReply("To już działa, żółć!", [
            ("To", 0, 0), ("już", times.0, times.0), ("działa", times.0, times.0), ("żółć", times.0, times.0),
        ])
        let right = try timedReply("już działa, żółć! Dalej.", [
            ("już", times.1, times.1), ("działa", times.1, times.1), ("żółć", times.1, times.1), ("Dalej", times.1, times.1),
        ])
        #expect(try GroqClient.Transcription.join([(left, 0, 20), (right, 3, 23)]) == "To już działa, żółć! Dalej.")
    }

    @Test func joiningDoesNotNeedWordTimestampMetadata() throws {
        let left = try reply([("To już działa, żółć!", -0.2, 1, 0)])
        let right = try reply([("już działa, żółć! Dalej.", -0.2, 1, 0)])
        #expect(try GroqClient.Transcription.join([(left, 0, 20), (right, 3, 23)]) == "To już działa, żółć! Dalej.")
    }

    @Test func anUncertainJoinStillDoesNotReturnFragments() throws {
        let left = try reply([("To ju", -0.2, 1, 0)])
        let right = try reply([("już działa.", -0.2, 1, 0)])
        #expect(throws: GroqClient.Transcription.JoinFailure.self) {
            try GroqClient.Transcription.join([(left, 0, 20), (right, 3, 23)])
        }
    }

    @Test func confirmedPauseKeepsBothUtterancesWithoutRequiringACommonWord() throws {
        let left = try reply([("To już działa.", -0.2, 1, 0)])
        let right = try reply([("Żółć pozostaje.", -0.2, 1, 0)])
        #expect(try GroqClient.Transcription.join([(left, 0, 19.925), (right, 0, 19.623)])
                == "To już działa. Żółć pozostaje.")
    }

    @Test func joiningStillFiltersHallucinatedSilence() throws {
        let left = try reply([("To już działa, żółć!", -0.2, 1, 0), (" Dziękuję za uwagę.", -1.4, 1, 0.9)])
        let right = try reply([("już działa, żółć! Dalej.", -0.2, 1, 0)])
        #expect(try GroqClient.Transcription.join([(left, 0, 20), (right, 3, 23)])
                == "To już działa, żółć! Dalej.")
    }

    @Test func anEmptyMiddlePartDoesNotDeduplicateUtterancesAcrossALongPause() throws {
        let speech = try reply([("To już działa.", -0.2, 1, 0)])
        let silence = try reply([])
        #expect(try GroqClient.Transcription.join([(speech, 0, 20), (silence, 3, 23), (speech, 3, 23)])
                == "To już działa. To już działa.")
    }

    @Test func repairSelectionUsesMeasuredSpeechRatherThanLongPauses() throws {
        let sparse = try reply([("Krótki wynik.", -0.09, 1, 0)])
        let closing = try reply([("Już kończę nagranie.", -0.22, 1, 0)])
        // The sparse result covers 12 seconds of speech; the closing only one second of speech.
        #expect(GroqClient.Transcription.partToRepair(at: 1, transcripts: [sparse, closing], voiced: [12, 1], repaired: []) == 0)
        #expect(GroqClient.Transcription.partToRepair(at: 1, transcripts: [sparse, closing], voiced: [12, 1], repaired: [0]) == 1)
        #expect(GroqClient.Transcription.partToRepair(at: 1, transcripts: [sparse, closing], voiced: [12, 1], repaired: [0, 1]) == nil)
    }
}
