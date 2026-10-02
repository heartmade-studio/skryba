import Foundation

/// How hard to try the cloud before moving on: to local Whisper if it's on, else to the saved queue.
///
/// All attempts share one deadline, so after releasing the key you are back to a usable app quickly,
/// even on a stalled connection. One attempt may take at most half of it, so a hanging request still
/// leaves time for another. Some failures are worth another attempt (a stalled upload, a busy
/// server); others never get better by repeating (no network at all, a rejected key).
enum Retry {
    static let maximumAttempts = 3

    /// Groq usually answers a short take in under a second. 12 seconds covers a slow network with room
    /// for a retry; a long take gets more, since its upload is bigger.
    static func deadline(forClipOf duration: TimeInterval) -> Duration {
        .seconds(12 + 0.1 * duration)
    }

    /// The pause before attempt `attempt + 1`.
    static func delay(after attempt: Int) -> Duration {
        .milliseconds(attempt == 1 ? 500 : 1000)
    }

    struct TimedOut: LocalizedError {
        var errorDescription: String? { "Skryba stopped waiting before a response arrived." }
    }

    /// Runs `operation` until it succeeds, up to `maximumAttempts` times, all within `deadline`.
    /// `onAttempt` reports each attempt as it starts (for the HUD).
    @MainActor
    static func attempts<T: Sendable>(
        within deadline: Duration,
        onAttempt: (Int) -> Void = { _ in },
        onAttemptFailure: (Int, Duration, Error) -> Void = { _, _, _ in },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        let end = clock.now + deadline
        var attempt = 1
        while true {
            onAttempt(attempt)
            let attemptStarted = clock.now
            do {
                return try await run(operation, until: min(end, clock.now + deadline / 2))
            } catch {
                onAttemptFailure(attempt, clock.now - attemptStarted, error)
                // Another attempt only if it could still get a fair share of the time.
                let next = clock.now + delay(after: attempt)
                guard attempt < maximumAttempts, isTransient(error) || error is TimedOut,
                      end - next >= deadline / 4 else { throw error }
                try await Task.sleep(until: next, clock: clock)
                attempt += 1
            }
        }
    }

    /// A safe diagnostic label: never includes provider response text, a transcript, or credentials.
    static func failureKind(for error: Error) -> String {
        if error is TimedOut { return "app_deadline" }
        if isCancellation(error) { return "cancelled" }
        if let error = error as? URLError { return "url_error_\(error.code.rawValue)" }
        if case SkrybaError.api(_, let status, _) = error { return "http_status_\(status)" }
        return "other_error"
    }

    /// Runs `operation`, cancelling it at `limit`. A request that keeps trickling bytes never hits
    /// URLSession's own timeout (it measures idle time), so this is the one that counts.
    static func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T, until limit: ContinuousClock.Instant
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(until: limit, clock: .continuous)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// There is no network path at all: don't retry, go straight to the fallback.
    static func isOffline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(error.code)
    }

    /// A failure that another attempt might fix.
    static func isTransient(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [
                .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .secureConnectionFailed,
            ].contains(error.code)
        }
        if case SkrybaError.api(_, let status, _) = error {
            return status == 0 || status == 429 || status >= 500
        }
        return false
    }

    /// The user cancelled, either as a Swift cancellation or as URLSession's own error.
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
