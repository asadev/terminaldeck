import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// L8 HOST · Deck Memory: installs the terminal-session side (launch wiring, hook events). It never types into a session.
/// M1 CORE / M2 FLOW / L4 AGENTS replace the file-based defaults through `DeckMemorySessionCenter.shared?.bind { … }`.
extension NativeCompositionProduction {
    func installDeckMemorySessions() async {
        #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
        // L8 (quit keeps sessions): Hoot's own CLI holds an account lease in the session host; it is ended
        // before the app hands its kept sessions over, or the host answers "not safe to detach".
        BackendHOSTKeepDetachPreparation.register("hoot") { [weak self] in
            let runtime = await MainActor.run { self?.hoot?.runtime }
            _ = try? await runtime?.stop()
        }
        #endif
        guard DeckMemorySessionCenter.shared == nil, let sessions else { return }
        let report = self.report
        let manager = sessions.manager, ledger = sessions.ledger
        var services = DeckMemorySessionServices.deckMemory(report: { report("memory: " + $0) })
        // 28 Oct (bug A): the session's own CLI moved to another conversation (/clear, /resume). The session (and the
        // helper keeping it) and its saved launch follow, so a restart continues the conversation it is really in.
        services.conversationChanged = { id, conversation in
            manager.setAgentSessionId(id, conversationId: conversation)
            try? await ledger.updateConversation(id, conversationID: conversation)
            NativeCompositionRoot.note("sessions: \(id.prefix(8)) is in conversation \(conversation.prefix(8)) now; a restart continues that one")
        }
        let center = DeckMemorySessionCenter(dataRoot: root.dataRoot, manager: manager, services: services)
        do {
            try center.start()
            DeckMemorySessionCenter.shared = center
            let owner = BackendCompositionRoot.appOwnerID
            // Codex and Gemini have no trusted hook here: their turn end is the session going quiet.
            DeckMemorySessionFeeds.keep(try await root.registry.subscribe("session:status", ownerID: owner) { event in
                guard event.arguments.count >= 2, let id = event.arguments[0].string, let status = event.arguments[1].string else { return }
                await center.statusChanged(sessionID: id, status: status)
                // 10 Nov (Sessions): a session that changed account while it ran (also a switch the keeper applied)
                // is written down with the account it runs on now, so a restart starts it on that account.
                if let meta = manager.list().first(where: { $0.id == id }) { await ledger.followAccount(meta) }
            })
            for channel in ["session:exit", "session:removed"] {
                DeckMemorySessionFeeds.keep(try await root.registry.subscribe(channel, ownerID: owner) { event in
                    guard let id = event.arguments.first?.string else { return }
                    await center.sessionEnded(sessionID: id, removed: channel == "session:removed")
                })
            }
            // The person can rename a session or make it a project's lead at any time.
            for channel in ["session:renamed", "project-registry:changed"] {
                DeckMemorySessionFeeds.keep(try await root.registry.subscribe(channel, ownerID: owner) { _ in await center.reassessOwners() })
            }
            // Who a session is, for a memory tool call made from inside it.
            DeckMemoryCenter.shared.setSessionResolver { id in DeckMemorySessionBinding.stamp(sessionID: id, manager: manager) }
            // Card / topics / notes / board changes keep each desk's hook files current (a feed, no polling).
            DeckMemorySessionFeeds.watch = Task {
                let memory = await DeckMemory.ready()
                await center.reassessOwners()
                for await change in memory.changes() { await center.memoryChanged(change) }
            }
        } catch { report("memory: terminal sessions are running without their memory wiring: " + error.localizedDescription) }
    }
}

private enum DeckMemorySessionFeeds {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var feeds: [NativeRPCSubscription] = []
    static func keep(_ feed: NativeRPCSubscription) { lock.withLock { feeds.append(feed) } }
    nonisolated(unsafe) static var watch: Task<Void, Never>?
}
