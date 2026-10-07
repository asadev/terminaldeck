import Foundation
import TerminalDeckNativeCore

public struct BackendDeckToolsProjectServices: Sendable {
    public let projects: BackendProjectService
    public let git: BackendGitService
    public let dev: BackendDevServers
    public let ports: BackendDevPortDiscovery
    public let dashboards: BackendDashboardStore
    public let artifacts: BackendArtifactsIndex
    public let devAccess: (any BackendDeckToolsProjectDevAccess)?
    public init(projects: BackendProjectService, git: BackendGitService, dev: BackendDevServers,
                ports: BackendDevPortDiscovery, dashboards: BackendDashboardStore, artifacts: BackendArtifactsIndex,
                devAccess: (any BackendDeckToolsProjectDevAccess)? = nil) {
        self.projects = projects; self.git = git; self.dev = dev; self.ports = ports
        self.dashboards = dashboards; self.artifacts = artifacts
        self.devAccess = devAccess
    }
}

/// The same domain reads/effects the source tool factory uses. Native adapters
/// keep the existing owners; deterministic tests can supply raw folder rows.
public protocol BackendDeckToolsProjectProvider: Sendable {
    var home: String { get }
    var appDataRoot: String { get }
    var devAccess: (any BackendDeckToolsProjectDevAccess)? { get }
    func listProjects() async -> [NativeRPCValue]
    func listFolder(path: String, context: NativeRPCContext) async throws -> NativeRPCValue
    func isFolder(_ path: String, context: NativeRPCContext) async throws -> Bool
    func add(path: String, context: NativeRPCContext) async throws -> NativeRPCValue
    func remove(path: String, context: NativeRPCContext) async throws -> NativeRPCValue
    func gitStatus(cwd: String, context: NativeRPCContext) async throws -> NativeRPCValue
    func gitInitialize(cwd: String, context: NativeRPCContext) async throws -> NativeRPCValue
    func devStart(folder: String, context: NativeRPCContext) async throws -> NativeRPCValue
    func devStatus(folder: String, context: NativeRPCContext) async throws -> NativeRPCValue
    func scanPorts(force: Bool) async throws -> [NativeRPCValue]
    func dashboardLoad(projectPath: String) async throws -> NativeRPCValue
    func dashboardSave(projectPath: String, layout: NativeRPCValue) async throws
    func dashboardClear(projectPath: String) async throws
    func artifactsList(project: String, options: BackendArtifactScanOptions, context: NativeRPCContext) async throws -> NativeRPCValue
    func artifactHistory(project: String, relative: String, options: BackendArtifactScanOptions, context: NativeRPCContext) async throws -> NativeRPCValue
}
public extension BackendDeckToolsProjectProvider { var devAccess: (any BackendDeckToolsProjectDevAccess)? { nil } }
public struct BackendDeckToolsNativeProjectProvider: BackendDeckToolsProjectProvider {
    private let services: BackendDeckToolsProjectServices
    public init(_ services: BackendDeckToolsProjectServices) { self.services = services }
    public var home: String { services.projects.home }
    public var appDataRoot: String { services.projects.appDataRoot.path }
    public var devAccess: (any BackendDeckToolsProjectDevAccess)? { services.devAccess }
    public func listProjects() async -> [NativeRPCValue] { await services.projects.list().elements ?? [] }
    public func listFolder(path: String, context: NativeRPCContext) async throws -> NativeRPCValue { try await services.projects.files.list(root:path,options:.init(showIgnored:true),context:context) }
    public func isFolder(_ path: String, context: NativeRPCContext) async throws -> Bool { try await services.projects.files.isDirectory(path,context:context) }
    public func add(path: String, context: NativeRPCContext) async throws -> NativeRPCValue { try await services.projects.add(path:path,context:context) }
    public func remove(path: String, context: NativeRPCContext) async throws -> NativeRPCValue { try await services.projects.remove(path:path,context:context) }
    public func gitStatus(cwd: String, context: NativeRPCContext) async throws -> NativeRPCValue { try await services.git.status(cwd:cwd,context:context) }
    public func gitInitialize(cwd: String, context: NativeRPCContext) async throws -> NativeRPCValue { try await services.git.initialize(cwd:cwd,context:context) }
    public func devStart(folder: String, context: NativeRPCContext) async throws -> NativeRPCValue { try await services.dev.start(folder:folder,context:context) }
    public func devStatus(folder: String, context: NativeRPCContext) async throws -> NativeRPCValue { try await services.dev.status(folder:folder,context:context) }
    public func scanPorts(force: Bool) async throws -> [NativeRPCValue] { try await services.ports.scan(force:force).map(\.wireValue) }
    public func dashboardLoad(projectPath: String) async throws -> NativeRPCValue { try await services.dashboards.load(projectPath:projectPath) }
    public func dashboardSave(projectPath: String, layout: NativeRPCValue) async throws { try await services.dashboards.save(projectPath:projectPath,layout:layout) }
    public func dashboardClear(projectPath: String) async throws { try await services.dashboards.clear(projectPath:projectPath) }
    public func artifactsList(project: String, options: BackendArtifactScanOptions, context: NativeRPCContext) async throws -> NativeRPCValue { try await services.artifacts.list(project:project,options:options,context:context) }
    public func artifactHistory(project: String, relative: String, options: BackendArtifactScanOptions, context: NativeRPCContext) async throws -> NativeRPCValue { try await services.artifacts.history(project:project,relative:relative,options:options,context:context) }
}

/// Exact project tool metadata and source orchestration around the existing
/// project/files/git/dev/dashboard/artifacts owners. No second Store is created.
public enum BackendDeckToolsProjects {
    private typealias A = BackendDeckToolsArgs
    private static func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    public static func definitions(services: BackendDeckToolsProjectServices,
                                   runtime: any BackendDeckToolsFilesRuntime) throws -> [BackendDeckToolsDefinition] {
        try definitions(provider:BackendDeckToolsNativeProjectProvider(services),runtime:runtime)
    }
    public static func definitions(provider services: any BackendDeckToolsProjectProvider,
                                   runtime: any BackendDeckToolsFilesRuntime) throws -> [BackendDeckToolsDefinition] {
        try BackendDeckToolsCatalogue.entries().filter { $0.module == "project-tools" }.map { entry in
            BackendDeckToolsDefinition(spec: entry.spec, title: entry.title, index: entry.index) { caller, args in
                await BackendDeckToolsSupport.reply {
                    let (value, summary) = try await call(entry.spec.id, args: args, caller: caller, services: services, runtime: runtime)
                    try await runtime.completed(caller, tool: entry.spec.id, summary: summary)
                    return .value(value)
                }
            }
        }
    }
    public static func area(services: BackendDeckToolsProjectServices,
                            runtime: any BackendDeckToolsFilesRuntime) throws -> BackendDeckCoreToolArea {
        try BackendDeckToolsSupport.area(id: "projects", definitions: definitions(services: services, runtime: runtime))
    }
    public static func folder(_ raw: String) throws -> String {
        guard raw.hasPrefix("/") else { throw A.bad("path must be an absolute folder, like /Users/you/Projects/app") }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }
    public static func refuseStorage(_ path: String, root: String) throws {
        if path == root || path.hasPrefix(root + "/") || path.hasPrefix(root + "\\") {
            throw NativeRPCError(code: "not-permitted", message: "\(path) is inside this app’s own storage and cannot be opened as a project.")
        }
    }
    private static func action(_ args: NativeRPCValue, choices: [String]) throws -> String {
        let value = try A.str(args, "action")
        guard choices.contains(value) else {
            throw A.bad("action must be " + choices.dropLast().map { "\"\($0)\"" }.joined(separator: ", ") + " or \"" + choices.last! + "\"")
        }
        return value
    }
    private static func browse(provider: any BackendDeckToolsProjectProvider, path: String, showHidden: Bool, context: NativeRPCContext) async throws -> NativeRPCValue {
        let listing = try await provider.listFolder(path:path,context:context)
        let opened = Set(await provider.listProjects().compactMap { $0["path"].string })
        let folders = (listing["entries"].elements ?? []).filter { $0["kind"].string == "dir" && $0["blocked"].bool != true && (showHidden || !($0["name"].string ?? "").hasPrefix(".")) }
        var rows: [NativeRPCValue] = []
        for entry in folders.prefix(300) {
            try Task.checkCancellation()
            let name = entry["name"].string ?? "", full = URL(fileURLWithPath:path).appendingPathComponent(name).path
            let repo = (try? await provider.isFolder(URL(fileURLWithPath:full).appendingPathComponent(".git").path,context:context)) ?? false
            rows.append(o([("name",.string(name)),("path",.string(full)),("open",.bool(opened.contains(full))),("repo",.bool(repo))]))
        }
        return o([("path",.string(path)),("home",.string(provider.home)),("folders",.array(rows)),("more",.bool(listing["truncated"].bool == true || folders.count > rows.count))])
    }
    private static func call(_ id: String, args: NativeRPCValue, caller: BackendMCPCallContext,
                             services s: any BackendDeckToolsProjectProvider, runtime: any BackendDeckToolsFilesRuntime) async throws -> (NativeRPCValue, NativeRPCValue) {
        let rpc = try await runtime.rpc(caller)
        var cwd = "", path = "", verb = ""
        let tier: BackendMCPTier
        switch id {
        case "projects.add":
            path = try folder(A.str(args, "path")); try refuseStorage(path, root: s.appDataRoot); tier = .alter
        case "projects.remove":
            path = try A.str(args, "path")
            guard await s.listProjects().contains(where: { $0["path"].string == path }) else { throw A.bad("\(path) is not an open project. projects.list shows the ones that are.") }
            _ = try await runtime.knownFolder(path, caller: caller); tier = .alter
        case "git.init": cwd = try await runtime.knownFolder(A.str(args, "cwd"), caller: caller); tier = .act
        case "dev.servers":
            verb = try action(args, choices: ["list", "start", "ports"])
            if verb == "start" { cwd = try await runtime.knownFolder(A.str(args, "cwd"), caller: caller) }
            tier = verb == "start" ? .act : .read
        case "dashboard.layout":
            verb = try action(args, choices: ["read", "save", "reset"]); cwd = try await runtime.knownFolder(A.str(args, "cwd"), caller: caller)
            if verb == "save" { _ = try A.record(args, "layout") }
            tier = verb == "read" ? .read : .alter
        case "artifacts.list": cwd = try await runtime.knownFolder(A.str(args, "cwd"), caller: caller); tier = .read
        default: tier = .read
        }
        let summaryText: String
        switch id {
        case "projects.browse": summaryText = "Look inside \(try A.optStr(args, "path") ?? "the home folder")"
        case "projects.add": summaryText = "Open \(try A.optStr(args, "path") ?? "?") as a project"
        case "projects.remove": summaryText = "Put away the project \(try A.optStr(args, "path") ?? "?")"
        case "git.init": summaryText = "Make \(try A.optStr(args, "cwd") ?? "?") a git repository"
        case "dev.servers": summaryText = verb == "start" ? "Start the dev server in \(try A.optStr(args, "cwd") ?? "?")" : verb == "ports" ? "List the ports something is listening on" : "List the dev servers"
        case "dashboard.layout": summaryText = verb == "save" ? "Save a new Overview arrangement for \(cwd)" : verb == "reset" ? "Put the Overview of \(cwd) back to the default" : "Read the Overview arrangement of \(cwd)"
        default: summaryText = try A.optStr(args, "path").map { "Read the history of \($0)" } ?? "List what agents made in \(try A.optStr(args, "cwd") ?? "?")"
        }
        guard caller.allowedTiers.contains(tier), !caller.cancellation.isCancelled else { throw NativeRPCError(code: "not-granted", message: "This caller is not permitted to use that tool.") }
        try await runtime.authorize(caller, tool: id, tier: tier, summary: summaryText, arguments: args)
        try Task.checkCancellation()
        switch id {
        case "projects.browse":
            path = try folder(A.optStr(args, "path") ?? s.home)
            guard (try? await s.isFolder(path, context: rpc)) == true else { throw A.bad("\(path) is not a folder on this machine") }
            let value = try await browse(provider:s,path:path,showHidden:A.optBool(args,"showHidden",false),context:rpc)
            return (value, o([("path", .string(path)), ("folders", .number(Double(value["folders"].elements?.count ?? 0)))]))
        case "projects.add":
            guard (try? await s.isFolder(path, context: rpc)) == true else { throw A.bad("\(path) is not a folder on this machine") }
            let result = try await s.add(path: path, context: rpc), shown = result["inWindow"].bool == true
            let value = result.setting("note", .string(shown ? "It is open, and the window’s sidebar shows it." : "It is saved as open. No window took it, so the sidebar shows it once a session starts there or the app next starts."))
            return (value, o([("path", .string(path)), ("already", result["already"]), ("inWindow", .bool(shown))]))
        case "projects.remove":
            let value = try await s.remove(path: path, context: rpc)
            return (value, o([("path", .string(path)), ("stillRunning", .number(Double(value["stillRunning"].elements?.count ?? 0)))]))
        case "git.init":
            let before = try await s.gitStatus(cwd: cwd, context: rpc)
            let after = before["repo"].bool == true ? before : try await s.gitInitialize(cwd: cwd, context: rpc)
            let created = before["repo"].bool != true && after["repo"].bool == true
            return (o([("cwd", .string(cwd)), ("created", .bool(created)), ("status", after)]), o([("cwd", .string(cwd)), ("created", .bool(created))]))
        case "dev.servers":
            if let access = s.devAccess {
                if verb == "ports" { return (o([("ports", try await access.ports(force: A.optBool(args, "refresh", false), context: rpc))]), o([("action", .string(verb))])) }
                if verb == "start" {
                    let state = try await access.start(folder: cwd, context: rpc)
                    if state.isNullish { throw A.bad("\(cwd) is not an open project, so its dev server cannot be started") }
                    return (o([("server", state)]), o([("action", .string(verb)), ("cwd", .string(cwd))]))
                }
                let servers = try await access.list(context: rpc)
                return (o([("servers", .array(servers))]), o([("action", .string(verb)), ("count", .number(Double(servers.count)))]))
            }
            if verb == "ports" { return (o([("ports", .array(try await s.scanPorts(force: A.optBool(args, "refresh", false))))]), o([("action", .string(verb))])) }
            if verb == "start" {
                let state = try await s.devStart(folder: cwd, context: rpc)
                if state.isNullish { throw A.bad("\(cwd) is not an open project, so its dev server cannot be started") }
                return (o([("server", state)]), o([("action", .string(verb)), ("cwd", .string(cwd))]))
            }
            var servers: [NativeRPCValue] = []
            for project in await s.listProjects() {
                // TS project-tools.ts lists every project's server; a folder-limited caller
                // simply does not see the ones outside its grant (never a refusal of the list).
                if let folder = project["path"].string, (try? await runtime.knownFolder(folder, caller: caller)) != nil {
                    servers.append(try await s.devStatus(folder: folder, context: rpc))
                }
            }
            return (o([("servers", .array(servers))]), o([("action", .string(verb)), ("count", .number(Double(servers.count)))]))
        case "dashboard.layout":
            if verb == "read" {
                let layout = try await s.dashboardLoad(projectPath: cwd)
                return (o([("cwd", .string(cwd)), ("layout", layout)]), o([("action", .string(verb)), ("saved", .bool(layout != .null))]))
            }
            if verb == "reset" { try await s.dashboardClear(projectPath: cwd); return (o([("cwd", .string(cwd)), ("reset", .bool(true))]), o([("action", .string(verb))])) }
            try await s.dashboardSave(projectPath: cwd, layout: A.record(args, "layout"))
            return (o([("cwd", .string(cwd)), ("saved", .bool(true))]), o([("action", .string(verb))]))
        case "artifacts.list":
            var options = BackendArtifactScanOptions(); options.scope = try A.optStr(args, "scope") == "all" ? .all : .project
            let cap = try A.optInt(args, "limit", 50, 1, 300); options.maxArtifacts = cap; options.maxChanges = cap
            if let relative = try A.optStr(args, "path") {
                if relative.hasPrefix("/") || relative.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").contains("..") { throw A.bad("path must be relative to the project, with no \"..\"") }
                return (try await s.artifactHistory(project: cwd, relative: relative, options: options, context: rpc), o([("cwd", .string(cwd)), ("path", .string(relative))]))
            }
            return (try await s.artifactsList(project: cwd, options: options, context: rpc), o([("cwd", .string(cwd)), ("scope", .string(options.scope.rawValue))]))
        default: throw BackendDeckToolsSupport.unavailable(id)
        }
    }
}
