import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

public struct BackendKnowledgeProvenance: Equatable, Sendable {
    public var source: String
    public var taskId: String?, goalId: String?, agentId: String?, sessionId: String?, conversationId: String?
    public var evidence: [String]?
    public init(source: String, taskId: String? = nil, goalId: String? = nil, agentId: String? = nil, sessionId: String? = nil, conversationId: String? = nil, evidence: [String]? = nil) {
        self.source = source; self.taskId = taskId; self.goalId = goalId; self.agentId = agentId; self.sessionId = sessionId; self.conversationId = conversationId; self.evidence = evidence
    }
    var wire: NativeRPCValue {
        BackendMemoryParsing.object([("source", .string(source)), ("taskId", taskId.map(NativeRPCValue.string) ?? .missing),
            ("goalId", goalId.map(NativeRPCValue.string) ?? .missing), ("agentId", agentId.map(NativeRPCValue.string) ?? .missing),
            ("sessionId", sessionId.map(NativeRPCValue.string) ?? .missing), ("conversationId", conversationId.map(NativeRPCValue.string) ?? .missing),
            ("evidence", evidence.map(BackendMemoryParsing.strings) ?? .missing)])
    }
}
public struct BackendKnowledgeRecord: Equatable, Sendable {
    public var id: String, project: String, kind: String, subject: String, statement: String, status: String
    public var provenance: BackendKnowledgeProvenance
    public var createdAt: Double, verifiedAt: Double?, staleAfterMs: Double?, supersedes: String?
    public init(id: String, project: String, kind: String, subject: String, statement: String, status: String = "claim", provenance: BackendKnowledgeProvenance,
                createdAt: Double, verifiedAt: Double? = nil, staleAfterMs: Double? = nil, supersedes: String? = nil) {
        self.id = id; self.project = project; self.kind = kind; self.subject = subject; self.statement = statement; self.status = status
        self.provenance = provenance; self.createdAt = createdAt; self.verifiedAt = verifiedAt; self.staleAfterMs = staleAfterMs; self.supersedes = supersedes
    }
}
public struct BackendKnowledgeView: Equatable, Sendable {
    public let record: BackendKnowledgeRecord; public let effective: String; public let notes: [String]
    public var id: String { record.id }; public var project: String { record.project }
    public init(record: BackendKnowledgeRecord, effective: String, notes: [String]) { self.record = record; self.effective = effective; self.notes = notes }
    public func shown(project: String, statementChars: Int = Int.max) -> NativeRPCValue {
        let r = record, p = r.provenance
        let text = r.statement.utf16.count > statementChars ? BackendMemoryParsing.cut(r.statement, max(0, statementChars - 1)) + "…" : r.statement
        return BackendMemoryParsing.object([("id", .string(r.id)), ("kind", .string(r.kind)), ("subject", .string(r.subject)), ("statement", .string(text)),
            ("status", .string(effective)), ("stored", .string(r.status)), ("why", notes.isEmpty ? .missing : BackendMemoryParsing.strings(notes)),
            ("source", .string(p.source)), ("task", p.taskId.map(NativeRPCValue.string) ?? .missing), ("goal", p.goalId.map(NativeRPCValue.string) ?? .missing),
            ("agent", p.agentId.map(NativeRPCValue.string) ?? .missing), ("evidence", p.evidence.map(BackendMemoryParsing.strings) ?? .missing),
            ("created", .string(BackendKnowledgeFormat.day(r.createdAt))), ("verified", r.verifiedAt.map { .string(BackendKnowledgeFormat.day($0)) } ?? .missing),
            ("supersedes", r.supersedes.map(NativeRPCValue.string) ?? .missing), ("sharedFrom", r.project == project ? .missing : .string(r.project))])
    }
}
public enum BackendKnowledgeFormat {
    public static let dayMs = 86_400_000.0, maxSubjectChars = 120, maxStatementChars = 4000, maxEvidenceItems = 20, maxEvidenceChars = 300
    public static let kinds = ["goal", "architecture", "decision", "constraint", "task-history", "result"]
    public static let statuses = ["claim", "verified", "superseded"], sources = ["owner", "hoot", "worker", "task", "review"]
    public static let keys = ["id", "kind", "subject", "status", "source", "task", "goal", "agent", "session", "conversation", "evidence", "created", "verified", "stale-after-days", "supersedes"]
    static func error(_ message: String) -> NativeRPCError { .init(code: "knowledge", message: message) }
    public static func validID(_ id: String) -> Bool { !BackendMemoryParsing.matches(#"^[A-Za-z0-9][A-Za-z0-9-]{0,63}$"#, id).isEmpty }
    public static func realProject(_ project: String) throws -> String {
        guard !BackendMemoryParsing.trim(project).isEmpty, project.hasPrefix("/") else { throw error("a project is named by its absolute folder path, not " + NativeRPCValue.string(project).compact) }
        return (try? BackendFilesystemAuthority.canonical(URL(fileURLWithPath: project)).path) ?? NativeTranscriptPaths.resolved(project)
    }
    public static func projectKey(_ real: String) -> String { SHA256.hash(data: Data(real.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() }
    public static func oneLine(_ text: String, max: Int) -> String {
        let flat = BackendMemoryParsing.trim(BackendMemoryParsing.replace(text, #"\s+"#, " "))
        return flat.utf16.count > max ? BackendMemoryParsing.trim(BackendMemoryParsing.cut(flat, max - 1)) + "…" : flat
    }
    public static func cleanEvidence(_ items: [String]?, roots: [String]) -> [String] {
        var out: [String] = []
        for raw in items ?? [] {
            var item = oneLine(raw, max: maxEvidenceChars).replacingOccurrences(of: ",", with: ";")
            if item.hasPrefix("/") {
                for root in roots {
                    let relative = relativePath(root: root, path: item)
                    if !relative.isEmpty, !relative.hasPrefix(".."), !relative.hasPrefix("/") { item = relative; break }
                }
            }
            if !item.isEmpty, !out.contains(item) { out.append(item) }; if out.count == maxEvidenceItems { break }
        }
        return out
    }
    static func iso(_ ms: Double) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: ms.rounded(.towardZero) / 1000))
    }
    public static func day(_ ms: Double) -> String { String(iso(ms).prefix(10)) }
    static func time(_ text: String?) -> Double? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return (date.timeIntervalSince1970 * 1000).rounded() }
        if !BackendMemoryParsing.matches(#"^\d{4}-\d{2}-\d{2}$"#, text).isEmpty, let date = ISO8601DateFormatter().date(from: text + "T00:00:00Z") { return (date.timeIntervalSince1970 * 1000).rounded() }
        // Date.parse's specified UTC/toString forms, and usual older local-date spellings.
        let unlabelled = BackendMemoryParsing.replace(text, #"\s*\([^)]*\)$"#, "")
        for pattern in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE MMM dd yyyy HH:mm:ss 'GMT'Z", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "MM/dd/yyyy", "MMMM d, yyyy", "MMM d, yyyy"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = .current; formatter.dateFormat = pattern; formatter.isLenient = false
            if let date = formatter.date(from: unlabelled) { return (date.timeIntervalSince1970 * 1000).rounded() }
        }
        return nil
    }
    static func relativePath(root: String, path: String) -> String {
        let a = NativeTranscriptPaths.resolved(root).split(separator: "/"), b = NativeTranscriptPaths.resolved(path).split(separator: "/")
        var common = 0; while common < a.count, common < b.count, a[common] == b[common] { common += 1 }
        return (Array(repeating: "..", count: a.count - common) + b.dropFirst(common).map(String.init)).joined(separator: "/")
    }
    public static func serialize(_ record: BackendKnowledgeRecord) -> String {
        let p = record.provenance
        let days = record.staleAfterMs.map { value -> String in let number = value / dayMs; return number.rounded() == number ? String(format: "%.0f", number) : String(number) }
        let values: [String: String?] = ["id": record.id, "kind": record.kind, "subject": record.subject, "status": record.status, "source": p.source,
            "task": p.taskId, "goal": p.goalId, "agent": p.agentId, "session": p.sessionId, "conversation": p.conversationId,
            "evidence": p.evidence?.isEmpty == false ? p.evidence?.joined(separator: ", ") : nil, "created": iso(record.createdAt),
            "verified": record.verifiedAt.map(iso), "stale-after-days": days, "supersedes": record.supersedes]
        var lines = ["---"]
        for key in keys {
            guard let value = values[key] ?? nil, !BackendMemoryParsing.trim(value).isEmpty else { continue }
            let flat = oneLine(value, max: 4000)
            let encoded = !BackendMemoryParsing.matches(#"^["'].*["']$"#, flat).isEmpty ? "\"" + flat + "\"" : flat
            lines.append(key + ": " + encoded)
        }
        lines += ["---", "", BackendMemoryParsing.trim(record.statement), ""]
        return lines.joined(separator: "\n")
    }
    public static func parse(_ text: String, file: String, project: String) -> BackendKnowledgeRecord? {
        let note = BackendMemoryParsing.parseNote(text, file: file), d = note.front
        let id = BackendMemoryParsing.replace(URL(fileURLWithPath: file).lastPathComponent, #"(?i)\.md$"#, "")
        guard validID(id), let kind = d["kind"], kinds.contains(kind), let status = d["status"], statuses.contains(status),
              let source = d["source"], sources.contains(source), let created = time(d["created"]), let subject = d["subject"], !subject.isEmpty else { return nil }
        let evidence = d["evidence"].map { $0.components(separatedBy: ",").map(BackendMemoryParsing.trim).filter { !$0.isEmpty } }
        var record = BackendKnowledgeRecord(id: id, project: project, kind: kind, subject: subject, statement: BackendMemoryParsing.trim(note.body), status: status,
            provenance: .init(source: source, taskId: d["task"], goalId: d["goal"], agentId: d["agent"], sessionId: d["session"], conversationId: d["conversation"], evidence: evidence?.isEmpty == false ? evidence : nil), createdAt: created, verifiedAt: time(d["verified"]))
        if let raw = d["stale-after-days"], let days = Double(raw), days.isFinite, days > 0 { record.staleAfterMs = (days * dayMs).rounded() }
        if let old = d["supersedes"], validID(old) { record.supersedes = old }; return record
    }
}

/// Internal disk owner; callers receive BackendKnowledgeService, never write/commit.
final class BackendKnowledgeStore {
    struct Share: Sendable { let from: String, to: String; let at: Double; var wire: NativeRPCValue { BackendMemoryParsing.object([("from", .string(from)), ("to", .string(to)), ("at", .number(at))]) } }
    let root: URL; let newID: @Sendable () throws -> String
    init(userData: String, newID: @escaping @Sendable () throws -> String) { root = URL(fileURLWithPath: userData).appendingPathComponent("knowledge"); self.newID = newID }
    func dir(_ real: String) -> URL { root.appendingPathComponent(BackendKnowledgeFormat.projectKey(real)) }
    func freshID(_ real: String) throws -> String {
        for _ in 0..<20 {
            let id = try newID(); guard BackendKnowledgeFormat.validID(id) else { throw BackendKnowledgeFormat.error("\(id) is not a usable record id") }
            if !FileManager.default.fileExists(atPath: dir(real).appendingPathComponent(id + ".md").path) { return id }
        }
        throw BackendKnowledgeFormat.error("could not find an unused record id")
    }
    func records(_ real: String) -> [BackendKnowledgeRecord] {
        BackendMemorySpaces.directory(dir(real).path).filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
            guard let text = try? BackendMemoryFiles.text(dir(real).appendingPathComponent(name).path) else { return nil }
            return BackendKnowledgeFormat.parse(text, file: name, project: real)
        }
    }
    func read(_ real: String, id: String) -> BackendKnowledgeRecord? { raw(real, id: id).flatMap { BackendKnowledgeFormat.parse($0, file: id + ".md", project: real) } }
    func raw(_ real: String, id: String) -> String? { guard BackendKnowledgeFormat.validID(id) else { return nil }; return try? BackendMemoryFiles.text(dir(real).appendingPathComponent(id + ".md").path) }
    func write(_ record: BackendKnowledgeRecord) throws {
        guard BackendKnowledgeFormat.validID(record.id) else { throw BackendKnowledgeFormat.error("\(record.id) is not a usable record id") }
        let directory = dir(record.project), marker = directory.appendingPathComponent("project.json")
        if !FileManager.default.fileExists(atPath: marker.path) {
            let json = BackendMemoryParsing.object([("project", .string(record.project))]); try BackendAccountFiles.writeAtomic(try json.encodedJSON(pretty: true) + Data("\n".utf8), to: marker)
        }
        try BackendAccountFiles.writeAtomic(Data(BackendKnowledgeFormat.serialize(record).utf8), to: directory.appendingPathComponent(record.id + ".md"))
    }
    func unlink(_ real: String, id: String) throws { if BackendKnowledgeFormat.validID(id) { try FileManager.default.removeItem(at: dir(real).appendingPathComponent(id + ".md")) } }
    func appendLog(_ real: String, _ entry: NativeRPCValue) throws {
        let directory = dir(real); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("log.jsonl"), bytes = try entry.encodedJSON() + Data("\n".utf8)
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BackendKnowledgeFormat.error("the project's knowledge log could not be opened") }; defer { Darwin.close(fd) }
        var at = 0
        while at < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: at), bytes.count - at) }
            if count < 0, errno == EINTR { continue }; guard count > 0 else { throw BackendKnowledgeFormat.error("the project's knowledge log could not be appended") }; at += count
        }
    }
    func log(_ real: String) -> [NativeRPCValue] {
        guard let text = try? BackendMemoryFiles.text(dir(real).appendingPathComponent("log.jsonl").path) else { return [] }
        return text.components(separatedBy: "\n").compactMap { try? NativeRPCValue.parseJSON(Data($0.utf8)) }
    }
    func shares() -> [Share] {
        guard let bytes = try? Data(contentsOf: root.appendingPathComponent("shares.json")), let value = try? NativeRPCValue.parseJSON(bytes), let shares = value["shares"].elements else { return [] }
        return shares.compactMap { guard let from = $0["from"].string, let to = $0["to"].string, let at = $0["at"].number else { return nil }; return .init(from: from, to: to, at: at) }
    }
    func writeShares(_ shares: [Share]) throws { try BackendAccountFiles.writeAtomic(try BackendMemoryParsing.object([("shares", .array(shares.map(\.wire)))]).encodedJSON(pretty: true) + Data("\n".utf8), to: root.appendingPathComponent("shares.json")) }
}
