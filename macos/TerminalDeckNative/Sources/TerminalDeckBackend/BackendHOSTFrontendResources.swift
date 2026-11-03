#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

/// App-side controls over actual helper state. Authorization must be bound to
/// original app authority by composition; absence refuses before private RPC.
public enum BackendHOSTFrontendResources {
    public typealias Authorization = @Sendable (NativeRPCContext, String, [NativeRPCValue], Bool) async throws -> Void
    public typealias HookMetadataContext = @Sendable (String, String?) async throws -> String?
    private static let registry = BackendHOSTFrontendRegistry()
    public static func accountApp(client: BackendHOSTClient) throws -> BackendHOSTAccountControlApp {
        guard let app = registry.app(client) else { throw BackendHOSTFailure.unavailable }; return app
    }
    public static func bindAuthorization(app: BackendHOSTAccountControlApp, check: @escaping Authorization) {
        registry.bind(app.authority, check: check)
    }
    /// Bind the same actual BR/context callback used by the original hook join,
    /// using only fields that really exist in the authenticated metadata.
    public static func bindHookMetadataContext(joins: BackendCompositionProductionBindings, handler: @escaping HookMetadataContext) {
        registry.bind(joins, context: handler)
    }
    public static func makeControls(client: BackendHOSTClient, app: BackendHOSTAccountControlApp,
                                    manager: BackendPTYManager) async throws -> BackendHOSTAccountSessionControls {
        guard let authorization = registry.authorization(app.authority) else { throw BackendHOSTFailure.unavailable }
        let ownerContext = try BackendHOSTProfileScope.requireCurrent()
        try await authorization(ownerContext, "hooks:server", [], false)
        let endpoint = try await client.resource("hooks.endpoint", arguments: .object([]))
        let socket = try endpoint["socketPath"].requireString("actual hook socket"), config = try endpoint["configPath"].requireString("actual private hook config")
        guard socket.hasPrefix("/"), config.hasPrefix("/"), !socket.contains("\0"), !config.contains("\0"),
              let environment = endpoint["sessionEnvironment"].string, environment == BackendSessionEnvironment.sessionVariable,
              let appID = endpoint["appID"].string, !appID.isEmpty else { throw BackendHOSTFailure.authentication }
        let state = BackendHOSTFrontendControlState(client: client, app: app, manager: manager,
            ownerContext: ownerContext, authorization: authorization)
        registry.bind(client, app: app)
        registry.retain(state)
        let switching = BackendHOSTSuppliedSessionSwitching(subject: { try await state.subject($0, target: $1) },
            perform: { try await state.perform($0, target: $1, note: $2) }, cancel: { try await state.cancel($0) }, stop: { await state.stopSwitches() },
            pending: { await state.pending($0) })
        let deferred = BackendHOSTSuppliedSessionDeferring(arm: { try await state.arm($0, target: $1) },
            list: { try await state.armed() }, cancel: { try await state.cancel($0) }, recoveryDraft: { await state.recovery($0) }, stop: { await state.stopSwitches() })
        let observation = BackendHOSTSuppliedSessionHookObserving(observe: { await state.observe($0) },
            remove: { await state.removeObserver($0) }, stop: { await state.closeObservation() })
        return .init(switches: switching, deferred: deferred, hooks: BackendHOSTFrontendHooks(state: state), hookObservation: observation,
            hookEndpoint: .init(socketPath: socket, configPath: config, sessionEnvironment: environment, appID: appID),
            detachForKeep: { try await state.detachForKeep() }, closeAfterDrain: { try await state.closeAfterDrain() })
    }
    public static func hookContext(event: NativeRPCValue, joins: BackendCompositionProductionBindings) async throws -> String? {
        let name = try event["event"].requireString("actual hook event", nonempty: true)
        let provider = try event["provider"].requireString("actual hook provider", nonempty: true)
        guard ["claude", "codex", "gemini"].contains(provider), event["receivedAt"].number?.isFinite == true else { throw BackendHOSTFailure.authentication }
        let session = event["sessionId"].string
        // Actual helper delivery is the event trigger; no polling/watch timer.
        for state in registry.states() { await state.fetchAcceptedHooks(triggerSession: session) }
        guard let handler = registry.context(joins) else { return nil }
        return try await handler(name, session)
    }
}

private final class BackendHOSTFrontendRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var authorization: [ObjectIdentifier: BackendHOSTFrontendResources.Authorization] = [:]
    private var contexts: [ObjectIdentifier: BackendHOSTFrontendResources.HookMetadataContext] = [:]
    private var retained: [BackendHOSTFrontendControlState] = []
    private var apps: [ObjectIdentifier: BackendHOSTAccountControlApp] = [:]
    func bind(_ client: BackendHOSTClient, app: BackendHOSTAccountControlApp) { lock.withLock { apps[ObjectIdentifier(client)] = app } }
    func app(_ client: BackendHOSTClient) -> BackendHOSTAccountControlApp? { lock.withLock { apps[ObjectIdentifier(client)] } }
    func bind(_ authority: BackendHOSTAccountControlAuthority, check: @escaping BackendHOSTFrontendResources.Authorization) { lock.withLock { authorization[ObjectIdentifier(authority)] = check } }
    func authorization(_ authority: BackendHOSTAccountControlAuthority) -> BackendHOSTFrontendResources.Authorization? { lock.withLock { authorization[ObjectIdentifier(authority)] } }
    func bind(_ joins: BackendCompositionProductionBindings, context: @escaping BackendHOSTFrontendResources.HookMetadataContext) { lock.withLock { contexts[ObjectIdentifier(joins)] = context } }
    func context(_ joins: BackendCompositionProductionBindings) -> BackendHOSTFrontendResources.HookMetadataContext? { lock.withLock { contexts[ObjectIdentifier(joins)] } }
    func retain(_ state: BackendHOSTFrontendControlState) { lock.withLock { retained.append(state) } }
    func states() -> [BackendHOSTFrontendControlState] { lock.withLock { retained } }
}
private struct BackendHOSTFrontendHooks: BackendHOSTAccountChannelInvoking {
    let state: BackendHOSTFrontendControlState
    func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        try await state.hook(channel, args: args, context: context)
    }
}
private actor BackendHOSTFrontendControlState {
    private let client: BackendHOSTClient, app: BackendHOSTAccountControlApp, manager: BackendPTYManager
    private let ownerContext: NativeRPCContext
    private let authorization: BackendHOSTFrontendResources.Authorization
    private var hookObservers: [UUID: @Sendable (BackendSessionHookEvent) async -> Void] = [:]
    private var hookSequence: UInt64 = 0
    private var observing = true, switchesStopped = false
    private var fetches = BackendHOSTHookFetchGate()
    init(client: BackendHOSTClient, app: BackendHOSTAccountControlApp, manager: BackendPTYManager,
         ownerContext: NativeRPCContext, authorization: @escaping BackendHOSTFrontendResources.Authorization) {
        self.client = client; self.app = app; self.manager = manager; self.ownerContext = ownerContext; self.authorization = authorization
    }
    private func authorize(_ channel: String, args: [NativeRPCValue], mutation: Bool) async throws -> NativeRPCContext {
        let original = try BackendHOSTProfileScope.requireCurrent()
        try await authorization(original, channel, args, mutation); try Task.checkCancellation(); return original
    }
    func subject(_ id: String, target: String) async throws -> BackendSessionSwitchPlan {
        let original = try await authorize("session:switch-plan", args: [.string(id), .string(target)], mutation: false)
        if BackendAPIAccountRecord.isAPIAccountID(target) {
            let status = try await client.resource("account.status", arguments: .object([]))
            guard status["apiKeyAccounts"].bool == true else { throw BackendAccountFailure("This API-key account needs the updated session service.") }
        }
        guard let meta = manager.list().first(where: { $0.id == id && $0.exitCode == nil }), manager.isHostedSession(id) else { throw BackendSessionFailure.missingSession }
        let to = try await app.facade.find(target, context: original)
        let from: BackendAccountProfile?
        if let previous = meta.profileId { from = try await app.facade.find(previous, context: original) } else { from = nil }
        func refused(_ sentence: String) -> BackendSessionSwitchPlan {
            .init(sessionID: id, refusal: sentence, from: from, to: to, conversation: "stays", resume: false, conversationID: nil, mode: .restart, saved: nil, carried: nil)
        }
        if BackendSessionSwitchCoordinator.requiresAccountReplacement(sourceID: meta.profileId, targetID: target) {
            if let to, BackendAPIAccountRecord.isAPIAccountID(to.id) {
                let credential = try await app.facade.invoke("profiles:signin", args: [.string(to.id)], context: original)
                guard credential["state"].string == "signed-in" else {
                    return refused(credential["detail"].string ?? "The API key is missing or unavailable. Open Settings › Coding AIs and update its key. Nothing was changed.")
                }
            }
            throw BackendSessionSwitchNoSeat(sessionID: id)
        }
        guard meta.provider == "claude" else {
            return refused("Only a Claude session can change account while it runs. Open a new session on that account instead.")
        }
        guard to?.provider == "claude" else { return refused("That account is not a Claude account on this Mac any more. Pick another one.") }
        // 12 Oct: a session with no seat (started before switching was ready) is not a refusal: the restart fallback
        // offers to restart it on the account, resuming the conversation. An older host says so only in its own
        // words; those are read as the same thing, never shown.
        let reply: NativeRPCValue
        do { reply = try await client.resource("switch.plan", arguments: .object([.init("id", .string(id)), .init("target", .string(target))])) }
        catch where BackendSessionSwitchNoSeat.recognizes(error) { throw BackendSessionSwitchNoSeat(sessionID: id) }
        catch { throw BackendSessionSwitchNoSeat.plainHostError(error) }
        try await authorization(original, "session:switch-plan", [.string(id), .string(target)], false)
        if reply["reason"].string == "no-seat" { throw BackendSessionSwitchNoSeat(sessionID: id) }
        guard reply["verified"].bool == true, reply["mode"].string == "in-place", reply["pid"].number == manager.pidOf(id).map(Double.init) else {
            return refused(reply["refusal"].string ?? "This session changed while it was being checked, so it was left as it is. Try again.")
        }
        return .init(sessionID: id, refusal: reply["refusal"].string, from: from, to: to, conversation: "same",
            resume: false, conversationID: meta.agentSessionId, mode: .inPlace, saved: nil, carried: nil)
    }
    func perform(_ id: String, target: String, note: String) async throws -> BackendSessionSwitchCoordinator.Execution {
        let original = try await authorize("session:switch-account", args: [.string(id), .string(target)], mutation: true)
        let plan = try await subject(id, target: target)
        guard plan.refusal == nil, plan.mode == .inPlace else { throw BackendSessionFailure.unsupported(plan.refusal ?? SwitchAccountRestartOffer.notReady) }
        let value: NativeRPCValue
        do { value = try await client.resource("switch.request", arguments: .object([.init("id", .string(id)), .init("target", .string(target)), .init("deferUntilIdle", .bool(false))])) }
        catch where BackendSessionSwitchNoSeat.recognizes(error) { throw BackendSessionSwitchNoSeat(sessionID: id) }
        catch { throw BackendSessionSwitchNoSeat.plainHostError(error) }
        let row = try JSONDecoder().decode(BackendHOSTDeferredSwitch.Row.self, from: value.encodedJSON())
        guard row.sessionID == id, row.targetID == target, let actual = try client.snapshot(id), actual.pid == row.pid else { throw BackendHOSTFailure.authentication }
        // 13 Oct: an older host answers a refused immediate switch with the row it started from (still "applying")
        // instead of the reason: that is not a switch, and the app must not say "Switched to".
        guard row.phase == .awaitingReread || row.phase == .confirmed else {
            throw BackendSessionFailure.unsupported("\(row.targetName) could not be handed to this session, so it is still on its account. Check that \(row.targetName) is signed in, then try again.")
        }
        try await authorization(original, "session:switch-account", [.string(id), .string(target)], true)
        if row.phase == .confirmed { guard actual.session.profileId == target else { throw BackendHOSTFailure.authentication } }
        return .init(phase: row.phase == .confirmed ? .confirmed : .awaitingReread, session: actual.session,
            requestedAccount: .init(id: row.targetID, name: row.targetName))
    }
    func arm(_ id: String, target: String) async throws -> NativeRPCValue {
        let original = try await authorize("session:switch-later", args: [.string(id), .string(target)], mutation: true)
        // A session that cannot switch in place cannot switch at its next message either: said in plain words.
        let plan: BackendSessionSwitchPlan
        do { plan = try await subject(id, target: target) }
        catch is BackendSessionSwitchNoSeat {
            throw BackendSessionFailure.unsupported(SwitchAccountRestartOffer.notReady + " Choose the account again and click Switch to move it now; it carries on with the same conversation.")
        }
        guard plan.refusal == nil, plan.mode == .inPlace else { throw BackendSessionFailure.unsupported(plan.refusal ?? SwitchAccountRestartOffer.notReady) }
        let value: NativeRPCValue
        do { value = try await client.resource("switch.request", arguments: .object([.init("id", .string(id)), .init("target", .string(target)), .init("deferUntilIdle", .bool(true))])) }
        catch { throw BackendSessionSwitchNoSeat.plainHostError(error) }
        try await authorization(original, "session:switch-later", [.string(id), .string(target)], true)
        return value
    }
    /// 18 Oct (#416): a list the session host cannot give is said, never shown as "nothing waiting".
    func armed() async throws -> [BackendSessionSwitchDeferred.Armed] {
        do {
            _ = try await authorize("session:switch-armed", args: [], mutation: false)
            let value = try await client.resource("switch.list", arguments: .object([]))
            let rows = try JSONDecoder().decode([BackendHOSTDeferredSwitch.Row].self, from: value.encodedJSON())
            return rows.filter { $0.phase == .queued }.map { .init(sessionID: $0.sessionID, accountID: $0.targetID, accountName: $0.targetName, armedAt: $0.requestedAt) }
        } catch { throw Self.said("The account changes waiting for your next message could not be read", error) }
    }
    /// 13 Oct: the account an in-place switch handed this session (the host's own register, kept across app
    /// starts), until the agent's next request proves it and the record catches up. Older hosts answer too.
    func pending(_ id: String) async -> BackendAccountIdentity? {
        do {
            _ = try await authorize("session:switch-armed", args: [], mutation: false)
            let value = try await client.resource("switch.list", arguments: .object([]))
            let rows = try JSONDecoder().decode([BackendHOSTDeferredSwitch.Row].self, from: value.encodedJSON())
            guard let row = rows.last(where: { $0.sessionID == id && ($0.phase == .applying || $0.phase == .awaitingReread) }),
                  manager.pidOf(id) == row.pid else { return nil }
            return BackendAccountIdentity(id: row.targetID, name: row.targetName)
        } catch { return nil }
    }
    func recovery(_ id: String) async -> String? {
        do { _ = try await authorize("session:switch-plan", args: [.string(id)], mutation: false)
            return try await client.resource("switch.recovery", arguments: .object([.init("id", .string(id))])).string
        } catch { log("The recovery draft of a switched session could not be read", error); return nil }
    }
    /// 18 Oct (#416): a cancel the session host refuses says so; the switch is still waiting.
    func cancel(_ id: String) async throws {
        do { _ = try await authorize("session:switch-cancel", args: [.string(id)], mutation: true)
            _ = try await client.resource("switch.cancel", arguments: .object([.init("id", .string(id))]))
        } catch { throw Self.said("The account change could not be cancelled, so it is still waiting", error) }
    }
    func stopSwitches() async {
        guard !switchesStopped else { return }
        do { try await authorization(ownerContext, "session:switch-cancel", [], true)
            _ = try await client.resource("switch.stop", arguments: .object([])); switchesStopped = true
        } catch { log("The session host's waiting account changes could not be stopped; they stay with it", error) }
    }
    func hook(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard BackendSessionHookRPC.channels.contains(channel) else { throw BackendHOSTFailure.invalid("Unknown original hook channel.") }
        let mutation = !["hooks:status", "hooks:offer", "hooks:server"].contains(channel)
        try await authorization(context, channel, args, mutation)
        let result = try await app.facade.invoke(channel, args: args, context: context)
        try await authorization(context, channel, args, mutation); return result
    }
    func observe(_ callback: @escaping @Sendable (BackendSessionHookEvent) async -> Void) -> UUID { let id = UUID(); hookObservers[id] = callback; return id }
    func removeObserver(_ id: UUID) { hookObservers[id] = nil }
    func closeObservation() { observing = false; hookObservers.removeAll() }
    /// 18 Oct (#44, #47): an event of a session that is already gone is passed over, never a wall for every later one,
    /// and a trigger that arrives mid-fetch reads once more afterwards, so the last event of a burst is not held back.
    func fetchAcceptedHooks(triggerSession: String?) async {
        guard observing, !hookObservers.isEmpty, let triggerSession, manager.list().contains(where: { $0.id == triggerSession && $0.exitCode == nil }) else { return }
        guard fetches.begin() else { return }
        repeat {
            do {
                let value = try await client.resource("hooks.accepted", arguments: .object([.init("after", .number(Double(hookSequence)))]))
                let events = try JSONDecoder().decode([BackendHOSTAcceptedHookEvent].self, from: value["events"].encodedJSON())
                for event in events.sorted(by: { $0.sequence < $1.sequence }) where event.sequence > hookSequence {
                    if let actual = BackendHOSTAcceptedHookEvent.deliverable(event, live: { id in manager.list().contains(where: { $0.id == id && $0.exitCode == nil }) }) {
                        for observer in Array(hookObservers.values) { await observer(actual) }
                    }
                    hookSequence = event.sequence
                }
            } catch { log("Accepted hook events could not be read from the session host; none was made up", error) }
        } while observing && !hookObservers.isEmpty && fetches.again()
        fetches.end()
    }
    func detachForKeep() async throws {
        guard manager.localSessionCount() == 0 else { throw BackendHOSTFailure.remote("In-app sessions still require the app to remain running.") }
        let ids = client.cachedSessions().filter { $0.exitCode == nil }.map(\.id)
        _ = try await client.resource("resources.adopted", arguments: .object([.init("ids", .array(ids.map(NativeRPCValue.string)))]))
        // L8 (11 Oct): asked a few times (2.5 s at most) and refused with the reason, not "host unavailable".
        let host = client
        try await BackendHOSTKeepDetachReadiness.wait(read: {
            let readiness = try await host.resource("resources.readiness", arguments: .object([]))
            return .init(safeToDetach: readiness["safeToDetach"].bool == true, claimsAdopted: readiness["claimsAdopted"].bool == true)
        })
        // App streams only. The helper keeps its account/MCP/hook/process owners.
        manager.detachHOSTFrontend(); await app.facade.close(); observing = false; hookObservers.removeAll()
    }
    func closeAfterDrain() async throws -> [String: BackendAccountCodexLease.Release] {
        try await Task.detached { try self.client.stopAll() }.value
        guard try await client.drain(timeoutMilliseconds: 2_000) else { throw BackendHOSTFailure.unavailable }
        _ = try await client.resource("resources.shutdown", arguments: .object([]))
        let reply = try await client.resource("resources.closed", arguments: .object([]))
        guard reply["closed"].bool == true, let fields = reply["releases"].fields else { throw BackendHOSTFailure.unavailable }
        var releases: [String: BackendAccountCodexLease.Release] = [:]
        for field in fields {
            guard releases[field.key] == nil else { throw BackendHOSTFailure.invalid("Duplicate actual Codex release.") }
            switch field.value["kind"].string {
            case "removed": releases[field.key] = .removed
            case "absent": releases[field.key] = .absent
            case "foreign": releases[field.key] = .retainedForForeignProcess
            case "capture-failed": releases[field.key] = .retainedBecauseCaptureFailed(try field.value["detail"].requireString("actual capture failure"))
            case "nothing-kept": releases[field.key] = .retainedNothingKept
            case "remove-failed": releases[field.key] = .retainedRemovalFailed
            default: throw BackendHOSTFailure.invalid("Unknown actual Codex release outcome.")
            }
        }
        await app.facade.close(); observing = false; hookObservers.removeAll(); return releases
    }
    /// 18 Oct (#416): what nobody is waiting on goes to the app log, never a private list nothing reads.
    private func log(_ what: String, _ error: Error) {
        FileHandle.standardError.write(Data(("[sessions] " + what + ": " + error.localizedDescription + "\n").utf8))
    }
    /// The host's refusal in plain words, without the transport's channel name in front.
    static func said(_ what: String, _ error: Error) -> Error {
        if error is CancellationError { return error }
        return BackendSessionFailure.unsupported(what + ": " + BackendSessionSwitchNoSeat.plain(error))
    }
}

/// Private accepted-event journal DTO. Every field comes from the ORIGINAL
/// verified helper event; metadata alone cannot manufacture these fields.
public struct BackendHOSTAcceptedHookEvent: Codable, Sendable {
    public let sequence: UInt64, provider: String, event: String, sessionID: String?, cliSessionID: String?, cwd: String?, toolName: String?
    public let receivedAt: Date, payloadJSON: Data, peerPID: Int32
    public let environmentProvider: String?, environmentDirectory: String?, environmentHome: String?, environmentWasRead: Bool?
    public init(sequence: UInt64, actual: BackendSessionHookEvent) throws {
        self.sequence = sequence; provider = actual.provider; event = actual.event; sessionID = actual.sessionID
        cliSessionID = actual.cliSessionID; cwd = actual.cwd; toolName = actual.toolName; receivedAt = actual.receivedAt
        payloadJSON = try actual.payload.encodedJSON(); peerPID = actual.peerPID
        environmentProvider = actual.agentEnvironment?.provider; environmentDirectory = actual.agentEnvironment?.configDirectory
        environmentHome = actual.agentEnvironment?.home; environmentWasRead = actual.agentEnvironment?.environmentWasRead
    }
    func original() throws -> BackendSessionHookEvent {
        guard sequence > 0, peerPID > 0, payloadJSON.count <= 1024 * 1024 else { throw BackendHOSTFailure.authentication }
        let environment: BackendAccountHookEvidence? = if let environmentProvider, let environmentWasRead {
            .init(provider: environmentProvider, configDirectory: environmentDirectory, home: environmentHome, environmentWasRead: environmentWasRead)
        } else { nil }
        return .init(provider: provider, event: event, sessionID: sessionID, cliSessionID: cliSessionID, cwd: cwd,
            toolName: toolName, receivedAt: receivedAt, payload: try NativeRPCValue.parseJSON(payloadJSON, maximumBytes: 1024 * 1024),
            agentEnvironment: environment, peerPID: peerPID)
    }
    /// 18 Oct (#44): nil for an event that cannot be read or whose session is gone; the caller moves past it.
    static func deliverable(_ event: Self, live: (String) -> Bool) -> BackendSessionHookEvent? {
        guard let actual = try? event.original(), let id = actual.sessionID, live(id) else { return nil }
        return actual
    }
}

/// 18 Oct (#47): one fetch at a time; a trigger that arrives meanwhile is kept and read by one more pass.
struct BackendHOSTHookFetchGate {
    private(set) var inFlight = false, pending = false
    mutating func begin() -> Bool { if inFlight { pending = true; return false }; inFlight = true; return true }
    mutating func again() -> Bool { defer { pending = false }; return pending }
    mutating func end() { inFlight = false; pending = false }
}
#endif
