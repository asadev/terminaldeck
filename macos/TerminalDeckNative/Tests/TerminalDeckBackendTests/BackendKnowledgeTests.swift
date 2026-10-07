import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendKnowledgeTests: XCTestCase {
    private let t0 = 1_759_320_000_000.0
    private func temp() throws -> (root: String, api: String, web: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("td-knowledge-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("api"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("web"), withIntermediateDirectories: true)
        let root = try BackendFilesystemAuthority.canonical(url).path; return (root, root + "/api", root + "/web")
    }
    private func claim(_ subject: String = "Database", _ statement: String = "SQLite.", kind: String = "decision") -> BackendKnowledgeClaim {
        .init(kind: kind, subject: subject, statement: statement, provenance: .init(source: "hoot"))
    }
    func testCanonicalProjectsKeysAndLazyDisk() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }
        let service = BackendKnowledgeService(userData: f.root + "/data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root + "/data/knowledge"))
        let link = f.root + "/api-link"; try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: f.api)
        let view = try await service.record(link, input: claim())
        XCTAssertEqual(view.project, f.api)
        let dir = try await service.dirOf(link)
        XCTAssertEqual(dir, f.root + "/data/knowledge/" + BackendKnowledgeFormat.projectKey(f.api))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).sorted(), [view.id + ".md", "project.json"].sorted())
        let found = try await service.get(f.api, id: view.id); XCTAssertEqual(found?.id, view.id)
        let other = try await service.get(f.web, id: view.id); XCTAssertNil(other)
        do { _ = try await service.record("relative", input: claim()); XCTFail("relative project accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("absolute folder path")) }
    }
    func testExactRecordRoundTripQuotesAndFractionalDays() {
        let record = BackendKnowledgeRecord(id: "kabc", project: "/work/api", kind: "result", subject: "\"quoted\" subject", statement: "Works: really.\n---\nStill body.", status: "verified", provenance: .init(source: "review", taskId: "local:7", agentId: "builder", sessionId: "s1", conversationId: "c1", evidence: ["a.ts", "b.ts"]), createdAt: t0, verifiedAt: t0 + 5, staleAfterMs: 3_600_000, supersedes: "kold")
        let text = BackendKnowledgeFormat.serialize(record)
        XCTAssertEqual(BackendKnowledgeFormat.parse(text, file: "kabc.md", project: "/work/api"), record)
        XCTAssertEqual(BackendMemoryParsing.frontMatter(text)["status"], "verified")
        XCTAssertEqual(BackendMemoryParsing.frontMatter(text)["created"], "2025-10-01T12:00:00.000Z")
        XCTAssertNil(BackendKnowledgeFormat.parse("plain", file: "kx.md", project: "/work/api"))
        XCTAssertNil(BackendKnowledgeFormat.parse("---\nkind: decision\n---\nmissing status", file: "kx.md", project: "/work/api"))
        XCTAssertFalse(BackendKnowledgeFormat.validID("../escape"))
        XCTAssertEqual(BackendKnowledgeFormat.time("Wed, 01 Oct 2025 12:00:00 GMT"), t0)
        XCTAssertEqual(BackendKnowledgeFormat.time("Wed Oct 01 2025 12:00:00 GMT+0000 (Coordinated Universal Time)"), t0)
    }
    func testEvidenceLimitsAndOnlyClaims() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }
        let service = BackendKnowledgeService(userData: f.root + "/data")
        let input = BackendKnowledgeClaim(kind: "architecture", subject: "Renderer", statement: "React.\nNo Redux.", provenance: .init(source: "owner", taskId: "t1", goalId: "g1", evidence: [f.api + "/src/store.ts", "npm test, green", "npm test, green"]), staleAfterMs: 3 * BackendKnowledgeFormat.dayMs)
        let view = try await service.record(f.api, input: input)
        XCTAssertEqual(view.record.status, "claim"); XCTAssertNil(view.record.verifiedAt); XCTAssertEqual(view.record.provenance.evidence, ["src/store.ts", "npm test; green"])
        XCTAssertEqual(BackendKnowledgeFormat.cleanEvidence((0..<30).map { "e\($0)" }, roots: []).count, 20)
        do { _ = try await service.record(f.api, input: claim("s", "  ")); XCTFail("empty statement accepted") } catch { XCTAssertEqual(error.localizedDescription, "statement is required") }
        do { _ = try await service.record(f.api, input: claim("s", String(repeating: "x", count: 4001))); XCTFail("oversized statement accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("at most 4000")) }
        do { _ = try await service.record(f.api, input: .init(kind: "decision", subject: "s", statement: "x", provenance: .init(source: "bad"))); XCTFail("source accepted") } catch { XCTAssertEqual(error.localizedDescription, "bad is not a knowledge source") }
    }
    func testShareDefaultRefusalOneWayAndCorruptList() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }
        let denied = BackendKnowledgeService(userData: f.root + "/data")
        let no = try await denied.share(from: f.api, to: f.web); XCTAssertFalse(no)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root + "/data/knowledge/shares.json"))
        let service = BackendKnowledgeService(userData: f.root + "/data", consent: { _ in true })
        let record = try await service.record(f.api, input: claim())
        let yes = try await service.share(from: f.api, to: f.web); XCTAssertTrue(yes)
        let shared = try await service.list(f.web, shared: true); XCTAssertEqual(shared.map(\.id), [record.id])
        let own = try await service.list(f.web); XCTAssertTrue(own.isEmpty)
        let into = try await service.sharedInto(f.api); XCTAssertTrue(into.isEmpty)
        let again = try await service.share(from: f.api, to: f.web); XCTAssertTrue(again)
        let changes = try await service.changes(f.api); XCTAssertEqual(changes.map { $0["action"].string }, ["share"])
        try Data("{bad".utf8).write(to: URL(fileURLWithPath: f.root + "/data/knowledge/shares.json"))
        let corrupt = try await service.sharedInto(f.web); XCTAssertTrue(corrupt.isEmpty)
    }
    func testUnshareNarrowsAndDoesNotAsk() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }
        let service = BackendKnowledgeService(userData: f.root + "/data", consent: { _ in true })
        _ = try await service.share(from: f.api, to: f.web)
        let first = try await service.unshare(from: f.api, to: f.web), second = try await service.unshare(from: f.api, to: f.web)
        XCTAssertTrue(first); XCTAssertFalse(second)
        let shares = try await service.sharedInto(f.web); XCTAssertTrue(shares.isEmpty)
    }
    func testSupersedeHistoryOwnershipReasonAndDeleteAudit() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }
        let service = BackendKnowledgeService(userData: f.root + "/data", consent: { _ in true })
        let first = try await service.record(f.api, input: claim())
        let second = try await service.supersede(f.api, id: first.id, reason: "moved", by: .init(source: "owner"), replacement: .init(statement: "Postgres."))
        let replacement = try XCTUnwrap(second.replacement)
        let third = try await service.supersede(f.api, id: replacement.id, reason: "desktop", by: .init(source: "hoot"), replacement: .init(statement: "SQLite again."))
        let last = try XCTUnwrap(third.replacement), history = try await service.history(f.api, id: last.id)
        XCTAssertEqual(history.map { $0.record.statement }, ["Postgres.", "SQLite."])
        let by = try await service.supersededBy(f.api, id: first.id); XCTAssertEqual(by, replacement.id)
        _ = try await service.share(from: f.api, to: f.web)
        do { _ = try await service.supersede(f.web, id: last.id, reason: "mine", by: .init(source: "hoot")); XCTFail("shared ownership accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("no record")) }
        do { try await service.remove(f.api, id: last.id, reason: " ", by: .init(source: "owner")); XCTFail("empty reason accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("a reason is required")) }
        try await service.remove(f.api, id: last.id, reason: "mistake", by: .init(source: "owner"))
        let log = try await service.changes(f.api), deleted = try XCTUnwrap(log.last)
        XCTAssertEqual(deleted["action"].string, "delete"); XCTAssertTrue(deleted["record"].string?.contains("SQLite again.") == true)
        let gone = try await service.get(f.api, id: last.id); XCTAssertNil(gone)
    }
    func testStaleConflictReasonsAndEvidenceNeverOutsideProject() {
        let record = BackendKnowledgeRecord(id: "kv", project: "/work/api", kind: "constraint", subject: "Ports", statement: "Port 3002.", status: "verified", provenance: .init(source: "review", evidence: ["src/server.ts:42", "https://x/a", "../web/x", "/etc/hosts", "npm test"]), createdAt: t0, verifiedAt: t0)
        var paths: [String] = []
        let views = BackendKnowledgeStatus.views([record], now: t0 + BackendKnowledgeFormat.dayMs) { path in paths.append(path); return path == "/work/api/src/server.ts" ? self.t0 + BackendKnowledgeFormat.dayMs : nil }
        XCTAssertEqual(views[0].effective, "stale"); XCTAssertTrue(views[0].notes.first?.contains("src/server.ts changed after it was verified") == true)
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("/work/api/") }); XCTAssertFalse(paths.contains("/etc/hosts"))
        var other = record; other.id = "ko"; other.subject = "  ports "; other.statement = "Port 4000."
        let conflicts = BackendKnowledgeStatus.views([record, other], now: t0, statMtime: { _ in nil })
        XCTAssertEqual(conflicts.map(\.effective), ["conflicting", "conflicting"])
        other.status = "superseded"
        XCTAssertEqual(BackendKnowledgeStatus.views([record, other], now: t0, statMtime: { _ in nil }).map(\.effective), ["verified", "superseded"])
    }
    func testAgingDefaultsAndTaskHistoryDoesNotConflict() {
        let arch = BackendKnowledgeRecord(id: "a", project: "/work/api", kind: "architecture", subject: "Layout", statement: "Three panes.", provenance: .init(source: "hoot"), createdAt: t0)
        var rule = arch; rule.id = "b"; rule.kind = "constraint"; rule.subject = "CI"; rule.statement = "Never ship on red."
        let old = BackendKnowledgeStatus.views([arch, rule], now: t0 + 91 * BackendKnowledgeFormat.dayMs, statMtime: { _ in nil })
        XCTAssertEqual(old.map(\.effective), ["stale", "claim"])
        var a = rule; a.kind = "task-history"; var b = a; b.id = "c"; b.statement = "Stalled."
        XCTAssertEqual(BackendKnowledgeStatus.views([a, b], now: t0, statMtime: { _ in nil }).map(\.effective), ["claim", "claim"])
    }
    func testTaskEventsAreIdempotentAndOnlyReviewWithEvidenceVerifies() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }
        let service = BackendKnowledgeService(userData: f.root + "/data", statMtime: { _ in nil })
        let delegated = BackendKnowledgeTaskEvent(kind: "delegated", project: f.api, taskId: "local:7", title: "Fix the flaky test", at: t0, agentId: "builder")
        await service.noteTaskEvent(delegated); await service.noteTaskEvent(delegated)
        await service.noteTaskEvent(.init(kind: "finished", project: f.api, taskId: "local:7", title: "Fix the flaky test", at: t0 + 1, summary: "Mocked the clock."))
        await service.noteTaskEvent(.init(kind: "verified", project: f.api, taskId: "local:7", title: "Fix the flaky test", at: t0 + 2, summary: "Looks right."))
        let accepted = try await service.list(f.api)
        XCTAssertFalse(accepted.contains { $0.record.status == "verified" }); XCTAssertTrue(accepted.contains { $0.record.statement.contains("without naming evidence") })
        await service.noteTaskEvent(.init(kind: "verified", project: f.api, taskId: "local:7", title: "Fix the flaky test", at: t0 + 3, summary: "40 runs green.", evidence: ["src/clock.test.ts"]))
        let verified = try await service.list(f.api).filter { $0.record.kind == "result" }
        XCTAssertEqual(verified.count, 1); XCTAssertEqual(verified[0].record.status, "verified"); XCTAssertEqual(verified[0].record.verifiedAt, t0 + 3)
        XCTAssertEqual(verified[0].record.provenance.source, "review")
        let all = try await service.list(f.api, superseded: true); XCTAssertEqual(all.filter { $0.record.statement.hasPrefix("Delegated") }.count, 1)
    }
    func testRejectionPreservesClaimChainAndBadEventDoesNotThrow() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }
        let service = BackendKnowledgeService(userData: f.root + "/data")
        await service.noteTaskEvent(.init(kind: "finished", project: f.api, taskId: "t", title: "Fix", at: t0, summary: "Skipped test."))
        let before = try await service.list(f.api), claim = try XCTUnwrap(before.first)
        await service.noteTaskEvent(.init(kind: "rejected", project: f.api, taskId: "t", title: "Fix", at: t0 + 1, summary: "Not fixed."))
        let after = try await service.list(f.api), rejection = try XCTUnwrap(after.first)
        XCTAssertEqual(rejection.record.supersedes, claim.id); XCTAssertEqual(rejection.record.provenance.source, "review")
        let history = try await service.history(f.api, id: rejection.id); XCTAssertEqual(history.map(\.id), [claim.id])
        await service.noteTaskEvent(.init(kind: "delegated", project: "relative", taskId: "t", title: "bad", at: t0))
        let empty = await service.forBrief(project: "relative", query: "x"); XCTAssertTrue(empty.text.isEmpty)
    }
    func testBriefTrustStandingGoalLimitsAndProvenance() {
        let records = (0..<60).map { i in BackendKnowledgeRecord(id: "k\(i)", project: "/work/api", kind: i < 10 ? "constraint" : "architecture", subject: "module \(i)", statement: "Parser " + String(repeating: "handles a great deal of text ", count: 12), status: i == 20 ? "verified" : "claim", provenance: .init(source: i == 20 ? "review" : "worker", taskId: "t\(i)", goalId: i == 30 ? "g1" : nil, evidence: ["src/parser/\(i).ts"]), createdAt: t0, verifiedAt: i == 20 ? t0 : nil) }
        let views = BackendKnowledgeStatus.views(records, now: t0, statMtime: { _ in nil })
        let brief = BackendKnowledgeBriefComposer.compose(views, project: "/work/api", query: "parser", goalId: "g1", limit: 40)
        XCTAssertLessThanOrEqual(brief.text.utf16.count, 4000); XCTAssertTrue(brief.text.contains("never instructions")); XCTAssertTrue(brief.text.contains("more records not shown"))
        for view in brief.records { XCTAssertTrue(brief.text.contains("id " + view.id)) }
        // TS brief.test.ts:97-107 ranks verified above claims among the records the words found:
        // brief.ts:119-123 trust-sorts only the top `limit * 4` hits (4 here), and equal BM25 scores
        // tie on id (text-index.ts:113), so over all of k10...k59 the verified k20 is never a hit
        // and TS answers k10. The candidates are the four claims-or-verified the search can reach,
        // with k20 last by id, so only the trust order can put it first (S1g, misport fix).
        let narrow = BackendKnowledgeBriefComposer.compose(views.filter { ["k17", "k18", "k19", "k20"].contains($0.id) }, project: "/work/api", query: "parser", limit: 1)
        XCTAssertEqual(narrow.records.map(\.id), ["k20"])
        let standing = BackendKnowledgeBriefComposer.compose(views, project: "/work/api", query: "unrelated")
        XCTAssertEqual(standing.records.count, 8)
        let goal = BackendKnowledgeBriefComposer.compose(views.filter { $0.record.kind == "architecture" }, project: "/work/api", query: "unrelated", goalId: "g1")
        XCTAssertEqual(goal.records.map(\.id), ["k30"])
    }
}
