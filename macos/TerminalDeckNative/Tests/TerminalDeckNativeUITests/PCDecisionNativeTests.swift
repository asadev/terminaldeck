import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend
@testable import TerminalDeckNative

@MainActor final class PCDecisionNativeTests: XCTestCase {
    func testNativeModelUsesActualRegisteredServiceWithoutAnyBridgePayload() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/unused-pc-decision-ui"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
        try await store.start(); try await config.start(); try await goals.start()
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { [] }, start: { _, _, _, _, _ in throw NativeRPCError(code: "fixture", message: "No process may start") }, send: { _, _ in XCTFail("No delivery") }, stop: { _ in }, setControl: { _, _, _ in }, check: { _, _ in (true, "") }, tellHoot: { _ in XCTFail("No Hoot") })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access, workspace: { $0.project }, problem: { _ in })
        let local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: engine)
        let service = BackendPCDecisions(persistence: memory, tasks: store, local: local, access: .init(verify: { _, _, _ in "owner" }, owner: { _, _, _ in }), nudge: { _, _ in false })
        await service.start(); await engine.setBusinessDecision { await service.heldReason($0) }; try await engine.start()
        addTeardownBlock { try? await engine.stop() }
        let task = try await local.create(.object([.init("title", .string("Review approach")), .init("instructions", .string("Explain the approach.")), .init("project", .string("/work/fixture"))]))
        let registry = NativeChannelRegistry()
        try await BackendPCDecisionsMCP.register(registry: registry, ownerID: "fixture", service: service, requireOwnerUI: { _ in })
        let model = PCTaskDecisionModel(taskID: task.id, invoke: { input in try await registry.invoke("decisions:perform", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [input]) })
        await model.load(); XCTAssertEqual(model.state["eligible"], .bool(true)); XCTAssertFalse(model.editing)
        await model.act("policy", extra: [.init("name", .string("Owner workflow")), .init("mode", .string("owner-before-start")), .init("policyExpected", .number(0))])
        let policy = try XCTUnwrap(model.state["policies"].elements?.first?["id"].string)
        await model.act("bind", extra: [.init("policy", .string(policy))]); XCTAssertNil(model.problem)
        XCTAssertFalse(model.editing); XCTAssertEqual(model.proposal, "Explain the approach.")
        let view = NativePCTaskDecisionView(taskID: task.id, model: model); _ = view.body
        XCTAssertFalse(model.pending)
    }
    /// #313: each stage offers only the decision buttons it can take.
    func testDecisionOffersOnlyWhatItsStageAllows() {
        let model = PCTaskDecisionModel(taskID: "local:fixture", invoke: { _ in .null })
        func at(_ state: String, released: Bool = false) { model.state = .object([.init("decision", .object([.init("state", .string(state)), .init("released", .bool(released))]))]) }
        at("draft")
        XCTAssertTrue(model.can("submit")); XCTAssertFalse(model.can("approve")); XCTAssertFalse(model.can("release")); XCTAssertFalse(model.can("reject"))
        at("submitted")
        XCTAssertTrue(model.can("approve")); XCTAssertTrue(model.can("changes")); XCTAssertFalse(model.can("submit")); XCTAssertFalse(model.can("release"))
        at("approved")
        XCTAssertTrue(model.can("release")); XCTAssertFalse(model.can("approve")); XCTAssertFalse(model.can("submit"))
        at("approved", released: true)
        XCTAssertFalse(model.can("release"))
        at("changes-requested")
        XCTAssertFalse(model.can("approve")); XCTAssertFalse(model.can("submit")); XCTAssertTrue(model.can("draft"))
    }
    /// #329: a change tried while the app starts asks to wait a moment.
    func testAChangeWhileStartingAsksToWait() async throws {
        guard !EngineBridge.shared.isReady else { throw XCTSkip("An engine is attached in this test run.") }
        let result = await TasksStore.shared.call("tasks:update", ["local:fixture", [:] as [String: Any]])
        XCTAssertFalse(result.ok); XCTAssertEqual(result.message, "Terminal Deck is still starting. Try again in a moment.")
    }
}
