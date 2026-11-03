import Foundation
import AppKit
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installTasksAndRoutines() async throws {
        let core = try wired(self.core, "core"), sessions = try wired(self.sessions, "sessions"), files = try wired(self.files, "files"),
            authority = try wired(self.authority, "authority"), clients = try wired(self.clients, "clients")
        // Server scope requests grant on the same saved-server store (installed later).
        let scopeRequests = BackendTAGAccessScope(keys: core.keys, serverStore: serverStoreReference)
        try joins.replaceContributions(owner: "tag-access", [try scopeRequests.bundle()])
        let persistence = try BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote"), ownership: root.state.ownership)
        // One change hook for store/config/goals/outbox; the CRM registration is its
        // only subscriber and publishes `tasks:changed` once per change (TS deck-control
        // index.ts:731 broadcast). Never subscribe to the published event itself (a loop).
        let changes = BackendCompositionChangeHub()
        let store = BackendTaskStore(persistence: persistence, writeDelay: 1_000, changed: { await changes.fire() })
        let config = try BackendTaskConfiguration(persistence: persistence, secrets: BackendConnectedTasksKeychain(appName: configuration.appName), changed: { await changes.fire() })
        let goals = BackendGoalStore(persistence: persistence, changed: { await changes.fire() })
        await installToolUseRestrictions(store: store, config: config)
        try await store.start(); try await config.start(); try await goals.start()
        if let pluginHost = clients.plugins {
            await pluginHost.setTaskPulseSource { try await store.all() }
            await pluginHost.noteTaskRows(try await store.all()) // baseline; no old completion backfill
            let pluginTaskChanges = await changes.observe { [store, report] in
                do { await pluginHost.noteTaskRows(try await store.all()) }
                catch { report("Plugin task pulse source: " + error.localizedDescription) }
            }
            try await root.retain(.init(name: "plugin-task-pulse-source", domains: ["plugin-task-pulse"], ownerID: "native.plugin-task-source", invokes: [], stop: { await pluginTaskChanges.cancelAndWait() }))
        }
        await core.control.setProfileConsentInspector { [joins, authority, config, root] tool, args, context in
            guard ["tasks.agents_import", "tasks_agents_import"].contains(tool) else {
                return BackendTAGProfileConsent.names(args)
            }
            let reply = try await joins.contexts.invoke(handler: { native, input in
                let folders: [String]
                if input.has("batches") {
                    folders = try input["batches"].requireArray("agent batches").map { try $0["folder"].requireString("folder", nonempty: true) }
                } else { folders = [try input["folder"].requireString("folder", nonempty: true)] }
                for folder in folders {
                    _ = try await authority.knownFolder(folder, native: native)
                    _ = try await authority.knownFolder(BackendTAGAgentImport.directory(folder).path, native: native)
                }
                let projects = try await Self.registeredProjects(registry: root.registry, context: authority.localContext())
                for batch in try BackendPROJAgentBatches.batches(input, projects: projects) {
                    let entries: [NativeRPCValue] = [batch.options] + (batch.options["agents"].fields ?? []).map(\.value)
                    for entry in entries {
                        if let path = entry["defaultProject"].string { _ = try await authority.knownFolder(path, native: native) }
                    }
                }
                let names = try await BackendPROJAgentBatches.preview(configuration: config, request: input, projects: projects)
                return .value(.object([.init("names", .array(names.map(NativeRPCValue.string)))]))
            }, arguments: args, context: context)
            guard let names = reply.structuredContent?["names"].elements else {
                throw NativeRPCError(code: "invalid-reply", message: "The authorized profile preview returned no names.")
            }
            return try names.map { try $0.requireString("profile name", nonempty: true) }
        }
        // FORK-TASKS: a registered project's folder counts for a task agent's start, open or not.
        let gate = NativeCompositionTaskGate(store: store, config: config, core: core, state: state, registered: { [root, authority] in
            return ((try? await Self.registeredProjects(registry: root.registry, context: authority.localContext())) ?? []).flatMap(\.folders)
        })
        let ags: NativeCompositionINT2AGS?
        if SourceNamespace.agentSettingsEnabled {
            ags = try await installINT2AGS(configuration: config, launchAuthority: { [authority, store, config] input, settings in
                let request: NativeRPCContext?
                #if TD_HOST_ACCOUNT_BRIDGE
                request = NativeCompositionCallContext.rpc ?? BackendHOSTProfileScope.context
                #else
                request = NativeCompositionCallContext.rpc
                #endif
                if let taskID = input.taskID {
                    try await gate.authorize("sessions.start", .object([.init("task", .string(taskID)),
                        .init("provider", input.provider.map(NativeRPCValue.string) ?? .null), .init("account", input.profileId.map(NativeRPCValue.string) ?? .null)]))
                    guard let task = try await store.byID(taskID), let row = try await config.agent(task.agentID) else {
                        throw NativeRPCError(code: "not-permitted", message: "The task's agent is no longer available.")
                    }
                    let owner = try BackendAGSProfileProjection.settings(BackendTaskEngine.playbookAgent(task, row), defaultProvider: settings.provider)
                    // Hooks/environment are the encrypted owner extension; the task gate owns the key/profile constraints.
                    guard owner.provider == settings.provider else { throw NativeRPCError(code: "not-permitted", message: "The task's coding agent changed during launch.") }
                } else if let rpc = request {
                    _ = try await authority.createContext(input, context: rpc)
                } else if let device = BackendAGSLaunchScope.deviceStart, !device.isEmpty {
                    // A paired device's own start: the remote host already checked its level, folders and boundary.
                } else if input.origin == .copilot, input.originRunId?.isEmpty == false {
                    // Hoot's (or a lead's) own sessions.start: the deck-control call that carries it was already checked by
                    // the security server (caller, folder, tier, consent). Its playbook only fills the AI's model, effort and
                    // permission (MEM 2c / H8, 11 Oct: refused here before, so a playbook start never ran).
                } else if !BackendAGSLaunchScope.restoring {
                    throw NativeRPCError(code: "not-permitted", message: "This agent launch has no current authorized request.")
                }
            })
        } else {
            ags = nil
        }
        let outbox = BackendTaskOutbox(persistence: persistence, target: { [config, core] key in
            guard let current = await core.keys.get(id: key), current["crmOnly"].bool == true || current["tasks"].bool == true,
                  let connection = try await config.connection(key), connection["enabled"].bool == true,
                  let address = connection["eventsUrl"].string, let url = URL(string: address),
                  let secret = try await config.eventsSecret(key) else { return nil }
            return try BackendTaskWebhookTarget(url: url, signingSecret: secret)
        }, onCommentID: { [store] id, comment in try await store.markOurs(keyID: id, eventID: comment) },
            changed: { await changes.fire() }, problem: { [report] in report($0) })
        let specs = try BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote/task-briefs"), ownership: root.state.ownership)
        // U144 (#363): week-old briefs and replies go at start; one a task still waits on stays.
        let waiting = Set(((try? await store.all(includeTrash: true)) ?? []).compactMap { $0.value["briefFile"].string.map { URL(fileURLWithPath: $0).lastPathComponent } })
        Task.detached(priority: .utility) { BackendTaskTypedBriefs.sweep(specs, keeping: waiting) }
        var access = BackendTaskSessionDriver.access(lifecycle: sessions.lifecycle, manager: sessions.manager, specs: specs,
            authorize: { try await gate.authorize($0, $1) }, environment: { [root, configuration] in
                var env = configuration.inheritedEnvironment; env["PATH"] = try await root.providers.loginPath(); return env
            }, setControl: { [joins] id, control, value in try await joins.setAgentControl(sessionID: id, control: control, value: value) },
            noteTurn: { [joins] id in await joins.noteTaskSend(id) },
            // TS task-engine.ts tellHoot: Hoot's own session (started if need be), the brief typed
            // into it as one line, exactly as deliverBrief does for every brief.
            tellHoot: { [weak self] text in
                let owners = await MainActor.run { (self?.hoot, self?.coreSurface) }
                guard let hoot = owners.0 else {
                    throw NativeRPCError(code: "unavailable", message: "Hoot is not running on this Mac, so this task is waiting for it.")
                }
                let line = text.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
                // #109: Hoot's page is its structured chat, so a task comment goes in through
                // the chat's one incoming path (it starts Hoot if needed). A busy Hoot throws,
                // and the comment shows "Couldn't reach Hoot" with Try Again.
                // Deck Memory: the app wrote this, not the person, and the message says so (the diary stamps it author = app).
                if hoot.runtime.structuredChat != nil {
                    _ = try await hoot.runtime.sayValidated(line, context: .object([.init("source", .object([.init("kind", .string("task"))]))])); return
                }
                guard let surface = owners.1 else {
                    throw NativeRPCError(code: "unavailable", message: "Hoot is not running on this Mac, so this task is waiting for it.")
                }
                let state = try await hoot.runtime.ensure()
                guard let session = state.sessionId else { throw NativeRPCError(code: "unavailable", message: "Hoot is not running on this Mac, so this task is waiting for it.") }
                _ = try await surface.deliverBrief(session, line: line)
            }, bindTaskSession: { [store, sessions] task, session in
                let live = Set(sessions.manager.list().filter { $0.exitCode == nil }.map(\.id))
                guard try await store.claim(task.id, sessionID: session.id, liveSessionIDs: live, expectedAssignee: task.value["assignee"]) else {
                    throw NativeRPCError(code: "task-already-held", message: "Another live session already holds this task. The new session was stopped.")
                }
            }, chats: sessionChats, sender: { task in
                BackendTeamChatSender.request(task.value["requestedBy"].string ?? "hoot", agents: (try? await config.allAgents()) ?? [])
            })
        // Review paperclip #1: the driver revalidates BackendPCDecisionDelivery at its final start/send (9d209a92).
        access.decisionSafeStart = true; access.decisionSafeSend = true
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { [files, authority] task in
                guard let workspaces = files.workspaces else { throw BackendSessionFailure.missingCapability("the native task workspace owner") }
                return try await workspaces.folderFor(taskID: task.id, project: task.project,
                    useWorkspace: task.value["useWorkspace"].bool == true, title: task.value["title"].string ?? "",
                    context: authority.localContext()) ?? task.project
            }, outgoing: BackendTaskOutbox.outgoing(store: store, outbox: outbox), notifications: { [core] task, event in
                if let ags { await ags.events.task(event) }
                try await core.notifications.taskNotifications(task, event)
            }, settings: { [root] agent in
                let preferred = await root.state.getPreferences()["defaultProvider"].string ?? "claude"
                let provider = agent["provider"].string ?? preferred
                let base = try BackendAGSProfileProjection.settings(agent, defaultProvider: provider)
                guard let ags, let id = agent["id"].string else { return base }
        // PLAYBOOK-SEATS: a row/agent pair whose AI is the playbook's: the agent's profile is carried to that AI.
                let profile = BackendPlaybookLayer.carried(try await ags.store.profile(id) ?? base, to: provider)
                return try BackendAGSPolicy.resolve(defaults: try await ags.store.defaults().providers[provider], profile: profile)
            }, profileID: { [sessions, root, authority] agent, folder in
                let preferred = await root.state.getPreferences()["defaultProvider"].string ?? "claude"
                let provider = agent["provider"].string ?? preferred
                // ACCOUNTS (FORK-L1's request of 04:31, made by L4): the account for a new session of this agent is
                // the one "effective" answer, which knows the agent's SEAT: the agent's own account (if it still
                // has one) → its seat → its project → the whole app → this Mac's login. It has to be decided
                // here: the launch refuses an account that differs from the one prepared.
                var input: [NativeRPCValue.Field] = [.init("provider", .string(provider)), .init("projectPath", .string(folder)),
                    .init("sessionProfileId", agent["account"].string.map(NativeRPCValue.string) ?? .null)]
                if let seat = await BackendAGTMemoryOwners.shared?.seatKey(agent: agent) { input.append(.init("seat", .string(seat))) }
                do {
                    return try await sessions.accountRPC.invoke("profiles:effective", args: [.object(input)], context: try authority.localContext())["accountId"].requireString("account")
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // L8 (11 Oct, found in the dev copy and true of his real host too): a session host that is
                    // still running an OLDER helper (it is never replaced while it holds sessions) does not know
                    // "profiles:effective" and refuses it ("could not be authenticated"). Every agent task then
                    // failed to start. Until that host is replaced, use the account answer every helper knows.
                    #if TD_HOST_ACCOUNT_BRIDGE
                    return try await BackendHOSTProfileScope.withContext(try authority.localContext()) {
                        try await sessions.profiles.resolve(sessionProfileID: agent["account"].string, projectPath: folder, provider: provider).id
                    }
                    #else
                    return try await sessions.profiles.resolve(sessionProfileID: agent["account"].string, projectPath: folder, provider: provider).id
                    #endif
                }
            }, problem: { [report] in report($0) })
        // FORK-TASKS (11 Oct): a task given to Hoot is worked as a task turn in Hoot's chat (no user bubble
        // there, one compact line) and its progress and answer come back to be posted as Hoot's comments on
        // the task. This is L6's background turn with reason "task" (exactly what its `taskTurn` is inside:
        // same queue, same wake-up, same consent for the task tools on this one task, same diary stamp), given
        // the task engine's WHOLE brief as the message: that brief already has the title once, the id once and
        // the task's own words as a quoted block, so nothing is wrapped around it a second time.
        // "unavailable" (no structured chat, or an id a background turn cannot carry) makes the engine fall
        // back to the one-line `tellHoot` above, which still says why on the task if Hoot cannot be reached.
        await engine.setHootTaskTurns({ [weak self] turn, progress in
            let hoot = await MainActor.run { self?.hoot }
            guard let hoot, hoot.runtime.structuredChat != nil,
                  turn.taskID.allSatisfy({ $0.isLetter || $0.isNumber || "-_.:".contains($0) }) else {
                throw NativeRPCError(code: "unavailable", message: "Hoot is not running on this Mac, so this task is waiting for it.")
            }
            // HOOT-TASKS-SPLIT (Asad, 12 Oct): the task's OWN Hoot conversation and process, never the chat's.
            let message = "[From \(BackendSharedBrand.name)'s Tasks, not typed by the owner. This is your conversation for task \(turn.taskID) only; what you answer is posted on the task's thread.]\n\n" + turn.brief
            // HOOT-THREAD: the thread so far on its first turn, then every comment posted since its last turn.
            let taskStore = await MainActor.run { self?.taskView?.store }
            let record = (try? await taskStore?.byID(turn.taskID)) ?? nil
            let notes = record?.value["notes"] ?? .array([])
            return try await hoot.taskConversations.turn(taskID: turn.taskID, title: turn.title, message: message,
                                                         comments: BackendHootTaskConversations.Comment.from(notes), clientMessageID: turn.clientMessageID, progress: progress)
        }, stop: { [weak self] taskID in
            // The task was stopped, deleted or given to someone else: Hoot's turn on it ends now (running:
            // interrupted; still waiting: never started). L6 reports such a turn as stopped, never finished.
            guard let hoot = await MainActor.run(body: { self?.hoot }) else { return }
            await hoot.taskConversations.cancel(taskID: taskID)
        }, closing: {
            // T19: the app has begun to close (set before anything is stopped, on every way of quitting).
            await MainActor.run { AppModel.shared.isTerminating }
        })
        // A brief names the project ("iMatch"), from the live project list.
        await engine.setProjectNames { [root, authority] task in
            guard let projects = try? await Self.registeredProjects(registry: root.registry, context: authority.localContext()) else { return nil }
            let id = PROJProjects.resolve(projectID: task.value["projectId"].string, folder: task.project, projects: projects)
            return id == PROJProjects.independentID ? nil : PROJProjects.name(for: id, projects: projects)
        }
        // PARALLEL-JOBS: an agent's jobs at once, each in its own worktree; claims, landing and clean-up (BackendParallelJobs).
        if let workspaces = files.workspaces {
            let git = files.git
            let parallelJobs = BackendParallelJobs(git: { [authority] cwd, arguments in try await git.workspaceCommand(cwd: cwd, arguments: arguments, context: authority.localContext()) },
                workspace: { [authority] id in let view = try await workspaces.view(taskID: id, context: authority.localContext())["workspace"]; return view.isNullish ? nil : view },
                remove: { [authority] id in _ = try await workspaces.remove(taskID: id, liveFolders: [], context: authority.localContext()) })
            await engine.setParallelJobs(parallelJobs); await BackendParallelJobsBox.shared.set(parallelJobs)
        }
        // SETTINGS-TRUTH rows 42/46: the project's "Linked servers" (Project settings, New project guide) reach every
        // brief for work in that project, Hoot's and the agents' alike.
        await engine.setProjectNotes { [root] task in
            let id = PROJProjects.resolve(projectID: task.value["projectId"].string, folder: task.project)
            guard id != PROJProjects.independentID else { return nil }
            // SETTINGS-TRUTH row 44 (TRUTH-INT): the project's repository from the guide reaches the same briefs.
            let values = await root.settings.projectSettings(id)["values"]
            let repo = values[PROJSetup.repoKey].string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lines = [BackendTaskEngine.linkedServersLine(values[PROJSetup.serversKey].string),
                         repo.isEmpty ? nil : "Code for this project: the GitHub repository \(repo) (https://github.com/\(repo))."].compactMap { $0 }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        if let chats = sessionChats {
            await engine.setHostedTaskChats { Set(await chats.conversations().filter { $0.job.agentID == "hoot" && $0.job.taskID != nil }.map { $0.session.id }) }
        }
        if let chats = sessionChats, let hoot {
            let visible = NativeHootTaskChatJobs(chats: chats, registry: root.registry, agents: { (try? await config.allAgents()) ?? [] })
            await hoot.taskConversations.setJobVisibility(started: { [sessions] taskID, title, worker in
                guard let runtime = worker as? BackendCopilotSessionRuntime else { throw BackendSessionFailure.missingCapability("Hoot's task runtime") }
                let task = try await store.byID(taskID)
                let meta = try await visible.start(taskID: taskID, title: title, runtime: runtime, task: task)
                if await runtime.isHostedTask() {
                    guard try await store.claim(taskID, sessionID: meta.id, liveSessionIDs: Set(sessions.manager.list().map(\.id)), expectedAssignee: task?.value["assignee"]) else { throw BackendSessionFailure.invalidInput("The task already has another live worker.") }
                }
            }, finished: { taskID, result in
                await visible.finish(taskID: taskID, result: result)
                // This running app delivers through the original task turn. Reattachment delivers through the host observer.
                if let row = try? await store.byID(taskID), row.sessionID != nil { try? await store.release(taskID, process: "idle") }
            }, closing: { await MainActor.run { AppModel.shared.isTerminating } })
        }
        if let chats = sessionChats {
            await chats.setJobObservers(turn: { id, turn in
                switch turn.state {
                case .done(let answer): try? await engine.noteFinishedTurn(sessionID: id, turnID: turn.turnID ?? id, answer: answer)
                case .failed(let reason): try? await engine.noteNeedsInput(sessionID: id, screen: reason)
                default: break
                }
            }, closed: { [lifecycle = sessions.lifecycle, registry = root.registry] id in
                try? await lifecycle.close(sessionID: id)
                _ = try? await chats.openJobHistory(id)
                if let row = await chats.conversations().first(where: { $0.session.id == id }) {
                    try? await registry.publish("session:created", arguments: [row.wire["session"]], ownerID: BackendCompositionRoot.appOwnerID)
                }
            })
        }
        // PLAYBOOK-SEATS: an agent's job runs with the playbook row for that job first (the project lead's playbook,
        // Hoot's where the project has no lead), then the agent's own settings, then the app defaults.
        await engine.setPlaybookSeats(playbook: { task in
            let projects = (try? await BackendPROJRegistry.installed?.projects()) ?? []
            let id = PROJProjects.resolve(projectID: task.value["projectId"].string, folder: task.project, projects: projects)
            let owner: DeckMemoryOwner = projects.first(where: { $0.id == id }).flatMap(AGTSeats.lead(of:)) != nil ? .lead(id) : .hoot
            return await BackendPlaybookFill.row(owner: owner, job: task.value["title"].string ?? "")
        }, own: { [ags] agent in
            guard let id = agent["id"].string else { return nil }
            let base = try BackendAGSProfileProjection.settings(agent, defaultProvider: agent["provider"].string ?? "claude")
            guard let ags else { return base }
            return try await ags.store.profile(id) ?? base
        })
        let local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: engine)
        await root.installReceiver(tasks: local, configuration: config, sessions: sessions, appName: configuration.appName,
            hook: { event in if let ags { await ags.events.receiver(id: event.id) } }, // RCV
            // The person's registered projects, read when an event is sorted: the Receiver matches a
            // folder against these and holds no project list of its own (L4, SUITE-0600 note C3).
            projects: { [root, authority] in
                return ((try? await Self.registeredProjects(registry: root.registry, context: authority.localContext())) ?? [])
            })
        let attachments = BackendTaskAttachments(persistence: persistence,
            authorizeSource: { [files, authority] path in try await files.authority.authorize(path, context: authority.localContext()) })
        // deck-control ELECTRON_TASK_REMINDERS: a Mac banner; a click shows the task (index.ts showTask:
        // the page opens it on `tasks:open`; the app comes forward because the person clicked).
        let registry = root.registry
        let reminders: @Sendable (String, String, String) async throws -> BackendTaskReminderDelivery = { taskID, title, body in
            await NativeCompositionBanners.shared.post(title: title, body: body) {
                Task { try? await registry.publish("tasks:open", arguments: [.string(taskID)], ownerID: BackendCompositionRoot.appOwnerID) }
            }
        }
        let detail = BackendTaskDetailService(store: store, local: local, people: .native(configuration: config), notify: reminders, files: attachments,
            desktop: .init(chooseFiles: { try await NativeCompositionFolderPicker.files() }, chooseFolder: { try await NativeCompositionFolderPicker.pick(NSHomeDirectory()) },
                openPath: { path in await MainActor.run { NSWorkspace.shared.open(URL(fileURLWithPath: path)) ? "" : "The file could not be opened." } }),
            settingsPersistence: persistence, problem: { [report] in report($0) })
        await BackendTaskFieldsBox.shared.set(detail: detail)   // CRM-FIELDS: Receiver/CRM values land as the task's custom fields
        // #109 "seen": a comment's recipient starting its turn on it (its session goes to
        // working; Hoot's chat goes busy) marks the comment read. Pushed events, no polling.
        installHootMentionDelivery(detail: detail)   // L8: an @agent in Hoot's chat is delivered through the Tasks mention path
        await detail.retainCommentSeenFeeds([
            try await root.registry.subscribe("session:status", ownerID: BackendCompositionRoot.appOwnerID) { [detail] event in
                guard event.arguments.count >= 2, let id = event.arguments[0].string, event.arguments[1].string == "working" else { return }
                await detail.noteRecipientWorking(sessionID: id)
            },
            try await root.registry.subscribe(BackendHootChatChannels.event, ownerID: BackendCompositionRoot.appOwnerID) { [detail] event in
                guard event.arguments.first?["busy"].bool == true else { return }
                await detail.noteRecipientWorking(sessionID: nil)
            },
        ])
        // HOOTFIX: one locator for Claude, Codex and Gemini task agents. Session events carry
        // no request, so its account reads run under the app owner (as startup does).
        let transcriptLocator = BackendTaskAgentTranscripts.locator(claude: { [joins] meta, directory in
            guard let id = meta.agentSessionId else { return nil }
            var scope = try await joins.accountTranscriptScope()
            if let directory { scope.configDirectory = directory; scope.additionalConfigDirectories = []; scope.deviceHomesRoot = nil }
            for folder in try NativeTranscriptPaths.projectDirectories(meta.cwd, scope: scope) {
                if let file = try NativeTranscriptPaths.listTranscripts(folder, scope: scope).first(where: { $0.sessionID == id }) { return .init(path: file.path, scope: scope) }
            }
            return nil
        }, metadata: { [sessions] in await sessions.lifecycle.metadata(transcripts: false) },
            systemDirectory: { [sessions] in sessions.profiles.configuration.systemDirectory($0) },
            ownerContext: { [authority] in try authority.localContext() },
            transcriptConfiguration: { [sessions] in await sessions.lifecycle.transcriptConfiguration(sessionID: $0) })
        let answers = BackendTaskTranscriptAnswers(locate: transcriptLocator)
        let tokenUsage = BackendAGOPTTokenUsage(locate: transcriptLocator, persistence: persistence)
        let monitor = BackendTaskTurnMonitor(store: store, engine: engine, manager: sessions.manager,
            answer: { try await answers.latest($0) }, tokenUsage: { try await tokenUsage.total($0) }, usageEvents: { meta, changed in try await tokenUsage.observe(meta, onChange: changed) }, problem: { [report] in report($0) })
        let view = BackendTaskStateView(store: store, configuration: config, goals: goals, outbox: outbox,
            keyViews: { [core] in await core.keys.list() })
        let planning = BackendGoalPlanning(goals: goals, tasks: store, configuration: config, local: local, detail: detail)
        let api = BackendTaskAPI(store: store, configuration: config, engine: engine)
        let tools = BackendTaskToolAuthority(requireTasks: { [authority, store, weak self] native in
            let caller = try await authority.resolve(native).caller
            if let self, await self.allowsINT2PhoneTasks(caller, mutation: false) { return }
            let worker = caller.sessionID == nil ? nil : try await store.bySession(caller.sessionID!)
            // L4-AGENTS: a session that fills a project's lead seat has the seat's task grant.
            let leadSeat = caller.kind == .session && worker == nil ? await BackendAGTLeadSeats.shared?.address(ofSession: caller.sessionID) : nil
            guard caller.kind == .local || caller.kind == .key && caller.tasks || caller.kind == .session && (worker != nil || leadSeat != nil) else { throw NativeRPCError(code: "not-granted", message: "This caller has no task grant.") }
        }, requireHoot: { [authority, joins, weak self] native in
            let caller = try await authority.resolve(native).caller
            let (tool, args) = try await joins.nativeTool(native)
            let readingGoals = tool == "tasks.goals" && ["list", "get"].contains(args["do"].string ?? "list") || tool == "tasks.progress"
            if let self, await self.allowsINT2PhoneTasks(caller, mutation: !readingGoals) { return }
            guard caller.kind == .local else { throw NativeRPCError(code: "not-granted", message: "This task operation belongs to Hoot.") }
        }, visible: { [authority, store, weak self] native, task in
            let caller = try await authority.resolve(native).caller
            if caller.kind == .local { return true }
            if caller.kind == .remote {
                guard task.isLocal, let self else { return false }
                return await self.allowsINT2PhoneTasks(caller, mutation: false, project: task.project)
            }
            if caller.kind == .key {
                guard caller.tasks, task.isLocal || task.value["keyId"].string == caller.keyID else { return false }
                return caller.folders == nil || caller.folders!.contains { BackendCompositionAuthority.within(task.project, $0) }
            }
            // L4-AGENTS: the session filling a lead seat sees the seat's tasks and the parts it handed on.
            if caller.kind == .session, let seat = await BackendAGTLeadSeats.shared?.address(ofSession: caller.sessionID) {
                let parent: BackendTaskRecord?
                if let id = task.value["parentTaskId"].string { parent = try await store.byID(id) } else { parent = nil }
                if BackendAGTLeadSeats.sees(seat, task, parent: parent) { return true }
            }
            guard caller.kind == .session, let session = caller.sessionID, let worker = try await store.bySession(session) else { return false }
            return task.sessionID == session || task.value["parentTaskId"].string == worker.id || (worker.value["reviewOfTaskId"].string == task.id && task.value["reviewerTaskId"].string == worker.id)
        }, project: { [authority] native, path in _ = try await authority.knownFolder(path, native: native) },
            authorize: { [joins, authority, store, goals, weak self] native, tool, args, tier in
                let caller = try await authority.resolve(native).caller
                let standingProfile = BackendTAGProfileConsent.honorsStandingKey(tool: tool, arguments: args, caller: caller)
                if caller.kind == .key, ["tasks.agents", "tasks_agents"].contains(tool), ["save", "save-many"].contains(args["do"].string ?? "") {
                    // The domain has validated the complete request and will apply
                    // only narrowing. Widening waits for the exact inbox decision.
                    try await BackendAGOPTProfileApprovalScope.$narrowing.withValue(true) {
                        try await joins.prepareNative(native, tier: tier, sentence: "Save the permitted narrower agent settings", ownerMustAnswer: false)
                    }
                } else {
                    // FORK-TASKS (11 Oct): being given a task (or asked in its comments) is the owner's yes to
                    // commenting on it, handing a part of it on and giving its verdict. Only for the task's own
                    // holder and only on that task; everything else still asks on screen.
                    var assigned = false
                    if tier != .read {
                        let who: BackendTaskAssignmentConsent.Caller
                        if caller.kind == .local { who = .hoot }
                        else if caller.kind == .session, (caller.machineID ?? "").isEmpty, let session = caller.sessionID { who = .session(session) }
                        else { who = .other }
                        assigned = (try? await BackendTaskAssignmentConsent.covers(tool: tool, arguments: args, caller: who, store: store)) ?? false
                        // L4-AGENTS: the same yes for the session that fills the lead seat holding the task.
                        if !assigned, case .session(let session) = who, let seats = BackendAGTLeadSeats.shared {
                            assigned = await seats.covers(tool: tool, arguments: args, sessionID: session, task: { try await store.byID($0) })
                        }
                    }
                    try await joins.prepareNative(native, tier: tier, sentence: BackendTAGProfileConsent.sentence(tool: tool, arguments: args) ?? ("Use " + tool),
                                                  ownerMustAnswer: BackendCrmLink.ownerMustAnswer(tool: tool, caller: caller, otherwise: tier != .read && !standingProfile && !assigned))
                }
                if caller.kind == .remote {
                    var project = args["project"].string
                    if let id = args["task"].string, let task = try await store.byID(id) {
                        guard task.isLocal else { throw NativeRPCError(code: "access-denied", message: "This phone panel cannot change a CRM task.") }
                        project = task.project
                    }
                    if let id = args["goal"].string, let goal = try await goals.byID(id) {
                        guard let actual = goal["project"].string, !actual.isEmpty else { throw NativeRPCError(code: "access-denied", message: "This goal has no granted project.") }
                        project = actual
                    }
                    guard let self, await self.allowsINT2PhoneTasks(caller, mutation: tier != .read, project: project) else {
                        throw NativeRPCError(code: "access-denied", message: "The phone's current task access changed while approval was pending.")
                    }
                }
            },
            actorName: { [weak self, authority, store] native in
                let caller = try await authority.resolve(native).caller
                // A paired phone or tablet speaks as itself ("Asad's iPhone"), never as "AI app (AI app)" (27 Oct walk, f).
                if caller.kind == .remote, let device = caller.deviceID, let trust = await self?.remoteTrust,
                   let named = await trust.device(device)?.name { return BackendTaskActor.deviceActor(named) }
                if caller.kind == .session, let session = caller.sessionID, let worker = try await store.bySession(session) { return "taskagent:" + worker.agentID }
                // L4-AGENTS: a session filling a lead seat speaks as the seat (its tasks' holder).
                if caller.kind == .session, let seat = await BackendAGTLeadSeats.shared?.address(ofSession: caller.sessionID) { return "taskagent:" + seat }
                return caller.kind == .local ? "hoot" : BackendTaskActor.appActor(caller.keyName ?? "AI app")
            },
            crmKeyID: { [authority] native in guard let key = try await authority.resolve(native).caller.keyID else { throw NativeRPCError(code: "not-granted", message: "This caller is not a CRM key.") }; return key },
            callerProject: { [sessions, state, store] native in BackendTaskProjectScope.callerProject(sessionID: native.sessionID, taskProject: native.sessionID.isEmpty ? nil : try await store.bySession(native.sessionID)?.project, sessionFolder: sessions.manager.list().first { $0.id == native.sessionID }?.cwd, openProjects: state.listProjects().compactMap { $0["path"].string }) },
            callerKeyID: { [authority] native in try await authority.resolve(native).caller.keyID },
            inheritedPermissionMode: { [root] in
                guard let path = try? await root.providers.loginPath(), let provider = try? await root.providers.resolve(.init(cwd: "/", provider: "claude"), loginPath: path) else { return "default" }
                return BackendTAGProfilePolicy.inheritedMode(arguments: provider.args)
            },
            requiresOwnerProfileEdits: { [authority] native in
                let caller = try await authority.resolve(native).caller
                return caller.kind == .key && caller.askFirst != false
            },
            authorizeProfileWidening: { [authority, core] native, args, change in
                let context = try await authority.resolve(native)
                guard context.caller.kind == .key, context.caller.tasks, context.caller.keyID != nil else {
                    throw NativeRPCError(code: "not-granted", message: "This widening request has no current task key.")
                }
                let summary = "\(context.caller.keyName ?? "This AI app") asks to \(change)"
                try await core.control.approveProfileWidening(context: context, arguments: args, summary: summary)
                let current = try await authority.resolve(native)
                guard current.caller.keyID == context.caller.keyID, current.caller.tasks else {
                    throw NativeRPCError(code: "not-granted", message: "The key's access changed while approval was open.")
                }
            },
            requireTaskAction: { [authority, store, weak self] native, tool in
                let caller = try await authority.resolve(native).caller
                if ["tasks.get", "tasks.delegate"].contains(tool), let self,
                   await self.allowsINT2PhoneTasks(caller, mutation: tool != "tasks.get") { return }
                if caller.kind == .local || ["tasks.delegate", "tasks.get"].contains(tool) && caller.kind == .key && caller.tasks { return }
                if caller.kind == .session, let session = caller.sessionID, let worker = try await store.bySession(session), worker.assigneeKind == "agent" { return }
                if caller.kind == .session, await BackendAGTLeadSeats.shared?.address(ofSession: caller.sessionID) != nil { return }   // L4-AGENTS: a lead seat's session
                throw NativeRPCError(code: "not-granted", message: "This task operation needs Hoot or its assigned task agent.")
            }, agentScope: { [authority, store] native in
                // AGENTS-GAP (Asad, 11 Oct: "will every lead agent be able to create its sub agents and modify them?"):
                // Hoot and the owner's own surfaces change every agent (an AI app: as its key's grant allows); a project's
                // lead, its own project's agents; any other session (a seat's agent at work), none.
                let caller = try await authority.resolve(native).caller
                guard caller.kind == .session else { return .everything }
                if let address = await BackendAGTLeadSeats.shared?.address(ofSession: caller.sessionID),
                   let project = BackendAGTLeadSeats.projectID(address) { return .project(project, lead: nil) }   // a session lead
                if let session = caller.sessionID, let worker = try await store.bySession(session),
                   let led = ((try? await BackendPROJRegistry.installed?.projects()) ?? []).first(where: { $0.lead == "agent:" + worker.agentID }) {
                    return .project(led.id, lead: worker.agentID)                                                    // a saved agent that leads
                }
                return .none
            }, widensAgents: { [authority, store] native in
                // Asad, 12 Oct: Hoot has full control except its own settings, so it may widen any agent; a project's lead
                // may widen its own project's agents (the agent scope keeps it there). Keys keep their own rules; others narrow.
                let caller = try await authority.resolve(native).caller
                if caller.kind == .local { return true }
                guard caller.kind == .session else { return false }
                if let address = await BackendAGTLeadSeats.shared?.address(ofSession: caller.sessionID), BackendAGTLeadSeats.projectID(address) != nil { return true }
                if let session = caller.sessionID, let worker = try await store.bySession(session) {
                    return ((try? await BackendPROJRegistry.installed?.projects()) ?? []).contains { $0.lead == "agent:" + worker.agentID }
                }
                return false
            })
        let dependencies = try wired(suppliers, "suppliers").taskDependencies(keyViews: { [core] in await core.keys.list() }, makeCRMKey: { [core] name in
            // A key must name its level (the store refuses one without); a CRM key never opens the MCP doors, and
            // the tasks address lets a CRM key send tasks whatever its level (BackendTaskKeyAccess).
            let result = try await core.keys.create(.object([.init("name", .string(name)), .init("level", .string("look")), .init("crmOnly", .bool(true))]))
            return (try result["id"].requireString("key id"), try result["key"].requireString("key"))
        })
        // tasks.delegate (TS task-tools): a CRM task handed on goes out through the same outbox as the engine's.
        let delegation = BackendTaskDelegation(store: store, configuration: config, local: local, engine: engine,
            outgoing: BackendTaskOutbox.outgoing(store: store, outbox: outbox))
        // Review paperclip (startup check): a failure here leaves only business decisions out, like remote workers.
        // Required tasks then stay held ("Required decision storage is unavailable"), so nothing runs unreviewed.
        do { try await installPCDecisions(persistence: persistence, store: store, local: local, engine: engine) }
        catch { report("Business decisions were not installed: " + error.localizedDescription) }
        await installRemoteWorkers()
        let registration = try await root.installTasks(view: view, local: local, engine: engine, detail: detail, monitor: monitor,
            planning: planning, api: api, delegation: delegation, dependencies: dependencies, authority: tools, knowledge: nil,
            indexed: true, readAttachment: { [authority, files] native, path in
                let rpc = try await authority.rpc(native)
                let file = try await files.authority.authorize(path, context: rpc)
                let bytes = try await BackendCompositionFileBytes.read(file.path, authority: files.authority, context: rpc, maximumBytes: 25 * 1024 * 1024)
                return (file.lastPathComponent, nil, bytes)
            })
        taskRegistration = registration; taskEngine = engine; taskView = view
        if let chats = sessionChats {
            for job in await chats.conversations() where job.job.agentID == "hoot" && job.job.taskID != nil {
                if let taskID = job.job.taskID, try await store.byID(taskID)?.sessionID == job.session.id { await chats.activateTaskJob(job.session.id) }
            }
        }
        try await installTasksPageTools(store: store, local: local, taskAuthority: tools)
        try await installPROJAgentScanning(configuration: config, taskAuthority: tools)
        await installAGTMemory(store: store, config: config, local: local, engine: engine, tools: tools)   // L4 · Deck Memory: seats, clean start, hands
        // Connected task systems (a CRM or tracker read through its MCP server); never takes Tasks down.
        await installConnectedTasks(persistence: persistence, store: store, config: config, local: local, changes: changes, authority: tools)
        try await installINT2AgentsWatch(tasks: view, taskAuthority: tools)
        joins.bindTaskMonitor(monitor, report: report)
        joins.bindTasks(wake: { await engine.nudge() }, stop: { try? await registration.stop() },
            http: NativeCompositionTaskHTTP(api: api, keys: core.keys))
        _ = try await root.installCRM(configuration: config,
            detailOwnership: .alreadyOwnedByTasks(expectedOwnerID: "native-composition:tasks", verifyOwnership: { [root] registry, channel, owner in
                guard registry === root.registry, await registry.registrationOwner(of: channel) == owner else {
                    throw NativeRPCError(code: "composition-conflict", message: "CRM detail is not owned by the retained task registration.")
                }
            }), taskState: { try await view.state() },
            subscribeChanges: { callback in await changes.observe(callback) },
            installSuppliers: { _ in .init(dispatcher: .init(service: detail), supplierLease: NativeRPCSubscription { await detail.stop() }) },
            problem: { [report] in report($0.message) })
        guard let sink = core.log.rawSink else { throw NativeRPCError(code: "composition-incomplete", message: "Routines require Core's actual shared action sink.") }
        let actions = NativeCompositionRoutineActions(sink: sink, report: report)
        var routineOptions = BackendRoutinesServiceOptions(userData: root.dataRoot, state: root.state,
            control: .init(control: core.control),
            mcpConfig: { [core] in core.unattendedConfigPath.path }, copilotRoot: URL(fileURLWithPath: state.copilotRoot()),
            actions: actions, sharedGit: files.watches,
            allowFolder: { [state] path in BackendRoutinesFolderPolicy.problem(path,
                allowedRoots: state.listProjects().compactMap { $0["path"].string } + [state.copilotRoot()]) },
            globalMaxRunsPerHour: { [state] in state.settingsEnvelope()["values"]["routines.maxRunsPerHour"].number ?? 60 },
            hoot: hootRoutineLaunch())
        // SETTINGS-TRUTH row 51: a routine whose "Who does it" is a saved agent becomes a task for that agent.
        routineOptions.agentProfile = { [config] id in try await config.agent(id) }
        let routineReports = routines21Reports(config: config, specs: specs)
        routineOptions.agentRun = routines21AgentRun(local: local, store: store, changes: changes, reports: routineReports)
        routineOptions.reports = routineReports
        let routines = await BackendRoutinesService.create(options: routineOptions)
        // Lifecycle facts come from the one accepted fanout (BackendCompositionEvents publishes
        // session:created / session:status); exits come from the coordinator's ordered observer.
        _ = try await root.installRoutines(service: routines, events: .init(sessionStarted: { [sessions, root] callback in
            for row in sessions.manager.list() { await callback(row) }
            return try await root.registry.subscribe("session:created", ownerID: BackendCompositionRoot.appOwnerID) { event in
                guard let id = event.arguments.first?["id"].string,
                      let meta = sessions.manager.list().first(where: { $0.id == id }) else { return }
                await callback(meta)
            }
        }, sessionStatus: { [root] callback in
            try await root.registry.subscribe("session:status", ownerID: BackendCompositionRoot.appOwnerID) { event in
                guard event.arguments.count >= 2, let id = event.arguments[0].string,
                      let status = event.arguments[1].string.flatMap(BackendSessionStatus.init(rawValue:)) else { return }
                await callback(id, status)
            }
        }, sessionExit: { [sessions] callback in
            let token = await sessions.lifecycle.observe { event in if case .exit(let id, let code) = event { await callback(id, code) } }
            return NativeRPCSubscription { await sessions.lifecycle.removeObserver(token) }
        }))
        await routines.reports.onChanged { [root] id in
            try? await root.registry.publish("routines:reports-changed", arguments: [.string(id)], ownerID: "native-composition:routines")
        }
        routinesOwner = routines
        try await installRoutines21Tools(api: routines.api)
        // Routines "when a task is created / finished": feed real task edges from the
        // one task change hub (never the published tasks:changed event, which would loop).
        // The root keeps the feed until shutdown: a dropped subscription cancels itself at once.
        let taskEvents = BackendROUTINESTaskEvents { [engine = routines.engine] kind, row in await engine.noteTaskEvent(kind: kind, task: row) }
        await taskEvents.accept((try? await store.all()) ?? [])
        let routineTaskChanges = await changes.observe { [store] in await taskEvents.accept((try? await store.all()) ?? []) }
        try await root.retain(.init(name: "routines-task-events", domains: ["routines-task-events"], ownerID: "native.routines-task-events", invokes: [], stop: { await routineTaskChanges.cancelAndWait() }))
    }
}

private struct NativeCompositionTaskHTTP: BackendDeckCoreSecurityTaskHTTP {
    let api: BackendTaskAPI
    let keys: BackendDeckCoreSecurityAccessKeys
    func answer(method: String, path: String, authorization: String?, body: String) async throws -> BackendDeckCoreSecurityHTTPResponse {
        let credential = authorization.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        let key = await keys.match(credential).flatMap { $0["crmOnly"].bool == true || $0["tasks"].bool == true ? $0 : nil }
        // SETTINGS-TRUTH #10: a Look-only key may read its tasks here but not create, assign, cancel or change them,
        // and a key limited to folders may only send work inside them.
        if let key, let refusal = BackendTaskKeyAccess.refusal(key: key, method: method, body: Data(body.utf8)) {
            return .json(.object([.init("error", .object([.init("code", .string("not_allowed")), .init("message", .string(refusal))]))]), status: 403)
        }
        let http = BackendTaskHTTP(api: api, authenticate: { _ in key?["id"].string })
        let result = try await http.handle(method: method, path: path, authorization: authorization, body: Data(body.utf8))
        return .json(result.body, status: result.status)
    }
}
private struct NativeCompositionRoutineActions: BackendRoutinesActionAppending {
    let sink: BackendHootJoinRawSink
    let report: @Sendable (String) -> Void
    func appendRoutineAction(_ value: NativeRPCValue) {
        do { try sink.append(value.setting("at", .string(ISO8601DateFormatter().string(from: Date()))).encodedJSON() + Data([10]), policy: .home(limit: BackendCopilotHome.logLimitBytes)) }
        catch { report("The shared routine action log could not append: " + error.localizedDescription) }
    }
}
private struct NativeCompositionTaskGate: Sendable {
    let store: BackendTaskStore, config: BackendTaskConfiguration, core: BackendDeckCoreRuntime, state: BackendCompositionState
    /// The folders of the person's registered projects, read each time it is asked.
    let registered: @Sendable () async -> [String]
    /// HOOTFIX: the rules live in BackendTaskSessionGate (tested with the real engine); a
    /// handed-back task's kept-open worker can now be stopped, so the queue keeps moving.
    func authorize(_ action: String, _ args: NativeRPCValue) async throws {
        try await BackendTaskSessionGate(store: store, config: config,
            connectionKeyExists: { [core] key in await core.keys.get(id: key) != nil },
            openProjects: { [state] in state.listProjects().compactMap { $0["path"].string } },
            registeredFolders: registered).authorize(action, args)
    }
}

extension NativeCompositionProduction {
    /// SETTINGS-TRUTH lines 71-74: Hoot's routines run on Hoot's own Coding AI, model and effort (its saved ready
    /// choices) and on the account of Hoot's row in Who uses what, resolved by the same account owner as any app-composed
    /// launch (the chat driver's path), and given back after the run.
    func hootRoutineLaunch() -> BackendRoutinesHootSource {
        let root = self.root, sessions = self.sessions, authority = self.authority
        return { inherited in
            guard let sessions else { throw NativeRPCError(code: "unavailable", message: "Hoot's accounts are not ready yet.") }
            let work: @Sendable () async throws -> BackendRoutinesHootLaunch = {
                let home = RNMHootPaths(dataRoot: root.dataRoot).home.path
                let defaults = BackendHootReadyDefaults(settings: root.settings, sessions: sessions, providers: root.providers)
                let selected = try await defaults.read(projectPath: home)
                guard selected.ready, let profile = selected.profile else {
                    throw NativeRPCError(code: "unavailable", message: "Hoot's Coding AI (\(CodingAICatalog.label(selected.provider.rawValue))) has no signed-in account, so its routine did not run. Sign in under Settings › Coding AIs.")
                }
                var input = BackendCreateSessionInput(cwd: home, cols: 80, rows: 24, provider: selected.provider.rawValue)
                input.resume = false; input.profileId = profile.id
                let path = try await root.providers.loginPath()
                let spec = try await root.providers.resolve(input, loginPath: path)
                let context = BackendLaunchContext(rememberTab: false, isAppComposed: true, requiresInAppOwner: true)
                let account = try await sessions.accounts.resolve(input, provider: spec, loginPath: path, context: context)
                // Never a child of an outer session; the account's own variables decide the login.
                var environment = BackendSessionEnvironment.stripInherited(inherited)
                for key in account.removeEnvironment { environment[key] = nil }
                environment.merge(account.environment) { _, next in next }
                environment["PATH"] = account.path
                environment["CLAUDECODE"] = nil
                let settings = selected.launchSettings
                return .init(provider: selected.provider.rawValue, command: spec.command, model: settings.model, effort: settings.effort,
                             fastMode: settings.fastMode, environment: environment, release: { await sessions.accounts.abandon(account) })
            }
            #if TD_HOST_ACCOUNT_BRIDGE
            return try await BackendRoutinesAppProfileScope.withOwner(authority: authority, operation: work)
            #else
            _ = authority
            return try await work()
            #endif
        }
    }
}
