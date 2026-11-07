import Foundation
import os

/// Completed recordings through OpenAI's file transcription API. Unlike Whisper, gpt-transcribe
/// takes `languages[]` and literal `keywords[]` hints, and returns JSON without segment confidence.
/// Optional cleanup uses the Responses API with the same key.
/// Docs: https://developers.openai.com/api/docs/guides/speech-to-text
struct OpenAIClient: ChatClient {
    static let model = "gpt-transcribe"
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let session = URLSession(configuration: .ephemeral)
    private static let log = Logger(subsystem: "pl.heartmade.skryba", category: "network")

    let apiKey: String
    var transport: URLSession = Self.session

    /// The caller owns retries and the shared deadline. Cancellation propagates to the upload.
    func transcribe(fileURL: URL, language: String, keywords: [String], requestTimeout: TimeInterval = 30) async throws -> String {
        var form = Multipart()
        form.field("model", Self.model)
        form.field("response_format", "json")
        if !language.isEmpty { form.field("languages[]", language) }
        // OpenAI rejects the whole request for a keyword containing these characters. Ignore that
        // hint rather than lose a dictation; Vocabulary still applies its local spelling fixes.
        for keyword in keywords where !keyword.isEmpty && keyword.rangeOfCharacter(from: CharacterSet(charactersIn: "<>\r\n")) == nil {
            form.field("keywords[]", keyword)
        }
        let data = try await send(to: Self.endpoint, body: try form.finish(withAudio: fileURL),
                                  contentType: form.contentType,
                                  timeout: requestTimeout, label: "transcription")
        return try JSONDecoder().decode(Reply.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keep the shared cleanup interface, but use Responses for OpenAI's reasoning models.
    /// No temperature or provider-specific chat fields are forwarded. Each dictation is stateless.
    func chat(_ request: ChatRequest) async throws -> String {
        let body = CleanupRequest(model: request.model, input: request.messages,
                                  reasoning: .init(effort: request.reasoningEffort ?? "medium"),
                                  maxOutputTokens: request.maxCompletionTokens, store: false)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try await send(to: URL(string: "https://api.openai.com/v1/responses")!,
                                  body: try encoder.encode(body), contentType: "application/json",
                                  timeout: ChatRequest.timeout, label: "cleanup")
        return try CleanupReply.text(from: data)
    }

    private func send(to url: URL, body: Data, contentType: String, timeout: TimeInterval, label: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let started = ContinuousClock.now
        let (data, response) = try await transport.upload(for: request, from: body)
        Self.log.notice("openai \(label, privacy: .public): \(body.count / 1024) KB, \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw SkrybaError.api(provider: "OpenAI", status: status, message: message)
        }
        return data
    }

    private struct CleanupRequest: Encodable {
        struct Reasoning: Encodable { let effort: String }
        let model: String
        let input: [ChatRequest.Message]
        let reasoning: Reasoning
        let maxOutputTokens: Int
        let store: Bool
    }

    private struct CleanupReply: Decodable {
        struct Output: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
            }
            let type: String
            let status: String?
            let role: String?
            let content: [Content]?
        }
        let status: String
        let output: [Output]

        static func text(from data: Data) throws -> String {
            let reply = try JSONDecoder().decode(Self.self, from: data)
            guard reply.status == "completed" else {
                // Never return a partial cleanup, or echo a provider-owned status in diagnostics.
                throw SkrybaError.incompleteReply(reason: "OpenAI cleanup did not complete")
            }
            var text = ""
            for item in reply.output where item.type == "message" {
                guard item.status == "completed", item.role == "assistant", let content = item.content else {
                    throw SkrybaError.incompleteReply(reason: "incomplete OpenAI message")
                }
                for part in content {
                    guard part.type == "output_text", let value = part.text else {
                        throw SkrybaError.incompleteReply(reason: "OpenAI cleanup returned no text")
                    }
                    text += value
                }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SkrybaError.incompleteReply(reason: "OpenAI cleanup returned no text")
            }
            return text
        }
    }

    private struct Reply: Decodable { let text: String }
    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable { let message: String }
        let error: Body
    }
}
