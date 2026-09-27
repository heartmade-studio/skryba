import Foundation
import os

/// Minimal client for Groq's OpenAI-compatible API: speech-to-text, and chat for the optional cleanup.
/// Docs: https://console.groq.com/docs/speech-to-text, https://console.groq.com/docs/text-chat
struct GroqClient {
    static let transcriptionEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    static let chatEndpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    static let model = "whisper-large-v3-turbo"

    let apiKey: String

    /// Ephemeral: no cookies, cache or credentials are written to disk.
    private static let session = URLSession(configuration: .ephemeral)
    private static let log = Logger(subsystem: "pl.heartmade.skryba", category: "network")

    func transcribe(fileURL: URL, language: String, prompt: String) async throws -> String {
        let boundary = "Skryba-\(UUID().uuidString)"
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", Self.model)
        // verbose_json adds per-segment confidence, used below to drop hallucinated silence.
        field("response_format", "verbose_json")
        field("temperature", "0")
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
        return try Self.decoder.decode(Transcription.self, from: data).speechText
    }

    /// One system + user exchange with a chat model; returns the reply text.
    func chat(
        model: String, system: String, user: String,
        reasoningEffort: String?, includeReasoning: Bool?, maxTokens: Int
    ) async throws -> String {
        let request = ChatRequest(
            model: model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            temperature: 0.2,
            maxCompletionTokens: maxTokens,
            reasoningEffort: reasoningEffort,
            includeReasoning: includeReasoning
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try await send(
            to: Self.chatEndpoint,
            contentType: "application/json",
            body: try encoder.encode(request),
            timeout: 15,
            label: "chat \(model)"
        )
        let reply = try Self.decoder.decode(ChatResponse.self, from: data)
        return reply.choices.first?.message.content ?? ""
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
            throw SkrybaError.api(status: 0, message: "No response from Groq.")
        }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw SkrybaError.api(status: http.statusCode, message: message)
        }
        return data
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxCompletionTokens: Int
        // Optional reasoning controls; omitted from the JSON when nil.
        let reasoningEffort: String?
        let includeReasoning: Bool?
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct Transcription: Decodable {
        let text: String
        let segments: [Segment]?

        struct Segment: Decodable {
            let text: String
            let noSpeechProb: Double?
            let avgLogprob: Double?

            /// Whisper's own silence rule: likely no speech *and* low confidence. See also `Hallucinations`.
            var isLikelySilence: Bool {
                (noSpeechProb ?? 0) > 0.6 && (avgLogprob ?? 0) < -1.0
            }
        }

        var speechText: String {
            guard let segments, !segments.isEmpty else {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return segments
                .filter { !$0.isLikelySilence }
                .map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable { let message: String }
        let error: Body
    }
}

enum SkrybaError: LocalizedError {
    case recordingFailed
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .recordingFailed:
            "Could not start recording."
        case .api(let status, let message) where status == 401:
            "Groq rejected the API key (\(message)). Check it in Settings."
        case .api(_, let message):
            "Groq: \(message)"
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
