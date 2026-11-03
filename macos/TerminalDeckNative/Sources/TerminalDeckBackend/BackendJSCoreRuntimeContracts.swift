import Foundation
@preconcurrency import JavaScriptCore
import TerminalDeckNativeCore

public enum BackendJSCoreRuntimeLimits {
    public static let handshakeMilliseconds = 10_000
    public static let requestMilliseconds = 30_000
    public static let messageBytes = 256 * 1024
    public static let incomingRequests = 8
    public static let shutdownMilliseconds = 1000
    public static let maximumTimers = 1024
    /// Helper-only raw input staging bound, not a new RPC request limit.
    public static let queuedInputBytes = 32 * messageBytes
}
public struct BackendJSCoreRuntimeConfiguration: Sendable {
    public let entryURL: URL
    public let folderURL: URL
    public let dataURL: URL
    public let environment: [String: String]
    public init(entryURL: URL, folderURL: URL, dataURL: URL, environment: [String: String]) throws {
        let entry = entryURL.standardizedFileURL.resolvingSymlinksInPath()
        let folder = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        let data = dataURL.standardizedFileURL.resolvingSymlinksInPath()
        guard [entryURL, folderURL, dataURL].allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.contains("\0") }),
              folder.path != "/", data.path != "/", entry.path.hasPrefix(folder.path + "/"),
              ["js", "mjs", "cjs"].contains(entry.pathExtension.lowercased()) else {
            throw BackendPluginsError(-32003, "The JavaScriptCore plugin entry is unavailable: it must be inside its own folder.")
        }
        self.entryURL = entry; self.folderURL = folder; self.dataURL = data
        // Reuse the plugin host's positive environment composition. Removing
        // the old inert flag does not grant any additional environment reach.
        var clean = BackendPluginsSandbox.environment(home: data.path, parent: environment)
        clean.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        self.environment = clean
    }
}

/// The module worker supplies this compatibility layer. It may touch JSContext
/// only on the helper's main thread. Capability methods use raw stdio exclusively;
/// they do not call tasks, goals, knowledge, notifications or consent directly.
public protocol BackendJSCoreRuntimeBootstrap: Sendable {
    func install(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) throws
    func loadEntry(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) throws
    func shutdown(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge)
}
public struct BackendJSCoreRuntimeUnavailableBootstrap: BackendJSCoreRuntimeBootstrap {
    public init() {}
    public func install(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) throws {
        throw BackendPluginsError(-32003, "The JavaScriptCore plugin module/stdio compatibility layer is unavailable.")
    }
    public func loadEntry(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) throws {
        throw BackendPluginsError(-32003, "The JavaScriptCore plugin module loader is unavailable.")
    }
    public func shutdown(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) {}
}

/// Small ownership wrapper: work may be enqueued across threads, but all JS
/// callbacks/values are executed and released on their single VM owner thread.
final class BackendJSCoreRuntimeWork: @unchecked Sendable {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func run() { let action = action; self.action = nil; action?() }
}
public final class BackendJSCoreRuntimeBridge: @unchecked Sendable {
    private weak var runtime: BackendJSCoreRuntimeVM?
    private let writeOutput: @Sendable (Data) -> Void
    private let writeError: @Sendable (Data) -> Void
    private let terminate: @Sendable (Int32) -> Void
    init(runtime: BackendJSCoreRuntimeVM, output: @escaping @Sendable (Data) -> Void,
         stderr: @escaping @Sendable (Data) -> Void, exit: @escaping @Sendable (Int32) -> Void) {
        self.runtime = runtime; writeOutput = output; writeError = stderr; terminate = exit
    }
    public func output(_ data: Data) { writeOutput(data) }
    public func stderr(_ data: Data) { writeError(data) }
    /// The helper supplies a hard OS exit; never dispatch this onto the VM.
    public func exit(_ code: Int32) { terminate(code) }
    public func setInputHandlers(data: @escaping (Data) -> Void, end: @escaping () -> Void) {
        runtime?.setInputHandlers(data: data, end: end)
    }
    public func enqueueVM(_ callback: @escaping () -> Void) { runtime?.enqueue(BackendJSCoreRuntimeWork(callback)) }
    public func schedule(delayMS: Double, repeatMS: Double?, callback: @escaping () -> Void) -> Int {
        runtime?.schedule(delayMS: delayMS, repeatMS: repeatMS, callback: callback) ?? 0
    }
    public func cancelTimer(_ id: Int) { runtime?.cancelTimer(id) }
}
