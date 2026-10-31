import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Server-control registry drain with barriers, no timers or I/O")
struct BackendDockerMCPRegistryDrainTests {
    @Test func cancelledHandlerFinishesCleanupBeforeDrainReturns() async throws {
        let registry = NativeChannelRegistry(), state = BackendDockerMCPRegistryDrainState()
        try await registry.register("drain:owned", ownerID: "server-control") { _, _ in try await state.handle() }
        let request = Task { try await registry.invoke("drain:owned", context: .init(caller: .nativeApp, ownerID: "window"), arguments: []) }
        defer { request.cancel(); state.releaseCleanup.finish(.success(())) }
        try await state.started.value()
        let drain = Task { await registry.stopOwnerAndWait("server-control"); await state.drained() }
        try await state.cleanupStarted.value()
        let waiting = await state.snapshot()
        #expect(!waiting.cleanupFinished)
        #expect(!waiting.drainReturned)
        state.releaseCleanup.finish(.success(()))
        await drain.value
        let finished = await state.snapshot()
        #expect(finished.cleanupFinished)
        #expect(finished.drainReturned)
        _ = await request.result
    }

    @Test func unrelatedRegistrationSurvivesEvenWhenCallerMatchesStoppedOwner() async throws {
        let registry = NativeChannelRegistry(), state = BackendDockerMCPRegistryDrainState()
        let otherStarted = BackendServersSSHOnce<Void>(), releaseOther = BackendServersSSHOnce<Void>()
        try await registry.register("drain:owned", ownerID: "server-control") { _, _ in try await state.handle() }
        try await registry.register("drain:unrelated", ownerID: "other-area") { _, _ in
            otherStarted.finish(.success(()))
            try await releaseOther.value()
            try Task.checkCancellation()
            return .string("unrelated registration survived")
        }
        let owned = Task { try await registry.invoke("drain:owned", context: .init(caller: .nativeApp, ownerID: "window"), arguments: []) }
        let other = Task { try await registry.invoke("drain:unrelated", context: .init(caller: .page, ownerID: "server-control"), arguments: []) }
        defer { owned.cancel(); other.cancel(); state.releaseCleanup.finish(.success(())); releaseOther.finish(.success(())) }
        try await state.started.value(); try await otherStarted.value()
        let drain = Task { await registry.stopOwnerAndWait("server-control"); await state.drained() }
        try await state.cleanupStarted.value()
        releaseOther.finish(.success(()))
        #expect(try await other.value == .string("unrelated registration survived"))
        #expect(await registry.has("drain:unrelated"))
        #expect(!(await state.snapshot()).drainReturned)
        state.releaseCleanup.finish(.success(())); await drain.value
        _ = await owned.result
    }

    @Test func newInvocationAndRegistrationAreRefusedWhileDrainWaits() async throws {
        let registry = NativeChannelRegistry(), state = BackendDockerMCPRegistryDrainState()
        try await registry.register("drain:owned", ownerID: "server-control") { _, _ in try await state.handle() }
        let request = Task { try await registry.invoke("drain:owned", context: .init(caller: .nativeApp, ownerID: "window"), arguments: []) }
        defer { request.cancel(); state.releaseCleanup.finish(.success(())) }
        try await state.started.value()
        let drain = Task { await registry.stopOwnerAndWait("server-control"); await state.drained() }
        try await state.cleanupStarted.value()
        #expect(!(await state.snapshot()).drainReturned)
        do {
            _ = try await registry.invoke("drain:owned", context: .init(caller: .nativeApp, ownerID: "new-window"), arguments: [])
            Issue.record("A new invocation entered a draining owner")
        } catch { #expect((error as? NativeRPCError)?.code == "missing-handler") }
        do {
            try await registry.register("drain:replacement", ownerID: "server-control") { _, _ in
                Issue.record("A replacement handler executed while its owner drained")
                return .null
            }
            Issue.record("A draining registration owner registered a replacement")
        } catch { #expect(error is NativeRPCError) }
        #expect(!(await registry.has("drain:replacement")))
        state.releaseCleanup.finish(.success(())); await drain.value
        _ = await request.result
    }
}

private actor BackendDockerMCPRegistryDrainState {
    nonisolated let started = BackendServersSSHOnce<Void>()
    nonisolated let cleanupStarted = BackendServersSSHOnce<Void>()
    nonisolated let releaseCleanup = BackendServersSSHOnce<Void>()
    private let pending = BackendServersSSHOnce<Void>()
    private var cleanupFinished = false, drainReturned = false
    func handle() async throws -> NativeRPCValue {
        let pending = self.pending
        started.finish(.success(()))
        do {
            try await withTaskCancellationHandler { try await pending.value() } onCancel: {
                pending.finish(.failure(CancellationError()))
            }
        } catch {
            cleanupStarted.finish(.success(()))
            // This barrier deliberately ignores the task's cancelled state:
            // a sealed cleanup must finish before its transport owner stops.
            try await releaseCleanup.value()
            cleanupFinished = true
            throw CancellationError()
        }
        return .null
    }
    func drained() { drainReturned = true }
    func snapshot() -> (cleanupFinished: Bool, drainReturned: Bool) { (cleanupFinished, drainReturned) }
}
