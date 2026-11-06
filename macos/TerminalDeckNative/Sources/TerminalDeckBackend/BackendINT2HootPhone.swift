import Foundation
import TerminalDeckNativeCore

/// Paired phones observe and control the SAME desk conversation. No per-device
/// process or transcript exists here. Only the original consent broker answers.
public actor BackendINT2HootPhone: BackendDeckCoreConsentRelay {
    private let trust: BackendRemoteTrustStore, endpoint: BackendRemoteHost
    private let consent: BackendDeckCoreSecurityConsentBroker
    private let runtime: @Sendable () async -> BackendCopilotSessionRuntime?
    private let log: @Sendable (Int) async -> [NativeRPCValue]
    private let setInteractive: @Sendable (Bool) async throws -> Void
    /// Switch (iOS batch 1): Hoot's ready state (`hoot:ready:read`: its AI, account and that AI's accounts) and
    /// the write Hoot's own account dropdown makes (`profiles:set-level` on the orchestrator seat). Nil: not offered.
    private let readAccounts: (@Sendable () async throws -> NativeRPCValue)?
    private let switchAccount: (@Sendable (_ provider: String, _ account: String) async throws -> Void)?
    /// Hoot's box (iOS batch 1): its permission mode, model and effort (`hoot:chat:options`); nil reads, a patch
    /// changes them. Nil: not offered.
    private let options: (@Sendable (_ patch: NativeRPCValue?) async throws -> NativeRPCValue)?
    /// 31 Oct (`chats.files`): the phone's uploaded files for Hoot's AI, `(files, text, provider, device)` → attachments
    /// and the message. Nil: not offered (the capability is not said back).
    public typealias Attach = @Sendable (_ files: [String], _ text: String, _ provider: String, _ deviceID: String) async throws -> (attachments: [NativeRPCValue], text: String)
    private var attach: Attach?
    public func setAttach(_ attach: Attach?) { self.attach = attach }
    private var watchers: [UUID: Task<Void, Never>] = [:]
    private var contexts: [UUID: BackendRemoteHostContext] = [:]
    /// The last conversation each phone was sent, so it can read back from it (`hoot.older`).
    private var latest: [UUID: NativeRPCValue] = [:]
    public init(trust: BackendRemoteTrustStore, endpoint: BackendRemoteHost, consent: BackendDeckCoreSecurityConsentBroker,
                runtime: @escaping @Sendable () async -> BackendCopilotSessionRuntime?,
                log: @escaping @Sendable (Int) async -> [NativeRPCValue],
                setInteractive: @escaping @Sendable (Bool) async throws -> Void,
                readAccounts: (@Sendable () async throws -> NativeRPCValue)? = nil,
                switchAccount: (@Sendable (_ provider: String, _ account: String) async throws -> Void)? = nil,
                options: (@Sendable (_ patch: NativeRPCValue?) async throws -> NativeRPCValue)? = nil) {
        self.trust = trust; self.endpoint = endpoint; self.consent = consent; self.runtime = runtime
        self.log = log; self.setInteractive = setInteractive
        self.readAccounts = readAccounts; self.switchAccount = switchAccount; self.options = options
    }
    public static let accountMessages: Set<String> = ["hoot.account.read", "hoot.account.switch", "hoot.options.read", "hoot.options.set"]
    public func feature() -> BackendRemoteHostFeature {
        .init(capability: "hoot", messageTypes: Set(BackendCopilotRemoteSurface.frameTier.keys).union(BackendCopilotRemoteSurface.untiered)
            .subtracting(["hoot.files", "hoot.file.read", "hoot.file.write", "hoot.file.reset", "hoot.memory.delete"])
            .union(Self.accountMessages),
            policy: .ownerOnly, additionalAdvertisedCapabilities: attach == nil ? ["hoot.events"] : ["hoot.events", BackendPhoneChats.filesCapability]) { [weak self] message, context in
                guard let self else { throw NativeRPCError(code: "unavailable", message: "Hoot's phone connection stopped.") }
                return try await self.handle(message, context: context)
            }
    }
    private func require(_ source: BackendRemoteHostContext, verb: String) async throws -> BackendRemoteHostContext {
        let current = try await endpoint.refreshedContext(source)
        guard current.kind == .mine, await BackendCopilotRemoteAccess(trust: trust).linked(current.deviceID) else {
            throw NativeRPCError(code: "access-denied", message: "Hoot is not shared with this device.")
        }
        try await trust.requirePhoneAccess(current.deviceID, message: verb)
        return current
    }
    private func desk() async throws -> BackendCopilotSessionRuntime {
        guard let value = await runtime() else { throw NativeRPCError(code: "unavailable", message: "The shared Hoot owner is not ready.") }
        return value
    }
    private func pending(_ context: BackendRemoteHostContext) async -> [NativeRPCValue] {
        var rows: [NativeRPCValue] = []
        for question in await consent.list() {
            guard await consent.mayAnswer(id: question.id, by: "device:" + context.deviceID) else { continue }
            rows.append(BackendCopilotRemoteWiring.pendingRow(question, mine: context.phoneAccess == .full)
                .setting("args", question.arguments).setting("tier", .string(question.tier.rawValue)))
        }
        return rows
    }
    private func handle(_ frame: BackendRemoteClientMessage, context source: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        let context = try await require(source, verb: frame.type), owner = try await desk()
        contexts[context.connectionID] = context
        switch frame.type {
        case "hoot.hello":
            let level = context.phoneAccess
            return [try .init(.copilotGrant, fields: [.init("link", .object([.init("linked", .bool(true)), .init("open", .bool(true)),
                .init("grant", .object([.init("read", .bool(level != nil)), .init("act", .bool(level != .look)), .init("alter", .bool(level == .full))]))]))])]
        case "hoot.bye", "hoot.detach": await disconnected(context.connectionID); return []
        case "hoot.attach":
            guard context.claimedCapabilities.contains("hoot.events"), let chat = owner.structuredChat else {
                throw NativeRPCError(code: "unavailable", message: "Update the phone to read Hoot's structured conversation.")
            }
            watchers[context.connectionID]?.cancel()
            let stream = await chat.subscribe()
            watchers[context.connectionID] = Task { [weak self] in
                for await snapshot in stream {
                    guard !Task.isCancelled, let self else { break }
                    do { try await self.publish(snapshot, context: context) } catch { break }
                }
            }
            return []
        case "hoot.older":
            // The page before what the phone has (27 Oct: Hoot showed only its newest ~64 KB, with no way back).
            guard let snapshot = latest[context.connectionID] else { return [] }
            return [try Self.page(snapshot, before: frame["before"].number.map { Int($0) } ?? 0)]
        case "hoot.state": return [try .init(.copilotState, fields: [.init("state", try await owner.invoke("hoot:state", arguments: []))])]
        case "hoot.sessions":
            let visible = try await endpoint.panelSessionIDs(context)
            let rows = endpoint.manager.list().filter { visible.contains($0.id) }.map(BackendCompositionSuppliers.sessionWire)
            return [try .init(.copilotSessions, fields: [.init("sessions", .array(rows))])]
        case "hoot.log":
            let count = min(200, max(1, Int(frame["limit"].number ?? 100)))
            return [try .init(.copilotLog, fields: [.init("rows", .array(await log(count))), .init("more", .bool(false))])]
        case "hoot.pending": return [try .init(.copilotPending, fields: [.init("questions", .array(await pending(context)))])]
        case "hoot.answer":
            let id = try frame["id"].requireString("question", nonempty: true)
            _ = try await require(context, verb: "hoot.answer")
            guard await consent.mayAnswer(id: id, by: "device:" + context.deviceID) else {
                throw NativeRPCError(code: "stale-approval", message: "This confirmation expired, was answered, or belongs to another caller.")
            }
            if await consent.list().contains(where: { $0.id == id && $0.tool == "hoot.cli" }) {
                guard let chat = owner.structuredChat else { throw NativeRPCError(code: "unavailable", message: "Hoot's question owner is unavailable.") }
                try await chat.answerBroker(id: id, allowed: frame["approved"].bool == true, by: "device:" + context.deviceID,
                    answers: frame["answers"].isNullish ? .object([]) : frame["answers"])
            } else {
                guard await consent.respond(id: id, approved: frame["approved"].bool == true, by: "device:" + context.deviceID) else {
                    throw NativeRPCError(code: "stale-approval", message: "This confirmation is no longer pending.")
                }
            }
            return [try .init(.copilotPending, fields: [.init("questions", .array(await pending(context)))])]
        case "hoot.start": _ = try await owner.ensure(); return []
        case "hoot.say":
            _ = try await owner.ensure(); let current = try await require(context, verb: frame.type)
            guard let chat = owner.structuredChat else { throw NativeRPCError(code: "unavailable", message: "Hoot's structured conversation is unavailable.") }
            let files = (frame["files"].elements ?? []).compactMap(\.string)
            var text = try frame["text"].requireString("message"), attachments: [NativeRPCValue] = []
            if !files.isEmpty {
                guard let attach else { throw NativeRPCError(code: "unavailable", message: "This Mac cannot take files for Hoot yet.") }
                (attachments, text) = try await attach(files, text, chat.provider.rawValue, current.deviceID)
            }
            _ = try await chat.say(text, attachments: attachments,
                consentCaller: .init(kind: .remote, tiers: current.phoneAccess?.tiers ?? [], deviceID: current.deviceID), clientMessageID: BackendChatRetryIdentity.messageID(frame["clientMessageId"].string, caller: "phone:" + current.deviceID, conversation: chat.conversationID, text: try frame["text"].requireString("message"), frame: frame.value)); return []
        case "hoot.cancel": try await owner.structuredChat?.interrupt(); return []
        case "hoot.stop": _ = try await owner.stop(); return []
        case "hoot.interactive": try await setInteractive(frame["on"].bool == true); return []
        case "hoot.account.read":
            guard let readAccounts else { throw NativeRPCError(code: "unavailable", message: "This Mac does not switch Hoot's account from a phone.") }
            return [try Self.accountState(rid: frame["rid"].string ?? "", ready: try await readAccounts())]
        case "hoot.account.switch":
            guard let readAccounts, let switchAccount else { throw NativeRPCError(code: "unavailable", message: "This Mac does not switch Hoot's account from a phone.") }
            let rid = frame["rid"].string ?? "", account = try frame["accountId"].requireString("account", nonempty: true)
            let ready = try await readAccounts(), provider = ready["provider"].string ?? ""
            // Only an account of the AI Hoot runs: another AI's login cannot run this conversation.
            guard (ready["accounts"].elements ?? []).contains(where: { $0["id"].string == account && $0["provider"].string == provider }) else {
                return [try Self.accountSwitched(rid: rid, ok: false, message: "That account is not one Hoot's AI can use.")]
            }
            try await switchAccount(provider, account)
            return [try Self.accountSwitched(rid: rid, ok: true, message: "Hoot switches to this account the next time it starts. This conversation stays.")]
        case "hoot.options.read":
            guard let options else { throw NativeRPCError(code: "unavailable", message: "This Mac does not show Hoot's choices on a phone.") }
            return [try BackendPhoneChats.optionsFrame("hoot", try await options(nil))]
        case "hoot.options.set":
            // Full control only (the host's access check): Hoot's own mode, model and effort, as its box on the Mac.
            guard let options else { throw NativeRPCError(code: "unavailable", message: "This Mac does not change Hoot's choices from a phone.") }
            var patch: [NativeRPCValue.Field] = []
            for key in ["permissionMode", "model", "effort"] { if let value = frame[key].string { patch.append(.init(key, .string(value))) } }
            return [try BackendPhoneChats.optionsFrame("hoot", try await options(.object(patch)))]
        default: throw NativeRPCError(code: "unavailable", message: "This Hoot phone operation has no shared-owner adapter yet.")
        }
    }
    /// Hoot's accounts in the session account shape (`account.state`, id `hoot`): only its own AI's, so a row can
    /// always run Hoot's conversation.
    static func accountState(rid: String, ready: NativeRPCValue) throws -> BackendRemoteServerMessage {
        let provider = ready["provider"].string ?? ""
        // The live sign-in facts (`signIns`, as the Mac's own Hoot setup reads them), else the ready state's flag.
        var facts: [String: CodingAISignIn] = [:]
        let rows: [NativeRPCValue] = (ready["accounts"].elements ?? []).filter { $0["provider"].string == provider }.compactMap { account in
            guard let id = account["id"].string, !id.isEmpty else { return nil }
            var signIn = NativeRPCValue.object([.init("state", .string(account["signedIn"].bool == true ? "signed-in" : "signed-out")), .init("account", .null)])
            let live = ready["signIns"][id]
            if live.fields != nil {
                let fact = CodingAIAccountsParse.signIn(CodingAIJSON(live.foundation))
                facts[id] = fact
                signIn = .object([.init("state", .string(fact.state.rawValue)), .init("account", fact.account.map(NativeRPCValue.string) ?? .null)])
            }
            return .object([.init("id", .string(id)), .init("name", .string(account["name"].string ?? id)), .init("provider", .string(provider)),
                .init("color", .null), .init("system", .bool(id == "system" || id.hasPrefix("system:"))), .init("signIn", signIn)])
        }
        // One row per login, as the Mac's own lists show them: this Mac's own sign-in and its kept copy are one row,
        // a login whose saved name is stale is not hidden; Hoot's own account stays.
        let logins = rows.compactMap { row -> CodingAIAccount? in
            guard let id = row["id"].string else { return nil }
            let system = row["system"].bool == true
            return CodingAIAccount(id: id, name: row["name"].string ?? id, provider: provider, system: system, keptBy: system ? .agent : .app)
        }
        let copies = CodingAILogins.duplicates(logins, signIn: facts, prefer: ready["profileId"].string)
        let shown = rows.filter { copies[$0["id"].string ?? ""] == nil }
        let current = ready["profileId"].string.flatMap { id in shown.first { $0["id"].string == id } } ?? .null
        return try .init(.accountState, fields: [.init("rid", .string(rid)), .init("id", .string("hoot")),
            .init("current", current), .init("accounts", .array(shown))])
    }
    static func accountSwitched(rid: String, ok: Bool, message: String) throws -> BackendRemoteServerMessage {
        try .init(.accountSwitched, fields: [.init("rid", .string(rid)), .init("id", .string("hoot")),
            .init("ok", .bool(ok)), .init("message", .string(message)), .init("session", .null)])
    }
    private func publish(_ snapshot: NativeRPCValue, context: BackendRemoteHostContext) async throws {
        let current = try await require(context, verb: "hoot.attach")
        guard contexts[current.connectionID] != nil else { throw CancellationError() }
        latest[current.connectionID] = snapshot
        try await endpoint.sendToConnection(current.connectionID, message: try Self.page(snapshot, before: nil))
    }

    /// The newest events that fit one frame (`before` nil: every push, `reset`), or the page ending just before
    /// event `before` (`older`); each says where it starts (`first`) among all of them (`total`).
    public static func historyFrame(_ store: BackendHootChatStore) async throws -> BackendRemoteServerMessage {
        try page(await store.snapshot(limit: 100_000), before: nil)
    }

    static func page(_ snapshot: NativeRPCValue, before: Int?) throws -> BackendRemoteServerMessage {
        // The store's own per-row actions: Hoot's Rewind/Fork enforce provider boundaries, so phones offer only those.
        let actions = snapshot["messageActions"].elements ?? []
        let all = (snapshot["events"].elements ?? []).map { BackendChatMessageActions.phoneEvent(ChatRenderedContent.phoneEvent($0), actions: actions) }
        let end = min(max(before ?? all.count, 0), all.count)
        var first = max(0, end - 600)
        var events = Array(all[first..<end])
        var includeRendered = true
        func frame() throws -> BackendRemoteServerMessage {
            var fields: [NativeRPCValue.Field] = [.init("conversationId", snapshot["conversationId"]), .init("reset", .bool(before == nil)),
                .init("foreground", .bool(BackendHootChatStore.foreground(in: snapshot))),
                .init("events", .array(events)), .init("renderedMessages", includeRendered ? ChatRenderedContent.phoneMessages(events) : .array([])), .init("first", .number(Double(first))), .init("total", .number(Double(all.count)))]
            if before != nil { fields.append(.init("older", .bool(true))) }
            return try .init(.hootEvents, fields: fields)
        }
        let limit = BackendRemoteProtocol.limits["MAX_MESSAGE_BYTES"]!
        let drop = oldestToDrop(events, budget: limit - 1_024)
        events.removeFirst(drop); first += drop
        var message = try frame()
        // Original message text always wins the shared frame budget. A phone can
        // derive the same visual fences from it when the additive block hints do not fit.
        if try message.value.encodedJSON().count > limit { includeRendered = false; message = try frame() }
        while try message.value.encodedJSON().count > limit, !events.isEmpty {
            events.removeFirst()
            first += 1
            message = try frame()
        }
        return message
    }

    /// How many of the oldest events to leave out so the rest fit `budget` bytes, each measured once (re-encoding
    /// the whole frame per dropped event took seconds for a long conversation).
    static func oldestToDrop(_ events: [NativeRPCValue], budget: Int) -> Int {
        let sizes = events.map { ((try? $0.encodedJSON().count) ?? 0) + 1 }
        var total = sizes.reduce(0, +), drop = 0
        while total > budget, drop < sizes.count { total -= sizes[drop]; drop += 1 }
        return drop
    }
    public func ask(_ request: BackendDeckCoreSecurityConsentRequest) async throws -> Bool {
        var delivered = false
        for context in contexts.values {
            guard (try? await require(context, verb: "hoot.answer")) != nil,
                  await consent.mayAnswer(id: request.id, by: "device:" + context.deviceID) else { continue }
            try await endpoint.sendToConnection(context.connectionID, message: .init(.copilotAsk, fields: [.init("question", BackendCopilotRemoteWiring.consentQuestion(request))]))
            delivered = true
        }
        return delivered
    }
    public func settled(id: String, outcome: BackendDeckCoreSecurityConsentOutcome) async throws {
        for context in contexts.values where (try? await require(context, verb: "hoot.pending")) != nil {
            try await endpoint.sendToConnection(context.connectionID, message: .init(.copilotSettled, fields: [.init("settled", .object([
                .init("id", .string(id)), .init("granted", .bool(outcome.granted)), .init("by", outcome.by.map(NativeRPCValue.string) ?? .null)]))]))
        }
    }
    public func disconnected(_ id: UUID) async {
        watchers[id]?.cancel(); watchers[id] = nil; latest[id] = nil
        if let context = contexts.removeValue(forKey: id) { try? await consent.callerGone("device:" + context.deviceID) }
    }
    public func stop() async { for id in Array(contexts.keys) { await disconnected(id) } }
}
