import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installToolUseRestrictions(store: BackendTaskStore, config: BackendTaskConfiguration) async {
        guard let core else { unwired("core"); return }
        guard let sessions else { unwired("sessions"); return }
        let root = self.root
        await config.setToolUseCatalogue { Set(await core.control.tools().map { $0.tool.id }) }
        let inspector = BackendToolUseRestrictions(subject: { context in
            let caller = context.caller
            // External keys, owner UI and Hoot retain their own grants. A claimed
            // profile ID in arguments never turns them into a saved agent.
            guard caller.kind == .session else { return .init(stamp: "independent:" + caller.kind.rawValue + ":" + (caller.keyID ?? "")) }
            let latest = try await BackendToolUseRestrictions.authenticatedSessionCaller(context, endpoint: core.sessionEndpoint)
            guard let id = caller.sessionID, !id.isEmpty, (caller.machineID ?? "").isEmpty,
                  latest.sessionID == id, latest.machineID == caller.machineID, latest.tiers == caller.tiers,
                  let live = sessions.manager.list().first(where: { $0.id == id && $0.exitCode == nil }) else {
                throw BackendDeckCoreSecurityRefusal(.notGranted, "The current local agent session could not be verified.")
            }
            let lead = await BackendAGTLeadSeats.shared?.address(ofSession: id) != nil
            let task = try await store.bySession(id)
            let subject: BackendToolUseRestrictions.Subject
            if task?.assigneeKind == "agent" {
                subject = try BackendToolUseRestrictions.resolve(caller: caller, live: live, task: task, namedProfile: nil, lead: lead)
            } else if let relay = context.relaySessionProof {
                // Restored helper Chats can have no task, remembered tab or app launch entry.
                // Only the authenticated helper's retained launch may bind their saved agent.
                subject = try BackendToolUseRestrictions.resolve(caller: caller, live: live, task: task, namedProfile: relay.agentProfileID, lead: lead)
            } else {
                let input = await sessions.lifecycle.launchInput(id)
                let saved: String?
                if input?.agentProfileID == nil { saved = try await root.state.ledgerEntries().first { $0.id == id }?.saved["agentProfileID"].string }
                else { saved = nil }
                subject = try BackendToolUseRestrictions.resolve(caller: caller, live: live, task: task, namedProfile: input?.agentProfileID ?? saved, lead: lead)
            }
            let current = try await BackendToolUseRestrictions.authenticatedSessionCaller(context, endpoint: core.sessionEndpoint)
            guard current.sessionID == latest.sessionID, current.machineID == latest.machineID, current.tiers == latest.tiers,
                  current.projectRoot == latest.projectRoot, current.taskProject == latest.taskProject,
                  sessions.manager.list().contains(where: { $0.id == id && $0.createdAt == live.createdAt && $0.exitCode == nil }),
                  !context.cancellation.isCancelled else {
                throw BackendDeckCoreSecurityRefusal(.notGranted, "The session's current saved-agent binding changed during verification.")
            }
            return subject
        }, profile: { try await config.agent($0) })
        await core.control.setToolUseInspector { context, tool, args, expected in
            try await inspector.inspect(context, tool: tool, arguments: args, expected: expected)
        }
    }
}
