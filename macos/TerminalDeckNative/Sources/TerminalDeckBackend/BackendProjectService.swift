import Foundation
import TerminalDeckNativeCore

/// Native project/folder operations from project-tools.ts and the app's picker
/// seams. Saving/removing uses the existing single-owner native Store actor.
public struct BackendProjectService: Sendable {
    public let store: NativeStateStore
    public let files: BackendFilesystemService
    public let home: String
    public let appDataRoot: URL
    private let sessions: @Sendable () async -> [BackendSessionMeta]
    private let show: (@Sendable (String) async throws -> Bool)?
    public init(store: NativeStateStore, files: BackendFilesystemService, home: String, appDataRoot: URL,
                liveSessions: @escaping @Sendable () async -> [BackendSessionMeta], showInWindow: (@Sendable (String) async throws -> Bool)? = nil) throws {
        guard home.hasPrefix("/"), appDataRoot.isFileURL, appDataRoot.path.hasPrefix("/") else { throw NativeRPCError.invalidArguments("Project operations need the actual home and app-data paths") }
        self.store = store; self.files = files; self.home = home; self.appDataRoot = appDataRoot
        sessions = liveSessions; show = showInWindow
    }
    public func list() async -> NativeRPCValue { .array(await store.getProjects()) }
    public func requireKnown(_ path: String, restrictedTo projectRoot: String? = nil) async throws -> String {
        guard await store.getProjects().contains(where: { $0["path"].string == path }) else { throw NativeRPCError(code: "access-denied", message: "That folder is not an open project") }
        if let projectRoot {
            let requested = try BackendFilesystemAuthority.canonical(URL(fileURLWithPath: path))
            let allowed = try BackendFilesystemAuthority.canonical(URL(fileURLWithPath: projectRoot))
            guard BackendFilesystemAuthority.within(requested, allowed) else { throw NativeRPCError(code: "access-denied", message: "That project is outside this MCP caller's bound project") }
        }
        return path
    }
    public func browse(path: String? = nil, showHidden: Bool = false, context: NativeRPCContext) async throws -> NativeRPCValue {
        let path = path ?? home
        let listing = try await files.list(root: path, options: .init(showIgnored: true), context: context)
        let opened = Set((await store.getProjects()).compactMap { $0["path"].string })
        let folders = (listing["entries"].elements ?? []).filter { $0["kind"].string == "dir" && $0["blocked"].bool != true && (showHidden || !($0["name"].string ?? "").hasPrefix(".")) }
        var rows: [NativeRPCValue] = []
        for entry in folders.prefix(300) {
            try Task.checkCancellation()
            let name = entry["name"].string ?? ""
            let full = URL(fileURLWithPath: path).appendingPathComponent(name).path
            let repo = (try? await files.isDirectory(URL(fileURLWithPath: full).appendingPathComponent(".git").path, context: context)) ?? false
            rows.append(.object([.init("name", .string(name)), .init("path", .string(full)), .init("open", .bool(opened.contains(full))), .init("repo", .bool(repo))]))
        }
        return .object([.init("path", .string(path)), .init("home", .string(home)), .init("folders", .array(rows)),
            .init("more", .bool(listing["truncated"].bool == true || folders.count > rows.count))])
    }
    public func add(path: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        let actual = try await files.authority.authorize(path, context: context)
        let own = appDataRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard !BackendFilesystemAuthority.within(actual, own) else { throw NativeRPCError(code: "access-denied", message: "This app's own storage cannot be opened as a project") }
        guard try await files.isDirectory(actual.path, context: context) else { throw NativeRPCError.invalidArguments("The selected project path is not a folder") }
        let already = await store.getProjects().contains { $0["path"].string == path }
        _ = try await store.addProject(path)
        let inWindow = (try? await show?(path)) ?? false
        return .object([.init("path", .string(path)), .init("already", .bool(already)), .init("inWindow", .bool(inWindow)),
            .init("note", .string(inWindow ? "It is open, and the sidebar shows it." : "It is saved as open. The sidebar will show it when a window next takes the project."))])
    }
    public func remove(path: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        _ = try await requireKnown(path)
        _ = try await files.authority.authorize(path, context: context)
        try await store.removeProject(path)
        let running = await sessions().filter { $0.cwd == path && $0.exitCode == nil }.map(\.id)
        return .object([.init("path", .string(path)), .init("removed", .bool(true)), .init("stillRunning", .array(running.map(NativeRPCValue.string)))])
    }
    public func liveSessions() async -> [BackendSessionMeta] { await sessions() }
}
