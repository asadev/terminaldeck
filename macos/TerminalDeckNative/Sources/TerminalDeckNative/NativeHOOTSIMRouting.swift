import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// Item 90: Hoot's routing cards. Called at the end of installINT2HootChatTools.
    /// Actual project/agent/task readers are resolved through the one core door,
    /// so this installer does not need another registry or task store.
    /// Proposing only writes a card into Hoot's chat; nothing is created, assigned
    /// or sent until the person answers the card (or approves Hoot's dispatch).
    func installHOOTSIMRouting(access: BackendDeckToolsAppAccess) async throws {
        guard let hoot, let core, let authority else { throw NativeRPCError(code: "unavailable", message: "Hoot's owners are not ready.") }
        let owner = "native.hoot-routing", root = self.root, joins = self.joins, runtime = hoot.runtime, hootPolicy = hoot.policy
        let require: @Sendable (BackendMCPCallContext) async throws -> Void = { native in
            let context = try await authority.resolve(native)
            guard context.caller.kind == .local, !context.cancellation.isCancelled else {
                throw NativeRPCError(code: "not-granted", message: "Only Hoot and this Mac's person can use these routing cards.")
            }
        }
        let run: @Sendable (BackendMCPCallContext, String, NativeRPCValue) async throws -> NativeRPCValue = { native, name, arguments in
            // A fresh real core call per operation, not a nested handler under
            // the route approval. No preApproved/approved flag is manufactured.
            let current = try await authority.resolve(native)
            guard current.caller.kind == .local, !current.cancellation.isCancelled else { throw CancellationError() }
            let answer = await core.control.call(name: name, arguments: arguments,
                options: .init(caller: current.caller, attended: current.attended, granted: current.granted,
                    cancellation: native.cancellation, sessionLimits: current.sessionLimits))
            guard answer.ok else { throw NativeRPCError(code: "routing-action-failed", message: answer.error ?? "The requested routing action failed.") }
            return answer.value
        }
        let ownerCall: @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue = { name, arguments in
            let context = try authority.localContext()
            guard let endpoint = await core.server.currentEndpoint(),
                  let grant = await endpoint.callers.match(authorization: "Bearer " + endpoint.token), grant.attended else {
                throw NativeRPCError(code: "unavailable", message: "The current owner approval path is unavailable.")
            }
            let actualCaller = await grant.caller()
            guard actualCaller.kind == .local else { throw NativeRPCError(code: "not-granted", message: "This is not the current app owner.") }
            try authority.requireLocalUI(context)
            let cancellation = BackendMCPCancellation()
            guard let result = await BackendDeckCoreSecurityServer.authenticatedCall(grant: grant, scope: cancellation,
                wrapper: { grant, scope, operation in try await joins.authenticated(grant: grant, cancellation: scope, operation: operation) },
                call: { await core.control.call(name: name, arguments: arguments,
                    options: .init(caller: actualCaller, attended: grant.attended, granted: grant.tools, cancellation: cancellation)) }) else {
                throw NativeRPCError(code: "not-granted", message: "The owner request no longer has current approval authority.")
            }
            guard result.ok else { throw NativeRPCError(code: "routing-failed", message: result.error ?? "Hoot could not update this routing card.") }
            return result.value
        }
        let routing = BackendHOOTSIMRouting(.init(require: require, conversationID: {
                guard let chat = runtime.structuredChat else { throw NativeRPCError(code: "unavailable", message: "Hoot's saved chat is unavailable.") }
                return chat.conversationID
            }, load: {
                guard let chat = runtime.structuredChat else { throw NativeRPCError(code: "unavailable", message: "Hoot's saved chat is unavailable.") }
                return await chat.routingRecords()
            }, append: { row in
                guard let chat = runtime.structuredChat else { throw NativeRPCError(code: "unavailable", message: "Hoot's saved chat is unavailable.") }
                try await chat.recordRouting(row)
            }, resolve: { native, request in
                if let folder = request["source"]["folder"].string, !folder.isEmpty { _ = try await access.knownFolder(native, folder) }
                let openProjects = try await run(native, "projects.list", .object([]))
                let openFolders = (openProjects["projects"].elements ?? []).compactMap { $0["path"].string }
                let projectValue = try await run(native, "project_registry.list", .object([]))
                let projects = try JSONDecoder().decode([PROJProject].self, from: projectValue["projects"].encodedJSON())
                let agents = try await run(native, "tasks.agents", .object([.init("do", .string("list"))]))
                let sessions = try await run(native, "sessions.list", .object([]))
                let tasks = try await run(native, "tasks.list", .object([.init("all_projects", .bool(true))]))
                return try BackendHOOTSIMRoutingResolver.resolve(request, projects: projects, openFolders: openFolders,
                    agents: agents["agents"].elements ?? [], sessions: sessions["sessions"].elements ?? [], tasks: tasks["tasks"].elements ?? [])
            }, authorize: { native, proposal in
                try await require(native)
                let target = proposal["target"]["name"].string ?? "the chosen target"
                let text = proposal["request"]["problem"].string ?? "this problem"
                let sentence = "Send “" + text + "” to " + target + ". " + (proposal["reason"].string ?? "")
                try await access.authorize(native, "hoot.route.dispatch", proposal, .alter, sentence, true)
            }, dispatch: { native, proposal in
                // The card's answer is the approval: the send goes through the core tools under this call.
                let created: @Sendable (NativeRPCValue) throws -> String = { try $0["created"]["id"].requireString("created task id", nonempty: true) }
                return try await NativeHOOTSIMRoutingSend.send(proposal, approval: .card, doors: .init(
                    tasks: { try await run(native, "tasks.list", .object([.init("all_projects", .bool(true))]))["tasks"].elements ?? [] },
                    create: { title, details, folder, assignee, _ in
                        try created(await run(native, "tasks.local_change", .object([.init("do", .string("create")),
                            .init("title", .string(title)), .init("details", .string(details)), .init("project", .string(folder)), .init("assignee", assignee)])))
                    },
                    assign: { task, assignee in
                        _ = try await run(native, "tasks.local_change", .object([.init("do", .string("assign")), .init("task", .string(task)), .init("assignee", assignee)]))
                    },
                    comment: { task, text in
                        _ = try await run(native, "tasks.local_change", .object([.init("do", .string("comment")), .init("task", .string(task)), .init("text", .string(text))]))
                    },
                    type: { session, line in
                        try await run(native, "sessions.send", .object([.init("sessionId", .string(session)), .init("text", .string(line)), .init("submit", .bool(true))]))["sentAt"]
                    }))
            }, policy: { await hootPolicy.snapshot() },
            autoDispatch: { proposal in
                try await NativeHOOTSIMRoutingSend.send(proposal, approval: .standing,
                    doors: .owner(registry: root.registry, context: try authority.localContext()))
            }))
        let definitions = try BackendHOOTSIMRoutingMCP.definitions(routing: routing, access: access)
        let policies = definitions.map(joins.nativePolicy)
        let area = try BackendDeckToolsSupport.area(id: "hoot-routing", definitions: definitions)
        let bundle = try BackendDeckCoreAreaIntegration.bundle(area: area, metadata: definitions.map(\.catalogueMetadata), policies: policies)
        let channels: Set<String> = ["hoot:route:answer", "hoot:route:read", "hoot:route:propose", "hoot:route:dispatch", "hoot:route:dismiss", "hoot:route:retarget"]
        var taskUpdates: NativeRPCSubscription?
        do {
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            for channel in channels {
                try await root.registry.register(channel, ownerID: owner, policy: { try authority.requireLocalUI($0) }) { context, args in
                    // Only the actual window owner enters here. Inputs never carry
                    // an approval Bool or a manufactured MCP/session identity.
                    try authority.requireLocalUI(context)
                    let name: String, arguments: NativeRPCValue
                    if channel == "hoot:route:answer" {
                        let action = try context.argument(2, in: args).requireString("answer")
                        guard ["approve", "dismiss", "other"].contains(action) else { throw NativeRPCError.invalidArguments("Choose approve, dismiss or other.") }
                        name = "hoot.route." + (action == "approve" ? "dispatch" : action == "dismiss" ? "dismiss" : "retarget")
                        var input = NativeRPCValue.object([.init("id", context.argument(0, in: args)), .init("revision", context.argument(1, in: args))])
                        if action == "other" { input = input.setting("target", context.argument(3, in: args)) }
                        arguments = input
                    } else {
                        name = channel.replacingOccurrences(of: ":", with: ".")
                        arguments = context.argument(0, in: args).isNullish ? .object([]) : context.argument(0, in: args)
                    }
                    return try await ownerCall(name, arguments)
                }
            }
            let updates = try await root.registry.subscribe("tasks:changed", ownerID: BackendCompositionRoot.appOwnerID) { _ in
                // Only cards already sent to a task are followed up, so a busy
                // task list costs nothing while no card is waiting on a result.
                guard let chat = runtime.structuredChat else { return }
                let records = await chat.routingRecords()
                guard records.contains(where: { $0["state"].string == "sent" && !($0["result"]["taskId"].string ?? "").isEmpty }) else { return }
                _ = try await ownerCall("hoot.route.read", .object([])) // Restore this chat's bounded routing projection.
                let current = try await ownerCall("tasks.list", .object([.init("all_projects", .bool(true))]))
                try await routing.observeTaskOutcomes(current["tasks"].elements ?? [], conversationID: chat.conversationID)
            }
            taskUpdates = updates
            try await root.retain(.init(name: "hoot-routing", domains: ["hoot-routing"], ownerID: owner, invokes: channels, stop: {
                await updates.cancelAndWait()
                await routing.stop(); await root.registry.removeOwner(owner); await root.mcp.removeTools(ownerID: owner)
                try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            }))
        } catch {
            await taskUpdates?.cancelAndWait()
            await routing.stop(); await root.registry.removeOwner(owner); await root.mcp.removeTools(ownerID: owner)
            try? joins.replaceContributions(owner: owner, [], policiesWrapped: true); throw error
        }
    }
}

/// U41 (#97): the one send of a routing card, whoever approved it. Matching an open task, assigning it, the
/// task note and the session line are the same either way, so the automatic send never makes a second copy
/// of a task the card's own send would reuse. Only the doors differ, by who said yes.
enum NativeHOOTSIMRoutingSend {
    /// The person on the card, or their standing "Do it and tell me" setting (Settings → Hoot).
    enum Approval: Sendable { case card, standing }
    struct Doors: Sendable {
        var tasks: @Sendable () async throws -> [NativeRPCValue]
        /// Makes the task and answers its id; the marker is in the details, so a door that answers a list can find it.
        var create: @Sendable (_ title: String, _ details: String, _ folder: String, _ assignee: NativeRPCValue, _ marker: String) async throws -> String
        var assign: @Sendable (_ task: String, _ assignee: NativeRPCValue) async throws -> Void
        var comment: @Sendable (_ task: String, _ text: String) async throws -> Void
        /// Types the line into the session and presses Return; answers when it was sent.
        var type: @Sendable (_ session: String, _ line: String) async throws -> NativeRPCValue
    }

    /// The open tasks this card would reuse: same title and problem, in the target's project or its folder.
    static func openTasks(_ tasks: [NativeRPCValue], for proposal: NativeRPCValue) throws -> [NativeRPCValue] {
        let target = proposal["target"], problem = try proposal["request"]["problem"].requireString("problem", nonempty: true)
        let title = String(problem.prefix(120)), folder = target["folder"].string ?? "", projectID = target["projectId"].string ?? "independent"
        return tasks.filter { task in
            task["title"].string == title && (task["projectId"].string == projectID || task["project"].string == folder)
                && ![task["status"].string, task["crmStatus"].string].contains { ["Done", "Cancelled"].contains($0 ?? "") }
                && (task["instructions"].string ?? task["details"].string ?? "").contains(problem)
        }
    }

    static func send(_ proposal: NativeRPCValue, approval: Approval, doors: Doors) async throws -> NativeRPCValue {
        let target = proposal["target"], reason = proposal["reason"].string ?? ""
        let problem = try proposal["request"]["problem"].requireString("problem", nonempty: true)
        let matches = try openTasks(try await doors.tasks(), for: proposal)
        guard matches.count <= 1 else { throw NativeRPCError(code: "routing-ambiguous-task", message: "More than one open task fits. Choose the exact task before sending.") }
        let assignee: NativeRPCValue = target["kind"].string == "agent" ? target["id"] : .string("none")
        let taskID: String
        if let existing = matches.first {
            taskID = try existing["id"].requireString("task id", nonempty: true)
            if target["kind"].string == "agent", (existing["assignee"].string ?? existing["assignee"]["agentId"].string) != target["id"].string {
                try await doors.assign(taskID, assignee)
            }
        } else {
            let marker = "Hoot routing card " + (proposal["id"].string ?? "")
            let details = problem + "\n\nSource: " + proposal["source"].compact + "\n\n" + marker + ". Routing reason: " + reason
            taskID = try await doors.create(String(problem.prefix(120)), details, target["folder"].string ?? "", assignee, marker)
        }
        try await doors.comment(taskID, approval == .card
            ? "Hoot proposed " + (target["name"].string ?? "a task only") + ": " + reason
            : "Hoot gave this to " + (target["name"].string ?? "a task") + " on your “Do it and tell me” setting. " + reason)
        var result = NativeRPCValue.object([.init("taskId", .string(taskID)), .init("target", target)])
        if approval == .standing { result = result.setting("automatic", .bool(true)) }
        if target["kind"].string == "session", let session = target["id"].string {
            // A person's session never becomes a task-engine-owned worker.
            // Hoot follows this exact send with the existing event-driven wait.
            let line = try BackendDeckCoreCatalogueRules.sanitizeSendText(("Task " + taskID + ": " + problem)
                .replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression))
            let sentAt = try await doors.type(session, line)
            result = result.setting("sessionId", .string(session)).setting("sentAt", sentAt)
                .setting("followUp", .object([.init("tool", .string("sessions.wait")), .init("arguments", .object([.init("sessionId", .string(session)), .init("after", sentAt)]))]))
        }
        return result
    }
}

extension NativeHOOTSIMRoutingSend.Doors {
    /// "Do it and tell me": after the card's 10 s Undo window the person's standing setting is the approval, so the
    /// send uses the same task and session doors the person's own window uses. It runs only while this Mac's
    /// window is open (localContext refuses otherwise), and only for targets inside Hoot's switches
    /// (BackendHOOTSIMRouting.sendsWithoutAsking). Typing is the same as sessions_send.
    static func owner(registry: NativeChannelRegistry, context: NativeRPCContext) -> Self {
        @Sendable func checked(_ reply: NativeRPCValue) throws -> NativeRPCValue {
            guard reply["ok"].bool != false else {
                throw NativeRPCError(code: "routing-failed", message: reply["message"].string ?? reply["error"].string ?? "The task change failed.")
            }
            return reply
        }
        return .init(
            tasks: { try await registry.invoke("tasks:state", context: context, arguments: [])["tasks"].elements ?? [] },
            create: { title, details, folder, assignee, marker in
                let reply = try checked(await registry.invoke("tasks:local-create", context: context, arguments: [.object([
                    .init("title", .string(title)), .init("instructions", .string(details)), .init("project", .string(folder)), .init("assignee", assignee)])]))
                guard let made = (reply["state"]["tasks"].elements ?? []).first(where: { ($0["instructions"].string ?? "").contains(marker) }),
                      let id = made["id"].string else { throw NativeRPCError(code: "routing-failed", message: "The new task could not be found after it was made.") }
                return id
            },
            assign: { task, assignee in
                _ = try checked(await registry.invoke("tasks:local-update", context: context, arguments: [.string(task), .object([.init("assignee", assignee)])]))
            },
            comment: { task, text in
                _ = try checked(await registry.invoke("tasks:local-detail", context: context, arguments: [.string("addTaskCommentWith"),
                    .array([.string(task), .string(text), .object([.init("parentId", .null)])])]))
            },
            type: { session, line in
                let sentAt = Date().timeIntervalSince1970 * 1000
                try await BackendDeckCoreTyping.typeLine(write: { data in
                    guard try await registry.send("session:write", context: context, arguments: [.string(session), .string(data)]) else {
                        throw NativeRPCError(code: "routing-failed", message: "The session is no longer running.")
                    }
                }, text: line, submit: true)
                return .number(sentAt)
            })
    }
}
