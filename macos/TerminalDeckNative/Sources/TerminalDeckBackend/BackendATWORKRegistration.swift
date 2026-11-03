import Foundation
import TerminalDeckNativeCore

public struct BackendATWORKService: Sendable {
    public let source: BackendATWORKSource
    public let authority: BackendCompositionAuthority
    public let registry: NativeChannelRegistry
    public init(source: BackendATWORKSource, authority: BackendCompositionAuthority, registry: NativeChannelRegistry) {
        self.source = source; self.authority = authority; self.registry = registry
    }
    public func invoke(_ operation: String, arguments: NativeRPCValue, caller: AWWatchCaller) async throws -> NativeRPCValue {
        let tool = operation == "list" ? "agents.at_work" : operation == "resume-command" ? "agents.resume_command" : "agents." + operation
        try await source.authorize(caller, tool: tool, arguments: arguments)
        if operation == "list" {
            try await source.monitor.refreshForRead()
            let snapshot = try await source.snapshot(caller)
            let sort = arguments["sort"].string ?? "cpu"
            guard ["cpu", "memory", "tokens", "time", "name"].contains(sort) else { throw NativeRPCError.invalidArguments("Sort must be cpu, memory, tokens, time or name.") }
            let filter = arguments["source"].string ?? "all"
            guard ["all", "terminal-deck", "other"].contains(filter) else { throw NativeRPCError.invalidArguments("Source must be all, terminal-deck or other.") }
            let inactive = await source.monitor.inactiveIDs()
            let rows = snapshot.agents.filter {
                $0.machineID.isEmpty && !inactive.contains($0.id) &&
                (filter == "all" || ($0.kind == "device" ? filter == "other" : filter == "terminal-deck"))
            }.sorted { a, b in
                let left: Double, right: Double
                switch sort {
                case "memory": left = a.memoryBytes ?? -1; right = b.memoryBytes ?? -1
                case "tokens": left = a.tokensToday ?? -1; right = b.tokensToday ?? -1
                case "time": left = -(a.since ?? Double.greatestFiniteMagnitude); right = -(b.since ?? Double.greatestFiniteMagnitude)
                case "name": return a.name.localizedStandardCompare(b.name) == .orderedAscending
                default: left = a.cpuPercent ?? -1; right = b.cpuPercent ?? -1
                }
                return left == right ? a.id < b.id : left > right
            }
            try await source.authorize(caller, tool: tool, arguments: arguments)
            return .object([.init("agents", .array(rows.map(\.wireValue))), .init("total", .number(Double(rows.count))),
                .init("notices", .array(snapshot.notices.map(NativeRPCValue.string)))])
        }
        let id = try arguments["id"].requireString("id", nonempty: true)
        let snapshot = try await source.snapshot(caller)
        guard let agent = snapshot.agents.first(where: { $0.id == id }) else { throw NativeRPCError(code: "access-denied", message: "That agent is outside your current access.") }
        if operation == "resume-command" {
            let command: String?
            if agent.kind == "device" {
                if let device = await source.inventory.device(id), let conversation = device.sessionID,
                   let validated = AGTShellAgents.resumeCommand(provider: device.ai, conversationID: conversation) {
                    command = (device.project.hasPrefix("/") ? "cd " + AGTDeviceDetect.shellQuote(device.project) + " && " : "") + validated
                } else { command = nil }
            }
            else {
                let session = authority.sessionViews().first { $0["id"].string == agent.sessionID }
                let graph = try authority.sessions()
                var meta: BackendSessionLifecycleCoordinator.Metadata?
                if let id = agent.sessionID { meta = await graph.lifecycle.metadata(sessionID: id) }
                let conversation = meta?.observedCLIConversationID ?? session?["agentSessionId"].string
                if let conversation, let validated = AGTShellAgents.resumeCommand(provider: agent.provider, conversationID: conversation) {
                    let folder = meta?.session.cwd ?? agent.project
                    command = (folder.hasPrefix("/") ? "cd " + AGTDeviceDetect.shellQuote(folder) + " && " : "") + validated
                } else { command = nil }
            }
            guard let command else { throw NativeRPCError(code: "unavailable", message: "This agent does not have a safe resume command.") }
            try await source.authorize(caller, tool: tool, arguments: arguments)
            return .object([.init("id", .string(id)), .init("command", .string(command))])
        }
        guard ["stop", "resume"].contains(operation) else { throw NativeRPCError.invalidArguments("Unknown At work operation.") }
        switch caller {
        case .app(let context):
            try authority.requireLocalUI(context)
            guard arguments["confirmed"].bool == true else { throw NativeRPCError(code: "approval-required", message: "Confirm this action first.") }
        case .mcp(let context):
            try await authority.authorize(context, tool: tool, arguments: arguments, tier: .alter,
                sentence: (operation == "stop" ? "Stop " : "Resume ") + agent.name, ownerMustAnswer: true)
        }
        let current = try await source.snapshot(caller)
        guard let currentAgent = current.agents.first(where: { $0.id == id }) else { throw NativeRPCError(code: "access-denied", message: "The agent became unavailable while approval was open.") }
        let rpc: NativeRPCContext
        switch caller { case .app(let context): rpc = context; case .mcp(let context): rpc = try await authority.rpc(context) }
        if operation == "stop" {
            guard currentAgent.machineID.isEmpty else {
                throw NativeRPCError(code: "unavailable", message: "Open this agent on its own machine to stop it.")
            }
            if currentAgent.kind == "hoot" {
                let result = try await registry.invoke("hoot:stop", context: rpc, arguments: [])
                if case .mcp(let context) = caller { try await authority.record(context, tool: tool, arguments: arguments, summary: .object([.init("id", .string(id)), .init("stopped", .bool(true))])) }
                return result
            }
            guard currentAgent.kind != "device", currentAgent.machineID.isEmpty, let sessionID = currentAgent.sessionID else {
                throw NativeRPCError(code: "unavailable", message: "Open agents in other apps in their own app to stop them.")
            }
            try await authority.requireSessionRPC(sessionID, context: rpc)
            let result = try await registry.invoke("session:kill", context: rpc, arguments: [.string(sessionID)])
            if case .mcp(let context) = caller { try await authority.record(context, tool: tool, arguments: arguments, summary: .object([.init("id", .string(id)), .init("stopped", .bool(true))])) }
            return result
        }
        guard currentAgent.kind == "device", let device = await source.inventory.device(id), BackendATWORKInventory.hasEnded(device),
              let conversation = device.sessionID,
              AGTShellAgents.resumeCommand(provider: device.ai, conversationID: conversation) != nil,
              device.project.hasPrefix("/") else {
            throw NativeRPCError(code: "unavailable", message: "Only a stopped hand-started agent with a readable conversation can resume here.")
        }
        var input = BackendCreateSessionInput(cwd: device.project, provider: "shell")
        input.shellAgent = .init(provider: device.ai, conversationId: conversation, cwd: device.project)
        let value = try NativeRPCValue.parseJSON(JSONEncoder().encode(input))
        let result = try await registry.invoke("session:create", context: rpc, arguments: [value])
        if case .mcp(let context) = caller { try await authority.record(context, tool: tool, arguments: arguments, summary: .object([.init("id", .string(id)), .init("session", result)])) }
        return result
    }
}

public enum BackendATWORKRegistration {
    public static let channels = ["agents-watch:watch", "agents-watch:invalidate", "agents-watch:devices", "agents-watch:stop", "agents-watch:resume", "agents-watch:resume-command", "agents-watch:free-heavy-job"]
    public static let toolIDs = ["agents.at_work", "agents.stop", "agents.resume_command", "agents.resume"]
    public static func install(service: BackendATWORKService, registry: NativeChannelRegistry, server: BackendNativeMCPServer, owner: String) async throws {
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        for channel in channels {
            try await registry.register(channel, ownerID: owner, policy: { try service.authority.requireLocalUI($0) }, handler: { context, args in
                try context.requireCount(args, 0...1)
                let input = args.first ?? .object([])
                if channel == "agents-watch:watch" {
                    let id = try input["viewerID"].requireString("viewerID", nonempty: true)
                    guard let visible = input["visible"].bool else { throw NativeRPCError.invalidArguments("visible must be a boolean.") }
                    await service.source.monitor.setVisible(id, visible: visible)
                    return await service.source.monitor.snapshot()
                }
                if channel == "agents-watch:invalidate" { await service.source.monitor.invalidate(); return .null }
                if channel == "agents-watch:devices" { return await service.source.inventory.wireValue() }
                if channel == "agents-watch:free-heavy-job" {
                    await BackendAGOPTCoordinator.shared.freeHolder(); await service.source.monitor.invalidate(); return .null
                }
                return try await service.invoke(String(channel.dropFirst("agents-watch:".count)), arguments: input, caller: .app(context))
            })
        }
        for tool in toolIDs {
            let operation = tool == "agents.at_work" ? "list" : tool == "agents.resume_command" ? "resume-command" : String(tool.dropFirst(7))
            let fields: [NativeRPCValue.Field] = operation == "list" ? [.init("sort", string), .init("source", string)] : [.init("id", string)]
            let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object(fields)),
                .init("required", .array(operation == "list" ? [] : [.string("id")])), .init("additionalProperties", .bool(false))])
            let change = operation == "stop" || operation == "resume"
            let spec = try BackendMCPTool(id: tool, wireName: tool.replacingOccurrences(of: ".", with: "_"),
                description: change ? "Stop a Terminal Deck agent, or resume a stopped hand-started session here. Changes run when the calling AI's permission mode allows them; each is logged." : "Read agents at work with native CPU, memory and today's observed tokens, or read a safe resume command. Current access applies; no agent is started.",
                inputSchema: schema, tier: change ? .alter : .read)
            try await server.registerTool(spec, ownerID: owner) { context, args in
                .value(try await service.invoke(operation, arguments: args, caller: .mcp(context)))
            }
        }
    }
}

public extension BackendCompositionRoot {
    /// NativeCompositionINT2Watch calls once, then uses the returned source for
    /// its established watch and directory tools. Registration starts no work.
    func installATWORK(source base: any AWAgentsWatchSource, authority: BackendCompositionAuthority,
                       lifecycle: BackendSessionLifecycleCoordinator,
                       resolveTranscript: AWAgentsWatchNativeSource.ResolveTranscript? = nil,
                       processIdentity: (@Sendable (AWWatchAgent) async -> BackendATWORKProcessIdentity?)? = nil) async throws -> BackendATWORKSource {
        let owner = "native-composition:atwork", registry = self.registry, mcp = self.mcp
        let inventory = BackendATWORKInventory(), tokenReader = BackendATWORKTokens(), manager = lifecycle.manager
        let resolve = resolveTranscript ?? AWAgentsWatchNativeSource.establishedTranscript(authority: authority)
        let monitor = BackendATWORKMonitor(readTargets: {
            let context = try authority.localContext(), caller = AWWatchCaller.app(context)
            let read = try await base.snapshot(caller)
            await inventory.refresh()
            let devices = await inventory.rows(), agents = (read.agents + devices).filter { $0.machineID.isEmpty }
            let metadata = await lifecycle.metadata(transcripts: false)
            var targets: [BackendATWORKTarget] = []
            for agent in agents {
                let process = await processIdentity?(agent)
                // A device's sessionID is a CLI conversation ID, never a Deck
                // PTY ID. Hoot's hidden PTY ID is injected internally only.
                let sessionID = agent.kind == "device" ? nil : process?.sessionID ?? agent.sessionID
                let pid = process?.pid ?? agent.pid ?? sessionID.flatMap { manager.pidOf($0) }
                let running: Bool?
                if let known = process?.running { running = known }
                else if let pid, pid > 1 { running = true }
                else if [.queued, .finished, .offline].contains(agent.state) { running = false }
                else { running = nil }
                var tokens = agent.tokensToday, path: String?
                var target: BackendTaskTranscriptTarget?
                if agent.kind == "device", let device = await inventory.device(agent.id), let raw = device.transcriptPath,
                   let safe = BackendAGTDeviceScanner.readable(raw, home: NSHomeDirectory()) {
                    if agent.provider == "claude", let scope = try? await authority.transcriptScope(project: nil, context: context) {
                        target = .init(path: safe, scope: scope)
                    } else if agent.provider == "codex" { target = .init(path: safe, roots: [NSHomeDirectory() + "/.codex/sessions"]) }
                } else if agent.provider == "claude" {
                    // Locate Hoot's transcript with its real private PTY ID,
                    // then publish only the original public row identity.
                    let locatorAgent = sessionID.flatMap { AWWatchAgent.decode(agent.wireValue.setting("sessionID", .string($0))) } ?? agent
                    if let located = try? await resolve(locatorAgent, caller) { target = .init(path: located.path, scope: located.scope) }
                } else if ["codex", "gemini"].contains(agent.provider), let meta = metadata.first(where: { $0.session.id == sessionID }) {
                    let known = meta.observedCLIConversationID ?? meta.session.agentSessionId
                    if known != nil, let config = await lifecycle.transcriptConfiguration(sessionID: meta.session.id) {
                        let claimed = Set(metadata.filter { $0.session.id != meta.session.id && $0.session.provider == agent.provider }.compactMap { $0.observedCLIConversationID ?? $0.session.agentSessionId })
                        target = try? BackendTaskAgentTranscripts.target(provider: agent.provider, configDirectory: config,
                            cwd: meta.session.cwd, createdAt: meta.session.createdAt, knownID: known, claimed: claimed)
                    }
                }
                if let target { path = target.path; tokens = try? await tokenReader.read(target: target, provider: agent.provider) }
                let watchIdentity = if let path { await tokenReader.fileIdentity(path) } else { String?.none }
                targets.append(.init(id: agent.id, pid: pid, tokensToday: tokens, watchPath: path, agent: agent.wireValue, watchIdentity: watchIdentity, running: running))
            }
            try authority.requireLocalUI(context)
            return targets
        }, readHeavyJob: { await BackendAGOPTCoordinator.shared.status(owner: BackendCompositionRoot.appOwnerID) },
            publish: { value in await authority.publish(ownerID: BackendCompositionRoot.appOwnerID, channel: "agents-watch:changed", value: value, registry: registry) })
        let source = BackendATWORKSource(base: base, monitor: monitor, inventory: inventory, authority: authority, manager: manager)
        let service = BackendATWORKService(source: source, authority: authority, registry: registry)
        let token = await lifecycle.observe { event in
            // PTY bytes are deliberately not inventory events. State/process
            // changes and vnode writes carry the useful invalidation signal.
            if case .data = event { return }
            await monitor.invalidate()
        }
        do {
            try await BackendATWORKRegistration.install(service: service, registry: registry, server: mcp, owner: owner)
            try await retain(.init(name: "atwork", domains: ["atwork"], ownerID: owner, invokes: Set(BackendATWORKRegistration.channels),
                events: ["agents-watch:changed"], stop: {
                    await lifecycle.removeObserver(token); await monitor.stop()
                    await registry.removeOwner(owner); await mcp.removeTools(ownerID: owner)
                }))
            return source
        } catch {
            await lifecycle.removeObserver(token); await monitor.stop()
            await registry.removeOwner(owner); await mcp.removeTools(ownerID: owner)
            throw error
        }
    }
}
