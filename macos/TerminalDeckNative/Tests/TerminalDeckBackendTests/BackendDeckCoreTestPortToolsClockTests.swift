import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreTestPortToolsClock: BackendDeckCoreEventsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var at = 0.0
    private var timers: [UUID:(Double,@Sendable () -> Void)] = [:]
    private var armedWaiters: [CheckedContinuation<Void,Never>] = []
    func now() -> Double { lock.withLock { at } }
    func schedule(after milliseconds: Double,_ run: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID(),waiters = lock.withLock { timers[id] = (at+max(0,milliseconds),run); let values = armedWaiters; armedWaiters.removeAll(); return values }
        for waiter in waiters { waiter.resume() }; return id
    }
    func cancel(_ handle: UUID) { lock.withLock { _ = timers.removeValue(forKey:handle) } }
    func waitUntilScheduled() async { await withCheckedContinuation { continuation in let ready = lock.withLock { if !timers.isEmpty { return true }; armedWaiters.append(continuation); return false }; if ready { continuation.resume() } } }
    func advance(_ milliseconds: Double) {
        let target = now()+milliseconds
        while true {
            let run: (@Sendable () -> Void)? = lock.withLock { guard let next = timers.filter({ $0.value.0 <= target }).min(by:{ $0.value.0 < $1.value.0 }) else { at = target; return nil }; at = next.value.0; timers[next.key] = nil; return next.value.1 }
            guard let run else { return }; run()
        }
    }
    func pending() -> Int { lock.withLock { timers.count } }
}

actor BackendDeckCoreTestPortToolsGate {
    private var value: NativeRPCValue?
    private var waits: [CheckedContinuation<NativeRPCValue,Never>] = []
    private var begunWaits: [CheckedContinuation<Void,Never>] = []
    private var began = false
    func wait() async -> NativeRPCValue {
        began = true; for waiter in begunWaits { waiter.resume() }; begunWaits.removeAll()
        if let value { return value }
        return await withCheckedContinuation { waits.append($0) }
    }
    func waitUntilBegan() async { if began { return }; await withCheckedContinuation { begunWaits.append($0) } }
    func release(_ value: NativeRPCValue = .object([])) { self.value = value; for waiter in waits { waiter.resume(returning:value) }; waits.removeAll() }
}

private struct BackendDeckCoreTestPortToolsGitHubHold: BackendDeckToolsAppGitHubService {
    let owner: BackendDeckCoreTestPortToolsApplicationFake,gate: BackendDeckCoreTestPortToolsGate
    func overview(_ folder: String) async throws -> NativeRPCValue { try await owner.overview(folder) }
    func refresh(_ folder: String) async throws -> NativeRPCValue { try await owner.refresh(folder) }
    func repo(_ folder: String) async throws -> NativeRPCValue { try await owner.repo(folder) }
    func clearCache(_ folder: String) async throws { await owner.clearCache(folder) }
    func authStatus(_ folder: String) async throws -> NativeRPCValue { try await owner.authStatus(folder) }
    func connect() async throws -> NativeRPCValue { try await owner.connect() }
    func awaitAuth(_ folder: String) async throws -> NativeRPCValue { await gate.wait() }
    func cancel(_ folder: String) async throws -> NativeRPCValue { try await owner.cancel(folder) }
    func disconnect(_ folder: String) async throws -> NativeRPCValue { try await owner.disconnect(folder) }
}

@MainActor
final class BackendDeckCoreTestPortToolsClockTests: XCTestCase {
    // TSCASE github-tools.test.ts:72
    func testGitHubL72DeadlineLetsGoWithoutCancellingSignIn() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),gate = BackendDeckCoreTestPortToolsGate(),clock = BackendDeckCoreTestPortToolsClock()
        let defs = try BackendDeckToolsAppGitHub.definitions(service:BackendDeckCoreTestPortToolsGitHubHold(owner:fake,gate:gate),access:BackendDeckCoreTestPortToolsFixture.access(.init()),clock:clock)
        let call = Task { try await BackendDeckCoreTestPortToolsFixture.call(defs,"github.connect",#"{"do":"wait"}"#) }
        await clock.waitUntilScheduled(); await gate.waitUntilBegan(); clock.advance(Double(BackendDeckToolsAppGitHub.signInWaitMs)+1)
        let value = try BackendDeckCoreTestPortToolsFixture.value(await call.value),calls = await fake.calls()
        XCTAssertEqual(value["finished"],.bool(false)); XCTAssertFalse(calls.contains { $0["operation"].string == "cancel" })
        await gate.release(); XCTAssertEqual(clock.pending(),0)
    }
}
