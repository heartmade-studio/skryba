import Foundation
import Testing
@testable import Skryba

/// Intercept real URLSession uploads: no credentials, microphones or cloud calls.
@Suite(.serialized)
struct OpenAIClientTests {
    private func transcribe(reply: String = #"{"text":"  Zażółć gęślą jaźń. \n","languages":[{"code":"pl"}]}"#,
                            status: Int = 200, language: String = "pl", keywords: [String] = [],
                            extension suffix: String = "m4a", hang: Bool = false) async throws -> String {
        OpenAIProtocol.state.reset(reply: reply, status: status, hang: hang)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(suffix)")
        try Data([0, 1, 2, 255]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await OpenAIClient(apiKey: "test-only", transport: transport)
            .transcribe(fileURL: file, language: language, keywords: keywords, requestTimeout: 17)
    }

    @Test func uploadsTheExactModelWithPluralLanguageAndVocabularyHints() async throws {
        #expect(try await transcribe(keywords: ["Heartmade", "Paweł Jurewicz", "bad<term", "bad>term", "bad\rterm", "bad\nterm", ""]) == "Zażółć gęślą jaźń.")
        let request = try #require(OpenAIProtocol.state.request)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
        #expect(request.timeoutInterval == 17)
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary=Skryba-"))
        let body = OpenAIProtocol.state.body
        let form = String(decoding: body, as: UTF8.self)
        #expect(form.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
        #expect(form.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        #expect(form.contains("name=\"languages[]\"\r\n\r\npl\r\n"))
        #expect(form.contains("name=\"keywords[]\"\r\n\r\nHeartmade\r\n"))
        #expect(form.contains("name=\"keywords[]\"\r\n\r\nPaweł Jurewicz\r\n"))
        #expect(!form.contains("bad"))
        #expect(!form.contains("name=\"language\""))
        #expect(!form.contains("name=\"prompt\""))
        #expect(!form.contains("verbose_json"))
        #expect(form.contains("filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n"))
        #expect(body.range(of: Data([0, 1, 2, 255])) != nil)
        let boundary = String(contentType.split(separator: "=").last!)
        #expect(form.hasSuffix("\r\n--\(boundary)--\r\n"))
    }

    @Test func autoDetectionOmitsLanguageAndEmptyVocabularyAndSupportsWAV() async throws {
        _ = try await transcribe(language: "", extension: "wav")
        let form = String(decoding: OpenAIProtocol.state.body, as: UTF8.self)
        #expect(!form.contains("name=\"languages[]\""))
        #expect(!form.contains("name=\"keywords[]\""))
        #expect(form.contains("filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n"))
    }

    @Test func uploadsNameTheAudioTypeWhateverTheExtensionCase() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).WAV")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var form = Multipart()
        form.field("model", "test")
        let body = String(decoding: try form.finish(withAudio: file), as: UTF8.self)
        #expect(body.contains("filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n"))
        #expect(body.hasSuffix("\r\n--\(form.boundary)--\r\n"))
        #expect(form.contentType == "multipart/form-data; boundary=\(form.boundary)")
    }

    @Test func emptySpeechSucceedsButAMissingTranscriptFails() async throws {
        #expect(try await transcribe(reply: #"{"text":""}"#) == "")
        for reply in [#"{"languages":[]}"#, #"{"text":null}"#, "not JSON"] {
            await #expect(throws: DecodingError.self) { try await transcribe(reply: reply) }
        }
    }

    @Test(arguments: [401, 403, 429, 503])
    func errorsKeepTheProviderAndStatusForSharedRetryPolicy(_ status: Int) async throws {
        do {
            _ = try await transcribe(reply: #"{"error":{"message":"Request rejected"}}"#, status: status)
            Issue.record("Expected an API error")
        } catch {
            guard case SkrybaError.api(let provider, let actual, let message) = error else {
                Issue.record("Expected an API error"); return
            }
            #expect(provider == "OpenAI")
            #expect(actual == status)
            #expect(message == "Request rejected")
            #expect(Retry.isTransient(error) == (status == 429 || status >= 500))
            #expect(Retry.failureKind(for: error) == "http_status_\(status)")
        }
    }

    @Test func nonJSONErrorsDoNotExposeTheResponseBody() async throws {
        do {
            _ = try await transcribe(reply: "private response", status: 502)
            Issue.record("Expected an API error")
        } catch {
            #expect(!error.localizedDescription.contains("private response"))
        }
    }

    @Test @MainActor func sharedDeadlineCancelsAStalledUpload() async throws {
        await #expect(throws: Retry.TimedOut.self) {
            try await Retry.run({ try await transcribe(hang: true) }, until: .now + .milliseconds(150))
        }
        #expect(OpenAIProtocol.state.wasStopped)
        #expect(Retry.deadline(forClipOf: 300, provider: .openai) == .seconds(120))
    }

    private func cleanup(reply: String, status: Int = 200, hang: Bool = false) async throws -> String {
        OpenAIProtocol.state.reset(reply: reply, status: status, hang: hang)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let request = TextCleanup.Model.luna.request(system: "Remove hesitations.",
                                                    user: "<transcript>yyy dzień dobry</transcript>", maxTokens: 4096)
        return try await OpenAIClient(apiKey: "test-only", transport: transport).chat(request)
    }

    private let cleanupReply = #"{"status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Dzień dobry."}]}]}"#

    @Test func cleanupUsesResponsesWithMediumReasoningAndStorageDisabled() async throws {
        #expect(try await cleanup(reply: cleanupReply) == "Dzień dobry.")
        let request = try #require(OpenAIProtocol.state.request)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try #require(JSONSerialization.jsonObject(with: OpenAIProtocol.state.body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-6-luna")
        #expect((json["reasoning"] as? [String: String])?["effort"] == "medium")
        #expect(json["max_output_tokens"] as? Int == 4096)
        #expect(json["store"] as? Bool == false)
        let messages = try #require(json["input"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[1]["content"] == "<transcript>yyy dzień dobry</transcript>")
        for field in ["temperature", "max_completion_tokens", "reasoning_effort", "include_reasoning", "chat_template_kwargs"] {
            #expect(json[field] == nil)
        }
    }

    @Test func partialRefusedOrMissingCleanupIsNeverReturnedAsSuccess() async throws {
        let replies = [
            cleanupReply.replacingOccurrences(of: "\"status\":\"completed\"", with: "\"status\":\"incomplete\""),
            #"{"status":"failed","output":[]}"#,
            #"{"status":"completed","output":[]}"#,
            #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"refusal","refusal":"No"}]}]}"#,
            #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":" "}]}]}"#,
        ]
        for reply in replies {
            await #expect(throws: SkrybaError.self) { try await cleanup(reply: reply) }
        }
        await #expect(throws: DecodingError.self) { try await cleanup(reply: "not JSON") }
    }

    @Test @MainActor func cleanupCanBeCancelledAtTheSharedDeadline() async throws {
        await #expect(throws: Retry.TimedOut.self) {
            try await Retry.run({ try await cleanup(reply: cleanupReply, hang: true) }, until: .now + .milliseconds(150))
        }
        #expect(OpenAIProtocol.state.wasStopped)
    }
}

private final class OpenAIProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: URLRequest?
        private var payload = Data()
        private var stopped = false
        private var reply = ""
        private var status = 200
        private var hang = false
        var request: URLRequest? { lock.withLock { captured } }
        var body: Data { lock.withLock { payload } }
        var wasStopped: Bool { lock.withLock { stopped } }
        func reset(reply: String, status: Int, hang: Bool) {
            lock.withLock {
                self.reply = reply; self.status = status; self.hang = hang
                captured = nil; payload = Data(); stopped = false
            }
        }
        func capture(_ request: URLRequest, body: Data) -> (String, Int, Bool) {
            lock.withLock { captured = request; payload = body; return (reply, status, hang) }
        }
        func stop() { lock.withLock { stopped = true } }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let (reply, status, hang) = Self.state.capture(request, body: body)
        guard !hang else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.state.stop() }
}
