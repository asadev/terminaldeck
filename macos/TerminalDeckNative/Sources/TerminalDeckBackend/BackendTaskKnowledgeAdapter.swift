import Foundation
import TerminalDeckNativeCore

/// Concrete client of the existing native knowledge owner. It does not open
/// another knowledge store, duplicate ingest rules or forward a Node request.
public struct BackendTaskKnowledgeAdapter: Sendable {
    public let service: BackendKnowledgeService
    public init(service: BackendKnowledgeService) { self.service = service }
    public func brief(_ task: BackendTaskRecord) async -> String {
        let result = await service.forBrief(project: task.project, query: (task.value["title"].string ?? "") + "\n" + (task.value["instructions"].string ?? ""), goalId: task.value["goalId"].string)
        return result.text
    }
    public func goal(_ goal: NativeRPCValue) async -> NativeRPCValue? {
        guard let project = goal["project"].string, !project.isEmpty else { return nil }
        let result = await service.forBrief(project: project, query: (goal["title"].string ?? "") + "\n" + (goal["description"].string ?? ""), goalId: goal["id"].string)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var counts: [String: Int] = [:]; for record in result.records { counts[record.effective, default: 0] += 1 }
        return BackendTaskValues.object([("text", .string(result.text)), ("counts", .object(counts.map { .init($0.key, .number(Double($0.value))) }))])
    }
    public func note(_ task: BackendTaskRecord, kind: String, summary: String = "", evidence: [String] = []) async {
        guard !task.project.isEmpty else { return }
        let worker = task.assigneeKind == "agent" ? task.agentID : task.value["handedFrom"].string
        let text = summary.isEmpty ? nil : BackendCrmInlineFiles.slice(summary.trimmingCharacters(in: .whitespacesAndNewlines), 0, 3_000), at = BackendTaskValues.time()
        var seen = BackendTaskValues.object([("kind", .string(kind)), ("project", .string(task.project)), ("taskId", .string(task.id)), ("title", .string(task.value["title"].string ?? "")), ("at", .number(at))])
        if let goal = task.value["goalId"].string { seen = seen.setting("goalId", .string(goal)) }
        if let worker { seen = seen.setting("agentId", .string(worker)) }
        if let session = task.sessionID { seen = seen.setting("sessionId", .string(session)) }
        if let text { seen = seen.setting("summary", .string(text)) }
        if !evidence.isEmpty { seen = seen.setting("evidence", .array(evidence.map(NativeRPCValue.string))) }
        await Observers.shared.emit(service, seen)
        await service.noteTaskEvent(BackendKnowledgeTaskEvent(kind: kind, project: task.project, taskId: task.id, title: task.value["title"].string ?? "", at: at, goalId: task.value["goalId"].string, agentId: worker, sessionId: task.sessionID,
            summary: text, evidence: evidence.isEmpty ? nil : evidence))
    }
    /// What the knowledge seam was handed, as the raw task event (task-engine.ts `knowledge.noteTaskEvent(event)`),
    /// for whoever wants to watch the seam: a diagnostics panel, or a test of the exact payload and order.
    public static func observe(_ service: BackendKnowledgeService, _ handler: @escaping @Sendable (NativeRPCValue) async throws -> Void) -> NativeRPCSubscription {
        let id = Observers.shared.add(service, handler)
        return NativeRPCSubscription { Observers.shared.remove(service, id) }
    }
    private final class Observers: @unchecked Sendable {
        static let shared = Observers()
        private let lock = NSLock(); private var table: [ObjectIdentifier: [UUID: @Sendable (NativeRPCValue) async throws -> Void]] = [:]
        func add(_ service: BackendKnowledgeService, _ handler: @escaping @Sendable (NativeRPCValue) async throws -> Void) -> UUID { let id = UUID(); lock.withLock { table[ObjectIdentifier(service), default: [:]][id] = handler }; return id }
        func remove(_ service: BackendKnowledgeService, _ id: UUID) { lock.withLock { table[ObjectIdentifier(service)]?[id] = nil } }
        func emit(_ service: BackendKnowledgeService, _ event: NativeRPCValue) async {
            let handlers: [@Sendable (NativeRPCValue) async throws -> Void] = lock.withLock { table[ObjectIdentifier(service)]?.values.map { $0 } ?? [] }
            for handler in handlers { try? await handler(event) }
        }
    }
}

public struct BackendTaskProviderAnswers: Sendable {
    private let runtime: any BackendDeckToolsSessionsRuntime, surface: any BackendDeckToolsSessionsSurface
    private let context: @Sendable (BackendSessionMeta) async throws -> BackendMCPCallContext
    public init(runtime: any BackendDeckToolsSessionsRuntime, surface: any BackendDeckToolsSessionsSurface,
                context: @escaping @Sendable (BackendSessionMeta) async throws -> BackendMCPCallContext) { self.runtime = runtime; self.surface = surface; self.context = context }
    public func latest(_ session: BackendSessionMeta) async throws -> BackendTaskAnswer? {
        let context = try await context(session), meta = try NativeRPCValue.parseJSON(JSONEncoder().encode(session))
        guard let answer = try await BackendDeckToolsSessionsArea.latestAnswer(meta, runtime: runtime, surface: surface, context: context), let text = answer["text"].string, let at = answer["at"].number else { return nil }
        return BackendTaskAnswer(text: text, at: at)
    }
}
