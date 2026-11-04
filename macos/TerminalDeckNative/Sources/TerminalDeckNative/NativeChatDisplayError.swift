import Foundation

/// Provider prose stays useful; runtime diagnostics belong in logs, never the chat footer.
enum NativeChatDisplayError {
    static func text(_ text: String) -> String {
        if text.localizedCaseInsensitiveContains("CancellationError") || text.localizedCaseInsensitiveContains("NSURLErrorDomain Code=-999") { return "" }
        if text.contains("Error Domain=") || text.contains("Swift.") || text.contains("The operation couldn’t be completed.") || text.contains("The operation couldn't be completed.") ||
            text.range(of: #"\([A-Za-z][A-Za-z0-9_.]* error -?\d+\.?(?:\))"#, options: .regularExpression) != nil {
            return "Couldn’t complete that chat action. Please try again."
        }
        return text
    }
    static func message(_ error: Error) -> String? {
        if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { return nil }
        let safe = text(error.localizedDescription)
        return safe.isEmpty ? nil : safe
    }
}
