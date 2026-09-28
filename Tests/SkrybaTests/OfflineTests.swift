import AVFoundation
import Foundation
import Testing
@testable import Skryba

struct RetryTests {
    @Test func noNetworkIsOfflineNotRetried() {
        let error = URLError(.notConnectedToInternet)
        #expect(Retry.isOffline(error))
        #expect(!Retry.isTransient(error))
    }

    @Test func stalledOrBusyConnectionsAreRetried() {
        #expect(Retry.isTransient(URLError(.timedOut)))
        #expect(Retry.isTransient(URLError(.networkConnectionLost)))
        #expect(Retry.isTransient(SkrybaError.api(provider: "Groq", status: 503, message: "")))
        #expect(Retry.isTransient(SkrybaError.api(provider: "Groq", status: 429, message: "")))
    }

    @Test func rejectedCredentialsAreNotRetried() {
        #expect(!Retry.isTransient(SkrybaError.api(provider: "Groq", status: 401, message: "")))
        #expect(!Retry.isTransient(SkrybaError.api(provider: "Cloudflare", status: 400, message: "")))
    }

    @Test func bothKindsOfCancellationAreRecognised() {
        #expect(Retry.isCancellation(CancellationError()))
        #expect(Retry.isCancellation(URLError(.cancelled)))
        #expect(!Retry.isCancellation(URLError(.timedOut)))
    }
}

@MainActor
struct PendingRecordingsTests {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SkrybaTests-\(UUID().uuidString)", isDirectory: true)

    private func clip() throws -> Clip {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: url)
        return Clip(url: url, duration: 4.2, voicedDuration: 3.1)
    }

    @Test func keptTakesSurviveARelaunch() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = PendingRecordings(directory: directory)
        let source = try clip()
        let item = try queue.keep(source)
        #expect(!FileManager.default.fileExists(atPath: source.url.path))

        let relaunched = PendingRecordings(directory: directory)
        relaunched.load()
        #expect(relaunched.items.map(\.id) == [item.id])
        #expect(relaunched.items.first?.voicedDuration == 3.1)

        relaunched.remove(item)
        #expect(relaunched.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: item.url.path))
    }

    @Test func theFolderIsPrivateAndNotBackedUp() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try PendingRecordings(directory: directory).keep(clip())
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    @Test func oldRecordingsAreDeletedAtLoad() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = PendingRecordings(directory: directory)
        let old = try queue.keep(clip(), now: .now.addingTimeInterval(-PendingRecordings.maximumAge - 60))
        let recent = try queue.keep(clip())

        queue.load()
        #expect(queue.items.map(\.id) == [recent.id])
        #expect(!FileManager.default.fileExists(atPath: old.url.path))
    }

    @Test func audioWithoutItsDetailsIsStillRecovered() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        try Data("audio".utf8).write(to: directory.appendingPathComponent("\(id.uuidString).m4a"))

        let queue = PendingRecordings(directory: directory)
        queue.load()
        #expect(queue.items.map(\.id) == [id])
        // Unknown voice length must not make the hallucination filter drop real speech.
        #expect(queue.items.first?.voicedDuration == .infinity)
    }
}

struct CloudflareTests {
    @Test func readsTheTranscript() throws {
        let reply = Data(#"{"success":true,"result":{"text":" Dzień dobry. ","word_count":2},"errors":[]}"#.utf8)
        #expect(try CloudflareClient.text(from: reply) == "Dzień dobry.")
    }

    @Test func anUnsuccessfulReplyThrows() {
        let reply = Data(#"{"success":false,"result":null,"errors":[{"code":5006,"message":"bad input"}]}"#.utf8)
        #expect(throws: SkrybaError.self) { try CloudflareClient.text(from: reply) }
    }

    @Test func accountIDsAreThirtyTwoHexCharacters() {
        #expect(CloudflareClient.isValidAccountID("0123456789abcdef0123456789ABCDEF"))
        #expect(!CloudflareClient.isValidAccountID("0123456789abcdef"))
        #expect(!CloudflareClient.isValidAccountID("0123456789abcdef0123456789abcdef/../x"))
    }
}

struct LocalWhisperTests {
    @Test func pathsStaySingleArgumentsWithoutAShell() {
        let arguments = LocalWhisper.arguments(
            model: URL(fileURLWithPath: "/Models/my model.bin"),
            audio: URL(fileURLWithPath: "/tmp/a clip.wav"),
            language: "",
            prompt: "Heartmade, Skryba",
            outputBase: URL(fileURLWithPath: "/tmp/out")
        )
        #expect(arguments.contains("/Models/my model.bin"))
        #expect(arguments.contains("/tmp/a clip.wav"))
        #expect(arguments.contains("Heartmade, Skryba"))
        #expect(arguments[arguments.firstIndex(of: "--language")! + 1] == "auto")
    }

    @Test func timeoutGrowsWithTheClip() {
        #expect(LocalWhisper.timeout(forClipOf: 2) == .seconds(30))
        #expect(LocalWhisper.timeout(forClipOf: 300) == .seconds(900))
    }

    @Test func aMissingSetupIsReportedWithoutRunningAnything() {
        let whisper = LocalWhisper(executablePath: "/nonexistent/whisper-cli", modelPath: "/nonexistent/model.bin")
        #expect(whisper.setupProblem == .executableMissing)
    }

    @Test func convertsTheRecordingToSixteenBitWAV() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SkrybaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // One second of a quiet tone, recorded the way `AudioRecorder` records.
        let m4a = directory.appendingPathComponent("take.m4a")
        do {
            let file = try AVAudioFile(forWriting: m4a, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            ])
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            for i in 0..<16_000 { buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.1) }
            try file.write(from: buffer)
        }

        let wav = directory.appendingPathComponent("take.wav")
        try LocalWhisper.convertToWAV(m4a, to: wav)
        let converted = try AVAudioFile(forReading: wav)
        #expect(converted.fileFormat.sampleRate == 16_000)
        #expect(converted.fileFormat.channelCount == 1)
        #expect(converted.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
        #expect(converted.length > 15_000)
    }

    /// End to end with a real whisper.cpp. Opt in: `SKRYBA_WHISPER_MODEL=/path/to/ggml-….bin swift test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SKRYBA_WHISPER_MODEL"] != nil))
    func transcribesSpeechWithWhisperCpp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SkrybaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aiff = directory.appendingPathComponent("speech.aiff")
        let m4a = directory.appendingPathComponent("speech.m4a")
        try run("/usr/bin/say", ["-o", aiff.path, "Hello from the offline test."])
        try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac@16000", "-c", "1", aiff.path, m4a.path])

        let whisper = LocalWhisper(executablePath: "", modelPath: ProcessInfo.processInfo.environment["SKRYBA_WHISPER_MODEL"]!)
        let text = try await whisper.transcribe(fileURL: m4a, duration: 3, language: "en", prompt: "")
        #expect(text.lowercased().contains("offline"))

        // Cancelling stops whisper-cli at once instead of waiting for it to finish.
        let started = ContinuousClock.now
        let task = Task { try await whisper.transcribe(fileURL: m4a, duration: 3, language: "en", prompt: "") }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = try Process.run(URL(fileURLWithPath: path), arguments: arguments)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
