import Foundation
import TerminalDeckNativeCore

/// The actual launch envelope produced by BackendStaysFixedEngine. Production
/// owns the native process; parity fixtures can capture it without spawning.
public struct BackendStaysFixedProcessPlan: Sendable {
    public let command: String, arguments: [String], cwd: String, environment: [String: String]
    public let timeoutMilliseconds: Int
}
public typealias BackendStaysFixedExecution = @Sendable (
    BackendStaysFixedProcessPlan, @escaping @Sendable (NativeRPCValue) -> Void
) async -> BackendStaysFixedRunResult

/// One stderr stream, retaining ordinary lines and turning only the source
/// record-separator-prefixed lines into normalized progress. The native pipe
/// owner and deterministic chunk fixtures use this same parser.
public struct BackendStaysFixedOutputParser: Sendable {
    private var pending = Data()
    public private(set) var stderr = Data()
    public init() {}
    public mutating func receive(_ bytes: Data) -> [NativeRPCValue] {
        pending.append(bytes); var events: [NativeRPCValue] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
            if line.starts(with: [30, 83, 70, 32]) {
                if let raw = try? NativeRPCValue.parseJSON(line.dropFirst(4)), raw != .null {
                    events.append(.object([
                        .init("type", .string(raw["type"].string ?? "note")),
                        .init("message", .string(raw["message"].string ?? "")),
                        .init("journey", raw["journey"].string.map(NativeRPCValue.string) ?? .null),
                        .init("count", raw["count"].number.map(NativeRPCValue.number) ?? .null),
                        .init("at", .number(raw["at"].number ?? 0))
                    ]))
                }
            } else { stderr.append(line); stderr.append(10) }
        }
        return events
    }
    public mutating func finish() {
        if !pending.starts(with: [30, 83, 70, 32]) { stderr.append(pending) }
        pending.removeAll()
    }
}
