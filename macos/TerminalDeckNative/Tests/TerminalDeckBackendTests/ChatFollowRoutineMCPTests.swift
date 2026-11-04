import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatFollowRoutineMCPTests: XCTestCase, @unchecked Sendable {
    actor Probe {
        var actions: [String] = []
        var approvals: [Bool] = []
        func action(_ value: String) { actions.append(value) }
        func approved(_ owner: Bool) { approvals.append(owner) }
    }
    func testRoutineViewportReadsFreelyAndScrollsOnlyAfterOwnerApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-follow-tool-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BackendRoutinesStore(directory: directory)
        _ = try store.save(.init(id: "scratch", name: "Scratch", triggers: [.manual], folder: "/scratch", prompt: "Check changes"))
        let engine = BackendRoutinesEngine(options: .init(store: store, runtime: .init(userData: directory), log: { _ in }))
        let api = BackendRoutinesAPI(engine: engine, store: store)
        let probe = Probe()
        func tool(approved: Bool) throws -> BackendDeckToolsDefinition {
            let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, path in path },
                session: { _, _ in .null }, runnableProject: { _, path in path }, rpc: { _ in .init(caller: .nativeApp, ownerID: "scratch") },
                authorize: { _, _, _, _, _, owner in
                    await probe.approved(owner)
                    if owner && !approved { throw NativeRPCError(code: "not-approved", message: "Owner declined scrolling.") }
                }, record: { _, _, _, _ in })
            return try XCTUnwrap(BackendRoutines21MCP.definitions(api: api, access: access, chatView: { id, action in
                XCTAssertEqual(id, "scratch")
                await probe.action(action)
                return .object([.init("views", .array([]))])
            }).first { $0.spec.id == "routines.chat_view" })
        }
        func context(_ tiers: Set<BackendMCPTier>) -> BackendMCPCallContext {
            .init(sessionID: "scratch", machineID: "", projectRoot: nil, attended: true,
                  allowedTools: ["routines.chat_view"], allowedTiers: tiers, cancellation: .init())
        }
        let read: NativeRPCValue = .object([.init("routineId", .string("scratch")), .init("do", .string("read"))])
        let scroll = read.setting("do", .string("latest"))
        let denied = try tool(approved: false)
        let first = try await denied.handler(context([.read]), read)
        XCTAssertFalse(first.isError)
        let noTier = try await denied.handler(context([.read]), scroll)
        XCTAssertTrue(noTier.isError)
        let noApproval = try await denied.handler(context([.read, .act]), scroll)
        XCTAssertTrue(noApproval.isError)
        let before = await probe.actions
        XCTAssertEqual(before, ["read"])
        let granted = try tool(approved: true)
        let accepted = try await granted.handler(context([.read, .act]), scroll)
        XCTAssertFalse(accepted.isError)
        let after = await probe.actions, approvals = await probe.approvals
        XCTAssertEqual(after, ["read", "latest"])
        XCTAssertEqual(approvals, [false, true, true])
    }
}
