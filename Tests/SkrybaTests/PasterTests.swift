import Testing
@testable import Skryba

struct PasterDecisionTests {
    @Test func pastesWhenEverythingIsStillInPlace() {
        #expect(Paster.decide(clipboardUnchanged: true, modifiersReleased: true, stillFocused: true) == .paste)
    }

    /// Regression: a key-release timeout used to re-copy the transcript over the user's fresh copy.
    @Test func neverTouchesAClipboardTheUserChanged() {
        let giveUp = Paster.Decision.giveUp(Paster.Message.clipboardChanged)
        #expect(Paster.decide(clipboardUnchanged: false, modifiersReleased: false, stillFocused: true) == giveUp)
        #expect(Paster.decide(clipboardUnchanged: false, modifiersReleased: true, stillFocused: false) == giveUp)
        #expect(Paster.decide(clipboardUnchanged: false, modifiersReleased: true, stillFocused: true) == giveUp)
    }

    @Test func leavesTheTranscriptOnTheClipboardOtherwise() {
        #expect(Paster.decide(clipboardUnchanged: true, modifiersReleased: false, stillFocused: true)
            == .keepOnClipboard(Paster.Message.keysHeld))
        #expect(Paster.decide(clipboardUnchanged: true, modifiersReleased: true, stillFocused: false)
            == .keepOnClipboard(Paster.Message.focusMoved))
    }
}
