import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

// DEPLOY-PIPELINE as app tools (Asad's rule: every feature ships its tools, and every AI gets the same ones).
// Whoever deploys reports live, cheaply: deploy_start, then deploy_step per step (with its result), then deploy_finish.
// deploy_runs reads the live runs and the history. The app works out who is calling (Hoot, a lead, an agent, a
// session, an AI app) and where the person asked for it (up the hand-off chain), so nobody has to say.

extension NativeCompositionProduction {
    /// Never fatal: a problem here leaves every other tool working.
    func installDeployTools() async {
        DeployBoard.shared.configure(dataRoot: root.dataRoot)
        do { try await installDeployToolsThrowing() }
        catch { NSLog("[native graph] deployment tools were not installed: %@", error.localizedDescription) }
        // Real history the project already keeps (Terminal Deck's install lines), read in once, off the start path.
        guard let authority else { return }
        let registry = root.registry
        Task { @MainActor in
            guard let projects = try? await Self.registeredProjects(registry: registry, context: authority.localContext()) else { return }
            await DeployBoard.shared.importBoards(projects)
        }
    }

    private func installDeployToolsThrowing() async throws {
        let owner = "native-composition:deploy", mcp = root.mcp, registry = root.registry
        guard let authority else { return }
        let joins = self.joins
        let definitions = Self.deployToolDefinitions()
        let projectList: @Sendable () async throws -> [PROJProject] = {
            try await Self.registeredProjects(registry: registry, context: authority.localContext())
        }
        let who: @Sendable (BackendMCPCallContext) async throws -> DeployCaller = { [weak self] caller in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The app is closing.") }
            return try await self.deployCaller(caller, authority: authority)
        }
        let taken = Set(await mcp.registrations().map(\.0.id))
        for (id, tier, description, input) in definitions {
            if taken.contains(id) { NSLog("[native graph] deployment tool %@ is already registered by another owner; skipped", id); continue }
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: input, tier: tier)
            try await mcp.registerTool(spec, ownerID: owner) { caller, args in
                guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot do that.") }
                let me = try await who(caller)
                let projects = try await projectList()
                func project(_ wanted: String?) throws -> PROJProject? {
                    if let wanted, !wanted.isEmpty {
                        guard let found = projects.first(where: { $0.id == wanted || $0.name.caseInsensitiveCompare(wanted) == .orderedSame || $0.folders.contains(PROJProjects.normalize(wanted)) }),
                              found.id != PROJProjects.independentID else {
                            throw NativeRPCError.invalidArguments("There is no project called \(wanted). project_registry_list lists them.")
                        }
                        return found
                    }
                    guard let folder = me.folder else { return nil }
                    let id = PROJProjects.resolve(projectID: me.projectID, folder: folder, projects: projects)
                    return id == PROJProjects.independentID ? nil : projects.first { $0.id == id }
                }
                let now = Date().timeIntervalSince1970
                switch id {
                case "deploy.start":
                    guard let target = try project(args["project"].string) else {
                        throw NativeRPCError.invalidArguments("Name the project (project_registry_list lists them).")
                    }
                    let plan: [(name: String, tool: String?)] = (args["steps"].elements ?? []).compactMap { row in
                        if let name = row.string { return (name, nil) }
                        return row["name"].string.map { ($0, row["tool"].string) }
                    }
                    let run = await MainActor.run {
                        DeployBoard.shared.change { $0.start(projectID: target.id, title: args["title"].string, version: args["version"].string,
                                                             commit: args["commit"].string, by: me.actor, origin: me.origin, plan: plan,
                                                             link: args["link"].string, at: now) }
                    }
                    return .value(.object([.init("run", .string(run.id)), .init("project", .string(target.name)), .init("steps", .number(Double(run.steps.count))),
                                           .init("next", .string("deploy_step for each step (name, tool, state, result), then deploy_finish."))]))
                case "deploy.step":
                    let wanted = try project(args["project"].string)?.id
                    // Counts are refused outside a sane range, never converted bare: Int(1e300) ends the app.
                    func count(_ key: String) throws -> Int? {
                        if args[key].isNullish { return nil }
                        guard let value = NativeNumber.integer(args[key].number, in: 0...1_000_000) else { throw NativeRPCError.invalidArguments("\(key) must be a whole number from 0 to 1000000.") }
                        return value
                    }
                    let passed = try count("passed"), failed = try count("failed")
                    let answer = try await MainActor.run { () throws -> NativeRPCValue in
                        let board = DeployBoard.shared
                        guard let runID = args["run"].string ?? NativeCompositionProduction.ownRun(board.ledger, me: me, project: wanted, now: now)?.id else {
                            throw NativeRPCError.invalidArguments("You have no live deployment. Start one with deploy_start (or name its run).")
                        }
                        let report = DeployStepReport(name: args["name"].string ?? "", tool: args["tool"].string, state: DeployState.parse(args["state"].string),
                                                      result: args["result"].string, log: args["log"].string, link: args["link"].string,
                                                      passed: passed, failed: failed)
                        let done = try board.change { try $0.report(runID: runID, report, at: now) }
                        let step = done.run.steps[done.index]
                        return .object([.init("run", .string(done.run.id)), .init("step", .string("\(done.index + 1) of \(done.run.steps.count)")),
                                        .init("state", .string(step.state.rawValue)), .init("pipeline", .string(done.run.state.rawValue))])
                    }
                    return .value(answer)
                case "deploy.finish":
                    let wanted = try project(args["project"].string)?.id
                    let answer = try await MainActor.run { () throws -> NativeRPCValue in
                        let board = DeployBoard.shared
                        guard let runID = args["run"].string ?? NativeCompositionProduction.ownRun(board.ledger, me: me, project: wanted, now: now)?.id else {
                            throw NativeRPCError.invalidArguments("You have no live deployment to finish (or name its run).")
                        }
                        let run = try board.change { try $0.finish(runID: runID, state: DeployState.parse(args["state"].string), result: args["result"].string,
                                                                   version: args["version"].string, commit: args["commit"].string, link: args["link"].string, at: now) }
                        return .object([.init("run", .string(run.id)), .init("state", .string(run.state.rawValue)),
                                        .init("took", .string(run.duration.map(DeployFormat.duration) ?? "")), .init("steps", .number(Double(run.steps.count)))])
                    }
                    return .value(answer)
                default:
                    let wanted = try args["project"].string.flatMap { try project($0)?.id }
                    let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                    let answer = await MainActor.run { () -> NativeRPCValue in
                        let ledger = DeployBoard.shared.ledger
                        if let id = args["run"].string {
                            return ledger.run(id).map { NativeCompositionProduction.wire($0, full: true, names: names) } ?? .object([.init("run", .null)])
                        }
                        let limit = NativeNumber.clamped(args["limit"].number, to: 1...50, fallback: 10)
                        var runs = wanted.map { ledger.runs(project: $0) } ?? ledger.runs
                        let live = runs.filter { $0.isLive && now - $0.updatedAt < DeployLedger.quietAfter }
                        if args["live"].bool == true { runs = live }
                        return .object([.init("live", .array(live.map { NativeCompositionProduction.wire($0, full: true, names: names) })),
                                        .init("history", .array(runs.filter { !$0.isLive }.prefix(limit).map { NativeCompositionProduction.wire($0, full: false, names: names) }))])
                    }
                    return .value(answer)
                }
            }
        }
        let ids = Set(definitions.map(\.0))
        let registered = await mcp.registrations().filter { ids.contains($0.0.id) }
        let metadata = registered.map { BackendDeckCoreCatalogueMetadata(tool: $0.0, title: $0.0.description, index: $0.0.description) }
        let policies = zip(metadata, registered).map { joins.mcpPolicy($0.0, handler: $0.1.1) }
        try joins.replaceContributions(owner: owner, [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
    }

    /// The four tools: id, tier, description, input schema.
    nonisolated static func deployToolDefinitions() -> [(String, BackendMCPTier, String, NativeRPCValue)] {
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        let integer = NativeRPCValue.object([.init("type", .string("integer"))])
        let flag = NativeRPCValue.object([.init("type", .string("boolean"))])
        let states = text.setting("enum", .array(DeployState.allCases.map { .string($0.rawValue) }))
        let planned = NativeRPCValue.object([.init("type", .string("array")), .init("items", .object([.init("type", .array([.string("string"), .string("object")]))]))])
        func schema(_ properties: [(String, NativeRPCValue)], required: [String] = []) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        // #615: step and finish take project too, so a caller with no run named (Hoot) says which project's live run it means.
        return [
            ("deploy.start", .act, "Start a deployment record so the person sees it live (project page, side panel, beside where they asked). Call it when a deploy begins, then deploy_step for EVERY step you really do (tests included, with their numbers), then deploy_finish. title: what it is in a few plain words (\"Installing Terminal Deck build 1c29bb8b\"); version and commit when known; steps: your own planned step names in order, only if you know them (strings, or {name, tool}). project defaults to your session's project. Returns the run id.",
             schema([("project", text), ("title", text), ("version", text), ("commit", text), ("link", text), ("steps", planned)])),
            ("deploy.step", .act, "Report one step of your live deployment. name: plain words (\"Tests\", \"Release build\", \"Upload to TestFlight\"); tool: the tool you really used, by its own name (\"GitHub Actions\", \"Vercel\", \"codesign\", \"swift test\"); state: running when it starts, done or failed when it ends; result: its short result (\"5,792 passed · 0 failed\", \"built 1c29bb8b · signed\", \"deployed to app.example.com · health 200\", \"failed: 2 tests · <first failure>\"); passed / failed: test numbers; log: a short excerpt worth keeping; link. The same name updates that step. A failed step stops the pipeline where everyone sees it; report it again to retry. run defaults to your own live run; project says which project's live run you mean when you name no run.",
             schema([("run", text), ("project", text), ("name", text), ("tool", text), ("state", states), ("result", text), ("passed", integer), ("failed", integer), ("log", text), ("link", text)], required: ["name"])),
            ("deploy.finish", .act, "Finish your live deployment: state done, failed or skipped (cancelled; default: failed when a step failed, else done), result in a few words, and the final version, commit or link. Steps still running end with it. run defaults to your own live run; project says which project's live run you mean when you name no run.",
             schema([("run", text), ("project", text), ("state", states), ("result", text), ("version", text), ("commit", text), ("link", text)])),
            ("deploy.runs", .read, "Deployments: the live runs and the history, newest first (each with its steps, tools, results, who ran it and where it was asked for). project narrows it; run gives one run in full; live true only the running ones; limit (default 10).",
             schema([("project", text), ("run", text), ("live", flag), ("limit", integer)])),
        ]
    }

    /// The caller's own live run: the one this session (or Hoot) started, else the only live run of the project.
    nonisolated static func ownRun(_ ledger: DeployLedger, me: DeployCaller, project: String?, now: Double) -> DeployRun? {
        let live = ledger.live(at: now).filter { $0.source == "reported" }
        if let session = me.actor.sessionID, let mine = live.first(where: { $0.by.sessionID == session }) { return mine }
        if me.actor.kind == "hoot" || me.actor.kind == "app", let mine = live.first(where: { $0.by.kind == me.actor.kind && $0.by.name == me.actor.name && (project == nil || $0.projectID == project) }) { return mine }
        if let project { let theirs = live.filter { $0.projectID == project }; if theirs.count == 1 { return theirs[0] } }
        return nil
    }

    /// Short words for a tool reply: a run and, in full, its steps as one line each.
    nonisolated static func wire(_ run: DeployRun, full: Bool, names: [String: String]) -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [
            .init("run", .string(run.id)), .init("project", .string(names[run.projectID] ?? run.projectID)), .init("what", .string(run.title ?? run.label)),
            .init("state", .string(run.state.rawValue)), .init("by", .string(run.byLine)),
            .init("started", .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: run.startedAt)))),
        ]
        if let version = run.version { fields.append(.init("version", .string(version))) }
        if let commit = run.commit { fields.append(.init("commit", .string(commit))) }
        if let span = run.duration { fields.append(.init("took", .string(DeployFormat.duration(span)))) }
        if let result = run.result { fields.append(.init("result", .string(result))) }
        if let link = run.link { fields.append(.init("link", .string(link))) }
        if run.source != "reported" { fields.append(.init("source", .string(run.source))) }
        if full {
            fields.append(.init("steps", .array(run.steps.map { step in
                .string([step.name, step.tool.map { "(\($0))" }, step.state.rawValue, step.line].compactMap { $0 }.joined(separator: " · "))
            })))
        } else { fields.append(.init("steps", .number(Double(run.steps.count)))) }
        return .object(fields)
    }

    /// Who is calling and where the person asked for it: up the hand-off chain (the task's parents, who asked for the
    /// first one) to the first conversation with the person. Never from arguments.
    func deployCaller(_ native: BackendMCPCallContext, authority: BackendCompositionAuthority) async throws -> DeployCaller {
        let caller = try await authority.resolve(native).caller
        let now = Date().timeIntervalSince1970
        switch caller.kind {
        case .local:
            return DeployCaller(actor: DeployActor(kind: "hoot", name: "Hoot", agentID: "hoot"),
                                origin: DeployOrigin(kind: "hoot", name: "Hoot", at: now), folder: native.projectRoot, projectID: nil)
        case .key:
            let name = caller.keyName ?? "An AI app"
            return DeployCaller(actor: DeployActor(kind: "app", name: name), origin: DeployOrigin(kind: "app", name: name, at: now), folder: native.projectRoot, projectID: nil)
        case .remote:
            return DeployCaller(actor: DeployActor(kind: "person", name: "Your phone"), origin: DeployOrigin(kind: "person", name: "your phone", at: now), folder: nil, projectID: nil)
        case .session:
            let sessionID = caller.sessionID ?? native.sessionID
            let meta = sessions?.manager.list().first { $0.id == sessionID }
            let sessionName = meta?.title.isEmpty == false ? meta!.title : "a session"
            let folder = native.projectRoot ?? caller.projectRoot ?? meta?.cwd
            let store = taskView?.store, config = taskView?.config
            if let store, let task = try? await store.bySession(sessionID) {
                let agentRow: NativeRPCValue? = (try? await config?.agent(task.agentID)) ?? nil
                let agentName = agentRow?["name"].string ?? task.agentID
                let actor = DeployActor(kind: "agent", name: agentName, agentID: task.agentID, sessionID: sessionID)
                let origin = await deployOrigin(task, store: store, config: config, now: now)
                    ?? DeployOrigin(kind: "session", name: agentName, sessionID: sessionID, at: now)
                return DeployCaller(actor: actor, origin: origin, folder: folder ?? (task.project.isEmpty ? nil : task.project), projectID: meta?.projectId)
            }
            if let address = await BackendAGTLeadSeats.shared?.address(ofSession: sessionID) {
                let name = BackendAGTLeadSeats.name(of: address) ?? sessionName
                return DeployCaller(actor: DeployActor(kind: "lead", name: name, sessionID: sessionID),
                                    origin: DeployOrigin(kind: "lead", name: name, sessionID: sessionID, at: now), folder: folder, projectID: meta?.projectId)
            }
            return DeployCaller(actor: DeployActor(kind: "session", name: sessionName, sessionID: sessionID),
                                origin: DeployOrigin(kind: "session", name: sessionName, sessionID: sessionID, at: now), folder: folder, projectID: meta?.projectId)
        }
    }

    private func deployOrigin(_ task: BackendTaskRecord, store: BackendTaskStore, config: BackendTaskConfiguration?, now: Double) async -> DeployOrigin? {
        var root = task, hops = 0
        while hops < 12, let parent = root.value["parentTaskId"].string, let up = try? await store.byID(parent, includeTrash: true) { root = up; hops += 1 }
        let at = DeployFormat.seconds(root.value["createdAt"].number) ?? now
        let asker = root.value["requestedBy"].string ?? "me"
        if asker == "hoot" { return DeployOrigin(kind: "hoot", name: "Hoot", at: at) }
        if asker.hasPrefix("taskagent:") {
            let who = String(asker.dropFirst("taskagent:".count))
            // The agent who asked: the session it talks in, if it is running.
            func liveSession(of agent: String) async -> String? {
                (try? await store.all())?.filter { $0.agentID == agent && $0.sessionID != nil }
                    .max { ($0.value["updatedAt"].number ?? 0) < ($1.value["updatedAt"].number ?? 0) }?.sessionID
            }
            if BackendAGTLeadSeats.isAddress(who), let seats = BackendAGTLeadSeats.shared {
                switch await seats.holder(who) {
                case .session(let id, let name, _): return DeployOrigin(kind: "lead", name: name, sessionID: id, at: at)
                case .agent(let id, let name): return DeployOrigin(kind: "lead", name: name, sessionID: await liveSession(of: id), at: at)
                default: return DeployOrigin(kind: "lead", name: BackendAGTLeadSeats.name(of: who) ?? "the lead", at: at)
                }
            }
            let row: NativeRPCValue? = (try? await config?.agent(who)) ?? nil
            let name = row?["name"].string ?? who
            let leads = ((try? await BackendPROJRegistry.installed?.projects()) ?? []).contains { $0.lead == "agent:" + who }
            return DeployOrigin(kind: leads ? "lead" : "session", name: name, sessionID: await liveSession(of: who), at: at)
        }
        if asker == "me" || asker.isEmpty {
            // The person gave the task himself: the strip shows in the session doing the work.
            return DeployOrigin(kind: "person", name: "you", sessionID: task.sessionID, at: at)
        }
        return DeployOrigin(kind: "app", name: BackendTaskActor.outsideActorName(asker) ?? asker, at: at)
    }
}

/// Who is calling a deployment tool, worked out by the app.
struct DeployCaller: Sendable {
    let actor: DeployActor
    let origin: DeployOrigin?
    let folder: String?
    let projectID: String?
}
