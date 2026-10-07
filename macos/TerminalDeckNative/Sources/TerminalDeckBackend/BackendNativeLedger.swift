import Foundation
import TerminalDeckNativeCore

/// Activated only when the old session owner is disabled. The Store actor
/// already owns persistence; this transfers pending/live/held attribution too.
public actor BackendNativeLedger: BackendSessionLedger {
    public nonisolated let readiness: BackendLaunchReadiness = .ready
    private let store: NativeStateStore
    private var errors: [String] = []

    private init(store: NativeStateStore) { self.store = store }

    public static func activate(store: NativeStateStore, oldSessionOwnerDisabled: Bool) async throws -> BackendNativeLedger {
        guard oldSessionOwnerDisabled, store.ownership == .exclusive || store.ownership == .memory else {
            throw BackendSessionFailure.missingCapability("exclusive native session-ledger ownership")
        }
        try await store.startSessionLedger()
        return BackendNativeLedger(store: store)
    }

    public func tabKey(_ input: BackendCreateSessionInput, context: BackendLaunchContext, live: [BackendSessionMeta]) async throws -> String? {
        if let explicit = input.tabKey, !explicit.isEmpty { return explicit }
        if let replaced = input.replaces, let old = live.first(where: { $0.id == replaced }), let key = old.tabKey { return key }
        guard context.rememberTab, Self.hasUsableBoundary(context) else { return nil }
        return UUID().uuidString.lowercased()
    }

    /// A confined session whose boundary has no device id cannot be re-confined on restore, so it is never written down.
    private static func hasUsableBoundary(_ context: BackendLaunchContext) -> Bool {
        guard let boundary = context.deviceBoundary else { return true }
        return !boundary.deviceKey.isEmpty
    }

    public func started(_ session: BackendSessionMeta, input: BackendCreateSessionInput, context: BackendLaunchContext) async throws {
        guard context.rememberTab, Self.hasUsableBoundary(context) else { return }
        var fields: [NativeRPCValue.Field] = [
            .init("cwd", .string(input.cwd)),
            .init("provider", .string(input.provider ?? session.provider)),
            .init("profileId", (session.profileId ?? input.profileId).map(NativeRPCValue.string) ?? .null),
            .init("cols", .number(Double(input.cols))), .init("rows", .number(Double(input.rows))),
            .init("lastSeenAt", .number(Date().timeIntervalSince1970 * 1000)),
        ]
        func append(_ name: String, _ value: String?) { if let value { fields.append(.init(name, .string(value))) } }
        append("tabKey", session.tabKey)
        append("homeProfileId", session.homeProfileId)
        append("agentSessionId", session.agentSessionId ?? (input.pickConversation == true ? input.resumeConversationId : nil))
        append("model", input.model)
        append("agentInstructions", input.agentInstructions)
        if let denied = input.deniedTools { fields.append(.init("deniedTools", .array(denied.map(NativeRPCValue.string)))) }
        if let noSkills = input.noSkills { fields.append(.init("noSkills", .bool(noSkills))) }
        append("confineDeviceId", context.deviceBoundary?.deviceKey)
        try await store.ledgerNote(session.id, saved: .object(fields))
    }

    public func removed(sessionID: String, reason: BackendRemovalReason) async {
        do { try await store.ledgerForget(sessionID) }
        catch { errors.append(error.localizedDescription) }
    }
    public func updateConversation(_ id: String, conversationID: String) async throws {
        try await store.ledgerUpdate(id, patch: .object([.init("agentSessionId", .string(conversationID))]))
    }
    public func activity(_ id: String) async throws { try await store.ledgerTouch(id) }
    public func prepareForQuit() async throws {
        try await store.ledgerFlush()
        try await store.ledgerFreeze()
    }
    public func entries() async throws -> [NativeOpenSessionLedger.Entry] { try await store.ledgerEntries() }
    public func held() async throws -> [NativeHeldSession] { try await store.heldSessions() }
    public func failures() -> [String] { errors }
}
