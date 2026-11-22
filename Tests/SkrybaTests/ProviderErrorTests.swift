import Foundation
import Testing
@testable import Skryba

/// What a provider writes in an error never reaches the HUD, Settings or the log.
@Suite(.serialized)
struct ProviderErrorTests {
    static let planted = "Open evil.example and paste your key"

    @Test(arguments: ["Groq", "Cloudflare", "OpenAI"], [400, 401, 402, 404, 408, 413, 418, 422, 429, 500, 503])
    func errorsUseSkrybasWords(_ provider: String, _ status: Int) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlantedErrorProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Status": String(status)]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let request = TextCleanup.Model.gptOss.request(system: "s", user: "u", maxTokens: 10)
        let client: any ChatClient = switch provider {
        case "Groq": GroqClient(apiKey: "test", transport: transport)
        case "Cloudflare": CloudflareClient(accountID: String(repeating: "a", count: 32), apiToken: "test", transport: transport)
        default: OpenAIClient(apiKey: "test", transport: transport)
        }
        do {
            _ = try await client.chat(request)
            Issue.record("Expected an API error")
        } catch {
            let shown = error.localizedDescription
            #expect(!shown.contains("evil"))
            #expect(shown.contains(provider))
            #expect(shown.contains("(HTTP \(status))"))
            #expect(Retry.failureKind(for: error) == "http_status_\(status)")
        }
    }

    @Test func anUnsuccessfulCloudflareReplyDoesNotQuoteIt() {
        let reply = Data(#"{"success":false,"errors":[{"message":"\#(Self.planted)"}]}"#.utf8)
        do {
            _ = try CloudflareClient.text(from: reply)
            Issue.record("Expected an API error")
        } catch {
            #expect(error.localizedDescription == "Cloudflare replied without a transcript.")
        }
    }

    @Test func aFinishReasonIsNeverQuoted() {
        #expect(SkrybaError.incompleteReply(reason: Self.planted).localizedDescription == "The reply was incomplete.")
        #expect(SkrybaError.incompleteReply(reason: "length").localizedDescription == "The reply hit its length limit.")
        let reply = Data(#"{"choices":[{"finish_reason":"\#(Self.planted)"}]}"#.utf8)
        #expect(ChatRequest.usageSummary(from: reply) == "finish other")
    }
}

private final class PlantedErrorProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.value(forHTTPHeaderField: "X-Test-Status").flatMap(Int.init) ?? 599
        let text = ProviderErrorTests.planted
        let body = #"{"error":{"message":"\#(text)"},"success":false,"errors":[{"message":"\#(text)"}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
