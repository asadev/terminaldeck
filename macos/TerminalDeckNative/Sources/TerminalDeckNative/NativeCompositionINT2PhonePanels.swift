import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// Install after core tools/Hoot, before the existing machine feature
    /// snapshots this registry's supplied panel capabilities.
    func installINT2PhonePanels(panels: BackendRemotePanelRegistry) async throws {
        guard let endpoint = remoteEndpoint, let trust = remoteTrust, let view = taskView else {
            throw NativeRPCError(code: "composition-incomplete", message: "Phone panels need the current remote device and task owners.")
        }
        let owner = "native.phone-panels"
        let scope = BackendINT2PhonePanelScope(endpoint: endpoint, trust: trust, control: core.control,
            bindings: joins, projectRows: { [state] in state.listProjects() }, sessionLinks: { rows, rpc in
                guard let issued = BackendINT2PhonePanelCaller.current, rpc.caller == .pairedDevice, rpc.ownerID == issued.deviceID else {
                    throw NativeRPCError(code: "access-denied", message: "Task session links need the original device connection.")
                }
                let current = try await endpoint.refreshedContext(issued)
                try await trust.requirePhoneAccess(current.deviceID, message: "panel.read", panel: "tasks")
                let authorized = try await endpoint.panelSessionIDs(current)
                let projects = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, String)? in
                    guard let id = row["task"].string, let project = row["project"].string else { return nil }; return (id, project)
                })
                var links: [String: String] = [:]
                for task in try await view.store.all() where task.isLocal && projects[task.id] == task.project {
                    guard let session = task.sessionID, authorized.contains(session),
                          current.reach.unrestricted || current.reach.folders.contains(where: { BackendRemoteTrustStore.within($0, task.project) }) else { continue }
                    links[task.id] = session
                }
                return links
            })
        let available = Set(await core.control.tools().map { $0.tool.id })
        let providers: [(BackendRemotePanelRegistry.Domain, Set<String>, BackendRemotePanelProvider)] = [
            (.tasks, ["tasks.local", "tasks.local_change"], BackendINT2PhonePanels.tasks(scope: scope)),
            (.goals, ["tasks.goals"], BackendINT2PhonePanels.goals(scope: scope)),
            (.staysfixed, ["fixed.status", "fixed.check", "fixed.stop"], BackendINT2PhonePanels.staysFixed(scope: scope)),
            (.settings, ["settings.read", "settings.write"], BackendINT2PhonePanels.settings(scope: scope)),
            (.simulators, ["devices.list", "devices.open"], BackendINT2PhonePanels.simulators(scope: scope)),
            (.hooks, ["hooks.status", "hooks.install", "hooks.remove", "hooks.sync"], BackendINT2PhonePanels.hooks(scope: scope)),
            (.servers, ["servers.look"], BackendINT2PhonePanels.servers(scope: scope))
        ]
        var installed: [BackendRemotePanelRegistry.Domain] = []
        do {
            for (domain, required, provider) in providers {
                guard required.isSubset(of: available) else {
                    report("Phone panel " + domain.rawValue + " is unavailable: missing existing tools " + required.subtracting(available).sorted().joined(separator: ", "))
                    continue
                }
                try await panels.register(domain, provider: provider)
                installed.append(domain)
            }
            let retained = installed
            try await root.retain(.init(name: "phone-panels", domains: ["phone-panels"], ownerID: owner, invokes: [],
                stop: { for domain in retained { await panels.unregister(domain) } }))
        } catch {
            for domain in installed { await panels.unregister(domain) }
            throw error
        }
        // GitHub and plugin tools explicitly refuse remote callers. AI-app
        // grant controls have no safe remote MCP operation. Memory is paused.
        // These stay absent instead of obtaining app-window authority.
    }
}
