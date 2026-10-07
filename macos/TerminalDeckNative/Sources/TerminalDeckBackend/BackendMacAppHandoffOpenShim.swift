import Foundation
import TerminalDeckNativeCore

public protocol BackendMacAppHandoffShimFiles: Sendable {
    func exists(_ path: String) async -> Bool
    func remove(_ path: String) async throws
    func makeDirectory(_ path: String) async throws
    func write(_ path: String, text: String, mode: Int) async throws
}
public struct BackendMacAppHandoffShimDisk: BackendMacAppHandoffShimFiles, Sendable {
    public init() {}
    public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    public func remove(_ path: String) throws { if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) } }
    public func makeDirectory(_ path: String) throws { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
    public func write(_ path: String, text: String, mode: Int) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)); try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
}
public struct BackendMacAppHandoffShimInstalled: Sendable, Equatable { public let directory: String; public let browser: String }
public actor BackendMacAppHandoffOpenShim {
    public static let directoryName = "shim"
    private let files: any BackendMacAppHandoffShimFiles
    private var installed: BackendMacAppHandoffShimInstalled?
    public init(files: any BackendMacAppHandoffShimFiles) { self.files = files }
    public static func directory(_ dataRoot: String) -> String { URL(fileURLWithPath: dataRoot).appendingPathComponent(directoryName).path }
    public static func prepend(path: String, shim: String?) -> String { guard let shim, !shim.isEmpty else { return path }; return ([shim] + path.components(separatedBy: ":").filter { $0 != shim }).joined(separator: ":") }
    public func current() -> BackendMacAppHandoffShimInstalled? { installed }
    public func write(dataRoot: String, configPath: String, platform: String = "darwin") async throws -> BackendMacAppHandoffShimInstalled? {
        guard platform == "darwin" else { return nil }
        try await remove(dataRoot: dataRoot)
        let folder = Self.directory(dataRoot); try await files.makeDirectory(folder)
        guard await files.exists("/usr/bin/open") else { try await remove(dataRoot: dataRoot); return nil }
        let path = URL(fileURLWithPath: folder).appendingPathComponent("open").path
        try await files.write(path, text: BackendMacAppHandoffOpenShimScript.make(realOpener: "/usr/bin/open", configPath: configPath), mode: 0o755)
        let result = BackendMacAppHandoffShimInstalled(directory: folder, browser: path); installed = result; return result
    }
    public func remove(dataRoot: String) async throws { installed = nil; try await files.remove(Self.directory(dataRoot)) }
}

/// The script's exact branch contract, exercised with fake endpoint/opener effects.
/// The generated POSIX script remains the CLI entry; this does not spawn a process.
public enum BackendMacAppHandoffShimInvocation {
    public static func requestsApp(_ args: [String]) -> Bool {
        guard args.count == 1 else { return false }
        return ["http://", "https://", "HTTP://", "HTTPS://", "Http://", "Https://"].contains { args[0].hasPrefix($0) }
    }
    public static func run(arguments: [String], sessionID: String?,
                           ask: @Sendable (String, String?) async throws -> String,
                           opener: @Sendable ([String]) async throws -> Int) async throws -> (status: Int, stdout: String) {
        guard requestsApp(arguments) else { return (try await opener(arguments), "") }
        let answer = (try? await ask(arguments[0], sessionID)) ?? "", lines = answer.components(separatedBy: "\n")
        let route = lines.first ?? ""
        var remainder = Array(lines.dropFirst()).joined(separator: "\n")
        while remainder.hasSuffix("\n") { remainder.removeLast() }
        if route == "tab" { return (0, remainder + "\n") }
        let printed = remainder.isEmpty ? "Terminal Deck did not take this link — opening it in your default browser." : remainder
        return (try await opener(arguments), printed + "\n")
    }
}
