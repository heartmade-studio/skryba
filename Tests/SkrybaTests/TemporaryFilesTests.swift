import AVFoundation
import Foundation
import Testing
@testable import Skryba

struct TemporaryFilesTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkrybaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test @MainActor func leftoversOfACrashAreRemovedAndNothingElse() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let leftovers = ["pl.heartmade.skryba/local-1", "pl.heartmade.skryba/chunks-1", "pl.heartmade.skryba-local-1"]
        let others = ["pl.heartmade.skryba-other", "someone-else"]
        for name in leftovers + others {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        AudioRecorder.removeLeftovers(in: root)

        for name in leftovers { #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)) }
        for name in others { #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)) }
    }

    /// A stand-in for whisper-cli that notes where it was told to work.
    private func fakeWhisper(in root: URL) throws -> (whisper: LocalWhisper, take: URL, note: URL) {
        let note = root.appendingPathComponent("output-path")
        let tool = root.appendingPathComponent("whisper-cli")
        try """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do [ "$1" = "--output-file" ] && out="$2"; shift; done
        echo "$out" > "\(note.path)"
        echo hello > "$out.txt"
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let model = root.appendingPathComponent("model.bin")
        try Data("model".utf8).write(to: model)

        let take = root.appendingPathComponent("take.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        try AVAudioFile(forWriting: take, settings: format.settings).write(from: buffer)
        return (LocalWhisper(executablePath: tool.path, modelPath: model.path), take, note)
    }

    @Test func localWhisperWorksWhereCleanupLooks() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (whisper, take, note) = try fakeWhisper(in: root)

        #expect(try await whisper.transcribe(fileURL: take, duration: 1, language: "en", prompt: "") == "hello")

        let output = try String(contentsOf: note, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let work = URL(fileURLWithPath: output).deletingLastPathComponent()
        #expect(work.deletingLastPathComponent().lastPathComponent == AudioRecorder.directory.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: work.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: AudioRecorder.directory.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    /// The menu's Cancel can now land before the job has started.
    @Test func cancellingBeforeTheStartNeverRunsWhisper() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (whisper, take, note) = try fakeWhisper(in: root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await whisper.transcribe(fileURL: take, duration: 1, language: "en", prompt: "")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: note.path))
    }
}
