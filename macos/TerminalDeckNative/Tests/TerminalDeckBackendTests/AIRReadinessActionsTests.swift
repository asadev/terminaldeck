import XCTest
import TerminalDeckNativeCore

final class AIRReadinessActionsTests: XCTestCase {
    private let project = "/work/Example Project"
    private func check(_ id: String, status: ReadinessStatus = .fail, detail: String = "Missing setup.",
                       fix: String? = nil, touches: [String] = [], destructive: Bool = false,
                       opens: String? = nil) -> ReadinessCheck {
        .init(id: id, title: "Check \(id)", status: status, detail: detail,
              fix: fix.map { .init(id: $0, label: "Fix it", description: "Known scanner change.", touches: touches, destructive: destructive) },
              gate: id == "secrets", opens: opens)
    }

    func testEveryScannerFindingHasPlainExplanationOrderedStepsAndReadyPrompt() {
        XCTAssertEqual(AIRReadinessActions.scannerCheckIDs.count, 10)
        for id in AIRReadinessActions.scannerCheckIDs {
            let plan = AIRReadinessActions.plan(for: check(id), projectPath: project)
            XCTAssertEqual(plan.checkID, id)
            XCTAssertFalse(plan.missingAndWhy.isEmpty, id)
            XCTAssertGreaterThanOrEqual(plan.steps.count, 3, id)
            XCTAssertTrue(plan.aiPrompt.contains(NativeRPCValue.string(project).compact), id)
            XCTAssertTrue(plan.aiPrompt.contains("1. " + plan.steps[0]), id)
            XCTAssertTrue(plan.aiPrompt.contains("Re-check"), id)
            XCTAssertTrue(plan.aiPrompt.contains("readiness_recheck (readiness.recheck) with projectPath"), id)
            XCTAssertTrue(plan.aiPrompt.contains("Do not read or print secret values"), id)
        }
    }

    func testSevenOfferedLocalFileFixesRequirePreviewAndMatchTheirCheck() {
        let fixtures = [
            ("claude-md", "create-claude-md", "CLAUDE.md"),
            ("claude-md", "create-agents-md", "AGENTS.md"),
            ("claude-md", "create-gemini-md", "GEMINI.md"),
            ("readme", "create-readme", "README.md"),
            ("gitignore", "create-gitignore", ".gitignore"),
            ("gitignore", "patch-gitignore", ".gitignore"),
            ("secrets", "ignore-secrets", ".gitignore")
        ]
        XCTAssertEqual(Set(fixtures.map { $0.1 }), AIRReadinessActions.automaticFixIDs)
        for (checkID, fixID, path) in fixtures {
            let status: ReadinessStatus = fixID == "ignore-secrets" || fixID == "patch-gitignore" ? .warn : .fail
            let plan = AIRReadinessActions.plan(for: check(checkID, status: status, fix: fixID, touches: [path]), projectPath: project)
            XCTAssertTrue(plan.automaticFixAvailable, fixID)
            XCTAssertNil(plan.manualReason, fixID)
            XCTAssertTrue(plan.steps.joined().contains("preview"), fixID)
            XCTAssertTrue(plan.steps.joined().localizedCaseInsensitiveContains("approve"), fixID)
        }
    }

    func testProposalCannotBorrowAnotherCheckFixOrEditUnrelatedFiles() {
        XCTAssertFalse(AIRReadinessActions.canAutomaticallyFix(check("readme", fix: "create-gitignore", touches: [".gitignore"])))
        XCTAssertFalse(AIRReadinessActions.canAutomaticallyFix(check("gitignore", fix: "patch-gitignore", touches: ["../.gitignore"])))
        XCTAssertFalse(AIRReadinessActions.canAutomaticallyFix(check("gitignore", fix: "patch-gitignore", touches: [".gitignore", "package.json"])))
        XCTAssertFalse(AIRReadinessActions.canAutomaticallyFix(check("gitignore", fix: "patch-gitignore", touches: [".gitignore"], destructive: true)))
        XCTAssertFalse(AIRReadinessActions.canAutomaticallyFix(check("gitignore", fix: "future-write", touches: [".gitignore"])))
        XCTAssertFalse(AIRReadinessActions.canAutomaticallyFix(check("readme", status: .pass, fix: "create-readme", touches: ["README.md"])))
    }

    func testScriptsGitCredentialsAndInstallsStayManualWithUsefulNextSteps() {
        let fixtures = [
            ("test-script", "add-test-script"), ("test-script", "replace-test-script"),
            ("typecheck-script", "add-typecheck-script"), ("lint-script", "add-lint-script"),
            ("git-repo", "git-init"), ("secrets", "untrack-secrets"),
            ("lockfile", "create-lockfile"), ("agent-cli:gemini", "upgrade-agent-cli")
        ]
        for (id, fix) in fixtures {
            let plan = AIRReadinessActions.plan(for: check(id, fix: fix), projectPath: project)
            XCTAssertFalse(plan.automaticFixAvailable, fix)
            XCTAssertNotNil(plan.manualReason, fix)
            XCTAssertGreaterThanOrEqual(plan.steps.count, 3, fix)
            XCTAssertTrue(plan.aiPrompt.contains("Show the proposed changes before applying them"), fix)
        }
        let secrets = AIRReadinessActions.plan(for: check("secrets", fix: "untrack-secrets"), projectPath: project)
        XCTAssertTrue(secrets.steps.joined().contains("git rm --cached -- <file>"))
        XCTAssertTrue(secrets.steps.joined().contains("past commits"))
        XCTAssertTrue(secrets.steps.joined().contains("Rotate"))
    }

    func testAgentSpecificInstructionsAndScoreUseTheSameScopedFinding() {
        let base = check("claude-md", status: .pass)
        let files = [("claude", "CLAUDE.md", "create-claude-md"), ("codex", "AGENTS.md", "create-agents-md"), ("gemini", "GEMINI.md", "create-gemini-md")]
        let agents = files.map { agent, file, fix in
            ReadinessForAgent(agent: agent, label: agent, file: file,
                              check: check("claude-md", fix: fix, touches: [file]), score: 42, band: .weak)
        }
        let report = ReadinessReport(projectPath: project, score: 100, band: .strong,
                                     checks: [check("readme", status: .pass), base], agents: agents)
        for (agent, file, _) in files {
            let plan = AIRReadinessActions.plans(for: report, agent: agent).first { $0.checkID == "claude-md" }
            XCTAssertEqual(plan?.agent, agent)
            XCTAssertTrue(plan?.steps.joined().contains(file) == true)
            XCTAssertTrue(plan?.automaticFixAvailable == true)
            XCTAssertEqual(AIRReadinessProgress(report: report, agent: agent).score, 42)
            XCTAssertFalse(AIRReadinessProgress(report: report, agent: agent).ready)
        }
        XCTAssertFalse(AIRReadinessActions.canAutomaticallyFix(check("claude-md", fix: "create-claude-md", touches: ["CLAUDE.md"]), agent: "codex"))
        XCTAssertFalse(AIRReadinessActions.canAutomaticallyFix(check("claude-md", fix: "create-claude-md", touches: ["CLAUDE.md"]), agent: "unknown"))
    }

    func testUnavailableScanRemainsActionableWithoutPretendingItIsNotApplicable() {
        let finding = check("readme", status: .skip, detail: "This check could not run: README.md is not readable UTF8 text.",
                            fix: "create-readme", touches: ["README.md"])
        let plan = AIRReadinessActions.plan(for: finding, projectPath: project)
        XCTAssertTrue(AIRReadinessActions.isUnverified(finding))
        XCTAssertFalse(plan.automaticFixAvailable)
        XCTAssertTrue(plan.missingAndWhy.contains("unverified"))
        XCTAssertTrue(plan.steps[0].contains("README.md is not readable"))
        XCTAssertTrue(plan.steps.last?.contains("Re-check") == true)
    }

    func testReadyMeansAllApplicableChecksPassEvenWhenWeightedBandIsStrong() {
        let report = ReadinessReport(projectPath: project, score: 98, band: .strong,
                                     checks: [check("secrets", status: .pass), check("readme", status: .warn),
                                              check("typecheck-script", status: .skip, detail: "Not a TypeScript project.")])
        let progress = AIRReadinessProgress(report: report)
        XCTAssertEqual(progress.passing, 1)
        XCTAssertEqual(progress.applicable, 2)
        XCTAssertEqual(progress.remaining, 1)
        XCTAssertEqual(progress.skipped, 1)
        XCTAssertFalse(progress.ready)
        XCTAssertFalse(progress.label.hasPrefix("Ready"))
    }

    func testUnverifiedSkipsRemainInProgressAndPreventReady() {
        let report = ReadinessReport(projectPath: project, score: 100, band: .strong,
                                     checks: [check("secrets", status: .pass),
                                              check("readme", status: .skip, detail: "This check could not run: Access denied."),
                                              check("typecheck-script", status: .skip, detail: "Not a TypeScript project.")])
        let progress = AIRReadinessProgress(report: report)
        XCTAssertEqual(progress.applicable, 1)
        XCTAssertEqual(progress.remaining, 1)
        XCTAssertEqual(progress.skipped, 1)
        XCTAssertEqual(progress.unverified, 1)
        XCTAssertFalse(progress.ready)
        XCTAssertTrue(progress.label.contains("1 of 2 checks passing"))
        XCTAssertTrue(progress.label.contains("could not be checked"))
    }

    func testCompleteReportIsReadyButAnEmptyOrAllSkippedReportIsUnverified() {
        let report = ReadinessReport(projectPath: project, score: 100, band: .strong,
                                     checks: [check("secrets", status: .pass), check("readme", status: .pass)])
        XCTAssertTrue(AIRReadinessProgress(report: report).ready)
        XCTAssertEqual(AIRReadinessProgress(report: report).remaining, 0)
        XCTAssertFalse(AIRReadinessProgress(report: .init(score: 0, band: .atRisk, checks: [])).ready)
        XCTAssertFalse(AIRReadinessProgress(report: .init(score: 0, band: .atRisk, checks: [check("lockfile", status: .skip)])).ready)
    }

    func testLockfileStepsUseOnlyTheDetectedPackageManager() {
        let cargo = AIRReadinessActions.plan(for: check("lockfile", detail: "Cargo.toml exists without Cargo.lock."), projectPath: project)
        XCTAssertTrue(cargo.steps.joined().contains("cargo generate-lockfile"))
        let npm = AIRReadinessActions.plan(for: check("lockfile", detail: "No lockfile was found.", fix: "create-lockfile"), projectPath: project)
        XCTAssertTrue(npm.steps.joined().contains("npm install --package-lock-only --ignore-scripts"))
        let other = AIRReadinessActions.plan(for: check("lockfile", detail: "The declared package manager must create its own lockfile."), projectPath: project)
        XCTAssertTrue(other.steps.joined().contains("packageManager"))
        XCTAssertFalse(other.steps.joined().contains("cargo"))
        XCTAssertFalse(other.steps.joined().contains("npm install"))
    }

    func testPreviewWireRoundTripRetainsApprovalBindingAndExactFileChange() throws {
        let preview = AIRReadinessFixPreview(id: "preview-1", projectPath: project, checkID: "claude-md", agent: "codex",
                                             fixID: "create-agents-md", title: "Create AGENTS.md", summary: "Create the starter file.",
                                             changes: [.init(path: "AGENTS.md", after: "# AGENTS.md\n")],
                                             checkFingerprint: "digest-of-check", createdAt: "2026-10-08T00:00:00Z", expiresAt: "2026-10-08T00:05:00Z")
        XCTAssertEqual(AIRReadinessFixPreview(json: AIRReadinessWire.wire(preview).foundation), preview)
        let incomplete = AIRReadinessWire.wire(preview).removing("checkFingerprint")
        XCTAssertNil(AIRReadinessFixPreview(json: incomplete.foundation))
        let invalidChange = AIRReadinessWire.wire(preview).setting("changes", .array([.object([.init("path", .string("AGENTS.md"))])]))
        XCTAssertNil(AIRReadinessFixPreview(json: invalidChange.foundation))
    }

    func testWriteOutcomeDoesNotTurnCreatedDocumentationIntoReady() throws {
        let report = ReadinessReport(projectPath: project, score: 50, band: .weak,
                                     checks: [check("claude-md", status: .warn, detail: "AGENTS.md is still the unfilled skeleton.", opens: "AGENTS.md")], scannedAt: "2026-10-08T00:00:01Z")
        let outcome = AIRReadinessFixOutcome(result: .init(ok: true, message: "Created AGENTS.md.", changed: ["AGENTS.md"]), report: report)
        XCTAssertEqual(AIRReadinessFixOutcome(json: AIRReadinessWire.wire(outcome).foundation), outcome)
        XCTAssertFalse(AIRReadinessProgress(report: outcome.report).ready)
        let plan = AIRReadinessActions.plan(for: report.checks[0], projectPath: project, agent: "codex")
        XCTAssertFalse(plan.automaticFixAvailable)
        XCTAssertTrue(plan.steps.joined().contains("exact install, run, and test commands"))
        XCTAssertEqual(AIRReadinessActionPlan(json: AIRReadinessWire.wire(plan).foundation), plan)
        let progress = AIRReadinessProgress(report: report)
        XCTAssertEqual(AIRReadinessProgress(json: AIRReadinessWire.wire(progress).foundation), progress)
    }

    func testProgressDecoderRejectsReadyWhileChecksAreUnfinished() {
        let report = ReadinessReport(projectPath: project, score: 98, band: .strong,
                                     checks: [check("secrets", status: .pass), check("readme", status: .warn)])
        let progress = AIRReadinessWire.wire(AIRReadinessProgress(report: report))
        let misleading = progress.setting("ready", .bool(true)).setting("remaining", .number(0))
        XCTAssertNil(AIRReadinessProgress(json: misleading.foundation))
    }

    func testProgressDecoderAcceptsJSONNumbersButRejectsFractionalOrBooleanCounts() throws {
        let report = ReadinessReport(projectPath: project, score: 50, band: .weak,
            checks: [check("claude-md", status: .warn)])
        let progress = AIRReadinessProgress(report: report)
        let wire = AIRReadinessWire.wire(progress)
        let decodedJSON = try JSONSerialization.jsonObject(with: wire.encodedJSON())
        XCTAssertEqual(AIRReadinessProgress(json: decodedJSON), progress)
        XCTAssertNil(AIRReadinessProgress(json: wire.setting("passing", .number(0.5)).foundation))
        XCTAssertNil(AIRReadinessProgress(json: wire.setting("passing", .bool(false)).foundation))
    }
}
