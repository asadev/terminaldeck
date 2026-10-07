import Foundation
import TerminalDeckNativeCore

public struct BackendDeckCoreReportTrail: Sendable {
    public let transcript: BackendCostTranscript
    public let fileBytes: Double
    public let fromByte: Double
    public init(transcript: BackendCostTranscript, fileBytes: Double, fromByte: Double) {
        var transcript = transcript
        transcript.truncated = fromByte > 0
        self.transcript = transcript; self.fileBytes = fileBytes; self.fromByte = fromByte
    }
}

/// Supplied by the native account/transcript and Git services. No live store is
/// chosen implicitly, and missing readers fail rather than report healthy work.
public protocol BackendDeckCoreReportSurface: Sendable {
    func listSessions() -> [NativeRPCValue]
    func transcriptsIn(cwd: String) async throws -> [NativeRPCValue]
    func transcriptBytes(path: String) async throws -> Double
    func readTranscriptFrom(path: String, fromByte: Double) async throws -> [NativeRPCValue]
    func readToolTrail(path: String, windowBytes: Int) async throws -> BackendDeckCoreReportTrail
    func transcriptTotals(path: String) async throws -> NativeRPCValue?
    func gitChanges(cwd: String) async throws -> NativeRPCValue
    func fileModifiedAt(path: String) async throws -> Double?
}

public enum BackendDeckCoreReports {
    public static let trailWindowBytes = 2 * 1024 * 1024, totalsMaxBytes = 24 * 1024 * 1024
    public static let maxLastMessageChars = 1200, defaultReportSessions = 8, maxReportSessions = 25

    public static func transcriptFor(surface: any BackendDeckCoreReportSurface, session: NativeRPCValue) async throws -> NativeRPCValue {
        let cwd = session["cwd"].string ?? ""
        let files = try await surface.transcriptsIn(cwd: cwd)
        return matchTranscript(session: session, files: files, sessionsInFolder: surface.listSessions().filter { $0["cwd"].string == cwd })
    }

    /// Companion to report.ts's imported matcher. Attribution always travels
    /// with its evidence, including the deliberately uncertain resumed case.
    public static func matchTranscript(session: NativeRPCValue, files: [NativeRPCValue], sessionsInFolder: [NativeRPCValue], toleranceMs: Double = 120_000) -> NativeRPCValue {
        func writes(_ value: NativeRPCValue) -> Bool { value["provider"].isNullish || value["provider"].string == "claude" }
        let id = session["id"].string ?? "", start = session["createdAt"].number ?? 0
        let others = sessionsInFolder.filter { $0["id"].string != id && writes($0) }.compactMap { $0["id"].string }
        func match(_ path: String?, _ basis: String, _ ambiguous: Bool, _ note: String?) -> NativeRPCValue {
            .object([.init("path", path.map(NativeRPCValue.string) ?? .null), .init("basis", .string(basis)), .init("ambiguous", .bool(ambiguous)),
                .init("otherSessions", .array(others.map(NativeRPCValue.string))), .init("note", note.map(NativeRPCValue.string) ?? .null)])
        }
        guard writes(session) else { return match(nil, "none", false, "A \(session["provider"].string ?? "session") session writes no transcript, so nothing in this folder is its conversation.") }
        let conversations = files.filter { ($0["bytes"].number ?? 0) > 0 }
        guard !conversations.isEmpty else { return match(nil, "none", false, nil) }
        func newest(_ values: [NativeRPCValue]) -> NativeRPCValue {
            values.dropFirst().reduce(values[0]) { ($1["modifiedAt"].number ?? 0) > ($0["modifiedAt"].number ?? 0) ? $1 : $0 }
        }
        if others.isEmpty {
            return match(newest(conversations)["path"].string, conversations.count == 1 ? "only-one" : "newest", false,
                conversations.count == 1 ? nil : "Several conversations in this folder; this is the most recent, and no other session is running here.")
        }
        if session["resumed"].bool == true {
            return match(newest(conversations)["path"].string, "newest", true,
                "This is the most recently written conversation in the folder rather than certainly this session's — it was resumed, so its conversation began before it did. Treat what it says as possibly another session's.")
        }
        let born = conversations.filter { abs(($0["createdAt"].number ?? 0) - start) <= toleranceMs }
        guard !born.isEmpty else { return match(nil, "none", false, "Every conversation in this folder began before this session started, so none of them is its. It has not written one yet.") }
        let claimants = sessionsInFolder.filter { $0["resumed"].bool != true }
        let mine = born.filter { file in
            let birth = file["createdAt"].number ?? 0
            let nearest = claimants.min { a, b in
                let x = abs((a["createdAt"].number ?? 0) - birth), y = abs((b["createdAt"].number ?? 0) - birth)
                return x == y ? (a["id"].string ?? "") < (b["id"].string ?? "") : x < y
            }
            return nearest?["id"].string == id
        }
        guard !mine.isEmpty else { return match(nil, "none", false, "Every conversation in this folder began nearer to another session's start than to this one's, so none of them is its.") }
        if mine.count == 1 {
            return match(mine[0]["path"].string, "started-together", true,
                "\(others.count) other session\(others.count == 1 ? "" : "s") share this folder; this file is the one that began nearest to when this session did.")
        }
        let nearest = mine.dropFirst().reduce(mine[0]) { a, b in abs((b["createdAt"].number ?? 0) - start) < abs((a["createdAt"].number ?? 0) - start) ? b : a }
        return match(nearest["path"].string, "nearest-start", true,
            "\(mine.count) conversations here began nearest to this session; this is the closest of them. Treat what it says as possibly another session's.")
    }

    public static func session(surface: any BackendDeckCoreReportSurface, session: NativeRPCValue, withChanges: Bool = true, fleet: BackendDeckCoreFleetContext = .none) async throws -> NativeRPCValue {
        let match = try await transcriptFor(surface: surface, session: session)
        let path = match["path"].string
        let bytes: Double
        let trail: BackendDeckCoreReportTrail?
        let spend: NativeRPCValue
        let lastMessage: NativeRPCValue
        if let path {
            bytes = try await surface.transcriptBytes(path: path)
            trail = try await surface.readToolTrail(path: path, windowBytes: trailWindowBytes)
            spend = try await spendOf(surface: surface, path: path, bytes: bytes)
            lastMessage = try await lastAgentMessage(surface: surface, path: path, bytes: bytes)
        } else { bytes = 0; trail = nil; spend = .null; lastMessage = .null }
        let changes: NativeRPCValue
        if withChanges { changes = try await changesIn(surface: surface, cwd: session["cwd"].string ?? "") }
        else { changes = .null }
        var transcript: NativeRPCValue = .null
        if let path {
            transcript = .object([.init("path", .string(path)), .init("bytes", .number(bytes)), .init("parsedFrom", .number(trail?.fromByte ?? 0)),
                .init("partial", .bool((trail?.fromByte ?? 0) > 0)), .init("basis", match["basis"]), .init("ambiguous", match["ambiguous"])])
            if let note = match["note"].string { transcript = transcript.setting("note", .string(note)) }
        }
        var report = NativeRPCValue.object([.init("sessionId", session["id"]), .init("cwd", session["cwd"]), .init("title", session["title"]), .init("provider", session["provider"]),
            .init("attention", session["attention"]), .init("attentionReason", session["attentionReason"]), .init("attentionForMs", session["attentionForMs"]),
            .init("status", session["status"]), .init("statusSource", session["statusSource"]), .init("createdAt", session["createdAt"]), .init("exitCode", session["exitCode"]),
            .init("startedByCopilot", session["startedByCopilot"]), .init("transcript", transcript), .init("spend", spend),
            .init("progress", BackendDeckCoreProgress.assess(trail?.transcript)), .init("lastMessage", lastMessage), .init("changes", changes)])
        if path == nil, let note = match["note"].string { report = report.setting("transcriptNote", .string(note)) }
        report = report.setting("reasons", .array(BackendDeckCoreImportance.reasons(importanceOf(report), fleet: fleet)))
        return report.setting("verdict", .string(verdictFor(report)))
    }

    public static func importanceOf(_ report: NativeRPCValue) -> NativeRPCValue {
        .object([.init("attention", report["attention"]), .init("attentionReason", report["attentionReason"]), .init("exitCode", report["exitCode"]), .init("progress", report["progress"]),
            .init("totalTokens", report["spend"]["totalTokens"].isNullish ? .null : report["spend"]["totalTokens"]),
            .init("changedFiles", report["changes"]["files"].isNullish ? .number(0) : report["changes"]["files"]),
            .init("lastMessage", report["lastMessage"]["truncated"].bool == true ? .null : report["lastMessage"]["text"].string.map { .string(BackendDeckCoreCatalogueRules.trim($0)) } ?? .null)])
    }
    private static func spendOf(surface: any BackendDeckCoreReportSurface, path: String, bytes: Double) async throws -> NativeRPCValue {
        if bytes > Double(totalsMaxBytes) {
            return .object([.init("requests", .number(0)), .init("usage", BackendCostTokens().wireValue), .init("totalTokens", .number(0)), .init("models", .array([])),
                .init("compactions", .number(0)), .init("contextPercent", .null), .init("skipped", .string("This transcript is \(Int(floor(bytes / 1_000_000 + 0.5))) MB, which is too large to total inside a fleet report. Ask about this session on its own."))])
        }
        guard let totals = try await surface.transcriptTotals(path: path) else { return .null }
        let total = ["input", "output", "cacheWrite5m", "cacheWrite1h", "cacheRead"].reduce(0.0) { $0 + (totals["usage"][$1].number ?? 0) }
        return .object([.init("requests", totals["requests"]), .init("usage", totals["usage"]), .init("totalTokens", .number(total)), .init("models", totals["models"]),
            .init("compactions", totals["compactions"]), .init("contextPercent", totals["context"]["percent"].number.map { .number(floor($0 + 0.5)) } ?? .null), .init("skipped", .null)])
    }
    private static func lastAgentMessage(surface: any BackendDeckCoreReportSurface, path: String, bytes: Double) async throws -> NativeRPCValue {
        for message in try await surface.readTranscriptFrom(path: path, fromByte: max(0, bytes - 256 * 1024)).reversed() {
            guard message["role"].string == "agent", let raw = message["text"].string else { continue }
            let text = BackendDeckCoreCatalogueRules.trim(raw)
            guard !text.isEmpty else { continue }
            let cut = text.utf16.count > maxLastMessageChars
            return .object([.init("at", message["at"]), .init("text", .string(cut ? String(decoding: text.utf16.prefix(maxLastMessageChars), as: UTF16.self) + "…" : text)), .init("truncated", .bool(cut))])
        }
        return .null
    }
    private static func changesIn(surface: any BackendDeckCoreReportSurface, cwd: String) async throws -> NativeRPCValue {
        let changes = try await surface.gitChanges(cwd: cwd)
        let files = changes["repo"].bool == true ? (changes["files"].elements ?? []) : []
        return .object([.init("files", .number(Double(files.count))), .init("insertions", .number(files.reduce(0) { $0 + ($1["insertions"].number ?? 0) })),
            .init("deletions", .number(files.reduce(0) { $0 + ($1["deletions"].number ?? 0) })), .init("paths", .array(files.prefix(20).map { $0["path"] })),
            .init("more", .bool(files.count > 20)), .init("reason", changes["repo"].bool == true ? .null : changes["reason"])])
    }
    public static func verdictFor(_ report: NativeRPCValue) -> String {
        let title = report["title"].string ?? "", whereText = title.isEmpty ? (report["cwd"].string ?? "") : title
        if report["attention"].string == "blocked" {
            let waited = report["attentionForMs"].number.map { " for " + minutes($0) } ?? ""
            return "Blocked on you\(waited) — \(whereText)."
        }
        if let exit = report["exitCode"].number, exit != 0 { return "Exited \(Int(exit)) — \(whereText)." }
        if report["progress"]["verdict"].string == "looping" { return "\(BackendDeckCoreProgress.sentence(report["progress"])) — \(whereText)." }
        if report["attention"].string == "done" {
            let n = Int(report["changes"]["files"].number ?? 0), wrote = n == 0 ? "nothing changed on disk" : "\(n) file\(n == 1 ? "" : "s") changed"
            return "Finished — \(wrote), \(whereText)."
        }
        return "\(report["attention"].string == "running" ? "Working" : "Quiet") — \(whereText)."
    }
    private static func minutes(_ ms: Double) -> String {
        let total = Int(floor(ms / 60_000 + 0.5))
        if total < 60 { return "\(total) min" }
        return total % 60 == 0 ? "\(total / 60)h" : "\(total / 60)h \(total % 60)m"
    }
    public static func fleet(surface: any BackendDeckCoreReportSurface, sessions: [NativeRPCValue], since: Double? = nil, limit: Int = 8, now: Double) async throws -> NativeRPCValue {
        let matching = sessions.filter { since == nil || max($0["statusSince"].number ?? 0, $0["createdAt"].number ?? 0) >= since! }
        let chosen = Array(matching.prefix(min(max(limit, 1), 25)))
        var read: [NativeRPCValue] = []
        for view in chosen { read.append(try await session(surface: surface, session: view)) }
        let context = BackendDeckCoreFleetContext.make(read.map { $0["spend"]["totalTokens"].number })
        let reports = read.map { $0.setting("reasons", .array(BackendDeckCoreImportance.reasons(importanceOf($0), fleet: context))) }
        var totals = NativeRPCValue.object([.init("sessions", .number(Double(reports.count)))])
        for attention in ["blocked", "running", "quiet", "done"] { totals = totals.setting(attention, .number(Double(reports.filter { $0["attention"].string == attention }.count))) }
        totals = totals.setting("failed", .number(Double(reports.filter { $0["exitCode"].number != nil && $0["exitCode"].number != 0 }.count)))
            .setting("looping", .number(Double(reports.filter { $0["progress"]["verdict"].string == "looping" }.count)))
            .setting("requests", .number(reports.reduce(0) { $0 + ($1["spend"]["requests"].number ?? 0) }))
            .setting("totalTokens", .number(reports.reduce(0) { $0 + ($1["spend"]["totalTokens"].number ?? 0) }))
        return .object([.init("generatedAt", .number(now)), .init("since", since.map(NativeRPCValue.number) ?? .null), .init("reports", .array(reports)),
            .init("omitted", .number(Double(matching.count - chosen.count))), .init("totals", totals), .init("headline", .string(headline(totals)))])
    }
    public static func headline(_ totals: NativeRPCValue) -> String {
        let sessions = Int(totals["sessions"].number ?? 0)
        guard sessions > 0 else { return "Nothing has run in that window." }
        var parts: [String] = []
        for (key, label) in [("blocked", "waiting on you"), ("failed", "failed"), ("looping", "looking stuck"), ("running", "still working")] {
            let n = Int(totals[key].number ?? 0); if n > 0 { parts.append("\(n) \(label)") }
        }
        let clean = max(0, Int(totals["done"].number ?? 0) - Int(totals["failed"].number ?? 0))
        if clean > 0 { parts.append("\(clean) finished") }
        if parts.isEmpty { parts.append("\(sessions) quiet") }
        return "\(sessions) session\(sessions == 1 ? "" : "s"): \(parts.joined(separator: ", "))."
    }
}
