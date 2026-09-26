import AppKit
import SwiftUI

@main
struct SkrybaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            if appDelegate.controller.phase == .idle, let icon = NSImage.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: appDelegate.controller.menuBarSymbol)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

struct MenuContent: View {
    let controller: AppController

    var body: some View {
        if controller.phase == .recording {
            Button("Cancel recording") { controller.cancelRecording() }
        } else {
            Text("Hold \(controller.triggerName) to dictate")
        }

        if let error = controller.hotKeyError {
            Text(error)
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
        }

        Divider()
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

private extension String {
    func truncated(to length: Int) -> String {
        count > length ? prefix(length) + "…" : self
    }
}
