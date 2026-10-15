import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts text into the focused field: put it on the clipboard, send ⌘V, then put the user's
/// previous clipboard back. This works in native, Electron and browser apps alike.
///
/// It only pastes where dictation started (see `PasteTarget`), and it never overwrites something the
/// user copied while the transcript was on its way.
///
/// The clipboard comes back only once the app has actually read the transcript. A busy app can
/// handle ⌘V seconds late; restoring on a fixed timer then pasted the user's old clipboard instead.
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

    /// What to do with the clipboard after ⌘V.
    enum AfterPaste: Equatable {
        /// The app read the transcript: put the user's clipboard back.
        case restore
        /// No read yet: keep the transcript there, so a late paste still gets the right text.
        case keepTranscript
        /// The user copied something meanwhile: leave their copy alone.
        case leaveAlone
    }

    enum Message {
        static let noPermission = "Grant Accessibility access to paste. The text is in your clipboard."
        static let focusMoved = "The focus moved, so nothing was pasted. The text is in your clipboard."
        static let keysHeld = "Keys were still held, so nothing was pasted. The text is in your clipboard."
        static let clipboardChanged = "You copied something, so nothing was pasted. Use “Copy last” in the menu."
        static let notConfirmed = "The app didn’t take the text in time. It is in your clipboard."
    }

    /// How long to wait for the app to read the transcript after ⌘V.
    static let readTimeout: Duration = .seconds(3)

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
        // The text is promised, not written: the pasteboard asks `reader` for it at the moment an app
        // reads it, which is the only sign that the paste happened.
        let reader = ReadWatcher(text: text)
        let item = NSPasteboardItem()
        item.setDataProvider(reader, forTypes: [.string])
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

        // ⌘V is asynchronous. Wait until the app has read the text, then restore the clipboard.
        let deadline = ContinuousClock.now + readTimeout
        while !reader.wasRead, pasteboard.changeCount == ourChange, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        // Some apps read the clipboard in several steps; let them finish before swapping it.
        if reader.wasRead { try? await Task.sleep(for: .milliseconds(250)) }

        switch afterPaste(read: reader.wasRead, clipboardUnchanged: pasteboard.changeCount == ourChange) {
        case .restore:
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
            return .pasted
        case .keepTranscript:
            // Replace the promise with real text, so it outlives Skryba and a late ⌘V still works.
            copy(text)
            return .notPasted(Message.notConfirmed)
        case .leaveAlone:
            return .pasted
        }
    }

    /// The user's old clipboard may come back only after the app has taken the transcript;
    /// restoring earlier is what pasted stale text into a slow app.
    nonisolated static func afterPaste(read: Bool, clipboardUnchanged: Bool) -> AfterPaste {
        guard clipboardUnchanged else { return .leaveAlone }
        return read ? .restore : .keepTranscript
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

    /// Supplies the promised transcript and records that someone asked for it. The pasteboard calls
    /// it on the main thread, while `paste` is suspended in its wait.
    @MainActor
    private final class ReadWatcher: NSObject, NSPasteboardItemDataProvider {
        private let text: String
        private(set) var wasRead = false

        init(text: String) { self.text = text }

        nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            item.setString(text, forType: type)
            MainActor.assumeIsolated { wasRead = true }
        }
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
