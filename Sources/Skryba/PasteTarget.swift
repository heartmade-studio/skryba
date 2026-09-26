import AppKit
import ApplicationServices

/// Where dictation started: the frontmost app, its focused window and its focused text field.
///
/// Transcription takes a moment, and the user may switch apps, browser tabs, chats or documents in
/// the meantime. The text is pasted only if all three are still the same. Apps that don't expose
/// their focused window or element (some Electron apps) fall back to the app-level check.
struct PasteTarget {
    let pid: pid_t
    let window: AXUIElement?
    let element: AXUIElement?

    /// A hung app could otherwise block an Accessibility query for seconds.
    private static let queryTimeout: Float = 0.25

    static func current() -> PasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, queryTimeout)
        return PasteTarget(
            pid: app.processIdentifier,
            window: element(appElement, kAXFocusedWindowAttribute),
            element: element(appElement, kAXFocusedUIElementAttribute)
        )
    }

    /// True if the same app, window and field still have focus.
    var isStillFocused: Bool {
        guard let now = PasteTarget.current(), now.pid == pid else { return false }
        return Self.same(window, now.window) && Self.same(element, now.element)
    }

    private static func same(_ start: AXUIElement?, _ now: AXUIElement?) -> Bool {
        switch (start, now) {
        case (nil, _): true // unknown at the start, so there is nothing to compare
        case (let start?, let now?): CFEqual(start, now)
        case (_?, nil): false // it was known and is now gone
        }
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}
