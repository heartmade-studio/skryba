import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A button that captures the next key combination pressed while it's active. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    let onBegin: () -> Void
    let onEnd: () -> Void

    @State private var monitor: Any?

    private var isRecording: Bool { monitor != nil }

    var body: some View {
        Button(isRecording ? "Press a shortcut…" : shortcut.displayString) {
            isRecording ? stop() : start()
        }
        .monospaced()
        .onDisappear(perform: stop)
    }

    private func start() {
        onBegin()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return
        }
        let modifiers = event.modifierFlags.intersection(Shortcut.supportedModifiers)
        // A bare letter would fire while typing; only F-keys may go without modifiers.
        // macOS 15+ also refuses global hotkeys whose only modifiers are ⌥ or ⌥⇧.
        let isValid = Shortcut.isFunctionKey(event.keyCode)
            || (!modifiers.isEmpty && modifiers != .option && modifiers != [.option, .shift])
        guard isValid else {
            NSSound.beep()
            return
        }
        shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: Shortcut.label(for: event))
        stop()
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        onEnd()
    }
}
