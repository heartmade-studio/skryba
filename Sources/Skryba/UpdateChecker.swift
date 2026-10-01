import AppKit
import Foundation
import Observation

/// A small release reminder. Installing the DMG remains the user's choice; Skryba never replaces
/// its running bundle or asks for extra macOS permissions.
@MainActor @Observable
final class UpdateChecker {
    private(set) var availableVersion: String?
    private(set) var isChecking = false
    @ObservationIgnored private var scheduledChecks: Task<Void, Never>?

    private static let releaseAPI = URL(string: "https://api.github.com/repos/heartmade-studio/skryba/releases/latest")!
    private static let downloadURL = URL(string: "https://github.com/heartmade-studio/skryba/releases/latest/download/Skryba.dmg")!
    private static let session = URLSession(configuration: .ephemeral)

    func start() {
        guard scheduledChecks == nil else { return }
        scheduledChecks = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(showResult: false)
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    func stop() {
        scheduledChecks?.cancel()
        scheduledChecks = nil
    }

    func check(showResult: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: Self.releaseAPI)
            request.timeoutInterval = 10
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await Self.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CheckError.unavailable }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard release.assets.contains(where: { $0.name == "Skryba.dmg" }),
                  let remote = Version(release.tagName),
                  let current = Version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            else { throw CheckError.invalidRelease }

            availableVersion = remote > current ? release.tagName : nil
            if showResult {
                if let availableVersion {
                    showUpdateAlert(version: availableVersion)
                } else {
                    showAlert(title: "Skryba is up to date", message: "You have the latest release.")
                }
            }
        } catch {
            if showResult {
                showAlert(title: "Could not check for updates", message: "Try again later, or visit Skryba's GitHub releases.")
            }
        }
    }

    func openDownload() {
        NSWorkspace.shared.open(Self.downloadURL)
    }

    private func showUpdateAlert(version: String) {
        let alert = NSAlert()
        alert.messageText = "Skryba \(version) is available"
        alert.informativeText = "Download the official DMG, then drag Skryba to Applications. Your settings stay on this Mac."
        alert.addButton(withTitle: "Download DMG")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { openDownload() }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    private enum CheckError: Error { case unavailable, invalidRelease }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String }
        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", assets
        }
    }

    /// Compare numeric release tags without accepting arbitrary strings from the release API.
    struct Version: Comparable {
        let parts: [Int]

        init?(_ value: String) {
            let number = value.hasPrefix("v") ? value.dropFirst() : Substring(value)
            let components = number.split(separator: ".", omittingEmptySubsequences: false)
            guard (2...4).contains(components.count),
                  components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) })
            else { return nil }
            let parsed = components.compactMap { Int($0) }
            guard parsed.count == components.count else { return nil }
            parts = parsed
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            !(lhs < rhs) && !(rhs < lhs)
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            let count = max(lhs.parts.count, rhs.parts.count)
            for index in 0..<count {
                let left = index < lhs.parts.count ? lhs.parts[index] : 0
                let right = index < rhs.parts.count ? rhs.parts[index] : 0
                if left != right { return left < right }
            }
            return false
        }
    }
}
