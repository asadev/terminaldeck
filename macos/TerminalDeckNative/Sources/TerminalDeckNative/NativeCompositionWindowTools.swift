import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

// HOOT-TOOL-AUDIT (L5, 11 Oct): window actions that only the native screens could do until now,
// as tools for Hoot and connected AI apps. Each one runs the very call its button runs
// (the side panel's Pin and Delete, the agent list's Open profile and Role, the Tasks page's
// Open task), behind the same consent gate as every other app change.

extension NativeCompositionProduction {
    /// Never fatal: a problem here leaves every other tool working.
    func installWindowTools() async {
        do { try await installWindowToolsThrowing() }
        catch { NSLog("[native graph] window tools were not installed: %@", error.localizedDescription) }
        do { try await installButtonTools() }
        catch { NSLog("[native graph] native button tools were not installed: %@", error.localizedDescription) }
        do { try await installAccessToolsThrowing() }
        catch { NSLog("[native graph] access tools were not installed: %@", error.localizedDescription) }
    }

    private func installWindowToolsThrowing() async throws {
        let owner = "native-composition:window-tools", mcp = root.mcp
        guard let authority else { return }
        let joins = self.joins, fileAuthority = files?.authority
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        let flag = NativeRPCValue.object([.init("type", .string("boolean"))])
        func schema(_ properties: [(String, NativeRPCValue)], required: [String]) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let definitions: [(String, BackendMCPTier, String, NativeRPCValue)] = [
            ("windows.move_page", .act, "Move a main page into its own window, or show its existing window. page: tasks, agents-all, hoot, memory, servers, devices, or settings:<section> (omit for the current page).",
             schema([("page", text)], required: [])),
            ("sessions.pin", .act, "Pin a session to the top of the side panel (pinned true) or unpin it, as the session menu's Pin does.",
             schema([("session", text), ("pinned", flag)], required: ["session", "pinned"])),
            ("sessions.delete", .alter, "Delete a session from the app, as the session menu's Delete does (it stops it and removes its row). The app's own close confirmation still applies.",
             schema([("session", text)], required: ["session"])),
            // Opening a page changes what is on the person's screen, so it is not look-only.
            ("agents.open_profile", .act, "Open an agent's profile page on the person's screen (agent id or name).",
             schema([("agent", text)], required: ["agent"])),
            ("agents.set_role", .alter, "Put a saved agent into a role seat of its project (role: a short role name like ios-engineer), or back into the seat named after it (role null). Memory stays with the seat it leaves.",
             schema([("agent", text), ("role", .object([.init("type", .array([.string("string"), .string("null")]))])), ("title", text)], required: ["agent", "role"])),
            ("tasks.open", .act, "Open one of the person's tasks in its popup on their screen.",
             schema([("task", text)], required: ["task"])),
            // Round 2 (HOOT-TOOL-AUDIT ranked list).
            ("mcp.switch", .alter, "Turn an MCP server on or off (what: server), one of its tools (what: tool, name), its use by a coding AI (what: ai, name claude/codex/gemini) or by an agent (what: agent, name = agent id), as the server's window does.",
             schema([("server", text), ("projectPath", text), ("what", text.setting("enum", .array(["server", "tool", "ai", "agent"].map(NativeRPCValue.string)))), ("name", text), ("enabled", flag)], required: ["server", "what", "enabled"])),
            ("artifacts.send", .act, "Send an artifact (a file a session made) to Hoot or to a session (target: hoot or a session id), as its Send to… menu does. cwd and relPath come from artifacts_list.",
             schema([("cwd", text), ("relPath", text), ("projectId", text), ("target", text)], required: ["cwd", "relPath", "target"])),
            ("artifacts.remove", .alter, "Take an artifact off the Artifacts list (the file itself stays), as Delete from list does.",
             schema([("cwd", text), ("relPath", text), ("projectId", text)], required: ["cwd", "relPath"])),
            ("receiver.assist", .act, "Receiver extras: suggest a rule from an event (eventId), learn a source's field map from its latest or a named event (sourceId, eventId), or save a source as a preset (sourceId, name).",
             schema([("action", text.setting("enum", .array(["suggest", "learn", "preset_save"].map(NativeRPCValue.string)))), ("eventId", text), ("sourceId", text), ("name", text)], required: ["action"])),
            ("devices.cold_start", .act, "Cold-start a simulator or emulator (start it fresh, without its saved state), as the device menu's Cold start does.",
             schema([("device", text)], required: ["device"])),
            ("tabs.close", .alter, "Close a tab in the main window, as its close button does (a session tab asks the app's own close question).",
             schema([("tab", text)], required: ["tab"])),
            ("tabs.order", .act, "Put the main window's tabs in this order (tab ids; the ones left out keep their place after them).",
             schema([("order", .object([.init("type", .string("array")), .init("items", text)]))], required: ["order"])),
            ("hoot.fast_mode", .alter, "Switch Claude Code's Fast mode for Hoot on or off, as Hoot's Brain tab does (only when the account offers it).",
             schema([("on", flag)], required: ["on"])),
            ("connected_tasks.settings", .alter, "A connected task system's settings: update (enabled, changes, markDone) or remove it, as Settings › Tasks does. Tokens are changed by the person only.",
             schema([("system", text), ("action", text.setting("enum", .array(["update", "remove"].map(NativeRPCValue.string)))), ("enabled", flag), ("changes", text), ("markDone", flag)], required: ["system", "action"])),
            ("projects.logo", .alter, "Set a project's logo from an image file on this Mac (path), or remove it (path null), as Project settings › Logo does.",
             schema([("project", text), ("path", .object([.init("type", .array([.string("string"), .string("null")]))]))], required: ["project", "path"])),
        ]
        /// The button's own engine call; a refusal comes back as its own sentence.
        @Sendable func engine(_ channel: String, _ arguments: [Any]) async throws -> NativeRPCValue {
            // Plain values cross to the main actor (where the bridge lives) and come back as plain values.
            let wire = try arguments.map { try NativeRPCValue.fromFoundation($0) }
            let value = try await NativeWindowToolsBridge.invoke(channel, wire)
            if value["ok"].bool == false { throw NativeRPCError(code: "refused", message: value["sentence"].string ?? value["message"].string ?? "That did not work.") }
            return value
        }
        // One thing, one name: a tool another owner already registered is left to that owner and
        // logged, never registered twice (a duplicate name stopped the app from starting on 11 Oct).
        let taken = Set(await mcp.registrations().map(\.0.id))
        for (id, tier, description, input) in definitions {
            if taken.contains(id) { NSLog("[native graph] window tool %@ is already registered by another owner; skipped", id); continue }
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: input, tier: tier)
            try await mcp.registerTool(spec, ownerID: owner) { caller, args in
                guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot do that.") }
                _ = try await authority.resolve(caller)
                switch id {
                case "windows.move_page":
                    let page = args["page"].string
                    let ref = await MainActor.run { () -> ScreenRef? in
                        if let page {
                            let ref = NativePageWindows.page(kind: "panel", id: page)
                            let known = page == "agents" || page == "hoot" || NativeScreens.registered.contains(page) || SHELLRoutes.owns(page)
                                || (page.hasPrefix("settings:") && NativeSettingsNavigation.items.contains { "settings:" + $0.id == page })
                                || AppModel.shared.sidebar?.item(id: page) != nil
                            return known ? ref : nil
                        }
                        return AppModel.shared.currentScreen.flatMap { NativePageWindows.page(kind: $0.kind, id: $0.id) }
                    }
                    guard let ref else { throw NativeRPCError.invalidArguments("Choose a page to move to its own window.") }
                    guard UIGMemoryVisibility.showsScreen(ref) else { throw NativeRPCError(code: "unavailable", message: "Memory is not available right now.") }
                    try await joins.prepareNative(caller, tier: tier, sentence: "Move \(ref.id) to its own window", ownerMustAnswer: false)
                    await MainActor.run { AppModel.shared.movePageToWindow(ref, bringForward: false) }
                    return .value(.object([.init("page", .string(ref.id)), .init("requested", .bool(true))]))
                case "sessions.pin":
                    let session = try args["session"].requireString("session", nonempty: true), pinned = args["pinned"].bool ?? true
                    try await joins.prepareNative(caller, tier: tier, sentence: (pinned ? "Pin" : "Unpin") + " a session in the side panel", ownerMustAnswer: false)
                    return .value(await MainActor.run {
                        let pins = SIDEBARPins.shared
                        if pins.isPinned(session) != pinned { pins.toggle(session) }
                        return .object([.init("session", .string(session)), .init("pinned", .bool(pins.isPinned(session)))])
                    })
                case "sessions.delete":
                    let session = try args["session"].requireString("session", nonempty: true)
                    try await joins.prepareNative(caller, tier: tier, sentence: "Delete the session \(session)", ownerMustAnswer: false)
                    let task = await MainActor.run { AppModel.shared.runButton(.closeSession(session)) }
                    guard await task.value else { throw NativeRPCError(code: "refused", message: await MainActor.run { AppModel.shared.buttonActions.problem ?? "That close was cancelled." }) }
                    return .value(.object([.init("session", .string(session)), .init("deleted", .bool(true))]))
                case "agents.open_profile", "agents.set_role":
                    let wanted = try args["agent"].requireString("agent", nonempty: true)
                    let agent = await MainActor.run { AGTAgentsStore.shared.agents.first { $0.id == wanted || $0.profileID == wanted || $0.name.caseInsensitiveCompare(wanted) == .orderedSame } }
                    guard let agent else { throw NativeRPCError.invalidArguments("There is no agent called \(wanted).") }
                    if id == "agents.open_profile" {
                        try await joins.prepareNative(caller, tier: tier, sentence: "Open the profile of \(agent.name)", ownerMustAnswer: false)
                        await MainActor.run { AppModel.shared.select("agents"); AGTAgentsStore.shared.openProfile = agent.id }
                        return .value(.object([.init("opened", .string(agent.name))]))
                    }
                    let role = args["role"].string.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
                    try await joins.prepareNative(caller, tier: tier, sentence: "Put \(agent.name) into the role " + (role ?? "named after it"), ownerMustAnswer: false)
                    let done = await AGTLeads.setRole(role, title: args["title"].string, for: agent)
                    guard done else { throw NativeRPCError(code: "refused", message: await MainActor.run { AGTAgentsStore.shared.message } ?? "The role could not be set.") }
                    return .value(.object([.init("agent", .string(agent.name)), .init("role", role.map(NativeRPCValue.string) ?? .null)]))
                case "mcp.switch":
                    let server = try args["server"].requireString("server", nonempty: true), what = args["what"].string ?? "server", on = args["enabled"].bool ?? true
                    var request: [String: Any] = ["serverId": server, "projectPath": args["projectPath"].string as Any? ?? NSNull(), "enabled": on]
                    try await joins.prepareNative(caller, tier: tier, sentence: "Turn " + (on ? "on" : "off") + " \(what == "server" ? "the MCP server" : what + " " + (args["name"].string ?? "")) of \(server)", ownerMustAnswer: false)
                    if what == "server" { return .value(try await engine("mcp:enabled", [request])) }
                    let name = try args["name"].requireString("name", nonempty: true)
                    let policy = try await engine("mcp:policy", [["serverId": server, "projectPath": request["projectPath"] as Any]])
                    if let revision = policy["revision"].foundation as Any? { request["revision"] = revision }
                    request[what == "tool" ? "tool" : what == "ai" ? "client" : "agentId"] = name
                    return .value(try await engine(what == "tool" ? "mcp:tools:set" : "mcp:access:set", [request]))
                case "artifacts.send", "artifacts.remove":
                    var request: [String: Any] = ["cwd": try args["cwd"].requireString("cwd", nonempty: true), "relPath": try args["relPath"].requireString("relPath", nonempty: true),
                                                  "projectId": args["projectId"].string as Any? ?? NSNull()]
                    if id == "artifacts.send" { request["target"] = try args["target"].requireString("target", nonempty: true) }
                    try await joins.prepareNative(caller, tier: tier, sentence: (id == "artifacts.send" ? "Send the artifact \(request["relPath"]!) to \(request["target"]!)" : "Take the artifact \(request["relPath"]!) off the list"), ownerMustAnswer: false)
                    return .value(try await engine(id == "artifacts.send" ? "artifacts:send" : "artifacts:hide", [request]))
                case "receiver.assist":
                    let action = args["action"].string ?? ""
                    var request: [String: Any] = [:]
                    switch action {
                    case "suggest": request["id"] = try args["eventId"].requireString("eventId", nonempty: true)
                    case "learn": request["sourceId"] = try args["sourceId"].requireString("sourceId", nonempty: true); if let event = args["eventId"].string { request["eventId"] = event }
                    default: request["sourceId"] = try args["sourceId"].requireString("sourceId", nonempty: true); request["name"] = try args["name"].requireString("name", nonempty: true)
                    }
                    try await joins.prepareNative(caller, tier: tier, sentence: action == "suggest" ? "Suggest a Receiver rule" : action == "learn" ? "Learn a Receiver source's fields" : "Save a Receiver source as a preset", ownerMustAnswer: false)
                    return .value(try await engine(action == "suggest" ? "receiver:suggest" : action == "learn" ? "receiver:learn" : "receiver:presetSave", [request]))
                case "devices.cold_start":
                    let device = try args["device"].requireString("device", nonempty: true)
                    try await joins.prepareNative(caller, tier: tier, sentence: "Cold-start the device \(device)", ownerMustAnswer: false)
                    return .value(try await engine("devices:cold-start", [device]))
                case "tabs.close":
                    let tab = try args["tab"].requireString("tab", nonempty: true)
                    try await joins.prepareNative(caller, tier: tier, sentence: "Close the tab \(tab)", ownerMustAnswer: false)
                    let task = await MainActor.run { AppModel.shared.closeTabForTool(tab) }
                    let outcome = await task.value
                    guard outcome.succeeded else { throw NativeRPCError(code: "refused", message: outcome.message) }
                    return .value(.object([.init("closed", .string(tab))]))
                case "tabs.order":
                    let order = (args["order"].elements ?? []).compactMap(\.string)
                    guard !order.isEmpty else { throw NativeRPCError.invalidArguments("order needs tab ids") }
                    try await joins.prepareNative(caller, tier: tier, sentence: "Reorder the window's tabs", ownerMustAnswer: false)
                    await MainActor.run { NativePaneArrangement.shared.setTabOrder(order) }
                    return .value(.object([.init("order", .array(order.map(NativeRPCValue.string)))]))
                case "hoot.fast_mode":
                    let on = args["on"].bool ?? true
                    let offered = await MainActor.run { ROUTINESHootBrainModel.shared.fastMode != nil }
                    guard offered else { throw NativeRPCError(code: "unavailable", message: "Fast mode is not offered for Hoot's current account and model.") }
                    try await joins.prepareNative(caller, tier: tier, sentence: "Turn Hoot's Fast mode " + (on ? "on" : "off"), ownerMustAnswer: false)
                    await MainActor.run { ROUTINESHootBrainModel.shared.selectFastMode(on) }
                    return .value(.object([.init("fastMode", .bool(on))]))
                case "connected_tasks.settings":
                    let system = try args["system"].requireString("system", nonempty: true)
                    if args["action"].string == "remove" {
                        try await joins.prepareNative(caller, tier: tier, sentence: "Remove the connected task system \(system)", ownerMustAnswer: false)
                        return .value(try await engine("connected-tasks:remove", [system]))
                    }
                    var patch: [String: Any] = [:]
                    if let on = args["enabled"].bool { patch["enabled"] = on }
                    if let changes = args["changes"].string { patch["changes"] = changes }
                    if let done = args["markDone"].bool { patch["markDone"] = done }
                    guard !patch.isEmpty else { throw NativeRPCError.invalidArguments("pass enabled, changes or markDone") }
                    try await joins.prepareNative(caller, tier: tier, sentence: "Change the connected task system \(system)", ownerMustAnswer: false)
                    return .value(try await engine("connected-tasks:update", [system, patch]))
                case "projects.logo":
                    let wanted = try args["project"].requireString("project", nonempty: true), path = args["path"].string
                    guard var project = await MainActor.run(body: { SIDEBARProjectStore.shared.projects.first { $0.id == wanted || $0.name.caseInsensitiveCompare(wanted) == .orderedSame } })
                    else { throw NativeRPCError.invalidArguments("There is no project called \(wanted).") }
                    // U11 (#622): the picture is read only from inside this caller's own file grants.
                    let picture: String?
                    if let path {
                        picture = try await NativeGrantedFiles.paths([(path as NSString).expandingTildeInPath], authority: fileAuthority, context: authority.rpc(caller)).first
                    } else { picture = nil }
                    try await joins.prepareNative(caller, tier: tier, sentence: path == nil ? "Remove the logo of \(project.name)" : "Set the logo of \(project.name)", ownerMustAnswer: false)
                    let old = project.logo
                    project.logo = try await MainActor.run { try picture.map { try ProjectLogos.adopt(URL(fileURLWithPath: $0), projectID: project.id) } ?? "" }
                    _ = try await NativeWindowToolsBridge.invoke("project-registry:save", [project.wireValue])
                    if !old.isEmpty, old != project.logo { await MainActor.run { ProjectLogos.discard(old) } }
                    return .value(.object([.init("project", .string(project.name)), .init("logo", .string(project.logo))]))
                default:
                    let task = try args["task"].requireString("task", nonempty: true)
                    try await joins.prepareNative(caller, tier: tier, sentence: "Open the task \(task)", ownerMustAnswer: false)
                    await MainActor.run { AppModel.shared.select("tasks"); TasksStore.shared.openTask(task) }
                    return .value(.object([.init("opened", .string(task))]))
                }
            }
        }
        let ids = Set(definitions.map(\.0))
        let registered = await mcp.registrations().filter { ids.contains($0.0.id) }
        let metadata = registered.map { BackendDeckCoreCatalogueMetadata(tool: $0.0, title: $0.0.description, index: $0.0.description) }
        let policies = zip(metadata, registered).map { joins.mcpPolicy($0.0, handler: $0.1.1) }
        try joins.replaceContributions(owner: owner, [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
    }
}

@MainActor
enum NativeWindowToolsBridge {
    static func invoke(_ channel: String, _ arguments: [NativeRPCValue]) async throws -> NativeRPCValue {
        try NativeRPCValue.fromFoundation(try await EngineBridge.shared.invoke(channel, arguments.map(\.foundation)))
    }
}
