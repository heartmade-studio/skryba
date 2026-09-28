import Foundation
import Testing
@testable import Skryba

@Suite(.serialized)
@MainActor
struct PendingRecordingsTests {
    @Test func savedAudioSurvivesReloadAndCanBeDiscarded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingRecordingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = PendingRecordings(directory: root)
        let source = root.deletingLastPathComponent().appendingPathComponent("source-\(UUID()).m4a")
        try Data("audio".utf8).write(to: source)

        let saved = try queue.keep(Clip(url: source, duration: 2, voicedDuration: 1.2))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: saved.url.path))

        let reloaded = PendingRecordings(directory: root)
        #expect(reloaded.items.map(\.id) == [saved.id])
        #expect(reloaded.items.first?.voicedDuration == 1.2)

        reloaded.remove(saved)
        #expect(reloaded.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: saved.url.path))
    }

    @Test func reloadRecoversAudioWhenMetadataWriteWasInterrupted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingRecordingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let url = root.appendingPathComponent("\(id.uuidString).m4a")
        try Data("audio".utf8).write(to: url)

        let queue = PendingRecordings(directory: root)
        #expect(queue.items.count == 1)
        #expect(queue.items.first?.id == id)
        #expect(queue.items.first?.voicedDuration == 0.2)
    }
}
