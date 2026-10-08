import Foundation
import TerminalDeckNativeCore

/// One app-owned durable conversation. No CLI transcript or terminal fallback.
public actor BackendHootChatStore {
    public nonisolated let conversationID: String
    public nonisolated let provider: HootChatProvider
    private let file: URL
    private var events: [HootChatEvent]
    private var sessionID: String?
    private var generation = UUID()
    private var process: BackendHootChatProcess?
    private var consumer: Task<Void, Never>?
    private var busy = false, turnID = "", sequence: Int
    private var pending: [String: HootChatRecord] = [:]
    private var answered: Set<String> = []
    private var observers: [UUID: AsyncStream<NativeRPCValue>.Continuation] = [:]
    private var contextKey: String?
    private var lastError: String?
    private var initializationID: String?
    private var initialization: CheckedContinuation<Void, Error>?
    private var initializationTimeout: Task<Void, Never>?
    private var backgroundTasks: Set<String> = []
    private var completedTurn = false
    private var cliStatus: String?
    private var stopping = 0
    private var rpc: BackendHootChatRPC?
    private let consent: BackendDeckCoreSecurityConsentBroker?
    private let consentNow: @Sendable () -> Double
    private var consentOrigin = "window"
    private struct ConsentBinding {
        let nonce: String, turn: String, generation: UUID, cancellation: BackendMCPCancellation
        var answers = NativeRPCValue.object([])
        var deciding = false
    }
    private var consentBindings: [String: ConsentBinding] = [:]
    public init(file: URL, provider: HootChatProvider = .claude, consent: BackendDeckCoreSecurityConsentBroker? = nil,
                consentNow: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) throws {
        self.file = file; self.provider = provider
        self.consent = consent; self.consentNow = consentNow
        if FileManager.default.fileExists(atPath: file.path) {
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            let value = try NativeRPCValue.parseJSON(bytes, maximumBytes: 16 * 1_048_576)
            guard value["provider"].string == provider.rawValue else { throw NativeRPCError.malformed("Hoot's saved conversation belongs to another provider.") }
            let savedID = try value["conversationId"].requireString("conversationId", nonempty: true)
            conversationID = savedID
            events = try (value["events"].elements ?? []).map(HootChatEvent.init(wire:))
            guard events.count <= 4000, events.allSatisfy({ $0.conversationID == savedID && $0.provider == provider }),
                  zip(events, events.dropFirst()).allSatisfy({ $0.sequence < $1.sequence }) else { throw NativeRPCError.malformed("Hoot's saved events are inconsistent.") }
            sequence = events.last?.sequence ?? 0; sessionID = value["sessionId"].string
            contextKey = value["contextKey"].string
        } else { conversationID = UUID().uuidString.lowercased(); events = []; sequence = 0 }
    }
    public var cliSessionID: String? { sessionID }
    public var alive: Bool { process?.alive == true }
    public var isBusy: Bool { busy }
    public func requireContext(_ key: String) throws {
        guard contextKey == nil || contextKey == key else {
            throw NativeRPCError(code: "conversation-context-changed", message: "Hoot's saved conversation uses another account or folder. Choose that account/folder or start a separate conversation.")
        }
        contextKey = key
    }
    public func attach(_ launch: BackendHootChatLaunch) throws {
        guard process == nil, stopping == 0 else { throw NativeRPCError.invalidArguments("Hoot's previous CLI process is still stopping.") }
        if provider != .claude {
            guard let setup = launch.setup else { throw NativeRPCError.invalidArguments("Hoot's RPC launch needs its backend-owned setup.") }
            rpc = BackendHootChatRPC(provider: provider, setup: setup)
        }
        let child = BackendHootChatProcess(), token = UUID()
        generation = token; try child.start(launch); process = child
        consumer = Task { [weak self] in
            var lines = HootChatJSONLines(), stderr = Data()
            for await output in child.output {
                guard !Task.isCancelled else { break }
                do {
                    switch output {
                    case .stdout(let bytes):
                        for row in try lines.append(bytes) {
                            try await self?.receive(row, token: token)
                        }
                    case .stderr(let bytes): if stderr.count < 16_384 { stderr.append(bytes.prefix(16_384 - stderr.count)) }
                    case .exit(let code):
                        for row in try lines.append(Data(), end: true) {
                            try await self?.receive(row, token: token)
                        }
                        await self?.exited(token: token, code: code, diagnostic: String(data: stderr, encoding: .utf8) ?? "")
                    }
                } catch { await self?.failed(token: token, error: error); child.stop(); break }
            }
        }
        publish(reset: false)
    }
    private var decoder = HootChatDecoder(provider: .claude)
    private func receive(_ row: NativeRPCValue, token: UUID) async throws {
        guard generation == token else { return }
        if provider == .claude {
            if row["type"].string == "control_response" { controlResponse(row, token: token); return }
            for record in try decoder.decode(row) { try accept(record, token: token) }
        } else {
            guard var adapter = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
            let update = try adapter.receive(row); rpc = adapter
            for record in update.records { try accept(record, token: token) }
            for message in update.send {
                guard generation == token, let child = process else { return }
                try await child.send(message)
            }
            if update.ready && generation == token { finishInitialization(error: nil) }
        }
    }
    public func initialize() async throws {
        try Task.checkCancellation()
        guard let child = process, initialization == nil else { throw NativeRPCError(code: "unavailable", message: "Hoot's CLI initialization is unavailable.") }
        let id = UUID().uuidString, token = generation
        let request: NativeRPCValue
        if provider == .claude {
            request = .object([.init("type", .string("control_request")), .init("request_id", .string(id)),
                .init("request", .object([.init("subtype", .string("initialize")), .init("hooks", .null)]))])
        } else {
            guard var adapter = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
            request = try adapter.begin(id: id, resume: sessionID); rpc = adapter
        }
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            initializationID = id; initialization = continuation
            Task {
                do { try await child.send(request) }
                catch { self.finishInitialization(error: error) }
            }
            initializationTimeout = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard token == generation else { return }
                finishInitialization(error: NativeRPCError(code: "timeout", message: "Hoot's CLI did not complete its structured handshake."))
            }
          }
        } onCancel: { [weak self] in Task { await self?.stop() } }
    }
    private func controlResponse(_ row: NativeRPCValue, token: UUID) {
        guard generation == token, row["response"]["request_id"].string == initializationID else { return }
        if row["response"]["subtype"].string == "success" { finishInitialization(error: nil) }
        else { finishInitialization(error: NativeRPCError(code: "unavailable", message: row["response"]["error"].string ?? "Hoot's CLI handshake failed.")) }
    }
    private func finishInitialization(error: Error?) {
        let waiting = initialization; initialization = nil; initializationID = nil
        initializationTimeout?.cancel(); initializationTimeout = nil
        if let error { waiting?.resume(throwing: error) } else { waiting?.resume() }
    }
    public func say(_ text: String, attachments: [NativeRPCValue] = [], consentCaller: BackendDeckCoreSecurityCaller = .local) async throws -> NativeRPCValue {
        guard !busy else { throw NativeRPCError(code: "busy", message: "Hoot is still answering. Stop it before sending another message.") }
        guard let process, process.alive else { throw NativeRPCError(code: "unavailable", message: "Start Hoot before sending a message.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              text.utf8.count <= 262_144, attachments.count <= 4 else { throw NativeRPCError.invalidArguments("Hoot needs a message of at most 256 KiB or up to four attachments.") }
        if consentCaller.kind == .remote, consentCaller.deviceID?.isEmpty != false { throw NativeRPCError.invalidArguments("Hoot needs the authenticated device caller.") }
        if consentCaller.kind == .key, consentCaller.keyID?.isEmpty != false { throw NativeRPCError.invalidArguments("Hoot needs the authenticated key caller.") }
        // Only documented Claude content blocks cross stdin. No local paths/URLs.
        for attachment in attachments {
            let source = attachment["source"]
            guard ["image", "document"].contains(attachment["type"].string ?? ""), source["type"].string == "base64",
                  let data = source["data"].string, Data(base64Encoded: data) != nil,
                  let media = source["media_type"].string,
                  ["image/png", "image/jpeg", "image/gif", "image/webp", "application/pdf"].contains(media) else {
                throw NativeRPCError.invalidArguments("Unsupported Hoot attachment.")
            }
        }
        let token = generation
        let nextTurn = UUID().uuidString.lowercased()
        let message: NativeRPCValue
        if provider == .claude { message = BackendHootChatCLI.user(text, attachments: attachments) }
        else {
            guard var adapter = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
            message = try adapter.user(text, attachments: attachments, id: nextTurn); rpc = adapter
        }
        turnID = nextTurn; busy = true; pending = [:]; answered = []; lastError = nil
        consentOrigin = consentCaller.consentSurface
        completedTurn = false; cliStatus = nil
        do {
            try append(.init(.user, id: turnID, value: .object([.init("text", .string(text)), .init("attachmentCount", .number(Double(attachments.count)))])))
            try await process.send(message)
            guard token == generation else { throw NativeRPCError(code: "interrupted", message: "Hoot was stopped while sending this message.") }
            return snapshot()
        } catch { await failed(token: token, error: error); throw error }
    }
    /// Authority is checked by the registered app/device route before this call.
    public func answer(id: String, allowed: Bool, answers: NativeRPCValue = .object([])) async throws {
        if let consent {
            guard let binding = consentBindings[id] else { throw NativeRPCError(code: "stale-approval", message: "Hoot has no current issued confirmation for this request.") }
            guard let question = await consent.list().first(where: { $0.tool == "hoot.cli" && $0.arguments["hootBinding"].string == binding.nonce }) else {
                throw NativeRPCError(code: "stale-approval", message: "Hoot's confirmation has not been issued or has expired.")
            }
            try await answerBroker(id: question.id, allowed: allowed, by: "window", answers: answers)
            return
        }
        try await sendAnswer(id: id, allowed: allowed, answers: answers)
    }
    /// Phone/native adapters supply their authenticated surface after checking
    /// current access. Only a live Core-issued ID can find this private binding.
    public func answerBroker(id: String, allowed: Bool, by: String, answers: NativeRPCValue = .object([])) async throws {
        guard let consent, let question = await consent.list().first(where: { $0.id == id }), question.tool == "hoot.cli",
              question.expiresAt > consentNow(), let nonce = question.arguments["hootBinding"].string,
              let (cliID, binding) = consentBindings.first(where: { $0.value.nonce == nonce }),
              binding.generation == generation, binding.turn == turnID, !binding.deciding, pending[cliID] != nil, !answered.contains(cliID),
              await consent.mayAnswer(id: id, by: by) else {
            throw NativeRPCError(code: "stale-approval", message: "This is not a current, authorized Hoot confirmation.")
        }
        try await validateAnswer(id: cliID, allowed: allowed, answers: answers)
        guard consentBindings[cliID]?.nonce == nonce, consentBindings[cliID]?.deciding == false,
              question.expiresAt > consentNow(), binding.generation == generation, pending[cliID] != nil else {
            throw NativeRPCError(code: "stale-approval", message: "Hoot's confirmation changed while validating the answer.")
        }
        consentBindings[cliID]?.answers = answers
        consentBindings[cliID]?.deciding = true
        guard await consent.respond(id: id, approved: allowed, by: by) else {
            throw NativeRPCError(code: "stale-approval", message: "Hoot's confirmation was already settled.")
        }
    }
    private func validateAnswer(id: String, allowed: Bool, answers: NativeRPCValue) async throws {
        guard let request = pending[id] else { throw NativeRPCError(code: "stale-approval", message: "Hoot is no longer asking this question.") }
        if allowed, provider == .codex, request.value["subtype"].string == "mcpServer/elicitation/request", request.value["input"]["mode"].string != "url" {
            if let error = try await BackendMcpClientJSONSchemaValidator().validate(schema: request.value["input"]["requestedSchema"], value: answers) {
                throw NativeRPCError.invalidArguments("Hoot's form answer is invalid: " + error)
            }
        }
        if provider != .claude { _ = try rpc?.answer(request, allowed: allowed, answers: answers) }
    }
    private func sendAnswer(id: String, allowed: Bool, answers: NativeRPCValue = .object([])) async throws {
        guard busy, let request = pending[id], !answered.contains(id), let child = process else {
            throw NativeRPCError(code: "stale-approval", message: "This Hoot question is no longer waiting for an answer.")
        }
        let token = generation
        if allowed, provider == .codex, request.value["subtype"].string == "mcpServer/elicitation/request",
           request.value["input"]["mode"].string != "url" {
            if let error = try await BackendMcpClientJSONSchemaValidator().validate(schema: request.value["input"]["requestedSchema"], value: answers) {
                throw NativeRPCError.invalidArguments("Hoot's form answer is invalid: " + error)
            }
            guard token == generation, pending[id] != nil, !answered.contains(id) else {
                throw NativeRPCError(code: "stale-approval", message: "This Hoot form is no longer waiting for an answer.")
            }
        }
        let message: NativeRPCValue
        if provider == .claude {
            guard request.value["subtype"].string == "can_use_tool", request.value["input"].fields != nil else {
                throw NativeRPCError.invalidArguments("This Hoot request cannot be approved as a tool call.")
            }
            message = BackendHootChatCLI.approval(id: id, allowed: allowed, input: request.value["input"])
        } else {
            guard let adapter = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
            message = try adapter.answer(request, allowed: allowed, answers: answers)
        }
        answered.insert(id); pending[id] = nil
        do {
            try await child.send(message)
            guard token == generation else { throw NativeRPCError(code: "stale-approval", message: "Hoot stopped before this answer arrived.") }
            try append(.init(.approvalResolved, id: id, value: .object([.init("allowed", .bool(allowed))])))
        } catch { await failed(token: token, error: error); throw error }
    }
    public func interrupt() async throws {
        guard busy, let child = process else { return }
        for id in Array(pending.keys) { try await answer(id: id, allowed: false) }
        guard busy else { return } // A denial may have completed the turn already.
        let message: NativeRPCValue
        if provider == .claude {
            message = .object([.init("type", .string("control_request")), .init("request_id", .string(UUID().uuidString)),
                .init("request", .object([.init("subtype", .string("interrupt"))]))])
        } else {
            guard var adapter = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
            message = try adapter.interrupt(); rpc = adapter
        }
        try await child.send(message)
    }
    public func stop() async {
        cancelConsentBindings()
        finishInitialization(error: NativeRPCError(code: "interrupted", message: "Hoot's CLI initialization was stopped."))
        generation = UUID(); let child = process; process = nil
        rpc = nil; decoder = HootChatDecoder(provider: .claude)
        consumer?.cancel(); consumer = nil
        pending = [:]; answered = []; backgroundTasks = []; cliStatus = nil; let wasBusy = busy; busy = false
        if wasBusy { try? append(.init(.interrupted)) }
        publish(reset: false)
        if let child { stopping += 1; await child.stopAndWait(); stopping -= 1 }
    }
    public func snapshot(after cursor: Int? = nil, limit: Int = 200) -> NativeRPCValue {
        let bounded = min(500, max(1, limit))
        let reset = cursor == nil || (cursor ?? 0) < (events.first?.sequence ?? 1) - 1 || (cursor ?? 0) > sequence
        let slice = reset ? Array(HootChatProjection.snapshotEvents(events).suffix(bounded)) : Array(events.filter { $0.sequence > (cursor ?? 0) }.prefix(bounded))
        return .object([.init("conversationId", .string(conversationID)), .init("provider", .string(provider.rawValue)),
            .init("reset", .bool(reset)), .init("events", .array(slice.map(\.wireValue))),
            .init("cursor", .number(Double(slice.last?.sequence ?? cursor ?? sequence))), .init("sequence", .number(Double(sequence))),
            .init("hasMore", .bool((slice.last?.sequence ?? cursor ?? sequence) < sequence)),
            .init("alive", .bool(alive)), .init("busy", .bool(busy)),
            .init("pending", .array(pending.keys.sorted().compactMap { pending[$0]?.value })),
            .init("problem", lastError.map(NativeRPCValue.string) ?? .null)])
    }
    public func subscribe() -> AsyncStream<NativeRPCValue> {
        let id = UUID(), pair = AsyncStream<NativeRPCValue>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation; pair.continuation.yield(snapshot(limit: 500))
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish(reset: Bool) {
        // Each observer receives a reset snapshot: dropping a buffered update is safe.
        let value = snapshot(limit: 500)
        for observer in observers.values { observer.yield(value) }
    }
    private func append(_ record: HootChatRecord) throws {
        sequence += 1
        let event = HootChatEvent(conversationID: conversationID, turnID: turnID, sequence: sequence, provider: provider, record: record)
        events.append(event)
        if events.count > 4000 {
            events = HootChatProjection.snapshotEvents(events)
            if events.count > 4000 { events.removeFirst(events.count - 4000) }
        }
        let value = NativeRPCValue.object([.init("version", .number(1)), .init("conversationId", .string(conversationID)),
            .init("provider", .string(provider.rawValue)), .init("sessionId", sessionID.map(NativeRPCValue.string) ?? .null),
            .init("contextKey", contextKey.map(NativeRPCValue.string) ?? .null), .init("events", .array(events.map(\.wireValue)))])
        let bytes = try value.encodedJSON()
        guard bytes.count <= 16 * 1_048_576 else { throw NativeRPCError(code: "history-limit", message: "Hoot's conversation reached its storage limit.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        publish(reset: false)
    }
    private func accept(_ record: HootChatRecord, token: UUID) throws {
        guard generation == token else { return }
        if let id = record.value["sessionId"].string { sessionID = id }
        if let task = record.value["taskStarted"].string { backgroundTasks.insert(task); busy = true }
        if let task = record.value["taskFinished"].string {
            backgroundTasks.remove(task)
            if completedTurn && backgroundTasks.isEmpty && pending.isEmpty { busy = false }
        }
        if let status = record.value["status"].string {
            cliStatus = status
            if status == "running" || status == "requires_action" { busy = true }
            if status == "idle" && backgroundTasks.isEmpty && pending.isEmpty { busy = false }
        }
        if record.kind == .approval {
            guard record.value["input"].fields != nil,
                  (provider != .claude && !record.value["rpcId"].isNullish) || record.value["subtype"].string == "can_use_tool" else {
                throw NativeRPCError(code: "unsupported-request", message: "Hoot's CLI sent an unsupported question: \(record.value["subtype"].string ?? "unknown").")
            }
            guard !record.messageID.isEmpty, pending[record.messageID] == nil, !answered.contains(record.messageID) else { return }
            busy = true
            pending[record.messageID] = record
            issueConsent(record)
        }
        if record.kind == .approvalResolved {
            consentBindings.removeValue(forKey: record.messageID)?.cancellation.cancel()
            pending[record.messageID] = nil; answered.insert(record.messageID)
        }
        if record.kind == .completed {
            completedTurn = true
            busy = !backgroundTasks.isEmpty || !pending.isEmpty || cliStatus == "running" || cliStatus == "requires_action"
        }
        if record.kind == .error {
            if lastError == record.value["text"].string { return }
            lastError = record.value["text"].string
        }
        try append(record)
    }
    private func issueConsent(_ record: HootChatRecord) {
        guard let consent else { return }
        let binding = ConsentBinding(nonce: UUID().uuidString, turn: turnID, generation: generation, cancellation: .init())
        consentBindings[record.messageID] = binding
        let arguments = record.value.setting("hootBinding", .string(binding.nonce)).setting("conversationId", .string(conversationID)).setting("turnId", .string(turnID))
        let origin = consentOrigin
        Task { [weak self] in
            let outcome = await consent.request(tool: "hoot.cli", tier: .alter, summary: record.value["name"].string ?? "Hoot needs your answer",
                arguments: arguments, cancellation: binding.cancellation, origin: origin, label: "Hoot", askedBy: "Hoot")
            await self?.settleConsent(id: record.messageID, binding: binding, outcome: outcome)
        }
    }
    private func settleConsent(id: String, binding: ConsentBinding, outcome: BackendDeckCoreSecurityConsentOutcome) async {
        guard binding.generation == generation, binding.turn == turnID, let current = consentBindings[id], current.nonce == binding.nonce, pending[id] != nil else { return }
        consentBindings[id] = nil
        do { try await sendAnswer(id: id, allowed: outcome.granted, answers: current.answers) }
        catch {
            // A boolean-only approver cannot silently satisfy a structured form.
            try? await sendAnswer(id: id, allowed: false)
            try? append(.text(.error, error.localizedDescription))
        }
    }
    private func cancelConsentBindings() {
        for binding in consentBindings.values { binding.cancellation.cancel() }; consentBindings = [:]
    }
    private func exited(token: UUID, code: Int32, diagnostic: String) {
        guard generation == token else { return }
        cancelConsentBindings()
        process = nil; consumer = nil
        finishInitialization(error: NativeRPCError(code: "unavailable", message: "Hoot's CLI exited during its handshake."))
        if busy || code != 0 {
            let text = lastError ?? (diagnostic.isEmpty ? "Hoot's CLI exited before completing its turn (\(code))." : String(diagnostic.prefix(2000)))
            let alreadyReported = lastError != nil
            lastError = text; busy = false; pending = [:]
            if !alreadyReported { try? append(.text(.error, text)) }
        }
        publish(reset: false)
    }
    private func failed(token: UUID, error: Error) async {
        guard generation == token else { return }
        cancelConsentBindings()
        finishInitialization(error: error)
        lastError = error.localizedDescription; let child = process; process = nil
        busy = false; pending = [:]; generation = UUID(); consumer?.cancel(); consumer = nil
        try? append(.text(.error, error.localizedDescription)); publish(reset: false)
        if let child { stopping += 1; await child.stopAndWait(); stopping -= 1 }
    }
}
