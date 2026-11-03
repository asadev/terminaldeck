import Foundation
import TerminalDeckNativeCore

/// Storefront projection over the real browser-tool and MCP catalogues. This
/// reads no preference store and cannot fabricate catalogue/install state.
public enum BackendRemotePanelStore {
    public struct Department: Sendable {
        public let read: @Sendable (String, NativeRPCContext) async throws -> NativeRPCValue
        public let install: (@Sendable (NativeRPCValue, NativeRPCContext) async throws -> NativeRPCValue)?
        public let remove: (@Sendable (NativeRPCValue, NativeRPCContext) async throws -> NativeRPCValue)?
        public init(read: @escaping @Sendable (String, NativeRPCContext) async throws -> NativeRPCValue,
                    install: (@Sendable (NativeRPCValue, NativeRPCContext) async throws -> NativeRPCValue)? = nil,
                    remove: (@Sendable (NativeRPCValue, NativeRPCContext) async throws -> NativeRPCValue)? = nil) { self.read = read; self.install = install; self.remove = remove }
    }
    private struct Entry: Sendable { let row: NativeRPCValue; let haystack: String; let installed: Bool; let addable: Bool; let free: Bool }
    private static let prices = ["free":"Free", "account":"Free, needs an account", "metered":"Free to a limit, then paid", "paid":"Paid", "unknown":"Not known"]
    private static let chips = [("all", "Everything"), ("installed", "Installed"), ("addable", "Can be added"), ("free", "Free")]
    public static func provider(tools: Department? = nil, servers: Department? = nil, categoryNames: [String: String]) throws -> BackendRemotePanelProvider {
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> NativeRPCValue = { request, context in
            var entries: [Entry] = [], problems: [String] = []
            if let tools {
                do {
                    let view = try await tools.read(request.path, context)
                    guard let rows = view["tools"].elements else { throw NativeRPCError.malformed("The native browser-tool catalogue omitted its tools") }
                    entries += rows.map { toolEntry($0, tools: tools) }
                    if tools.install == nil { problems.append("Browser tools can be browsed from here and not installed from here.") }
                } catch { problems.append("The browser tools could not be read — \(error.localizedDescription).") }
            } else { problems.append("The tools this app installs into its own browser cannot be read from here.") }
            if let servers {
                do {
                    let view = try await servers.read(request.path, context)
                    guard let rows = view["rows"].elements else { throw NativeRPCError.malformed("The native MCP catalogue omitted its rows") }
                    let writer = view["writer"]["found"].bool == true
                    entries += rows.map { serverEntry($0, folder: request.path, canInstall: servers.install != nil && writer, canRemove: servers.remove != nil && writer, categoryNames: categoryNames) }
                    if !writer { problems.append("Claude Code’s command line tool writes this configuration and was not found on this machine. The catalogue is listed; nothing can be installed or removed until it is there.") }
                    else if servers.install == nil { problems.append("MCP servers can be browsed from here and not installed from here.") }
                } catch { problems.append("The MCP server catalogue could not be read — \(error.localizedDescription).") }
            } else { problems.append("The MCP server catalogue cannot be read from here.") }
            let query = request.query ?? "", chosen = chips.contains(where: { $0.0 == request.scope }) ? request.scope! : "all"
            let found = entries.filter { matches($0.haystack, query: query) }, shown = found.filter { keep($0, chip: chosen) }
            if shown.isEmpty && !entries.isEmpty {
                problems.insert(!query.isEmpty ? "Nothing in the store matches “\(query)”." : ["all":"This store is empty.", "installed":"Nothing from this store is installed on this machine.", "addable":"Nothing in the store can be installed from here.", "free":"Nothing in the store is free of both a bill and a sign-up."][chosen]!, at: 0)
            }
            var payload = NativeRPCValue.object([.init("path", .string(request.path)), .init("rows", .array(Array(shown.prefix(200)).map(\.row)))])
            // Nested shorthand arguments would conflate chip and entry; the
            // explicit loop also retains source order across filtered options.
            var scopes: [NativeRPCValue] = []
            for (id, label) in chips where id == "all" || id == chosen || found.contains(where: { keep($0, chip: id) }) { scopes.append(.object([.init("id", .string(id)), .init("label", .string(label)), .init("on", .bool(id == chosen))])) }
            if scopes.count > 1 { payload = payload.setting("scopes", .array(scopes)) }
            if !problems.isEmpty { payload = payload.setting("note", .string(problems.joined(separator: " "))) }
            return payload
        }
        // panels/store.ts:620-715: every refusal below is that file's own sentence.
        @Sendable func because(_ error: Error) -> String { let said = error.localizedDescription; return said.isEmpty ? "" : " — \(said)" }
        @Sendable func performTool(_ id: String, _ request: BackendRemotePanelActionRequest, _ context: NativeRPCContext) async -> String {
            guard let tools else { return "This host has no browser tool store." }
            do {
                if request.action == "install" {
                    guard let install = tools.install else { return "Nothing can be installed from here." }
                    let done = try await install(.string(id), context), said = done["message"].string ?? ""
                    return !said.isEmpty ? said : done["ok"].bool == true ? "Installed." : "That did not work."
                }
                if request.action == "remove" {
                    guard let remove = tools.remove else { return "Nothing can be removed from here." }
                    let done = try await remove(.string(id), context), said = done["message"].string ?? ""
                    return !said.isEmpty ? said : done["ok"].bool == true ? "Removed." : "That did not work."
                }
            } catch { return "That could not be done\(because(error))." }
            return "This store has no “\(request.action)”."
        }
        @Sendable func performServer(_ id: String, _ request: BackendRemotePanelActionRequest, _ context: NativeRPCContext) async -> String {
            guard let servers else { return "This host has no MCP server catalogue." }
            let folder = request.panel.path
            let view: NativeRPCValue
            do { view = try await servers.read(folder, context) } catch { return "That could not be done\(because(error))." }
            guard let row = view["rows"].elements?.first(where: { $0["id"].string == id }) else { return "That row is not in this store." }
            guard view["writer"]["found"].bool == true else { return "Claude Code’s command line tool writes this configuration, and it is not on this machine." }
            let name = row["name"].string ?? "Server"
            do {
                if request.action == "install" || request.action == "install.here" {
                    guard let install = servers.install else { return "Nothing can be installed from here." }
                    if let blocked = row["blocked"].string, !blocked.isEmpty { return blocked }
                    if row["state"].string != "available" { return "\(name) is already in your configuration." }
                    let scope = request.action == "install.here" ? "project" : "user"
                    if scope == "project" && folder.isEmpty { return "There is no folder in view to install into." }
                    let done = try await install(.object([.init("id", row["id"]), .init("scope", .string(scope)), .init("projectPath", .string(folder)),
                        .init("values", .object(request.fields.keys.sorted().map { .init($0, .string(request.fields[$0]!)) }))]), context)
                    let said = done["message"].string ?? ""
                    return !said.isEmpty ? said : done["ok"].bool == true ? "\(name) is installed." : "That did not work."
                }
                if request.action == "remove" {
                    guard let remove = servers.remove else { return "Nothing can be removed from here." }
                    guard let scope = row["scope"].string, !scope.isEmpty else { return "\(name) is not in your configuration." }
                    let done = try await remove(.object([.init("name", row["name"]), .init("scope", .string(scope)), .init("projectPath", .string(folder))]), context)
                    let said = done["message"].string ?? ""
                    return !said.isEmpty ? said : done["ok"].bool == true ? "\(name) is removed." : "That did not work."
                }
            } catch { return "That could not be done\(because(error))." }
            return "This store has no “\(request.action)”."
        }
        return .init(read: read, act: { request, context in
            let id = request.id ?? ""
            let notice = id.hasPrefix("tool:") ? await performTool(String(id.dropFirst(5)), request, context)
                : id.hasPrefix("server:") ? await performServer(String(id.dropFirst(7)), request, context) : "That row is not in this store."
            let redraw = try await read(request.panel, context)
            return notice.isEmpty ? redraw : redraw.setting("notice", .string(notice))
        })
    }
    private static func toolEntry(_ tool: NativeRPCValue, tools: Department) -> Entry {
        let state = tool["state"].string ?? "available", name = tool["name"].string ?? "Tool", installed = state != "available"
        var row = NativeRPCValue.object([.init("id", .string("tool:" + (tool["id"].string ?? ""))), .init("title", .string(name)), .init("detail", .string(tool["message"].string.flatMap { $0.isEmpty ? nil : $0 } ?? tool["summary"].string ?? "")), .init("value", .string(["available":"Free", "installed":"Installed", "outdated":"Update available", "damaged":"Damaged"][state] ?? state))])
        if state == "damaged" { row = row.setting("status", .string("warn")) } else if installed { row = row.setting("status", .string("ok")) }
        var actions: [NativeRPCValue] = []
        if tools.install != nil && state != "installed" { actions.append(action("install", state == "outdated" ? "Update" : state == "damaged" ? "Repair" : "Install")) }
        if tools.remove != nil && installed { actions.append(action("remove", "Remove").setting("kind", .string("destructive")).setting("confirm", .string("The file \(name) installed is deleted from this machine. Installing it again fetches it and checks it against the same fingerprint, so nothing is lost that cannot be got back."))) }
        if !actions.isEmpty { row = row.setting("actions", .array(actions)) }
        let search = [name, tool["summary"].string ?? "", "Built into this app"].joined(separator: " ")
        return Entry(row: row, haystack: search, installed: installed, addable: tools.install != nil && state == "available", free: true)
    }
    private static func serverEntry(_ server: NativeRPCValue, folder: String, canInstall: Bool, canRemove: Bool, categoryNames: [String: String]) -> Entry {
        let installed = server["state"].string == "installed", blocked = server["blocked"].string ?? "", runtimeMissing = server["runtimeMissing"].bool == true
        let addable = server["state"].string == "available" && blocked.isEmpty && canInstall, name = server["name"].string ?? "Server", category = server["category"].string ?? ""
        let detail = !blocked.isEmpty ? blocked : runtimeMissing && !(server["caveat"].string ?? "").isEmpty ? server["caveat"].string! : server["summary"].string ?? ""
        var row = NativeRPCValue.object([.init("title", .string(name)), .init("id", .string("server:" + (server["id"].string ?? ""))), .init("detail", .string(detail)), .init("value", .string(installed ? "Installed" : prices[server["cost"].string ?? "unknown"] ?? "Not known"))])
        if !blocked.isEmpty || runtimeMissing { row = row.setting("status", .string("warn")) } else if installed { row = row.setting("status", .string("ok")) }
        var actions: [NativeRPCValue] = []
        if addable {
            let fields = (server["inputs"].elements ?? []).map { field -> NativeRPCValue in
                .object([.init("id", field["key"]), .init("label", field["label"]), .init("placeholder", .string(field["inEnvironment"].bool == true ? "Leave blank to use the \(field["key"].string ?? "key") this machine exports" : field["hint"].string ?? "")), .init("required", .bool(field["required"].bool == true && field["inEnvironment"].bool != true))])
            }
            var install = action("install", "Install"); if !fields.isEmpty { install = install.setting("fields", .array(fields)) }; actions.append(install)
            if !folder.isEmpty { actions.append(install.setting("id", .string("install.here")).setting("label", .string("Install for this folder"))) }
        }
        if installed && !(server["scope"].string ?? "").isEmpty && canRemove { actions.append(action("remove", "Remove").setting("kind", .string("destructive")).setting("confirm", .string("\(name) is unwritten from Claude Code’s configuration, and any key you typed into it goes with it — this app never kept a copy to put back."))) }
        if !actions.isEmpty { row = row.setting("actions", .array(actions)) }
        let parts = [name, server["summary"].string ?? "", categoryNames[category] ?? (category == "your-own" ? "Added by you" : "")] + (server["tags"].elements?.compactMap(\.string) ?? [])
        return Entry(row: row, haystack: parts.joined(separator: " "), installed: installed, addable: addable, free: server["cost"].string == "free")
    }
    private static func action(_ id: String, _ label: String) -> NativeRPCValue { .object([.init("id", .string(id)), .init("label", .string(label))]) }
    private static func keep(_ entry: Entry, chip: String) -> Bool { switch chip { case "installed": return entry.installed; case "addable": return entry.addable; case "free": return entry.free; default: return true } }
    private static func matches(_ haystack: String, query: String) -> Bool {
        let plain = haystack.lowercased()
        func squash(_ text: String) -> String { text.replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression) }
        let tight = squash(plain)
        return query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { word in let value = String(word), squashed = squash(value); return plain.contains(value) || !squashed.isEmpty && tight.contains(squashed) }
    }
}
