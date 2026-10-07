import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRemoteServeMachinesTestsPanelsReadiness: XCTestCase {
    private let path = "/work/project"
    private func read(_ rig: BackendRemoteServeMachinesTestsPanelsReadinessRig, scope: String? = nil, cli: Bool = true) async throws -> NativeRPCValue {
        let panel = await rig.provider(cli: cli); return try await panel.read(.init(path: path, scope: scope, query: nil), .init(caller: .nativeApp, ownerID: "test"))
    }
    private func act(_ rig: BackendRemoteServeMachinesTestsPanelsReadinessRig, _ action: String, scope: String? = nil) async throws -> NativeRPCValue {
        let panel = await rig.provider(); let run = try XCTUnwrap(panel.act)
        return try await run(.init(panel: .init(path: path, scope: scope, query: nil), action: action, id: nil, fields: [:]), .init(caller: .nativeApp, ownerID: "test"))
    }
    private func row(_ payload: NativeRPCValue, _ id: String) throws -> NativeRPCValue { try XCTUnwrap(payload["rows"].elements?.first { $0["id"].string == id }) }
    private func first(_ payload: NativeRPCValue) throws -> NativeRPCValue { try XCTUnwrap(payload["rows"].elements?.first) }
    private typealias F = BackendRemoteServeMachinesTestsPanelsReadinessFixtures
    func testScoreBandAndWeightedApplicableCountLead() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsReadinessRig(F.report(score: 68, checks: [F.check("secrets", gate: true), F.check("readme"), F.check("git-repo"), F.check("lockfile", status: "fail"), F.check("lint-script", status: "skip")]))
        let payload = try await read(rig), summary = try first(payload)
        XCTAssertEqual(summary["title"].string, "AI readiness"); XCTAssertEqual(summary["value"].string, "68 out of 100"); XCTAssertEqual(summary["status"].string, "warn")
        XCTAssertTrue(summary["detail"].string?.contains("Workable") == true); XCTAssertTrue(summary["detail"].string?.contains("3 of 4 applicable checks passing, weighted") == true)
        XCTAssertTrue(summary["detail"].string?.contains("1 not applicable here") == true); XCTAssertEqual(payload["path"].string, path)
    }
    func testCappedScoreExplainsWhyAndTintsBad() async throws {
        let payload = try await read(.init(F.report(score: 39, band: "at-risk", cap: "No secrets committed")))
        XCTAssertTrue(try first(payload)["detail"].string?.contains("Score held at 39 by No secrets committed") == true); XCTAssertEqual(try first(payload)["status"].string, "bad")
    }
    func testStatusTintsAndSkippedUntintedWords() async throws {
        let payload = try await read(.init(F.report(checks: [F.check("secrets", gate: true), F.check("readme", status: "warn"), F.check("lockfile", status: "fail"), F.check("lint-script", status: "skip")])))
        XCTAssertEqual(try row(payload, "secrets")["status"].string, "ok"); XCTAssertEqual(try row(payload, "readme")["status"].string, "warn"); XCTAssertEqual(try row(payload, "lockfile")["status"].string, "bad")
        XCTAssertFalse(try row(payload, "lint-script").has("status")); XCTAssertEqual(try row(payload, "lint-script")["value"].string, "Not applicable"); XCTAssertEqual(try row(payload, "secrets")["value"].string, "Passing")
    }
    func testGatesLeadThenFailuresWarningsPassesAndSkips() async throws {
        let payload = try await read(.init(F.report(checks: [F.check("lint-script", status: "skip"), F.check("claude-md"), F.check("readme", status: "warn"), F.check("lockfile", status: "fail"), F.check("secrets", status: "warn", gate: true)])))
        XCTAssertEqual(payload["rows"].elements?.dropFirst().map { $0["id"].string }, ["secrets", "lockfile", "readme", "claude-md", "lint-script"])
        XCTAssertTrue(try row(payload, "secrets")["detail"].string?.contains("it caps the score") == true)
    }
    func testAgentScopesExistOnlyWhenGraded() async throws {
        let graded = try await read(.init(F.report(agents: [F.agent()])))
        XCTAssertEqual(graded["scopes"], .array([F.scope("project", "Project", true), F.scope("codex", "Codex CLI", false)]))
        let bare = try await read(.init()); XCTAssertFalse(bare.has("scopes"))
    }
    func testAgentScopeSwapsInstructionsAndScore() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsReadinessRig(F.report(checks: [F.check("secrets", gate: true), F.check("claude-md")], agents: [F.agent()]))
        let neutral = try await read(rig); XCTAssertEqual(try first(neutral)["value"].string, "70 out of 100"); XCTAssertEqual(try row(neutral, "claude-md")["value"].string, "Passing")
        let agent = try await read(rig, scope: "codex"); XCTAssertEqual(try first(agent)["value"].string, "20 out of 100"); XCTAssertTrue(try first(agent)["detail"].string?.contains("Graded for Codex CLI") == true)
        XCTAssertEqual(try row(agent, "claude-md")["value"].string, "Failing"); XCTAssertEqual(agent["scopes"].elements?.first { $0["id"].string == "codex" }?["on"].bool, true)
    }
    func testUnknownAgentScopeFallsBackToProject() async throws {
        let payload = try await read(.init(F.report(agents: [F.agent()])), scope: "an-agent-that-left-the-catalogue")
        XCTAssertEqual(try first(payload)["value"].string, "70 out of 100"); XCTAssertFalse(try first(payload)["detail"].string?.contains("Graded for") == true)
    }
    func testFixableRowOffersItsOwnFixAndUnfixableRowOffersNone() async throws {
        let payload = try await read(.init(F.report(checks: [F.check("readme", status: "fail", fix: F.readme), F.check("git-clean", status: "warn")])))
        XCTAssertEqual(try row(payload, "readme")["actions"], .array([F.action("create-readme", "Create the README")]))
        XCTAssertFalse(try row(payload, "git-clean").has("actions"))
    }
    func testDestructiveFixCarriesFullConfirmation() async throws {
        let payload = try await read(.init(F.report(checks: [F.check("secrets", status: "fail", fix: F.untrack, gate: true)])))
        XCTAssertEqual(try row(payload, "secrets")["actions"], .array([F.action("untrack-secrets", "Untrack and ignore").setting("kind", .string("destructive")).setting("confirm", F.untrack["description"])]))
    }
    func testFixTouchesAreOnTheRow() async throws {
        let payload = try await read(.init(F.report(checks: [F.check("secrets", status: "fail", fix: F.untrack, gate: true)])))
        XCTAssertTrue(try row(payload, "secrets")["detail"].string?.contains("Changes .gitignore, git index.") == true)
    }
    func testUnfixableFindingNamesItsFile() async throws {
        let payload = try await read(.init(F.report(checks: [F.check("readme", status: "warn", opens: "README.md")])))
        XCTAssertTrue(try row(payload, "readme")["detail"].string?.contains("README.md") == true); XCTAssertFalse(try row(payload, "readme").has("actions"))
    }
    func testScanAgainAlwaysOffered() async throws {
        let payload = try await read(.init()); XCTAssertEqual(payload["actions"], .array([F.action("scan", "Scan again")]))
    }
    func testFixRedrawReadsTheRepairedState() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsReadinessRig(F.report(score: 55, checks: [F.check("readme", status: "fail", fix: F.readme)]))
        await rig.afterFix(F.report(score: 78, checks: [F.check("readme")]), message: "Wrote the README. Fill in the placeholders.")
        let payload = try await act(rig, "create-readme"); let asked = await rig.asked
        XCTAssertEqual(asked, [[path, "create-readme"]]); XCTAssertEqual(payload["notice"].string, "Wrote the README. Fill in the placeholders.")
        XCTAssertEqual(try first(payload)["value"].string, "78 out of 100"); XCTAssertEqual(try row(payload, "readme")["value"].string, "Passing"); XCTAssertFalse(try row(payload, "readme").has("actions"))
    }
    func testFixKeepsChosenAgentScope() async throws {
        let payload = try await act(.init(F.report(agents: [F.agent()])), "create-agents-md", scope: "codex")
        XCTAssertEqual(try first(payload)["value"].string, "20 out of 100"); XCTAssertEqual(payload["scopes"].elements?.first { $0["id"].string == "codex" }?["on"].bool, true)
    }
    func testBothInstructionsFixesDispatch() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsReadinessRig(); await rig.afterFix(nil, message: "Written.")
        for id in ["create-agents-md", "create-gemini-md"] { let payload = try await act(rig, id); XCTAssertEqual(payload["notice"].string, "Written.") }
        let asked = await rig.asked; XCTAssertEqual(asked.map { $0[1] }, ["create-agents-md", "create-gemini-md"])
    }
    func testMachineFixHasEmptyPathAndProjectFixHasFolder() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsReadinessRig(); _ = try await act(rig, "upgrade-agent-cli"); _ = try await act(rig, "create-readme")
        let asked = await rig.asked; XCTAssertEqual(asked, [["", "upgrade-agent-cli"], [path, "create-readme"]])
    }
    func testScanAgainIsOneFreshScanAndNoFix() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsReadinessRig(), payload = try await act(rig, "scan")
        XCTAssertEqual(payload["notice"].string, "Scanned again."); let scans = await rig.scans, fixes = await rig.asked.count
        XCTAssertEqual(scans, 1); XCTAssertEqual(fixes, 0)
    }
    func testUnknownActionRefusesWithRedrawAndNoFix() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsReadinessRig(), payload = try await act(rig, "rm -rf")
        XCTAssertEqual(payload["notice"].string, "That is not an action this panel offers."); XCTAssertGreaterThan(payload["rows"].elements?.count ?? 0, 0)
        let fixes = await rig.asked.count; XCTAssertEqual(fixes, 0)
    }
    func testThrowingFixBecomesExactNoticeWithRows() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsReadinessRig(); await rig.fail(fix: "EACCES on .gitignore")
        let payload = try await act(rig, "ignore-secrets"); XCTAssertEqual(payload["notice"].string, "The fix could not be applied: EACCES on .gitignore"); XCTAssertGreaterThan(payload["rows"].elements?.count ?? 0, 0)
    }
    func testScannerFailureKeepsScanAgainAndEmptyRows() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsReadinessRig(); await rig.fail(scan: "ENOENT: no such folder")
        let payload = try await read(rig); XCTAssertTrue(payload["note"].string?.contains("This folder could not be scanned: ENOENT: no such folder") == true)
        XCTAssertEqual(payload["rows"], .array([])); XCTAssertEqual(payload["actions"], .array([F.action("scan", "Scan again")]))
    }
    func testMissingAgentProbeCostsOnlyItsOwnRows() async throws {
        let payload = try await read(.init(), cli: false)
        XCTAssertTrue(payload["note"].string?.contains("Agent CLI versions are not read on this host") == true); XCTAssertEqual(try row(payload, "secrets")["value"].string, "Passing")
        XCTAssertFalse(payload["rows"].elements?.contains { $0["id"].string?.hasPrefix("agent-cli") == true } == true)
    }
    func testStaleAgentVersionOffersUpgrade() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsReadinessRig(); await rig.versions([F.cli("some-agent", "0.32.1", "Upgrade it: `brew upgrade some-agent`.")])
        let payload = try await read(rig), cli = try row(payload, "agent-cli:some-agent")
        XCTAssertEqual(cli["title"].string, "some-agent is too old to sign in"); XCTAssertEqual(cli["value"].string, "0.32.1"); XCTAssertEqual(cli["status"].string, "warn")
        XCTAssertEqual(cli["actions"], .array([F.action("upgrade-agent-cli", "Upgrade it")])); XCTAssertFalse(payload.has("note"))
    }
    func testFailedAgentProbeIsNoteAndNoAgentRows() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsReadinessRig(); await rig.fail(cli: "the login shell would not answer")
        let payload = try await read(rig); XCTAssertTrue(payload["note"].string?.contains("Agent CLI versions could not be read: the login shell would not answer") == true)
        XCTAssertFalse(payload["rows"].elements?.contains { $0["id"].string?.hasPrefix("agent-cli") == true } == true)
    }
    func testCountWithoutSkippedClause() async throws { let actual = try await count(passing: 9, applicable: 10, skipped: 0); XCTAssertEqual(actual, "9 of 10 applicable checks passing, weighted.") }
    func testCountNamesSkippedRows() async throws { let actual = try await count(passing: 3, applicable: 4, skipped: 6); XCTAssertEqual(actual, "3 of 4 applicable checks passing, weighted · 6 not applicable here.") }
    func testCountUsesSingularCheck() async throws { let actual = try await count(passing: 1, applicable: 1, skipped: 9); XCTAssertTrue(actual.contains("1 of 1 applicable check passing")) }
    func testRowsUseTheActualCheckIDs() async throws {
        let ids = ["secrets", "readme", "lockfile"], payload = try await read(.init(F.report(checks: ids.map { F.check($0) })))
        for id in ids { XCTAssertEqual(try row(payload, id)["id"].string, id) }
    }
    func testDesktopAgentShapeSuppliesThePanelConsumerUnchanged() async throws {
        // Native desktop and panel seams both carry NativeRPCValue. Exercise
        // every shared field through the real projection, without a second type.
        let desktop = F.cli("claude --version", "1.0.60", "Update the Claude CLI to sign in from here.")
        let rig = BackendRemoteServeMachinesTestsPanelsReadinessRig(); await rig.versions([desktop])
        let payload = try await read(rig), row = try row(payload, "agent-cli:claude --version")
        XCTAssertEqual(row["title"].string, "claude --version is too old to sign in"); XCTAssertEqual(row["value"].string, "1.0.60")
        XCTAssertEqual(row["detail"].string, "Update the Claude CLI to sign in from here."); XCTAssertEqual(row["status"].string, "warn")
        let original = await rig.versionRows; XCTAssertEqual(original, [desktop])
    }
    private func count(passing: Int, applicable: Int, skipped: Int) async throws -> String {
        let checks = (0..<(applicable + skipped)).map { F.check("c\($0)", status: $0 < passing ? "pass" : $0 < applicable ? "fail" : "skip") }
        let payload = try await read(.init(F.report(checks: checks))); let detail = try XCTUnwrap(try first(payload)["detail"].string)
        return detail.components(separatedBy: " — ").dropFirst().joined(separator: " — ")
    }
}

private enum BackendRemoteServeMachinesTestsPanelsReadinessFixtures {
    static let weights: [String: Double] = ["secrets": 30, "claude-md": 18, "test-script": 14, "git-repo": 12, "gitignore": 10, "readme": 8, "typecheck-script": 8, "git-clean": 8, "lint-script": 6, "lockfile": 6]
    static let readme = fix("create-readme", "Create the README", "Writes a short README at the project root, with placeholders to fill in.", ["README.md"], false)
    static let untrack = fix("untrack-secrets", "Untrack and ignore", "Adds the secret patterns, then stops git following those files. They stay on your disk, and they remain in every past commit.", [".gitignore", "git index"], true)
    static func action(_ id: String, _ label: String) -> NativeRPCValue { .object([.init("id", .string(id)), .init("label", .string(label))]) }
    static func scope(_ id: String, _ label: String, _ on: Bool) -> NativeRPCValue { .object([.init("id", .string(id)), .init("label", .string(label)), .init("on", .bool(on))]) }
    static func fix(_ id: String, _ label: String, _ description: String, _ touches: [String], _ destructive: Bool) -> NativeRPCValue { .object([.init("id", .string(id)), .init("label", .string(label)), .init("description", .string(description)), .init("touches", .array(touches.map(NativeRPCValue.string))), .init("destructive", .bool(destructive))]) }
    static func check(_ id: String, status: String = "pass", fix: NativeRPCValue = .null, gate: Bool = false, opens: String? = nil) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("title", .string(id == "secrets" ? "No secrets committed" : id)), .init("status", .string(status)), .init("weight", .number(weights[id] ?? 1)), .init("detail", .string("What the scan found here.")), .init("fix", fix), .init("gate", .bool(gate)), .init("opens", opens.map(NativeRPCValue.string) ?? .null)])
    }
    static func report(score: Double = 70, band: String = "fair", cap: String? = nil, checks: [NativeRPCValue]? = nil, agents: [NativeRPCValue] = []) -> NativeRPCValue {
        .object([.init("projectPath", .string("/work/project")), .init("score", .number(score)), .init("band", .string(band)), .init("checks", .array(checks ?? [check("secrets", gate: true)])), .init("cappedBy", cap.map(NativeRPCValue.string) ?? .null), .init("agents", .array(agents)), .init("scannedAt", .string("2026-08-24T09:00:00.000Z"))])
    }
    static func agent() -> NativeRPCValue { .object([.init("agent", .string("codex")), .init("label", .string("Codex CLI")), .init("file", .string("AGENTS.md")), .init("check", check("claude-md", status: "fail")), .init("score", .number(20)), .init("band", .string("at-risk")), .init("cappedBy", .null)]) }
    static func cli(_ command: String, _ version: String, _ advice: String) -> NativeRPCValue { .object([.init("command", .string(command)), .init("version", .string(version)), .init("stale", .bool(true)), .init("advice", .string(advice))]) }
}
private struct BackendRemoteServeMachinesTestsPanelsReadinessError: LocalizedError, Sendable { let message: String; var errorDescription: String? { message } }
private actor BackendRemoteServeMachinesTestsPanelsReadinessRig {
    private var snapshot: NativeRPCValue, next: NativeRPCValue?, outcome = "Done."
    private var scanError: String?, fixError: String?, cliError: String?
    private(set) var versionRows: [NativeRPCValue] = [], asked: [[String]] = [], scans = 0
    init(_ snapshot: NativeRPCValue = BackendRemoteServeMachinesTestsPanelsReadinessFixtures.report()) { self.snapshot = snapshot }
    func afterFix(_ next: NativeRPCValue?, message: String) { self.next = next; outcome = message }
    func fail(scan: String? = nil, fix: String? = nil, cli: String? = nil) { scanError = scan; fixError = fix; cliError = cli }
    func versions(_ rows: [NativeRPCValue]) { versionRows = rows }
    func provider(cli: Bool = true) -> BackendRemotePanelProvider {
        BackendRemotePanelReadiness.provider(scan: { _, _ in try await self.scan() }, fix: { path, id, _ in try await self.fix(path, id) }, staleAgents: cli ? { @Sendable _ in try await self.stale() } : nil)
    }
    private func scan() throws -> NativeRPCValue { scans += 1; if let scanError { throw BackendRemoteServeMachinesTestsPanelsReadinessError(message: scanError) }; return snapshot }
    private func fix(_ path: String, _ id: String) throws -> NativeRPCValue { asked.append([path, id]); if let fixError { throw BackendRemoteServeMachinesTestsPanelsReadinessError(message: fixError) }; if let next { snapshot = next }; return .object([.init("ok", .bool(true)), .init("message", .string(outcome)), .init("changed", .array([]))]) }
    private func stale() throws -> [NativeRPCValue] { if let cliError { throw BackendRemoteServeMachinesTestsPanelsReadinessError(message: cliError) }; return versionRows }
}
