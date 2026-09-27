import Testing
@testable import Skryba

struct TripleTapTests {
    /// Taps as (press, release) times in seconds; returns what the final press reported.
    private func thirdPress(after taps: [(Double, Double)], at time: Double) -> Bool {
        var detector = TripleTap()
        for (press, release) in taps {
            _ = detector.press(at: press)
            detector.release(at: release)
        }
        return detector.press(at: time)
    }

    @Test func recognisesThreeQuickTaps() {
        #expect(thirdPress(after: [(0.0, 0.1), (0.25, 0.35)], at: 0.5))
    }

    @Test func ignoresTwoTaps() {
        var detector = TripleTap()
        let result1 = detector.press(at: 0.0)
        #expect(!result1)
        detector.release(at: 0.1)
        let result2 = detector.press(at: 0.25)
        #expect(!result2)
    }

    @Test func ignoresSlowTaps() {
        #expect(!thirdPress(after: [(0.0, 0.1), (0.6, 0.7)], at: 1.3))
    }

    @Test func aHoldResetsTheCount() {
        // Tap, then a normal push-to-talk hold, then a tap: not a triple tap.
        #expect(!thirdPress(after: [(0.0, 0.1), (0.2, 0.8)], at: 0.9))
    }

    @Test func startsOverAfterATripleTap() {
        var detector = TripleTap()
        for (press, release) in [(0.0, 0.1), (0.2, 0.3)] {
            _ = detector.press(at: press)
            detector.release(at: release)
        }
        let result3 = detector.press(at: 0.4)
        #expect(result3)
        detector.release(at: 0.5)
        let result4 = detector.press(at: 0.6)
        #expect(!result4)
    }

    @Test func resetForgetsTaps() {
        var detector = TripleTap()
        for (press, release) in [(0.0, 0.1), (0.2, 0.3)] {
            _ = detector.press(at: press)
            detector.release(at: release)
        }
        detector.reset()
        let result5 = detector.press(at: 0.4)
        #expect(!result5)
    }
}
