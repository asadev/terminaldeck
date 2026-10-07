import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// Retain one registered channel group as its own area (one owner id, stopped with the graph).
    func retainChannels(_ name: String, owner: String, _ registered: (invokes: [String], sends: [String], events: [String]),
                        stop: @escaping @Sendable () async -> Void = {}) async throws {
        let registry = root.registry
        do {
            try await root.retain(.init(name: name, domains: [name], ownerID: owner, invokes: Set(registered.invokes),
                sends: Set(registered.sends), events: Set(registered.events),
                stop: { await stop(); await BackendCompositionSendLeases.shared.drop(owner); await registry.removeOwner(owner) }))
        } catch { await stop(); await BackendCompositionSendLeases.shared.drop(owner); await registry.removeOwner(owner); throw error }
    }

    /// The page's and the app's own channels that Node used to answer (D14: no Node fallback).
    func installAppChannels(controls: any BackendCompositionAgentControlsOwning) async throws {
        guard let customAgents = clients.customAgents else {
            throw NativeRPCError(code: "composition-incomplete", message: "App channels need the custom-agents owner.")
        }
        let appOwner = "native-composition:app-channels"
        try await retainChannels("app-channels", owner: appOwner, try await BackendCompositionAppChannels.register(registry: root.registry,
            ownerID: appOwner, authority: authority, controls: controls, providers: root.providers, customAgents: customAgents))
        let updateOwner = "native-composition:updates"
        try await retainChannels("updates", owner: updateOwner,
            try await NativeCompositionUpdateChannels.register(registry: root.registry, ownerID: updateOwner, authority: authority),
            stop: { await MainActor.run { NativeCompositionUpdateChannels.stop() } })
    }
}

/// The session's device boundary for attachments, from the same ledger/restore rule the file graph uses.
struct NativeCompositionAttachBoundary: BackendMacAppHandoffAttachBoundary {
    let authority: BackendCompositionAuthority
    let restore: BackendSessionRestoreContext
    func boundary(_ sessionID: String, context: NativeRPCContext) async throws -> BackendDeviceBoundary? {
        try await authority.requireSessionRPC(sessionID, context: context)
        let saved = try await authority.state.store.ledgerGet(sessionID)
        guard !saved.isNullish else { return nil }
        return try await restore.context(for: BackendSessionSaved(saved)).deviceBoundary
    }
}

extension NativeCompositionProduction {
    /// TS index.ts state/prefs/accounts-history/confine/wsl handlers and the desktop handoff
    /// (links, attachments) over their one owner each.
    func installStateAndDesktopChannels() async throws {
        guard let restore = restoreContext else { throw NativeRPCError(code: "composition-incomplete", message: "Desktop channels need the restore context.") }
        let stateOwner = "native-composition:state-channels"
        try await retainChannels("state-channels", owner: stateOwner, try await BackendCompositionStateChannels.register(registry: root.registry,
            ownerID: stateOwner, authority: authority, sharedHistory: sessions.sharedHistory, profiles: sessions.profiles))
        let handoff = NativeCompositionDesktopHandoff(authority: authority, registry: root.registry)
        let attachments = BackendMacAppHandoffAttachments(files: BackendMacAppHandoffAttachDisk(), clipboard: handoff, panels: handoff,
            boundaries: NativeCompositionAttachBoundary(authority: authority, restore: restore),
            bringIn: BackendMacAppHandoffBringInTransfers(transfers: files.transfers),
            pasteDirectory: root.dataRoot.appendingPathComponent("pasted", isDirectory: true).path, home: configuration.homeDirectory.path)
        let desktopOwner = "native-composition:desktop-channels"
        try await retainChannels("desktop-channels", owner: desktopOwner, try await BackendCompositionDesktopChannels.register(registry: root.registry,
            ownerID: desktopOwner, authority: authority, links: BackendMacAppHandoffLinks(desktop: handoff), attachments: attachments,
            linkRequests: linkRequests))
    }
}

extension NativeCompositionProduction {
    /// TS native-shell browser/window channels: bind/connect menus, the reach ledger, popout
    /// refusals, the page's view sends and the Chrome-retired refusals.
    func installBrowserChannels() async throws {
        let ledgerOwners = BackendCompositionBrowserReachLedger.owners(machines: machineCoordinator, servers: serversOwner?.reach)
        let ledger = BackendCompositionBrowserReachLedger(registry: root.registry, open: ledgerOwners.open, close: ledgerOwners.close)
        reachLedger = ledger
        let owner = "native-composition:browser-channels"
        try await retainChannels("browser-channels", owner: owner, try await BackendCompositionBrowserChannels.register(registry: root.registry,
            ownerID: owner, authority: authority, bindings: NativeCompositionBrowserChannels.bindings(), reachLedger: ledger,
            hiddenCommands: nil))
    }
}
