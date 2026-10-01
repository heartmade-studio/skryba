import AppKit
import SwiftUI

@main
struct SkrybaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller, updates: appDelegate.updates)
        } label: {
            let controller = appDelegate.controller
            if controller.phase != .idle || !controller.pendingRecordings.items.isEmpty {
                Image(systemName: controller.menuBarSymbol)
            } else if appDelegate.updates.availableVersion != nil {
                Image(systemName: "arrow.down.circle.fill")
            } else if let icon = NSImage.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: controller.menuBarSymbol)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    let updates = UpdateChecker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        updates.start()
    }

    /// Opening Skryba again (Finder, Spotlight) while it runs shows Settings, the usual menu-bar-app behaviour.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
        updates.stop()
    }
}

struct MenuContent: View {
    let controller: AppController
    let updates: UpdateChecker

    var body: some View {
        if controller.phase.isRecording {
            Button("Cancel recording") { controller.cancelRecording() }
        } else if controller.phase == .transcribing {
            Button("Cancel transcription") { controller.cancelTranscription() }
        } else {
            Text("Hold \(controller.triggerName) to dictate")
        }
        if !controller.network.isOnline {
            Text("Offline")
        }

        if let error = controller.hotKeyError {
            Text(error)
        }
        if !controller.settings.canTranscribe {
            Button("Set up transcription…") { controller.openSettings() }
        }
        if !controller.microphoneGranted || !controller.accessibilityGranted {
            Button("Grant permissions…") { controller.openSettings() }
        }

        let pending = controller.pendingRecordings.items
        if !pending.isEmpty {
            Divider()
            Text(pending.count == 1 ? "1 saved recording" : "\(pending.count) saved recordings")
            // Newest first: usually the one you just lost.
            ForEach(pending.reversed()) { item in
                Menu(item.label) {
                    Button("Transcribe and copy") { controller.retry(item) }
                        .disabled(controller.phase != .idle)
                    Button("Delete…") { controller.delete(item) }
                        .disabled(controller.phase == .transcribing)
                }
            }
        }

        if let last = controller.lastTranscript {
            Divider()
            Button("Copy last: \(last.truncated(to: 40))") { Paster.copy(last) }
            if let raw = controller.lastRawTranscript {
                Button("Copy without AI cleanup") { Paster.copy(raw) }
            }
        }

        Divider()
        if let version = updates.availableVersion {
            Button("Update available: Skryba \(version)…") { updates.openDownload() }
        }
        Button(updates.isChecking ? "Checking for Updates…" : "Check for Updates…") {
            Task { await updates.check(showResult: true) }
        }
        .disabled(updates.isChecking)
        Button("Settings…") { controller.openSettings() }
            .keyboardShortcut(",")
        Button("Quit Skryba") { NSApp.terminate(nil) }
            .keyboardShortcut("q")

        Divider()
        Button("by Heartmade") { NSWorkspace.shared.open(Heartmade.url) }
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

private extension PendingRecordings.Item {
    /// "14:05 · 0:42" for today, with the date for older ones.
    var label: String {
        let seconds = Int(duration.rounded())
        let time = createdAt.formatted(date: Calendar.current.isDateInToday(createdAt) ? .omitted : .abbreviated, time: .shortened)
        return seconds > 0 ? "\(time) · \(seconds / 60):\(String(format: "%02d", seconds % 60))" : time
    }
}

private extension String {
    func truncated(to length: Int) -> String {
        count > length ? prefix(length) + "…" : self
    }
}
