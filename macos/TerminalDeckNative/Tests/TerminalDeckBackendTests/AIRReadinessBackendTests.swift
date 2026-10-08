import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private final class AIRBackendBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}
private actor AIRBackendScanProbe {
    enum Kind: Sendable { case ignore, secret, readme, unsafe }
    let root: URL
    let kind: Kind
    var count = 0
    var beforeScan: (@Sendable (Int) async throws -> Void)?
    init(root: URL, kind: Kind) { self.root = root; self.kind = kind }
    func hook(_ action: @escaping @Sendable (Int) async throws -> Void) { beforeScan = action }
    func calls() -> Int { count }
    func scan(_ project: String, _ context: NativeRPCContext) async throws -> ReadinessReport {
        count += 1
        try await beforeScan?(count)
        let check: ReadinessCheck
        let ignore = root.appendingPathComponent(".gitignore")
        let content = (try? String(contentsOf: ignore, encoding: .utf8)) ?? ""
        switch kind {
        case .ignore:
            let present = FileManager.default.fileExists(atPath: ignore.path)
            check = .init(id: "gitignore", title: "Ignore rules", status: present ? .pass : .fail,
                detail: present ? "Rules found." : "No .gitignore was found.",
                fix: present ? nil : .init(id: "create-gitignore", label: "Create .gitignore", touches: [".gitignore"]))
        case .secret:
            let rules = BackendFilesystemIgnore(texts: [content])
            let ignored = rules.ignored(".env", directory: false)
            check = .init(id: "secrets", title: "Secrets", status: ignored ? .pass : .warn,
                detail: ignored ? "No secrets exposed." : ".env is present without ignore coverage.",
                fix: ignored ? nil : .init(id: "ignore-secrets", label: "Ignore secret files", touches: [".gitignore"]), gate: true)
        case .readme:
            let present = FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path)
            check = .init(id: "readme", title: "README", status: present ? .warn : .fail,
                detail: present ? "Fill in the placeholders." : "No README was found.",
                fix: present ? nil : .init(id: "create-readme", label: "Create README.md", touches: ["README.md"]))
        case .unsafe:
            check = .init(id: "lockfile", title: "Pinned dependencies", status: .warn,
                detail: "No lockfile was found.", fix: .init(id: "create-lockfile", label: "Create lockfile", touches: ["package-lock.json"]))
        }
        let instructions = ReadinessCheck(id: "claude-md", title: "Instructions", status: .pass, detail: "Instructions present.")
        return .init(projectPath: project, score: check.status == .pass ? 100 : 40, band: check.status == .pass ? .strong : .weak,
            checks: [check], agents: [ReadinessForAgent(agent: "codex", label: "Codex", file: "AGENTS.md", check: instructions, score: 40, band: .weak)], scannedAt: "scan-\(count)")
    }
}
private actor AIRBackendApprovalPause {
    private var entered = false
    private var enterWait: CheckedContinuation<Void, Never>?
    private var releaseWait: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; enterWait?.resume(); enterWait = nil
        await withCheckedContinuation { releaseWait = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enterWait = $0 }
    }
    func release() { releaseWait?.resume(); releaseWait = nil }
}

final class AIRReadinessBackendTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let root: URL
        let service: BackendAIRReadinessService
        let probe: AIRBackendScanProbe
        let grant: AIRBackendBox<Bool>
        let identity: AIRBackendBox<String>
        let clock: AIRBackendBox<Date>
        let approvals: AIRBackendBox<[AIRReadinessFixPreview]>
        let context: NativeRPCContext
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    private func fixture(_ kind: AIRBackendScanProbe.Kind = .ignore,
                         approve: (@Sendable (NativeRPCContext, AIRReadinessFixPreview) async throws -> Void)? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIR-scratch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NativeStateStore()
        _ = try await store.addProject(root.path)
        let grant = AIRBackendBox(true), identity = AIRBackendBox("native-test-owner")
        let clock = AIRBackendBox(Date(timeIntervalSince1970: 1_800_000_000))
        let approvals = AIRBackendBox<[AIRReadinessFixPreview]>([])
        let authority = BackendFilesystemAuthority { _ in
            BackendFilesystemScope(readRoots: grant.value ? [root] : [], writeRoots: grant.value ? [root] : [])
        }
        let projects = try BackendProjectService(store: store, files: BackendFilesystemService(authority: authority),
            home: root.path, appDataRoot: root.appendingPathComponent("app-state"), liveSessions: { [] })
        let probe = AIRBackendScanProbe(root: root, kind: kind)
        let service = BackendAIRReadinessService(projects: projects, scan: { try await probe.scan($0, $1) },
            callerIdentity: { context in context.ownerID == "other" ? "another-caller" : identity.value },
            approve: { context, preview in
                approvals.set(approvals.value + [preview])
                try await approve?(context, preview)
            }, authorizeMutation: { _ in
                guard grant.value else { throw NativeRPCError(code: "access-denied", message: "The grant was revoked.") }
            }, now: { clock.value })
        return .init(root: root, service: service, probe: probe, grant: grant, identity: identity, clock: clock,
            approvals: approvals, context: .init(caller: .nativeApp, ownerID: "test-owner"))
    }
    private func preview(_ f: Fixture, id: String = "gitignore", agent: String? = nil) async throws -> AIRReadinessFixPreview {
        try await f.service.previewFix(project: f.root.path, checkID: id, agent: agent, context: f.context)
    }
    private func expectCode(_ code: String, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected \(code)") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, code) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    func testExactPreviewDoesNotWriteAndApprovedFixIncludesFreshScan() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let p = try await preview(f)
        XCTAssertEqual(p.projectPath, f.root.path)
        XCTAssertEqual(p.changes.map(\.path), [".gitignore"])
        XCTAssertNil(p.changes[0].before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".gitignore").path))
        let outcome = try await f.service.fixApproved(previewID: p.id, context: f.context)
        XCTAssertTrue(outcome.result.ok)
        XCTAssertEqual(outcome.report.checks[0].status, .pass)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent(".gitignore"), encoding: .utf8), p.changes[0].after)
        XCTAssertEqual(f.approvals.value, [p])
        let count = await f.probe.calls()
        XCTAssertEqual(count, 4, "Preview, validation, post-approval validation and automatic recheck must all scan.")
    }
    func testDenialNeverWritesAndConsumesPreview() async throws {
        let f = try await fixture(approve: { _, _ in throw NativeRPCError(code: "approval-required", message: "Declined.") }); defer { f.cleanup() }
        let p = try await preview(f)
        await expectCode("approval-required") { _ = try await f.service.fixApproved(previewID: p.id, context: f.context) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".gitignore").path))
        await expectCode("stale-preview") { _ = try await f.service.fixApproved(previewID: p.id, context: f.context) }
    }
    func testChangedFileNeverGetsOverwritten() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let p = try await preview(f)
        let path = f.root.appendingPathComponent(".gitignore")
        try "# My new work\n".write(to: path, atomically: true, encoding: .utf8)
        await expectCode("stale-preview") { _ = try await f.service.fixApproved(previewID: p.id, context: f.context) }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "# My new work\n")
        XCTAssertTrue(f.approvals.value.isEmpty)
    }
    func testReplayAndDifferentCallerAreRefused() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let p = try await preview(f)
        let other = NativeRPCContext(caller: .nativeApp, ownerID: "other")
        await expectCode("stale-preview") { _ = try await f.service.pendingPreview(previewID: p.id, context: other) }
        await expectCode("stale-preview") { _ = try await f.service.fixApproved(previewID: p.id, context: other) }
        _ = try await f.service.fixApproved(previewID: p.id, context: f.context)
        await expectCode("stale-preview") { _ = try await f.service.fixApproved(previewID: p.id, context: f.context) }
        XCTAssertEqual(f.approvals.value.count, 1)
    }
    func testExpiredPreviewDoesNotAskOrWrite() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let p = try await preview(f)
        f.clock.set(f.clock.value.addingTimeInterval(301))
        await expectCode("stale-preview") { _ = try await f.service.fixApproved(previewID: p.id, context: f.context) }
        XCTAssertTrue(f.approvals.value.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".gitignore").path))
    }
    func testRevokedGrantAfterPreviewRefuses() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let p = try await preview(f)
        f.grant.set(false)
        await expectCode("access-denied") { _ = try await f.service.fixApproved(previewID: p.id, context: f.context) }
        XCTAssertTrue(f.approvals.value.isEmpty)
    }
    func testKnownAgentCanFixSharedCheckAndUnknownAgentCannot() async throws {
        let f = try await fixture(.readme); defer { f.cleanup() }
        let p = try await preview(f, id: "readme", agent: "codex")
        XCTAssertEqual(p.agent, "codex")
        let outcome = try await f.service.fixApproved(previewID: p.id, context: f.context)
        XCTAssertTrue(outcome.result.ok)
        XCTAssertEqual(outcome.report.checks[0].status, .warn, "A draft alone must not be reported as ready.")
        await expectCode("invalid-check") { _ = try await preview(f, id: "readme", agent: "unknown-agent") }
    }
    func testAppendPreviewShowsOnlyAddedLinesAndRepairsLastMatchNegation() async throws {
        let f = try await fixture(.secret); defer { f.cleanup() }
        let file = f.root.appendingPathComponent(".gitignore")
        let original = "# Private existing note TOKEN_VALUE=keep-private\n.env\n!.env\n.env.*\n!.env.example\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        try "DO_NOT_READ_SECRET_VALUE".write(to: f.root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let p = try await preview(f, id: "secrets")
        XCTAssertNil(p.changes[0].before)
        XCTAssertFalse(p.changes[0].after!.contains("keep-private"))
        XCTAssertFalse(p.changes[0].after!.contains("DO_NOT_READ_SECRET_VALUE"))
        XCTAssertEqual(p.changes[0].action, "Append these exact lines")
        let outcome = try await f.service.fixApproved(previewID: p.id, context: f.context)
        XCTAssertTrue(outcome.result.ok)
        let current = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(current, original + p.changes[0].after!)
        XCTAssertTrue(BackendFilesystemIgnore(texts: [current]).ignored(".env", directory: false))
        XCTAssertFalse(BackendFilesystemIgnore(texts: [current]).ignored(".env.example", directory: false))
        XCTAssertEqual(outcome.report.checks[0].status, .pass)
    }
    func testHardlinkedAndSymlinkedIgnoreFilesAreNotModified() async throws {
        let f = try await fixture(.secret); defer { f.cleanup() }
        let outside = f.root.appendingPathComponent("protected-file"), ignore = f.root.appendingPathComponent(".gitignore")
        try "protected\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: outside, to: ignore)
        await expectCode("fix-unavailable") { _ = try await preview(f, id: "secrets") }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "protected\n")
        try FileManager.default.removeItem(at: ignore)
        try FileManager.default.createSymbolicLink(at: ignore, withDestinationURL: outside)
        await expectCode("fix-unavailable") { _ = try await preview(f, id: "secrets") }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "protected\n")
    }
    func testUnsafeFixGetsExplanationAndPreviewRefuses() async throws {
        let f = try await fixture(.unsafe); defer { f.cleanup() }
        let plan = try await f.service.explain(project: f.root.path, checkID: "lockfile", context: f.context)
        XCTAssertFalse(plan.automaticFixAvailable)
        XCTAssertFalse(plan.steps.isEmpty)
        XCTAssertFalse(plan.aiPrompt.isEmpty)
        await expectCode("fix-unavailable") { _ = try await preview(f, id: "lockfile") }
        XCTAssertTrue(f.approvals.value.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("package-lock.json").path))
    }
    func testExpiryDuringPostApprovalScanDoesNotWrite() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let p = try await preview(f)
        await f.probe.hook { count in if count == 3 { f.clock.set(f.clock.value.addingTimeInterval(301)) } }
        await expectCode("stale-preview") { _ = try await f.service.fixApproved(previewID: p.id, context: f.context) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".gitignore").path))
    }
    func testCallerChangedDuringPostApprovalScanDoesNotWrite() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let p = try await preview(f)
        await f.probe.hook { count in if count == 3 { f.identity.set("different-current-owner") } }
        await expectCode("access-denied") { _ = try await f.service.fixApproved(previewID: p.id, context: f.context) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".gitignore").path))
    }
    func testLegacyFixChannelCannotBypassPreview() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        await expectCode("approval-required") {
            _ = try await f.service.invoke("readiness:fix", args: [.string(f.root.path), .string("create-gitignore"), .bool(true)], context: f.context)
        }
        XCTAssertTrue(f.approvals.value.isEmpty)
    }
    func testMCPFixRequiresAlterAndRejectsConsentFlagsBeforeApproval() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let p = try await preview(f)
        let access = BackendAIRReadinessToolAccess(rpcContext: { _ in f.context },
            knownFolder: { _, path in
                guard path == f.root.path else { throw NativeRPCError(code: "access-denied", message: "Wrong project.") }
                return path
            }, authorizeRead: { _, _, _ in }, noteResult: { _, _ in },
            authorizeLaunch: { _, _, _ in throw NativeRPCError(code: "unavailable", message: "No session launch in this scratch test.") },
            launchAI: { _, _, _ in throw NativeRPCError(code: "unavailable", message: "No session owner in this scratch test.") })
        let definitions = try BackendAIRReadinessTools.definitions(service: f.service, access: access)
        XCTAssertEqual(Set(definitions.map { $0.spec.id }), BackendAIRReadinessTools.toolIDs)
        let definition = try XCTUnwrap(definitions.first(where: { $0.spec.id == "readiness.fix" }))
        XCTAssertEqual(definition.spec.tier, .read, "The real alter effect must ask only after the exact preview is available.")
        let readOnly = BackendMCPCallContext(sessionID: "scratch-session", machineID: "", projectRoot: f.root.path,
            attended: true, allowedTools: BackendAIRReadinessTools.toolIDs, allowedTiers: [.read], cancellation: BackendMCPCancellation())
        let args: NativeRPCValue = .object([.init("previewId", .string(p.id))])
        let denied = try await definition.handler(readOnly, args)
        XCTAssertTrue(denied.isError)
        XCTAssertEqual(denied.structuredContent?["code"].string, "access-denied")
        let granted = BackendMCPCallContext(sessionID: "scratch-session", machineID: "", projectRoot: f.root.path,
            attended: true, allowedTools: BackendAIRReadinessTools.toolIDs, allowedTiers: [.read, .alter], cancellation: BackendMCPCancellation())
        let flags = try await definition.handler(granted, args.setting("approved", .bool(true)))
        XCTAssertTrue(flags.isError)
        XCTAssertEqual(flags.structuredContent?["code"].string, "invalid-arguments")
        XCTAssertTrue(f.approvals.value.isEmpty)
        let applied = try await definition.handler(granted, args)
        XCTAssertFalse(applied.isError)
        XCTAssertEqual(applied.structuredContent?["result"]["ok"].bool, true)
        XCTAssertEqual(f.approvals.value, [p], "The actual service approval must receive the exact preview.")
    }
    func testCancellationDuringApprovalDoesNotWriteAndConsumesPreview() async throws {
        let pause = AIRBackendApprovalPause()
        let f = try await fixture(approve: { _, _ in await pause.hold() }); defer { f.cleanup() }
        let p = try await preview(f)
        let work = Task { try await f.service.fixApproved(previewID: p.id, context: f.context) }
        await pause.waitUntilEntered()
        work.cancel()
        await pause.release()
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".gitignore").path))
        await expectCode("stale-preview") { _ = try await f.service.fixApproved(previewID: p.id, context: f.context) }
    }
    func testFileEditedWhileApprovalOpenKeepsConcurrentWork() async throws {
        let f = try await fixture(.secret, approve: { _, p in
            try "# concurrent work\n".write(to: URL(fileURLWithPath: p.projectPath).appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        }); defer { f.cleanup() }
        let path = f.root.appendingPathComponent(".gitignore")
        try "# original\n".write(to: path, atomically: true, encoding: .utf8)
        let p = try await preview(f, id: "secrets")
        await expectCode("stale-preview") { _ = try await f.service.fixApproved(previewID: p.id, context: f.context) }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "# concurrent work\n")
    }
    func testReplacedProjectFolderInvalidatesPreview() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let p = try await preview(f)
        // Move rather than remove so the OS cannot recycle the old inode.
        let saved = f.root.appendingPathExtension("original")
        try FileManager.default.moveItem(at: f.root, to: saved)
        defer { try? FileManager.default.removeItem(at: saved) }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        await expectCode("stale-preview") { _ = try await f.service.fixApproved(previewID: p.id, context: f.context) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".gitignore").path))
    }
    func testMCPAskAIPreparesOriginalCallAndExactPromptBeforeLaunch() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let prepared = AIRBackendBox<[NativeRPCValue]>([]), launchCount = AIRBackendBox(0)
        let access = BackendAIRReadinessToolAccess(rpcContext: { _ in f.context },
            knownFolder: { _, path in
                guard path == f.root.path else { throw NativeRPCError(code: "access-denied", message: "Wrong project.") }
                return path
            }, authorizeRead: { _, _, _ in }, noteResult: { _, _ in },
            authorizeLaunch: { _, original, request in
                prepared.set([original, request])
                throw NativeRPCError(code: "approval-required", message: "Declined exact launch.")
            }, launchAI: { _, _, _ in
                launchCount.set(launchCount.value + 1)
                throw NativeRPCError(code: "unavailable", message: "No live sessions are used by this test.")
            })
        let definition = try XCTUnwrap(BackendAIRReadinessTools.definitions(service: f.service, access: access).first(where: { $0.spec.id == "readiness.ask_ai" }))
        let caller = BackendMCPCallContext(sessionID: "scratch-session", machineID: "", projectRoot: f.root.path,
            attended: true, allowedTools: BackendAIRReadinessTools.toolIDs, allowedTiers: [.read, .alter], cancellation: BackendMCPCancellation())
        let args: NativeRPCValue = .object([.init("projectPath", .string(f.root.path)), .init("checkId", .string("gitignore")), .init("provider", .string("claude"))])
        let reply = try await definition.handler(caller, args)
        XCTAssertTrue(reply.isError)
        XCTAssertEqual(reply.structuredContent?["code"].string, "approval-required")
        XCTAssertEqual(prepared.value.first, args, "Core prepareEffect must bind the original MCP arguments.")
        let request = try XCTUnwrap(prepared.value.last)
        let plan = try await f.service.explain(project: f.root.path, checkID: "gitignore", context: f.context)
        XCTAssertEqual(request["cwd"].string, f.root.path)
        XCTAssertEqual(request["firstPrompt"].string, plan.aiPrompt)
        XCTAssertEqual(request["provider"].string, "claude")
        XCTAssertEqual(request["resume"].bool, false)
        XCTAssertEqual(launchCount.value, 0)
        XCTAssertTrue(f.approvals.value.isEmpty)
    }
}
