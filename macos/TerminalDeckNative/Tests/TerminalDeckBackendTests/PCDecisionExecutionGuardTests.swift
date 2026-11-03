import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class PCDecisionExecutionGuardTests: XCTestCase, @unchecked Sendable {
    private actor State {
        var allowed = true, effects = 0
        func revoke() { allowed = false }
        func verify() throws { guard allowed else { throw NativeRPCError(code: "decision-held", message: "Fixture decision changed") } }
        func effect() { effects += 1 }
    }
    private actor Worker: BackendHootTaskWorker {
        let state: State
        init(_ state: State) { self.state = state }
        func backgroundTurn(_ turn: BackendHootBackgroundTurn, progress: @escaping @Sendable (BackendHootTaskProgress) async -> Void) async throws -> BackendHootTaskResult {
            try await BackendPCDecisionDelivery.verifyFinal(.input); await state.effect()
            return .init(answer: "fixture", finished: true)
        }
        func cancelBackgroundTurn(reason: String, id: String?) async {}
        func rest() async {}
    }

    func testMissingRequiredValidatorFailsClosedWhileOrdinaryEffectsRemainAvailable() async throws {
        try await BackendPCDecisionDelivery.verify()
        do {
            try await BackendPCDecisionDelivery.$required.withValue(true) { try await BackendPCDecisionDelivery.verifyFinal(.input) }
            XCTFail("Required execution lost its validator")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "decision-held") }
    }

    func testHootRevalidatesAfterPreparingItsTaskWorkerBeforeMemoryOrProviderEffects() async throws {
        let state = State(), worker = Worker(state)
        let conversations = BackendHootTaskConversations(memory: { fatalError("A refused task must not reach memory or provider delivery") }, make: { _ in
            await state.revoke(); return worker
        })
        do {
            _ = try await BackendPCDecisionDelivery.$required.withValue(true) {
                try await BackendPCDecisionDelivery.$validate.withValue({ try await state.verify() }) {
                    try await conversations.turn(taskID: "local:fixture", title: "Held", message: "Must not execute")
                }
            }
            XCTFail("Revoked Hoot task executed")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "decision-held") }
        let effects = await state.effects; XCTAssertEqual(effects, 0)
    }

    func testLeadFinalPortReceivesCurrentValidatorAndRefusesChangesAfterPreparation() async throws {
        for changed in [false, true] {
            let state = State()
            let task = BackendAGTLeadSeatTask(id: "local:fixture", title: "Review", details: "Fixture", seat: "lead:p", toldSession: nil, givenBy: "Owner",
                decisionRequired: true, decisionScope: "fixture-scope", decisionReference: "fixture-reference")
            var dependencies = BackendAGTLeadSeats.Dependencies(
                projects: { [PROJProject(id: "p", name: "Fixture", folders: ["/fixture"], lead: "session:s1", leadName: "Fixture lead")] },
                sessions: { [.init(id: "s1", title: "Fixture lead", projectID: "p", provider: "claude")] },
                tell: { _, _ in
                    if changed { await state.revoke() }
                    try await BackendPCDecisionDelivery.verifyFinal(.input)
                    await state.effect()
                }, tasks: { [task] }, task: { $0 == task.id ? task : nil }, told: { _, _ in }, note: { _, _, _ in }, handToAgent: { _, _ in })
            dependencies.validateDelivery = { _ in try await state.verify() }
            let seats = BackendAGTLeadSeats(dependencies)
            await seats.assigned(task.id); await seats.settle()
            let effects = await state.effects; XCTAssertEqual(effects, changed ? 0 : 1)
        }
    }

    func testProviderSpawnCannotReviveAnOwnerStoppedWhileFinalValidationWaits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-final-spawn-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"), provider: .claude)
        do {
            try await BackendPCDecisionDelivery.$validate.withValue({}) {
                try await BackendPCDecisionDelivery.$finalEffect.withValue({ _ in await store.stop() }) {
                    try await store.attach(.init(command: "/usr/bin/true", arguments: [], cwd: root.path, environment: [:]))
                }
            }
            XCTFail("A stopped owner was revived")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "interrupted") }
        let alive = await store.alive; XCTAssertFalse(alive)
        await store.stop()
    }
}
