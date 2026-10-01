import Foundation
import Observation
import os

/// Tells the user a newer Skryba is out; it never downloads or installs anything. Once a day it asks
/// GitHub for the latest release, and the menu then links to it for a manual download.
///
/// The request carries nothing about the user or their dictations, only what any web request does
/// (the IP address). It can be turned off in Settings.
@MainActor @Observable
final class UpdateCheck {
    static let releasesAPI = URL(string: "https://api.github.com/repos/heartmade-studio/skryba/releases/latest")!
    static let downloadPage = URL(string: "https://github.com/heartmade-studio/skryba/releases/latest")!

    /// The newer version on GitHub, e.g. "1.6", or nil while Skryba is up to date or not checked yet.
    private(set) var available: String?

    /// Called once per newer version, so the user hears about each one only once.
    @ObservationIgnored var onNewVersion: ((String) -> Void)?

    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Ephemeral: no cookies, cache or credentials are written to disk.
    private static let session = URLSession(configuration: .ephemeral)
    private static let log = Logger(subsystem: "pl.heartmade.skryba", category: "update")
    private static let announcedKey = "announcedUpdateVersion"

    /// Checks shortly after launch, then once a day, while `isEnabled` says so.
    func start(isEnabled: @escaping @MainActor () -> Bool) {
        guard let current = Self.currentVersion else { return } // a `swift run` build has no version
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10)) // stay out of the way while the app starts
            while !Task.isCancelled {
                if isEnabled() { await self?.check(current: current) }
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    /// Turning the check off also hides an update it already found.
    func clear() {
        available = nil
    }

    private func check(current: String) async {
        do {
            var request = URLRequest(url: Self.releasesAPI)
            request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await Self.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let latest = try Self.version(fromRelease: data)
            guard Self.isNewer(latest, than: current) else {
                available = nil
                return
            }
            available = latest
            let defaults = UserDefaults.standard
            if defaults.string(forKey: Self.announcedKey) != latest {
                defaults.set(latest, forKey: Self.announcedKey)
                onNewVersion?(latest)
            }
        } catch {
            // Optional and silent: a failed check just waits for tomorrow's.
            Self.log.notice("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The version in GitHub's latest release, "v1.5" → "1.5".
    nonisolated static func version(fromRelease data: Data) throws -> String {
        let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Compares dotted versions number by number: "1.10" is newer than "1.9", "1.5.1" than "1.5".
    /// Anything that isn't plain numbers is never newer, so an odd tag can't nag.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = numbers(candidate), let old = numbers(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    nonisolated private static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    private struct Release: Decodable {
        let tag_name: String
    }
}
