import Foundation

/// What the engine says on its stdout.
///
/// Contract: exactly one of
///   `TD_NATIVE_READY <url>`    url like `http://127.0.0.1:<port>/?t=<token>`
///   `TD_NATIVE_FAILED <reason>`
public enum EngineSignal: Equatable, Sendable {
    case ready(URL)
    case failed(String)
}

public enum EngineLineParser {
    public static let readyPrefix = "TD_NATIVE_READY"
    public static let failedPrefix = "TD_NATIVE_FAILED"

    /// Parses one stdout line. Returns nil for ordinary output (not a protocol line).
    ///
    /// A READY line whose address is not a plain local `http://` address with a port
    /// is turned into `.failed`, so the shell never loads anything but the engine.
    public static func parse(_ rawLine: String) -> EngineSignal? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        if let rest = payload(of: line, prefix: readyPrefix) {
            guard !rest.isEmpty else {
                return .failed("The engine said it was ready but gave no address.")
            }
            guard let url = URL(string: rest), EngineOrigin(url: url) != nil else {
                return .failed("The engine reported an address that is not a local http address: \(redacted(rest))")
            }
            return .ready(url)
        }

        if let rest = payload(of: line, prefix: failedPrefix) {
            return .failed(rest.isEmpty ? "The engine reported a failure without a reason." : rest)
        }

        return nil
    }

    /// The text after `prefix`, if the line is exactly `prefix` or `prefix<space>…`.
    private static func payload(of line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        if rest.isEmpty { return "" }
        guard let first = rest.first, first == " " || first == "\t" else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

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

/// Splits a byte stream into lines. Bytes are kept until a full line arrives,
/// so a multi-byte character split across two reads is never mangled.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    /// Adds a chunk and returns every complete line in it (without the newline).
    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var lineData = pending[pending.startIndex..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }

    /// At end of stream: whatever is left without a trailing newline.
    public mutating func flush() -> String? {
        defer { pending = Data() }
        guard !pending.isEmpty else { return nil }
        var rest = pending
        if rest.last == 0x0D { rest = rest.dropLast() }
        return String(decoding: rest, as: UTF8.self)
    }
}
