import Foundation
import Observation
import os

/// Takes that couldn't be transcribed yet (offline, the provider failed, or the user cancelled), kept
/// so a dictation is never lost. The user transcribes or deletes them from the menu.
///
/// The folder is private (0700), left out of Time Machine backups, and anything older than
/// `maximumAge` is deleted at launch: voice recordings shouldn't pile up unnoticed.
@MainActor @Observable
final class PendingRecordings {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let createdAt: Date
        let duration: TimeInterval
        let voicedDuration: TimeInterval
    }

    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Skryba/Pending", isDirectory: true)
    }

    /// Oldest first.
    private(set) var items: [Item] = []

    @ObservationIgnored private let directory: URL
    private static let log = Logger(subsystem: "pl.heartmade.skryba", category: "pending")

    init(directory: URL = PendingRecordings.defaultDirectory) {
        self.directory = directory
    }

    /// Moves a finished take into the queue before anything is sent, so a crash or an outage can't lose it.
    func keep(_ clip: Clip, now: Date = .now) throws -> Item {
        try prepareDirectory()
        let id = UUID()
        let item = Item(
            id: id, url: directory.appendingPathComponent("\(id.uuidString).m4a"),
            createdAt: now, duration: clip.duration, voicedDuration: clip.voicedDuration
        )
        try FileManager.default.moveItem(at: clip.url, to: item.url)
        // Details go in a sidecar file; without it `load` still recovers the audio.
        let metadata = Metadata(createdAt: now, duration: clip.duration, voicedDuration: clip.voicedDuration)
        try? JSONEncoder().encode(metadata).write(to: metadataURL(for: id), options: .atomic)
        items.append(item)
        return item
    }

    func remove(_ item: Item) {
        AudioRecorder.remove(item.url)
        AudioRecorder.remove(metadataURL(for: item.id))
        items.removeAll { $0.id == item.id }
    }

    /// Reads the queue from disk and deletes recordings older than `maximumAge`.
    func load(now: Date = .now) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var loaded: [Item] = []
        for url in files where url.pathExtension == "m4a" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let metadata = (try? Data(contentsOf: metadataURL(for: id)))
                .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
            let created = metadata?.createdAt
                ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? now
            // Unknown voice length: assume plenty, so the hallucination filter doesn't drop real speech.
            let item = Item(
                id: id, url: url, createdAt: created,
                duration: metadata?.duration ?? 0, voicedDuration: metadata?.voicedDuration ?? .infinity
            )
            if now.timeIntervalSince(created) > Self.maximumAge {
                AudioRecorder.remove(url)
                AudioRecorder.remove(metadataURL(for: id))
                Self.log.notice("deleted an expired recording")
            } else {
                loaded.append(item)
            }
        }
        items = loaded.sorted { $0.createdAt < $1.createdAt }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
    }

    private func metadataURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private struct Metadata: Codable {
        let createdAt: Date
        let duration: TimeInterval
        let voicedDuration: TimeInterval
    }
}
