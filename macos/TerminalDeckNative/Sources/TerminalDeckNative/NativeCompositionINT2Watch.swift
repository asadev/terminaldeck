import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installINT2AgentsWatch(tasks: BackendTaskStateView, taskAuthority: BackendTaskToolAuthority) async throws {
        let authority = try wired(self.authority, "authority"), registry = root.registry, sessions = try wired(self.sessions, "sessions")
        let activity = AWAgentsWatchActivity(changed: {
            try? await registry.publish("agents-watch:changed", arguments: [], ownerID: BackendCompositionRoot.appOwnerID)
        })
        // AGT: the AI typed by hand into a shell tab is remembered on that tab (survives restarts).
        let shells = BackendAGTShellAgents(dataRoot: root.dataRoot, changed: {
            Task { try? await registry.publish(BackendAGTShellAgents.changedEvent, arguments: [], ownerID: BackendCompositionRoot.appOwnerID) }
        })
        BackendAGTShellAgents.install(shells)
        let lifecycle = sessions.lifecycle
        let hookToken = await sessions.hookCoordinator.observeAccepted { event in
            await activity.accept(event)
            if let id = event.sessionID { shells.accept(event, session: authority.sessionViews().first { $0["id"].string == id }) }
        }
        let lifecycleToken = await sessions.lifecycle.observe { event in
            switch event {
            case .removed(let id, _), .exit(let id, _):
                await activity.remove(id)
            case .status(let id, _):
                // A shell tab's screen changed state: look once at its own process tree (throttled per tab).
                if let row = authority.sessionViews().first(where: { $0["id"].string == id }), row["provider"].string == "shell" {
                    shells.scan(session: row, rootPID: lifecycle.manager.pidOf(id))
                }
            default: break
            }
        }
        let hoot = AWAgentsWatchNativeSource.StructuredHoot(require: { caller in
            switch caller {
            case .app(let rpc): try authority.requireLocalUI(rpc)
            case .mcp(let native):
                guard try await authority.resolve(native).caller.kind == .local else {
                    throw NativeRPCError(code: "not-granted", message: "Hoot's conversation belongs to the app owner.")
                }
            }
        }, read: { [weak self] _ in
            guard let runtime = await MainActor.run(body: { self?.hoot?.runtime }), let chat = runtime.structuredChat else {
                throw NativeRPCError(code: "unavailable", message: "Hoot's structured conversation is not available.")
            }
            return try AWAgentsWatchHoot.project(await chat.snapshot(limit: 500))
        }, readAgents: { [weak self] _ in
            // The list shows Hoot's row only: never build or clean the conversation for it.
            guard let runtime = await MainActor.run(body: { self?.hoot?.runtime }), let chat = runtime.structuredChat else {
                throw NativeRPCError(code: "unavailable", message: "Hoot's structured conversation is not available.")
            }
            return try AWAgentsWatchHoot.agents(await chat.snapshot(limit: 500))
        })
        let remote: AWAgentsWatchNativeSource.Remote = { [weak self] caller in
            switch caller {
            case .app(let rpc): try authority.requireLocalUI(rpc)
            case .mcp(let native):
                let current = try await authority.resolve(native)
                guard native.machineID.isEmpty, current.caller.actsAsOwner else {
                    return .init(agents: [], tasks: [], notices: ["Connected-machine activity is outside this caller's access."])
                }
            }
            guard let coordinator = await MainActor.run(body: { self?.machineCoordinator }) else {
                return .init(agents: [], tasks: [], notices: ["Connected-machine activity is not available yet."])
            }
            let snapshot = AWAgentsWatchMachines.project(try await coordinator.view())
            try Task.checkCancellation()
            if case .mcp(let native) = caller {
                guard try await authority.resolve(native).caller.actsAsOwner else {
                    throw NativeRPCError(code: "not-granted", message: "Connected-machine access was removed.")
                }
            }
            return snapshot
        }
        let baseSource = AWAgentsWatchNativeSource(authority: authority, tasks: tasks, taskAuthority: taskAuthority,
            transcript: AWAgentsWatchNativeSource.establishedTranscript(authority: authority), activity: activity, hoot: hoot, remote: remote)
        do {
            let source = try await root.installATWORK(source: baseSource, authority: authority, lifecycle: lifecycle,
                resolveTranscript: AWAgentsWatchNativeSource.establishedTranscript(authority: authority),
                processIdentity: { [weak self] agent in
                    guard agent.kind == "hoot" else { return nil }
                    guard let runtime = await MainActor.run(body: { self?.hoot?.runtime }) else {
                        return .init(pid: nil, running: false)
                    }
                    do {
                        guard let id = try await runtime.state().sessionId else {
                            return .init(pid: nil, running: false)
                        }
                        let pid = lifecycle.manager.pidOf(id)
                        return .init(pid: pid, running: pid == nil ? nil : true, sessionID: id)
                    } catch { return .init(pid: nil, running: nil) }
                })
            try await root.installAgentsWatch(source: source)
            await installAGTAgents(source: source, tasks: tasks, taskAuthority: taskAuthority)
            await installAGTShellAgents(shells)
            try await root.retain(.init(name: "agents-watch-activity", domains: ["agents-watch-activity"], ownerID: "native-composition:agents-watch-activity", invokes: [],
                stop: {
                    BackendAGTShellAgents.install(nil)
                    await sessions.hookCoordinator.removeAcceptedObserver(hookToken)
                    await sessions.lifecycle.removeObserver(lifecycleToken)
                    await activity.stop()
                }))
        } catch {
            BackendAGTShellAgents.install(nil)
            await sessions.hookCoordinator.removeAcceptedObserver(hookToken)
            await sessions.lifecycle.removeObserver(lifecycleToken)
            await activity.stop()
            throw error
        }
    }

    /// AGT: the Agents page's MCP tools and its one app-only file writer. A failure
    /// here leaves the tools absent (said in the log) and never takes tasks down with it.
    func installAGTAgents(source: any AWAgentsWatchSource, tasks: BackendTaskStateView, taskAuthority: BackendTaskToolAuthority) async {
        let owner = "native-composition:agents-directory", registry = root.registry, mcp = root.mcp
        let live = BackendAGTDirectoryService.liveRead(source)
        let service = BackendAGTDirectoryService(config: tasks.config, authority: taskAuthority, live: live,
            profileRead: { [weak self] caller, id in
                // The directory is installed first. Resolve the later-installed canonical profile reader at call time.
                if id == AGTDirectory.hootID {
                    return try await BackendAGTDirectoryService(config: tasks.config, authority: taskAuthority, live: live)
                        .invoke("agents.profile", arguments: .object([.init("id", .string(id))]), caller: caller)
                }
                if let authority = await MainActor.run(body: { self?.authority }),
                   try await authority.resolve(caller).caller.kind == .session {
                    guard let row = try await tasks.config.agent(id) else { throw NativeRPCError.invalidArguments("Choose a saved agent from agents_directory.") }
                    return BackendAgentStartSelection.publicProfile(row)
                }
                guard let profile = await MainActor.run(body: { self?.agentSettings?.profileService }) else {
                    throw NativeRPCError(code: "unavailable", message: "The agent profile reader is not ready.")
                }
                return try await profile.profile(id, call: .tool(caller))
            })
        do {
            try await BackendAGTDirectoryTools.install(server: mcp, service: service, ownerID: owner)
            try await BackendORGMCP.install(service: service, server: mcp, ownerID: owner)
            try await BackendAGTDirectoryTools.installAppChannel(registry: registry, config: tasks.config, ownerID: owner,
                                                                 requireApp: { try BackendCompositionRoot.requireLocalUI($0) })
            // Every agent on this Mac, in any app: read-only, scanned only when asked.
            let authority = try wired(self.authority, "authority")
            try await BackendAGTDeviceTools.install(registry: registry, server: mcp, scanner: BackendAGTDeviceScanner(), ownerID: owner,
                requireApp: { try BackendCompositionRoot.requireLocalUI($0) },
                authorize: { native, args in try await taskAuthority.authorize(native, BackendAGTDeviceTools.toolID, args, .read) },
                isOwner: { native in (try? await authority.resolve(native).caller.actsAsOwner) ?? false })
            try await root.retain(.init(name: "agents-directory", domains: ["agents-directory"], ownerID: owner,
                invokes: [BackendAGTDirectoryTools.writeSourceChannel, BackendAGTDeviceTools.listChannel, BackendAGTDeviceTools.readChannel],
                stop: { await registry.removeOwner(owner); await mcp.removeTools(ownerID: owner) }))
        } catch {
            await registry.removeOwner(owner); await mcp.removeTools(ownerID: owner)
            NSLog("[agents] The Agents tools were not installed: %@", error.localizedDescription)
        }
    }

    /// AGT: the tab strip's list of shell tabs with an AI in them (`{sessions: {id: provider}}`), app only.
    func installAGTShellAgents(_ shells: BackendAGTShellAgents) async {
        let owner = "native-composition:agt-shell-agents", registry = root.registry
        guard let authority else { unwired("authority"); return }
        do {
            try await registry.register(BackendAGTShellAgents.listChannel, ownerID: owner, policy: { context in
                guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Only the app's own window reads this.") }
            }, handler: { context, args in
                try BackendCompositionRoot.requireLocalUI(context)
                let rows = shells.decorate(authority.sessionViews()).compactMap { row -> NativeRPCValue.Field? in
                    guard let id = row["id"].string, let provider = row["innerAgent"]["provider"].string else { return nil }
                    return .init(id, .string(provider))
                }
                return .object([.init("sessions", .object(rows))])
            })
            try await root.retain(.init(name: "agt-shell-agents", domains: ["agt-shell-agents"], ownerID: owner,
                invokes: [BackendAGTShellAgents.listChannel], events: [BackendAGTShellAgents.changedEvent],
                stop: { await registry.removeOwner(owner) }))
        } catch {
            await registry.removeOwner(owner)
            NSLog("[agents] Shell-tab AI list was not installed: %@", error.localizedDescription)
        }
    }

    func installINT2WatchCatalogue() async throws {
        let ids = Set(AWAgentsWatchRegistration.operations.map { "agents.watch_" + $0 } + BackendATWORKRegistration.toolIDs)
        let registered = await root.mcp.registrations().filter { ids.contains($0.0.id) }
        guard Set(registered.map { $0.0.id }) == ids else {
            throw NativeRPCError(code: "composition-incomplete", message: "Agents at work needs its registered watch and control tools.")
        }
        let metadata = registered.map { spec, _ in
            BackendDeckCoreCatalogueMetadata(tool: spec, title: spec.description, index: spec.description)
        }
        let joins = self.joins
        let policies = zip(metadata, registered).map { row, registration in joins.mcpPolicy(row, handler: registration.1) }
        try joins.replaceContributions(owner: "agents-watch", [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
        try await root.retain(.init(name: "agents-watch-catalogue", domains: ["agents-watch-catalogue"], ownerID: "native-composition:agents-watch-catalogue", invokes: [],
            stop: { try? joins.replaceContributions(owner: "agents-watch", [], policiesWrapped: true) }))
        // AGT: the Agents tools join the catalogue when they installed.
        let agtIDs = Set(BackendAGTDirectoryTools.ids + BackendORGMCP.ids)
        let agt = await root.mcp.registrations().filter { agtIDs.contains($0.0.id) }
        guard Set(agt.map { $0.0.id }) == agtIDs else { return }
        let agtMetadata = agt.map { spec, _ in BackendDeckCoreCatalogueMetadata(tool: spec, title: spec.description, index: spec.description) }
        let agtPolicies = zip(agtMetadata, agt).map { row, registration in joins.mcpPolicy(row, handler: registration.1) }
        try joins.replaceContributions(owner: BackendAGTDirectoryTools.owner, [try .init(metadata: agtMetadata, policies: agtPolicies)], policiesWrapped: true)
        try await root.retain(.init(name: "agents-directory-catalogue", domains: ["agents-directory-catalogue"], ownerID: "native-composition:agents-directory-catalogue", invokes: [],
            stop: { try? joins.replaceContributions(owner: BackendAGTDirectoryTools.owner, [], policiesWrapped: true) }))
    }
}
