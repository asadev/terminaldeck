import Foundation

/// Hides the page address's per-launch key before it reaches a log or the screen.
public enum EngineLineParser {
    /// Strips the query (which carries the bridge token) so it never reaches a log or the screen.
    public static func redacted(_ address: String) -> String {
        guard let q = address.firstIndex(of: "?") else { return address }
        return String(address[..<q]) + "?…"
    }

    /// The ready URL with its token hidden, for logging.
    public static func redacted(_ url: URL) -> String {
        redacted(url.absoluteString)
    }
}
