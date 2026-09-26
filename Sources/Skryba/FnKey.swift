import AppKit
import Carbon.HIToolbox

/// Push-to-talk on the Fn (🌐) key alone.
///
/// Carbon hotkeys can't register a bare modifier, so this watches modifier changes with an NSEvent
/// monitor instead. Seeing other apps' key events requires Accessibility permission, which Skryba
/// already needs for pasting.
///
/// Fn also works as a modifier (Fn+↑ is Page Up, Fn+⌫ is forward delete). If any other key or modifier
/// joins while Fn is held, the press is treated as one of those shortcuts and `onCancel` fires.
@MainActor
final class FnKey {
    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?

    private var monitors: [Any] = []
    private var isDown = false
    private var isInterrupted = false

    /// True when macOS itself does nothing on 🌐 (System Settings → Keyboard → "Press 🌐 key to").
    /// Otherwise every dictation would also open the emoji picker or switch the input source.
    static var isFreeForApps: Bool {
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return (value as? Int) == 0
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        // Global monitors see events sent to other apps, local ones those sent to Skryba (e.g. Settings).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged where event.keyCode == UInt16(kVK_Function):
            let fnDown = event.modifierFlags.contains(.function)
            if fnDown, !isDown {
                isDown = true
                isInterrupted = !event.modifierFlags.intersection(Shortcut.supportedModifiers).isEmpty
                if !isInterrupted { onPress?() }
            } else if !fnDown, isDown {
                isDown = false
                if !isInterrupted { onRelease?() }
            }
        case .flagsChanged, .keyDown:
            if isDown, !isInterrupted {
                isInterrupted = true
                onCancel?()
            }
        default:
            break
        }
    }
}
