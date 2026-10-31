import Foundation
import TerminalDeckNativeCore

/// updates/update-error.ts. Classification precedes stripping so a network
/// code buried in a feed/stack still produces the source's retryable sentence.
public enum BackendAppUpdateError {
    public struct Failure: Sendable, Equatable {
        public let text: String, transient: Bool
        public var wire: NativeRPCValue { .object([.init("text", .string(text)), .init("transient", .bool(transient))]) }
    }
    public static let maximumText = 120
    public static let transientCodes = ["ERR_NETWORK_CHANGED", "ERR_INTERNET_DISCONNECTED", "ERR_NAME_NOT_RESOLVED", "ERR_NAME_RESOLUTION_FAILED",
        "ERR_NETWORK_IO_SUSPENDED", "ERR_CONNECTION_RESET", "ERR_CONNECTION_CLOSED", "ERR_CONNECTION_ABORTED", "ERR_CONNECTION_TIMED_OUT",
        "ERR_TIMED_OUT", "ERR_ADDRESS_UNREACHABLE", "ERR_EMPTY_RESPONSE", "ENOTFOUND", "EAI_AGAIN", "ECONNRESET", "ETIMEDOUT", "ENETDOWN", "ENETUNREACH", "EHOSTUNREACH"]
    public static func describe(_ value: NativeRPCValue) -> Failure {
        let message: String
        if let text = value.string { message = BackendSharedText.trim(text) }
        else if let text = value["message"].string, !BackendSharedText.trim(text).isEmpty { message = BackendSharedText.trim(text) }
        else { let text = BackendSharedText.trim(BackendMcpClientValue.jsString(value)); message = text == "[object Object]" ? "" : text }
        return classify(message)
    }
    public static func describe(_ error: any Error) -> Failure {
        // Foundation supplies numeric network codes rather than Chromium's
        // textual codes. Preserve the same user-facing transient category.
        if let url = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .timedOut].contains(url.code) {
            return Failure(text: "No connection to the update server.", transient: true)
        }
        let message = BackendSharedText.trim((error as? NativeRPCError)?.message ?? error.localizedDescription)
        return classify(message.isEmpty ? "Error" : message)
    }
    private static func classify(_ message: String) -> Failure {
        let upper = message.uppercased()
        if transientCodes.contains(where: upper.contains) { return Failure(text: "No connection to the update server.", transient: true) }
        if ["RATE LIMIT", "HTTP 429", "STATUS CODE 429"].contains(where: upper.contains) { return Failure(text: "GitHub is rate-limiting this machine. Try again later.", transient: true) }
        if upper.contains("ENOSPC") || upper.contains("NO SPACE LEFT") { return Failure(text: "Not enough disk space for the update.", transient: false) }
        if upper.contains("EACCES") || upper.contains("EPERM") { return Failure(text: "The app could not write the update.", transient: false) }
        let text = firstSentence(message)
        return Failure(text: text.isEmpty ? "The update check failed." : text, transient: false)
    }
    public static func firstSentence(_ message: String) -> String {
        var text = message
        for pattern in [#"(\bXML:\s*)?<\?xml|<html|<feed\b"#, #"\s+at\s+\S+\s*\("#] {
            if let regex = try? NSRegularExpression(pattern: BackendSharedText.javascriptPattern(pattern), options: pattern.contains("XML") ? [.caseInsensitive] : []),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text) { text = String(text[..<range.lowerBound]) }
        }
        text = BackendSharedText.trim(text.components(separatedBy: "\n").first ?? "")
        text = text.replacingOccurrences(of: BackendSharedText.javascriptPattern(#"\s*Error:\s*"#), with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: BackendSharedText.javascriptPattern(#"\s+"#), with: " ", options: .regularExpression)
        text = BackendSharedText.trim(text)
        if text.utf16.count > maximumText {
            text = BackendSharedText.prefix(text, maximumText - 1).replacingOccurrences(of: BackendSharedText.whitespaceClass + "+$", with: "", options: .regularExpression) + "…"
        }
        return text
    }
}
