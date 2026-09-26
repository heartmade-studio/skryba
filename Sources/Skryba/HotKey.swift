import Carbon.HIToolbox

/// A global push-to-talk hotkey built on Carbon's `RegisterEventHotKey`.
///
/// Carbon is old, but it is still the only system API that reports both key-down and key-up for a
/// global shortcut without asking for Accessibility or Input Monitoring permission.
@MainActor
final class HotKey {
    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static let signature: OSType = 0x534B_5259 // 'SKRY'

    init() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                // Carbon delivers application events on the main thread.
                MainActor.assumeIsolated {
                    let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                    if isPress { hotKey.onPress?() } else { hotKey.onRelease?() }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    /// Returns false when the shortcut is already registered by another app.
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }
}
