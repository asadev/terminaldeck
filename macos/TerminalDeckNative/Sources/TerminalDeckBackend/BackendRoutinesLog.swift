import Foundation
import TerminalDeckNativeCore

/// log.ts keeps routine rows in the existing copilot action log.
public struct BackendRoutinesLogEntry: Sendable, Equatable {
    public let action: String
    public let routine: String
    public let runID: String?
    public let outcome: String
    public let detail: String?
    public let data: NativeRPCValue?
    public init(action: String, routine: String, runID: String? = nil, outcome: String,
                detail: String? = nil, data: NativeRPCValue? = nil) {
        self.action = action; self.routine = routine; self.runID = runID
        self.outcome = outcome; self.detail = detail; self.data = data
    }
    public var wireValue: NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("action", .string(action))]
        if let detail { fields.append(.init("detail", .string(detail))) }
        fields.append(.init("routine", .string(routine)))
        if let runID { fields.append(.init("runId", .string(runID))) }
        fields.append(.init("outcome", .string(outcome)))
        if let data { fields.append(.init("data", data)) }
        return .object(fields)
    }
}

public typealias BackendRoutinesLogger = @Sendable (BackendRoutinesLogEntry) -> Void

/// Supply the Hoot home's one shared append writer here when composing the app.
public protocol BackendRoutinesActionAppending: Sendable {
    func appendRoutineAction(_ value: NativeRPCValue)
}

/// Compatible disk sink for a shell without an assembled Hoot home yet. It
/// never reads or writes until append is called, and needs an explicit data URL.
/// Sharing this instance with Hoot avoids two independently rotating writers.
public final class BackendRoutinesActionLog: BackendRoutinesActionAppending, @unchecked Sendable {
    public static let limitBytes = BackendCopilotHome.logLimitBytes
    public let paths: BackendCopilotPaths
    public var directory: URL { URL(fileURLWithPath: paths.log, isDirectory: true) }
    public var actions: URL { URL(fileURLWithPath: paths.actions) }
    private let lock = NSLock()
    private var failure: String?
    private let now: @Sendable () -> Date
    public init(userData: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        paths = BackendCopilotPaths(userData: userData.path)
        self.now = now
    }
    public var lastError: String? { lock.withLock { failure } }
    public var logger: BackendRoutinesLogger { { [self] entry in appendRoutineAction(entry.wireValue) } }
    public func appendRoutineAction(_ value: NativeRPCValue) {
        lock.withLock {
            do {
                try BackendCopilotStorageIO.mkdir(paths.log)
                if (BackendCopilotStorageIO.bytes(paths.actions) ?? 0) >= Self.limitBytes {
                    try BackendCopilotStorageIO.rename(paths.actions, paths.actions + ".1")
                }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let row = NativeRPCValue.object([.init("at", .string(formatter.string(from: now())))])
                    .merging(value)
                try BackendCopilotStorageIO.write(paths.actions, String(decoding: row.encodedJSON(), as: UTF8.self) + "\n", append: true)
                failure = nil
            } catch { failure = error.localizedDescription }
        }
    }
}

public enum BackendRoutinesLogging {
    public static func logger(using sink: any BackendRoutinesActionAppending) -> BackendRoutinesLogger {
        { entry in sink.appendRoutineAction(entry.wireValue) }
    }
}
