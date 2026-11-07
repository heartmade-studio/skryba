import Foundation
import Testing
@testable import Skryba

@MainActor
struct DiagnosticRecordingTests {
    private func fixture() throws -> (URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let suite = "SkrybaDiagnosticTests-\(UUID().uuidString)"
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func aRequestedCopySurvivesDeletionOfTheOriginalAndIsOneShot() throws {
        let (root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let source = root.appendingPathComponent("original.m4a")
        let bytes = Data("controlled test audio".utf8)
        try bytes.write(to: source)
        defaults.set(true, forKey: DiagnosticRecording.requestKey)
        let folder = root.appendingPathComponent("diagnostic")
        let captured = try DiagnosticRecording.captureIfRequested(source, duration: 56,
                                                                  defaults: defaults, directory: folder)
        let copy = try #require(captured)
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(!defaults.bool(forKey: DiagnosticRecording.requestKey))
        try FileManager.default.removeItem(at: source)
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(try DiagnosticRecording.captureIfRequested(source, duration: 56, defaults: defaults, directory: folder) == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(directoryMode == 0o700)
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func unarmedOrShortTakesDoNotWriteOrConsumeTheRequest() throws {
        let (root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let missing = root.appendingPathComponent("missing.m4a")
        let folder = root.appendingPathComponent("diagnostic")
        #expect(try DiagnosticRecording.captureIfRequested(missing, duration: 56, defaults: defaults, directory: folder) == nil)
        defaults.set(true, forKey: DiagnosticRecording.requestKey)
        #expect(try DiagnosticRecording.captureIfRequested(missing, duration: 10, defaults: defaults, directory: folder) == nil)
        #expect(defaults.bool(forKey: DiagnosticRecording.requestKey))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aFailedCopyLeavesTheRequestArmed() throws {
        let (root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DiagnosticRecording.requestKey)
        #expect(throws: (any Error).self) {
            try DiagnosticRecording.captureIfRequested(root.appendingPathComponent("missing.m4a"), duration: 56,
                                                       defaults: defaults, directory: root.appendingPathComponent("diagnostic"))
        }
        #expect(defaults.bool(forKey: DiagnosticRecording.requestKey))
    }

    @Test func diagnosticAudioExpiresAfterSevenDays() throws {
        let (root, defaults, suite) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let file = root.appendingPathComponent("old.m4a")
        try Data("test audio".utf8).write(to: file)
        let old = Date.now.addingTimeInterval(-DiagnosticRecording.maximumAge - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        DiagnosticRecording.removeExpired(in: root)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
