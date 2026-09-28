import Foundation

/// How hard to try the cloud before giving up and keeping the recording for later.
///
/// Some failures are worth another attempt (a stalled upload, a busy server), others never get
/// better by repeating (no network at all, a rejected key). Each attempt is shown in the HUD and
/// can be cancelled, so a bad connection never feels like a hang.
enum Retry {
    static let maximumAttempts = 3
    /// No new attempt starts after this much time; the user shouldn't wait longer than about a minute.
    static let budget: Duration = .seconds(40)

    /// The pause before attempt `attempt + 1`.
    static func delay(after attempt: Int) -> Duration {
        .seconds(attempt == 1 ? 1 : 3)
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
