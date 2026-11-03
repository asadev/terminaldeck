import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Exercises the production scanner after AIR writes, rather than a scanner
/// stub which could award a passing result for an unfinished document.
final class AIRReadinessScannerTests: XCTestCase {
    func testCreatingInstructionsStillNeedsProjectDetails() async throws {
        let fixture = try await AIRScannerFixture.make()
        defer { fixture.remove() }
        let initial = try await fixture.air.listChecks(project: fixture.project.path, context: fixture.context)
        XCTAssertEqual(initial.checks.first { $0.id == "claude-md" }?.status, .fail)
        let preview = try await fixture.air.previewFix(project: fixture.project.path, checkID: "claude-md", context: fixture.context)
        let outcome = try await fixture.air.fixApproved(previewID: preview.id, context: fixture.context)
        XCTAssertTrue(outcome.result.ok)
        XCTAssertEqual(outcome.report.checks.first { $0.id == "claude-md" }?.status, .warn)
        XCTAssertFalse(AIRReadinessProgress(report: outcome.report).ready)
        let next = try await fixture.air.explain(project: fixture.project.path, checkID: "claude-md", context: fixture.context)
        XCTAssertFalse(next.automaticFixAvailable)
        XCTAssertFalse(next.aiPrompt.isEmpty)
        XCTAssertTrue(next.steps.contains { $0.localizedCaseInsensitiveContains("command") })
    }

    func testIgnoringSecretsPreservesFileAndScannerConfirmsCoverage() async throws {
        let fixture = try await AIRScannerFixture.make()
        defer { fixture.remove() }
        let original = "# Keep this rule\nlocal-cache/"
        try Data(original.utf8).write(to: fixture.project.appendingPathComponent(".gitignore"))
        try Data("AIR test secret value".utf8).write(to: fixture.project.appendingPathComponent(".env"))
        let preview = try await fixture.air.previewFix(project: fixture.project.path, checkID: "secrets", context: fixture.context)
        XCTAssertFalse(AIRReadinessWire.wire(preview).compact.contains("AIR test secret value"))
        let outcome = try await fixture.air.fixApproved(previewID: preview.id, context: fixture.context)
        XCTAssertTrue(outcome.result.ok)
        let saved = try String(contentsOf: fixture.project.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertTrue(saved.hasPrefix(original))
        XCTAssertEqual(outcome.report.checks.first { $0.id == "secrets" }?.status, .pass)
        XCTAssertEqual(try String(contentsOf: fixture.project.appendingPathComponent(".env"), encoding: .utf8), "AIR test secret value")
    }

    func testRealScanPlansCoverEveryGapAndEachAgentVariant() async throws {
        let fixture = try await AIRScannerFixture.make()
        defer { fixture.remove() }
        let report = try await fixture.air.listChecks(project: fixture.project.path, context: fixture.context)
        XCTAssertEqual(report.checks.count, 10)
        for agent in [nil, "claude", "codex", "gemini"] as [String?] {
            let checks = ReadinessRules.view(of: report, agent: agent).checks.filter { $0.status != .pass }
            let checkIDs = Set(checks.map(\.id))
            let plans = AIRReadinessActions.plans(for: report, agent: agent).filter { checkIDs.contains($0.checkID) }
            XCTAssertEqual(Set(plans.map(\.checkID)), Set(checks.map(\.id)))
            for plan in plans {
                XCTAssertFalse(plan.missingAndWhy.isEmpty)
                XCTAssertFalse(plan.steps.isEmpty)
                XCTAssertTrue(plan.aiPrompt.contains(fixture.project.path))
            }
        }
    }

    func testSecretIgnoreFixRepairsALaterNegation() async throws {
        let fixture = try await AIRScannerFixture.make()
        defer { fixture.remove() }
        let original = ".env\n!.env\n"
        try Data(original.utf8).write(to: fixture.project.appendingPathComponent(".gitignore"))
        try Data("AIR test value".utf8).write(to: fixture.project.appendingPathComponent(".env"))
        let preview = try await fixture.air.previewFix(project: fixture.project.path, checkID: "secrets", context: fixture.context)
        let outcome = try await fixture.air.fixApproved(previewID: preview.id, context: fixture.context)
        XCTAssertTrue(outcome.result.ok)
        XCTAssertEqual(outcome.report.checks.first { $0.id == "secrets" }?.status, .pass)
        XCTAssertTrue(try String(contentsOf: fixture.project.appendingPathComponent(".gitignore"), encoding: .utf8).hasPrefix(original))
    }

    func testInstalledProjectToolsSupplyExactManualScriptDirections() async throws {
        let fixture = try await AIRScannerFixture.make()
        defer { fixture.remove() }
        let contents = #"{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"},"devDependencies":{"vitest":"1","typescript":"1","eslint":"1"}}"#
        let manifest = fixture.project.appendingPathComponent("package.json")
        try Data(contents.utf8).write(to: manifest)
        let report = try await fixture.air.listChecks(project: fixture.project.path, context: fixture.context)
        for (id, command) in [("test-script", "vitest run"), ("typecheck-script", "tsc --noEmit"), ("lint-script", "eslint .")] {
            let check = try XCTUnwrap(report.checks.first { $0.id == id })
            let plan = AIRReadinessActions.plan(for: check, projectPath: fixture.project.path)
            XCTAssertFalse(plan.automaticFixAvailable)
            XCTAssertTrue(plan.aiPrompt.contains(command))
            do {
                _ = try await fixture.air.previewFix(project: fixture.project.path, checkID: id, context: fixture.context)
                XCTFail("A manual script edit must not supply an automatic fix preview")
            } catch let error as NativeRPCError { XCTAssertEqual(error.code, "fix-unavailable") }
        }
        XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8), contents)
    }
}

private struct AIRScannerFixture: Sendable {
    let root: URL
    let project: URL
    let context: NativeRPCContext
    let air: BackendAIRReadinessService

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIR-scanner-" + UUID().uuidString)
        let project = root.appendingPathComponent("sample")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        do {
            let store = NativeStateStore()
            _ = try await store.addProject(project.path)
            let context = NativeRPCContext(caller: .nativeApp, ownerID: "AIR-scanner-test")
            let authority = BackendFilesystemAuthority { _ in .init(readRoots: [project], writeRoots: [project]) }
            let files = BackendFilesystemService(authority: authority)
            let projects = try BackendProjectService(store: store, files: files, home: root.path,
                appDataRoot: root.appendingPathComponent("isolated-store"), liveSessions: { [] })
            let gitRunner = BackendGitRunner(inheritedEnvironment: [:], loginPath: { "/usr/bin:/bin" })
            let git = BackendGitService(authority: authority, runner: gitRunner)
            let providers = try BackendNativeProviders(store: store, dataRoot: root.appendingPathComponent("isolated-store"),
                inheritedEnvironment: [:], home: root.path, runner: BackendCommandRunner(), loginPath: { "/usr/bin:/bin" })
            let tools = BackendReadinessTools(providers: providers, executor: BackendDevProcessExecutor(), authority: authority,
                inheritedEnvironment: [:], home: root.path)
            let scanner = BackendReadinessService(projects: projects, git: git, tools: tools,
                appName: "AIR scanner test", authorizeMutation: { _ in })
            let air = BackendAIRReadinessService(readiness: scanner, projects: projects,
                callerIdentity: { $0.ownerID }, approve: { _, _ in }, authorizeMutation: { _ in })
            return Self(root: root, project: project, context: context, air: air)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
