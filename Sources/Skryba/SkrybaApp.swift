import AppKit
import SwiftUI

@main
struct SkrybaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            ZStack(alignment: .topTrailing) {
                if appDelegate.controller.phase == .idle, let icon = NSImage.menuBarIcon {
                    Image(nsImage: icon)
                } else {
                    Image(systemName: appDelegate.controller.menuBarSymbol)
                }
                if !appDelegate.controller.pendingRecordings.items.isEmpty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
                        .offset(x: 2, y: -1)
                }
            }
            .accessibilityLabel(appDelegate.controller.pendingRecordings.items.isEmpty
                ? "Skryba" : "Skryba, saved recordings waiting")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    /// Opening Skryba again (Finder, Spotlight) while it runs shows Settings, the usual menu-bar-app behaviour.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

struct MenuContent: View {
    let controller: AppController
    @State private var recordingToDelete: PendingRecordings.Item?

    var body: some View {
        Group {
            if controller.phase.isRecording {
                Button("Cancel recording") { controller.cancelRecording() }
            } else {
                Text("Hold \(controller.triggerName) to dictate")
            }
            Text(controller.settings.providerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = controller.hotKeyError {
                Text(error)
            }
            if !controller.pendingRecordings.items.isEmpty {
                Divider()
                Text("Transcription failed or is still pending. Your audio is saved.")
                Text("Manual retries copy the transcript. Press ⌘V to paste it.")
                if let latest = controller.latestPendingRecording {
                    Button("Retry latest saved recording") {
                        controller.retryPendingRecording(latest)
                    }
                    .disabled(isTranscribing)
                }
                Menu("Saved recordings (\(controller.pendingRecordings.items.count))") {
                    ForEach(controller.pendingRecordings.items) { item in
                        Menu(recordingLabel(item)) {
                            Text("Saved \(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(durationLabel(item.duration))")
                            Button("Retry and copy transcript") {
                                controller.retryPendingRecording(item)
                            }
                            .disabled(isTranscribing)
                            Button("Delete recording…", role: .destructive) {
                                recordingToDelete = item
                            }
                        }
                    }
                }
            }
            if controller.settings.apiKey.isEmpty {
                Button("Add Groq API key…") { controller.openSettings() }
            }
            if !controller.microphoneGranted || !controller.accessibilityGranted {
                Button("Grant permissions…") { controller.openSettings() }
            }

            if let last = controller.lastTranscript {
                Divider()
                Button("Copy last: \(last.truncated(to: 40))") { Paster.copy(last) }
                if let raw = controller.lastRawTranscript {
                    Button("Copy without AI cleanup") { Paster.copy(raw) }
                }
            }

            Divider()
            Button("Settings…") { controller.openSettings() }
                .keyboardShortcut(",")
            Button("Quit Skryba") { NSApp.terminate(nil) }
                .keyboardShortcut("q")

            Divider()
            Button("by Heartmade") { NSWorkspace.shared.open(Heartmade.url) }
        }
        .confirmationDialog(
            "Delete saved recording?",
            isPresented: Binding(
                get: { recordingToDelete != nil },
                set: { if !$0 { recordingToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete recording", role: .destructive) {
                if let recordingToDelete { controller.discardPendingRecording(recordingToDelete) }
                recordingToDelete = nil
            }
            Button("Cancel", role: .cancel) { recordingToDelete = nil }
        } message: {
            Text("This permanently deletes the saved audio. This cannot be undone.")
        }
    }

    private var isTranscribing: Bool {
        controller.phase == .transcribing || controller.phase == .pasting
    }

    private func recordingLabel(_ item: PendingRecordings.Item) -> String {
        "\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(durationLabel(item.duration))"
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

enum Heartmade {
    /// Tagged so heartmade.pl analytics can tell visits that came from Skryba.
    static let url = URL(string: "https://heartmade.pl/en/?utm_source=skryba&utm_medium=app")!
}

private extension NSImage {
    /// The quill, drawn black on transparent. As a template image macOS tints it for light and dark menu bars.
    @MainActor static let menuBarIcon: NSImage? = {
        let image = Bundle.main.image(forResource: "MenuBarIcon")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }()
}

private extension String {
    func truncated(to length: Int) -> String {
        count > length ? prefix(length) + "…" : self
    }
}
