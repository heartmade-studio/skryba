import Foundation

/// How hard to try the cloud before moving on: to local Whisper if it's on, else to the saved queue.
///
/// All attempts share one deadline, so after releasing the key you are back to a usable app quickly,
/// even on a stalled connection. One attempt may take at most half of it, so a hanging request still
/// leaves time for another. Some failures are worth another attempt (a stalled upload, a busy
/// server); others never get better by repeating (no network at all, a rejected key).
enum Retry {
    static let maximumAttempts = 3

    static func clampedAttempts(_ count: Int) -> Int {
        min(max(count, 1), maximumAttempts)
    }

    /// Allow more time for Cloudflare and OpenAI file inference than Groq's fast Whisper route.
    /// Both policies bound the whole operation, including retries and Groq's part repairs.
    static func deadline(forClipOf duration: TimeInterval, provider: Settings.TranscriptionProvider = .groq) -> Duration {
        .seconds(provider == .cloudflare || provider == .openai
                 ? 60 + 0.2 * max(0, duration) : 12 + 0.1 * max(0, duration))
    }

    static func attemptBudget(within deadline: Duration) -> Duration { deadline / 2 }

    /// URLSession's idle timeout must not cut off an attempt earlier than our shared policy allows.
    /// Retry.run still enforces the actual remaining time, even if bytes keep arriving.
    static func requestTimeout(within deadline: Duration) -> TimeInterval {
        Double(milliseconds(attemptBudget(within: deadline))) / 1000
    }

    /// The pause before attempt `attempt + 1`.
    static func delay(after attempt: Int) -> Duration {
        .milliseconds(attempt == 1 ? 500 : 1000)
    }

    struct TimedOut: LocalizedError {
        var errorDescription: String? { "Skryba stopped waiting before a response arrived." }
    }

    /// Runs `operation` until it succeeds, up to `attemptLimit` times, all within `deadline`.
    /// `onAttempt` reports each attempt as it starts (for the HUD).
    @MainActor
    static func attempts<T: Sendable>(
        within deadline: Duration,
        attemptLimit: Int = maximumAttempts,
        onAttempt: (Int) -> Void = { _ in },
        onAttemptFailure: (Int, Duration, Error) -> Void = { _, _, _ in },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        let end = clock.now + deadline
        let attemptLimit = clampedAttempts(attemptLimit)
        var attempt = 1
        while true {
            onAttempt(attempt)
            let attemptStarted = clock.now
            do {
                return try await run(operation, until: min(end, clock.now + attemptBudget(within: deadline)))
            } catch {
                onAttemptFailure(attempt, clock.now - attemptStarted, error)
                // Another attempt only if it could still get a fair share of the time.
                let next = clock.now + delay(after: attempt)
                guard attempt < attemptLimit, isTransient(error) || error is TimedOut,
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
        if error is GroqClient.Transcription.JoinFailure { return "transcript_unaligned_overlap" }
        // Status 0: the client gave up before any HTTP status (no reply, an invalid account ID).
        if case SkrybaError.api(_, let status, _) = error { return status == 0 ? "no_http_status" : "http_status_\(status)" }
        if case SkrybaError.incompleteReply(let reason) = error {
            // Only fixed, app-owned reasons may reach the log. Chat finish reasons come from a
            // provider and must never be echoed verbatim, even in a diagnostic error label.
            return switch reason {
            case "missing word timestamps": "transcript_missing_word_timestamps"
            case "unmatched word timestamps": "transcript_unmatched_word_timestamps"
            case "incomplete word timestamps": "transcript_incomplete_word_timestamps"
            case "could not align overlapping words": "transcript_unaligned_overlap"
            case "length": "reply_length_limit"
            default: "incomplete_reply"
            }
        }
        return "other_error"
    }

    /// Whole milliseconds, so the logs read the same whatever the Mac's locale.
    static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
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
