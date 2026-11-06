import Foundation
import TerminalDeckNativeCore

/// The helper owns the existing conversation engine, decoder, permission waiters
/// and job completion. Its chat files are the replay journal; clients never write them.
public actor BackendHOSTChats {
    private let manager: BackendPTYManager
    private let directory: URL
    private let modelCatalogue: @Sendable () async -> NativeRPCValue
    private var engine: BackendSessionChats?
    private var opening: Task<BackendSessionChats, Error>?
    private var observers: [UUID: AsyncStream<NativeRPCValue>.Continuation] = [:]
    private var latest: [String: NativeRPCValue] = [:]
    private var processBinding: (@Sendable (String, Int32) async throws -> Void)?
    public func setProcessBinding(_ bind: @escaping @Sendable (String, Int32) async throws -> Void) { processBinding = bind }
    private func processStarted(_ id: String, _ pid: Int32) async throws { try await processBinding?(id, pid) }
    private var launches: [String: Data] = [:]
    public init(manager: BackendPTYManager, directory: URL,
                modelCatalogue: @escaping @Sendable () async -> NativeRPCValue = { await BackendHootModelSource.liveCatalogue() }) {
        self.manager = manager; self.directory = directory; self.modelCatalogue = modelCatalogue
    }
    private func owner() async throws -> BackendSessionChats {
        if let engine { return engine }
        if let opening { return try await opening.value }
        let task = Task { [manager, directory, modelCatalogue] in
            let chats = BackendSessionChats(manager: manager, directory: directory,
                publish: { [weak self] id, snapshot in await self?.changed(id, snapshot) },
                processStarted: { [weak self] id, pid in try await self?.processStarted(id, pid) }, modelCatalogue: modelCatalogue)
            try await chats.restoreJobHistory()
            return chats
        }
        opening = task
        defer { opening = nil }
        let chats = try await task.value; engine = chats; return chats
    }
    private func changed(_ id: String, _ snapshot: NativeRPCValue) async {
        let job = await engine?.conversation(id)
        let value = NativeRPCValue.object([.init("id", .string(id)), .init("snapshot", snapshot),
            .init("job", (try? job.map { try NativeRPCValue.parseJSON(JSONEncoder().encode($0)) }) ?? .null)])
        // 18 Oct (#76): only a chat that still exists is replayed to the next app; a late update of a gone one is not kept.
        var current = job != nil
        if !current { current = await engine?.isChat(id) ?? false }
        latest[id] = current ? value : nil
        for observer in observers.values { observer.yield(value) }
    }
    /// The operations after which a chat is gone from this helper (a kept team history is read again on subscribe).
    static func endsChat(_ method: String) -> Bool { ["chats.close", "chats.remove", "chats.delete"].contains(method) }
    public func subscribe() async throws -> AsyncStream<NativeRPCValue> {
        let chats = try await owner()
        // A reconnect gets CURRENT state (including permissions), not a dead app's cache.
        for meta in manager.list() where meta.chat == true {
            if let snapshot = try? await chats.read(meta.id, cursor: nil, limit: 500) { await changed(meta.id, snapshot) }
        }
        let id = UUID(), pair = AsyncStream<NativeRPCValue>.makeStream(bufferingPolicy: .bufferingNewest(128))
        observers[id] = pair.continuation
        for value in latest.values { pair.continuation.yield(value) }
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return pair.stream
    }
    private func unsubscribe(_ id: UUID) async {
        observers[id] = nil
        guard observers.isEmpty, let engine else { return }
        _ = await engine.stopTransientVoice()
    }
    /// Old apps reconcile by text after losing a reply. They cannot safely enter a send at all.
    /// Keep this before owner(): restoring a conversation can await work past the old 10 s deadline.
    static func validateDeliveryIdentity(_ method: String, payload: Data) throws {
        guard method == "chats.say" || method == "chats.steer" else { return }
        let args = try NativeRPCValue.parseJSON(payload)
        guard let id = args["clientMessageId"].string,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // The old Send now catch recognizes these words and leaves the row held; its
            // ordinary send catch restores the draft and attachments to the composer.
            throw NativeRPCError(code: "chat-steering-unavailable", message: "Not sent. Update the app before sending to this keeper. Your message is held in the queue.")
        }
    }
    public func invoke(_ method: String, payload: Data) async throws -> Data {
        try Self.validateDeliveryIdentity(method, payload: payload)
        if method == "chats.say" || method == "chats.steer" {
            let message = try NativeRPCValue.parseJSON(payload)
            let queue = BackendChatDeliveryQueue(directory: directory.appendingPathComponent("delivery-requests"))
            if try queue.begin(message) { return try await invokeOnce("chats.read", payload: payload) }
            do {
                let result = try await invokeOnce(method, payload: payload)
                try queue.finish(message)
                return result
            } catch { queue.refused(message, error: error); throw error }
        }
        return try await invokeOnce(method, payload: payload)
    }
    private func invokeOnce(_ method: String, payload: Data) async throws -> Data {
        // Detaching audio must not instantiate an engine or restore/start any conversation.
        if method == "chats.voice-detach" {
            let args = try NativeRPCValue.parseJSON(payload)
            let reply = await engine?.stopTransientVoice(args["id"].string)
                ?? .object([.init("stopped", .bool(true)), .init("sessions", .array([]))])
            return try reply.encodedJSON()
        }
        let chats = try await owner(), args = try NativeRPCValue.parseJSON(payload)
        let id = args["id"].string ?? ""
        let reply: NativeRPCValue
        switch method {
        case "chats.launch":
            let launch = try JSONDecoder().decode(BackendHOSTProtocol.Launch.self, from: payload)
            guard launch.input.chat == true, UUID(uuidString: launch.id) != nil,
                  launch.id == launch.metadata.id, launch.metadata.cwd == launch.input.cwd,
                  launch.metadata.exitCode == nil, launch.cwd.hasPrefix("/"), !launch.cwd.contains("\0"),
                  launch.environment[BackendSessionEnvironment.sessionVariable] == launch.id,
                  launch.environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else { throw BackendHOSTFailure.authentication }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let digest = try encoder.encode(launch)
            if let previous = launches[launch.id] {
                guard previous == digest, let meta = manager.list().first(where: { $0.id == launch.id }) else { throw BackendHOSTFailure.uncertainLaunch(launch.id) }
                return try JSONEncoder().encode(meta)
            }
            // Claim the id BEFORE awaiting a spawn. A lost reply never starts a duplicate AI.
            launches[launch.id] = digest
            let meta = launch.metadata
            let spawn = BackendSpawnSpec(provider: meta.provider, command: launch.command, args: launch.arguments,
                path: launch.environment["PATH"] ?? "", env: launch.environment,
                profile: meta.profileId.map { BackendAccountIdentity(id: $0, name: meta.profileName ?? $0) },
                homeProfileId: meta.homeProfileId, agentSessionId: meta.agentSessionId, resumed: meta.resumed,
                hostCwd: launch.cwd, tabKey: meta.tabKey)
            return try JSONEncoder().encode(await chats.launch(launch.input, spawn: spawn, hostLaunch: launch))
        case "chats.job":
            try await chats.setHostedJob(id, job: JSONDecoder().decode(BackendTeamChatJob.self, from: args["job"].encodedJSON()), projectID: args["projectID"].string)
            reply = try await chats.read(id, cursor: nil, limit: 500)
        case "chats.inventory":
            reply = .object([.init("sessions", try NativeRPCValue.parseJSON(JSONEncoder().encode(manager.list().filter { $0.chat == true }))),
                .init("jobs", try NativeRPCValue.parseJSON(JSONEncoder().encode(await chats.conversations())))])
        case "chats.media": reply = try await chats.media(id, rowID: args["rowId"].requireString("source tool row", nonempty: true))
        case "chats.read": reply = try await chats.read(id, cursor: args["cursor"].number.map(Int.init), limit: Int(args["limit"].number ?? 500), seen: args["seen"].number.map(Int.init), conversation: args["conversation"].string)
        case "chats.resume-input": reply = try NativeRPCValue.parseJSON(JSONEncoder().encode(await chats.jobResumeInput(id)))
        case "chats.resume-continue": reply = try await chats.continueResumedJob(id)
        case "chats.provider": reply = try await chats.providerFeature(id, operation: args["operation"].requireString("operation", nonempty: true), arguments: args["arguments"].isNullish ? .object([]) : args["arguments"])
        case "chats.terminal":
            let approval = args["appApproval"].isNullish ? nil : try BackendChatOwnedTerminals.AppApproval(trustedWire: args["appApproval"])
            reply = try await chats.ownedTerminalFeature(id, operation: args["operation"].requireString("operation", nonempty: true),
                arguments: args["arguments"].isNullish ? .object([]) : args["arguments"], approval: approval)
        case "chats.seed-fork":
            let worktree = args["worktree"].isNullish ? nil : try JSONDecoder().decode(BackendChatForkWorktree.self, from: args["worktree"].encodedJSON())
            try await chats.seedFork(id, from: args["parent"].requireString("parent", nonempty: true), through: Int(args["sequence"].number ?? 0), worktree: worktree); reply = .bool(true)
        case "chats.rewind": reply = try await chats.rewind(id, sequence: Int(args["sequence"].number ?? 0))
        case "chats.undo-rewind": reply = try await chats.rewind(id, sequence: nil)
        case "chats.handoff": reply = try await chats.handoffPrompt(id, sequence: Int(args["sequence"].number ?? 0))
        case "chats.say": reply = try await chats.say(id, text: args["text"].requireString("message"), attachments: args["attachments"].elements ?? [], context: args["context"].isNullish ? .object([]) : args["context"], clientMessageID: args["clientMessageId"].string)
        case "chats.steer": reply = try await chats.steer(id, text: args["text"].requireString("message"), attachments: args["attachments"].elements ?? [], context: args["context"].isNullish ? .object([]) : args["context"], clientMessageID: args["clientMessageId"].string)
        case "chats.queued": try await chats.setQueuedCount(id, count: BackendHootChatChannels.integer(args["count"], maximum: 1_000_000) ?? 0); reply = .bool(true)
        case "chats.ensure": try await chats.ensure(id); reply = try await chats.read(id, cursor: nil, limit: 500)
        case "chats.interrupt": reply = try await chats.interruptTurn(id)
        case "chats.stop": reply = try await chats.stop(id)
        case "chats.child-stop": reply = try await chats.stopChild(id, task: args["taskId"].requireString("taskId", nonempty: true))
        case "chats.answer": reply = try await chats.answer(id, request: args["request"].requireString("permission request"), allowed: args["allowed"].bool == true, answers: args["answers"].isNullish ? .object([]) : args["answers"])
        case "chats.type": try await chats.type(id, data: args["text"].requireString("text")); reply = .bool(true)
        case "chats.draft": try await chats.setDraft(id, text: args["text"].requireString("draft")); reply = .bool(true)
        case "chats.options": reply = args["patch"].isNullish ? try await chats.options(id) : try await chats.setOptions(id, args["patch"])
        case "chats.turn": reply = BackendSessionChats.wire(try await chats.turn(id))
        case "chats.close": await chats.close(id); reply = .bool(true)
        case "chats.remove":
            guard let meta = manager.list().first(where: { $0.id == id }) else { throw BackendSessionFailure.missingSession }
            try await chats.removeSession(meta); reply = .bool(true)
        case "chats.delete": try await chats.deleteJobHistory(id); reply = .bool(true)
        case "chats.keep": try await chats.keepJobOpen(id, args["keepOpen"].bool ?? true); reply = .bool(true)
        case "chats.finish": try await chats.finishJob(id, result: args["result"].requireString("result"), failed: args["failed"].bool == true); reply = .bool(true)
        case "chats.open": reply = try NativeRPCValue.parseJSON(JSONEncoder().encode(await chats.openJobHistory(id)))
        case "chats.stopAll": await chats.endAllForQuit(); reply = .bool(true)
        default: throw BackendHOSTFailure.invalid("Unknown chat service operation.")
        }
        // 18 Oct (#76): a gone chat's last snapshot and launch claim are not kept for the helper's life.
        if Self.endsChat(method) { latest[id] = nil; launches[id] = nil }
        return try reply.encodedJSON()
    }
}
