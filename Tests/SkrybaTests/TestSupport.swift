import Foundation
import Synchronization

/// A clock that skips its first `jumps` sleeps and hangs on the rest until cancelled, so deadline
/// tests judge the policy rather than how busy the machine is.
final class TestClock: Clock, Sendable {
    typealias Instant = ContinuousClock.Instant

    private struct State {
        var now: Instant
        var jumps: Int
        var sleeps: [Instant] = []
    }

    let start: Instant
    private let state: Mutex<State>

    init(jumps: Int) {
        let start = ContinuousClock.now
        self.start = start
        state = Mutex(State(now: start, jumps: jumps))
    }

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var elapsed: Duration { now - start }
    /// When each sleep was due, from the start.
    var sleeps: [Duration] { state.withLock { $0.sleeps }.map { $0 - start } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let jumped = state.withLock { state in
            state.sleeps.append(deadline)
            guard state.jumps > 0 else { return false }
            state.jumps -= 1
            state.now = max(state.now, deadline)
            return true
        }
        if !jumped { try await Task.sleep(for: .seconds(60)) }
    }
}

/// Waits for something that happens on another thread, without betting on how soon.
func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let limit = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < limit else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Settings that never reach the disk. A throwaway suite leaves an empty file behind in
/// ~/Library/Preferences, even after `removePersistentDomain`.
final class MemoryDefaults: UserDefaults {
    private nonisolated(unsafe) var values: [String: Any] = [:] // each test uses its own, serially

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
}
