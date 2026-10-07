import Foundation
import TerminalDeckNativeCore

public struct BackendKnowledgeClaim: Sendable {
    public let kind: String, subject: String, statement: String; public let provenance: BackendKnowledgeProvenance; public let staleAfterMs: Double?
    public init(kind: String, subject: String, statement: String, provenance: BackendKnowledgeProvenance, staleAfterMs: Double? = nil) {
        self.kind = kind; self.subject = subject; self.statement = statement; self.provenance = provenance; self.staleAfterMs = staleAfterMs
    }
}
public struct BackendKnowledgeReplacement: Sendable {
    public let statement: String; public let subject: String?, kind: String?; public let evidence: [String]?; public let staleAfterMs: Double?
    public init(statement: String, subject: String? = nil, kind: String? = nil, evidence: [String]? = nil, staleAfterMs: Double? = nil) {
        self.statement = statement; self.subject = subject; self.kind = kind; self.evidence = evidence; self.staleAfterMs = staleAfterMs
    }
}
public struct BackendKnowledgeShareRequest: Sendable { public let from: String, to: String; public let records: Int }

public enum BackendKnowledgeStatus {
    public static func evidenceFile(project: String, item: String) -> String? {
        let text = BackendMemoryParsing.trim(item)
        guard !text.isEmpty, BackendMemoryParsing.matches(#"(?i)^[a-z][a-z0-9+.-]*://"#, text).isEmpty else { return nil }
        let bare = BackendMemoryParsing.replace(text, #":\d+(?::\d+)?$"#, "")
        let full = NativeTranscriptPaths.resolved(bare.hasPrefix("/") ? bare : BackendMemorySpaces.joined(project, bare))
        let relative = BackendKnowledgeFormat.relativePath(root: project, path: full)
        guard !relative.isEmpty, !relative.hasPrefix(".."), !relative.hasPrefix("/") else { return nil }; return full
    }
    public static func fileMtime(_ path: String) -> Double? { guard let info = try? BackendMemoryFiles.info(path), info.file else { return nil }; return info.modified * 1000 }
    public static func views(_ records: [BackendKnowledgeRecord], now: Double, statMtime: (String) -> Double?) -> [BackendKnowledgeView] {
        let live = records.filter { $0.status != "superseded" && $0.kind != "task-history" }
        func flat(_ value: String) -> String { BackendMemoryParsing.trim(BackendMemoryParsing.replace(value, #"\s+"#, " ")) }
        return records.map { record in
            if record.status == "superseded" { return .init(record: record, effective: "superseded", notes: []) }
            let others = record.kind == "task-history" ? [] : live.filter { $0.id != record.id && flat($0.subject).lowercased() == flat(record.subject).lowercased() && flat($0.statement) != flat(record.statement) }
            let conflict = others.map { "disagrees with \($0.id) (\($0.status), \(BackendKnowledgeFormat.day($0.verifiedAt ?? $0.createdAt))) on \"\(record.subject)\"" }
            let since = record.verifiedAt ?? record.createdAt, word = record.verifiedAt == nil ? "recorded" : "verified"
            let limit = record.staleAfterMs ?? (record.kind == "result" ? 30 * BackendKnowledgeFormat.dayMs : record.kind == "architecture" ? 90 * BackendKnowledgeFormat.dayMs : nil)
            var stale: [String] = []
            if let limit, now - since > limit {
                stale.append("\(word) \(Int(floor((now - since) / BackendKnowledgeFormat.dayMs))) days ago (\(BackendKnowledgeFormat.day(since))); a \(record.kind) older than \(Int((limit / BackendKnowledgeFormat.dayMs).rounded())) days is re-checked")
            }
            for item in record.provenance.evidence ?? [] {
                guard let file = evidenceFile(project: record.project, item: item), let modified = statMtime(file), modified > since else { continue }
                stale.append("\(BackendKnowledgeFormat.relativePath(root: record.project, path: file)) changed after it was \(word) (\(BackendKnowledgeFormat.day(modified)) > \(BackendKnowledgeFormat.day(since)))")
            }
            return .init(record: record, effective: !conflict.isEmpty ? "conflicting" : !stale.isEmpty ? "stale" : record.status, notes: conflict + stale)
        }
    }
}

/// Claim-only public API, task-event ingestion and bounded briefs (book.ts + index.ts).
public actor BackendKnowledgeService {
    let store: BackendKnowledgeStore
    let now: @Sendable () -> Double
    let statMtime: @Sendable (String) -> Double?
    let onError: @Sendable (String, String) -> Void
    private let consent: (@Sendable (BackendKnowledgeShareRequest) async throws -> Bool)?
    public init(userData: String, now: @escaping @Sendable () -> Double = { (Date().timeIntervalSince1970 * 1000).rounded(.down) },
                consent: (@Sendable (BackendKnowledgeShareRequest) async throws -> Bool)? = nil,
                statMtime: (@Sendable (String) -> Double?)? = nil, newID: (@Sendable () throws -> String)? = nil,
                onError: @escaping @Sendable (String, String) -> Void = { NSLog("[knowledge] %@: %@", $1, $0) }) {
        store = BackendKnowledgeStore(userData: userData, newID: newID ?? { "k" + (try BackendAccountFiles.randomHex(bytes: 5)) })
        self.now = now; self.consent = consent; self.statMtime = statMtime ?? BackendKnowledgeStatus.fileMtime; self.onError = onError
    }
    public func projectOf(_ project: String) throws -> String { try BackendKnowledgeFormat.realProject(project) }
    public func dirOf(_ project: String) throws -> String { store.dir(try projectOf(project)).path }
    public func sharedInto(_ project: String) throws -> [String] {
        let real = try projectOf(project)
        return BackendMemoryParsing.unique(store.shares().filter { $0.to == real && $0.from != real }.map(\.from))
    }
    public func sharedOut(_ project: String) throws -> [String] {
        let real = try projectOf(project)
        return BackendMemoryParsing.unique(store.shares().filter { $0.from == real && $0.to != real }.map(\.to))
    }
    func ownViews(_ real: String) -> [BackendKnowledgeView] {
        BackendKnowledgeStatus.views(store.records(real).sorted { $0.createdAt == $1.createdAt ? $0.id.localizedCompare($1.id) == .orderedAscending : $0.createdAt > $1.createdAt }, now: now(), statMtime: statMtime)
    }
    public func list(_ project: String, shared: Bool = false, superseded: Bool = false) throws -> [BackendKnowledgeView] {
        let real = try projectOf(project); var views = ownViews(real)
        if shared { for from in try sharedInto(real) { views += ownViews(from) } }
        return superseded ? views : views.filter { $0.effective != "superseded" }
    }
    public func get(_ project: String, id: String) throws -> BackendKnowledgeView? {
        let real = try projectOf(project)
        for owner in [real] + (try sharedInto(real)) { if let view = ownViews(owner).first(where: { $0.id == id }) { return view } }; return nil
    }
    public func history(_ project: String, id: String) throws -> [BackendKnowledgeView] {
        guard let start = try get(project, id: id) else { return [] }
        let all = Dictionary(uniqueKeysWithValues: ownViews(start.project).map { ($0.id, $0) })
        var next = start.record.supersedes, chain: [BackendKnowledgeView] = []
        while let id = next, chain.count < 50, let view = all[id], !chain.contains(where: { $0.id == id }) { chain.append(view); next = view.record.supersedes }
        return chain
    }
    public func supersededBy(_ project: String, id: String) throws -> String? { store.records(try projectOf(project)).first { $0.supersedes == id }?.id }
    public func record(_ project: String, input: BackendKnowledgeClaim) throws -> BackendKnowledgeView {
        let real = try projectOf(project), next = try claim(project, real: real, input: input)
        try commit(real, next: next); return viewOf(next)
    }
    public func supersede(_ project: String, id: String, reason: String, by: BackendKnowledgeProvenance, replacement: BackendKnowledgeReplacement? = nil) throws -> (superseded: BackendKnowledgeView, replacement: BackendKnowledgeView?) {
        let real = try projectOf(project), reason = try reasonOf(reason)
        guard let old = store.read(real, id: id) else { throw BackendKnowledgeFormat.error("there is no record \(id) in this project’s knowledge") }
        if old.status == "superseded" {
            let replaced = try supersededBy(real, id: id)
            throw BackendKnowledgeFormat.error("\(id) is already superseded" + (replaced.map { " by " + $0 } ?? ""))
        }
        var next: BackendKnowledgeRecord?
        if let replacement {
            var provenance = by; provenance.evidence = replacement.evidence
            next = try claim(project, real: real, input: .init(kind: replacement.kind ?? old.kind, subject: replacement.subject ?? old.subject, statement: replacement.statement, provenance: provenance, staleAfterMs: replacement.staleAfterMs ?? old.staleAfterMs))
            next?.supersedes = id
        }
        try commit(real, next: next); try retire(real, id: id, reason: reason, by: by, replacement: next?.id)
        return (viewOf(store.read(real, id: id)!), next.map(viewOf))
    }
    public func remove(_ project: String, id: String, reason: String, by: BackendKnowledgeProvenance) throws {
        let real = try projectOf(project), reason = try reasonOf(reason)
        guard let raw = store.raw(real, id: id), store.read(real, id: id) != nil else { throw BackendKnowledgeFormat.error("there is no record \(id) in this project’s knowledge") }
        try store.appendLog(real, logEntry(action: "delete", reason: reason, by: by).setting("id", .string(id)).setting("record", .string(raw)))
        try store.unlink(real, id: id)
    }
    public func share(from: String, to: String, by: BackendKnowledgeProvenance = .init(source: "owner")) async throws -> Bool {
        let realFrom = try projectOf(from), realTo = try projectOf(to)
        if realFrom == realTo { throw BackendKnowledgeFormat.error("a project already reads its own knowledge") }
        if try sharedOut(realFrom).contains(realTo) { return true }
        guard let consent, try await consent(.init(from: realFrom, to: realTo, records: store.records(realFrom).count)) == true else { return false }
        let at = now(); try store.writeShares(store.shares() + [.init(from: realFrom, to: realTo, at: at)])
        try store.appendLog(realFrom, logEntry(action: "share", reason: "shared with " + realTo, by: by).setting("at", .number(at)).setting("project", .string(realTo)))
        return true
    }
    public func unshare(from: String, to: String, by: BackendKnowledgeProvenance = .init(source: "owner")) throws -> Bool {
        let realFrom = try projectOf(from), realTo = try projectOf(to), shares = store.shares()
        let kept = shares.filter { !($0.from == realFrom && $0.to == realTo) }; guard kept.count != shares.count else { return false }
        try store.writeShares(kept)
        try store.appendLog(realFrom, logEntry(action: "unshare", reason: "no longer shared with " + realTo, by: by).setting("project", .string(realTo))); return true
    }
    public func changes(_ project: String) throws -> [NativeRPCValue] { store.log(try projectOf(project)) }
    func claim(_ project: String, real: String, input: BackendKnowledgeClaim) throws -> BackendKnowledgeRecord {
        guard BackendKnowledgeFormat.kinds.contains(input.kind) else { throw BackendKnowledgeFormat.error("\(input.kind) is not a kind of knowledge") }
        let subject = BackendKnowledgeFormat.oneLine(try requiredText(input.subject, label: "subject", max: 480), max: 120)
        let statement = try requiredText(input.statement, label: "statement", max: 4000)
        guard BackendKnowledgeFormat.sources.contains(input.provenance.source) else { throw BackendKnowledgeFormat.error("\(input.provenance.source) is not a knowledge source") }
        var p = input.provenance
        func cleanID(_ id: String?) -> String? { id.map { BackendKnowledgeFormat.oneLine($0, max: 200) }.flatMap { $0.isEmpty ? nil : $0 } }
        p.taskId = cleanID(p.taskId); p.goalId = cleanID(p.goalId); p.agentId = cleanID(p.agentId); p.sessionId = cleanID(p.sessionId); p.conversationId = cleanID(p.conversationId)
        let evidence = BackendKnowledgeFormat.cleanEvidence(p.evidence, roots: BackendMemoryParsing.unique([real, project.hasPrefix("/") ? NativeTranscriptPaths.resolved(project) : real])); p.evidence = evidence.isEmpty ? nil : evidence
        if let limit = input.staleAfterMs, !limit.isFinite || limit <= 0 { throw BackendKnowledgeFormat.error("staleAfterMs must be a positive number") }
        return .init(id: try store.freshID(real), project: real, kind: input.kind, subject: subject, statement: statement, provenance: p, createdAt: now(), staleAfterMs: input.staleAfterMs.map { $0.rounded() })
    }
    func requiredText(_ value: String, label: String, max: Int) throws -> String {
        let value = BackendMemoryParsing.trim(value)
        guard !value.isEmpty else { throw BackendKnowledgeFormat.error("\(label) is required") }
        if value.utf16.count > max { throw BackendKnowledgeFormat.error("\(label) is \(value.utf16.count) characters; at most \(max) — put the rest in a file and name it as evidence") }; return value
    }
    func reasonOf(_ reason: String) throws -> String {
        guard !BackendMemoryParsing.trim(reason).isEmpty else { throw BackendKnowledgeFormat.error("a reason is required, and is kept in the project’s log") }
        return BackendKnowledgeFormat.oneLine(reason, max: 500)
    }
    func commit(_ real: String, next: BackendKnowledgeRecord?) throws {
        guard let next else { return }; guard next.project == real else { throw BackendKnowledgeFormat.error("a record is written into its own project only") }; try store.write(next)
    }
    func retire(_ real: String, id: String, reason: String, by: BackendKnowledgeProvenance, replacement: String?) throws {
        guard var old = store.read(real, id: id), old.status != "superseded" else { return }; old.status = "superseded"; try store.write(old)
        try store.appendLog(real, logEntry(action: "supersede", reason: BackendKnowledgeFormat.oneLine(reason, max: 500), by: by).setting("id", .string(id)).setting("replacement", replacement.map(NativeRPCValue.string) ?? .missing))
    }
    func logEntry(action: String, reason: String, by: BackendKnowledgeProvenance) -> NativeRPCValue {
        BackendMemoryParsing.object([("at", .number(now())), ("action", .string(action)), ("reason", .string(reason)), ("by", by.wire)])
    }
    func viewOf(_ record: BackendKnowledgeRecord) -> BackendKnowledgeView {
        ownViews(record.project).first { $0.id == record.id } ?? BackendKnowledgeStatus.views([record], now: now(), statMtime: statMtime)[0]
    }
}
