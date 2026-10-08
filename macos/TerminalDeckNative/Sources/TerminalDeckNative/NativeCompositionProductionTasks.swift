import Foundation
import AppKit
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installTasksAndRoutines() async throws {
        let scopeRequests = BackendTAGAccessScope(keys: core.keys)
        try joins.replaceContributions(owner: "tag-access", [try scopeRequests.bundle()])
        let persistence = try BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote"), ownership: root.state.ownership)
        // One change hook for store/config/goals/outbox; the CRM registration is its
        // only subscriber and publishes `tasks:changed` once per change (TS deck-control
        // index.ts:731 broadcast). Never subscribe to the published event itself (a loop).
        let changes = BackendCompositionChangeHub()
        let store = BackendTaskStore(persistence: persistence, changed: { await changes.fire() })
        let config = try BackendTaskConfiguration(persistence: persistence, changed: { await changes.fire() })
        let goals = BackendGoalStore(persistence: persistence, changed: { await changes.fire() })
        try await store.start(); try await config.start(); try await goals.start()
        let ags: NativeCompositionINT2AGS?
        if SourceNamespace.agentSettingsEnabled {
            ags = try await installINT2AGS(configuration: config)
        } else {
            ags = nil
        }
        let outbox = BackendTaskOutbox(persistence: persistence, target: { [config, core] key in
            guard let current = await core!.keys.get(id: key), current["crmOnly"].bool == true || current["tasks"].bool == true,
                  let connection = try await config.connection(key), connection["enabled"].bool == true,
                  let address = connection["eventsUrl"].string, let url = URL(string: address),
                  let secret = connection["eventsSecret"].string else { return nil }
            return try BackendTaskWebhookTarget(url: url, signingSecret: secret)
        }, onCommentID: { [store] id, comment in try await store.markOurs(keyID: id, eventID: comment) },
            changed: { await changes.fire() }, problem: { [report] in report($0) })
        let gate = NativeCompositionTaskGate(store: store, config: config, core: core, state: state)
        let specs = try BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote/task-briefs"), ownership: root.state.ownership)
        let access = BackendTaskSessionDriver.access(lifecycle: sessions.lifecycle, manager: sessions.manager, specs: specs,
            authorize: { try await gate.authorize($0, $1) }, environment: { [root, configuration] in
                var env = configuration.inheritedEnvironment; env["PATH"] = try await root.providers.loginPath(); return env
            }, setControl: { [joins] id, control, value in try await joins.setAgentControl(sessionID: id, control: control, value: value) },
            noteTurn: { [joins] id in await joins.noteTaskSend(id) },
            // TS task-engine.ts tellHoot: Hoot's own session (started if need be), the brief typed
            // into it as one line, exactly as deliverBrief does for every brief.
            tellHoot: { [weak self] text in
                let owners = await MainActor.run { (self?.hoot, self?.coreSurface) }
                guard let hoot = owners.0, let surface = owners.1 else {
                    throw NativeRPCError(code: "unavailable", message: "Hoot is not running on this Mac, so this task is waiting for it.")
                }
                let state = try await hoot.runtime.ensure()
                guard let session = state.sessionId else { throw NativeRPCError(code: "unavailable", message: "Hoot is not running on this Mac, so this task is waiting for it.") }
                let line = text.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
                _ = try await surface.deliverBrief(session, line: line)
            }, bindTaskSession: { [store, sessions] task, session in
                let live = Set(sessions!.manager.list().filter { $0.exitCode == nil }.map(\.id))
                guard try await store.claim(task.id, sessionID: session.id, liveSessionIDs: live, expectedAssignee: task.value["assignee"]) else {
                    throw NativeRPCError(code: "task-already-held", message: "Another live session already holds this task. The new session was stopped.")
                }
            })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { [files, authority] task in
                guard let workspaces = files!.workspaces else { throw BackendSessionFailure.missingCapability("the native task workspace owner") }
                return try await workspaces.folderFor(taskID: task.id, project: task.project,
                    useWorkspace: task.value["useWorkspace"].bool == true, title: task.value["title"].string ?? "",
                    context: authority!.localContext()) ?? task.project
            }, outgoing: BackendTaskOutbox.outgoing(store: store, outbox: outbox), notifications: { [core] task, event in
                if let ags { await ags.events.task(event) }
                try await core!.notifications.taskNotifications(task, event)
            }, problem: { [report] in report($0) })
        let local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: engine)
        await root.installReceiver(tasks: local, configuration: config, sessions: sessions, appName: configuration.appName,
            hook: { event in if let ags { await ags.events.receiver(id: event.id) } }) // RCV
        let attachments = BackendTaskAttachments(persistence: persistence,
            authorizeSource: { [files, authority] path in try await files!.authority.authorize(path, context: authority!.localContext()) })
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
        let answers = BackendTaskTranscriptAnswers { [sessions, joins] meta in
            guard meta.provider == "claude", let id = meta.agentSessionId else { return nil }
            var scope = try await joins.accountTranscriptScope()
            if let row = await sessions!.lifecycle.metadata().first(where: { $0.session.id == meta.id }), let directory = row.transcriptConfiguration {
                scope.configDirectory = directory; scope.additionalConfigDirectories = []; scope.deviceHomesRoot = nil
            }
            for folder in try NativeTranscriptPaths.projectDirectories(meta.cwd, scope: scope) {
                if let file = try NativeTranscriptPaths.listTranscripts(folder, scope: scope).first(where: { $0.sessionID == id }) { return .init(path: file.path, scope: scope) }
            }
            return nil
        }
        let monitor = BackendTaskTurnMonitor(store: store, engine: engine, manager: sessions.manager,
            answer: { try await answers.latest($0) }, problem: { [report] in report($0) })
        let view = BackendTaskStateView(store: store, configuration: config, goals: goals, outbox: outbox,
            keyViews: { [core] in await core!.keys.list() })
        let planning = BackendGoalPlanning(goals: goals, tasks: store, configuration: config, local: local, detail: detail)
        let api = BackendTaskAPI(store: store, configuration: config, engine: engine)
        let tools = BackendTaskToolAuthority(requireTasks: { [authority, store, weak self] native in
            let caller = try await authority!.resolve(native).caller
            if let self, await self.allowsINT2PhoneTasks(caller, mutation: false) { return }
            let worker = caller.sessionID == nil ? nil : try await store.bySession(caller.sessionID!)
            guard caller.kind == .local || caller.kind == .key && caller.tasks || caller.kind == .session && worker != nil else { throw NativeRPCError(code: "not-granted", message: "This caller has no task grant.") }
        }, requireHoot: { [authority, joins, weak self] native in
            let caller = try await authority!.resolve(native).caller
            let (tool, args) = try await joins.nativeTool(native)
            let readingGoals = tool == "tasks.goals" && ["list", "get"].contains(args["do"].string ?? "list") || tool == "tasks.progress"
            if let self, await self.allowsINT2PhoneTasks(caller, mutation: !readingGoals) { return }
            guard caller.kind == .local else { throw NativeRPCError(code: "not-granted", message: "This task operation belongs to Hoot.") }
        }, visible: { [authority, store, weak self] native, task in
            let caller = try await authority!.resolve(native).caller
            if caller.kind == .local { return true }
            if caller.kind == .remote {
                guard task.isLocal, let self else { return false }
                return await self.allowsINT2PhoneTasks(caller, mutation: false, project: task.project)
            }
            if caller.kind == .key {
                guard caller.tasks, task.isLocal || task.value["keyId"].string == caller.keyID else { return false }
                return caller.folders == nil || caller.folders!.contains { BackendCompositionAuthority.within(task.project, $0) }
            }
            guard caller.kind == .session, let session = caller.sessionID, let worker = try await store.bySession(session) else { return false }
            return task.sessionID == session || task.value["parentTaskId"].string == worker.id || (worker.value["reviewOfTaskId"].string == task.id && task.value["reviewerTaskId"].string == worker.id)
        }, project: { [authority] native, path in _ = try await authority!.knownFolder(path, native: native) },
            authorize: { [joins, authority, store, goals, weak self] native, tool, args, tier in
                try await joins.prepareNative(native, tier: tier, sentence: "Use " + tool, ownerMustAnswer: tier != .read)
                let caller = try await authority!.resolve(native).caller
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
            actorName: { [authority, store] native in
                let caller = try await authority!.resolve(native).caller
                if caller.kind == .session, let session = caller.sessionID, let worker = try await store.bySession(session) { return "taskagent:" + worker.agentID }
                return caller.kind == .local ? "hoot" : BackendTaskActor.appActor(caller.keyName ?? "AI app")
            },
            crmKeyID: { [authority] native in guard let key = try await authority!.resolve(native).caller.keyID else { throw NativeRPCError(code: "not-granted", message: "This caller is not a CRM key.") }; return key },
            callerProject: { [sessions, state, store] native in BackendTaskProjectScope.callerProject(sessionID: native.sessionID, taskProject: native.sessionID.isEmpty ? nil : try await store.bySession(native.sessionID)?.project, sessionFolder: sessions!.manager.list().first { $0.id == native.sessionID }?.cwd, openProjects: state.listProjects().compactMap { $0["path"].string }) },
            callerKeyID: { [authority] native in try await authority!.resolve(native).caller.keyID },
            inheritedPermissionMode: { [root] in
                guard let path = try? await root.providers.loginPath(), let provider = try? await root.providers.resolve(.init(cwd: "/", provider: "claude"), loginPath: path) else { return "default" }
                return BackendTAGProfilePolicy.inheritedMode(arguments: provider.args)
            },
            requireTaskAction: { [authority, store, weak self] native, tool in
                let caller = try await authority!.resolve(native).caller
                if ["tasks.get", "tasks.delegate"].contains(tool), let self,
                   await self.allowsINT2PhoneTasks(caller, mutation: tool != "tasks.get") { return }
                if caller.kind == .local || ["tasks.delegate", "tasks.get"].contains(tool) && caller.kind == .key && caller.tasks { return }
                if caller.kind == .session, let session = caller.sessionID, let worker = try await store.bySession(session), worker.assigneeKind == "agent" { return }
                throw NativeRPCError(code: "not-granted", message: "This task operation needs Hoot or its assigned task agent.")
            })
        let dependencies = try suppliers.taskDependencies(keyViews: { [core] in await core!.keys.list() }, makeCRMKey: { [core] name in
            let result = try await core!.keys.create(.object([.init("name", .string(name)), .init("crmOnly", .bool(true))]))
            return (try result["id"].requireString("key id"), try result["key"].requireString("key"))
        })
        // tasks.delegate (TS task-tools): a CRM task handed on goes out through the same outbox as the engine's.
        let delegation = BackendTaskDelegation(store: store, configuration: config, local: local, engine: engine,
            outgoing: BackendTaskOutbox.outgoing(store: store, outbox: outbox))
        let registration = try await root.installTasks(view: view, local: local, engine: engine, detail: detail, monitor: monitor,
            planning: planning, api: api, delegation: delegation, dependencies: dependencies, authority: tools, knowledge: nil,
            indexed: true, readAttachment: { [authority, files] native, path in
                let rpc = try await authority!.rpc(native)
                let file = try await files!.authority.authorize(path, context: rpc)
                let bytes = try await BackendCompositionFileBytes.read(file.path, authority: files!.authority, context: rpc, maximumBytes: 25 * 1024 * 1024)
                return (file.lastPathComponent, nil, bytes)
            }, oldTaskOwnerDisabled: true)
        taskRegistration = registration; taskEngine = engine; taskView = view
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
        let routines = await BackendRoutinesService.create(options: .init(userData: root.dataRoot, state: root.state,
            control: .init(control: core.control), providers: BackendRoutinesNativeProviderAdapter(providers: root.providers),
            mcpConfig: { [core] in core!.unattendedConfigPath.path }, copilotRoot: URL(fileURLWithPath: state.copilotRoot()),
            actions: actions, sharedGit: files.watches,
            allowFolder: { [state] path in (state.listProjects().compactMap { $0["path"].string } + [state.copilotRoot()]).first { BackendCompositionAuthority.within(path, $0) } },
            globalMaxRunsPerHour: { [state] in state.settingsEnvelope()["values"]["routines.maxRunsPerHour"].number ?? 60 }))
        // Lifecycle facts come from the one accepted fanout (BackendCompositionEvents publishes
        // session:created / session:status); exits come from the coordinator's ordered observer.
        _ = try await root.installRoutines(service: routines, events: .init(sessionStarted: { [sessions, root] callback in
            for row in sessions!.manager.list() { await callback(row) }
            return try await root.registry.subscribe("session:created", ownerID: BackendCompositionRoot.appOwnerID) { event in
                guard let id = event.arguments.first?["id"].string,
                      let meta = sessions!.manager.list().first(where: { $0.id == id }) else { return }
                await callback(meta)
            }
        }, sessionStatus: { [root] callback in
            try await root.registry.subscribe("session:status", ownerID: BackendCompositionRoot.appOwnerID) { event in
                guard event.arguments.count >= 2, let id = event.arguments[0].string,
                      let status = event.arguments[1].string.flatMap(BackendSessionStatus.init(rawValue:)) else { return }
                await callback(id, status)
            }
        }, sessionExit: { [sessions] callback in
            let token = await sessions!.lifecycle.observe { event in if case .exit(let id, let code) = event { await callback(id, code) } }
            return NativeRPCSubscription { await sessions!.lifecycle.removeObserver(token) }
        }))
        routinesOwner = routines
    }
}

private struct NativeCompositionTaskHTTP: BackendDeckCoreSecurityTaskHTTP {
    let api: BackendTaskAPI
    let keys: BackendDeckCoreSecurityAccessKeys
    func answer(method: String, path: String, authorization: String?, body: String) async throws -> BackendDeckCoreSecurityHTTPResponse {
        let http = BackendTaskHTTP(api: api, authenticate: { [keys] authorization in
            let credential = authorization.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
            guard let key = await keys.match(credential), key["crmOnly"].bool == true || key["tasks"].bool == true else { return nil }
            return key["id"].string
        })
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
    func authorize(_ action: String, _ args: NativeRPCValue) async throws {
        let rows = try await store.all()
        let task: BackendTaskRecord?
        if let id = args["task"].string { task = rows.first { $0.id == id } }
        else if let id = args["sessionId"].string { task = rows.first { $0.sessionID == id } }
        else if action == "tasks.check", let command = args["command"].string {
            var match: BackendTaskRecord?
            for row in rows { if let agent = try await config.agent(row.agentID), agent["verifyCommand"].string == command,
                row.project == args["cwd"].string { match = row; break } }
            task = match
        } else { task = nil }
        guard ["sessions.start", "sessions.send", "sessions.stop", "agents.set_control", "tasks.check"].contains(action),
              let task, let agent = try await config.agent(task.agentID), agent["status"].string != "paused", agent["status"].string != "archived" else {
            throw NativeRPCError(code: "access-denied", message: "This operation has no current configured task/agent owner.")
        }
        if !task.isLocal {
            guard let key = task.value["keyId"].string, await core.keys.get(id: key) != nil,
                  let connection = try await config.connection(key), connection["enabled"].bool == true else {
                throw NativeRPCError(code: "access-denied", message: "This task's connection grant was removed or disabled.")
            }
        }
        guard state.listProjects().contains(where: { $0["path"].string == task.project }) else {
            throw NativeRPCError(code: "access-denied", message: "The task's project is no longer open.")
        }
        if action == "sessions.start" {
            guard args["provider"] == agent["provider"], args["account"] == agent["account"] else {
                throw NativeRPCError(code: "access-denied", message: "This launch does not match the configured task agent.")
            }
        }
    }
}
