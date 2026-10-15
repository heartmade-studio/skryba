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

struct PasterAfterPasteTests {
    @Test func restoresOnlyOnceTheAppReadTheTranscript() {
        #expect(Paster.afterPaste(read: true, clipboardUnchanged: true) == .restore)
    }

    /// Regression: a fixed 500 ms restore let a busy app paste the user's old clipboard instead.
    @Test func keepsTheTranscriptWhenTheReadIsNotConfirmed() {
        #expect(Paster.afterPaste(read: false, clipboardUnchanged: true) == .keepTranscript)
    }

    @Test func neverTouchesAClipboardTheUserChangedAfterPaste() {
        #expect(Paster.afterPaste(read: true, clipboardUnchanged: false) == .leaveAlone)
        #expect(Paster.afterPaste(read: false, clipboardUnchanged: false) == .leaveAlone)
    }
}
