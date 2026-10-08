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
    private var watchers: [UUID: Task<Void, Never>] = [:]
    private var contexts: [UUID: BackendRemoteHostContext] = [:]
    public init(trust: BackendRemoteTrustStore, endpoint: BackendRemoteHost, consent: BackendDeckCoreSecurityConsentBroker,
                runtime: @escaping @Sendable () async -> BackendCopilotSessionRuntime?,
                log: @escaping @Sendable (Int) async -> [NativeRPCValue],
                setInteractive: @escaping @Sendable (Bool) async throws -> Void) {
        self.trust = trust; self.endpoint = endpoint; self.consent = consent; self.runtime = runtime
        self.log = log; self.setInteractive = setInteractive
    }
    public func feature() -> BackendRemoteHostFeature {
        .init(capability: "copilot", messageTypes: Set(BackendCopilotRemoteSurface.frameTier.keys).union(BackendCopilotRemoteSurface.untiered)
            .subtracting(["copilot.files", "copilot.file.read", "copilot.file.write", "copilot.file.reset", "copilot.memory.delete"]),
            policy: .ownerOnly, additionalAdvertisedCapabilities: ["hoot.events"]) { [weak self] message, context in
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
        case "copilot.hello":
            let level = context.phoneAccess
            return [try .init(.copilotGrant, fields: [.init("link", .object([.init("linked", .bool(true)), .init("open", .bool(true)),
                .init("grant", .object([.init("read", .bool(level != nil)), .init("act", .bool(level != .look)), .init("alter", .bool(level == .full))]))]))])]
        case "copilot.bye", "copilot.detach": await disconnected(context.connectionID); return []
        case "copilot.attach":
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
        case "copilot.state": return [try .init(.copilotState, fields: [.init("state", try await owner.invoke("copilot:state", arguments: []))])]
        case "copilot.sessions":
            let visible = try await endpoint.panelSessionIDs(context)
            let rows = endpoint.manager.list().filter { visible.contains($0.id) }.map(BackendCompositionSuppliers.sessionWire)
            return [try .init(.copilotSessions, fields: [.init("sessions", .array(rows))])]
        case "copilot.log":
            let count = min(200, max(1, Int(frame["limit"].number ?? 100)))
            return [try .init(.copilotLog, fields: [.init("rows", .array(await log(count))), .init("more", .bool(false))])]
        case "copilot.pending": return [try .init(.copilotPending, fields: [.init("questions", .array(await pending(context)))])]
        case "copilot.answer":
            let id = try frame["id"].requireString("question", nonempty: true)
            _ = try await require(context, verb: "copilot.answer")
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
        case "copilot.start": _ = try await owner.ensure(); return []
        case "copilot.say":
            _ = try await owner.ensure(); let current = try await require(context, verb: frame.type)
            guard let chat = owner.structuredChat else { throw NativeRPCError(code: "unavailable", message: "Hoot's structured conversation is unavailable.") }
            _ = try await chat.say(frame["text"].requireString("message"),
                consentCaller: .init(kind: .remote, tiers: current.phoneAccess?.tiers ?? [], deviceID: current.deviceID)); return []
        case "copilot.cancel": try await owner.structuredChat?.interrupt(); return []
        case "copilot.stop": _ = try await owner.stop(); return []
        case "copilot.interactive": try await setInteractive(frame["on"].bool == true); return []
        default: throw NativeRPCError(code: "unavailable", message: "This Hoot phone operation has no shared-owner adapter yet.")
        }
    }
    private func publish(_ snapshot: NativeRPCValue, context: BackendRemoteHostContext) async throws {
        let current = try await require(context, verb: "copilot.attach")
        guard contexts[current.connectionID] != nil else { throw CancellationError() }
        var events = snapshot["events"].elements ?? []
        var message = try BackendRemoteServerMessage(.hootEvents, fields: [.init("conversationId", snapshot["conversationId"]),
            .init("reset", .bool(true)), .init("events", .array(events))])
        while try message.value.encodedJSON().count > BackendRemoteProtocol.limits["MAX_MESSAGE_BYTES"]!, !events.isEmpty {
            events.removeFirst()
            message = try .init(.hootEvents, fields: [.init("conversationId", snapshot["conversationId"]), .init("reset", .bool(true)), .init("events", .array(events))])
        }
        try await endpoint.sendToConnection(current.connectionID, message: message)
    }
    public func ask(_ request: BackendDeckCoreSecurityConsentRequest) async throws -> Bool {
        var delivered = false
        for context in contexts.values {
            guard (try? await require(context, verb: "copilot.answer")) != nil,
                  await consent.mayAnswer(id: request.id, by: "device:" + context.deviceID) else { continue }
            try await endpoint.sendToConnection(context.connectionID, message: .init(.copilotAsk, fields: [.init("question", BackendCopilotRemoteWiring.consentQuestion(request))]))
            delivered = true
        }
        return delivered
    }
    public func settled(id: String, outcome: BackendDeckCoreSecurityConsentOutcome) async throws {
        for context in contexts.values where (try? await require(context, verb: "copilot.pending")) != nil {
            try await endpoint.sendToConnection(context.connectionID, message: .init(.copilotSettled, fields: [.init("settled", .object([
                .init("id", .string(id)), .init("granted", .bool(outcome.granted)), .init("by", outcome.by.map(NativeRPCValue.string) ?? .null)]))]))
        }
    }
    public func disconnected(_ id: UUID) async {
        watchers[id]?.cancel(); watchers[id] = nil
        if let context = contexts.removeValue(forKey: id) { try? await consent.callerGone("device:" + context.deviceID) }
    }
    public func stop() async { for id in Array(contexts.keys) { await disconnected(id) } }
}
