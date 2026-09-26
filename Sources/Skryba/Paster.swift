import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts text into the focused field: put it on the clipboard, send ⌘V, then put the user's
/// previous clipboard back. This works in native, Electron and browser apps alike.
///
/// It only pastes where dictation started (see `PasteTarget`), and it never overwrites something the
/// user copied while the transcript was on its way.
@MainActor
enum Paster {
    enum Outcome: Equatable {
        case pasted
        /// Nothing was pasted; the message says why and where the text is.
        case notPasted(String)
    }

    /// What to do once the wait for released modifier keys is over.
    enum Decision: Equatable {
        case paste
        /// Don't paste; the transcript is already on the clipboard, so leave it there.
        case keepOnClipboard(String)
        /// Don't paste and don't touch the clipboard: it now holds the user's own copy.
        case giveUp(String)
    }

    enum Message {
        static let noPermission = "Grant Accessibility access to paste. The text is in your clipboard."
        static let focusMoved = "The focus moved, so nothing was pasted. The text is in your clipboard."
        static let keysHeld = "Keys were still held, so nothing was pasted. The text is in your clipboard."
        static let clipboardChanged = "You copied something, so nothing was pasted. Use “Copy last” in the menu."
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds Skryba to Privacy & Security → Accessibility.
    static func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func paste(_ text: String, into target: PasteTarget?) async -> Outcome {
        let pasteboard = NSPasteboard.general

        guard isTrusted else {
            copy(text)
            return .notPasted(Message.noPermission)
        }
        guard let target, target.isStillFocused else {
            copy(text)
            return .notPasted(Message.focusMoved)
        }

        let saved = snapshot(of: pasteboard)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Asks clipboard managers not to record this temporary item (nspasteboard.org convention).
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let ourChange = pasteboard.changeCount

        let released = await waitForModifierRelease()
        switch decide(
            clipboardUnchanged: pasteboard.changeCount == ourChange,
            modifiersReleased: released,
            stillFocused: target.isStillFocused
        ) {
        case .keepOnClipboard(let message), .giveUp(let message):
            return .notPasted(message)
        case .paste:
            break
        }

        sendCommandV()

        // ⌘V is asynchronous and there is no "pasted" callback. Give the app time to read the
        // clipboard, then restore it unless the user copied something new in between.
        try? await Task.sleep(for: .milliseconds(500))
        if pasteboard.changeCount == ourChange {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        return .pasted
    }

    /// The user's own clipboard always wins: if they copied something while we waited, nothing is
    /// pasted and nothing is overwritten, whatever else went wrong.
    nonisolated static func decide(clipboardUnchanged: Bool, modifiersReleased: Bool, stillFocused: Bool) -> Decision {
        guard clipboardUnchanged else { return .giveUp(Message.clipboardChanged) }
        guard modifiersReleased else { return .keepOnClipboard(Message.keysHeld) }
        guard stillFocused else { return .keepOnClipboard(Message.focusMoved) }
        return .paste
    }

    /// Leaves the text on the clipboard as a normal, lasting item for the user to paste themselves.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// If the user still holds ⌃/⇧ from a shortcut, ⌘V would arrive as ⌃⇧⌘V. Waits up to ~1 s;
    /// returns false if the keys are still down, rather than sending a mangled shortcut.
    private static func waitForModifierRelease() async -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        for _ in 0..<40 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
