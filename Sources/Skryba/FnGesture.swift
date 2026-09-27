import Foundation

/// Everything a Fn press means, in one place: hold to talk, triple-tap for hands-free, tap to stop.
///
/// It turns Fn presses and releases into actions and owns all the state between them, so no part of
/// a gesture can outlive the take it belongs to:
///
/// - Every press **starts** recording, so push-to-talk keeps its first syllable. Every release
///   **stops** it; the two taps before the third are too short to be sent.
/// - A **tap** is a press released within `maximumTapDuration`. Hands-free starts when the **third**
///   tap is released and all three presses fall within `window`. Two taps and then a hold stay
///   push-to-talk: how long a press lasts is known only when it ends.
/// - In hands-free, the next press stops the take, and its release does nothing.
/// - `reset()` forgets everything. The controller calls it whenever a take ends without a Fn release
///   (another key joined Fn, Cancel in the menu, a trigger change, quit), because that release, if it
///   ever comes, belongs to no gesture.
struct FnGesture {
    enum Action: Equatable {
        case start, stop, enterHandsFree, none
    }

    static let maximumTapDuration: TimeInterval = 0.3
    static let window: TimeInterval = 1.0

    private var pressedAt: TimeInterval?
    /// Press times of recent quick taps.
    private var taps: [TimeInterval] = []
    /// The press that ended hands-free is down; its release must not act.
    private var endingHandsFree = false

    mutating func press(at time: TimeInterval, handsFree: Bool) -> Action {
        if handsFree {
            reset()
            endingHandsFree = true
            return .stop
        }
        pressedAt = time
        return .start
    }

    mutating func release(at time: TimeInterval) -> Action {
        if endingHandsFree {
            endingHandsFree = false
            return .none
        }
        guard let pressedAt else { return .stop }
        self.pressedAt = nil
        guard time - pressedAt <= Self.maximumTapDuration else {
            // A normal push-to-talk hold starts the count over.
            taps.removeAll()
            return .stop
        }
        taps.removeAll { pressedAt - $0 > Self.window }
        taps.append(pressedAt)
        guard taps.count == 3 else { return .stop }
        taps.removeAll()
        return .enterHandsFree
    }

    mutating func reset() {
        pressedAt = nil
        taps.removeAll()
        endingHandsFree = false
    }
}
