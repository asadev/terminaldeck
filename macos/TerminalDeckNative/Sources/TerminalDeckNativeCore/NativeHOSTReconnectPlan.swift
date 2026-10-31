import Foundation

/// 28 Oct (bug A, Asad: after a keeper restart the app sat dead for nine minutes until he quit and reopened it):
/// how a lost session helper is reconnected. Five quick attempts (1, 2, 3, 4 s apart), then one every 30 s until a
/// helper answers or the app closes; a deliberate restart gets the same retries as a crash (it once got one try, and
/// a cancelled first try meant giving up). A slow retry that fails the same way again writes no new log line.
public struct NativeHOSTReconnectPlan: Sendable {
    public static let quickAttempts = 5
    public static let slowPause: Double = 30
    private var lastFailure: String?
    public init() {}
    /// Seconds to wait after failed attempt `attempt` (1-based).
    public static func pause(after attempt: Int) -> Double { attempt < quickAttempts ? Double(max(1, attempt)) : slowPause }
    /// The log line for a failed attempt, or nil when a slow retry failed for the same reason as the one before.
    public mutating func failed(attempt: Int, _ reason: String) -> String? {
        defer { lastFailure = reason }
        if attempt < Self.quickAttempts { return "attempt \(attempt) failed: " + reason }
        if attempt == Self.quickAttempts {
            return "attempt \(attempt) failed: " + reason + "; trying again every \(Int(Self.slowPause)) s until a helper answers"
        }
        return reason == lastFailure ? nil : "attempt \(attempt) failed: " + reason
    }
}
