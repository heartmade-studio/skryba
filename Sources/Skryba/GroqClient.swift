import Foundation
import os

/// Minimal client for Groq's OpenAI-compatible API: speech-to-text, and chat for the optional cleanup.
/// Docs: https://console.groq.com/docs/speech-to-text, https://console.groq.com/docs/text-chat
struct GroqClient: ChatClient {
    static let transcriptionEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    static let chatEndpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    /// The full model, not turbo: turbo misheard names and English terms in Polish dictation
    /// ("Heartman" → "Hrp Noan"). It costs more ($0.111 vs $0.04 per hour) and is a little slower.
    static let model = "whisper-large-v3"

    let apiKey: String
    var transport: URLSession = Self.session

    /// Ephemeral: no cookies, cache or credentials are written to disk.
    private static let session = URLSession(configuration: .ephemeral)
    private static let log = Logger(subsystem: "pl.heartmade.skryba", category: "network")

    /// Whisper's own fallback temperature for a doubtful result (it steps 0.2, 0.4, … up to 1.0).
    /// A little randomness gets the decoder out of the rut it fell into at temperature 0.
    static let retryTemperature = 0.2
    static let maximumPartRepairs = 2

    /// Long takes use independent windows, so a bad decode after a pause can't carry through the
    /// rest of the recording. All parts still share the caller's cancellable retry deadline.
    func transcribe(fileURL: URL, language: String, prompt: String, dictationID: String = UUID().uuidString) async throws -> String {
        let chunks = try AudioChunks.prepare(fileURL)
        defer { chunks.remove() }
        let chunked = chunks.parts.count > 1
        var replies: [(transcript: Transcription, from: Double, until: Double)] = []
        var detectedLanguage = language
        let run = dictationID
        let pauseJoins = chunks.parts.dropFirst().count { $0.from == 0 }
        Self.log.notice("groq audio parts: count=\(chunks.parts.count) pause_joins=\(pauseJoins) run=\(run, privacy: .public)")
        for (index, part) in chunks.parts.enumerated() {
            try Task.checkCancellation()
            let transcript = try await transcribePart(
                part.url, language: detectedLanguage, prompt: prompt
            )
            // Auto-detect once, rather than letting an English name or a pause change the next
            // part's language. An unrecognised provider value simply leaves auto-detection on.
            if detectedLanguage.isEmpty { detectedLanguage = transcript.languageCode ?? "" }
            Self.log.notice(
                "groq audio part decoded: run=\(run, privacy: .public) part=\(index + 1) characters=\(transcript.speechText.count) segments=\(transcript.segments?.count ?? 0) from_ms=\(Retry.milliseconds(.seconds(part.from))) until_ms=\(Retry.milliseconds(.seconds(part.until))) voiced_ms=\(Retry.milliseconds(.seconds(part.voicedDuration)))"
            )
            replies.append((transcript, part.from, part.until))
        }
        if !chunked { return replies[0].transcript.speechText }
        var repaired: Set<Int> = []
        while true {
            try Task.checkCancellation()
            do {
                let text = try Transcription.join(replies) { boundary, summary in
                    Self.log.notice("groq seam analysis: run=\(run, privacy: .public) boundary=\(boundary) \(summary, privacy: .public)")
                }
                Self.log.notice("groq audio joined: run=\(run, privacy: .public) parts=\(replies.count) pause_joins=\(pauseJoins) method=text_overlap part_repairs=\(repaired.count)")
                return text
            } catch let failure as Transcription.JoinFailure {
                guard repaired.count < Self.maximumPartRepairs,
                      let index = Transcription.partToRepair(at: failure.boundary, transcripts: replies.map(\.transcript),
                                                           voiced: chunks.parts.map(\.voicedDuration), repaired: repaired) else {
                    Self.log.notice("groq part repair exhausted: run=\(run, privacy: .public) boundary=\(failure.boundary)")
                    throw failure // AppController keeps the original for a manual retry.
                }
                repaired.insert(index)
                let part = chunks.parts[index]
                Self.log.notice("groq part repair started: run=\(run, privacy: .public) boundary=\(failure.boundary) part=\(index + 1) before_characters=\(replies[index].transcript.speechText.count)")
                // A failed overlap can mean one decode omitted speech. Retry only that part at
                // Whisper's fallback temperature; never upload the whole original on this path.
                let candidate = try await transcription(of: part.url, language: detectedLanguage, prompt: prompt,
                                                        temperature: Self.retryTemperature)
                try Task.checkCancellation()
                if !candidate.speechText.isEmpty { replies[index].transcript = candidate }
                Self.log.notice("groq part repair completed: run=\(run, privacy: .public) part=\(index + 1) candidate_characters=\(candidate.speechText.count)")
            }
        }
    }

    /// Groq doesn't do Whisper's temperature fallback itself. Retry a doubtful part once and keep
    /// the better result; never discard a usable first reply just because the second request failed.
    private func transcribePart(_ file: URL, language: String, prompt: String) async throws -> Transcription {
        let first = try await transcription(of: file, language: language, prompt: prompt, temperature: 0)
        Self.log.notice("groq segments: \(first.confidenceSummary, privacy: .public)")
        guard first.doubtfulSegments > 0 else { return first }

        let second: Transcription
        do {
            second = try await transcription(of: file, language: language, prompt: prompt, temperature: Self.retryTemperature)
        } catch where !Retry.isCancellation(error) {
            // The first transcript is still usable; a failed second opinion must not lose it.
            Self.log.notice("groq confidence retry failed: \(Retry.failureKind(for: error), privacy: .public)")
            return first
        }
        let kept = Transcription.better(first, second)
        Self.log.notice(
            "groq confidence retry: \(second.confidenceSummary, privacy: .public) kept=\(kept === second ? "retry" : "first", privacy: .public)"
        )
        return kept
    }

    private func transcription(of fileURL: URL, language: String, prompt: String, temperature: Double) async throws -> Transcription {
        let boundary = "Skryba-\(UUID().uuidString)"
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", Self.model)
        // verbose_json adds per-segment confidence: used to drop hallucinated silence and to spot
        // garbled segments worth a retry.
        field("response_format", "verbose_json")
        field("temperature", String(temperature))
        if !language.isEmpty { field("language", language) }
        if !prompt.isEmpty { field("prompt", prompt) }

        let wav = fileURL.pathExtension == "wav"
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(wav ? "wav" : "m4a")\"\r\n")
        body.append("Content-Type: \(wav ? "audio/wav" : "audio/mp4")\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n")

        let data = try await send(
            to: Self.transcriptionEndpoint,
            contentType: "multipart/form-data; boundary=\(boundary)",
            body: body,
            timeout: 30,
            label: "transcription"
        )
        return try Transcription.decode(data)
    }

    /// One chat completion; returns the reply text.
    func chat(_ request: ChatRequest) async throws -> String {
        let data = try await send(
            to: Self.chatEndpoint,
            contentType: "application/json",
            body: try request.encoded(),
            timeout: ChatRequest.timeout,
            label: "chat \(request.model)"
        )
        if let usage = ChatRequest.usageSummary(from: data) {
            Self.log.info("groq chat usage: \(usage, privacy: .public)")
        }
        return try ChatRequest.replyText(from: data)
    }

    private func send(to url: URL, contentType: String, body: Data, timeout: TimeInterval, label: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let started = ContinuousClock.now
        let (data, response) = try await transport.upload(for: request, from: body)
        Self.log.notice("groq \(label, privacy: .public): \(body.count / 1024) KB, \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        guard let http = response as? HTTPURLResponse else {
            throw SkrybaError.api(provider: "Groq", status: 0, message: "No response.")
        }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw SkrybaError.api(provider: "Groq", status: http.statusCode, message: message)
        }
        return data
    }

    /// A `verbose_json` reply. A class, so `transcribe` can tell which of two replies it kept.
    final class Transcription: Decodable, Sendable {
        let text: String
        let segments: [Segment]?
        let language: String?

        var languageCode: String? {
            guard let language else { return nil }
            let english = Locale(identifier: "en")
            return Locale.LanguageCode.isoLanguageCodes.first { code in
                code.identifier.count == 2 && (code.identifier == language.lowercased()
                    || english.localizedString(forLanguageCode: code.identifier)?.lowercased() == language.lowercased())
            }?.identifier
        }

        static func decode(_ data: Data) throws -> Transcription {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Transcription.self, from: data)
        }

        struct Segment: Decodable {
            let text: String
            let noSpeechProb: Double?
            let avgLogprob: Double?
            let compressionRatio: Double?
            let start: Double?
            let end: Double?

            /// Whisper's own silence rule: likely no speech *and* low confidence. See also `Hallucinations`.
            var isLikelySilence: Bool {
                (noSpeechProb ?? 0) > 0.6 && (avgLogprob ?? 0) < -1.0
            }

            /// Whisper's own thresholds for retrying a window at a higher temperature: the model was
            /// unsure of its words, or it repeated itself (text that compresses too well).
            var isDoubtful: Bool {
                !isLikelySilence && ((avgLogprob ?? 0) < -1.0 || (compressionRatio ?? 0) > 2.4)
            }
        }

        /// The segments that end up in the transcript.
        private var speech: [Segment] { (segments ?? []).filter { !$0.isLikelySilence } }

        var speechText: String {
            guard let segments, !segments.isEmpty else {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return speech.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Audio overlap is matched as text, not as a pair of clocks. The same utterance can have
        /// very different word timestamps in two independent decodes, including zero-duration words.
        static func join(_ parts: [(transcript: Transcription, from: Double, until: Double)],
                         onBoundary: ((Int, String) -> Void)? = nil) throws -> String {
            guard let first = parts.first else { return "" }
            var result = first.transcript.speechText
            var previousHadSpeech = !result.isEmpty
            for (offset, part) in parts.dropFirst().enumerated() {
                let next = part.transcript.speechText
                if next.isEmpty {
                    onBoundary?(offset + 1, "reason=empty_part")
                    previousHadSpeech = false
                    continue
                }
                if part.from == 0 || !previousHadSpeech {
                    onBoundary?(offset + 1, "reason=consecutive_audio")
                    result = [result, next].filter { !$0.isEmpty }.joined(separator: " ")
                } else {
                    let analysis = TranscriptJoiner.analyze(result, next)
                    onBoundary?(offset + 1, analysis.summary)
                    guard let joined = analysis.text else {
                        throw JoinFailure(boundary: offset + 1)
                    }
                    result = joined
                }
                previousHadSpeech = true
            }
            return result
        }

        struct JoinFailure: LocalizedError {
            /// Index of the right-hand part, also the one-based boundary number.
            let boundary: Int
            var errorDescription: String? { "Could not align transcription parts \(boundary) and \(boundary + 1)." }
        }

        /// Prefer a suspiciously short decode relative to measured speech, not relative to file
        /// length: a long pause followed by a short closing sentence is legitimately sparse.
        static func partToRepair(at boundary: Int, transcripts: [Transcription], voiced: [TimeInterval],
                                 repaired: Set<Int>) -> Int? {
            guard boundary > 0, boundary < transcripts.count, voiced.count == transcripts.count else { return nil }
            return [boundary - 1, boundary].filter { !repaired.contains($0) }.min { a, b in
                let densityA = voiced[a] >= 0.3 ? Double(transcripts[a].speechText.count) / voiced[a] : .infinity
                let densityB = voiced[b] >= 0.3 ? Double(transcripts[b].speechText.count) / voiced[b] : .infinity
                if densityA != densityB { return densityA < densityB }
                if transcripts[a].lowestLogprob != transcripts[b].lowestLogprob {
                    return transcripts[a].lowestLogprob < transcripts[b].lowestLogprob
                }
                return a < b
            }
        }

        var doubtfulSegments: Int { speech.count { $0.isDoubtful } }

        /// The least confident segment's score; 0 when there is nothing to judge.
        var lowestLogprob: Double { speech.compactMap(\.avgLogprob).min() ?? 0 }

        /// Fewer doubtful segments wins; on a tie, the higher worst-segment confidence. The first one
        /// (temperature 0) wins a full tie.
        static func better(_ first: Transcription, _ second: Transcription) -> Transcription {
            if second.speechText.isEmpty, !first.speechText.isEmpty { return first }
            if second.doubtfulSegments != first.doubtfulSegments {
                return second.doubtfulSegments < first.doubtfulSegments ? second : first
            }
            return second.lowestLogprob > first.lowestLogprob ? second : first
        }

        /// Numbers only, never the dictated words: enough to tune the thresholds from the log.
        var confidenceSummary: String {
            let highestCompression = speech.compactMap(\.compressionRatio).max() ?? 0
            return "count=\(speech.count) doubtful=\(doubtfulSegments) "
                + "lowest_avg_logprob=\(Self.decimal(lowestLogprob)) highest_compression_ratio=\(Self.decimal(highestCompression))"
        }

        /// Two decimals with a dot, whatever the Mac's locale, so the logs read the same everywhere.
        private static func decimal(_ value: Double) -> String {
            String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable { let message: String }
        let error: Body
    }
}

enum SkrybaError: LocalizedError {
    case recordingFailed
    case api(provider: String, status: Int, message: String)
    case incompleteReply(reason: String)

    var errorDescription: String? {
        switch self {
        case .recordingFailed:
            "Could not start recording."
        case .api(let provider, let status, let message) where status == 401 || status == 403:
            "\(provider) rejected the credentials (\(message)). Check them in Settings."
        case .api(let provider, _, let message):
            "\(provider): \(message)"
        case .incompleteReply(let reason):
            "The reply was incomplete (\(reason))."
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
