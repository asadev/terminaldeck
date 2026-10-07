import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// dashboard-store.ts only: editable tile arrangements, excluding usage/cost
/// and insights. Caller project identity overrides any path in the payload.
public actor BackendDashboardStore {
    private let directory: URL
    private let ownership: NativeStateStore.Ownership
    public init(userData: URL, ownership: NativeStateStore.Ownership = .readOnly) throws {
        guard userData.isFileURL, userData.path.hasPrefix("/") else { throw NativeRPCError.invalidArguments("Dashboards require the app's own data directory") }
        directory = userData.appendingPathComponent("dashboards", isDirectory: true); self.ownership = ownership
    }
    public func load(projectPath: String) throws -> NativeRPCValue {
        let file = try path(projectPath)
        if ownership == .memory { return memory[file.lastPathComponent] ?? .null }
        guard FileManager.default.fileExists(atPath: file.path) else { return .null }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512 * 1024,
              let data = try? Data(contentsOf: file), data.count <= 512 * 1024,
              let value = try? NativeRPCValue.parseJSON(data, maximumBytes: 512 * 1024) else { return .null }
        return value
    }
    public func save(projectPath: String, layout: NativeRPCValue) throws {
        try writable()
        guard layout.fields != nil, let widgets = layout["widgets"].elements, widgets.count <= 200 else { throw NativeRPCError.invalidArguments("dashboard: refusing to save a payload that is not a layout") } // dashboard-store.ts:108
        let data = try layout.setting("projectPath", .string(projectPath)).encodedJSON(pretty: true)
        guard data.count <= 512 * 1024 else { throw NativeRPCError.invalidArguments("dashboard: payload too large to save") } // dashboard-store.ts:117
        let file = try path(projectPath)
        if ownership == .memory { memory[file.lastPathComponent] = layout.setting("projectPath", .string(projectPath)); return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    public func clear(projectPath: String) throws {
        try writable(); let file = try path(projectPath)
        if ownership == .memory { memory[file.lastPathComponent] = nil; return }
        do { try FileManager.default.removeItem(at: file) } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
    }
    private var memory: [String: NativeRPCValue] = [:]
    private func writable() throws { guard ownership == .exclusive || ownership == .memory else { throw NativeRPCError(code: "read-only", message: "Node still owns dashboard persistence; native writes are disabled") } }
    private func path(_ project: String) throws -> URL {
        guard project.hasPrefix("/"), !project.contains("\0") else { throw NativeRPCError.invalidArguments("dashboard: an absolute project path is required") } // dashboard-store.ts:51
        // dashboard-store.ts:35-36: node `resolve` then `basename`, purely lexical; basename('/') is '' so the root becomes `project-<hash>`.
        var segments: [Substring] = []
        for part in project.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = segments.popLast(); continue }
            segments.append(part)
        }
        let canonical = "/" + segments.joined(separator: "/")
        let slug = String((segments.last.map(String.init) ?? "").replacingOccurrences(of: "[^a-zA-Z0-9._-]+", with: "-", options: .regularExpression).prefix(40))
        let digest = String(SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10))
        return directory.appendingPathComponent((slug.isEmpty ? "project" : slug) + "-" + digest + ".json")
    }
}
