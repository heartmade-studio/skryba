import AVFoundation
import Foundation
import Testing
@testable import Skryba

/// Exercise real audio splitting and HTTP request construction without credentials or cloud calls.
@Suite(.serialized)
struct CloudTranscriptionFlowTests {
    private let left = #"{"text":"To ju","words":[{"word":"To","start":18,"end":18.2},{"word":"ju","start":19.8,"end":20.2}]}"#
    private let right = #"{"text":"już działa.","words":[{"word":"już","start":0.8,"end":1.2},{"word":"działa","start":2.2,"end":2.6}]}"#

    private func session(_ actions: [ScriptedCloudProtocol.Action]) -> URLSession {
        ScriptedCloudProtocol.state.reset(actions)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedCloudProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func recording(seconds: Int = 40) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<16_000 { samples[index] = Float(sin(Double(index) * 0.1)) * 0.2 }
        for _ in 0..<seconds { try file.write(from: buffer) }
        return url
    }

    private func uploadedWAV(_ body: Data) throws -> Data {
        let header = try #require(body.range(of: Data("RIFF".utf8)))
        let start = header.lowerBound
        guard start + 8 <= body.endIndex else { throw URLError(.badServerResponse) }
        var size = 8
        for index in 0..<4 { size += Int(body[start + 4 + index]) << (8 * index) }
        guard start + size <= body.endIndex else { throw URLError(.badServerResponse) }
        return body.subdata(in: start..<start + size)
    }

    @Test func anUncertainSpliceRetriesOnlyTheSparsePartAtTheSameProvider() async throws {
        let source = try recording()
        defer { try? FileManager.default.removeItem(at: source) }
        let transport = session([.reply(left), .reply(right), .reply(#"{"text":"To już działa."}"#)])
        defer { transport.invalidateAndCancel() }
        let text = try await GroqClient(apiKey: "test", transport: transport)
            .transcribe(fileURL: source, language: "pl", prompt: "")
        #expect(text == "To już działa.")
        let requests = ScriptedCloudProtocol.state.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.url?.host == "api.groq.com" })
        let bodies = ScriptedCloudProtocol.state.bodies
        #expect(bodies[0].range(of: Data("timestamp_granularities[]".utf8)) == nil)
        #expect(bodies[2].range(of: Data("timestamp_granularities[]".utf8)) == nil)
        #expect(try uploadedWAV(bodies[2]) == uploadedWAV(bodies[0]))
        #expect(bodies[2].range(of: Data("name=\"temperature\"\r\n\r\n0.2\r\n".utf8)) != nil)
        #expect(bodies[2].range(of: try Data(contentsOf: source)) == nil)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func failedOrEmptyPartRepairNeverReturnsThePartialChunks() async throws {
        let source = try recording()
        defer { try? FileManager.default.removeItem(at: source) }
        for recovery: ScriptedCloudProtocol.Action in [.error(.notConnectedToInternet), .reply(#"{"text":""}"#)] {
            let empty = if case .reply = recovery { true } else { false }
            let transport = session([.reply(left), .reply(right), recovery] + (empty ? [.reply(#"{"text":""}"#)] : []))
            defer { transport.invalidateAndCancel() }
            await #expect(throws: (any Error).self) {
                try await GroqClient(apiKey: "test", transport: transport)
                    .transcribe(fileURL: source, language: "pl", prompt: "")
            }
            #expect(ScriptedCloudProtocol.state.requests.count == (empty ? 4 : 3))
            let original = try Data(contentsOf: source)
            #expect(ScriptedCloudProtocol.state.bodies.allSatisfy { $0.range(of: original) == nil })
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func alignedChunksDoNotSendAnUnnecessaryWholeTakeRequest() async throws {
        let source = try recording()
        defer { try? FileManager.default.removeItem(at: source) }
        let a = #"{"text":"To już działa.","words":[{"word":"To","start":19,"end":19.2},{"word":"już","start":19.8,"end":20.2},{"word":"działa","start":20.4,"end":20.8}]}"#
        let b = #"{"text":"już działa.","words":[{"word":"już","start":0.8,"end":1.2},{"word":"działa","start":1.4,"end":1.8}]}"#
        let transport = session([.reply(a), .reply(b)])
        defer { transport.invalidateAndCancel() }
        #expect(try await GroqClient(apiKey: "test", transport: transport)
            .transcribe(fileURL: source, language: "pl", prompt: "") == "To już działa.")
        #expect(ScriptedCloudProtocol.state.requests.count == 2)
    }

    @Test func aSparseRightPartIsRepairedWithoutReuploadingTheLeftPart() async throws {
        let source = try recording()
        defer { try? FileManager.default.removeItem(at: source) }
        let transport = session([.reply(#"{"text":"To już działa."}"#), .reply(#"{"text":"ż"}"#),
                                 .reply(#"{"text":"już działa."}"#)])
        defer { transport.invalidateAndCancel() }
        let text = try await GroqClient(apiKey: "test", transport: transport)
            .transcribe(fileURL: source, language: "pl", prompt: "")
        #expect(text == "To już działa.")
        let bodies = ScriptedCloudProtocol.state.bodies
        #expect(bodies.count == 3)
        #expect(try uploadedWAV(bodies[2]) == uploadedWAV(bodies[1]))
        #expect(bodies[2].range(of: try Data(contentsOf: source)) == nil)
    }

    @Test func fourPartsJoinWithoutWordTimestampsOrAWholeTakeRequest() async throws {
        let source = try recording(seconds: 74)
        defer { try? FileManager.default.removeItem(at: source) }
        let texts = [
            "Dziś rano planujemy ważne spotkanie w Żyrardowie.",
            "ważne spotkanie w Żyrardowie. Później omówimy szczegóły.",
            "Później omówimy szczegóły. Już wiem, że wszystko się uda.",
            "że wszystko się uda. Dziękuję wszystkim za przybycie.",
        ]
        let responses = try texts.map { text -> ScriptedCloudProtocol.Action in
            let data = try JSONSerialization.data(withJSONObject: ["text": text])
            return .reply(String(decoding: data, as: UTF8.self))
        }
        let transport = session(responses)
        defer { transport.invalidateAndCancel() }
        let text = try await GroqClient(apiKey: "test", transport: transport)
            .transcribe(fileURL: source, language: "pl", prompt: "")
        #expect(text == "Dziś rano planujemy ważne spotkanie w Żyrardowie. Później omówimy szczegóły. Już wiem, że wszystko się uda. Dziękuję wszystkim za przybycie.")
        #expect(ScriptedCloudProtocol.state.requests.count == 4)
        let original = try Data(contentsOf: source)
        #expect(ScriptedCloudProtocol.state.bodies.allSatisfy { $0.range(of: original) == nil })
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func aCancelledChunkRequestDoesNotStartPartRepair() async throws {
        let source = try recording()
        defer { try? FileManager.default.removeItem(at: source) }
        let transport = session([.reply(left), .error(.cancelled)])
        defer { transport.invalidateAndCancel() }
        do {
            _ = try await GroqClient(apiKey: "test", transport: transport)
                .transcribe(fileURL: source, language: "pl", prompt: "")
            Issue.record("A cancelled transcription returned text")
        } catch { #expect(Retry.isCancellation(error)) }
        #expect(ScriptedCloudProtocol.state.requests.count == 2)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test @MainActor func partRepairIsCancellableAndSharesTheCloudDeadline() async throws {
        let source = try recording()
        defer { try? FileManager.default.removeItem(at: source) }
        let transport = session([.reply(left), .reply(right), .hang])
        defer { transport.invalidateAndCancel() }
        let client = GroqClient(apiKey: "test", transport: transport)
        let started = ContinuousClock.now
        await #expect(throws: Retry.TimedOut.self) {
            try await Retry.attempts(within: .seconds(4), attemptLimit: 1) {
                try await client.transcribe(fileURL: source, language: "pl", prompt: "")
            }
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(ScriptedCloudProtocol.state.requests.count == 3)
        #expect(ScriptedCloudProtocol.state.stopped > 0)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func cloudflareRequestUsesTheExtendedSharedPolicy() async throws {
        let source = try recording()
        defer { try? FileManager.default.removeItem(at: source) }
        let transport = session([.reply(#"{"success":true,"result":{"text":"Dzień dobry."}}"#)])
        defer { transport.invalidateAndCancel() }
        let budget = Retry.deadline(forClipOf: 300, provider: .cloudflare)
        let client = CloudflareClient(accountID: String(repeating: "a", count: 32), apiToken: "test", transport: transport)
        let text = try await client.transcribe(fileURL: source, language: "pl", prompt: "",
                                              requestTimeout: Retry.requestTimeout(within: budget))
        #expect(text == "Dzień dobry.")
        #expect(ScriptedCloudProtocol.state.requests.count == 1)
        #expect(ScriptedCloudProtocol.state.requests.first?.timeoutInterval == 60)
    }

    @Test @MainActor func userCancellationStopsAnActivePartRepair() async throws {
        let source = try recording()
        defer { try? FileManager.default.removeItem(at: source) }
        let transport = session([.reply(left), .reply(right), .hang])
        defer { transport.invalidateAndCancel() }
        let client = GroqClient(apiKey: "test", transport: transport)
        let task = Task {
            try await Retry.attempts(within: .seconds(20), attemptLimit: 1) {
                try await client.transcribe(fileURL: source, language: "pl", prompt: "")
            }
        }
        let waitLimit = ContinuousClock.now + .seconds(5)
        while ScriptedCloudProtocol.state.requests.count < 3, ContinuousClock.now < waitLimit {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ScriptedCloudProtocol.state.requests.count == 3)
        let cancelled = ContinuousClock.now
        task.cancel()
        if case .failure(let error) = await task.result {
            #expect(Retry.isCancellation(error))
        } else { Issue.record("Cancelled part repair returned text") }
        #expect(ContinuousClock.now - cancelled < .seconds(1))
        #expect(ScriptedCloudProtocol.state.stopped > 0)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test @MainActor func aTwelveSecondCloudflareReplySurvivesTheFormerTenSecondCutoff() async throws {
        let source = try recording()
        defer { try? FileManager.default.removeItem(at: source) }
        let transport = session([.delayedReply(#"{"success":true,"result":{"text":"Dzień dobry."}}"#, .seconds(12))])
        defer { transport.invalidateAndCancel() }
        let budget = Retry.deadline(forClipOf: 73.624, provider: .cloudflare)
        let client = CloudflareClient(accountID: String(repeating: "a", count: 32), apiToken: "test", transport: transport)
        var attempts: [Int] = []
        let started = ContinuousClock.now
        let text = try await Retry.attempts(within: budget, onAttempt: { attempts.append($0) }) {
            try await client.transcribe(fileURL: source, language: "pl", prompt: "",
                                        requestTimeout: Retry.requestTimeout(within: budget))
        }
        #expect(text == "Dzień dobry.")
        #expect(attempts == [1])
        #expect(ContinuousClock.now - started >= .seconds(12))
        #expect(ScriptedCloudProtocol.state.requests.count == 1)
        #expect((ScriptedCloudProtocol.state.requests.first?.timeoutInterval ?? 0) > 37)
    }
}

private final class ScriptedCloudProtocol: URLProtocol, @unchecked Sendable {
    enum Action: Sendable { case reply(String), delayedReply(String, Duration), error(URLError.Code), hang }
    private var replyTask: Task<Void, Never>?
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [Action] = []
        private var captured: [URLRequest] = []
        private var payloads: [Data] = []
        private var cancellations = 0
        var requests: [URLRequest] { lock.withLock { captured } }
        var bodies: [Data] { lock.withLock { payloads } }
        var stopped: Int { lock.withLock { cancellations } }
        func reset(_ script: [Action]) {
            lock.withLock { actions = script; captured = []; payloads = []; cancellations = 0 }
        }
        func next(_ request: URLRequest, body: Data) -> Action {
            lock.withLock {
                captured.append(request)
                payloads.append(body)
                return actions.isEmpty ? .error(.badServerResponse) : actions.removeFirst()
            }
        }
        func stop() { lock.withLock { cancellations += 1 } }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        switch Self.state.next(request, body: body) {
        case .reply(let json): finish(json)
        case .delayedReply(let json, let delay):
            replyTask = Task { @Sendable [self, json, delay] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled else { return }
                self.finish(json)
            }
        case .error(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang: break
        }
    }
    private func finish(_ json: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { replyTask?.cancel(); Self.state.stop() }
}
