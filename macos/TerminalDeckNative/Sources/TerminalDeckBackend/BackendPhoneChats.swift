import Foundation
import TerminalDeckNativeCore

/// Agent chats on a paired phone (iOS batch 1, step 3): the remote `chats` capability.
///
/// A Chat session is a session, so the existing verbs keep their jobs: the session list (each chat marked `chat`),
/// `rename`, `close` and `account.read` / `account.switch` (Switch, per session). This adds only what a session
/// verb cannot do for a conversation: watch it (the same typed events as Hoot's, replayed whole on every change),
/// say something, stop an answer, answer an approval, and start a new chat with an agent in a folder the Mac
/// offers this device. The app's own chat engine serves every call.
///
/// Before any call reaches here the host has already checked the device's access level for the message
/// (`BackendINT2PhoneAccessLevel.permits`: watching is a read, saying/starting is Work, answering is Full)
/// and, through `sessionField`, that the chat is visible to this device. A pushed update checks both again.
public actor BackendPhoneChats {
    /// The app's chat engine, as closures, so the adapter is tested without a live helper.
    public struct Engine: Sendable {
        public var read: @Sendable (String) async throws -> NativeRPCValue
        public var isChat: @Sendable (String) async -> Bool
        public var say: @Sendable (String, String) async throws -> Void
        public var interrupt: @Sendable (String) async throws -> Void
        public var answer: @Sendable (_ chat: String, _ request: String, _ allowed: Bool) async throws -> Void
        public var start: @Sendable (BackendRemoteCreateRequest) async throws -> BackendSessionMeta
        /// What the New session form offers for a folder: `{providers, accounts, agents, defaultProvider?}` (the
        /// Mac's own New session dialog's lists: its AIs with their models and efforts, its accounts, the folder's
        /// project agents).
        public var choices: @Sendable (_ folder: String?) async throws -> NativeRPCValue
        /// A chat's permission mode, model and effort, as its box shows them (`session:chat:options`), and a change.
        public var options: @Sendable (String) async throws -> NativeRPCValue
        public var setOptions: @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
        /// 29 Oct: Send now from a phone, the Mac's own interrupt-and-send (`session:chat:steer`).
        public var sendIdentified: (@Sendable (_ chat: String, _ text: String, _ clientMessageID: String, _ steer: Bool) async throws -> Void)?
        public var steer: @Sendable (String, String) async throws -> Void
        /// 31 Oct (`chats.files`): a message with the phone's uploaded files. The device id decides which files it may name.
        public var sendFiles: (@Sendable (_ chat: String, _ text: String, _ files: [String], _ clientMessageID: String, _ steer: Bool, _ deviceID: String) async throws -> Void)?
        public init(read: @escaping @Sendable (String) async throws -> NativeRPCValue,
                    isChat: @escaping @Sendable (String) async -> Bool,
                    say: @escaping @Sendable (String, String) async throws -> Void,
                    interrupt: @escaping @Sendable (String) async throws -> Void,
                    answer: @escaping @Sendable (String, String, Bool) async throws -> Void,
                    start: @escaping @Sendable (BackendRemoteCreateRequest) async throws -> BackendSessionMeta,
                    choices: @escaping @Sendable (String?) async throws -> NativeRPCValue = { _ in
                        .object([.init("providers", .array([])), .init("accounts", .array([])), .init("agents", .array([]))]) },
                    options: @escaping @Sendable (String) async throws -> NativeRPCValue = { _ in
                        throw NativeRPCError(code: "unavailable", message: "This Mac cannot read a chat's choices.") },
                    setOptions: @escaping @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue = { _, _ in
                        throw NativeRPCError(code: "unavailable", message: "This Mac cannot change a chat's choices.") },
                    steer: @escaping @Sendable (String, String) async throws -> Void = { _, _ in
                        throw NativeRPCError(code: "unavailable", message: "This Mac cannot send a message now while the AI answers.") }) {
            self.read = read; self.isChat = isChat; self.say = say; self.interrupt = interrupt; self.answer = answer; self.start = start
            self.choices = choices; self.options = options; self.setOptions = setOptions; self.steer = steer
        }
    }
    /// What this adapter asks of the host. Production is `init(endpoint:trust:engine:)`.
    public struct Host: Sendable {
        public var send: @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void
        /// The device may still read this chat: current access, and the chat still visible to it.
        public var stillSees: @Sendable (BackendRemoteHostContext, String) async -> Bool
        /// A chat this device just started: approval, folder and access checked again, then shown to it.
        public var admitStarted: @Sendable (BackendRemoteHostContext, BackendSessionMeta) async throws -> Void
        public init(send: @escaping @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void,
                    stillSees: @escaping @Sendable (BackendRemoteHostContext, String) async -> Bool,
                    admitStarted: @escaping @Sendable (BackendRemoteHostContext, BackendSessionMeta) async throws -> Void) {
            self.send = send; self.stillSees = stillSees; self.admitStarted = admitStarted
        }
    }

    public static let messages: Set<String> = ["chats.watch", "chats.unwatch", "chats.say", "chats.interrupt", "chats.answer", "chats.new",
                                                "chats.choices", "chats.options", "chats.set", "chats.older", "chats.steer"]
    /// Files in a chat or Hoot message (31 Oct): the phone claims it, a Mac that takes `files` says it back.
    public static let filesCapability = "chats.files"
    /// The most events one frame carries; the phone keeps the newest 600.
    static let maxEvents = 600

    private let engine: Engine
    private let host: Host
    private let now: @Sendable () -> Date
    private let beat: Duration
    private var watching: [UUID: [String: BackendRemoteHostContext]] = [:]
    private var scheduled: Set<String> = []

    public init(engine: Engine, host: Host, beat: Duration = .milliseconds(200), now: @escaping @Sendable () -> Date = { Date() }) {
        self.engine = engine; self.host = host; self.beat = beat; self.now = now
    }

    public init(endpoint: BackendRemoteHost, trust: BackendRemoteTrustStore, engine: Engine) {
        self.init(engine: engine, host: .init(
            send: { connection, message in try await endpoint.sendToConnection(connection, message: message) },
            stillSees: { context, chat in (try? await endpoint.panelSessionIDs(context))?.contains(chat) == true },
            admitStarted: { context, meta in
                // The same re-checks the host makes after a phone's `create`.
                guard await trust.isApproved(context.deviceID), await trust.canReachFolder(context.deviceID, folder: meta.cwd),
                      (try? await trust.requirePhoneAccess(context.deviceID, message: "chats.new")) != nil else {
                    throw BackendRemoteTrustFailure.denied("This device is no longer approved for that folder.")
                }
                _ = try? await trust.remoteServeIncludeStartedSession(context.deviceID, sessionID: meta.id)
                await endpoint.sessionsChanged()
            }))
    }

    public func feature() -> BackendRemoteHostFeature {
        .init(capability: "chats", messageTypes: Self.messages, policy: .grantedDevice, sessionField: "id",
              additionalAdvertisedCapabilities: engine.sendFiles == nil ? [] : [Self.filesCapability]) { [weak self] message, context in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "Chats on the phone stopped.") }
            return try await self.handle(message, context: context)
        }
    }

    func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        if message.type == "chats.new" { return [try await start(message, context: context)] }
        if message.type == "chats.choices" { return [try await choices(message, reach: context.reach)] }
        let chat = try message["id"].requireString("chat", nonempty: true)
        guard await engine.isChat(chat) else {
            return [try .error(code: "unknown-session", message: "That chat is no longer on this Mac.")]
        }
        switch message.type {
        case "chats.watch":
            watching[context.connectionID, default: [:]][chat] = context
            #if DEBUG
            let readAt = Date()
            let frame = try await conversation(chat)
            BackendRemoteRelayClient.note("open: chats.watch \(chat.prefix(8)) read in \(Int(Date().timeIntervalSince(readAt) * 1_000)) ms (\(((try? BackendRemoteProtocol.serialize(frame))?.utf8.count ?? 0) / 1024) KB)")
            return [frame]
            #else
            return [try await conversation(chat)]
            #endif
        case "chats.unwatch":
            watching[context.connectionID]?[chat] = nil
            return []
        case "chats.older":
            // The page before what the phone has (27 Oct: a chat showed only its newest ~64 KB, with no way back).
            return [try await conversation(chat, before: message["before"].number.map { Int($0) } ?? 0)]
        case "chats.say", "chats.steer":
            let files = (message["files"].elements ?? []).compactMap(\.string)
            let text = try message["text"].requireString("message", nonempty: files.isEmpty)
            if !files.isEmpty {
                guard let send = engine.sendFiles else { return [try .error(code: "unavailable", message: "This Mac cannot take files in a chat yet.")] }
                try await send(chat, text, files, BackendChatRetryIdentity.messageID(message["clientMessageId"].string, caller: "phone:" + context.deviceID, conversation: chat, text: text + files.joined(separator: "\n"), frame: message.value, now: now()), message.type == "chats.steer", context.deviceID)
                return []
            }
            if let send = engine.sendIdentified {
                try await send(chat, text, BackendChatRetryIdentity.messageID(message["clientMessageId"].string, caller: "phone:" + context.deviceID, conversation: chat, text: text, frame: message.value, now: now()), message.type == "chats.steer")
            } else if message.type == "chats.steer" { try await engine.steer(chat, text) }
            else { try await engine.say(chat, text) }
            return []
        case "chats.interrupt":
            try await engine.interrupt(chat)
            return []
        case "chats.answer":
            // Full control only (the host's access check); the engine answers only a request still waiting.
            try await engine.answer(chat, try message["request"].requireString("request", nonempty: true), message["approved"].bool == true)
            return []
        case "chats.options":
            return [try Self.optionsFrame(chat, try await engine.options(chat))]
        case "chats.set":
            // Model and effort are Work; what the AI may do without asking is the same call as an approval: Full.
            if message["permissionMode"] != .missing, !Self.fullControl(context) {
                return [try .error(code: "unauthorized", message: "Changing what the AI may do without asking needs Full control. Change this phone's access on the Mac.")]
            }
            var patch: [NativeRPCValue.Field] = []
            for key in ["permissionMode", "model", "effort"] { if let value = message[key].string { patch.append(.init(key, .string(value))) } }
            return [try Self.optionsFrame(chat, try await engine.setOptions(chat, .object(patch)))]
        default:
            throw NativeRPCError.invalidArguments("Unknown chat operation.")
        }
    }

    /// Full control: the level the host issued, or (a Mac without levels) the person's own device.
    static func fullControl(_ context: BackendRemoteHostContext) -> Bool {
        context.phoneAccess.map { $0 == .full } ?? (context.kind == .mine)
    }
    /// A new session's login and permission mode are Full control: Work may start a session, not choose whose
    /// login it spends or what it may do without asking.
    public static func mayChooseLoginAndMode(_ choices: BackendRemoteStartChoices, _ context: BackendRemoteHostContext) -> Bool {
        (choices.account == nil && choices.permissionMode == nil) || fullControl(context)
    }
    public static let fullControlNeeded = "Choosing the login or the permission mode of a new session needs Full control. Change this phone's access on the Mac."


    /// A chat's box, as the phone draws it: the mode, the model and its choices, the effort and its levels.
    static func optionsFrame(_ id: String, _ options: NativeRPCValue) throws -> BackendRemoteServerMessage {
        var fields: [NativeRPCValue.Field] = [.init("models", .array(offeredModels(options))),
            .init("efforts", .array((options["efforts"].elements ?? []).compactMap(\.string).prefix(16).map(NativeRPCValue.string)))]
        for key in ["permissionMode", "model", "effort", "recommendedEffort"] {
            if let value = options[key].string { fields.append(.init(key, .string(key == "model" ? shownModel(value, options) : value))) }
        }
        return try .init(.chatsOptions, fields: [.init("id", .string(id)), .init("options", .object(fields))])
    }
    /// A Claude Code alias in use ("claude:opus[1m]") is the live model it stands for, so the sheet ticks that row.
    static func shownModel(_ model: String, _ options: NativeRPCValue) -> String {
        let parts = model.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let live = aliasTarget(parts[1], options["catalog"][parts[0]]) else { return model }
        return parts[0] + ":" + live
    }
    private static func aliasTarget(_ model: String, _ section: NativeRPCValue) -> String? {
        let listed = ((section["featured"].elements ?? []) + (section["more"].elements ?? [])).compactMap(\.string)
        guard !listed.contains(model), let live = BackendSessionChats.liveModel(forAlias: model, in: section),
              (section["models"].elements ?? []).contains(where: { $0["id"].string == live }) else { return nil }
        return live
    }

    /// The models the Mac's box offers, one list: each AI's live featured and older models (the catalogue), then
    /// the ones it reports in use. Each id is `<ai>:<model>`, as the chat engine takes it back. At most 64.
    static func offeredModels(_ options: NativeRPCValue) -> [NativeRPCValue] {
        let names = ["claude": "Claude", "codex": "Codex", "gemini": "Gemini"]
        func placeholder(_ id: String) -> Bool {
            ["default", "auto", ""].contains((id.split(separator: ":").last.map(String.init) ?? "").lowercased().replacingOccurrences(of: "[1m]", with: ""))
        }
        var out: [NativeRPCValue] = [], seen = Set<String>()
        func add(_ id: String, _ name: String, _ ai: String, detail: String, more: Bool) {
            guard !placeholder(id), seen.insert(id).inserted else { return }
            out.append(.object([.init("id", .string(id)), .init("name", .string(name)), .init("provider", .string(ai)),
                                .init("detail", .string(detail)), .init("more", .bool(more))]))
        }
        for provider in ["claude", "codex", "gemini"] {
            let live = options["catalog"][provider], rows = live["models"].elements ?? []
            let featured = Set((live["featured"].elements ?? []).compactMap(\.string))
            for listed in ((live["featured"].elements ?? []) + (live["more"].elements ?? [])).compactMap(\.string) {
                guard let row = rows.first(where: { $0["id"].string == listed }) else { continue }
                let older = !featured.contains(listed)
                add(provider + ":" + listed, row["name"].string ?? listed, names[provider] ?? provider,
                    detail: modelDetail(row, older: older), more: older)
            }
        }
        for row in options["models"].elements ?? [] {
            guard let id = row["id"].string, id.contains(":") else { continue }
            let provider = String(id.split(separator: ":").first ?? "")
            // An alias in use is already listed as the live model it stands for (see shownModel).
            if aliasTarget(String(id.split(separator: ":", maxSplits: 1).last ?? ""), options["catalog"][provider]) != nil { continue }
            add(id, row["name"].string ?? id, names[provider] ?? row["provider"].string ?? provider, detail: "In use now", more: false)
        }
        return Array(out.prefix(64))
    }

    /// A model's one line under its name in the phone's Select model sheet, from the live catalogue's own facts
    /// (never a written description): the newest of its line or an earlier one, and how much it can read at once.
    static func modelDetail(_ row: NativeRPCValue, older: Bool) -> String {
        // Claude Code's own list says it in its own words ("Opus 5.5 · Best for everyday, complex tasks").
        if let about = row["description"].string, !about.isEmpty { return about }
        let window = max(row["maxContextWindow"].number ?? 0, row["contextWindow"].number ?? 0)
        let context = row["oneMillion"].bool == true || window >= 1_000_000 ? "1M context"
            : window >= 1000 ? "\(Int(window / 1000))K context" : nil
        return [older ? "Earlier model" : "Newest of its line", context].compactMap { $0 }.joined(separator: " · ")
    }

    /// The New session form's lists for one folder, bounded (a list bomb never reaches a phone).
    /// The Mac's last New session folder is the owner's own path: it goes only to a device that may start there
    /// (the owner's device, or a guest whose given folders hold it), never as news of a folder outside its grant.
    private func choices(_ message: BackendRemoteClientMessage, reach: BackendRemoteDeviceReach) async throws -> BackendRemoteServerMessage {
        let rid = try message["rid"].requireString("request", nonempty: true)
        let lists = try await engine.choices(message["cwd"].string)
        func bounded(_ key: String) -> NativeRPCValue { .array(Array((lists[key].elements ?? []).prefix(64))) }
        var fields: [NativeRPCValue.Field] = [.init("rid", .string(rid)), .init("providers", bounded("providers")),
                                              .init("accounts", bounded("accounts")), .init("agents", bounded("agents"))]
        if let preferred = lists["defaultProvider"].string { fields.append(.init("defaultProvider", .string(preferred))) }
        if let mode = lists["openAs"].string, ["chat", "terminal"].contains(mode) { fields.append(.init("openAs", .string(mode))) }
        if let folder = lists["defaultFolder"].string, folder.hasPrefix("/"), folder.utf8.count <= 1024,
           reach.unrestricted || reach.folders.contains(where: { BackendRemoteTrustStore.within($0, folder) }) {
            fields.append(.init("defaultFolder", .string(folder)))
        }
        return try .init(.chatsChoices, fields: fields)
    }

    private func start(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> BackendRemoteServerMessage {
        guard Self.mayChooseLoginAndMode(BackendRemoteStartChoices(message: message), context) else {
            return try .error(code: "unauthorized", message: Self.fullControlNeeded)
        }
        let planned: BackendRemoteCreateRequest
        switch BackendRemoteServeSessionCreate.plan(.init(message: message, deviceID: context.deviceID),
                                                    offered: context.reach.folders, unrestricted: context.reach.unrestricted) {
        case .failure(let refusal): return try .error(code: refusal.code, message: refusal.message)
        case .success(let request): planned = request
        }
        guard let provider = planned.provider, BackendCreateSessionInput.chatProviders.contains(provider) else {
            return try .error(code: "unauthorized", message: "A chat runs with Claude, Codex or Gemini.")
        }
        let meta = try await engine.start(planned)
        try await host.admitStarted(context, meta)
        return try BackendRemoteServeSessionCreate.Outcome.created(meta).message()
    }

    /// One chat's conversation as the phone reads it: its newest events that fit one frame, each within the
    /// same bounds as Hoot's phone events (one conversation, text up to 64 KiB, tool input up to 16 KiB).
    /// The newest page (`before` nil: the watch and every push, `reset`), or the page that ends just before event
    /// `before` (`older`). Each page says where it starts among all the conversation's events (`first`) and how many
    /// there are (`total`), so a phone can ask for the page before it.
    public func conversation(_ chat: String, before: Int? = nil) async throws -> BackendRemoteServerMessage {
        // A picture's bytes never travel to a phone: each page carries its stand-in (BackendChatMedia), so a chat
        // with pictures still pages back through all of its history (28 Oct).
        let snapshot = BackendChatMedia.slim(try await engine.read(chat))
        let conversation = snapshot["conversationId"].string.flatMap { $0.isEmpty ? nil : $0 } ?? chat
        let all = (snapshot["events"].elements ?? []).map { BackendChatMessageActions.phoneEvent(ChatRenderedContent.phoneEvent($0), actions: snapshot["messageActions"].elements ?? []) }.filter { event in
            guard let decoded = try? HootChatEvent(wire: event), decoded.conversationID == conversation else { return false }
            return (event["value"]["text"].string?.utf8.count ?? 0) <= 65536
                && ((try? event["value"]["input"].encodedJSON().count) ?? 0) <= 16384
        }
        let end = min(max(before ?? all.count, 0), all.count)
        var first = max(0, end - Self.maxEvents)
        var events = Array(all[first..<end])
        let busy = BackendHootChatStore.foreground(in: snapshot)
        var includeRendered = true
        func frame() throws -> BackendRemoteServerMessage {
            var fields: [NativeRPCValue.Field] = [.init("id", .string(chat)), .init("conversationId", .string(conversation)),
                .init("reset", .bool(before == nil)), .init("foreground", .bool(busy)), .init("busy", .bool(busy)), .init("events", .array(events)),
                .init("renderedMessages", includeRendered ? ChatRenderedContent.phoneMessages(events) : .array([])),
                .init("first", .number(Double(first))), .init("total", .number(Double(all.count)))]
            if before != nil { fields.append(.init("older", .bool(true))) }
            return try .init(.chatsEvents, fields: fields)
        }
        let limit = BackendRemoteProtocol.limits["MAX_MESSAGE_BYTES"] ?? 1_048_576
        // Drop the oldest by their own sizes first (one encoding each), then check the whole frame.
        let drop = BackendINT2HootPhone.oldestToDrop(events, budget: limit - 1_024)
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

    /// The chat engine published a change. Every phone watching that chat gets its current conversation, at most
    /// once per beat while an answer streams.
    public func published(_ chat: String) {
        for (connection, chats) in watching where chats[chat] != nil {
            let key = connection.uuidString + "|" + chat
            guard !scheduled.contains(key) else { continue }
            scheduled.insert(key)
            Task { [weak self, beat] in
                try? await Task.sleep(for: beat)
                await self?.push(connection, chat)
            }
        }
    }

    private func push(_ connection: UUID, _ chat: String) async {
        scheduled.remove(connection.uuidString + "|" + chat)
        guard let context = watching[connection]?[chat] else { return }
        guard await host.stillSees(context, chat) else {
            watching[connection]?[chat] = nil
            return
        }
        guard let frame = try? await conversation(chat) else { return }
        do { try await host.send(connection, frame) } catch { watching[connection] = nil }
    }

    /// Which chats a connection watches (tests and diagnostics).
    func watched(by connection: UUID) -> Set<String> { Set(watching[connection]?.keys.map { $0 } ?? []) }

    public func disconnected(_ connection: UUID) { watching[connection] = nil }
    public func stop() { watching.removeAll(); scheduled.removeAll() }
}
