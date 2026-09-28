import Foundation
import os

/// Speech-to-text through Cloudflare Workers AI, an alternative to Groq with the same Whisper model.
/// Docs: https://developers.cloudflare.com/workers-ai/models/whisper-large-v3-turbo/
struct CloudflareClient {
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
        guard Self.isValidAccountID(accountID) else {
            throw SkrybaError.api(provider: "Cloudflare", status: 0, message: "The account ID is invalid.")
        }
        let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/ai/run/\(Self.model)")!
        let body = Request(
            audio: try Data(contentsOf: fileURL).base64EncodedString(),
            language: language.isEmpty ? nil : language,
            initialPrompt: prompt.isEmpty ? nil : prompt
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let started = ContinuousClock.now
        let (data, response) = try await Self.session.upload(for: request, from: try encoder.encode(body))
        Self.log.info("cloudflare transcription: \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.errors?.first?.message
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw SkrybaError.api(provider: "Cloudflare", status: status, message: message)
        }
        return try Self.text(from: data)
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
}
