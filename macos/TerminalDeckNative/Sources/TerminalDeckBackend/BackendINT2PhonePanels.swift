import Foundation
import TerminalDeckNativeCore

/// Supplied only by the authenticated host's panel dispatch, never a wire field.
public enum BackendINT2PhonePanelCaller {
    @TaskLocal public static var current: BackendRemoteHostContext?
}

private actor BackendINT2PhonePanelResult {
    var result: BackendDeckCoreSecurityCallResult?
    func set(_ value: BackendDeckCoreSecurityCallResult) { result = value }
    func get() throws -> BackendDeckCoreSecurityCallResult {
        guard let result else { throw NativeRPCError(code: "panel-unavailable", message: "The current core call did not return an outcome.") }
        return result
    }
}

/// Every operation enters the existing control/consent door with a live device
/// grant. No native-app context, independent caller table or receipt is minted.
public struct BackendINT2PhonePanelScope: Sendable {
    public let endpoint: BackendRemoteHost
    public let trust: BackendRemoteTrustStore
    public let control: BackendDeckCoreSecurityControl
    public let bindings: BackendCompositionProductionBindings
    public let projectRows: @Sendable () -> [NativeRPCValue]
    public let sessionLinks: @Sendable ([NativeRPCValue], NativeRPCContext) async throws -> [String: String]
    public init(endpoint: BackendRemoteHost, trust: BackendRemoteTrustStore, control: BackendDeckCoreSecurityControl,
                bindings: BackendCompositionProductionBindings, projectRows: @escaping @Sendable () -> [NativeRPCValue],
                sessionLinks: @escaping @Sendable ([NativeRPCValue], NativeRPCContext) async throws -> [String: String]) {
        self.endpoint = endpoint; self.trust = trust; self.control = control; self.bindings = bindings
        self.projectRows = projectRows; self.sessionLinks = sessionLinks
    }
    public func current(_ rpc: NativeRPCContext, domain: String, mutation: Bool = false) async throws -> BackendRemoteHostContext {
        guard let issued = BackendINT2PhonePanelCaller.current, rpc.caller == .pairedDevice, rpc.ownerID == issued.deviceID else {
            throw NativeRPCError(code: "access-denied", message: "This panel needs its original authenticated device connection.")
        }
        let current = try await endpoint.refreshedContext(issued)
        if ["settings", "hooks", "simulators", "servers"].contains(domain), current.kind != .mine {
            throw NativeRPCError(code: "access-denied", message: "This machine panel belongs to an owner-approved device.")
        }
        guard current.claimedCapabilities.contains("panels." + domain) else {
            throw NativeRPCError(code: "access-denied", message: "This device did not negotiate panels.")
        }
        try await trust.requirePhoneAccess(current.deviceID, message: mutation ? "panel.act" : "panel.read", panel: domain)
        return current
    }
    public func projects(_ rpc: NativeRPCContext, domain: String) async throws -> [NativeRPCValue] {
        let context = try await current(rpc, domain: domain)
        return projectRows().filter { row in
            guard let path = row["path"].string, !path.isEmpty else { return false }
            return context.reach.unrestricted || context.reach.folders.contains { BackendRemoteTrustStore.within($0, path) }
        }
    }
    public func level(_ rpc: NativeRPCContext, domain: String) async throws -> BackendINT2PhoneAccessLevel {
        let context = try await current(rpc, domain: domain)
        guard let level = await trust.phoneAccess(context.deviceID) else { throw CancellationError() }
        return level
    }
    private static func workOperation(domain: String, tool: String, args: NativeRPCValue) -> Bool {
        switch (domain, tool) {
        case ("tasks", "tasks.local_change"): return ["create", "update", "status", "assign"].contains(args["do"].string ?? "")
        case ("goals", "tasks.goals"): return ["create", "update", "remove"].contains(args["do"].string ?? "")
        case ("staysfixed", "fixed.check"), ("staysfixed", "fixed.stop"), ("simulators", "devices.open"): return true
        default: return false
        }
    }
    public func call(_ tool: String, arguments: NativeRPCValue, rpc: NativeRPCContext, domain: String,
                     tier: BackendMCPTier = .read, projects paths: [String] = []) async throws -> NativeRPCValue {
        let mutation = tier != .read
        let context = try await current(rpc, domain: domain, mutation: mutation)
        guard let policy = await control.policy(named: tool), BackendUIGMemoryDiscovery.showsTool(policy.tool) else {
            throw NativeRPCError(code: "panel-unavailable", message: "The existing " + tool + " tool is unavailable.")
        }
        let tools: Set<String> = [policy.tool.id, policy.tool.wireName]
        let cancellation = BackendMCPCancellation()
        let liveCaller: @Sendable () async -> BackendDeckCoreSecurityCaller = {
            do {
                let fresh = try await current(rpc, domain: domain, mutation: mutation)
                guard let level = await trust.phoneAccess(fresh.deviceID), level.tiers.contains(tier),
                      level != .work || !mutation || Self.workOperation(domain: domain, tool: tool, args: arguments),
                      paths.allSatisfy({ path in fresh.reach.unrestricted || fresh.reach.folders.contains { BackendRemoteTrustStore.within($0, path) } }) else {
                    return .init(kind: .remote, tiers: [], deviceID: context.deviceID)
                }
                return .init(kind: .remote, tiers: level.tiers, deviceID: fresh.deviceID,
                    tasks: domain == "tasks" || domain == "goals", folders: fresh.reach.unrestricted ? nil : fresh.reach.folders,
                    projectRoot: paths.first)
            } catch { return .init(kind: .remote, tiers: [], deviceID: context.deviceID) }
        }
        let grant = BackendDeckCoreSecurityGrant(identity: "device:" + context.deviceID + ":connection:" + context.connectionID.uuidString,
            attended: true, tools: tools, cancellation: cancellation, caller: liveCaller)
        let slot = BackendINT2PhonePanelResult()
        defer { cancellation.cancel() }
        try await withTaskCancellationHandler {
            try await bindings.authenticated(grant: grant, cancellation: cancellation) {
                let caller = await grant.caller()
                let result = await control.call(name: tool, arguments: arguments,
                    options: .init(caller: caller, attended: true, granted: tools, cancellation: cancellation))
                await slot.set(result)
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        guard (await liveCaller()).tiers.contains(tier) else {
            throw NativeRPCError(code: "access-denied", message: "The device's access changed while this panel call was running.")
        }
        let result = try await slot.get()
        guard result.ok else { throw NativeRPCError(code: result.refusal?.rawValue ?? "panel-refused", message: result.error ?? "The existing tool refused this action.") }
        return result.value
    }
}

public extension BackendINT2PhonePanels {
    static func staysFixed(scope: BackendINT2PhonePanelScope) -> BackendRemotePanelProvider {
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> V = { request, rpc in
            let value = try await scope.call("fixed.status", arguments: object([("project", .string(request.path))]), rpc: rpc, domain: "staysfixed", projects: [request.path])
            let canWork = try await scope.level(rpc, domain: "staysfixed") != .look
            let rows = [object([("id", .string("status")), ("title", .string("Stays Fixed")),
                ("value", .string(value["setUp"].bool == true ? "Set up" : "Not set up")),
                ("detail", value["unavailable"].isNullish ? value["lastCheck"]["headline"] : value["unavailable"])])]
                + (value["guards"].elements ?? []).compactMap { guardRow -> V? in
                    guard let name = guardRow["name"].string else { return nil }; return object([("title", .string(name)), ("detail", guardRow["because"])])
                }
            var actions: [V] = []
            if canWork, value["setUp"].bool == true { actions.append(action("check", "Run check")) }
            if canWork, !value["running"].isNullish { actions.append(action("stop", "Stop check")) }
            return payload(request, rows: rows, actions: actions)
        }
        return .init(read: read, act: { request, rpc in
            try requireFields(request, allowed: [])
            guard ["check", "stop"].contains(request.action) else { throw NativeRPCError.invalidArguments("This Stays Fixed action is unavailable.") }
            let tool = request.action == "check" ? "fixed.check" : "fixed.stop"
            _ = try await scope.call(tool, arguments: object([("project", .string(request.panel.path))]), rpc: rpc, domain: "staysfixed", tier: .act, projects: [request.panel.path])
            return try await read(request.panel, rpc)
        })
    }

    static func simulators(scope: BackendINT2PhonePanelScope) -> BackendRemotePanelProvider {
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> V = { request, rpc in
            let value = try await scope.call("devices.list", arguments: .object([]), rpc: rpc, domain: "simulators")
            let canWork = try await scope.level(rpc, domain: "simulators") != .look
            let rows = (value["devices"].elements ?? []).compactMap { device -> V? in
                guard let id = device["id"].string, let name = device["name"].string else { return nil }
                let usable = device["usable"].bool == true || device["canStart"].bool == true
                return object([("id", .string(id)), ("title", .string(name)), ("detail", device["runtime"]),
                    ("value", device["state"]),
                    ("actions", .array(canWork && usable ? [action("open", device["usable"].bool == true ? "Open" : "Start and open")] : []))])
            }
            var result = payload(request, rows: rows)
            if let note = value["note"].string ?? value["empty"].string ?? value["reason"].string { result = result.setting("note", .string(note)) }; return result
        }
        return .init(scope: .machine, read: read, act: { request, rpc in
            try requireFields(request, allowed: [])
            guard request.action == "open", let id = request.id else { throw NativeRPCError.invalidArguments("Choose a currently offered device.") }
            _ = try await scope.call("devices.open", arguments: object([("deviceId", .string(id))]), rpc: rpc, domain: "simulators", tier: .act)
            return try await read(request.panel, rpc)
        })
    }

    private static func publicSetting(_ definition: SettingDefinition) -> Bool {
        let key = definition.id.lowercased()
        return !BackendDeckToolsAppApplication.isProtected(definition.id) &&
            !["secret", "password", "token", "apikey", "credential"].contains(where: key.contains)
    }
    static func settings(scope: BackendINT2PhonePanelScope) -> BackendRemotePanelProvider {
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> V = { request, rpc in
            let value = try await scope.call("settings.read", arguments: .object([]), rpc: rpc, domain: "settings")
            let settings = value["settings"]["values"].fields != nil ? value["settings"]["values"] : value["settings"]
            let values = SettingsSchema.values(settings: CodingAIJSON(settings.foundation), preferences: CodingAIJSON(value["preferences"].foundation))
            let full = try await scope.level(rpc, domain: "settings") == .full
            let rows = try SettingsSchema.all.filter(publicSetting).map { definition -> V in
                let scalar = try V.fromFoundation((values[definition.id] ?? definition.defaultValue).foundation)
                let text = scalar.string ?? scalar.compact
                var options = definition.options.map { object([("id", .string($0.value)), ("label", .string($0.label))]) }
                if definition.kind == .toggle { options = [object([("id", .string("true")), ("label", .string("On"))]), object([("id", .string("false")), ("label", .string("Off"))])] }
                let actions = full ? [action("edit", "Change", fields: [field("value", definition.label, value: text, required: definition.kind != .text, choices: options)])] : []
                return object([("id", .string(definition.id)), ("title", .string(definition.label)), ("detail", .string(definition.help)), ("value", .string(text)), ("actions", .array(actions))])
            }
            return payload(request, rows: rows)
        }
        return .init(scope: .machine, read: read, act: { request, rpc in
            try requireFields(request, allowed: ["value"])
            guard request.action == "edit", let id = request.id, let definition = SettingsSchema.setting(id), publicSetting(definition) else { throw NativeRPCError.invalidArguments("This setting is not offered for editing.") }
            let text = request.fields["value"] ?? "", scalar: V
            switch definition.kind {
            case .toggle: guard ["true", "false"].contains(text) else { throw NativeRPCError.invalidArguments("Choose On or Off.") }; scalar = .bool(text == "true")
            case .number: guard let number = Double(text), number.isFinite else { throw NativeRPCError.invalidArguments("Enter a valid number.") }; scalar = .number(number)
            case .text, .select: scalar = .string(text)
            }
            let key = definition.store == .prefs ? definition.prefsKey ?? definition.id : definition.id
            _ = try await scope.call("settings.write", arguments: object([("scope", .string(definition.store == .prefs ? "preferences" : "settings")), ("patch", .object([.init(key, scalar)]))]), rpc: rpc, domain: "settings", tier: .alter)
            return try await read(request.panel, rpc)
        })
    }

    static func hooks(scope: BackendINT2PhonePanelScope) -> BackendRemotePanelProvider {
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> V = { request, rpc in
            let value = try await scope.call("hooks.status", arguments: .object([]), rpc: rpc, domain: "hooks")
            let full = try await scope.level(rpc, domain: "hooks") == .full
            let rows = (value["agents"].elements ?? []).compactMap { hook -> V? in
                guard let id = hook["agent"].string ?? hook["provider"].string ?? hook["id"].string else { return nil }
                let actions = full ? [action("install", "Install hooks"), action("remove", "Remove hooks", confirm: "Remove Terminal Deck's hooks from " + id + "?")] : []
                return object([("id", .string(id)), ("title", .string(hook["label"].string ?? id)), ("value", hook["state"]), ("detail", hook["message"]), ("actions", .array(actions))])
            }
            return payload(request, rows: rows, actions: full ? [action("sync", "Update hook paths")] : [])
        }
        return .init(scope: .machine, read: read, act: { request, rpc in
            try requireFields(request, allowed: [])
            guard ["install", "remove", "sync"].contains(request.action) else { throw NativeRPCError.invalidArguments("This hook action is unavailable.") }
            let args: V
            if request.action == "sync" { args = .object([]) }
            else { guard let id = request.id else { throw NativeRPCError.invalidArguments("Choose an installed agent first.") }; args = object([("agent", .string(id))]) }
            _ = try await scope.call("hooks." + request.action, arguments: args, rpc: rpc, domain: "hooks", tier: .alter)
            return try await read(request.panel, rpc)
        })
    }

    /// The existing remote server tool permits scoped reads. Its separate
    /// management tools explicitly refuse remote callers, so offer no writes.
    static func servers(scope: BackendINT2PhonePanelScope) -> BackendRemotePanelProvider {
        .init(scope: .machine, read: { request, rpc in
            let value = try await scope.call("servers.look", arguments: .object([]), rpc: rpc, domain: "servers")
            let rows = (value["servers"].elements ?? []).compactMap { server -> V? in
                guard let id = server["id"].string, let name = server["name"].string else { return nil }
                return object([("id", .string(id)), ("title", .string(name)), ("detail", server["host"]), ("value", server["status"])])
            }
            return payload(request, rows: rows)
        })
    }
}

public enum BackendINT2PhonePanels {
    private typealias V = NativeRPCValue
    private static func object(_ fields: [(String, V)]) -> V { .object(fields.map { .init($0.0, $0.1) }) }
    private static func field(_ id: String, _ label: String, value: String = "", required: Bool = false, choices: [V] = []) -> V {
        var row = object([("id", .string(id)), ("label", .string(label)), ("value", .string(value)), ("required", .bool(required))])
        let wireChoices = choices.compactMap { choice -> V? in
            (choice.string ?? choice["id"].string).map(V.string)
        }
        if !wireChoices.isEmpty { row = row.setting("choices", .array(wireChoices)) }; return row
    }
    private static func action(_ id: String, _ label: String, fields: [V] = [], confirm: String? = nil) -> V {
        var row = object([("id", .string(id)), ("label", .string(label)), ("fields", .array(fields))])
        if let confirm { row = row.setting("destructive", .bool(true)).setting("confirm", .string(confirm)) }; return row
    }
    private static func choices(_ projects: [V]) -> [V] {
        projects.compactMap { row in
            guard let path = row["path"].string else { return nil }
            return object([("id", .string(path)), ("label", .string(row["title"].string ?? row["name"].string ?? URL(fileURLWithPath: path).lastPathComponent))])
        }
    }
    private static func payload(_ request: BackendRemotePanelRequest, rows: [V], actions: [V] = []) -> V {
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let visible = query.isEmpty ? rows : rows.filter { ($0["title"].string ?? "").localizedCaseInsensitiveContains(query) || ($0["detail"].string ?? "").localizedCaseInsensitiveContains(query) }
        return object([("path", .string(request.path)), ("rows", .array(Array(visible.prefix(200)))), ("actions", .array(actions))])
    }
    private static func requireFields(_ request: BackendRemotePanelActionRequest, allowed: Set<String>) throws {
        guard Set(request.fields.keys).isSubset(of: allowed) else { throw NativeRPCError.invalidArguments("This action received a field it does not offer.") }
    }
    private static func selectedProject(_ request: BackendRemotePanelActionRequest, projects: [V]) throws -> String {
        let target = request.fields["project"] ?? request.panel.path
        guard projects.contains(where: { $0["path"].string == target }) else {
            throw NativeRPCError(code: "access-denied", message: "Choose one of this device's currently authorized open projects.")
        }
        return target
    }

    public static func tasks(scope: BackendINT2PhonePanelScope) -> BackendRemotePanelProvider {
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> V = { request, rpc in
            let value = try await scope.call("tasks.local", arguments: object([("do", .string("list")), ("project", .string(request.path)), ("limit", .number(200))]), rpc: rpc, domain: "tasks", projects: [request.path])
            let tasks = (value["tasks"].elements ?? []).filter { $0["project"].string == request.path }
            let projects = try await scope.projects(rpc, domain: "tasks"), projectChoices = choices(projects)
            let level = try await scope.level(rpc, domain: "tasks"), canWork = level != .look
            let agents = (value["agents"].elements ?? []).filter { !["archived", "paused"].contains($0["status"].string ?? "") }.compactMap { agent -> V? in
                guard let id = agent["id"].string, let name = agent["name"].string else { return nil }; return object([("id", .string(id)), ("label", .string(name))])
            }
            let links = try await scope.sessionLinks(tasks, rpc)
            let rows = tasks.compactMap { task -> V? in
                guard let id = task["task"].string, let title = task["title"].string else { return nil }
                var actions: [V] = []
                if canWork {
                    actions.append(action("edit", "Edit title", fields: [field("title", "Title", value: title, required: true)]))
                    if projectChoices.count > 1 { actions.append(action("move", "Move to project", fields: [field("project", "Project", value: request.path, required: true, choices: projectChoices)])) }
                    if task["status"].string != "done", (value["statuses"].elements ?? []).contains(.string("done")) { actions.append(action("done", "Done")) }
                    if !agents.isEmpty, task["agentWorking"].bool != true { actions.append(action("run", "Run with an agent", fields: [field("agent", "Agent", required: true, choices: agents)])) }
                }
                var row = object([("id", .string(id)), ("title", .string(title)), ("detail", task["assigneeName"]), ("value", task["status"]), ("actions", .array(actions))])
                if let session = links[id] { row = row.setting("sessionId", .string(session)) }; return row
            }
            var fields = [field("title", "Title", required: true), field("details", "Details")]
            if projectChoices.count > 1 { fields.append(field("project", "Project", value: request.path, required: true, choices: projectChoices)) }
            return payload(request, rows: rows, actions: canWork ? [action("add", "Add task", fields: fields)] : [])
        }
        return .init(read: read, act: { request, rpc in
            let projects = try await scope.projects(rpc, domain: "tasks")
            let target = try selectedProject(request, projects: projects)
            var args = object([("project", .string(target))])
            let tier: BackendMCPTier
            switch request.action {
            case "add":
                try requireFields(request, allowed: ["title", "details", "project"])
                args = args.setting("do", .string("create")).setting("title", .string(request.fields["title"] ?? "")).setting("details", .string(request.fields["details"] ?? ""))
                tier = .alter
            case "edit", "move", "done", "run":
                guard let id = request.id else { throw NativeRPCError.invalidArguments("Choose a current task first.") }
                let before = try await scope.call("tasks.local", arguments: object([("do", .string("list")), ("project", .string(request.panel.path)), ("limit", .number(200))]), rpc: rpc, domain: "tasks", projects: [request.panel.path])
                guard (before["tasks"].elements ?? []).contains(where: { $0["task"].string == id && $0["project"].string == request.panel.path }) else { throw NativeRPCError(code: "access-denied", message: "This task is no longer in the authorized project.") }
                args = args.setting("task", .string(id))
                if request.action == "done" { try requireFields(request, allowed: []); args = args.setting("do", .string("status")).setting("status", .string("done")); tier = .act }
                else if request.action == "edit" { try requireFields(request, allowed: ["title"]); args = args.setting("do", .string("update")).setting("title", .string(request.fields["title"] ?? "")); tier = .alter }
                else if request.action == "move" { try requireFields(request, allowed: ["project"]); args = args.setting("do", .string("update")); tier = .alter }
                else {
                    try requireFields(request, allowed: ["agent"])
                    let agent = request.fields["agent"] ?? ""
                    guard (before["agents"].elements ?? []).contains(where: { $0["id"].string == agent && !["archived", "paused"].contains($0["status"].string ?? "") }) else { throw NativeRPCError.invalidArguments("Choose a currently available task agent.") }
                    args = args.setting("do", .string("assign")).setting("assignee", .string(agent)); tier = .alter
                }
            default: throw NativeRPCError.invalidArguments("This task action is unavailable.")
            }
            _ = try await scope.call("tasks.local_change", arguments: args, rpc: rpc, domain: "tasks", tier: tier, projects: [request.panel.path, target])
            return try await read(request.panel, rpc).setting("notice", .string("Task updated."))
        })
    }

    public static func goals(scope: BackendINT2PhonePanelScope) -> BackendRemotePanelProvider {
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> V = { request, rpc in
            let value = try await scope.call("tasks.goals", arguments: object([("do", .string("list")), ("project", .string(request.path))]), rpc: rpc, domain: "goals", projects: [request.path])
            let goals = (value["goals"].elements ?? []).filter { $0["project"].string == request.path }
            let canWork = try await scope.level(rpc, domain: "goals") != .look
            let rows = goals.compactMap { goal -> V? in
                guard let id = goal["id"].string, let title = goal["title"].string else { return nil }
                let actions = canWork ? [action("edit", "Edit goal", fields: [field("title", "Title", value: title, required: true), field("description", "Description", value: goal["description"].string ?? "")]), action("achieved", "Mark achieved"), action("remove", "Remove goal", confirm: "Remove “" + title + "”? Its tasks and child goals move to its parent.")] : []
                let progress = goal["progress"], detail = "\(Int(progress["done"].number ?? 0)) of \(Int(progress["total"].number ?? 0)) tasks done"
                return object([("id", .string(id)), ("title", .string(title)), ("detail", .string(detail)), ("value", goal["status"]), ("actions", .array(actions))])
            }
            return payload(request, rows: rows, actions: canWork ? [action("add", "Add goal", fields: [field("title", "Title", required: true), field("description", "Description")])] : [])
        }
        return .init(read: read, act: { request, rpc in
            var args = object([("project", .string(request.panel.path))]); let tier: BackendMCPTier
            if request.action == "add" {
                try requireFields(request, allowed: ["title", "description"])
                args = args.setting("do", .string("create")).setting("title", .string(request.fields["title"] ?? "")).setting("description", .string(request.fields["description"] ?? "")); tier = .act
            } else {
                guard let id = request.id else { throw NativeRPCError.invalidArguments("Choose a current goal first.") }
                let before = try await scope.call("tasks.goals", arguments: object([("do", .string("list")), ("project", .string(request.panel.path))]), rpc: rpc, domain: "goals", projects: [request.panel.path])
                guard (before["goals"].elements ?? []).contains(where: { $0["id"].string == id && $0["project"].string == request.panel.path }) else { throw NativeRPCError(code: "access-denied", message: "This goal is no longer in the authorized project.") }
                args = args.setting("goal", .string(id))
                switch request.action {
                case "edit": try requireFields(request, allowed: ["title", "description"]); args = args.setting("do", .string("update")).setting("title", .string(request.fields["title"] ?? "")).setting("description", .string(request.fields["description"] ?? "")); tier = .act
                case "achieved": try requireFields(request, allowed: []); args = args.setting("do", .string("update")).setting("status", .string("achieved")); tier = .act
                case "remove": try requireFields(request, allowed: []); args = args.setting("do", .string("remove")); tier = .alter
                default: throw NativeRPCError.invalidArguments("This goal action is unavailable.")
                }
            }
            _ = try await scope.call("tasks.goals", arguments: args, rpc: rpc, domain: "goals", tier: tier, projects: [request.panel.path])
            return try await read(request.panel, rpc).setting("notice", .string("Goal updated."))
        })
    }
}
