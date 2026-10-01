import Foundation
import os

/// OpenAI-compatible chat endpoint exposed by LM Studio on this Mac.
/// The fixed loopback URL keeps transcripts off the network; there is no configurable host.
struct LocalChatClient: ChatClient {
    static let endpoint = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!
    static let modelsEndpoint = URL(string: "http://127.0.0.1:1234/v1/models")!
    private static let session = URLSession(configuration: .ephemeral)
    private static let noRedirects = NoRedirects()
    private static let log = Logger(subsystem: "pl.heartmade.skryba", category: "local-chat")
    private static let modelDiscoveryTimeout: TimeInterval = 3

    let model: String

    func chat(_ request: ChatRequest) async throws -> String {
        guard Self.isLoopback(Self.endpoint), !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkrybaError.api(provider: "LM Studio", status: 0, message: "Choose a local model in Settings → AI Cleanup.")
        }
        let body = try Self.encodedBody(request, model: model.trimmingCharacters(in: .whitespacesAndNewlines))
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: ChatRequest.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        let started = ContinuousClock.now
        let (data, response) = try await Self.session.data(for: urlRequest, delegate: Self.noRedirects)
        Self.log.info("local cleanup: \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Never include the server's body: some local servers echo the submitted prompt.
            throw SkrybaError.api(provider: "LM Studio", status: status, message: "The local chat server returned an error.")
        }
        return try ChatRequest.replyText(from: data)
    }

    static func availableModels() async throws -> [String] {
        guard isLoopback(modelsEndpoint) else { throw LocalChatError.nonLoopback }
        let request = URLRequest(url: modelsEndpoint, timeoutInterval: modelDiscoveryTimeout)
        let (data, response) = try await session.data(for: request, delegate: noRedirects)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LocalChatError.unavailable }
        return try modelIDs(from: data)
    }

    static func modelIDs(from data: Data) throws -> [String] {
        try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id).sorted()
    }

    static func encodedBody(_ request: ChatRequest, model: String) throws -> Data {
        let localRequest = LocalRequest(
            model: model, messages: request.messages, temperature: request.temperature,
            maxTokens: request.maxCompletionTokens
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(localRequest)
    }

    static func isLoopback(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && url.port == 1234
    }

    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private struct LocalRequest: Encodable {
        let model: String
        let messages: [ChatRequest.Message]
        let temperature: Double
        let maxTokens: Int
    }

    /// A local server must not redirect a transcript to a nonlocal URL.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }

    enum LocalChatError: LocalizedError {
        case nonLoopback, unavailable
        var errorDescription: String? {
            switch self {
            case .nonLoopback: "Local cleanup only supports the LM Studio server on this Mac."
            case .unavailable: "Can't reach LM Studio. Start its local server and load a model."
            }
        }
    }
}
