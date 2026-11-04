import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// M2 FLOW · Deck Memory: starts the flow that fills the memory (diary, board, note helper,
/// nightly tidy-up) and connects it to signals the app already has. Nothing here polls:
/// every feed is an event the app publishes, plus Hoot's own event stream.
extension NativeCompositionProduction {
    func installDeckMemoryFlow() async {
        guard DeckMemoryFlow.engine == nil, let sessions, let authority else { return }
        let report = self.report, root = self.root, joins = self.joins
        let lifecycle = sessions.lifecycle, manager = sessions.manager, hidden = authority.hidden
        let configuration = sessions.profiles.configuration
        let names = DeckMemoryFlowProjectNames()
        let helperFolder = root.dataRoot.appendingPathComponent("deck-memory/helper", isDirectory: true)
        let runner = DeckMemoryFlowCLIRunner(providers: root.providers, workFolder: helperFolder)

        // The same strict record finder the task engine uses: the session's own conversation, never "newest in folder".
        let finder = BackendTaskAgentTranscripts.locator(claude: { [joins] meta, directory in
            guard let id = meta.agentSessionId else { return nil }
            var scope = try await joins.accountTranscriptScope()
            if let directory { scope.configDirectory = directory; scope.additionalConfigDirectories = []; scope.deviceHomesRoot = nil }
            for folder in try NativeTranscriptPaths.projectDirectories(meta.cwd, scope: scope) {
                if let file = try NativeTranscriptPaths.listTranscripts(folder, scope: scope).first(where: { $0.sessionID == id }) { return .init(path: file.path, scope: scope) }
            }
            return nil
        }, metadata: { await lifecycle.metadata(transcripts: false) },
            systemDirectory: { configuration.systemDirectory($0) },
            ownerContext: { try authority.localContext() }, transcriptConfiguration: { await lifecycle.transcriptConfiguration(sessionID: $0) })

        let locate: @Sendable (String, String?) async -> DeckMemoryFlowRecordTarget? = { id, hint in
            guard !hidden.contains(id), let meta = manager.list().first(where: { $0.id == id }),
                  ["claude", "codex", "gemini"].contains(meta.provider) else { return nil }
            let find: @Sendable () async -> DeckMemoryFlowRecordTarget? = {
                let row = await lifecycle.metadata(sessionID: id)
                let conversation = meta.agentSessionId ?? row?.observedCLIConversationID
                if let found = try? await finder(meta) {
                    let roots = found.scope.flatMap { try? NativeTranscriptPaths.approvedRoots($0) } ?? found.roots
                    // L8 HOST reads how full a Codex or Gemini desk is from the record this found.
                    if meta.provider != "claude" { DeckMemorySessionCenter.shared?.noteTranscript(sessionID: id, path: found.path) }
                    return .init(path: found.path, roots: roots, provider: meta.provider,
                                 conversation: conversation ?? URL(fileURLWithPath: found.path).deletingPathExtension().lastPathComponent)
                }
                // The path the CLI's own turn-end hook named, accepted only inside that account's own folder.
                guard let hint, hint.hasPrefix("/") else { return nil }
                let home = row?.transcriptConfiguration ?? configuration.systemDirectory(meta.provider)
                let roots: [String]
                switch meta.provider {
                case "claude": roots = [URL(fileURLWithPath: home).appendingPathComponent("projects").path]
                case "codex": roots = [URL(fileURLWithPath: home).appendingPathComponent("sessions").path]
                default: roots = BackendTaskAgentTranscripts.geminiRoots(configDirectory: home)
                }
                return .init(path: hint, roots: roots, provider: meta.provider,
                             conversation: conversation ?? URL(fileURLWithPath: hint).deletingPathExtension().lastPathComponent)
            }
            #if TD_HOST_ACCOUNT_BRIDGE
            // Session events carry no request: account reads run under the app owner, as startup does.
            if BackendHOSTProfileScope.context == nil, let owner = try? authority.localContext() {
                return await BackendHOSTProfileScope.withContext(owner, operation: find)
            }
            #endif
            return await find()
        }

        let info: @Sendable (BackendSessionMeta) -> DeckMemoryFlowEngine.SessionInfo = { meta in
            .init(id: meta.id, title: meta.title, provider: meta.provider, cwd: meta.cwd, project: meta.resolvedProjectID,
                  createdAt: meta.createdAt, status: meta.exitCode == nil ? nil : "exited", chat: meta.chat == true, exitCode: meta.exitCode)
        }
        var dependencies = DeckMemoryFlowEngine.Dependencies(
            store: { DeckMemoryFlowStoreAdapter(await DeckMemory.ready()) },
            clock: BackendTaskTimers.realClock,
            stateFile: .init(url: root.dataRoot.appendingPathComponent("deck-memory/flow-state.json")),
            runner: runner,
            installedAIs: { await runner.installed() },
            hootAI: { [weak self] in await MainActor.run { self?.hoot?.runtime.structuredChat?.provider.rawValue } },
            session: { id in
                guard !hidden.contains(id), let meta = manager.list().first(where: { $0.id == id }) else { return nil }
                var session = info(meta)
                if meta.exitCode == nil { session.status = await lifecycle.status(sessionID: id).rawValue }
                return session
            },
            sessions: {
                // With what each is doing right now, so a session found at start is not shown as just "Started".
                var list: [DeckMemoryFlowEngine.SessionInfo] = []
                for meta in manager.list() where !hidden.contains(meta.id) && meta.exitCode == nil {
                    var session = info(meta)
                    session.status = await lifecycle.status(sessionID: meta.id).rawValue
                    list.append(session)
                }
                return list
            },
            stamp: { id in await DeckMemoryCenter.shared.stamp(forSession: id) },
            locate: locate,
            hootRead: { [weak self] cursor in
                guard let chat = await MainActor.run(body: { self?.hoot?.runtime.structuredChat }) else { return nil }
                return await chat.snapshot(after: cursor, limit: 500)
            },
            projectName: { names.name($0) },
            report: { report("memory flow: " + $0) },
            changed: { Task { @MainActor in NotificationCenter.default.post(name: .deckMemoryFlowChanged, object: nil) } })
        // "user" is not always the person: a session Hoot or the app started has Hoot on that side,
        // unless the app saw exactly who typed a message (DeckMemoryFlowInbox.typed).
        dependencies.userSide = { id in
            switch manager.list().first(where: { $0.id == id })?.origin {
            case .copilot: return .orchestrator
            case .app: return .app
            default: return .person
            }
        }
        dependencies.helperFolder = helperFolder.standardizedFileURL.path
        // A task is placed in the project its own id names, else the one its folder lies in (the live list of projects).
        dependencies.projectOf = { id, folder in names.project(id: id, folder: folder) }
        let engine = DeckMemoryFlowEngine(dependencies)
        DeckMemoryFlow.install(engine)
        // HOOT-FLOW: the agents' rule and skill-step reports for Hoot's job flow, and the short titles of every rule.
        await BackendJobFlowLog.shared.configure(file: root.dataRoot.appendingPathComponent("deck-memory/job-flow.jsonl"))
        let titles = DeckMemoryShortTitles(store: { await DeckMemory.ready() }, runner: runner,
                                           helper: { await DeckMemoryShortTitles.flowHelper(installed: { await runner.installed() }) },
                                           report: { report("memory flow: " + $0) })
        DeckMemoryShortTitles.install(titles)

        // The profile's two buttons (L5 PROFILE shows them only when these are set).
        NativeMemoryActions.runHelper = { key in await DeckMemoryFlow.runHelperNow(ownerKey: key) }
        NativeMemoryActions.runTidy = { key in await DeckMemoryFlow.runTidyNow(ownerKey: key) }

        let owner = BackendCompositionRoot.appOwnerID, registry = root.registry
        func feed(_ channel: String, _ handler: @escaping @Sendable (NativeRPCEvent) async -> Void) async {
            do { DeckMemoryFlowFeeds.keep(try await registry.subscribe(channel, ownerID: owner, handler: handler)) }
            catch { report("memory flow: the app's \(channel) feed is not connected: " + error.localizedDescription) }
        }
        // The board follows the app's own session events. No AI, no reading of screens.
        await feed("session:created") { event in
            guard let wire = event.arguments.first, let id = wire["id"].string, !hidden.contains(id),
                  let meta = manager.list().first(where: { $0.id == id }) else { return }
            engine.post(.sessionSeen(info(meta)))
        }
        await feed("session:switched") { event in
            guard event.arguments.count >= 2, let old = event.arguments[0].string, let id = event.arguments[1]["id"].string else { return }
            if old != id { await BackendJobFlowLog.shared.sessionEnded(old); engine.post(.sessionRemoved(id: old)) }
            if !hidden.contains(id), let meta = manager.list().first(where: { $0.id == id }) { engine.post(.sessionSeen(info(meta))) }
        }
        await feed("session:status") { event in
            guard event.arguments.count >= 2, let id = event.arguments[0].string, let status = event.arguments[1].string, !hidden.contains(id) else { return }
            engine.post(.sessionStatus(id: id, status: status))
        }
        await feed("session:exit") { event in
            guard let id = event.arguments.first?.string else { return }
            await BackendJobFlowLog.shared.sessionEnded(id)
            guard !hidden.contains(id) else { return }
            engine.post(.sessionExit(id: id, code: Int(event.arguments.count > 1 ? event.arguments[1].number ?? 0 : 0)))
        }
        await feed("session:removed") { event in
            guard let id = event.arguments.first?.string else { return }
            await BackendJobFlowLog.shared.sessionEnded(id)
            engine.post(.sessionRemoved(id: id))
        }
        await feed("session:renamed") { event in
            guard event.arguments.count >= 2, let id = event.arguments[0].string, let title = event.arguments[1].string, !hidden.contains(id) else { return }
            engine.post(.sessionRenamed(id: id, title: title))
        }
        // The app's task event is only a ping ("something changed"): the list is read from the app's own task state.
        let taskView = self.taskView
        // Who is hired into which seat, from the same list (L4's own rule says which seat an agent sits in):
        // a seat with no session open is "filled by <name>, idle", and only a seat nobody holds is vacant.
        let postHires: @Sendable ([NativeRPCValue]) async -> Void = { agents in
            guard let owners = BackendAGTMemoryOwners.shared else { return }
            var hires: [String: [String]] = [:]
            for agent in agents where agent["status"].string != "archived" {
                guard let key = await owners.seatKey(agent: agent), let seat = AGTSeat(key: key)?.owner.key,
                      let name = agent["name"].string ?? agent["id"].string, !name.isEmpty else { continue }
                hires[seat, default: []].append(name)
            }
            engine.post(.hires(hires.mapValues { names in
                names.count <= 3 ? names.joined(separator: ", ") : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
            }))
        }
        let readTasks: @Sendable () async -> Void = {
            guard let state = try? await taskView?.state() else { return }
            if let agents = state["agents"].elements { await postHires(agents) }
            if let tasks = state["tasks"].elements { await BackendJobFlowLog.shared.noteTasks(tasks, activeSessions: Set(manager.list().filter { $0.exitCode == nil }.map(\.id))); engine.post(.tasks(tasks)) }
        }
        await feed("tasks:changed") { event in
            guard let payload = event.arguments.first, let tasks = payload["tasks"].elements, let agents = payload["agents"].elements else { await readTasks(); return }
            await postHires(agents); await BackendJobFlowLog.shared.noteTasks(tasks, activeSessions: Set(manager.list().filter { $0.exitCode == nil }.map(\.id))); engine.post(.tasks(tasks))
        }
        await feed("project-registry:changed") { event in
            guard let projects = event.arguments.first?["projects"].elements else { return }
            names.set(projects.compactMap { row in
                guard let id = row["id"].string, let name = row["name"].string else { return nil }
                return PROJProject(id: id, name: name, folders: (row["folders"].elements ?? []).compactMap(\.string))
            })
        }
        // MCP tools: what the profile's Helper and Tidy-up parts do, for sessions, Hoot and connected AI apps.
        do {
            try await DeckMemoryFlowTools.install(server: root.mcp, authorize: { native, tool, args, tier, sentence in
                try await authority.authorize(native, tool: tool, arguments: args, tier: tier, sentence: sentence, ownerMustAnswer: tier == .alter)
            }, owner: { native, requested in
                let caller = try await authority.resolve(native).caller
                if let session = caller.sessionID {
                    // A session only ever acts on the memory of the seat it fills.
                    guard let stamp = await DeckMemoryCenter.shared.stamp(forSession: session) else {
                        throw NativeRPCError(code: "not-granted", message: "This session has no memory of its own yet.")
                    }
                    return stamp.owner.key
                }
                return requested.flatMap { DeckMemoryOwner($0)?.key } ?? DeckMemoryOwner.hoot.key
            }, checklist: {
                let saved = (try? await DeckMemory.store.template(.orchestrator))?.checklist ?? ""
                return saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DeckMemoryFlowChecklist.defaultText : saved
            })
            let ids = Set(DeckMemoryFlowTools.ids)
            let registered = await root.mcp.registrations().filter { ids.contains($0.0.id) }
            let metadata = registered.map { spec, _ in BackendDeckCoreCatalogueMetadata(tool: spec, title: spec.description, index: spec.description) }
            let policies = zip(metadata, registered).map { row, registration in joins.mcpPolicy(row, handler: registration.1) }
            try joins.replaceContributions(owner: "deck-memory-flow", [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
        } catch {
            report("memory flow: its tools for AI apps were not all installed: " + error.localizedDescription)
        }
        // Hoot: its own event stream is the diary's source and the turn-end signal.
        if let chat = hoot?.runtime.structuredChat {
            DeckMemoryFlowFeeds.hoot = Task {
                for await _ in await chat.subscribe() { engine.hootChanged() }
            }
        } else { report("memory flow: Hoot's conversation is not connected, so its diary is not being kept.") }
        // Waits for the memory store to open, then takes the signals kept so far.
        DeckMemoryFlowFeeds.start = Task {
            await engine.start()
            await readTasks()
            // Older notes and every top rule get their short titles once, in the background; then after each change.
            await titles.start()
        }
    }
}

/// The projects as the registry has them (names and folders), kept current by its own change event.
/// Before the first change arrives the app's standing list answers, as it does for a session's project.
private final class DeckMemoryFlowProjectNames: @unchecked Sendable {
    private let lock = NSLock()
    private var projects: [PROJProject] = []
    func set(_ next: [PROJProject]) { lock.withLock { projects = next } }
    func name(_ id: String) -> String? { lock.withLock { projects.first { $0.id == id }?.name } ?? PROJProjects.name(for: id) }
    /// The task's own project id, else the project whose folder holds the task's folder, else Independent.
    func project(id: String?, folder: String) -> String {
        let known = lock.withLock { projects }
        return known.isEmpty ? PROJProjects.resolve(projectID: id, folder: folder) : PROJProjects.resolve(projectID: id, folder: folder, projects: known)
    }
}

private enum DeckMemoryFlowFeeds {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var feeds: [NativeRPCSubscription] = []
    static func keep(_ feed: NativeRPCSubscription) { lock.withLock { feeds.append(feed) } }
    nonisolated(unsafe) static var hoot: Task<Void, Never>?
    nonisolated(unsafe) static var start: Task<Void, Never>?
}
