import Foundation

/// Delivered by the task engine, never constructed from an MCP argument.
public struct BackendKnowledgeTaskEvent: Sendable {
    public let kind: String, project: String, taskId: String, title: String
    public let at: Double; public let goalId: String?, agentId: String?, sessionId: String?, summary: String?, evidence: [String]?
    public init(kind: String, project: String, taskId: String, title: String, at: Double, goalId: String? = nil, agentId: String? = nil, sessionId: String? = nil, summary: String? = nil, evidence: [String]? = nil) {
        self.kind = kind; self.project = project; self.taskId = taskId; self.title = title; self.at = at; self.goalId = goalId; self.agentId = agentId; self.sessionId = sessionId; self.summary = summary; self.evidence = evidence
    }
}
public extension BackendKnowledgeService {
    /// Task flow continues on storage errors, while the supplied error reporter receives the actual failure.
    func noteTaskEvent(_ event: BackendKnowledgeTaskEvent) {
        do { try ingest(event) } catch { onError(error.localizedDescription, "\(event.kind) event for task \(event.taskId)") }
    }
}
extension BackendKnowledgeService {
    func ingest(_ event: BackendKnowledgeTaskEvent) throws {
        let real = try projectOf(event.project), records = store.records(real), subject = "task " + event.taskId
        let results = records.filter { $0.kind == "result" && $0.subject == subject && $0.status != "superseded" }
        let summary = BackendMemoryParsing.trim(event.summary ?? ""), to = event.agentId.map { " to " + $0 } ?? ""
        func provenance(_ source: String) -> BackendKnowledgeProvenance { .init(source: source, taskId: event.taskId, goalId: event.goalId, agentId: event.agentId, sessionId: event.sessionId, evidence: event.evidence) }
        func build(_ kind: String, _ statement: String, _ source: String) throws -> BackendKnowledgeRecord {
            let trimmed = BackendMemoryParsing.trim(statement)
            let fitted = trimmed.utf16.count > 4000 ? BackendMemoryParsing.trim(BackendMemoryParsing.cut(trimmed, 3999)) + "…" : trimmed
            var next = try claim(event.project, real: real, input: .init(kind: kind, subject: subject, statement: fitted, provenance: provenance(source)))
            next.createdAt = event.at; return next
        }
        func already(_ next: BackendKnowledgeRecord) -> Bool {
            records.contains { $0.kind == next.kind && $0.subject == next.subject && $0.statement == next.statement && $0.createdAt == next.createdAt && $0.status == next.status }
        }
        func history(_ statement: String, source: String = "task", supersedes: String? = nil) throws -> BackendKnowledgeRecord? {
            var next = try build("task-history", statement, source); next.supersedes = supersedes
            if already(next) { return nil }; try commit(real, next: next); return next
        }
        switch event.kind {
        case "delegated": _ = try history("Delegated “\(event.title)”\(to)." + (summary.isEmpty ? "" : " " + summary))
        case "reassigned": _ = try history("Reassigned “\(event.title)”\(to)." + (summary.isEmpty ? "" : " " + summary))
        case "stalled": _ = try history("“\(event.title)” stalled." + (summary.isEmpty ? "" : " " + summary))
        case "finished":
            let next = try build("result", event.title + ": " + (summary.isEmpty ? "finished, with no summary given." : summary), "task")
            if already(next) { return }; try commit(real, next: next)
            for old in results where old.status == "claim" { try retire(real, id: old.id, reason: "a newer result was claimed for the same task", by: next.provenance, replacement: next.id) }
        case "verified":
            let old = results.filter { $0.status == "claim" }.sorted { $0.createdAt > $1.createdAt }.first
            if (event.evidence ?? []).filter({ !BackendMemoryParsing.trim($0).isEmpty }).isEmpty {
                _ = try history("Review accepted the result of “\(event.title)” without naming evidence, so it stays a claim." + (summary.isEmpty ? "" : " " + summary), source: "review"); return
            }
            var next = try build("result", summary.isEmpty ? old?.statement ?? event.title + ": verified." : event.title + ": " + summary, "review")
            next.status = "verified"; next.verifiedAt = event.at; next.supersedes = old?.id
            if already(next) { return }; try commit(real, next: next)
            for old in results { try retire(real, id: old.id, reason: "verified by review", by: next.provenance, replacement: next.id) }
        case "rejected":
            let claims = results.filter { $0.status == "claim" }, reasons = summary.isEmpty ? "no reasons were given." : summary
            guard let next = try history("Review rejected the result of “\(event.title)”: " + reasons, source: "review", supersedes: claims.sorted { $0.createdAt > $1.createdAt }.first?.id) else { return }
            for old in claims { try retire(real, id: old.id, reason: "rejected by review: " + reasons, by: next.provenance, replacement: next.id) }
        default: throw BackendKnowledgeFormat.error("\(event.kind) is not a task knowledge event")
        }
    }
}
