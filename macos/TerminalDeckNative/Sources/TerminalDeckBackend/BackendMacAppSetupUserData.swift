import Foundation
import TerminalDeckNativeCore

/// Boot migration only, before the existing Store/path/provider owners start.
/// This does not own or load state.json, and never copies caches/credentials.
public protocol BackendMacAppSetupUserDataIO: Sendable {
    func ensureDirectory(_ path: String) async throws
    func exists(_ path: String) async throws -> Bool
    func copy(_ source: String, to target: String) async throws
}
public struct BackendMacAppSetupLocalUserDataIO: BackendMacAppSetupUserDataIO, Sendable {
    public init() {}
    public func ensureDirectory(_ path: String) async throws { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
    public func exists(_ path: String) async throws -> Bool { FileManager.default.fileExists(atPath: path) }
    public func copy(_ source: String, to target: String) async throws { try FileManager.default.copyItem(atPath: source, toPath: target) }
}
public enum BackendMacAppSetupUserData {
    public static func flag(_ arguments: [String]) -> String? { NativePlatformPaths.userDataFlag(arguments) }
    /// Returns the path the existing native EngineConfiguration/paths install
    /// must use. Explicit args/current pinned paths perform zero IO or setPath.
    public static func pin(current: String, arguments: [String], io: any BackendMacAppSetupUserDataIO,
                           adopt: @Sendable (String) async throws -> Void) async -> String {
        guard flag(arguments) == nil else { return current }
        let pinned = URL(fileURLWithPath: current).deletingLastPathComponent().appendingPathComponent("terminaldeck").path
        guard current != pinned else { return current }
        do {
            try await io.ensureDirectory(pinned)
            let destination = pinned + "/state.json", source = current + "/state.json"
            let destinationExists = try await io.exists(destination)
            if !destinationExists { if try await io.exists(source) { try await io.copy(source, to: destination) } }
            try await adopt(pinned); return pinned
        } catch { return current }
    }
}
