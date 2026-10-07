import Foundation
import TerminalDeckNativeCore
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Source RegExp/replace semantics through the system WebKit JavaScript engine.
/// No DOM, filesystem, network, cookies, host callbacks, Node or Chromium are
/// present. Inputs are function arguments, never interpolated executable text.
enum BackendBrowserScrapingRegex {
    static func validate(_ pattern: String, flags: String = "") throws {
        _ = try firstCapture("", pattern: pattern, flags: flags)
    }
    static func firstCapture(_ text: String, pattern: String, flags: String) throws -> String? {
        guard text.utf8.count <= 1_048_576, pattern.count <= 512, Set(flags).isSubset(of: Set("imsuy")), Set(flags).count == flags.count else {
            throw BackendBrowserScrapingError.invalid("Coverage text/pattern exceeds its bounds or uses flags outside source i/m/s/u/y.")
        }
        #if canImport(JavaScriptCore)
        guard let context = JSContext(), let function = context.evaluateScript("""
          (function(text, pattern, flags) {
            const found = new RegExp(pattern, flags).exec(text);
            return found === null ? null : String(found[1] === undefined ? found[0] : found[1]);
          })
          """) else { throw BackendBrowserScrapingError.unsupported("The system JavaScriptCore regex engine is unavailable.") }
        context.exception = nil
        let value = function.call(withArguments: [text, pattern, flags])
        guard context.exception == nil else { throw BackendBrowserScrapingError.invalid("The system JavaScript engine refused this coverage pattern or flags.") }
        guard let value, !value.isNull, !value.isUndefined else { return nil }
        guard value.isString else { throw BackendBrowserScrapingError.invalid("Coverage pattern produced an invalid capture.") }
        return value.toString()
        #else
        throw BackendBrowserScrapingError.unsupported("Source coverage matching requires the system JavaScriptCore framework.")
        #endif
    }
    static func total(_ captured: String) -> Double? {
        let text = captured.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        guard !text.isEmpty else { return nil }
        let digits = Set("0123456789")
        if text.allSatisfy({ digits.contains($0) }) {
            return Double(text).flatMap { $0 <= 9_007_199_254_740_991 ? $0 : nil }
        }
        let separators = Set(text.filter { !digits.contains($0) })
        guard separators.count == 1, let separator = separators.first, separator == "." || separator == "," || separator.isWhitespace else { return nil }
        let groups = text.split(separator: separator, omittingEmptySubsequences: false)
        guard groups.count >= 2, (1...3).contains(groups[0].count), groups.allSatisfy({ $0.allSatisfy { digits.contains($0) } }),
              groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        return Double(groups.joined()).flatMap { $0 <= 9_007_199_254_740_991 ? $0 : nil }
    }
    static func replace(_ source: String, pattern: String, replacement: String, flags: String) throws -> String {
        guard source.utf8.count <= 65_536, pattern.count <= 512, replacement.count <= 512,
              Set(flags).isSubset(of: Set("gimsuy")), Set(flags).count == flags.count else {
            throw BackendBrowserScrapingError.invalid("Rendition regex inputs exceed their bounds or contain unsupported/duplicate source flags.")
        }
        #if canImport(JavaScriptCore)
        guard let context = JSContext(), let function = context.evaluateScript("""
          (function (source, pattern, replacement, flags) {
            const expression = new RegExp(pattern, flags);
            // ECMAScript owns UTF-16 matching, Unicode/sticky flags, captures,
            // zero-width advancement and every standard replacement token.
            const output = source.replace(expression, replacement);
            if (output.length > 65536) throw new RangeError('Rewritten URL exceeds 65536 characters');
            return output;
          })
          """) else { throw BackendBrowserScrapingError.unsupported("The system JavaScriptCore regex engine is unavailable.") }
        // Every context is private to this explicit call and carries no native
        // objects or session data beyond its bounded URL/string inputs.
        context.exception = nil
        let value = function.call(withArguments: [source, pattern, replacement, flags])
        if context.exception != nil {
            throw BackendBrowserScrapingError.invalid("The system JavaScript engine refused this rendition pattern, flags or rewritten URL bound.")
        }
        guard let value, value.isString, let result = value.toString(), result.utf8.count <= 65_536 else {
            throw BackendBrowserScrapingError.invalid("The rendition rewrite did not return a URL within the 64 KiB bound.")
        }
        return result
        #else
        throw BackendBrowserScrapingError.unsupported("Exact source JavaScript regex matching requires the system JavaScriptCore framework; no substitute matcher was used.")
        #endif
    }
}
