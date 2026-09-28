import Foundation
import os

/// Cloudflare Workers AI, an alternative to Groq: the same Whisper model, and chat models for AI cleanup.
/// Docs: https://developers.cloudflare.com/workers-ai/models/whisper-large-v3-turbo/
struct CloudflareClient: ChatClient {
    static let model = "@cf/openai/whisper-large-v3-turbo"

    let accountID: String
    let apiToken: String

    /// Ephemeral: no cookies, cache or credentials are written to disk.
    private static let session = URLSession(configuration: .ephemeral)
    private static let log = Logger(subsystem: "pl.heartmade.skryba", category: "network")

    /// An account ID is 32 hex characters. Checking it also keeps the URL below well-formed.
    static func isValidAccountID(_ id: String) -> Bool {
        id.wholeMatch(of: /[0-9a-fA-F]{32}/) != nil
    }

    func transcribe(fileURL: URL, language: String, prompt: String) async throws -> String {
        let body = Request(
            audio: try Data(contentsOf: fileURL).base64EncodedString(),
            language: language.isEmpty ? nil : language,
            initialPrompt: prompt.isEmpty ? nil : prompt
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try await post(path: "ai/run/\(Self.model)", body: try encoder.encode(body), timeout: 30, label: "transcription")
        return try Self.text(from: data)
    }

    /// One chat completion, for AI cleanup. Workers AI takes the OpenAI format at `ai/v1`.
    /// Docs: https://developers.cloudflare.com/workers-ai/configuration/open-ai-compatibility/
    func chat(_ request: ChatRequest) async throws -> String {
        let data = try await post(path: "ai/v1/chat/completions", body: try request.encoded(), timeout: ChatRequest.timeout, label: "chat \(request.model)")
        return try ChatRequest.replyText(from: data)
    }

    private func post(path: String, body: Data, timeout: TimeInterval, label: String) async throws -> Data {
        guard Self.isValidAccountID(accountID) else {
            throw SkrybaError.api(provider: "Cloudflare", status: 0, message: "The account ID is invalid.")
        }
        var request = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let started = ContinuousClock.now
        let (data, response) = try await Self.session.upload(for: request, from: body)
        Self.log.info("cloudflare \(label, privacy: .public): \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw SkrybaError.api(provider: "Cloudflare", status: status, message: Self.errorMessage(in: data, status: status))
        }
        return data
    }

    /// Workers AI replies with `{"errors": [{"message": …}]}`; the OpenAI endpoint may use `{"error": {"message": …}}`.
    static func errorMessage(in data: Data, status: Int) -> String {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.errors?.first?.message
            ?? (try? JSONDecoder().decode(OpenAIError.self, from: data))?.error.message
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
    }

    /// The transcript from a Workers AI reply: `{"success": true, "result": {"text": "…"}}`.
    static func text(from data: Data) throws -> String {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.success, let text = envelope.result?.text else {
            let message = envelope.errors?.first?.message ?? "No transcript in the reply."
            throw SkrybaError.api(provider: "Cloudflare", status: 200, message: message)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Request: Encodable {
        /// The m4a file, base64-encoded; Workers AI decodes the container itself.
        let audio: String
        let language: String?
        let initialPrompt: String?
    }

    private struct Envelope: Decodable {
        struct Result: Decodable { let text: String? }
        struct Message: Decodable { let message: String }
        let success: Bool
        let result: Result?
        let errors: [Message]?
    }

    private struct OpenAIError: Decodable {
        struct Body: Decodable { let message: String }
        let error: Body
    }
}
