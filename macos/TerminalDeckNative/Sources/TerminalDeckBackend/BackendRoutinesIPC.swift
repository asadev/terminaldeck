import Foundation
import TerminalDeckNativeCore

public enum BackendRoutinesTier: String, Sendable { case read, act, alter, human }
public struct BackendRoutinesWriteResult: Sendable, Equatable {
    public let ok: Bool, id: String?, view: BackendRoutinesView?, problems: [String]
    public init(id: String, view: BackendRoutinesView?) { ok = true; self.id = id; self.view = view; problems = [] }
    public init(problems: [String]) { ok = false; id = nil; view = nil; self.problems = problems }
    public var wire: NativeRPCValue {
        if ok { return .object([.init("ok", .bool(true)), .init("id", id.map(NativeRPCValue.string) ?? .null), .init("view", view?.wire ?? .null)]) }
        return .object([.init("ok", .bool(false)), .init("problems", .array(problems.map(NativeRPCValue.string)))])
    }
}

/// IPC and a contributed MCP operation share these same checks. Raw text stays
/// human-only; it is intentionally absent from the MCP tier type/catalogue.
public actor BackendRoutinesAPI {
    public static let listChannel = "routines:list", getChannel = "routines:get", createChannel = "routines:create", updateChannel = "routines:update", deleteChannel = "routines:delete", runChannel = "routines:run", pauseChannel = "routines:pause", resumeChannel = "routines:resume", textChannel = "routines:text", saveTextChannel = "routines:save-text"
    public static let tiers: [String: BackendRoutinesTier] = [listChannel: .read, getChannel: .read, textChannel: .read, runChannel: .act, pauseChannel: .act, resumeChannel: .act, createChannel: .alter, updateChannel: .alter, deleteChannel: .alter, saveTextChannel: .human]
    public static var channels: Set<String> { Set(tiers.keys) }
    public let engine: BackendRoutinesEngine, store: BackendRoutinesStore
    public init(engine: BackendRoutinesEngine, store: BackendRoutinesStore) { self.engine = engine; self.store = store }
    public func list() async -> [BackendRoutinesView] { await engine.list() }
    public func get(_ id: NativeRPCValue) async -> BackendRoutinesView? { guard let name = valid(id) else { return nil }; return await engine.get(name) }
    private func valid(_ id: NativeRPCValue) -> String? { guard let id = id.string, BackendRoutinesFormat.isValidId(id) else { return nil }; return id }
    private func objectLike(_ draft: NativeRPCValue) -> Bool { draft.fields != nil || draft.elements != nil }
    public func create(_ draft: NativeRPCValue) async throws -> BackendRoutinesWriteResult {
        guard objectLike(draft) else { return .init(problems: ["A routine needs a name, a trigger, a folder and a prompt."]) }
        // File mutations have no suspension until the atomic store write. This
        // preserves the TS API's synchronous duplicate/cap/write transaction.
        let current = store.list(), existing = Set(current.map(\.id))
        guard existing.count < BackendRoutinesStore.maxRoutines else { return .init(problems: ["This app will not keep more than \(BackendRoutinesStore.maxRoutines) routines."]) }
        let wanted = draft["id"].string ?? BackendRoutinesFormat.suggestId(BackendDeckCoreCatalogueRules.jsString(draft["name"].isNullish ? .string("") : draft["name"]), taken: existing)
        guard BackendRoutinesFormat.isValidId(wanted) else { return .init(problems: ["`\(wanted)` is not a usable routine name. Use lowercase letters, digits and hyphens."]) }
        guard !existing.contains(wanted) else { return .init(problems: ["There is already a routine called `\(wanted)`."]) }
        let parsed = BackendRoutinesFormat.routineFromDraft(wanted, draft: draft)
        guard let routine = parsed.routine else { return .init(problems: parsed.problems) }
        if let duplicate = current.first(where: { item in guard let other = item.routine else { return false }; return other.folder == routine.folder && other.prompt == routine.prompt && other.triggers.map(BackendRoutinesFormat.serializeTrigger).joined(separator: "|") == routine.triggers.map(BackendRoutinesFormat.serializeTrigger).joined(separator: "|") }) {
            return .init(problems: ["`\(duplicate.id)` already does exactly this. Edit it rather than adding a second."])
        }
        _ = try store.save(routine); await engine.reload(); return .init(id: wanted, view: await engine.get(wanted))
    }
    public func update(_ id: NativeRPCValue, draft: NativeRPCValue) async throws -> BackendRoutinesWriteResult {
        guard let id = valid(id) else { return .init(problems: ["That is not a usable routine name."]) }
        guard objectLike(draft) else { return .init(problems: ["Nothing was supplied to change."]) }
        guard store.list().contains(where: { $0.id == id }) else { return .init(problems: ["There is no routine called `\(id)`."]) }
        let parsed = BackendRoutinesFormat.routineFromDraft(id, draft: draft); guard let routine = parsed.routine else { return .init(problems: parsed.problems) }
        _ = try store.save(routine); await engine.reload(); return .init(id: id, view: await engine.get(id))
    }
    public func text(_ id: NativeRPCValue) -> NativeRPCValue {
        guard let id = valid(id) else { return problems(["That is not a usable routine name."]) }
        let result = store.readText(id)
        guard result.ok, let text = result.text, let file = result.file else { return problems([result.error ?? "This routine could not be read."]) }
        return .object([.init("ok", .bool(true)), .init("id", .string(id)), .init("text", .string(text)), .init("file", .string(file))])
    }
    public func saveText(_ id: NativeRPCValue, text: NativeRPCValue) async throws -> BackendRoutinesWriteResult {
        guard let id = valid(id) else { return .init(problems: ["That is not a usable routine name."]) }
        guard let text = text.string else { return .init(problems: ["Nothing was supplied to save."]) }
        guard store.list().contains(where: { $0.id == id }) else { return .init(problems: ["There is no routine called `\(id)`."]) }
        let parsed = BackendRoutinesFormat.parseRoutine(id, text: text); guard parsed.ok else { return .init(problems: parsed.problems) }
        _ = try store.saveText(id, text: text); await engine.reload(); return .init(id: id, view: await engine.get(id))
    }
    public func remove(_ id: NativeRPCValue) async throws -> NativeRPCValue {
        guard let id = valid(id) else { return problems(["That is not a usable routine name."]) }
        let removed = try store.remove(id); await engine.reload()
        return removed ? .object([.init("ok", .bool(true))]) : problems(["There is no routine called `\(id)`."])
    }
    public func run(_ id: NativeRPCValue, by: String = "user") async -> BackendRoutinesRunResult {
        guard let id = valid(id) else { return .init(started: false, reason: "That is not a usable routine name.") }; return await engine.runNow(id, by: by)
    }
    public func pause(_ id: NativeRPCValue, reason: NativeRPCValue) async -> Bool {
        guard let id = valid(id) else { return false }
        let trimmed = reason.string.map(BackendRoutinesValues.trim) ?? ""
        return await engine.pause(id, reason: trimmed.isEmpty ? "Paused." : BackendRoutinesExecutionText.prefix(trimmed, 300))
    }
    public func resume(_ id: NativeRPCValue) async -> Bool { guard let id = valid(id) else { return false }; return await engine.resume(id) }
    private func problems(_ messages: [String]) -> NativeRPCValue { .object([.init("ok", .bool(false)), .init("problems", .array(messages.map(NativeRPCValue.string)))]) }
    public func invoke(_ channel: String, arguments: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        func arg(_ index: Int) -> NativeRPCValue { context.argument(index, in: arguments) }
        switch channel {
        case Self.listChannel: return .array(await list().map(\.wire))
        case Self.getChannel: return await get(arg(0))?.wire ?? .null
        case Self.textChannel: return text(arg(0))
        case Self.createChannel: return try await create(arg(0)).wire
        case Self.updateChannel: return try await update(arg(0), draft: arg(1)).wire
        case Self.deleteChannel: return try await remove(arg(0))
        case Self.runChannel: return await run(arg(0), by: "user").wire
        case Self.pauseChannel: return .bool(await pause(arg(0), reason: arg(1)))
        case Self.resumeChannel: return .bool(await resume(arg(0)))
        case Self.saveTextChannel:
            guard context.caller == .nativeApp else { throw NativeRPCError(code: "not-permitted", message: "Only a person editing a routine in the app may save its raw text.") }
            return try await saveText(arg(0), text: arg(1)).wire
        default: throw NativeRPCError(code: "unavailable", message: "The native routine channel is not registered.")
        }
    }
    public func register(on registry: NativeChannelRegistry, ownerID: String) async throws {
        for channel in Self.channels.sorted() {
            let tier = Self.tiers[channel]!
            try await registry.register(channel, ownerID: ownerID, policy: { context in
                try context.require(tier == .read ? "routines.read" : "routines.write")
                if tier == .human, context.caller != .nativeApp { throw NativeRPCError(code: "not-permitted", message: "Only a person editing a routine in the app may save its raw text.") }
            }) { [self] context, args in try await invoke(channel, arguments: args, context: context) }
        }
    }
}
