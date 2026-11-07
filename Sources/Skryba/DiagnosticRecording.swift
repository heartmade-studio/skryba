import Foundation

/// Explicit, one-shot preservation for a controlled reproduction. Off by default; never depends
/// on a background watcher winning a race against successful transcription deleting the original.
@MainActor
enum DiagnosticRecording {
    static let requestKey = "captureNextDiagnosticTake"
    static let directory = URL.applicationSupportDirectory.appendingPathComponent("Skryba/Diagnostic", isDirectory: true)
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static func captureIfRequested(_ source: URL, duration: TimeInterval,
                                   defaults: UserDefaults = .standard, directory: URL = directory) throws -> URL? {
        guard defaults.bool(forKey: requestKey), (40...120).contains(duration) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try folder.setResourceValues(values)
        let destination = directory.appendingPathComponent("\(UUID().uuidString).m4a")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            // Consume the request only after copying succeeds. Short status dictations don't
            // consume it, and a copy failure leaves the request armed for the next manual retry.
            defaults.set(false, forKey: requestKey)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func removeExpired(in directory: URL = directory, now: Date = .now) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "m4a" {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > maximumAge else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
