import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installINT2AgentsWatch(tasks: BackendTaskStateView, taskAuthority: BackendTaskToolAuthority) async throws {
        let authority = self.authority!, registry = root.registry, sessions = self.sessions!
        let activity = AWAgentsWatchActivity(changed: {
            try? await registry.publish("agents-watch:changed", arguments: [], ownerID: BackendCompositionRoot.appOwnerID)
        })
        let hookToken = await sessions.hookCoordinator.observeAccepted { await activity.accept($0) }
        let lifecycleToken = await sessions.lifecycle.observe { event in
            switch event {
            case .removed(let id, _), .exit(let id, _):
                await activity.remove(id)
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
        let source = AWAgentsWatchNativeSource(authority: authority, tasks: tasks, taskAuthority: taskAuthority,
            transcript: AWAgentsWatchNativeSource.establishedTranscript(authority: authority), activity: activity, hoot: hoot, remote: remote)
        do {
            try await root.installAgentsWatch(source: source)
            try await root.retain(.init(name: "agents-watch-activity", domains: ["agents-watch-activity"], ownerID: "native-composition:agents-watch-activity", invokes: [],
                stop: {
                    await sessions.hookCoordinator.removeAcceptedObserver(hookToken)
                    await sessions.lifecycle.removeObserver(lifecycleToken)
                    await activity.stop()
                }))
        } catch {
            await sessions.hookCoordinator.removeAcceptedObserver(hookToken)
            await sessions.lifecycle.removeObserver(lifecycleToken)
            await activity.stop()
            throw error
        }
    }

    func installINT2WatchCatalogue() async throws {
        let ids = Set(AWAgentsWatchRegistration.operations.map { "agents.watch_" + $0 })
        let registered = await root.mcp.registrations().filter { ids.contains($0.0.id) }
        guard Set(registered.map { $0.0.id }) == ids else {
            throw NativeRPCError(code: "composition-incomplete", message: "Agents at work needs its three registered read tools.")
        }
        let metadata = registered.map { spec, _ in
            BackendDeckCoreCatalogueMetadata(tool: spec, title: spec.description, index: spec.description)
        }
        let policies = zip(metadata, registered).map { row, registration in joins.mcpPolicy(row, handler: registration.1) }
        try joins.replaceContributions(owner: "agents-watch", [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
        let joins = self.joins
        try await root.retain(.init(name: "agents-watch-catalogue", domains: ["agents-watch-catalogue"], ownerID: "native-composition:agents-watch-catalogue", invokes: [],
            stop: { try? joins.replaceContributions(owner: "agents-watch", [], policiesWrapped: true) }))
    }
}
