import Foundation
import TerminalDeckNativeCore

public protocol BackendDeckToolsMachinesServerShells: Sendable {
    func openShells() async throws -> [NativeRPCValue]
    func shellScreen(_ shellID: String) async throws -> String?
}
/// Four tools beside servers.look/logs/control. No server grant lowers the shell tier.
public actor BackendDeckToolsMachinesServers {
    public typealias V = NativeRPCValue
    typealias S = BackendDeckToolsMachinesShared
    typealias A = BackendDeckToolsArgs
    public static let ids = ["servers.details", "servers.ports", "servers.manage", "servers.shell"]
    public static let about = ["setup", "host", "ports", "folder", "start-in", "grant", "keys", "preview", "shells", "shell"]
    public static let portVerbs = ["open-here", "close-here", "disconnect", "cancel-setup", "cancel-host"]
    public static let shellVerbs = ["open", "type", "keys", "set", "close"]
    public static let manageVerbs = ["add", "rename", "forget", "revoke", "set-start-in", "allow-windows", "upload", "install-agent", "sign-in-agent", "sign-out-agent", "remove-agent", "install-host", "pair-host", "link-host", "remove-host"]
    private static let agentVerbs = ["install-agent", "sign-in-agent", "sign-out-agent", "remove-agent"]
    private static let needsShell = ["install-agent", "sign-in-agent", "sign-out-agent", "install-host", "pair-host", "link-host"]
    private let channels: any BackendDeckToolsMachinesChannels
    private let shells: any BackendDeckToolsMachinesServerShells
    private let dataRoot: URL
    private let home: URL
    private let sleep: @Sendable (Int) async throws -> Void
    private var lastServers: [V]?
    public init(channels: any BackendDeckToolsMachinesChannels, shells: any BackendDeckToolsMachinesServerShells, dataRoot: URL, home: URL,
                sleep: @escaping @Sendable (Int) async throws -> Void = BackendDeckToolsSessionsTyping.realSleep) {
        self.channels = channels; self.shells = shells; self.dataRoot = dataRoot; self.home = home; self.sleep = sleep
    }
    private func call(_ channel: String, _ args: [V], _ context: BackendDeckToolsMachinesContext) async throws -> V { try await channels.call(channel, args, context: context) }
    private func servers(_ context: BackendDeckToolsMachinesContext) async throws -> [V] { let rows = try await call("servers:list", [], context).elements ?? []; lastServers = rows; return rows }
    private func name(_ id: String) -> String { lastServers?.first { $0["id"].string == id }?["name"].string ?? id }
    private func known(_ id: String) throws { if let lastServers, !lastServers.contains(where: { $0["id"].string == id }) { throw S.refused("There is no server with the id \(id) in this app. servers.look lists them.") } }
    private func requireServer(_ id: String, _ context: BackendDeckToolsMachinesContext) async throws { _ = try await servers(context); try known(id) }
    private func shell(_ id: String) async throws -> V {
        guard let row = try await shells.openShells().first(where: { $0["shellId"].string == id }) else { throw S.refused("No terminal \(id) is open. servers.details with about \"shells\" lists the open ones; servers.shell with do \"open\" opens one.") }; return row
    }
    public func definitions(environment: any BackendDeckToolsMachinesEnvironment) throws -> [BackendDeckToolsDefinition] {
        try BackendDeckToolsMachinesFactory.definitions(ids: Self.ids, environment: environment, prepare: { [self] spec, args, context in try await self.policy(spec, args, context) }, run: { [self] id, args, context in try await self.run(id, args, context) })
    }
    public func policy(_ spec: BackendMCPTool, _ args: V, _ context: BackendDeckToolsMachinesContext) async throws -> BackendDeckToolsMachinesPolicy {
        let id = spec.id, verb = args["do"].string ?? ""
        try S.hereOnly(context, ["servers.details": "Reading a server’s page", "servers.ports": "Connecting to a server", "servers.shell": "A terminal on a server", "servers.manage": "Changing a server"][id] ?? "Using a server")
        if id == "servers.details" {
            let about = try A.oneOf(args, "about", Self.about)
            if !["keys", "shells", "shell"].contains(about) { try known(A.str(args, "serverId")) }; if about == "preview" { _ = try A.str(args, "cardId"); _ = try A.str(args, "action") }; if about == "shell" { _ = try await shell(A.str(args, "shellId")) }
        } else if id == "servers.ports" {
            try known(A.str(args, "serverId")); _ = try A.oneOf(args, "do", Self.portVerbs)
            if ["open-here", "close-here"].contains(verb) { _ = try A.int(args, "port", 1, 65_535) }
        } else if id == "servers.shell" {
            _ = try A.oneOf(args, "do", Self.shellVerbs)
            if verb == "open" { try known(A.str(args, "serverId")) }
            else {
                _ = try await shell(A.str(args, "shellId"))
                if verb == "type" { let text = try BackendDeckToolsSessionsTyping.sanitizeSendText(A.str(args, "text")); if text.utf16.count > 1_000 { throw A.bad("text must be 1000 characters or fewer, so the person can read all of it before it runs; got \(text.utf16.count)") } }
                if verb == "keys" { _ = try BackendDeckToolsSessionsTyping.resolveKeys(.array(A.strList(args, "keys").map(V.string))) }
                if verb == "set" { _ = try A.oneOf(args, "control", ["model", "effort", "fast", "permission"]); _ = try A.str(args, "value") }
            }
        } else {
            _ = try A.oneOf(args, "do", Self.manageVerbs)
            if verb == "add" {
                _ = try A.str(args, "address"); _ = try A.str(args, "username"); if args["port"] != .missing { _ = try A.int(args, "port", 1, 65_535) }
                let key = try A.optStr(args, "keyPath"), password = try A.optStr(args, "password"); if (key == nil) == (password == nil) { throw A.bad("add needs exactly one of keyPath or password") }
            } else {
                try known(A.str(args, "serverId")); if verb == "rename" { _ = try A.str(args, "name") }; if verb == "allow-windows" { _ = try A.bool(args, "allowed") }; if verb == "upload" { _ = try S.sendable(A.str(args, "path"), dataRoot: dataRoot, home: home) }
                if Self.agentVerbs.contains(verb) { _ = try A.oneOf(args, "agent", ["claude", "codex", "gemini"]) }
                if let shellID = try A.optStr(args, "shellId") { if !Self.needsShell.contains(verb) { throw A.bad("\(verb) does not use a terminal; leave shellId out") }; if try await shell(shellID)["serverId"] != args["serverId"] { throw A.bad("that terminal is on a different server") } }
            }
        }
        var logged = args
        if id == "servers.manage" { for key in ["password", "passphrase"] where args[key] != .missing { logged = logged.setting(key, .string("[redacted]")) } }
        return .init(tool: spec, arguments: args, loggedArguments: logged, tier: spec.tier, sentence: try await sentence(id, args))
    }
    public func sentence(_ id: String, _ args: V) async throws -> String {
        let verb = args["do"].string ?? "", server = name(args["serverId"].string ?? "?"), about = args["about"].string ?? "?"
        func text(_ key: String) -> String { args[key].string ?? "undefined" }
        if id == "servers.details" { if about == "keys" { return "List the SSH key files on this computer" }; if about == "shells" { return "List the terminals open on servers" }; if about == "shell" { return "Read the terminal \(text("shellId"))" }; return "Read the \(about) of \(server)" }
        if id == "servers.ports" { switch verb { case "open-here": return "Give port \(args["port"].compact) on \(server) an address on this computer"; case "close-here": return "Stop serving port \(args["port"].compact) of \(server) here"; case "disconnect": return "Close this app’s connection to \(server)"; case "cancel-setup": return "Cancel the agent install in progress on \(server)"; default: return "Cancel the host install in progress on \(server)" } }
        if id == "servers.shell" {
            if verb == "open" { return "Open a terminal on \(server)\((args["folder"].string ?? "").isEmpty ? "" : " in " + text("folder")). Anything typed into it runs as that server’s account." }
            let shellID = args["shellId"].string ?? "", found = try await shells.openShells().first { $0["shellId"].string == shellID }, where_ = found.map { "the terminal on " + name($0["serverId"].string ?? "") } ?? "the terminal \(shellID)"
            switch verb { case "type": return "Type into \(where_): \(text("text"))\(args["submit"].bool == false ? "" : " — and press return, which runs it")"; case "keys": return "Press \((args["keys"].elements ?? []).compactMap(\.string).joined(separator: ", ")) in \(where_)"; case "set": return "Set \(text("control")) to \(text("value")) for the agent in \(where_)"; default: return "Close \(where_)" }
        }
        let agent = args["agent"].string ?? "?"
        switch verb {
        case "add": let way = args["keyPath"].string == "choose" ? "a key file you choose in the window that opens" : args["keyPath"].string.map { "the key " + $0 } ?? "a password"; return "Add the server \(text("username"))@\(text("address"))\(args["port"].number.map { ":\(Int($0))" } ?? ""), signing in with \(way)"
        case "rename": return "Rename \(server) to “\(text("name"))”"
        case "forget": return "Forget \(server): its sign-in is deleted from this computer and its terminals close"
        case "revoke": return "Take back any control you were given over \(server)"
        case "set-start-in": return (args["folder"].string ?? "").isEmpty ? "Open \(server)’s terminals in its home folder" : "Open \(server)’s terminals in \(text("folder"))"
        case "allow-windows": return args["allowed"].bool == true ? "Let sessions on \(server) drive browser windows in this app" : "Stop sessions on \(server) driving browser windows in this app"
        case "upload": return "Copy \(text("path")) from this computer onto \(server)"
        case "install-agent": return "Install \(agent) on \(server), in its account’s own home folder"
        case "sign-in-agent": return "Sign \(agent) in on \(server)"
        case "sign-out-agent": return "Sign \(agent) out on \(server)"
        case "remove-agent": return "Remove \(agent) from \(server)"
        case "install-host": return "Install this app’s host program on \(server), so its sessions can be reached from here and from paired devices"
        case "pair-host": return "Show a code on \(server)’s host for a phone or another computer to pair with it"
        case "link-host": return "Link this computer to the host on \(server), so it appears in this app’s machines"
        case "remove-host": return args["alsoData"].bool == true ? "Remove the host program from \(server), and delete its data" : "Remove the host program from \(server), keeping its data"
        default: return "Change \(server)"
        }
    }
    public func run(_ id: String, _ args: V, _ context: BackendDeckToolsMachinesContext) async throws -> BackendDeckToolsMachinesOutput {
        let verb = args["do"].string ?? ""
        if id == "servers.details" {
            let about = try A.oneOf(args, "about", Self.about)
            if about == "keys" { let keys = try await call("servers:keys", [], context).elements ?? []; return .init(S.object(["keys": .array(keys.map { S.object(["path": $0["path"], "name": $0["name"], "what": $0["what"], "needsPassphrase": $0["locked"]]) }), "note": .string("servers.manage with do \"add\" and keyPath set to one of these signs in with it. Only files listed here can be used.")]), S.object(["keys": .number(Double(keys.count))])) }
            if about == "shells" { let open = try await shells.openShells(); _ = try await servers(context); return .init(S.object(["shells": .array(open.map { $0.setting("server", .string(name($0["serverId"].string ?? ""))) })]), S.object(["shells": .number(Double(open.count))])) }
            if about == "shell" { let shell = try await shell(A.str(args, "shellId")), shellID = shell["shellId"].string!; async let screen = shells.shellScreen(shellID); async let controls = call("servers:controls:read", [.string(shellID)], context); async let account = call("servers:shell:account", [.string(shellID)], context); let (text, control, signedIn) = try await (screen, controls, account); return .init(shell.removing("openedAt").setting("server", .string(name(shell["serverId"].string ?? ""))).setting("screen", text.map(V.string) ?? .null).setting("controls", control).setting("signedIn", signedIn), S.object(["shellId": .string(shellID), "screen": .bool(text != nil)])) }
            let serverID = try A.str(args, "serverId"), summary = S.object(["serverId": .string(serverID)]); try await requireServer(serverID, context)
            switch about {
            case "setup": let answer = try S.ok(await call("servers:setup:look", [.string(serverID)], context), key: "sentence"); return .init(summary.setting("agents", answer["rows"]), summary.setting("agents", .number(Double(answer["rows"].elements?.count ?? 0))))
            case "host": return .init(summary.setting("host", try S.ok(await call("servers:host:look", [.string(serverID)], context), key: "sentence")["offer"]), summary)
            case "ports": return .init(summary.setting("ports", try await call("servers:ports", [.string(serverID)], context)), summary)
            case "folder": return .init(try await call("servers:folder", [.string(serverID), .string(A.optStr(args, "path") ?? "")], context), summary)
            case "start-in": let answer = try await call("servers:start-in", [.string(serverID)], context); return .init(answer.setting("serverId", .string(serverID)), summary)
            case "grant": return .init(summary.setting("grant", try await call("servers:grant-state", [.string(serverID)], context)), summary)
            default: let answer = try S.ok(await call("servers:preview", [.string(serverID), .string(A.str(args, "cardId")), .string(A.str(args, "action"))], context), key: "sentence"); return .init(summary.setting("preview", answer["preview"]), summary.setting("action", args["action"]))
            }
        }
        if id == "servers.shell" {
            if verb == "open" { let serverID = try A.str(args, "serverId"); try await requireServer(serverID, context); let answer = try S.ok(await call("servers:shell:open", [.string(serverID), .number(120), .number(30), .string(A.optStr(args, "folder") ?? "")], context), key: "sentence"); return .init(S.object(["serverId": .string(serverID), "shellId": answer["shellId"], "note": .string("Read it with servers.details about \"shell\".")]), S.object(["serverId": .string(serverID), "shellId": answer["shellId"]])) }
            let shell = try await shell(A.str(args, "shellId")), shellID = shell["shellId"], summary = S.object(["serverId": shell["serverId"], "shellId": shellID])
            if verb == "close" { return .init(try await call("servers:shell:close", [shellID], context).setting("shellId", shellID), summary) }
            if verb == "set" { let answer = try S.ok(await call("servers:controls:apply", [shellID, args["control"], args["value"]], context)); return .init(answer, summary.setting("control", args["control"]).setting("value", args["value"])) }
            let write: @Sendable (String) async throws -> Void = { [self] data in let answer = try await self.call("servers:shell:write", [shellID, .string(data)], context); if answer["written"].bool != true { throw S.refused("That terminal closed before anything was typed.") } }
            var details = summary
            if verb == "type" { let text = try BackendDeckToolsSessionsTyping.sanitizeSendText(A.str(args, "text")), submit = try A.optBool(args, "submit", true); try await BackendDeckToolsSessionsTyping.typeLine(write: write, text: text, submit: submit, sleep: sleep); details = details.setting("text", .string(text)).setting("submitted", .bool(submit)) }
            else { try await BackendDeckToolsSessionsTyping.pressKeys(write: write, keys: BackendDeckToolsSessionsTyping.resolveKeys(args["keys"]), sleep: sleep); details = details.setting("keys", args["keys"]) }
            return .init(S.object(["shellId": shellID, "typed": .bool(true), "note": .string("servers.details about \"shell\" shows what it printed.")]), details)
        }
        if id == "servers.manage", verb == "add" {
            var draft: V
            if let key = try A.optStr(args, "keyPath") {
                let path: String
                if key == "choose" { let chosen = try await call("servers:key-pick", [], context); guard let picked = chosen["path"].string else { throw S.refused("No key file was chosen, or the file chosen is not a private key.") }; path = picked }
                else { _ = try await call("servers:keys", [], context); path = key }
                let read = try S.ok(await call("servers:key-read", [.string(path)], context), key: "sentence"); draft = S.object(["method": .string("key"), "key": read["key"]]); if let passphrase = try A.optStr(args, "passphrase") { draft = draft.setting("passphrase", .string(passphrase)) }
            } else { draft = S.object(["method": .string("password"), "password": .string(try A.str(args, "password"))]) }
            draft = draft.setting("address", .string(try A.str(args, "address"))).setting("username", .string(try A.str(args, "username"))).setting("remember", .bool(try A.optBool(args, "remember", true)))
            if let name = try A.optStr(args, "name") { draft = draft.setting("name", .string(name)) }; if args["port"] != .missing { draft = draft.setting("port", .number(Double(try A.int(args, "port", 1, 65_535)))) }
            let added = try S.ok(await call("servers:add", [draft], context), key: "sentence"); _ = try await servers(context); return .init(added, S.object(["serverId": added["id"], "savedSignIn": added["savedSignIn"]]))
        }
        let serverID = try A.str(args, "serverId"), summary = S.object(["serverId": .string(serverID)]); try await requireServer(serverID, context)
        if id == "servers.ports" {
            switch verb {
            case "open-here": return .init(try S.ok(await call("servers:reach", [.string(serverID), args["port"]], context), fallback: "That port could not be reached."), summary.setting("port", args["port"]))
            case "close-here": return .init(summary.setting("port", args["port"]).setting("closed", try await call("servers:reach:close", [.string(serverID), args["port"]], context)), summary.setting("port", args["port"]))
            default: let channel = verb == "disconnect" ? "servers:close" : verb == "cancel-setup" ? "servers:setup:cancel" : "servers:host:cancel"; return .init(try await call(channel, [.string(serverID)], context).setting("serverId", .string(serverID)), summary)
            }
        }
        if ["rename", "forget", "revoke", "set-start-in", "allow-windows"].contains(verb) {
            let channel = ["rename": "servers:rename", "forget": "servers:forget", "revoke": "servers:revoke", "set-start-in": "servers:start-in:set", "allow-windows": "servers:drive-windows"][verb]!
            var params: [V] = [.string(serverID)], details = summary
            if verb == "rename" { params.append(args["name"]); details = details.setting("name", args["name"]) }; if verb == "set-start-in" { let folder = try A.optStr(args, "folder") ?? ""; params.append(.string(folder)); details = details.setting("folder", .string(folder)) }; if verb == "allow-windows" { params.append(args["allowed"]); details = details.setting("allowed", args["allowed"]) }
            let answer = try await call(channel, params, context); if verb == "forget" { _ = try await servers(context) }; return .init(answer.setting("serverId", .string(serverID)), details)
        }
        if verb == "upload" { let path = try S.sendable(A.str(args, "path"), dataRoot: dataRoot, home: home), answer = try S.ok(await call("servers:upload", [.string(serverID), .string(path)], context)); return .init(summary.setting("path", answer["path"]), summary.setting("from", .string(path))) }
        if verb == "remove-agent" || verb == "remove-host" { let channel = verb == "remove-agent" ? "servers:setup:remove" : "servers:host:remove", value = verb == "remove-agent" ? V.string(try A.oneOf(args, "agent", ["claude", "codex", "gemini"])) : .bool(try A.optBool(args, "alsoData", false)), answer = try S.ok(await call(channel, [.string(serverID), value], context), key: "sentence")["state"]; return .init(summary.setting("state", answer), summary.setting("step", answer["step"])) }
        let named = try A.optStr(args, "shellId"), shellID: String
        if let named { shellID = named } else { shellID = try S.ok(await call("servers:shell:open", [.string(serverID), .number(120), .number(30), .string("")], context), key: "sentence")["shellId"].requireString("opened shell id") }
        let channel = ["install-agent": "servers:setup:install", "sign-in-agent": "servers:setup:signin", "sign-out-agent": "servers:setup:signout", "install-host": "servers:host:install", "pair-host": "servers:host:pair", "link-host": "servers:host:link"][verb]
        guard let channel else { throw A.bad("Unknown server verb") }
        var params: [V] = [.string(serverID)]; if Self.agentVerbs.contains(verb) { params.append(.string(try A.oneOf(args, "agent", ["claude", "codex", "gemini"]))) }; params.append(.string(shellID))
        let state = try S.ok(await call(channel, params, context), key: "sentence")["state"], finished = ["done", "failed", "idle"].contains(state["step"].string ?? "")
        if named == nil && finished { _ = try await call("servers:shell:close", [.string(shellID)], context) }
        var result = summary.setting("state", state); if !finished { result = result.setting("shellId", .string(shellID)).setting("note", .string("Still going, in this terminal. Watch it with servers.details about \"shell\"; closing it cancels what is running.")) }; return .init(result, summary.setting("step", state["step"]))
    }
}
