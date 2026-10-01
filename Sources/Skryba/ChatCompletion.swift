import Foundation

/// Something that runs an OpenAI-style chat completion: Groq, or Cloudflare Workers AI.
/// AI cleanup uses the provider that transcribes, so the text goes nowhere the audio didn't.
protocol ChatClient: Sendable {
    func chat(_ request: ChatRequest) async throws -> String
}

/// One chat completion request in the OpenAI format, which both providers accept.
/// Optional fields are omitted from the JSON when nil; each model uses only the ones it knows.
struct ChatRequest: Encodable, Sendable {
    /// A thinking model sends nothing until it has an answer, and URLSession's timeout measures idle
    /// time. AI cleanup's own deadline (`AppController.cleanupDeadline`) is the one that counts.
    static let timeout: TimeInterval = 120

    struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let maxCompletionTokens: Int
    /// GPT-OSS and Qwen: how long the model thinks before answering.
    var reasoningEffort: String?
    /// Groq only: false keeps the reasoning out of the reply.
    var includeReasoning: Bool?
    /// Gemma on Cloudflare: `["enable_thinking": false]` turns its reasoning off.
    var chatTemplateKwargs: [String: Bool]?

    /// The JSON body; snake_case keys, as the OpenAI format expects.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(self)
    }

    /// The reply of a chat completion. A reply that didn't end on its own ("length": it hit the token
    /// limit) is cut off, so it throws rather than returning half a text.
    static func replyText(from data: Data) throws -> String {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let choice = try decoder.decode(Response.self, from: data).choices.first else { return "" }
        if let reason = choice.finishReason, reason != "stop" {
            throw SkrybaError.incompleteReply(reason: reason)
        }
        return choice.message.content ?? ""
    }

    /// What one reply took, for the log: token counts and the length of the hidden reasoning, never
    /// any of its text. It tells a model that thought for long from a request that waited in a queue.
    /// Decoded apart from the reply, so a provider's odd `usage` can't break the cleanup itself.
    static func usageSummary(from data: Data) -> String? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply = try? decoder.decode(UsageReply.self, from: data) else { return nil }
        var parts: [String] = []
        if let usage = reply.usage {
            if let prompt = usage.promptTokens { parts.append("\(prompt) in") }
            if let completion = usage.completionTokens { parts.append("\(completion) out") }
            if let reasoning = usage.completionTokensDetails?.reasoningTokens { parts.append("\(reasoning) reasoning") }
            // Groq only: seconds waiting for the model, and generating. A slow reply with a short
            // generation was a busy provider, not a model thinking for long.
            if let queue = usage.queueTime { parts.append("queue \(Self.milliseconds(queue))") }
            if let generation = usage.completionTime { parts.append("generation \(Self.milliseconds(generation))") }
        }
        // Cloudflare may not count reasoning tokens apart; the length of its reasoning field stands in.
        let message = reply.choices?.first?.message
        if let reasoning = message?.reasoningContent ?? message?.reasoning {
            parts.append("reasoning \(reasoning.count) chars")
        }
        if let reason = reply.choices?.first?.finishReason { parts.append("finish \(reason)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func milliseconds(_ seconds: Double) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }

    private struct UsageReply: Decodable {
        struct Usage: Decodable {
            struct Details: Decodable { let reasoningTokens: Int? }
            let promptTokens: Int?
            let completionTokens: Int?
            let completionTokensDetails: Details?
            let queueTime: Double?
            let completionTime: Double?
        }
        struct Choice: Decodable {
            struct Message: Decodable {
                let reasoningContent: String?
                let reasoning: String?
            }
            let message: Message?
            let finishReason: String?
        }
        let usage: Usage?
        let choices: [Choice]?
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finishReason: String?
        }
        let choices: [Choice]
    }
}
