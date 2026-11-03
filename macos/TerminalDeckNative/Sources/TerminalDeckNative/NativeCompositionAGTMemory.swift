import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// L4 AGENTS · Deck Memory: which seat a terminal session sits in (a project's lead seat, a role
/// seat, or none), the clean start for a new job, and the hands on a seat (spec 3a, 3b). Reads the
/// project registry (who leads) and the agent profiles (which role). L8 HOST reads
/// `BackendAGTMemoryOwners.shared` for every session and registers M1's session resolver from it.
extension NativeCompositionProduction {
    func installAGTMemory(store: BackendTaskStore, config: BackendTaskConfiguration, local: BackendTaskLocalService,
                          engine: BackendTaskEngine, tools: BackendTaskToolAuthority) async {
        let registry = root.registry, authority = self.authority, report = self.report
        let projects: BackendAGTMemoryOwners.Projects = {
            guard let authority else { return [] }
            return (try? await Self.registeredProjects(registry: registry, context: authority.localContext())) ?? []
        }
        let owners = BackendAGTMemoryOwners(projects: projects,
            agents: { (try? await config.allAgents()) ?? [] },
            taskAgent: { id in (try? await store.byID(id))?.agentID },
            taskSeat: { id in
                guard let task = try? await store.byID(id) else { return nil }
                if let role = task.value[BackendAGTHandsService.taskSeatField].string { return role }
                // The helper's session can start before its task record carries the seat.
                return await BackendAGTHands.shared.helperRole(agent: task.agentID, title: task.value["title"].string)
            })
        BackendAGTMemoryOwners.shared = owners
        // A deleted agent never stays a project's lead: cleared when it is deleted, and once at start (for one
        // deleted before this existed). The lead seat keeps its memory and shows as vacant with memory.
        await config.setAgentRemoved { [report] id in
            do { try await BackendPROJRegistry.installed?.clearLeads { $0 == id } } catch { report("The deleted agent is still named as a project's lead: " + error.localizedDescription) }
        }
        // Only ids absent from the saved file: an agent that merely did not read this time (another build) keeps its lead.
        if let ids = try? await config.savedAgentIDs() {
            _ = try? await BackendPROJRegistry.installed?.clearLeads { !ids.contains($0) }
        }
        // A new hire with an id used before starts with no runs of the agent that had it (runs kept, retired).
        await config.setHistoryRetirement { [report] id in
            do { try await store.retireAgentHistory(id) } catch { report("An old agent's run history could not be set aside: " + error.localizedDescription) }
        }
        BackendAGTJobStart.shared = BackendAGTJobStart(projects: projects)

        // 3b: hands. A hand's job is its task's title. A short-lived helper seat folds back into its
        // parent when its last session is removed: M2 FLOW does that (after its helper has read the
        // session's last words), so nothing is folded from here.
        await BackendAGTHands.shared.bind(taskTitle: { id in (try? await store.byID(id))?.value["title"].string }, seatEmptied: { _ in })
        let manager = sessions?.manager, lifecycle = sessions?.lifecycle
        BackendAGTHandsService.shared = BackendAGTHandsService(.init(projects: projects,
            agent: { try await config.agent($0) },
            saveAgent: { _ = try await config.saveAgent($0) },
            createTask: { input, by in try await local.create(input, by: by).id },
            patchTask: { id, patch in _ = try await store.update(id, patch: patch) },
            nudge: { await engine.nudge() },
            sessions: {
                let all = await projects()
                return (manager?.list() ?? []).filter { $0.exitCode == nil }.map {
                    ($0.id, $0.title, PROJProjects.resolve(projectID: $0.projectId, folder: $0.cwd, projects: all))
                }
            },
            tell: { id, text in
                guard let lifecycle, let manager else { throw NativeRPCError(code: "unavailable", message: "Sessions are not running.") }
                // #23: the checked typing a task brief uses (prompt ready, text seen, then Return), never a raw write.
                try await BackendTaskBriefDelivery.deliver(id, line: text, manager: manager, write: { data in try await lifecycle.write(sessionID: id, data: data) })
            }))
        await installAGTLeadSeats(store: store, config: config, local: local, engine: engine, projects: projects)
        // L8's session centre: every session that fills a seat is a numbered hand.
        DeckMemorySessionCenter.shared?.bind { services in
            services.owner = { input, provider in await owners.owner(input, provider: provider) }
            services.joinHand = { sessionID, seat, job, taskID in
                guard let owner = BackendAGTMemoryOwners.memoryOwner(seat) else { return nil }
                let hand = await BackendAGTHands.shared.join(sessionID: sessionID, seat: owner, job: job, taskID: taskID)
                return (hand.number, hand.job.isEmpty ? nil : hand.job)
            }
            services.leaveHand = { id in await BackendAGTHands.shared.leave(sessionID: id) }
        }
        // The tools: agents.hands, agents.add_hand (asks first), agents.request_hands.
        do {
            let owner = "native-composition:agents-hands", mcp = root.mcp, joins = self.joins
            try await BackendAGTHandsMCP.install(server: mcp, ownerID: owner, authority: tools, service: { BackendAGTHandsService.shared })
            let registered = await mcp.registrations().filter { BackendAGTHandsMCP.ids.contains($0.0.id) }
            let metadata = registered.map { BackendDeckCoreCatalogueMetadata(tool: $0.0, title: $0.0.description, index: $0.0.description) }
            let policies = zip(metadata, registered).map { joins.mcpPolicy($0.0, handler: $0.1.1) }
            try joins.replaceContributions(owner: owner, [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
            try await root.retain(.init(name: "agents-hands", domains: ["agents-hands"], ownerID: owner, invokes: [], sends: [], events: [], stop: {
                try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
                await mcp.removeTools(ownerID: owner)
            }))
        } catch { report("Agent hands tools could not start: " + error.localizedDescription) }
    }

    /// A project's lead SEAT as a task holder (a lead that is a plain session can be given a task and
    /// asked from a task comment). The seat's session is told with the checked typing a task brief uses.
    private func installAGTLeadSeats(store: BackendTaskStore, config: BackendTaskConfiguration, local: BackendTaskLocalService,
                                     engine: BackendTaskEngine, projects: @escaping BackendAGTMemoryOwners.Projects) async {
        guard let sessions else { return }
        let manager = sessions.manager, lifecycle = sessions.lifecycle, report = self.report
        var seatDeps = BackendAGTLeadSeats.Dependencies.live(store: store, engine: engine, local: local, configuration: config, projects: projects,
            sessions: {
                let all = await projects()
                return manager.list().filter { $0.exitCode == nil }.map {
                    .init(id: $0.id, title: $0.title, projectID: PROJProjects.resolve(projectID: $0.projectId, folder: $0.cwd, projects: all), provider: $0.provider)
                }
            },
            tell: { id, line in
                try await BackendTaskBriefDelivery.deliver(id, line: line, manager: manager, write: { text in try await lifecycle.write(sessionID: id, data: text) })
            })
        // SETTINGS-TRUTH row 48: "Hoot leads for now" (saved by the New project guide) is read each time a seat is asked.
        seatDeps.hootLeads = { [root] id in await root.settings.projectSettings(id)["values"][PROJSetup.hootLeadsKey].bool == true }
        let seats = BackendAGTLeadSeats(seatDeps)
        BackendAGTLeadSeats.shared = seats
        await seats.refreshNames()
        do {
            // Pushed events only: a session going calm takes what waits for its seat; one ending puts
            // what it had been told back to waiting.
            await seats.retain([
                try await root.registry.subscribe("session:status", ownerID: BackendCompositionRoot.appOwnerID) { event in
                    guard event.arguments.count >= 2, let id = event.arguments[0].string,
                          ["idle", "waiting", "completed"].contains(event.arguments[1].string ?? "") else { return }
                    Task { await seats.calm(sessionID: id) }
                },
                try await root.registry.subscribe("session:exit", ownerID: BackendCompositionRoot.appOwnerID) { event in
                    guard let id = event.arguments.first?.string else { return }
                    Task { await seats.ended(sessionID: id) }
                },
            ])
        } catch { report("Lead seats could not listen for sessions: " + error.localizedDescription) }
        // What was waiting when the app closed is told to whoever fills each seat now.
        Task { await seats.sweep() }
    }
}
