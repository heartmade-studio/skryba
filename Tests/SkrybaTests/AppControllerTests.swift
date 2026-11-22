import Foundation
import Testing
@testable import Skryba

/// The whole controller, with a throwaway queue and settings, and no keychain, network, screen or
/// clipboard. Saved-recording retries share the commit point with fresh takes.
@MainActor
final class AppControllerTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkrybaTests-\(UUID().uuidString)")
    private var controller: AppController!
    private var copied: [String] = []

    private struct Outcome {
        let copied: [String]
        let audioKept: Bool
        let phase: AppController.Phase
        let hud: RecordingHUD.Style?
    }

    private func dictate(
        transcript: String, cancelAsTranscriptArrives: Bool = false,
        cleaned: String? = nil, cleanupError: (any Error)? = nil, skipAsCleanupArrives: Bool = false
    ) async throws -> Outcome {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = Settings(defaults: MemoryDefaults(), readKey: { _ in "test-only" })
        settings.provider = .openai
        settings.vocabulary = ""
        settings.replacements = ""
        settings.cleanupEnabled = cleaned != nil || cleanupError != nil

        let audio = root.appendingPathComponent("take.m4a")
        try Data("audio".utf8).write(to: audio)
        let queue = PendingRecordings(directory: root.appendingPathComponent("Pending"))
        let item = try queue.keep(Clip(url: audio, duration: 4, voicedDuration: 3))

        // Each stand-in clicks Cancel and then returns its result: the job is cancelled after the
        // reply arrived, and before the controller has resumed to use it.
        var outside = AppController.Outside()
        outside.transcribe = { [unowned self] in
            if cancelAsTranscriptArrives { controller.cancelTranscription() }
            return Transcription(text: transcript, source: .cloud(.openai))
        }
        outside.cleanUp = { [unowned self] in
            if skipAsCleanupArrives { controller.cancelTranscription() }
            if let cleanupError { throw cleanupError }
            return cleaned ?? ""
        }
        outside.copy = { [unowned self] in copied.append($0) }
        let hud = RecordingHUD(presents: false)
        controller = AppController(settings: settings, pendingRecordings: queue, hud: hud, outside: outside)

        controller.retry(item)
        let limit = ContinuousClock.now + .seconds(20)
        while controller.phase == .transcribing, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(5))
        }
        return Outcome(
            copied: copied,
            audioKept: queue.items.contains(item) && FileManager.default.fileExists(atPath: item.url.path),
            phase: controller.phase,
            hud: hud.style
        )
    }

    @Test func aTranscriptIsDeliveredAndItsRecordingRemoved() async throws {
        let result = try await dictate(transcript: "Dzień dobry.\nDo zobaczenia.")
        #expect(result.copied == ["Dzień dobry. Do zobaczenia."])
        #expect(!result.audioKept)
    }

    @Test func cancelWinsOverATranscriptThatJustArrived() async throws {
        let result = try await dictate(transcript: "Nie wklejaj tego.", cancelAsTranscriptArrives: true)
        #expect(result.copied.isEmpty)
        #expect(result.audioKept)
        #expect(result.phase == .error("Cancelled. The recording is saved in the Skryba menu."))
    }

    @Test func cancelWinsOverAnEmptyTranscriptToo() async throws {
        let result = try await dictate(transcript: "", cancelAsTranscriptArrives: true)
        #expect(result.audioKept)
    }

    @Test func cleanupIsApplied() async throws {
        let result = try await dictate(transcript: "yyy dzień dobry", cleaned: "dzień dobry")
        #expect(result.copied == ["dzień dobry"])
    }

    @Test func skipWinsOverACleanupThatJustArrived() async throws {
        let result = try await dictate(transcript: "yyy dzień dobry", cleaned: "dzień dobry", skipAsCleanupArrives: true)
        #expect(result.copied == ["yyy dzień dobry"])
    }

    /// Both ways cleanup can end just before the click: an error, and its deadline.
    @Test(arguments: [0, 1]) func skipWinsOverACleanupThatJustFailed(_ kind: Int) async throws {
        let error: any Error = kind == 0 ? SkrybaError.api(provider: "OpenAI", status: 500) : Retry.TimedOut()
        let result = try await dictate(transcript: "yyy dzień dobry", cleanupError: error, skipAsCleanupArrives: true)
        #expect(result.copied == ["yyy dzień dobry"])
        #expect(result.hud == .info("Copied. Press ⌘V to paste."))
    }

    @Test func aCleanupFailureWithoutSkipStillWarns() async throws {
        let error = SkrybaError.api(provider: "OpenAI", status: 500)
        let result = try await dictate(transcript: "yyy dzień dobry", cleanupError: error)
        #expect(result.copied == ["yyy dzień dobry"])
        #expect(result.hud == .info("Copied. Press ⌘V to paste. AI cleanup skipped. \(error.localizedDescription)"))
    }

    @Test func anOversizedTranscriptKeepsTheRecording() async throws {
        let result = try await dictate(transcript: String(repeating: "a", count: 50_001))
        #expect(result.copied.isEmpty)
        #expect(result.audioKept)
    }

    /// Counted in scalars: a single Character can carry any number of combining marks.
    @Test func oneEndlessCharacterIsOversizedToo() async throws {
        let result = try await dictate(transcript: "a" + String(repeating: "\u{301}", count: 50_000))
        #expect(result.copied.isEmpty)
        #expect(result.audioKept)
    }

    @Test func aLongButPossibleTranscriptIsDelivered() async throws {
        // Five minutes of very fast speech is about 15,000 characters.
        let text = Array(repeating: "słowo", count: 3000).joined(separator: " ")
        let result = try await dictate(transcript: text)
        #expect(result.copied == [text])
    }

    @Test func anOversizedCleanupFallsBackToThePlainTranscript() async throws {
        // Punctuation is invisible to the word guard, so only a size limit stops this.
        let result = try await dictate(transcript: "dzień dobry", cleaned: "dzień dobry" + String(repeating: "!", count: 50_001))
        #expect(result.copied == ["dzień dobry"])
    }
}
