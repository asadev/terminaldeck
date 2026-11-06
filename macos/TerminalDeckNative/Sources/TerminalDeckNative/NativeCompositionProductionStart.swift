import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// The ONE session-tool lease facade: ordinary leases plus the "elsewhere"
    /// leases servers and deck-tools share (never a second endpoint owner).
    func deckToolLeases() throws -> BackendDeckToolsSessionsLeaseFacade {
        if let leaseFacade { return leaseFacade }
        let made = BackendDeckToolsSessionsLeaseFacade(local: try wired(sessions, "sessions").sessionTools, endpoint: try wired(core, "core").sessionEndpoint)
        leaseFacade = made; return made
    }

    /// Before the manifest is sealed: observers and engines whose owners are
    /// installed and whose Node counterparts are disabled by this same manifest.
    /// Order follows TS startup: lifecycle observers, metrics, tasks, routines, machines.
    /// index.ts:5010-5030 at start: the session `open` shim (open-shim.ts writeOpenShim) first on
    /// every session's PATH, then the app map (app-context.ts writeAppContext), which says whether
    /// `open <url>` opens in the app. Both are removed or rewritten at the next start.
    func installOpenShim() async {
        guard let sessions else { return }
        await sessions.launch.setVerbsRegistry(verbs)
        var installed: BackendMacAppHandoffShimInstalled?
        do {
            installed = try await openShim.write(dataRoot: root.dataRoot.path, configPath: sessions.hookEndpoint.configPath)
            sessions.manager.setOpenShim(directory: installed?.directory, browser: installed?.browser)
            #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
            hostManaged?.acceptOpenShim(installed)
            #endif
        } catch { report("The session `open` shim could not be written: " + error.localizedDescription) }
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        let name = BackendCompositionBrowserChannels.thisMachineName()
        let paths = NativePlatformPaths.native(configuration: engineConfiguration, home: configuration.homeDirectory,
            downloads: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0], appRoot: Bundle.main.bundleURL)
        do { _ = try await appContext.write(paths: paths, input: .init(version: version, machineName: name.isEmpty ? "A desktop" : name, opensInApp: installed != nil)) }
        catch { report("The app map for sessions could not be written: " + error.localizedDescription) }
    }

    func startAreas() async throws {
        let files = try wired(self.files, "files"), sessions = try wired(self.sessions, "sessions"),
            authority = try wired(self.authority, "authority"), usage = try wired(self.usage, "usage")
        try await files.startLifecycle(lifecycle: sessions.lifecycle, contextForSession: { [authority] _ in
            try authority.localContext()
        })
        try await usage.startAfterOwnershipTransfer()
        if let taskRegistration { try await taskRegistration.start() }
        if let routinesOwner { try await routinesOwner.start() }
        if let machineOwner { try await machineOwner.start() }
    }

    /// After the bridge is configured and the manifest sealed: dial remote access
    /// if it was left on (TS server.ts autoStart: `remote.enabled` !== false).
    /// Saved tabs are restored when the page first connects (`pageReady`).
    func afterSeal() async {
        startHootAtLaunch()
        // 12 Oct (CRM link): the relay link says in the log when it connects or fails, and a start that is still
        // under way after 30 s says which step it waits on, so "no relay" can be seen next time.
        let report = self.report
        BackendRemoteRelayClient.setLog { line in report(line) }
        guard let remoteHost else { report("remote access: not assembled in this app, so no relay link."); return }
        guard state.settingsEnvelope()["values"]["remote.enabled"].bool != false else { report("remote access: switched off in Settings, so no relay link."); return }
        let watch = Task { try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled else { return }
            let step = await remoteHost.startStep; if step != "running" { report("remote access: still \(step) after 30 s.") } }
        do { _ = try await remoteHost.start() }
        catch { report("remote access did not come up at launch: " + error.localizedDescription) }
        _ = watch
    }

    /// First run ready: Hoot comes up on its own after every app start, once its
    /// tools are sealed in, so nobody has to press Start. It is the same start the
    /// page's "Start Hoot" uses. A Mac with no signed-in Coding AI gets Hoot's honest
    /// "could not start" state instead. Starting the CLI sends nothing to the AI.
    private func installHootFork(_ runtime: BackendCopilotSessionRuntime) async {
        if let chats = sessionChats, let conversations = hoot?.taskConversations, let source = runtime.structuredChat {
            await runtime.setForkHandler { [weak self, root] sequence in
                let child = try await conversations.forkRuntime(source: source, through: sequence)
                do {
                    await self?.installHootFork(child)
                    let state = try await child.ensure()
                    guard state.status == .running else { throw NativeRPCError(code: "unavailable", message: state.problem ?? "The new Hoot conversation could not start.") }
                    var job = BackendTeamChatJob(fromID: "hoot", fromName: "Hoot", agentID: "hoot", agentName: "Hoot", title: "Hoot · fork")
                    job.keepOpen = true
                    let meta = try await chats.exposeTaskRuntime(child, folder: state.folder.runningIn ?? "/", projectID: nil, job: job)
                    let value = try NativeRPCValue.parseJSON(JSONEncoder().encode(meta))
                    try await root.registry.publish("session:created", arguments: [value], ownerID: BackendCompositionRoot.appOwnerID)
                    await MainActor.run {
                        if let row = value.foundation as? [String: Any] { AppModel.shared.buttonActions.created(row); AppModel.shared.select(meta.id) }
                    }
                    return .object([.init("session", value), .init("confirmed", .bool(true)), .init("parentConversationId", .string(source.conversationID))])
                } catch { await child.rest(); throw error }
            }
        }
    }

    func startHootAtLaunch() {
        guard let runtime = hoot?.runtime, runtime.structuredChat != nil else { return }
        let report = self.report
        // Context handoff (L5's button): Hoot writes it in a background turn. Nothing is added to the chat;
        // the document arrives through M1's handoff tool and shows in L5's panel.
        Task { @MainActor in
            // L5: the panel's Stop. With no topic it stops whichever of Hoot's handoffs is running or waiting (the whole
            // conversation, or one "up to" a message: its id is "upto-<event>").
            NativeHandoffActions.cancel = { _, topicID in await runtime.cancelBackgroundTurn(reason: "handoff", id: topicID) }
            NativeHandoffActions.ask = { ownerKey, topicID, topicTitle, progress in
                guard ownerKey == DeckMemoryOwner.hoot.key else {
                    throw NativeRPCError(code: "unavailable", message: "Only Hoot can write a handoff here for now.")
                }
                let turn = BackendHootBackgroundTurn(reason: "handoff", id: topicID ?? "conversation", title: topicTitle,
                                                     message: BackendHootTaskTurns.handoffRequest(topicID: topicID, title: topicTitle))
                let result = try await runtime.backgroundTurn(turn) { step in
                    switch step {
                    case .started: await progress("Hoot is reading what it has on this")
                    case .step(let line): await progress(line)
                    case .text: await progress("Hoot is writing the handoff")
                    }
                }
                guard result.finished else { throw NativeRPCError(code: "failed", message: result.problem ?? "Hoot did not finish the handoff.") }
            }
        }
        // "<seat> answered": when an agent that was @ mentioned in Hoot's chat answers (L8's signal), one line goes under that message.
        if let chat = runtime.structuredChat {
            NotificationCenter.default.addObserver(forName: .hootMentionAnswered, object: nil, queue: .main) { note in
                guard let answer = note.userInfo?["answer"] as? BackendHootMentionAnswer else { return }
                Task { await chat.noteAnswer(answer.wireValue) }
            }
        }
        Task { await installHootFork(runtime) }
        // The chat's Rewind and Undo (Hoot page and island): back to a message, the desk rebuilt up to there.
        Task { @MainActor in
            HootChatActions.handoffConversation = { id, prompt, progress in
                let result = try await runtime.backgroundTurn(.init(reason: "handoff", id: "session:" + id, title: "Chat context handoff", message: prompt)) { step in
                    switch step {
                    case .started: await progress("Hoot is reading this conversation")
                    case .step(let line): await progress(line)
                    case .text: await progress("Hoot is writing the handoff")
                    }
                }
                guard result.finished else { throw NativeRPCError(code: "failed", message: result.problem ?? "Hoot did not finish the handoff.") }
            }
            HootChatActions.fork = { sequence in try await runtime.forkChat(through: sequence) }
            HootChatActions.rewind = { sequence in try await runtime.rewindChat(to: sequence) }
            HootChatActions.undoRewind = { try await runtime.undoRewindChat() }
            HootChatActions.handoffUpTo = { sequence, progress in
                let result = try await runtime.handoffTurn(upTo: sequence) { step in
                    switch step {
                    case .started: await progress("Hoot is reading the conversation up to that message")
                    case .step(let line): await progress(line)
                    case .text: await progress("Hoot is writing the handoff")
                    }
                }
                guard result.finished else { throw NativeRPCError(code: "failed", message: result.problem ?? "Hoot did not finish the handoff.") }
            }
        }
        #if DEBUG
        // Dev copy only: take the builders' old test exchanges out of the person's chat (kept in the chat file).
        DevReload.hootTidy = {
            let marks = ["Build-lane memory check", "Dev check from L6"]
            do {
                var gone = try await runtime.setAsideExchanges(reason: "builders' test messages") { text in marks.contains { text.hasPrefix($0) } }
                // And the builders' own background turns (the dev test door, the scratch tasks named in the request).
                let turns = DevReload.hootTidyTurns
                gone += try await runtime.setAsideTurns(reason: "builders' test turns") { turn in turn.hasPrefix("bg:dev-test:") || turns.contains { !$0.isEmpty && turn.hasPrefix($0) } }
                return "took out " + String(gone) + " exchange(s) or turn(s)"
            } catch { return "could not: " + error.localizedDescription }
        }
        // Dev copy only: measure the records fence many times in a row (it starts no session).
        let records = runtime.installedRecords, data = root.dataRoot.path
        DevReload.fenceProbe = { count in
            var missed = 0, reasons: [String: Int] = [:]
            let began = Date()
            for _ in 0..<max(1, min(count, 500)) {
                let measured = await records.measure(userData: data)
                if measured.fence == nil { missed += 1; reasons[String((measured.reason ?? "?").suffix(70)), default: 0] += 1 }
            }
            return "not held \(missed) of \(count) in \(String(format: "%.1f", Date().timeIntervalSince(began))) s \(reasons)"
        }
        // Dev copy only: the builders' test door (DevReload "TerminalDeckDevHootSay"). A background turn, so
        // nothing shows in the person's chat and the diary knows it was a test.
        DevReload.hootTest = { text in
            do {
                let result = try await runtime.backgroundTurn(.init(reason: "dev-test", id: "check", title: "Build check", message: text))
                return result.finished ? result.answer : "(not finished: " + (result.problem ?? "stopped") + ") " + result.answer
            } catch { return "(could not ask Hoot: " + error.localizedDescription + ")" }
        }
        #endif
        Task {
            // Every later stop is logged with its reason and Hoot restarts quietly.
            await runtime.setReporter(report)
            do {
                let started = try await runtime.ensure()
                report(started.status == .running ? "Hoot is awake (started at launch)"
                    : "Hoot did not start at launch: " + (started.problem ?? "it stopped"))
            } catch { report("Hoot did not start at launch: " + error.localizedDescription) }
            // An @ mention answered while the app was closed: read it from its task and draw "<seat> answered" now, or as
            // soon as the delivery service is installed if it is not yet (never dependent on which starts first).
            if let chat = runtime.structuredChat {
                let pass = BackendHootLateAnswers(chat: chat)
                let token = NotificationCenter.default.addObserver(forName: .hootMentionDeliveryReady, object: nil, queue: .main) { _ in
                    Task { await pass.runOnce() }
                }
                pass.keep(token)
                await pass.runOnce()
            }
            await self.continueAfterRestart()   // L8: what this restart interrupted goes on by itself
        }
    }

    /// TS index.ts hydrateRenderer: the first page to connect restores the saved
    /// tabs (an event sent before the page listens is dropped, not queued); every
    /// later page load (a reload) is re-told every live session and the held rows.
    func pageReady() async {
        if !restoreStarted {
            if let hostCore, !hostCore.mayRestore {
                report("Saved-session restore is paused while kept sessions are unavailable.")
            } else {
                restoreStarted = true
                do {
                    let sessions = try wired(self.sessions, "sessions")
                    #if TD_HOST_ACCOUNT_BRIDGE
                    // The real current app page's recovery owner authorizes this call.
                    let result = try await BackendHOSTProfileScope.withContext(wired(authority, "authority").localContext()) {
                        try await sessions.restoreSavedSessions()
                    }
                    #else
                    let result = try await sessions.restoreSavedSessions()
                    #endif
                    for decision in result.decisions where decision.outcome == .skip || decision.outcome == .failed {
                        report("restore held a " + decision.session.provider + " tab: " + decision.reason)
                    }
                    report("restore: \(result.started.count) started, \(result.decisions.count) planned")
                } catch { report("Saved sessions could not be restored: " + error.localizedDescription) }
            }
        } else if let devices {
            await devices.pageGone()   // TS devices/ipc.ts: a full reload never asked for the old page's pictures
        }
        guard let sessions else { unwired("sessions"); return }
        for meta in sessions.manager.list() {
            try? await root.registry.publish("session:created", arguments: [BackendCompositionSuppliers.sessionWire(meta)])
        }
        if let held = try? await root.state.heldSessions() {
            try? await root.registry.publish("sessions:held", arguments: [.array(held.map(\.wireValue))])
        }
        // 22 Oct (Reviewer, finding 5): finished jobs a running helper still lists from before this start leave the
        // list after restore, once the page shows its tabs, so the job that was the active tab at quit stays.
        if !finishedJobsSwept, let chats = sessionChats {
            finishedJobsSwept = true
            let listed = Set(sessions.manager.list().map(\.id))
            Task { @MainActor in
                if !listed.isEmpty {
                    _ = await NativeBrowserSignalWait.until(timeout: .seconds(30)) {
                        AppModel.shared.tabs?.tabs.contains { listed.contains($0.id) } == true
                    }
                }
                await chats.retireFinishedJobs()
            }
        }
    }

    /// L8 (11 Oct): a start that failed part-way must give back what it took, or the app's own retry fails
    /// on the leftovers. `stop()` below is written for a quit (the process ends); this closes what only a
    /// process exit used to release: the remote trust lease, the machine store's lease, and the process-wide
    /// owners this attempt installed (they point at the failed attempt's sessions).
    func releaseAfterFailedStart() async {
        root.events.bind(remote: nil)
        if let remoteEndpoint { await remoteEndpoint.stop() }      // closes the trust store with it
        await remoteTrust?.close(); remoteTrust = nil; remoteEndpoint = nil
        await machineStore?.close(); machineStore = nil
        DeckMemorySessionCenter.shared?.stop(); DeckMemorySessionCenter.shared = nil
        BackendHootMentionDelivery.shared = nil
        BackendHOSTKeepDetachPreparation.register("hoot", nil)
        #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
        // The quit after a failed start must not find this attempt's helper owner (2 Nov 06:37 dev-copy abort).
        if let hostManaged, NativeCompositionINT2HOSTManaged.current === hostManaged { NativeCompositionINT2HOSTManaged.current = nil }
        #endif
    }

    /// Unretained services the backend's area shutdown does not own.
    func stop() async {
        await tagConsentOwnerActivity?.stop(); tagConsentOwnerActivity = nil
        linkTabWindow.stop()
        await releaseServerControlOwner(BackendCompositionRoot.appOwnerID)
        if hostCore?.preservingHosted != true {
            sessions?.manager.setOpenShim(directory: nil, browser: nil); try? await openShim.remove(dataRoot: root.dataRoot.path)
        }
        let trace: @Sendable (String) -> Void = { NativeCompositionRoot.note("quit: " + $0) }
        if let remoteHost { await BackendCompositionRoot.traced("remote host", trace) { await remoteHost.stop() } }
        if let leaseFacade { await BackendCompositionRoot.traced("server leases", trace) { await leaseFacade.stop() } }
    }

    /// TS remote/server.ts: registration starts only after the host endpoint is up.
    func startRemoteRegistration() async throws {
        guard let remoteRegistration else { throw NativeRPCError(code: "composition-incomplete", message: "Remote serving is not registered.") }
        // The relay link checks itself on wake/unlock whenever remote serving runs, not only with phone Devices
        // installed (Reviewer, 31 Oct).
        await MainActor.run { NativeRelayWake.install() }
        try await remoteRegistration.start()
    }
}

/// The late-answer pass at Hoot's start, run once when the delivery service is there (now or when it is installed).
private actor BackendHootLateAnswers {
    private let chat: BackendHootChatStore
    private var done = false
    nonisolated(unsafe) private var token: NSObjectProtocol?
    init(chat: BackendHootChatStore) { self.chat = chat }
    nonisolated func keep(_ token: NSObjectProtocol) { self.token = token }
    func runOnce() async {
        guard !done, let delivery = BackendHootMentionDelivery.shared else { return }
        done = true
        if let token { NotificationCenter.default.removeObserver(token); self.token = nil }
        for receipt in await chat.receiptsWithoutAnswer() {
            if let answer = await delivery.answer(receiptID: receipt) { await chat.noteAnswer(answer.wireValue) }
        }
    }
}
