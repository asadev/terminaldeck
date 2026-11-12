import Foundation
import TerminalDeckNativeCore

/// Activated only when the old session owner is disabled. The Store actor
/// already owns persistence; this transfers pending/live/held attribution too.
public actor BackendNativeLedger: BackendSessionLedger {
    public nonisolated let readiness: BackendLaunchReadiness = .ready
    private let store: NativeStateStore
    private var errors: [String] = []

    private init(store: NativeStateStore) { self.store = store }

    public static func activate(store: NativeStateStore) async throws -> BackendNativeLedger {
        guard store.ownership == .exclusive || store.ownership == .memory else {
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
        try await store.ledgerNote(session.id, saved: Self.savedLaunch(session, input: input, deviceKey: context.deviceBoundary?.deviceKey))
    }

    /// The saved launch (folder, AI, conversation, agent) a restore starts the session again from. The ledger writes
    /// it for a remembered tab; the deliberate helper restart builds it from the helper's own record for a live
    /// session that was never remembered (an AI-started chat), so that session comes back instead of blocking.
    public static func savedLaunch(_ session: BackendSessionMeta, input: BackendCreateSessionInput, deviceKey: String?) -> NativeRPCValue {
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
        append("agentProfileID", input.agentProfileID)
        append("claudeAgent", input.claudeAgent)
        append("permissionMode", input.permissionMode)
        append("taskID", input.taskID)
        append("taskProject", input.taskProject)
        append("agentDefinitionsFile", input.agentDefinitionsFile)
        if let allowed = input.allowedTools { fields.append(.init("allowedTools", .array(allowed.map(NativeRPCValue.string)))) }
        if let denied = input.deniedTools { fields.append(.init("deniedTools", .array(denied.map(NativeRPCValue.string)))) }
        if let noSkills = input.noSkills { fields.append(.init("noSkills", .bool(noSkills))) }
        append("confineDeviceId", deviceKey)
        if input.chat == true { fields.append(.init("chat", .bool(true))) }   // a restart brings it back as a chat
        // 10 Nov (Asad: Commander came back without its seat): the project the tab was opened for and its effort come
        // back with it (before, a restart started it with no project and lost what its seat is resolved from).
        append("projectId", input.projectId ?? session.projectId)
        append("effort", input.effort)
        // 10 Nov: who opened the tab, and when this process started (what tells an unused tab from a used one).
        append(NativeOpenSessionLedger.openedByKey, openedBy(input))
        fields.append(.init(NativeOpenSessionLedger.startedAtKey, .number(session.createdAt)))
        return .object(fields)
    }
    /// Who opened a tab: "restore" (a restart or a keeper restart brought it back), "hoot", "agent" (an AI app, a
    /// session AI's tool, a task or a routine) or "person".
    public static func openedBy(_ input: BackendCreateSessionInput, restoring: Bool = BackendAGSLaunchScope.restoring) -> String {
        if restoring { return "restore" }
        if input.taskID != nil || input.taskProject != nil || input.originRoutineId != nil || input.originApp != nil || input.origin == .app { return "agent" }
        if input.origin == .copilot { return "hoot" }
        return "person"
    }
    /// 10 Nov (Asad: the label and the restart must be the account the session really runs on): a session that
    /// changed account while it ran (an in-place switch, also one the keeper applied while the app was closed) is
    /// written down with that account and the folder it runs in, so a restart starts it on the same account.
    public func followAccount(_ session: BackendSessionMeta) async {
        guard session.exitCode == nil, let saved = try? await store.ledgerGet(session.id), saved.fields != nil else { return }
        let profile = session.profileId.map(NativeRPCValue.string) ?? .null
        let home = session.homeProfileId.map(NativeRPCValue.string) ?? .missing
        let savedHome = saved["homeProfileId"].string.map(NativeRPCValue.string) ?? .missing
        guard saved["profileId"] != profile || savedHome != home else { return }
        var next = saved.setting("profileId", profile)
        next = session.homeProfileId == nil ? next.removing("homeProfileId") : next.setting("homeProfileId", home)
        do { try await store.ledgerNote(session.id, saved: next) } catch { errors.append(error.localizedDescription) }
    }

    public func removed(sessionID: String, reason: BackendRemovalReason) async {
        do { try await store.ledgerForget(sessionID) }
        catch { errors.append(error.localizedDescription) }
    }
    public func updateConversation(_ id: String, conversationID: String) async throws {
        try await store.ledgerUpdate(id, patch: .object([.init("agentSessionId", .string(conversationID))]))
    }
    public func activity(_ id: String) async throws { try await store.ledgerTouch(id) }
    /// 1 Nov (item 58): the session really did something (`BackendPTYManager.noteActivity`), kept across restarts.
    public func noteActivity(_ id: String, at: Double) async throws { try await store.ledgerActivity(id, at: at) }
    public func prepareForQuit() async throws {
        try await store.ledgerFlush()
        try await store.ledgerFreeze()
    }
    public func entries() async throws -> [NativeOpenSessionLedger.Entry] { try await store.ledgerEntries() }
    public func held() async throws -> [NativeHeldSession] { try await store.heldSessions() }
    public func failures() -> [String] { errors }
}
