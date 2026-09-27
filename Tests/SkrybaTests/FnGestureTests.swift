import Testing
@testable import Skryba

struct FnGestureTests {
    /// Plays taps as (press, release) times in seconds and returns what each release reported.
    private func releases(_ taps: [(Double, Double)], on gesture: inout FnGesture) -> [FnGesture.Action] {
        taps.map { press, release in
            _ = gesture.press(at: press, handsFree: false)
            return gesture.release(at: release)
        }
    }

    private func releases(_ taps: [(Double, Double)]) -> [FnGesture.Action] {
        var gesture = FnGesture()
        return releases(taps, on: &gesture)
    }

    @Test func everyPressStartsAndAHoldStops() {
        var gesture = FnGesture()
        #expect(gesture.press(at: 0.0, handsFree: false) == .start)
        #expect(gesture.release(at: 2.0) == .stop)
    }

    @Test func threeQuickTapsEnterHandsFreeOnTheThirdRelease() {
        #expect(releases([(0.0, 0.1), (0.25, 0.35), (0.5, 0.6)]) == [.stop, .stop, .enterHandsFree])
    }

    @Test func twoTapsThenAHoldIsPushToTalk() {
        #expect(releases([(0.0, 0.1), (0.2, 0.3), (0.4, 3.0)]) == [.stop, .stop, .stop])
    }

    @Test func ignoresSlowTaps() {
        #expect(releases([(0.0, 0.1), (0.6, 0.7), (1.3, 1.4)]).last == .stop)
    }

    @Test func aHoldResetsTheCount() {
        // Tap, a normal push-to-talk hold, then two taps: not a triple tap.
        #expect(releases([(0.0, 0.1), (0.2, 0.8), (0.9, 1.0), (1.1, 1.2)]).last == .stop)
    }

    @Test func aTapInHandsFreeStopsAndItsReleaseDoesNothing() {
        var gesture = FnGesture()
        _ = releases([(0.0, 0.1), (0.2, 0.3), (0.4, 0.5)], on: &gesture)
        #expect(gesture.press(at: 5.0, handsFree: true) == .stop)
        #expect(gesture.release(at: 5.1) == .none)
        // The stopping tap doesn't count toward a new triple tap.
        #expect(releases([(5.3, 5.4), (5.5, 5.6)], on: &gesture) == [.stop, .stop])
    }

    // The audit's cases: a take cancelled mid-gesture must leave nothing behind (`reset()`).

    @Test func aTapAfterACancelledThirdPressStops() {
        var gesture = FnGesture()
        _ = releases([(0.0, 0.1), (0.2, 0.3)], on: &gesture)
        #expect(gesture.press(at: 0.4, handsFree: false) == .start)
        gesture.reset() // another key joined Fn; FnKey reports no release
        #expect(releases([(2.0, 2.1)], on: &gesture) == [.stop])
    }

    @Test func aTapAfterACancelledHandsFreeStopStops() {
        var gesture = FnGesture()
        #expect(gesture.press(at: 0.0, handsFree: true) == .stop)
        gesture.reset() // another key joined Fn while it ended hands-free
        #expect(releases([(2.0, 2.1)], on: &gesture) == [.stop])
    }

    @Test func twoTapsAfterACancelAreNotATripleTap() {
        var gesture = FnGesture()
        _ = releases([(0.0, 0.1), (0.2, 0.3), (0.4, 0.5)], on: &gesture)
        gesture.reset() // Cancel recording in the menu
        #expect(releases([(0.6, 0.7), (0.8, 0.9)], on: &gesture) == [.stop, .stop])
    }

    @Test func startsOverAfterATripleTap() {
        #expect(releases([(0.0, 0.1), (0.2, 0.3), (0.4, 0.5), (0.6, 0.7)]).last == .stop)
    }
}
