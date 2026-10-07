import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendJSCoreTransportLaunch: Sendable {
    public let command: String
    public let arguments: [String]
    public let cwd: String
    public let environment: [String: String]
    public let helper: String
}

/// Uses the existing JSON-RPC process, source Seatbelt plan and positive
/// environment composition. This is not a second host or consent dispatcher.
public struct BackendJSCoreTransportFactory: Sendable {
    public let helperExecutable: URL
    public init(helperExecutable: URL) throws {
        guard helperExecutable.isFileURL, helperExecutable.path.hasPrefix("/"), helperExecutable.path != "/", !helperExecutable.path.contains("\0") else {
            throw BackendPluginsError(-32003, "The isolated JavaScriptCore helper executable is unavailable.")
        }
        self.helperExecutable = helperExecutable.standardizedFileURL
    }
    /// The one value needed by BackendPluginsHost's existing runtime argument.
    /// The integration owner supplies its bundled, signed native helper, never
    /// the SwiftUI executable and never a fallback to Node or an installed app.
    public func runtimePath() throws -> String {
        let helper = helperExecutable.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: helper.path),
              (try? helper.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw BackendPluginsError(-32003, "The isolated JavaScriptCore helper executable is unavailable.")
        }
        return helper.path
    }
    public func launch(folder: URL, data: URL, main: String, parentEnvironment: [String: String]) throws -> BackendJSCoreTransportLaunch {
        let config = try BackendJSCoreRuntimeConfiguration(entryURL: folder.appendingPathComponent(main), folderURL: folder, dataURL: data, environment: parentEnvironment)
        let helper = try runtimePath()
        guard access("/usr/bin/sandbox-exec", X_OK) == 0 else {
            throw BackendPluginsError(-32003, "The JavaScriptCore plugin sandbox is unavailable on this Mac.")
        }
        let launch = BackendPluginsSandbox.command(runtime: helper, main: config.entryURL.path, folder: config.folderURL.path, data: config.dataURL.path)
        return .init(command: launch.0, arguments: launch.1, cwd: config.folderURL.path, environment: config.environment, helper: helper)
    }
    public func process(folder: URL, data: URL, main: String, parentEnvironment: [String: String],
                        onRequest: @escaping BackendPluginsProcess.RequestHandler,
                        onExit: @escaping @Sendable (String) async -> Void) throws -> BackendPluginsProcess {
        let launch = try launch(folder: folder, data: data, main: main, parentEnvironment: parentEnvironment)
        return BackendPluginsProcess(command: launch.command, arguments: launch.arguments, cwd: launch.cwd,
            environment: launch.environment, timeoutMilliseconds: BackendJSCoreRuntimeLimits.requestMilliseconds,
            maximumBytes: BackendJSCoreRuntimeLimits.messageBytes, onRequest: onRequest, onExit: onExit)
    }
}

/// Byte framing only; RPC validation/IDs/errors/8 incoming calls stay in the
/// existing BackendPluginsProcess. The helper rejects unbounded incoming lines
/// before it can accumulate them, while preserving all original stream bytes.
public struct BackendJSCoreTransportLineBudget: Sendable {
    public let maximumBytes: Int
    private var pendingBytes = 0
    public init(maximumBytes: Int = BackendJSCoreRuntimeLimits.messageBytes) { self.maximumBytes = max(64, maximumBytes) }
    public mutating func accept(_ bytes: Data) throws {
        for byte in bytes {
            if byte == 10 { pendingBytes = 0 }
            else {
                guard pendingBytes < maximumBytes else { throw BackendPluginsError(-32005, "that request is larger than \(maximumBytes) bytes") }
                pendingBytes += 1
            }
        }
    }
}
