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

    /// Ephemeral: no cookies, cache or credentials are written to disk.
    private static let session = URLSession(configuration: .ephemeral)
    private static let log = Logger(subsystem: "pl.heartmade.skryba", category: "network")

    /// Whisper's own fallback temperature for a doubtful result (it steps 0.2, 0.4, … up to 1.0).
    /// A little randomness gets the decoder out of the rut it fell into at temperature 0.
    static let retryTemperature = 0.2

    /// Transcribes at temperature 0. If a segment looks garbled (see `Segment.isDoubtful`), sends the
    /// whole recording once more with a little randomness and keeps the better of the two.
    /// Groq doesn't do this fallback itself, unlike the open-source Whisper.
    func transcribe(fileURL: URL, language: String, prompt: String) async throws -> String {
        let first = try await transcription(of: fileURL, language: language, prompt: prompt, temperature: 0)
        Self.log.info("groq segments: \(first.confidenceSummary, privacy: .public)")
        guard first.doubtfulSegments > 0 else { return first.speechText }

        let second: Transcription
        do {
            second = try await transcription(of: fileURL, language: language, prompt: prompt, temperature: Self.retryTemperature)
        } catch where !Retry.isCancellation(error) {
            // The first transcript is still usable; a failed second opinion must not lose it.
            Self.log.notice("groq confidence retry failed: \(Retry.failureKind(for: error), privacy: .public)")
            return first.speechText
        }
        let kept = Transcription.better(first, second)
        Self.log.info(
            "groq confidence retry: \(second.confidenceSummary, privacy: .public) kept=\(kept === second ? "retry" : "first", privacy: .public)"
        )
        return kept.speechText
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

        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        body.append("Content-Type: audio/mp4\r\n\r\n")
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
        let (data, response) = try await Self.session.upload(for: request, from: body)
        Self.log.info("groq \(label, privacy: .public): \(body.count / 1024) KB, \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
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

        var doubtfulSegments: Int { speech.count { $0.isDoubtful } }

        /// The least confident segment's score; 0 when there is nothing to judge.
        var lowestLogprob: Double { speech.compactMap(\.avgLogprob).min() ?? 0 }

        /// Fewer doubtful segments wins; on a tie, the higher worst-segment confidence. The first one
        /// (temperature 0) wins a full tie.
        static func better(_ first: Transcription, _ second: Transcription) -> Transcription {
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
