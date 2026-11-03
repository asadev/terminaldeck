import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// Connected task systems: the service, its MCP tools (in the catalogue), the app's
    /// channels and the agent-answer hook on the task store's change hub. A failure here
    /// leaves only this feature out (said in the log) and never takes Tasks down with it.
    func installConnectedTasks(persistence: BackendTaskPersistence, store: BackendTaskStore, config: BackendTaskConfiguration,
                               local: BackendTaskLocalService, changes: BackendCompositionChangeHub,
                               authority: BackendTaskToolAuthority) async {
        let owner = "native-composition:connected-tasks", registry = root.registry, mcp = root.mcp, joins = self.joins
        let service = BackendConnectedTasksService(persistence: persistence,
            secrets: BackendConnectedTasksKeychain(appName: configuration.appName),
            agents: .init(create: { input in try await local.create(input).id },
                          outcome: { id in
                              guard let task = try await store.byID(id, includeTrash: true) else { return .init(answer: nil, stopped: true) }
                              if let answer = task.value["result"]["answer"].string { return .init(answer: answer) }
                              if !task.value["result"].isNullish { return .init(answer: "Finished (no written answer).") }
                              return task.value["stopped"].bool == true ? .init(answer: nil, stopped: true) : nil
                          },
                          agent: { id in
                              guard let row = try await config.agent(id) else { return nil }
                              return (name: row["name"].string ?? id, project: row["defaultProject"].string)
                          }),
            changed: { try? await registry.publish(BackendConnectedTasksTools.changedEvent, arguments: [], ownerID: BackendCompositionRoot.appOwnerID) },
            problem: { NSLog("[connected tasks] %@", $0) },
            chooseFiles: { try await NativeCompositionFolderPicker.files().map { URL(fileURLWithPath: $0) } },
            openURL: { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } })
        var hub: NativeRPCSubscription?
        do {
            try await service.start()
            try await BackendConnectedTasksTools.install(server: mcp, service: service, authority: authority,
                                                         agentID: { name in try await config.agent(name)?["id"].string }, ownerID: owner)
            try await BackendConnectedTasksTools.installAppChannels(registry: registry, service: service, ownerID: owner,
                                                                    requireApp: { try BackendCompositionRoot.requireLocalUI($0) })
            // No timer: a finished agent's answer is noticed when the task store changes.
            hub = await changes.observe { await service.agentResults() }
            let ids = Set(BackendConnectedTasksTools.ids)
            let registered = await mcp.registrations().filter { ids.contains($0.0.id) }
            let metadata = registered.map { spec, _ in BackendDeckCoreCatalogueMetadata(tool: spec, title: spec.description, index: spec.description) }
            let policies = zip(metadata, registered).map { row, registration in joins.mcpPolicy(row, handler: registration.1) }
            try joins.replaceContributions(owner: BackendConnectedTasksTools.owner, [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
            let lease = hub
            try await root.retain(.init(name: "connected-tasks", domains: ["connected-tasks"], ownerID: owner,
                invokes: Set(BackendConnectedTasksTools.channels), sends: [], events: [BackendConnectedTasksTools.changedEvent],
                stop: {
                    await lease?.cancelAndWait()
                    try? joins.replaceContributions(owner: BackendConnectedTasksTools.owner, [], policiesWrapped: true)
                    await registry.removeOwner(owner); await mcp.removeTools(ownerID: owner)
                }))
            Task { await service.agentResults() } // answers that arrived while the app was closed
        } catch {
            await hub?.cancelAndWait()
            try? joins.replaceContributions(owner: BackendConnectedTasksTools.owner, [], policiesWrapped: true)
            await registry.removeOwner(owner); await mcp.removeTools(ownerID: owner)
            NSLog("[connected tasks] Connected task systems were not installed: %@", error.localizedDescription)
        }
    }
}
