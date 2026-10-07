import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private final class BackendKnowledgeParityClock: @unchecked Sendable {
    private let lock = NSLock(); private var instant: Double, seed = 0
    private var failures: [(String, String)] = []
    init(_ instant: Double) { self.instant = instant }
    func now() -> Double { lock.withLock { instant } }
    func set(_ value: Double) { lock.withLock { instant = value } }
    func newID() -> String { lock.withLock { let value = "k\(seed)"; seed += 1; return value } }
    func failed(_ error: String, _ what: String) { lock.withLock { failures.append((error, what)) } }
    var errors: [String] { lock.withLock { failures.map(\.0) } }
}
private actor BackendKnowledgeParityConsent {
    var answer = false; private(set) var questions: [BackendKnowledgeShareRequest] = []
    func set(_ value: Bool) { answer = value }
    func ask(_ request: BackendKnowledgeShareRequest) -> Bool { questions.append(request); return answer }
}
private struct BackendKnowledgeParityAuthority: BackendKnowledgeToolAuthority {
    let identity: BackendKnowledgeToolCaller; let projects: Set<String>
    func caller(_ context: BackendMCPCallContext) async throws -> BackendKnowledgeToolCaller { identity }
    func requireKnownFolder(_ project: String) async throws -> String {
        guard projects.contains(project) else { throw NativeRPCError(code: "not-permitted", message: "\(project) is not a folder this app has open. Use projects.list to see the folders you can ask about.") }; return project
    }
    func authorize(_ context: BackendMCPCallContext, tool: String, arguments: NativeRPCValue, tier: BackendMCPTier) async throws {}
}
@MainActor final class BackendKnowledgeParityTests: XCTestCase {
    private let t0 = BackendKnowledgeFormat.time("2026-10-01T12:00:00Z")!, day = BackendKnowledgeFormat.dayMs
    private func temp() throws -> (root: String, api: String, web: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("td-knowledge-parity-" + UUID().uuidString)
        for name in ["api", "web"] { try FileManager.default.createDirectory(at: url.appendingPathComponent(name), withIntermediateDirectories: true) }
        let root = try BackendFilesystemAuthority.canonical(url).path; return (root, root + "/api", root + "/web")
    }
    private func make(_ root: String, clock: BackendKnowledgeParityClock, consent: BackendKnowledgeParityConsent? = nil) -> BackendKnowledgeService {
        let ask: (@Sendable (BackendKnowledgeShareRequest) async throws -> Bool)?
        if let consent { ask = { request in await consent.ask(request) } } else { ask = nil }
        return BackendKnowledgeService(userData: root + "/data", now: { clock.now() }, consent: ask, statMtime: { _ in nil }, newID: { clock.newID() }, onError: { clock.failed($0, $1) })
    }
    private func claim(_ subject: String, _ statement: String, kind: String = "decision", source: String = "hoot", stale: Double? = nil) -> BackendKnowledgeClaim {
        .init(kind: kind, subject: subject, statement: statement, provenance: .init(source: source), staleAfterMs: stale)
    }
    private func context(_ id: String = "w1", machine: String = "") -> BackendMCPCallContext { .init(sessionID: id, machineID: machine, projectRoot: nil, attended: true, allowedTools: [], allowedTiers: [.read, .act], cancellation: .init()) }
    private func meta(_ id: String, cwd: String) throws -> BackendSessionMeta {
        let value = BackendMemoryParsing.object([("id", .string(id)), ("cwd", .string(cwd)), ("title", .string("Fixture")), ("provider", .string("claude")), ("exitCode", .null), ("createdAt", .number(1)), ("resumed", .bool(false)), ("agentSessionId", .string("conv-" + id))])
        return try JSONDecoder().decode(BackendSessionMeta.self, from: value.encodedJSON())
    }
    private func args(_ project: String, kind: String = "decision", subject: String = "s", statement: String = "x") -> NativeRPCValue { BackendMemoryParsing.object([("project", .string(project)), ("kind", .string(kind)), ("subject", .string(subject)), ("statement", .string(statement))]) }
    private func refusal(_ tool: String, args: NativeRPCValue, authority: BackendKnowledgeParityAuthority, service: BackendKnowledgeService?, context: BackendMCPCallContext? = nil) async -> String {
        do { _ = try await BackendKnowledgeMCP.call(tool: tool, args: args, context: context ?? self.context(), service: service, authority: authority); XCTFail("Expected refusal"); return "" }
        catch { return error.localizedDescription }
    }
    func testSharedFrontKeysOrderTimestampEvidenceAndStatementBody() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let clock = BackendKnowledgeParityClock(t0), book = make(f.root, clock: clock)
        let view = try await book.record(f.api, input: .init(kind: "architecture", subject: "Renderer", statement: "React with one store.\nNo Redux.", provenance: .init(source: "owner", taskId: "t1", goalId: "g1", evidence: [f.api + "/src/store.ts", "npm test, all green"]), staleAfterMs: 3 * day))
        let dir = try await book.dirOf(f.api), text = try BackendMemoryFiles.text(dir + "/" + view.id + ".md"), front = BackendMemoryParsing.frontMatter(text)
        XCTAssertTrue(Set(front.keys).isSubset(of: Set(BackendKnowledgeFormat.keys)))
        XCTAssertEqual(front["id"], view.id); XCTAssertEqual(front["kind"], "architecture"); XCTAssertEqual(front["subject"], "Renderer"); XCTAssertEqual(front["status"], "claim"); XCTAssertEqual(front["source"], "owner")
        XCTAssertEqual(front["goal"], "g1"); XCTAssertEqual(front["task"], "t1"); XCTAssertEqual(front["evidence"], "src/store.ts, npm test; all green")
        XCTAssertEqual(front["stale-after-days"], "3"); XCTAssertEqual(front["created"], "2026-10-01T12:00:00.000Z")
        XCTAssertEqual(BackendMemoryParsing.trim(BackendMemoryParsing.bodyOf(text)), "React with one store.\nNo Redux.")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir).contains { $0.hasSuffix(".tmp") })
    }
    func testPublicRecordCannotMintVerifiedEvenForResultAndWorkerProvenance() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let book = make(f.root, clock: .init(t0))
        let view = try await book.record(f.api, input: claim("s", "done", kind: "result", source: "worker"))
        XCTAssertEqual(view.record.status, "claim"); XCTAssertNil(view.record.verifiedAt)
        let dir = try await book.dirOf(f.api), text = try BackendMemoryFiles.text(dir + "/" + view.id + ".md")
        XCTAssertEqual(BackendMemoryParsing.frontMatter(text)["status"], "claim")
    }
    func testShareQuestionsOneWayOnlyOnceAndUnshareNeverAsks() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let consent = BackendKnowledgeParityConsent(), book = make(f.root, clock: .init(t0), consent: consent)
        let a = try await book.record(f.api, input: claim("Database", "SQLite."))
        let no = try await book.share(from: f.api, to: f.web); XCTAssertFalse(no)
        let before = try await book.list(f.web, shared: true); XCTAssertTrue(before.isEmpty)
        await consent.set(true); let yes = try await book.share(from: f.api, to: f.web); XCTAssertTrue(yes)
        let questions = await consent.questions; XCTAssertEqual(questions.count, 2)
        for q in questions { XCTAssertEqual(q.from, f.api); XCTAssertEqual(q.to, f.web); XCTAssertEqual(q.records, 1) }
        let views = try await book.list(f.web, shared: true); XCTAssertEqual(views.map(\.id), [a.id]); XCTAssertEqual(views.map(\.project), [f.api])
        let own = try await book.list(f.web); XCTAssertTrue(own.isEmpty)
        _ = try await book.record(f.web, input: claim("Framework", "Next.js."))
        let backwards = try await book.list(f.api, shared: true); XCTAssertEqual(backwards.map { $0.record.subject }, ["Database"])
        _ = try await book.share(from: f.api, to: f.web); let once = await consent.questions; XCTAssertEqual(once.count, 2)
        let logs = try await book.changes(f.api); XCTAssertEqual(logs.map { $0["action"].string }, ["share"])
        let narrowed = try await book.unshare(from: f.api, to: f.web); XCTAssertTrue(narrowed)
        let still = await consent.questions; XCTAssertEqual(still.count, 2)
        let absent = try await book.list(f.web, shared: true); XCTAssertEqual(absent.map { $0.record.subject }, ["Framework"])
        let twice = try await book.unshare(from: f.api, to: f.web); XCTAssertFalse(twice)
    }
    func testCompleteSupersedeChainReasonLogAndWithdrawRefusal() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let clock = BackendKnowledgeParityClock(t0), book = make(f.root, clock: clock)
        let first = try await book.record(f.api, input: claim("Database", "SQLite."))
        clock.set(t0 + 1000); let second = try await book.supersede(f.api, id: first.id, reason: "moved to Postgres", by: .init(source: "owner"), replacement: .init(statement: "Postgres.")), next = try XCTUnwrap(second.replacement)
        clock.set(t0 + 2000); let third = try await book.supersede(f.api, id: next.id, reason: "back to SQLite for the desktop build", by: .init(source: "hoot"), replacement: .init(statement: "SQLite again.", evidence: ["docs/db.md"])), last = try XCTUnwrap(third.replacement)
        XCTAssertEqual(last.record.supersedes, next.id); XCTAssertEqual(last.record.subject, "Database"); XCTAssertEqual(last.record.kind, "decision"); XCTAssertEqual(last.record.status, "claim")
        let history = try await book.history(f.api, id: last.id); XCTAssertEqual(history.map { $0.record.statement }, ["Postgres.", "SQLite."])
        let live = try await book.list(f.api); XCTAssertEqual(live.map(\.id), [last.id])
        let full = try await book.list(f.api, superseded: true); XCTAssertEqual(full.map(\.effective), ["claim", "superseded", "superseded"])
        let changes = try await book.changes(f.api); XCTAssertEqual(changes.map { $0["reason"].string }, ["moved to Postgres", "back to SQLite for the desktop build"])
        let withdrawn = try await book.supersede(f.api, id: last.id, reason: "no longer true", by: .init(source: "hoot")); XCTAssertNil(withdrawn.replacement); XCTAssertEqual(withdrawn.superseded.effective, "superseded")
        do { _ = try await book.supersede(f.api, id: last.id, reason: "again", by: .init(source: "hoot")); XCTFail("Superseded twice") } catch { XCTAssertTrue(error.localizedDescription.contains("already superseded")) }
    }
    func testAgeFromVerificationAndExplicitPeriodAndConflictResolution() async throws {
        let project = "/fixture/api", record = BackendKnowledgeRecord(id: "kv", project: project, kind: "result", subject: "task 1", statement: "Builds.", status: "verified", provenance: .init(source: "review", evidence: ["npm run build"]), createdAt: t0 - 100 * day, verifiedAt: t0 - 10 * day)
        XCTAssertEqual(BackendKnowledgeStatus.views([record], now: t0, statMtime: { _ in nil })[0].effective, "verified")
        let aged = BackendKnowledgeStatus.views([record], now: t0 + 25 * day, statMtime: { _ in nil })[0]; XCTAssertEqual(aged.effective, "stale"); XCTAssertTrue(aged.notes[0].hasPrefix("verified 35 days ago"))
        let arch = BackendKnowledgeRecord(id: "ka", project: project, kind: "architecture", subject: "Layout", statement: "Three panes.", provenance: .init(source: "hoot"), createdAt: t0)
        let oldArchitecture = BackendKnowledgeStatus.views([arch], now: t0 + 91 * day, statMtime: { _ in nil })[0]; XCTAssertEqual(oldArchitecture.effective, "stale"); XCTAssertTrue(oldArchitecture.notes[0].contains("recorded 91 days ago (2026-10-01)"))
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let clock = BackendKnowledgeParityClock(t0), book = make(f.root, clock: clock)
        let a = try await book.record(f.api, input: claim("Database", "SQLite.")); clock.set(t0 + 1)
        let b = try await book.record(f.api, input: claim("  database ", "Postgres.", source: "worker"))
        let logging = try await book.record(f.api, input: claim("Logging", "pino.")); _ = try await book.record(f.api, input: claim("logging", "  pino. "))
        let av = try await book.get(f.api, id: a.id), bv = try await book.get(f.api, id: b.id), lv = try await book.get(f.api, id: logging.id)
        XCTAssertEqual(av?.effective, "conflicting"); XCTAssertTrue(av?.notes[0].contains("disagrees with " + b.id) == true); XCTAssertTrue(bv?.notes[0].contains("disagrees with " + a.id) == true); XCTAssertEqual(lv?.effective, "claim")
        _ = try await book.supersede(f.api, id: b.id, reason: "wrong", by: .init(source: "owner")); let resolved = try await book.get(f.api, id: a.id); XCTAssertEqual(resolved?.effective, "claim")
        let short = try await book.record(f.api, input: claim("Font", "Inter.", source: "owner", stale: 2 * day)); clock.set(t0 + 3 * day)
        let expired = try await book.get(f.api, id: short.id); XCTAssertEqual(expired?.effective, "stale")
    }
    func testSharedProjectsDoNotConflictAndTaskHistoryAccumulates() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let consent = BackendKnowledgeParityConsent(); await consent.set(true)
        let book = make(f.root, clock: .init(t0), consent: consent)
        _ = try await book.record(f.api, input: claim("Database", "SQLite.")); _ = try await book.record(f.web, input: claim("Database", "Postgres.")); _ = try await book.share(from: f.api, to: f.web)
        let views = try await book.list(f.web, shared: true); XCTAssertEqual(views.map(\.effective), ["claim", "claim"])
        for statement in ["Delegated.", "Stalled."] { _ = try await book.record(f.api, input: claim("task 1", statement, kind: "task-history", source: "task")) }
        let own = try await book.list(f.api).filter { $0.record.kind == "task-history" }; XCTAssertEqual(own.map(\.effective), ["claim", "claim"])
    }
    func testEveryHistoryEventKeepsExactStatementProvenanceAndOwnTime() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let book = make(f.root, clock: .init(t0 + 99_999))
        for (kind, at, agent, summary) in [("delegated", t0, "builder", ""), ("reassigned", t0 + 1, "fixer", ""), ("stalled", t0 + 2, "builder", "Waiting on a CI runner.")] {
            await book.noteTaskEvent(.init(kind: kind, project: f.api, taskId: "local:7", title: "Fix the flaky test", at: at, goalId: "g1", agentId: agent, sessionId: "s1", summary: summary))
        }
        let views = try await book.list(f.api, superseded: true).sorted { $0.record.createdAt < $1.record.createdAt }
        XCTAssertEqual(views.map { $0.record.createdAt }, [t0, t0 + 1, t0 + 2]); XCTAssertEqual(views.map { $0.record.kind }, ["task-history", "task-history", "task-history"])
        XCTAssertEqual(views.map { $0.record.statement }, ["Delegated “Fix the flaky test” to builder.", "Reassigned “Fix the flaky test” to fixer.", "“Fix the flaky test” stalled. Waiting on a CI runner."])
        XCTAssertEqual(views[0].record.subject, "task local:7"); XCTAssertEqual(views[0].record.provenance, .init(source: "task", taskId: "local:7", goalId: "g1", agentId: "builder", sessionId: "s1"))
    }
    func testNewFinishedClaimReplacesOnlyOlderClaimAndDuplicateIsOnce() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let book = make(f.root, clock: .init(t0 + 99_999))
        await book.noteTaskEvent(.init(kind: "finished", project: f.api, taskId: "local:7", title: "Fix the flaky test", at: t0, summary: "Retried the network call."))
        let next = BackendKnowledgeTaskEvent(kind: "finished", project: f.api, taskId: "local:7", title: "Fix the flaky test", at: t0 + 5, summary: "Mocked the clock instead.")
        await book.noteTaskEvent(next); await book.noteTaskEvent(next)
        let live = try await book.list(f.api); XCTAssertEqual(live.count, 1); XCTAssertEqual(live[0].record.statement, "Fix the flaky test: Mocked the clock instead."); XCTAssertEqual(live[0].record.status, "claim"); XCTAssertEqual(live[0].record.provenance.source, "task")
        let all = try await book.list(f.api, superseded: true); XCTAssertEqual(all.filter { $0.effective == "superseded" }.count, 1)
    }
    func testReviewExactEvidenceTimeReplacementAndRejectionLog() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let book = make(f.root, clock: .init(t0 + 99_999))
        await book.noteTaskEvent(.init(kind: "finished", project: f.api, taskId: "local:7", title: "Fix the flaky test", at: t0, summary: "Mocked the clock."))
        let before = try await book.list(f.api), old = before[0]
        await book.noteTaskEvent(.init(kind: "verified", project: f.api, taskId: "local:7", title: "Fix the flaky test", at: t0 + 60_000, summary: "Mocked the clock; 40 runs green.", evidence: ["src/clock.test.ts", "npm test"]))
        let live = try await book.list(f.api), verified = live[0]
        XCTAssertEqual(live.count, 1); XCTAssertEqual(verified.record.status, "verified"); XCTAssertEqual(verified.effective, "verified"); XCTAssertEqual(verified.record.verifiedAt, t0 + 60_000); XCTAssertEqual(verified.record.supersedes, old.id)
        XCTAssertEqual(verified.record.statement, "Fix the flaky test: Mocked the clock; 40 runs green."); XCTAssertEqual(verified.record.provenance.evidence, ["src/clock.test.ts", "npm test"])
        let log = try await book.changes(f.api), retired = log.last!; XCTAssertEqual(retired["action"].string, "supersede"); XCTAssertEqual(retired["id"].string, old.id); XCTAssertEqual(retired["reason"].string, "verified by review"); XCTAssertEqual(retired["replacement"].string, verified.id)
        await book.noteTaskEvent(.init(kind: "finished", project: f.web, taskId: "local:8", title: "Fix the flaky test", at: t0, summary: "Skipped the test."))
        await book.noteTaskEvent(.init(kind: "rejected", project: f.web, taskId: "local:8", title: "Fix the flaky test", at: t0 + 1, summary: "Skipping is not a fix; the race is still there."))
        let rejected = try await book.list(f.web)[0]; XCTAssertEqual(rejected.record.statement, "Review rejected the result of “Fix the flaky test”: Skipping is not a fix; the race is still there."); XCTAssertEqual(rejected.record.provenance.source, "review")
        let rejectionLog = try await book.changes(f.web); XCTAssertEqual(rejectionLog.last?["reason"].string, "rejected by review: Skipping is not a fix; the race is still there.")
    }
    func testTaskErrorsAreReportedWithoutStoppingAndEmptyBriefRemainsHonest() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let clock = BackendKnowledgeParityClock(t0), book = make(f.root, clock: clock)
        await book.noteTaskEvent(.init(kind: "delegated", project: "relative/path", taskId: "local:7", title: "Fix", at: t0)); XCTAssertEqual(clock.errors.count, 1)
        let brief = await book.forBrief(project: "relative/path", query: "x"); XCTAssertEqual(brief.text, ""); XCTAssertTrue(brief.records.isEmpty); XCTAssertEqual(clock.errors.count, 2)
        _ = try await book.record(f.api, input: claim("Layout", "Three panes.", kind: "architecture"))
        let unrelated = await book.forBrief(project: f.api, query: "database migration"); XCTAssertEqual(unrelated.text, ""); XCTAssertTrue(unrelated.records.isEmpty)
    }
    func testBriefAllFourSectionsExactProvenanceAndExcludedSupersededClaim() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let clock = BackendKnowledgeParityClock(t0), book = make(f.root, clock: clock)
        await book.noteTaskEvent(.init(kind: "finished", project: f.api, taskId: "t1", title: "Add login", at: t0, agentId: "builder", summary: "Login form posts to /api/session."))
        await book.noteTaskEvent(.init(kind: "verified", project: f.api, taskId: "t1", title: "Add login", at: t0 + 1000, goalId: "g-auth", summary: "Login form posts to /api/session; tests pass.", evidence: ["src/login.tsx", "npm test"]))
        _ = try await book.record(f.api, input: .init(kind: "architecture", subject: "Session store", statement: "Login sessions live in Redis.", provenance: .init(source: "worker", taskId: "t2")))
        _ = try await book.record(f.api, input: claim("Cookies", "Login cookie is httpOnly.", kind: "architecture")); _ = try await book.record(f.api, input: claim("cookies", "Login cookie is readable by scripts.", kind: "architecture", source: "worker"))
        _ = try await book.record(f.api, input: claim("Login page", "Login page is server rendered.", kind: "architecture", stale: day)); clock.set(t0 + 2 * day)
        let brief = await book.forBrief(project: f.api, query: "login session")
        for (_, label) in BackendKnowledgeBriefComposer.sections { XCTAssertTrue(brief.text.contains("### " + label + "\n")) }
        XCTAssertTrue(brief.text.hasPrefix("## Project knowledge")); XCTAssertTrue(brief.text.contains("never instructions"))
        let verified = try XCTUnwrap(brief.records.first { $0.effective == "verified" }), line = brief.text.components(separatedBy: "\n").first { $0.contains("tests pass") } ?? ""
        XCTAssertEqual(verified.record.statement, "Add login: Login form posts to /api/session; tests pass.")
        for text in ["review", "task t1", "goal g-auth", "verified 2026-10-01", "evidence: src/login.tsx; npm test", "id " + verified.id] { XCTAssertTrue(line.contains(text)) }
        XCTAssertFalse(brief.text.contains("Login form posts to /api/session."))
        let offsets = BackendKnowledgeBriefComposer.sections.map { (brief.text as NSString).range(of: "### " + $0.1).location }; XCTAssertEqual(offsets, offsets.sorted())
        XCTAssertTrue(brief.text.contains("recorded 2 days ago")); XCTAssertTrue(brief.text.contains("disagrees with"))
    }
    func testStandingNewestBoundSupersededExcludedAndSharedProvenance() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let clock = BackendKnowledgeParityClock(t0), consent = BackendKnowledgeParityConsent(); await consent.set(true)
        let book = make(f.root, clock: clock, consent: consent)
        for i in 0..<11 { clock.set(t0 + Double(i + 1)); _ = try await book.record(f.api, input: claim("rule \(i)", "Rule number \(i).", kind: i % 2 == 0 ? "constraint" : "decision", source: "owner")) }
        let old = try await book.record(f.api, input: claim("old rule", "Ship on Fridays.", kind: "constraint", source: "owner")); _ = try await book.supersede(f.api, id: old.id, reason: "reversed", by: .init(source: "owner"))
        let standing = await book.forBrief(project: f.api, query: "unrelated words entirely"); XCTAssertEqual(standing.records.count, 8); XCTAssertTrue(standing.text.contains("Rule number 10.")); XCTAssertFalse(standing.text.contains("Ship on Fridays"))
        _ = try await book.record(f.web, input: claim("API style", "The web app calls REST endpoints only.", source: "owner"))
        let prior = await book.forBrief(project: f.api, query: "REST endpoints"); XCTAssertFalse(prior.text.contains("from web"))
        _ = try await book.share(from: f.web, to: f.api); let shared = await book.forBrief(project: f.api, query: "REST endpoints"); XCTAssertTrue(shared.text.contains("from web"))
    }
    func testBriefSameGoalFlowsThroughBookWithNoWordMatch() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let book = make(f.root, clock: .init(t0))
        _ = try await book.record(f.api, input: .init(kind: "goal", subject: "Auth", statement: "Everyone signs in with a passkey.", provenance: .init(source: "owner", goalId: "g-auth")))
        _ = try await book.record(f.api, input: .init(kind: "architecture", subject: "Other", statement: "Unrelated.", provenance: .init(source: "hoot", goalId: "g-other")))
        let brief = await book.forBrief(project: f.api, query: "button colour", goalId: "g-auth"); XCTAssertEqual(brief.records.map { $0.record.subject }, ["Auth"])
    }
    func testHootSharedSearchGetAndOwnedOnlySupersede() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let consent = BackendKnowledgeParityConsent(); await consent.set(true)
        let book = make(f.root, clock: .init(t0), consent: consent), local = BackendKnowledgeParityAuthority(identity: .init(kind: .local), projects: [f.api, f.web])
        let theirs = try await book.record(f.web, input: claim("REST", "REST only.", source: "owner")), searchArgs = BackendMemoryParsing.object([("project", .string(f.api)), ("query", .string("REST"))])
        let before = try await BackendKnowledgeMCP.call(tool: "knowledge.search", args: searchArgs, context: context(), service: book, authority: local); XCTAssertEqual(before["records"].elements?.count, 0)
        let getArgs = BackendMemoryParsing.object([("project", .string(f.api)), ("id", .string(theirs.id))])
        let missing = await refusal("knowledge.get", args: getArgs, authority: local, service: book); XCTAssertTrue(missing.contains("no record"))
        _ = try await book.share(from: f.web, to: f.api)
        let shared = try await BackendKnowledgeMCP.call(tool: "knowledge.search", args: searchArgs, context: context(), service: book, authority: local)
        XCTAssertEqual(shared["records"].elements?.first?["sharedFrom"].string, f.web); XCTAssertEqual(shared["sharedFrom"].elements?.compactMap(\.string), [f.web])
        let notMine = await refusal("knowledge.supersede", args: getArgs.setting("reason", .string("mine now")), authority: local, service: book); XCTAssertTrue(notMine.contains("no record"))
        for kind in ["result", "task-history"] {
            let why = await refusal("knowledge.record", args: args(f.api, kind: kind), authority: local, service: book); XCTAssertTrue(why.contains("kind must be one of"))
        }
    }
    func testMissingKnowledgeRefusesAfterCallerAndScopePrechecks() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }
        let local = BackendKnowledgeParityAuthority(identity: .init(kind: .local), projects: [f.api]), worker = BackendKnowledgeParityAuthority(identity: .init(kind: .session, session: try meta("w1", cwd: f.api)), projects: [f.api])
        for (tool, authority) in [("knowledge.search", local), ("knowledge.note", worker)] {
            let message = await refusal(tool, args: args(f.api), authority: authority, service: nil); XCTAssertEqual(message, "Project knowledge is not running on this computer right now.")
        }
        let other = await refusal("knowledge.search", args: args(f.api), authority: worker, service: nil); XCTAssertEqual(other, "knowledge.search is Hoot’s own tool.")
        let sneaky = await refusal("knowledge.note", args: args(f.api).setting("status", .string("verified")), authority: worker, service: nil); XCTAssertTrue(sneaky.contains("only a task’s review"))
    }
    func testWorkerOwnSessionScopeAndTaskScopeIgnoreNamedProject() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let book = make(f.root, clock: .init(t0))
        let worker = BackendKnowledgeParityAuthority(identity: .init(kind: .session, session: try meta("w1", cwd: f.api)), projects: [f.api, f.web])
        let note = try await BackendKnowledgeMCP.call(tool: "knowledge.note", args: args(f.web, subject: "Retries", statement: "Network calls retry three times.").setting("evidence", BackendMemoryParsing.strings([f.api + "/src/net.ts"])), context: context(), service: book, authority: worker)
        XCTAssertEqual(note["noted"]["status"].string, "claim"); let own = try await book.list(f.api); XCTAssertEqual(own[0].record.provenance, .init(source: "worker", sessionId: "w1", conversationId: "conv-w1", evidence: ["src/net.ts"]))
        let web = try await book.list(f.web); XCTAssertTrue(web.isEmpty)
        let task = BackendKnowledgeParityAuthority(identity: .init(kind: .session, session: try meta("w2", cwd: f.root + "/workspace"), task: .init(taskId: "local:9", project: f.web, agentId: "builder", goalId: "g1")), projects: [f.api, f.web])
        _ = try await BackendKnowledgeMCP.call(tool: "knowledge.note", args: args(f.api, kind: "architecture", subject: "Queue", statement: "Jobs go through one queue."), context: context("w2"), service: book, authority: task)
        let taskViews = try await book.list(f.web); XCTAssertEqual(taskViews[0].record.provenance, .init(source: "worker", taskId: "local:9", goalId: "g1", agentId: "builder", sessionId: "w2", conversationId: "conv-w2"))
    }
    func testEveryHootToolRefusesOtherCallersAndWorkerKindsCannotMintVerified() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(atPath: f.root) }; let book = make(f.root, clock: .init(t0))
        for kind in [BackendKnowledgeToolCaller.Kind.key, .remote, .session] { for tool in BackendKnowledgeMCP.localToolIDs {
            let authority = BackendKnowledgeParityAuthority(identity: .init(kind: kind), projects: [f.api]), input = args(f.api).setting("id", .string("k1")).setting("reason", .string("r"))
            let why = await refusal(tool, args: input, authority: authority, service: book); XCTAssertEqual(why, tool + " is Hoot’s own tool.")
        } }
        let worker = BackendKnowledgeParityAuthority(identity: .init(kind: .session, session: try meta("w1", cwd: f.api)), projects: [f.api])
        for sneak in [BackendMemoryParsing.object([("status", .string("verified"))]), BackendMemoryParsing.object([("verified", .bool(true))]), BackendMemoryParsing.object([("verifiedAt", .number(t0))])] {
            let why = await refusal("knowledge.note", args: args(f.api, statement: "Tests pass.").merging(sneak), authority: worker, service: book); XCTAssertTrue(why.contains("only a task’s review"))
        }
        let result = await refusal("knowledge.note", args: args(f.api, kind: "result", statement: "Verified."), authority: worker, service: book); XCTAssertTrue(result.contains("kind must be one of"))
        _ = try await BackendKnowledgeMCP.call(tool: "knowledge.note", args: args(f.api, statement: "Verified: tests pass."), context: context(), service: book, authority: worker)
        let views = try await book.list(f.api); XCTAssertEqual(views[0].record.status, "claim")
    }
    func testTaskStoreAdapterNilAgentOnlyAndConversationWithoutInventedGoal() throws {
        XCTAssertNil(BackendKnowledgeTaskScope.fromTask(nil))
        let value = BackendMemoryParsing.object([("id", .string("local:1")), ("keyId", .string("local")), ("externalTaskId", .string("1")), ("local", .bool(true)), ("project", .string("/fixture/api")), ("assignee", BackendMemoryParsing.object([("kind", .string("agent")), ("agentId", .string("builder")), ("identity", .string("builder"))])), ("conversationId", .string("c9")), ("goalId", .string("not-in-source-scope"))])
        let task = try BackendTaskRecord(value), scope = try XCTUnwrap(BackendKnowledgeTaskScope.fromTask(task))
        XCTAssertEqual(scope.taskId, "local:1"); XCTAssertEqual(scope.project, "/fixture/api"); XCTAssertEqual(scope.agentId, "builder"); XCTAssertEqual(scope.conversationId, "c9"); XCTAssertNil(scope.goalId)
        let person = try BackendTaskRecord(value.setting("assignee", BackendMemoryParsing.object([("kind", .string("person")), ("agentId", .string("must-not-copy"))])).setting("conversationId", .string("")))
        let narrowed = BackendKnowledgeTaskScope.fromTask(person); XCTAssertNil(narrowed?.agentId); XCTAssertNil(narrowed?.conversationId)
    }
}
