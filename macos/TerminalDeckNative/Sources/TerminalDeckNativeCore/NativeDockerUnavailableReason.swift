import Foundation

/// Uses only an existing safe connection sentence. No credential or connection
/// lookup belongs here; absent cached evidence never implies a missing sign-in.
public struct NativeDockerUnavailableReason: Equatable, Sendable {
    public let title: String
    public let message: String

    public static func connection(problem: String?, fallback: String, isLocal: Bool) -> Self {
        let reason = problem?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isLocal, let reason, !reason.isEmpty {
            let lower = reason.lowercased()
            let signInAction = "Open Server connection below to check the username and password or SSH key."
            if lower == "there is no sign-in stored for this server yet. add the password or key and try again." {
                return Self(title: "This server has no saved sign-in", message: signInAction)
            }
            if lower.contains("sign-in was refused") || lower.contains("sign-in-refused") {
                return Self(title: "This server refused the sign-in", message: reason + "\n\n" + signInAction)
            }
            return Self(title: "Can’t reach this server",
                        message: reason + "\n\nOpen Server connection below to check the connection, then try again.")
        }
        let safeFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = safeFallback.isEmpty ? "No connection result is available." : safeFallback
        return Self(title: isLocal ? "Could not check this Mac" : "Could not check this server",
                    message: detail + (isLocal
                        ? "\n\nCheck the connection on this Mac, then try again."
                        : "\n\nOpen Server connection below to check the connection, then try again."))
    }
}
