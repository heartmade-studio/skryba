import Foundation

/// Cloudflare Workers AI Whisper fallback. The caller decides explicitly whether it may run.
struct CloudflareTranscriber {
    static let model = "@cf/openai/whisper-large-v3-turbo"

    private struct RequestBody: Encodable {
        let audio: String
        let language: String?
        let initialPrompt: String?
    }

    private struct ResponseBody: Decodable {
        struct Result: Decodable { let text: String? }
        let result: Result?
        let success: Bool?
    }

    private static let session = URLSession(configuration: .ephemeral)

    let accountID: String
    let token: String

    func transcribe(fileURL: URL, language: String, prompt: String) async throws -> String {
        let id = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !token.isEmpty else { throw CloudflareError.notConfigured }
        guard id.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil else {
            throw CloudflareError.invalidAccountID
        }
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(id)/ai/run/\(Self.model)") else {
            throw CloudflareError.invalidAccountID
        }
        let body = RequestBody(
            audio: try Data(contentsOf: fileURL).base64EncodedString(),
            language: language.isEmpty ? nil : language,
            initialPrompt: prompt.isEmpty ? nil : prompt
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await Self.session.upload(for: request, from: try encoder.encode(body))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CloudflareError.api(status)
        }
        return try Self.decodeResponse(data)
    }

    static func decodeResponse(_ data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard decoded.success != false, let text = decoded.result?.text else {
            throw CloudflareError.invalidResponse
        }
        return text
    }
}

private enum CloudflareError: LocalizedError {
    case notConfigured
    case invalidAccountID
    case api(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Cloudflare Workers AI is not configured."
        case .invalidAccountID: "Cloudflare Account ID is invalid."
        case .api(let status): "Cloudflare Workers AI returned HTTP \(status)."
        case .invalidResponse: "Cloudflare Workers AI returned an invalid transcription response."
        }
    }
}
