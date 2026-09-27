import Foundation

/// Recognises three quick taps of the trigger key, which switch dictation to hands-free mode.
///
/// A tap is a press released within `maximumTapDuration`. The third press counts when it comes
/// within `window` of the first tap. Any longer hold (normal push-to-talk) starts the count over.
struct TripleTap {
    static let maximumTapDuration: TimeInterval = 0.3
    static let window: TimeInterval = 1.0

    private var pressedAt: TimeInterval?
    /// Press times of recent quick taps.
    private var taps: [TimeInterval] = []

    /// Records a press; returns true if it completes a triple tap.
    mutating func press(at time: TimeInterval) -> Bool {
        pressedAt = time
        taps.removeAll { time - $0 > Self.window }
        guard taps.count >= 2 else { return false }
        taps.removeAll()
        return true
    }

    mutating func release(at time: TimeInterval) {
        guard let pressedAt else { return }
        self.pressedAt = nil
        if time - pressedAt <= Self.maximumTapDuration {
            taps.append(pressedAt)
        } else {
            taps.removeAll()
        }
    }

    mutating func reset() {
        pressedAt = nil
        taps.removeAll()
    }
}
