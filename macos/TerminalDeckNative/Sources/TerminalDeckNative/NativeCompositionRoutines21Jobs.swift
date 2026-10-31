import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func routines21FollowUp(config: BackendTaskConfiguration, specs: BackendTaskPersistence)
        -> @Sendable (BackendRoutinesRoutine, String, String) async throws -> BackendRoutinesRunOutcome {
        let sessions = self.sessions, chats = sessionChats, root = self.root, authority = self.authority
        return { routine, question, jobID in
            guard let sessions, let chats else {
                throw NativeRPCError(code: "unavailable", message: "The routine's agent chat is still starting. Try again in a moment.")
            }
            let work: @Sendable () async throws -> BackendRoutinesRunOutcome = {
                var input: BackendCreateSessionInput
                if routine.routinesAgentID == "@hoot" {
                    let defaults = BackendHootReadyDefaults(settings: root.settings, sessions: sessions, providers: root.providers)
                    let selection = try await defaults.read(projectPath: routine.folder)
                    guard selection.ready, let profile = selection.profile else {
                        throw NativeRPCError(code: "unavailable", message: "Sign in to Hoot's Coding AI under Settings › Coding AIs, then ask again.")
                    }
                    let settings = selection.launchSettings
                    let agent = NativeRPCValue.object([.init("id", .string("hoot")), .init("name", .string("Hoot")),
                        .init("provider", .string(selection.provider.rawValue)), .init("account", .string(profile.id)),
                        .init("model", settings.model.map(NativeRPCValue.string) ?? .null),
                        .init("effort", settings.effort.map(NativeRPCValue.string) ?? .null)])
                    input = try BackendRoutines21TaskWaiter.freshFollowUpInput(routine: routine, agent: agent, jobID: jobID)
                    input.agentSettings = settings
                    input.permissionMode = settings.permissionMode
                    // Hoot's saved selection owns the provider/account; this is its seat rather than a task profile.
                    input.agentProfileID = nil
                } else {
                    guard let agent = try await config.agent(routine.routinesAgentID) else {
                        throw NativeRPCError.invalidArguments("The routine's agent no longer exists. Choose another agent before asking again.")
                    }
                    input = try BackendRoutines21TaskWaiter.freshFollowUpInput(routine: routine, agent: agent, jobID: jobID, specs: specs)
                }
                let launchInput = input
                return try await BackendRoutines21TaskWaiter.run(start: {
                    let meta = try await sessions.lifecycle.create(launchInput,
                        context: .init(rememberTab: false, isAppComposed: true, requiresInAppOwner: true, fromAI: true), holdOnFailure: false)
                    do { _ = try await chats.say(meta.id, text: question) }
                    catch { try? await chats.finishJob(meta.id, result: "The question could not be delivered.", failed: true); throw error }
                    return meta.id
                }, read: { id in
                    guard let record = await chats.conversation(id), record.isFinished else { return nil }
                    return .init(ok: !record.failed, sessionIds: [id], error: record.failed ? record.result : nil, output: record.result)
                }, subscribe: { changed in
                    try await root.registry.subscribe(BackendSessionChats.event, ownerID: BackendCompositionRoot.appOwnerID) { _ in await changed() }
                }, stop: { id in _ = try? await chats.stop(id) })
            }
            #if TD_HOST_ACCOUNT_BRIDGE
            return try await BackendRoutinesAppProfileScope.withOwner(authority: authority, operation: work)
            #else
            _ = authority
            return try await work()
            #endif
        }
    }

    func routines21AgentRun(local: BackendTaskLocalService, store: BackendTaskStore,
                            changes: BackendCompositionChangeHub, reports: BackendRoutines21Reports) -> BackendROUTINESRunner.ProfileRun {
        let engine = taskEngine
        return { request, agent in
            let input = BackendRoutines21TaskWaiter.taskInput(request: request, agent: agent)
            return try await BackendRoutines21TaskWaiter.run(start: { try await local.create(input, by: "routine").id },
                read: { id in
                    guard let task = try await store.byID(id, includeTrash: true) else {
                        return .init(ok: false, error: "The agent's routine task was removed before it finished.")
                    }
                    return BackendRoutines21TaskWaiter.taskOutcome(task.value)
                }, subscribe: { changed in await changes.observe(changed) }, cancellation: request.cancellation,
                stop: { id in try? await engine?.cancel(id, reason: "The routine stopped waiting for its report.") },
                // U66: past the hour the task goes on; its answer lands in the run's report.
                late: { outcome in try? await reports.finishLate(request, outcome: outcome) })
        }
    }
}
