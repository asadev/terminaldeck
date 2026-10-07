import Foundation
import TerminalDeckNativeCore

/// Existing installer StoreView/StoreRow shapes enter as NativeRPCValue so a
/// second ledger or catalogue model is not invented in this projection.
public protocol BackendCommunityStoreProviding: Sendable {
    func view() async throws -> NativeRPCValue
    func install(id: String, choice: NativeRPCValue) async throws -> NativeRPCValue
    func remove(id: String) async throws -> NativeRPCValue
}
public protocol BackendCommunityMachineProbing: Sendable {
    func onPath(_ binary: String) async throws -> Bool
    func agents() async throws -> [String: BackendNativeProviders.Binary]
}
public actor BackendCommunityNativeProbe: BackendCommunityMachineProbing {
    public typealias LoginPath = @Sendable () async throws -> String
    public typealias ResolveBinary = @Sendable (String, String) async -> BackendNativeProviders.Binary
    private let loginPath: LoginPath
    private let resolveBinary: ResolveBinary
    private var runtimes: Set<String>?
    private var measuring: Task<Set<String>, Error>?
    public init(providers: BackendNativeProviders) {
        loginPath = { try await providers.loginPath() }
        resolveBinary = { await providers.resolveBinary($0, path: $1) }
    }
    /// Deterministic dependency seam for the same native probing logic. The
    /// real app retains its provider-based constructor above.
    public init(loginPath: @escaping LoginPath, resolveBinary: @escaping ResolveBinary) {
        self.loginPath = loginPath; self.resolveBinary = resolveBinary
    }
    public func onPath(_ binary: String) async throws -> Bool {
        if let runtimes { return runtimes.contains(binary) }
        if let measuring { let found = try await measuring.value; return found.contains(binary) }
        let readPath = loginPath
        let task = Task { let path = try await readPath(); return Set(["node", "python3"].filter { BackendNativeProviders.lookup($0, path: path) != nil }) }
        measuring = task
        do { let found = try await task.value; runtimes = found; measuring = nil; return found.contains(binary) }
        catch { measuring = nil; throw error }
    }
    public func agents() async throws -> [String: BackendNativeProviders.Binary] {
        let path = try await loginPath()
        async let claude = resolveBinary("claude", path)
        async let codex = resolveBinary("codex", path)
        async let gemini = resolveBinary("gemini", path)
        let (c, o, g) = await (claude, codex, gemini)
        return ["claude": c, "codex": o, "gemini": g]
    }
}

public enum BackendCommunityProjection {
    public static let agentIDs = ["claude", "codex", "gemini"]
    public static func agentLine(_ binary: BackendNativeProviders.Binary?) -> String {
        guard let binary else { return "" }
        let entry = CodingAICatalog.agent(binary.id), label = entry?.label ?? binary.id
        if binary.runnable == nil {
            if !binary.broken { return entry?.install.map { "\(label) is not installed. Install it with `\($0)`, then check again." } ?? "\(label) is not installed on this machine." }
            let whereFound = binary.onPath.map { " at \($0)" } ?? ""
            return entry?.install.map { "\(label) is installed\(whereFound) but will not start. Reinstalling usually fixes it: `\($0)`." } ?? "\(label) is installed\(whereFound) but will not start."
        }
        if binary.usedAlternate, let runnable = binary.runnable {
            let fix = entry?.install.map { " Reinstalling with `\($0)` would fix the one on your PATH." } ?? ""
            return "The `\(entry?.bin ?? binary.id)` on your PATH will not start, so \(label) runs from \(runnable) instead.\(fix)"
        }
        return ""
    }
    public static func missingNeeds(_ needs: [String], probe: any BackendCommunityMachineProbing) async throws -> [String] {
        var result: [String] = []
        for need in needs {
            if let bin = ["node": "node", "python": "python3"][need] { let found = try await probe.onPath(bin); if !found { result.append(need) } }
        }
        return result
    }
    public static func profileURL(_ row: NativeRPCValue) -> String {
        let publisher = row["publisher"].string ?? "", host = row["source"]["host"].string ?? ""
        return publisher.isEmpty || host.isEmpty ? "" : "https://\(host)/\(publisher)"
    }
    public static func mcpCommand(_ install: NativeRPCValue) -> String {
        guard install["kind"].string == "mcp" else { return "" }
        let head = install["runtime"].string == "node" ? "npx -y" : "uvx"
        let args = (install["args"].elements ?? []).compactMap(\.string).map { argument in
            if let captures = BackendGitHubRules.captures(argument, #"^\$\{input:([A-Z][A-Z0-9_]{0,63})\}$"#), let key = captures[0] { return "${\(key)}" }
            return argument
        }
        return ([head, install["package"].string ?? ""] + args).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Source installer table. Integration must use this same table from its
    /// install adapter; copying it into the screen would let paths drift.
    public static func plannedTargets(row: NativeRPCValue, agents: [String], homes: NativeRPCValue, userData: String) -> [String] {
        let id = row["id"].string ?? "", publisher = row["publisher"].string ?? ""
        let parts = id.components(separatedBy: "/"), item = parts.count > 1 ? parts[1] : id, folder = publisher + "." + item
        func join(_ root: String, _ path: String) -> String { (root as NSString).appendingPathComponent(path) }
        var result = [join(userData, "community/items/" + folder)]
        if row["kind"].string == "routine" { result.append(join(userData, "routines/" + publisher + "-" + item + ".md")); return result }
        if row["kind"].string == "mcp" { result += agents.map { "\(CodingAICatalog.label($0)): an MCP server called \(publisher)-\(item)" }; return result }
        for agent in agents {
            let home = homes[agent].string ?? "", memory = ["claude": "CLAUDE.md", "codex": "AGENTS.md", "gemini": "GEMINI.md"][agent] ?? ""
            if row["kind"].string == "skill" { result.append(join(home, "skills/" + folder)); if agent == "codex" { result.append(join(home, memory)) } }
            if row["kind"].string == "instructions" { result.append(join(home, "instructions/" + folder + ".md")); result.append(join(home, memory)) }
        }
        return result
    }
    public static func projectItem(_ item: NativeRPCValue, agents: [NativeRPCValue], homes: NativeRPCValue = .object([]), userData: String, probe: any BackendCommunityMachineProbing) async throws -> NativeRPCValue {
        let row = item["row"], install = row["install"], declared = (row["agents"].elements ?? []).compactMap(\.string)
        let selected = agents.filter { $0["found"].bool == true && declared.contains($0["id"].string ?? "") }.compactMap { $0["id"].string }
        var fields: [(String, NativeRPCValue)] = []
        for key in ["id", "publisher", "kind", "name", "summary", "version", "licence", "cost", "delivery"] { fields.append((key, .string(row[key].string ?? ""))) }
        for key in ["tags", "agents", "needs", "network"] { fields.append((key, row[key].elements.map(NativeRPCValue.array) ?? .array([]))) }
        let needs = (row["needs"].elements ?? []).compactMap(\.string), note = item["note"].string ?? "", state = item["state"].string ?? ""
        let missing = try await missingNeeds(needs, probe: probe)
        fields += [("handle", .string(row["publisher"].string ?? "")), ("profileUrl", .string(profileURL(row))), ("tier", .number(row["tier"].number ?? 0)), ("missing", .array(missing.map(NativeRPCValue.string))), ("costNote", .string(row["costNote"].string ?? "")), ("offsiteUrl", .string("")), ("repo", .string(row["source"]["repo"].string ?? "")), ("commit", .string(row["source"]["commit"].string ?? "")), ("artifactUrl", .string(row["artifact"]["url"].string ?? "")), ("sha256", .string(row["artifact"]["sha256"].string ?? "")), ("bytes", .number(row["artifact"]["bytes"].number ?? 0)), ("updatedAt", .string(row["repoStats"]["pushedAt"].string ?? "")), ("stars", .number(row["repoStats"]["stars"].number ?? -1)), ("openIssues", .number(row["repoStats"]["openIssues"].number ?? -1)), ("ratingScore", .number(0)), ("ratingCount", .number(0)), ("state", .string(state)), ("installedVersion", .string(item["installed"]["version"].string ?? "")), ("message", .string(note)), ("reason", .string(state == "withdrawn" ? note : "")), ("lands", .array(plannedTargets(row: row, agents: selected, homes: homes, userData: userData).map(NativeRPCValue.string))), ("command", .string(mcpCommand(install))), ("variables", .array(install["kind"].string == "mcp" ? (install["inputs"].elements ?? []).map { $0["key"] } : [])), ("trigger", .string("")), ("reach", install["kind"].string == "extension" ? (install["reach"].elements.map(NativeRPCValue.array) ?? .array([])) : .array([])), ("logo", .string(row["icon"].string ?? ""))]
        return BackendGitHubRules.object(fields)
    }
    public static func projectView(_ view: NativeRPCValue, userData: String, probe: any BackendCommunityMachineProbing) async throws -> NativeRPCValue {
        let binaries = try await probe.agents()
        let agents = agentIDs.map { id in BackendGitHubRules.object([("id", .string(id)), ("name", .string(CodingAICatalog.label(id))), ("found", .bool(binaries[id]?.runnable != nil)), ("note", .string(agentLine(binaries[id])))]) }
        let items = try await withThrowingTaskGroup(of: (Int, NativeRPCValue).self) { group in
            for (index, item) in (view["items"].elements ?? []).enumerated() { group.addTask { (index, try await projectItem(item, agents: agents, homes: view["homes"], userData: userData, probe: probe)) } }
            var result: [(Int, NativeRPCValue)] = []
            for try await item in group { result.append(item) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let problem = view["ok"].bool == true ? "" : view["why"].string ?? "The community store could not be read."
        return BackendGitHubRules.object([("from", .string(view["from"].string == "kept" ? "kept" : "store")), ("at", .string(view["at"].string ?? "")), ("stale", .string(view["stale"].string ?? "")), ("because", .string(view["because"].string ?? "")), ("problem", .string(problem)), ("items", .array(items)), ("folder", .string(view["folder"].string ?? "")), ("agents", .array(agents))])
    }
}

public enum BackendCommunityChannels {
    public static let unavailable = "The community store is not available in this build."
    public static func readChoice(_ raw: NativeRPCValue) -> NativeRPCValue {
        guard raw.fields != nil else { return .object([]) }
        var result = NativeRPCValue.object([])
        if let agents = raw["agents"].elements { result = result.setting("agents", .array(agents.filter { $0.string != nil })) }
        if let folder = raw["folder"].string { result = result.setting("folder", .string(folder)) }
        if let values = raw["values"].fields { result = result.setting("values", .object(values.filter { $0.value.string != nil })) }
        return result
    }
    public static func register(registry: NativeChannelRegistry, ownerID: String, store: (any BackendCommunityStoreProviding)?, userData: String, probe: any BackendCommunityMachineProbing, emptyHomes: NativeRPCValue = .object([])) async throws -> [String] {
        let channels = ["community:list", "community:install", "community:remove"]
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Only the app's own window may use the community store channels") }
                let failure = BackendGitHubRules.object([("ok", .bool(false)), ("message", .string(unavailable))])
                if channel == "community:list" {
                    let view: NativeRPCValue
                    if let store { view = try await store.view() }
                    else { view = BackendGitHubRules.object([("ok", .bool(false)), ("why", .string(unavailable)), ("items", .array([])), ("homes", emptyHomes), ("folder", .string(""))]) }
                    return try await BackendCommunityProjection.projectView(view, userData: userData, probe: probe)
                }
                guard let id = context.argument(0, in: args).string, let store else { return failure }
                if channel == "community:install" { return try await store.install(id: id, choice: readChoice(context.argument(1, in: args))) }
                return try await store.remove(id: id)
            }
        }
        return channels
    }
}
