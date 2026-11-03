import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class SFXSetupMCPTests: XCTestCase {
    private func context(tiers: Set<BackendMCPTier> = [.read, .act, .alter]) -> BackendMCPCallContext {
        .init(sessionID: "sfx-test", machineID: "", projectRoot: nil, attended: true, allowedTools: Set(BackendSFXMCP.toolIDs), allowedTiers: tiers, cancellation: .init())
    }
    private func access(_ audit: SFXSetupMCPAudit, deny: Bool = false, denyProject: Bool = false) -> BackendDeckToolsAppAccess {
        .init(caller: { _ in .init(kind: .local) }, knownFolder: { _, root in root }, session: { _, _ in .null },
              runnableProject: { _, root in if denyProject { throw NativeRPCError(code: "not-granted", message: "Project not granted.") }; return root },
              rpc: { _ in .init(caller: .nativeApp, ownerID: "sfx-test") },
              authorize: { _, id, _, tier, summary, owner in
                  await audit.record(id, tier: tier, summary: summary, owner: owner)
                  if deny { throw NativeRPCError(code: "not-approved", message: "The owner declined.") }
              }, record: { _, _, _, _ in })
    }

    func testColdPreviewDoesNotPrepareRuntimeAndPreparationAlwaysAsksOwner() async throws {
        let root = try scratch(), audit = SFXSetupMCPAudit(), plan = SFXSetupMCPPlan()
        let setup = BackendSFXSetupService(plan: { _, prepare in await plan.called(prepare); throw BackendStaysFixedNotDownloaded(note: "Prepare the pinned runtime.") }, setup: { _ in .null })
        let definitions = try BackendSFXMCP.definitions(service: setup, access: access(audit))
        let preview = try XCTUnwrap(definitions.first { $0.spec.id == "fixed.setup_preview" })
        let read = try await preview.handler(context(), .object([.init("project", .string(root.path))]))
        XCTAssertEqual(read.structuredContent?["prepareNeeded"], .bool(true))
        let first = await plan.preparations; XCTAssertEqual(first, 0)
        let prepare = try XCTUnwrap(definitions.first { $0.spec.id == "fixed.setup_prepare" })
        _ = try await prepare.handler(context(), .object([.init("project", .string(root.path))]))
        let asks = await audit.calls, downloads = await plan.preparations
        XCTAssertEqual(downloads, 1); XCTAssertEqual(asks.last?.owner, true); XCTAssertEqual(asks.last?.tier, .alter)
        XCTAssertTrue(asks.last?.summary.contains("about 60 MB") == true)
    }

    func testDeclinedPreparationAndUngrantedProjectNeverReachPlanner() async throws {
        let root = try scratch(), audit = SFXSetupMCPAudit(), plan = SFXSetupMCPPlan()
        let setup = BackendSFXSetupService(plan: { _, prepare in await plan.called(prepare); throw BackendStaysFixedNotDownloaded(note: "Prepare.") }, setup: { _ in .null })
        for permissions in [(true, false), (false, true)] {
            let definitions = try BackendSFXMCP.definitions(service: setup, access: access(audit, deny: permissions.0, denyProject: permissions.1))
            let prepare = try XCTUnwrap(definitions.first { $0.spec.id == "fixed.setup_prepare" })
            let reply = try await prepare.handler(context(), .object([.init("project", .string(root.path))]))
            XCTAssertTrue(reply.isError)
        }
        let preparations = await plan.preparations; XCTAssertEqual(preparations, 0)
    }

    func testClientApprovalFlagsAndReadOnlyWriteAreRefused() async throws {
        let root = try scratch(), audit = SFXSetupMCPAudit(), plan = SFXSetupMCPPlan()
        let setup = BackendSFXSetupService(plan: { _, prepare in await plan.called(prepare); return .null }, setup: { _ in .null })
        let definitions = try BackendSFXMCP.definitions(service: setup, access: access(audit))
        let prepare = try XCTUnwrap(definitions.first { $0.spec.id == "fixed.setup_prepare" })
        let flagged = try await prepare.handler(context(), .object([.init("project", .string(root.path)), .init("approved", .bool(true))]))
        XCTAssertTrue(flagged.isError)
        let readOnly = try await prepare.handler(context(tiers: [.read]), .object([.init("project", .string(root.path))]))
        XCTAssertTrue(readOnly.isError)
        let preparations = await plan.preparations, asks = await audit.calls
        XCTAssertEqual(preparations, 0); XCTAssertTrue(asks.isEmpty)
    }

    func testApplyShowsExactCommandAndDenialOrPostApprovalRevocationKeepsFiles() async throws {
        for revokeAfterApproval in [false, true] {
            let root = try scratch(), audit = SFXSetupMCPAudit(), grant = SFXSetupMCPGrant(), writes = SFXSetupMCPPlan()
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let ignore = root.appendingPathComponent(".gitignore"), originalIgnore = Data("keep-my-rule\n".utf8)
            try originalIgnore.write(to: ignore)
            let command = "/usr/bin/swift SFXGreeting.swift --help"
            let plan = Self.plan(root)
            let setup = BackendSFXSetupService(plan: { _, _ in plan }, setup: { _ in await writes.called(true); return .object([.init("ok", .bool(true))]) })
            let reviewed = try await setup.preview(root.path, checkCommand: command), token = try XCTUnwrap(reviewed["token"].string)
            let guarded = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) },
                knownFolder: { _, path in path }, session: { _, _ in .null },
                runnableProject: { _, path in guard await grant.allowed else { throw NativeRPCError(code: "not-granted", message: "Project grant revoked.") }; return path },
                rpc: { _ in .init(caller: .nativeApp, ownerID: "sfx-test") },
                authorize: { _, id, _, tier, summary, owner in
                    await audit.record(id, tier: tier, summary: summary, owner: owner)
                    if revokeAfterApproval { await grant.revoke() }
                    else { throw NativeRPCError(code: "not-approved", message: "The owner declined setup.") }
                }, record: { _, _, _, _ in })
            let definitions = try BackendSFXMCP.definitions(service: setup, access: guarded)
            let apply = try XCTUnwrap(definitions.first { $0.spec.id == "fixed.setup_apply" })
            let reply = try await apply.handler(context(), .object([.init("project", .string(root.path)), .init("token", .string(token))]))
            XCTAssertTrue(reply.isError)
            let asks = await audit.calls
            XCTAssertEqual(asks.count, 1); XCTAssertEqual(asks.first?.owner, true)
            XCTAssertTrue(asks.first?.summary.contains(command) == true)
            XCTAssertTrue(asks.first?.summary.contains("staysfixed.config.json") == true)
            XCTAssertEqual(try Data(contentsOf: ignore), originalIgnore)
            XCTAssertNil(BackendStaysFixedWhere.config(root.path))
            let called = await writes.preparations; XCTAssertEqual(called, 0)
        }
    }

    nonisolated private static func plan(_ root: URL) -> NativeRPCValue {
        .object([.init("root", .string(root.path)), .init("summary", .string("Swift command needs an explicit command.")), .init("config", .object([.init("file", .string(root.appendingPathComponent("staysfixed.config.js").path)), .init("text", .string("export default { product: 'swift-sample' };\n")), .init("exists", .bool(false))])), .init("readiness", .array([])), .init("covers", .object([.init("short", .string("No runnable product detected."))]))])
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SFX-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.resolvingSymlinksInPath()
    }
}

private actor SFXSetupMCPPlan {
    var preparations = 0
    func called(_ prepare: Bool) { if prepare { preparations += 1 } }
}
private actor SFXSetupMCPAudit {
    struct Call: Sendable { let id: String, tier: BackendMCPTier, summary: String, owner: Bool }
    var calls: [Call] = []
    func record(_ id: String, tier: BackendMCPTier, summary: String, owner: Bool) { calls.append(.init(id: id, tier: tier, summary: summary, owner: owner)) }
}
private actor SFXSetupMCPGrant {
    var allowed = true
    func revoke() { allowed = false }
}
