import Foundation
import Observation

/// Durable, private storage for finished takes that have not transcribed successfully yet.
@MainActor @Observable
final class PendingRecordings {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let voicedDuration: TimeInterval
        let createdAt: Date
        let duration: TimeInterval
    }

    private struct Metadata: Codable {
        let id: UUID
        let voicedDuration: TimeInterval
        let createdAt: Date
        let duration: TimeInterval
    }

    private let directory: URL
    private(set) var items: [Item] = []

    init(directory: URL = PendingRecordings.defaultDirectory) {
        self.directory = directory
        reload()
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skryba/Pending Recordings", isDirectory: true)
    }

    /// Moves a validated take into Application Support before any network request starts.
    func keep(_ clip: Clip) throws -> Item {
        try createPrivateDirectory()
        let id = UUID()
        let createdAt = Date()
        let url = audioURL(for: id)
        try FileManager.default.moveItem(at: clip.url, to: url)
        do {
            let metadata = Metadata(
                id: id, voicedDuration: clip.voicedDuration, createdAt: createdAt, duration: clip.duration
            )
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL(for: id), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL(for: id).path)
        } catch {
            // Keep the audio if metadata writing fails; reload can recover it conservatively.
            reload()
            throw error
        }
        let item = Item(
            id: id, url: url, voicedDuration: clip.voicedDuration,
            createdAt: createdAt, duration: clip.duration
        )
        items.append(item)
        return item
    }

    func remove(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
        try? FileManager.default.removeItem(at: metadataURL(for: item.id))
        items.removeAll { $0.id == item.id }
    }

    func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            items = []
            return
        }
        items = files.filter { $0.pathExtension == "m4a" }.compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            let metadata = (try? Data(contentsOf: metadataURL(for: id)))
                .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date ?? .distantPast
            return Item(
                id: id, url: url, voicedDuration: metadata?.voicedDuration ?? 0.2,
                createdAt: metadata?.createdAt ?? modified, duration: metadata?.duration ?? 0
            )
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private func createPrivateDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func audioURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).m4a") }
    private func metadataURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}
