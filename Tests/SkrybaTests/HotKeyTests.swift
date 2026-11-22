import Carbon.HIToolbox
import Testing
@testable import Skryba

@MainActor
struct HotKeyTests {
    /// The handler holds an unretained pointer, so it has to leave with the object.
    @Test func theHandlerIsRemovedWithTheHotKey() throws {
        var created: EventRef?
        #expect(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &created) == noErr)
        let event = try #require(created)
        defer { ReleaseEvent(event) }

        var presses = 0
        var hotKey: HotKey? = HotKey()
        hotKey?.onPress = { presses += 1 }
        #expect(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
        #expect(presses == 1)

        hotKey = nil
        #expect(SendEventToEventTarget(event, GetApplicationEventTarget()) == OSStatus(eventNotHandledErr))
        #expect(presses == 1)
    }
}
