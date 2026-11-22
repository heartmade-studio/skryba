import AppKit
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

struct PasterClipboardTests {
    /// Regression: the promise is fulfilled on the reading thread; assuming the main one trapped.
    @Test func thePromiseCanBeReadOffTheMainThread() async {
        let watcher = Paster.ReadWatcher(text: "transcript")
        #expect(!watcher.wasRead)
        let supplied = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let item = NSPasteboardItem()
                watcher.pasteboard(nil, item: item, provideDataForType: .string)
                continuation.resume(returning: item.string(forType: .string))
            }
        }
        #expect(supplied == "transcript")
        #expect(watcher.wasRead)
    }

    @Test @MainActor func copyingLeavesOneLine() {
        let pasteboard = NSPasteboard.withUniqueName() // never the user's clipboard
        defer { pasteboard.releaseGlobally() }
        Paster.copy("echo one\necho two\n", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "echo one echo two")
    }
}
