import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// `update:get/check/download/install` and the `update:state` push, natively
/// (INT-A, D14). native-updates.ts registerNativeUpdateIpc forwarded each one
/// through Node's native-os door to `NativeAppUpdater.shared.handle(channel)`
/// and pushed every answer, and every change the updater announced, as
/// `update:state`. Here the same updater answers on the one registry.
///
/// Policy (actions/agents.ts: updates.status / updates.download / updates.install):
/// the app window or a credential-resolved page ticket; get/check read
/// (`authorizeMetadata`), download/install change (`authorizeMutation`).
@MainActor
enum NativeCompositionUpdateChannels {
    static let reads = ["update:get", "update:check"]
    static let writes = ["update:download", "update:install"]
    static let stateEvent = "update:state"
    private static var previous: (([String: Any]) -> Void)?
    private static var installed = false

    static func register(registry: NativeChannelRegistry, ownerID: String,
                         authority: BackendCompositionAuthority) async throws -> (invokes: [String], sends: [String], events: [String]) {
        for channel in reads + writes {
            if await registry.has(channel) { throw NativeRPCError(code: "duplicate-handler", message: "Update channel is already registered: " + channel) }
        }
        var registered: [String] = []
        do {
            for channel in reads + writes {
                let write = writes.contains(channel)
                try await registry.register(channel, ownerID: ownerID, policy: { context in
                    if write { try authority.authorizeMutation(context) } else { try authority.authorizeMetadata(context) }
                }, handler: { _, _ in try await NativeCompositionUpdateChannels.answer(channel, registry: registry) })
                registered.append(channel)
            }
        } catch {
            for channel in registered { await registry.removeHandler(channel, ownerID: ownerID) }
            throw error
        }
        // native-updates.ts osEvents 'update:state': the updater's own changes
        // (download progress, a launch check) reach the page as `update:state`.
        if !installed { previous = NativeAppUpdater.shared.onState; installed = true }
        NativeAppUpdater.shared.onState = { state in
            guard let value = try? NativeRPCValue.fromFoundation(state) else { return }
            Task { try? await registry.publish(NativeCompositionUpdateChannels.stateEvent, arguments: [value]) }
        }
        return (registered, [], [stateEvent])
    }

    /// The area's stop: hand the updater's announcements back to whoever had them.
    static func stop() {
        guard installed else { return }
        NativeAppUpdater.shared.onState = previous
        previous = nil; installed = false
    }

    /// native-updates.ts request(channel): the updater's state after the request,
    /// pushed as `update:state` too; an answer without a phase is refused.
    static func answer(_ channel: String, registry: NativeChannelRegistry) async throws -> NativeRPCValue {
        let raw = await NativeAppUpdater.shared.handle(channel) ?? ["phase": "error", "message": "Unknown update channel."]
        let state = try NativeRPCValue.fromFoundation(raw)
        guard state["phase"].string != nil else {
            throw NativeRPCError(code: "internal", message: "The native updater returned an invalid status.")
        }
        try? await registry.publish(stateEvent, arguments: [state])
        return state
    }
}
