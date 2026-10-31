import Foundation
import TerminalDeckNativeCore
import Darwin

/// Source RegExp/replace semantics through the system WebKit JavaScript engine.
/// The fixed system JavaScript runner has no session data or supplied code.
/// Inputs are JSON arguments, never interpolated executable text.
enum BackendBrowserScrapingRegex {
    static let maximumTextBytes = 16_384
    /// JSC's VM watchdog does not interrupt native RegExp backtracking. Run
    /// the fixed JavaScript function in a disposable system JSC process instead.
    /// Only JSON arguments cross the boundary; patterns are never source code.
    private static func execute(_ body: String, arguments: [String]) throws -> Any {
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let json = try JSONSerialization.data(withJSONObject: arguments)
        process.arguments = ["-l", "JavaScript", "-e", """
          ObjC.import('Foundation');
          function run() {
            const a = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(
              $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile, $.NSUTF8StringEncoding)));
          """ + body + " }"]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = input
        process.standardOutput = output; process.standardError = errors
        // Drain concurrently: even a valid replacement can exceed a pipe buffer.
        let result = Output(), finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            try? input.fileHandleForWriting.write(contentsOf: json)
            try? input.fileHandleForWriting.close()
        }
        DispatchQueue.global(qos: .utility).async { result.set(output.fileHandleForReading.readDataToEndOfFile()) }
        DispatchQueue.global(qos: .utility).async { _ = errors.fileHandleForReading.readDataToEndOfFile() }
        if finished.wait(timeout: .now() + 1) == .timedOut {
            // This PID is our own disposable matcher. SIGKILL also stops native
            // engine work, unlike cancelling a Swift task or a JSC VM watchdog.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw BackendBrowserScrapingError.invalid("The pattern exceeded its one-second execution limit.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BackendBrowserScrapingError.invalid("The JavaScript engine refused this pattern or flags.")
        }
        let data = result.get()
        guard data.count <= 400_000 else { throw BackendBrowserScrapingError.invalid("The pattern output exceeds its bound.") }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    private final class Output: @unchecked Sendable {
        private let ready = DispatchSemaphore(value: 0)
        private var data = Data()
        func set(_ value: Data) { data = value; ready.signal() }
        func get() -> Data { ready.wait(); return data }
    }
    static func validate(_ pattern: String, flags: String = "") throws {
        _ = try firstCapture("", pattern: pattern, flags: flags)
    }
    static func firstCapture(_ text: String, pattern: String, flags: String) throws -> String? {
        try coverageMatch(text, pattern: pattern, flags: flags).map { $0.group ?? $0.whole }
    }
    static func coverageMatch(_ text: String, pattern: String, flags: String) throws -> (whole: String, group: String?)? {
        try coverageMatches(text, patterns: [pattern], flags: flags)[0]
    }
    static func coverageMatches(_ text: String, patterns: [String], flags: String) throws -> [(whole: String, group: String?)?] {
        guard text.utf8.count <= maximumTextBytes, patterns.count <= 16, patterns.allSatisfy({ $0.count <= 512 }),
              Set(flags).isSubset(of: Set("imsuy")), Set(flags).count == flags.count else {
            throw BackendBrowserScrapingError.invalid("Coverage text/pattern exceeds its bounds or uses unsupported/duplicate flags.")
        }
        // All generic patterns share one context and one deadline.
        let value = try execute("""
          return JSON.stringify(a.slice(2).map(pattern => {
            const found = new RegExp(pattern, a[1]).exec(a[0]);
            return found === null ? null : [found[0], found[1] === undefined ? null : found[1]];
          }));
          """, arguments: [text, flags] + patterns)
        guard let matches = value as? [Any], matches.count == patterns.count else {
            throw BackendBrowserScrapingError.invalid("Coverage pattern produced an invalid capture.")
        }
        return try matches.map { value in
            if value is NSNull { return nil }
            guard let parts = value as? [Any], parts.count == 2, let whole = parts[0] as? String else {
                throw BackendBrowserScrapingError.invalid("Coverage pattern produced an invalid capture.")
            }
            return (whole, parts[1] as? String)
        }
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
        let value = try execute("""
          const output = a[0].replace(new RegExp(a[1], a[3]), a[2]);
          if (output.length > 65536) throw new RangeError('Rewritten URL exceeds 65536 characters');
          return JSON.stringify(output);
          """, arguments: [source, pattern, replacement, flags])
        guard let result = value as? String, result.utf8.count <= 65_536 else {
            throw BackendBrowserScrapingError.invalid("The rendition rewrite did not return a URL within the 64 KiB bound.")
        }
        return result
    }
}
