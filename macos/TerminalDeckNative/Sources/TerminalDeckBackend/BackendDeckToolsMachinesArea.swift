import Foundation
import TerminalDeckNativeCore

public struct BackendDeckToolsMachinesStateWaiter: Sendable {
    public let registry: NativeChannelRegistry
    private let clock: any BackendDeckCoreEventsClock
    public init(registry: NativeChannelRegistry, clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock()) {
        self.registry = registry; self.clock = clock
    }
    public func next(matches: @escaping @Sendable (NativeRPCValue) -> Bool, ceilingMS: Int,
                     after: @escaping @Sendable () async throws -> Void) async throws -> NativeRPCValue? {
        let clock = self.clock
        let stream = try await registry.events("machines:state", ownerID: "deck-tools-machine-state-" + UUID().uuidString)
        let pending = Task { try await withThrowingTaskGroup(of: NativeRPCValue?.self) { group in
            group.addTask { for try await event in stream { let view = event.arguments.first ?? .missing; if view["machines"].elements != nil && matches(view) { return view } }; return nil }
            group.addTask { try await BackendDeckToolsMachinesPortClock.wait(clock: clock, milliseconds: Double(ceilingMS)); return nil }
            defer { group.cancelAll() }; return try await group.next() ?? nil
        } }
        do { try await after(); return try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() } }
        catch { pending.cancel(); throw error }
    }
}

/// Six native wrappers over the same machine registry used by the native Machines panel.
public actor BackendDeckToolsMachinesArea {
    public typealias V = NativeRPCValue
    typealias S = BackendDeckToolsMachinesShared
    typealias A = BackendDeckToolsArgs
    public static let ids = ["machines.look", "machines.session", "machines.copilot", "machines.ports", "machines.upload", "machines.manage"]
    private let channels: any BackendDeckToolsMachinesChannels
    private let stateWaiter: BackendDeckToolsMachinesStateWaiter
    private let watch: BackendDeckToolsMachinesWatch
    private let dataRoot: URL
    private let home: URL
    private let sleep: @Sendable (Int) async throws -> Void
    private var lastView: V?
    public init(channels: any BackendDeckToolsMachinesChannels, stateWaiter: BackendDeckToolsMachinesStateWaiter,
                watch: BackendDeckToolsMachinesWatch, dataRoot: URL, home: URL,
                sleep: @escaping @Sendable (Int) async throws -> Void = BackendDeckToolsSessionsTyping.realSleep) {
        self.channels = channels; self.stateWaiter = stateWaiter; self.watch = watch; self.dataRoot = dataRoot; self.home = home; self.sleep = sleep
    }
    public static func startedKey(_ machine: String, _ session: String) -> String { "machine:\(machine):\(session)" }
    private func name(_ id: String) -> String { lastView?["machines"].elements?.first { $0["id"].string == id }?["name"].string ?? id }
    private func call(_ channel: String, _ args: [V], _ context: BackendDeckToolsMachinesContext) async throws -> V {
        await watch.invoked(channel, args); return try await channels.call(channel, args, context: context)
    }
    private func view(_ context: BackendDeckToolsMachinesContext) async throws -> V { let value = try await call("machines:list", [], context); lastView = value; return value }
    private func known(_ id: String, in view: V?) throws {
        if let view, !(view["machines"].elements ?? []).contains(where: { $0["id"].string == id }) { throw S.refused("There is no machine with the id \(id) in this app. Use machines.look to see the machines it is paired to.") }
    }
    private func requireMachine(_ id: String, _ context: BackendDeckToolsMachinesContext) async throws -> V { let value = try await view(context); try known(id, in: value); return value }
    private static func sessions(_ view: V, _ machine: String) -> [V] { view["links"].elements?.first { $0["id"].string == machine }?["sessions"].elements ?? [] }
    private func requireSession(_ machine: String, _ session: String, _ context: BackendDeckToolsMachinesContext) async throws -> V {
        let value = try await requireMachine(machine, context)
        guard let found = Self.sessions(value, machine).first(where: { $0["id"].string == session }) else { throw S.refused("\(name(machine)) has no session \(session) that this computer can see. Use machines.look with that machineId to list its sessions.") }; return found
    }
    public static func sessionRow(_ value: V) -> V { S.object(["id": value["id"], "title": value["title"], "folder": value["cwd"], "agent": value["provider"], "status": value["status"], "exitCode": value["exitCode"]]) }
    public static func rows(_ view: V, mine: @Sendable (String, String) async -> Bool = { _, _ in false }) async -> [V] {
        var rows: [V] = []
        for machine in view["machines"].elements ?? [] {
            let id = machine["id"].string ?? "", link = view["links"].elements?.first { $0["id"].string == id } ?? .missing
            var sessions: [V] = []
            for session in link["sessions"].elements ?? [] { sessions.append(sessionRow(session).setting("startedByYou", .bool(await mine(id, session["id"].string ?? "")))) }
            rows.append(S.object(["id": machine["id"], "name": machine["name"], "platform": machine["platform"], "state": .string(link["state"].string ?? "offline"), "online": .bool(link["state"].string == "online"), "why": link["reason"].isNullish ? .null : link["reason"], "sessions": .array(sessions), "folders": link["folders"].isNullish ? .null : link["folders"], "ports": link["ports"].isNullish ? .array([]) : link["ports"], "sharesCopilot": .bool(!link["copilot"].isNullish), "hostVersion": .string(link["hostVersion"].string ?? ""), "lastConnectedAt": machine["lastConnectedAt"]]))
        }
        return rows
    }
    public func definitions(environment: any BackendDeckToolsMachinesEnvironment) throws -> [BackendDeckToolsDefinition] {
        try BackendDeckToolsMachinesFactory.definitions(ids: Self.ids, environment: environment,
            prepare: { [self] spec, args, context in try await self.policy(spec, args, context) },
            run: { [self] id, args, context in try await self.run(id, args, context) })
    }
    public func policy(_ spec: BackendMCPTool, _ args: V, _ context: BackendDeckToolsMachinesContext) async throws -> BackendDeckToolsMachinesPolicy {
        let id = spec.id, verb = args["do"].string ?? ""
        let words = ["machines.look": "Looking at the other computers", "machines.session": "Driving a session on another computer", "machines.copilot": "Talking to Hoot on another computer", "machines.ports": "Reaching another computer’s ports", "machines.upload": "Sending files to another computer", "machines.manage": "Changing which computers this app is paired to"]
        try S.hereOnly(context, words[id] ?? "Using another computer")
        let machine = try A.optStr(args, "machineId"), session = try A.optStr(args, "sessionId")
        if id == "machines.look", session != nil { _ = try A.str(args, "machineId") }
        if id != "machines.look", id != "machines.manage" || !["pair", "show-code", "cancel-code"].contains(verb) { try known(A.str(args, "machineId"), in: lastView) }
        var tier = spec.tier
        switch id {
        case "machines.session":
            _ = try A.oneOf(args, "do", ["start", "send", "keys", "stop", "rename", "set", "switch-login", "watch"])
            if verb != "start" { _ = try A.str(args, "sessionId") }
            if verb == "send" { _ = try BackendDeckToolsSessionsTyping.sanitizeSendText(A.str(args, "text")) }
            if verb == "keys" { _ = try BackendDeckToolsSessionsTyping.resolveKeys(.array(A.strList(args, "keys").map(V.string))) }
            if verb == "set" { _ = try A.oneOf(args, "control", ["model", "effort", "fast", "permission"]); _ = try A.str(args, "value") }
            if verb == "switch-login" { _ = try A.str(args, "loginId") }
            if verb == "rename", args["title"].string == nil { throw A.bad("title is required for rename") }
            if !["start", "watch", "rename"].contains(verb) { let own = await context.startedByCopilot(Self.startedKey(machine ?? "", session ?? "")); tier = verb == "switch-login" || (verb == "set" && args["control"].string == "permission") || !own ? .alter : .act }
        case "machines.copilot":
            _ = try A.oneOf(args, "do", ["read", "say", "start"])
            if verb == "say" { _ = try BackendDeckToolsSessionsTyping.sanitizeSendText(A.str(args, "text")) }
            if args["waitSeconds"] != .missing { _ = try A.int(args, "waitSeconds", 0, 120) }
            if args["messages"] != .missing { _ = try A.int(args, "messages", 1, 100) }
        case "machines.ports":
            _ = try A.oneOf(args, "do", ["list", "refresh", "open-here", "close-here", "open-there"])
            if ["open-here", "close-here"].contains(verb) { _ = try A.int(args, "port", 1, 65_535) }
            if verb == "open-there", try A.str(args, "url").utf16.count > 2_048 { throw A.bad("url must be 2048 characters or fewer") }
        case "machines.upload":
            _ = try A.oneOf(args, "do", ["send", "cancel"]); tier = verb == "cancel" ? .act : .alter
            if verb == "send" { _ = try S.sendable(A.str(args, "path"), dataRoot: dataRoot, home: home) }
        case "machines.manage":
            _ = try A.oneOf(args, "do", ["pair", "show-code", "cancel-code", "connect", "disconnect", "rename", "forget", "allow-windows", "restart-host", "stop-host", "sign-in", "sign-out", "github-connect", "github-cancel", "github-disconnect"])
            if verb == "pair" { _ = try A.str(args, "code") }; if verb == "rename" { _ = try A.str(args, "name") }
            if verb == "allow-windows" { _ = try A.bool(args, "allowed") }; if ["sign-in", "sign-out"].contains(verb) { _ = try A.str(args, "loginId") }
        default: break
        }
        return .init(tool: spec, arguments: args, loggedArguments: args, tier: tier, ownerMustAnswer: id == "machines.manage", sentence: sentence(id, args))
    }
    public func sentence(_ id: String, _ args: V) -> String {
        let verb = args["do"].string ?? "", machine = name(args["machineId"].string ?? "?"), target = "session \(args["sessionId"].string ?? "?") on \(machine)"
        let value = { (key: String) in args[key].string ?? "undefined" }
        switch id {
        case "machines.look": if args["machineId"].isNullish { return "List the other computers this app is paired to" }; return args["sessionId"].isNullish ? "Look at \(machine)" : "Look at \(target)"
        case "machines.session": switch verb {
            case "start": return "Start a \(args["agent"].string.map { $0 + " " } ?? "")session on \(machine)\((args["folder"].string ?? "").isEmpty ? "" : " in " + value("folder"))"
            case "send": return "Type into \(target): “\(args["text"].string ?? "")”\(args["submit"].bool == false ? "" : " and press return")"
            case "keys": return "Press \((args["keys"].elements ?? []).compactMap(\.string).joined(separator: ", ")) in \(target)"
            case "stop": return "Stop \(target). Whatever it was doing ends and cannot be resumed from here."
            case "rename": return "Rename \(target) to “\(args["title"].string ?? "")”"
            case "set": return "Set \(value("control")) to \(value("value")) in \(target)"
            case "switch-login": return "Restart \(target) as the login \(value("loginId")). The agent process there is ended and started again."
            default: return "Start receiving the screen of \(target) (it is sized 120×30 there)"
        }
        case "machines.copilot": return verb == "say" ? "Say to Hoot on \(machine): “\(value("text"))”" : verb == "start" ? "Start Hoot on \(machine)" : "Read the conversation with Hoot on \(machine)"
        case "machines.ports": switch verb { case "open-here": return "Give port \(args["port"].compact) on \(machine) an address on this computer"; case "close-here": return "Stop serving port \(args["port"].compact) of \(machine) here"; case "open-there": return "Open \(value("url")) in the browser on \(machine)"; case "refresh": return "Ask \(machine) what it is serving"; default: return "List what \(machine) is serving" }
        case "machines.upload": return verb == "cancel" ? "Cancel the file transfer to \(machine)" : "Send \(value("path")) from this computer to \(machine), into \((args["folder"].string ?? "").isEmpty ? "its downloads folder" : value("folder"))"
        default: switch verb {
            case "pair": return "Pair this computer to the one showing that code, so this app can reach it and its sessions"
            case "show-code": return "Show a pairing code on this computer, so another computer can be paired to it"
            case "cancel-code": return "Withdraw the pairing code on screen"
            case "connect": return "Connect to \(machine)"
            case "disconnect": return "Disconnect from \(machine) until it is connected again"
            case "rename": return "Rename \(machine) to “\(value("name"))” in this app"
            case "forget": return "Forget \(machine): this computer stops reaching it and would need a new code to pair again"
            case "allow-windows": return args["allowed"].bool == true ? "Let sessions on \(machine) drive browser windows in this app" : "Stop sessions on \(machine) driving browser windows in this app"
            case "restart-host": return "Restart the host program on \(machine). Its connections drop and come back"
            case "stop-host": return "Stop the host program on \(machine). It cannot be started again from here — only on that computer"
            case "sign-in": return "Sign in the agent login \(value("loginId")) on \(machine)"
            case "sign-out": return "Sign out the agent login \(value("loginId")) on \(machine)"
            case "github-connect": return "Connect \(machine) to GitHub"
            case "github-cancel": return "Cancel the GitHub sign-in waiting on \(machine)"
            default: return "Disconnect \(machine) from GitHub"
        }
        }
    }
    public func run(_ id: String, _ args: V, _ context: BackendDeckToolsMachinesContext) async throws -> BackendDeckToolsMachinesOutput {
        let machine = try A.optStr(args, "machineId"), session = try A.optStr(args, "sessionId"), verb = args["do"].string ?? ""
        let mine: @Sendable (String, String) async -> Bool = { await context.startedByCopilot(Self.startedKey($0, $1)) }
        if id == "machines.look" {
            let state: V
            if let machine { state = try await requireMachine(machine, context) } else { state = try await view(context) }
            let rows = await Self.rows(state, mine: mine)
            guard let machine else {
                var result = S.object(["thisComputer": state["here"], "machines": .array(rows)])
                if !state["blocked"].isNullish { result = result.setting("cannotPairNow", state["blocked"]) }
                if rows.isEmpty { result = result.setting("note", .string("This computer is not paired to any other. machines.manage with do \"pair\" and a code shown on the other computer adds one.")) }
                return .init(result, S.object(["machines": .number(Double(rows.count)), "online": .number(Double(rows.filter { $0["online"].bool == true }.count))]))
            }
            let row = rows.first { $0["id"].string == machine } ?? .null
            guard let session else {
                if row["online"].bool != true { return .init(row.setting("note", .string("\(name(machine)) is not connected, so it cannot be asked anything right now.")), S.object(["machineId": .string(machine), "online": .bool(false)])) }
                async let host = call("machines:host:read", [.string(machine)], context)
                async let logins = call("machines:logins:read", [.string(machine)], context)
                async let github = call("machines:github:read", [.string(machine)], context)
                let answers = try await [host, logins, github]
                var value = row; for (index, key) in ["host", "logins", "github"].enumerated() { value = value.setting(key, answers[index].isNullish ? .string("did not answer") : answers[index]) }
                return .init(value, S.object(["machineId": .string(machine), "online": .bool(true), "answered": .number(Double(answers.filter { !$0.isNullish }.count))]))
            }
            let target = try await requireSession(machine, session, context)
            async let screen = watch.screen(machine, session)
            async let controls = call("machines:controls:read", [.string(machine), .string(session)], context)
            async let login = call("machines:account:read", [.string(machine), .string(session)], context)
            async let plan = call("machines:usage:read", [.string(machine), .string(session), .string("plan"), .bool(false)], context)
            async let window = call("machines:usage:read", [.string(machine), .string(session), .string("context"), .bool(false)], context)
            let (seen, controlsValue, loginValue, planValue, windowValue) = try await (screen, controls, login, plan, window)
            var value = Self.sessionRow(target).setting("machineId", .string(machine)).setting("machine", .string(name(machine))).setting("startedByYou", .bool(await mine(machine, session))).setting("screen", seen).setting("controls", controlsValue.isNullish ? .string("did not answer") : controlsValue).setting("login", loginValue.isNullish ? .string("did not answer") : loginValue).setting("usage", S.object(["plan": planValue, "context": windowValue]))
            if seen.isNullish { value = value.setting("screenNote", .string("Nothing on this computer is showing that session, so its screen has not been seen here. machines.session with do \"watch\" starts receiving it.")) }
            else if seen["live"].bool != true { value = value.setting("screenNote", .string("This is the last screen seen here; nothing on this computer is receiving it now.")) }
            return .init(value, S.object(["machineId": .string(machine), "sessionId": .string(session), "screen": .bool(!seen.isNullish), "live": .bool(seen["live"].bool == true)]))
        }
        if id == "machines.manage", ["pair", "show-code", "cancel-code"].contains(verb) {
            if verb == "cancel-code" { _ = try await call("machines:code:cancel", [], context); return .init(S.object(["cancelled": .bool(true)]), S.object(["cancelled": .bool(true)])) }
            if verb == "show-code" { let answer = try S.ok(await call("machines:code", [], context)); return .init(S.object(["code": answer["code"]["token"], "expiresAt": answer["code"]["expiresAt"], "note": .string("Type this on the other computer, in its Machines list. It works once.")]), S.object(["shown": .bool(true), "expiresAt": answer["code"]["expiresAt"]])) }
            let result = try S.ok(await call("machines:pair", [.string(A.str(args, "code"))], context)), state = try await view(context)
            let host = result["offer"]["hostId"].string ?? result["offer"]["id"].string ?? ""
            let row = await Self.rows(state).first { $0["id"].string == host }
            return .init(S.object(["paired": .bool(true), "machineId": .string(host), "name": row?["name"] ?? result["offer"]["name"], "machine": row ?? .null]), S.object(["paired": .bool(true), "machineId": .string(host)]))
        }
        let machineID = try A.str(args, "machineId"), state = try await requireMachine(machineID, context), summary = S.object(["machineId": .string(machineID)])
        if id == "machines.session" {
            if verb == "start" {
                let before = Set(Self.sessions(state, machineID).compactMap { $0["id"].string }), agent = try A.optStr(args, "agent") ?? ""
                if !agent.isEmpty && !["claude", "codex", "gemini", "shell"].contains(agent) { throw A.bad("agent must be one of: claude, codex, gemini, shell") }
                let sent = BackendDeckToolsMachinesBooleanBox()
                let next = try await stateWaiter.next(matches: { Self.sessions($0, machineID).contains { !before.contains($0["id"].string ?? "") } }, ceilingMS: 15_000) { [self] in await sent.set(try await self.call("machines:create", [.string(machineID), .string(A.optStr(args, "folder") ?? ""), .string(agent)], context).bool == true) }
                if !(await sent.value) { throw S.refused("\(name(machineID)) could not be asked to start a session: it is not connected, or its build cannot start one from here.") }
                guard let started = next.flatMap({ Self.sessions($0, machineID).first { !before.contains($0["id"].string ?? "") } }) else { return .init(summary.setting("sessionId", .null).setting("note", .string("The request reached \(name(machineID)) but no new session appeared within 15 seconds. That computer may have refused the folder; machines.look on it shows its sessions and the folders it allows.")), summary.setting("started", .bool(false))) }
                await context.noteStarted(Self.startedKey(machineID, started["id"].string ?? "")); return .init(Self.sessionRow(started).setting("machineId", .string(machineID)).setting("startedByYou", .bool(true)), summary.setting("sessionId", started["id"]).setting("started", .bool(true)))
            }
            let sessionID = try A.str(args, "sessionId"), target = try await requireSession(machineID, sessionID, context), both = summary.setting("sessionId", .string(sessionID)), params: [V] = [.string(machineID), .string(sessionID)]
            if ["send", "keys"].contains(verb) {
                if !target["exitCode"].isNullish { throw A.bad("session \(sessionID) has already exited; there is nothing to type into") }
                let write: @Sendable (String) async throws -> Void = { [self] data in _ = try S.ok(await self.call("machines:send", params + [.string(data)], context)) }
                if verb == "send" { try await BackendDeckToolsSessionsTyping.typeLine(write: write, text: BackendDeckToolsSessionsTyping.sanitizeSendText(A.str(args, "text")), submit: A.optBool(args, "submit", true), sleep: sleep) }
                else { try await BackendDeckToolsSessionsTyping.pressKeys(write: write, keys: BackendDeckToolsSessionsTyping.resolveKeys(args["keys"]), sleep: sleep) }
                return .init(both.setting("sent", .bool(true)), verb == "send" ? both.setting("text", args["text"]).setting("submitted", .bool(try A.optBool(args, "submit", true))) : both.setting("keys", args["keys"]))
            }
            if verb == "set" { let answer = try S.ok(await call("machines:controls:apply", params + [args["control"], args["value"]], context)); return .init(answer, both.setting("control", args["control"]).setting("value", args["value"])) }
            if verb == "switch-login" { let answer = try S.ok(await call("machines:account:switch", params + [args["loginId"]], context)); if let new = answer["session"].string, await mine(machineID, sessionID) { await context.noteStarted(Self.startedKey(machineID, new)) }; return .init(S.object(["machineId": .string(machineID), "sessionId": answer["session"], "previousSessionId": .string(sessionID), "message": answer["message"]]), both.setting("now", answer["session"])) }
            if verb == "watch" {
                if await watch.attached(machineID, sessionID) { return .init(both.setting("watching", .bool(true)).setting("note", .string("Already being received here.")), both.setting("already", .bool(true))) }
                guard try await call("machines:attach", params + [.number(120), .number(30)], context).bool == true else { throw S.refused("\(name(machineID)) is not connected, so its sessions cannot be watched right now.") }; return .init(both.setting("watching", .bool(true)).setting("note", .string("machines.look with this sessionId now shows its screen.")), both.setting("watching", .bool(true)))
            }
            let answer = try await call(verb == "stop" ? "machines:close" : "machines:session:rename", params + (verb == "rename" ? [args["title"]] : []), context)
            guard answer.bool == true else { throw S.refused(verb == "stop" ? "\(name(machineID)) could not be asked to stop that session: it is not connected, or its build cannot." : "\(name(machineID)) could not be asked to rename it: not connected, or too old a build.") }
            return .init(both.setting(verb == "stop" ? "stopRequested" : "renameRequested", .bool(true)), verb == "rename" ? both.setting("title", args["title"]) : both)
        }
        if id == "machines.copilot" {
            let limit = args["messages"] == .missing ? 20 : try A.int(args, "messages", 1, 100)
            if verb == "start" { _ = try S.ok(await call("machines:copilot:start", [.string(machineID)], context)); return .init(await shapedChat(machineID, limit), summary.setting("started", .bool(true))) }
            let beforeAttach = await watch.conversation(machineID)
            _ = try await watch.nextChange(machineID, ceilingMS: beforeAttach["changedAt"].isNullish ? 3_000 : 0) { [self] in _ = try S.ok(await self.call("machines:copilot:attach", [.string(machineID)], context)); _ = try await self.call("machines:copilot:refresh", [.string(machineID)], context) }
            if verb == "read" { let chat = await watch.conversation(machineID); return .init(await shapedChat(machineID, limit), summary.setting("messages", .number(Double(chat["messages"].elements?.count ?? 0)))) }
            let text = try BackendDeckToolsSessionsTyping.sanitizeSendText(A.str(args, "text")), old = await watch.conversation(machineID)["messages"].elements?.last?["id"].string
            _ = try S.ok(await call("machines:copilot:say", [.string(machineID), .string(text)], context))
            let seconds = args["waitSeconds"] == .missing ? 0 : try A.int(args, "waitSeconds", 0, 120)
            let answered: Bool? = seconds == 0 ? nil : await watch.replied(machineID, since: old, ceilingMS: seconds * 1_000)
            var value = await shapedChat(machineID, limit).setting("said", .string(text)); if let answered { value = value.setting("answered", .bool(answered)); if !answered { value = value.setting("note", .string("No finished answer within \(seconds) seconds; read again later.")) } }
            return .init(value, summary.setting("text", .string(text)).setting("waited", .number(Double(seconds))).setting("answered", answered.map(V.bool) ?? .null))
        }
        if id == "machines.ports" {
            if ["list", "refresh"].contains(verb) {
                var source = state
                if verb == "refresh" { let asked = BackendDeckToolsMachinesBooleanBox(); let pushed = try await stateWaiter.next(matches: { ($0["links"].elements ?? []).contains { $0["id"].string == machineID } }, ceilingMS: 6_000) { [self] in await asked.set(try await self.call("machines:ports", [.string(machineID)], context).bool == true) }; if !(await asked.value) { throw S.refused("\(name(machineID)) is not connected, so it cannot be asked.") }; if let pushed { source = pushed } else { source = try await view(context) } }
                let ports = source["links"].elements?.first { $0["id"].string == machineID }?["ports"].elements ?? []; return .init(summary.setting("ports", .array(ports)), summary.setting("ports", .number(Double(ports.count))))
            }
            if verb == "open-here" { return .init(try S.ok(await call("machines:reach", [.string(machineID), args["port"]], context), fallback: "That port could not be reached."), summary.setting("port", args["port"])) }
            if verb == "close-here" { return .init(summary.setting("port", args["port"]).setting("closed", try await call("machines:reach:close", [.string(machineID), args["port"]], context)), summary.setting("port", args["port"])) }
            guard try await call("machines:open", [.string(machineID), args["url"]], context).bool == true else { throw S.refused("\(name(machineID)) could not be asked to open it: not connected, or its build cannot.") }; return .init(summary.setting("url", args["url"]).setting("opened", .bool(true)), summary.setting("url", args["url"]))
        }
        if id == "machines.upload" {
            if verb == "cancel" { return .init(summary.setting("cancelled", try await call("machines:upload:cancel", [.string(machineID)], context)), summary) }
            let path = try S.sendable(A.str(args, "path"), dataRoot: dataRoot, home: home)
            return .init(try S.ok(await call("machines:upload", [.string(machineID), .string(path), .string(A.optStr(args, "folder") ?? "")], context), fallback: "That file did not send."), summary.setting("path", .string(path)))
        }
        let channelsByVerb = ["connect": "machines:connect", "disconnect": "machines:disconnect", "rename": "machines:rename", "forget": "machines:forget", "allow-windows": "machines:drive-windows", "restart-host": "machines:host:restart", "stop-host": "machines:host:stop", "sign-in": "machines:logins:signin", "sign-out": "machines:logins:signout", "github-connect": "machines:github:connect", "github-cancel": "machines:github:cancel", "github-disconnect": "machines:github:disconnect"]
        guard let channel = channelsByVerb[verb] else { throw A.bad("Unknown machine verb") }
        var params: [V] = [.string(machineID)]; if verb == "rename" { params.append(args["name"]) }; if verb == "allow-windows" { params.append(args["allowed"]) }; if ["sign-in", "sign-out"].contains(verb) { params.append(args["loginId"]) }
        let answer = try await call(channel, params, context)
        if ["connect", "disconnect", "rename", "allow-windows"].contains(verb) { return .init(S.object(["machine": await Self.rows(answer).first { $0["id"].string == machineID } ?? .null]), verb == "rename" ? summary.setting("name", args["name"]) : verb == "allow-windows" ? summary.setting("allowed", args["allowed"]) : summary) }
        if verb == "forget" { lastView = answer; return .init(S.object(["forgotten": .bool(!(answer["machines"].elements ?? []).contains { $0["id"].string == machineID })]), summary) }
        if ["restart-host", "stop-host"].contains(verb) { return .init(summary.setting("answer", answer.isNullish ? .string("No reply. The host may already be acting on it, which drops the connection; machines.look shows the link coming back.") : answer), summary.setting("answered", .bool(!answer.isNullish))) }
        if ["sign-in", "sign-out"].contains(verb) { return .init(try S.ok(answer), summary.setting("loginId", args["loginId"])) }
        return .init(summary.setting("github", answer.isNullish ? .string("did not answer") : answer), summary.setting("verb", .string(verb)))
    }
    private func shapedChat(_ machine: String, _ limit: Int) async -> V { let chat = await watch.conversation(machine); return S.object(["machineId": .string(machine), "state": chat["state"], "run": chat["run"], "messages": .array(Array((chat["messages"].elements ?? []).suffix(limit)))]) }
}

actor BackendDeckToolsMachinesBooleanBox { var value = false; func set(_ value: Bool) { self.value = value } }
public enum BackendDeckToolsMachinesFactory {
    public static func metadata(_ definitions: [BackendDeckToolsDefinition]) -> [BackendDeckCoreCatalogueMetadata] {
        definitions.map { .init(tool: $0.spec, title: $0.title, aliases: $0.aliases, index: $0.index) }
    }
    public static func definitions(ids: [String], environment: any BackendDeckToolsMachinesEnvironment,
        prepare: @escaping @Sendable (BackendMCPTool, NativeRPCValue, BackendDeckToolsMachinesContext) async throws -> BackendDeckToolsMachinesPolicy,
        run: @escaping @Sendable (String, NativeRPCValue, BackendDeckToolsMachinesContext) async throws -> BackendDeckToolsMachinesOutput) throws -> [BackendDeckToolsDefinition] {
        try BackendDeckToolsMachinesCatalogue.rows().filter { ids.contains($0["id"].string ?? "") }.map { row in
            let id = try row["id"].requireString("tool id")
            guard let tier = BackendMCPTier(rawValue: row["tier"].string ?? "") else { throw BackendDeckToolsArgs.bad("Unknown native machine-area tool tier") }
            let spec = try BackendMCPTool(id: id, wireName: row["wire"].requireString("wire name"), description: row["description"].requireString("description"), inputSchema: row["inputSchema"], tier: tier, advertised: false)
            return BackendDeckToolsDefinition(spec: spec, title: row["title"].string ?? "", index: row["index"].string) { call, args in
                var prepared: BackendDeckToolsMachinesPolicy?
                do {
                    let context = try await environment.context(for: call)
                    try await environment.validate(arguments: args, schema: spec.inputSchema)
                    let policy = try await prepare(spec, args, context)
                    prepared = policy
                    return try await environment.execute(context: context, policy: policy) { try await run(id, args, context) }
                } catch {
                    return await environment.failed(call: call, tool: spec, policy: prepared,
                        loggedArguments: prepared?.loggedArguments ?? loggedArguments(toolID: id, arguments: args), error: error)
                }
            }
        }
    }
    public static func loggedArguments(toolID: String, arguments: NativeRPCValue) -> NativeRPCValue {
        var result = arguments
        if toolID == "devices.type", let text = arguments["text"].string { result = result.setting("text", .string("[\(text.utf16.count) characters]")) }
        if toolID == "servers.manage" { for key in ["password", "passphrase"] where arguments[key] != .missing { result = result.setting(key, .string("[redacted]")) } }
        return result
    }
    /// Used by the central gate after recording a failed call, preserving the actual refusal.
    public static func failureReply(_ error: any Error) -> BackendMCPToolReply {
        let message: String, refusal: NativeRPCValue
        if let source = error as? BackendDeckCoreSecurityRefusal { message = source.message; refusal = .string(source.reason.rawValue) }
        else if let source = error as? NativeRPCError { message = source.message; refusal = ["not-permitted", "not-granted", "not-permitted-unattended"].contains(source.code) ? .string(source.code) : .null }
        else if error is CancellationError { message = "The caller went away."; refusal = .null }
        else { message = error.localizedDescription; refusal = .null }
        return .init(content: [.object([.init("type", .string("text")), .init("text", .string(message))])],
                     structuredContent: .object([.init("ok", .bool(false)), .init("error", .string(message)), .init("refusal", refusal)]), isError: true)
    }

}
