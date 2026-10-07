import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendGitHubParityCache: XCTestCase {
    func testSecondReadAndConcurrentReadsUseOneLoader() async throws {
        let clock = BackendGitHubParityClock(), cache = BackendGitHubCache(now: { clock.now() }), counter = BackendGitHubParityCounter()
        let loader: @Sendable () async -> NativeRPCValue = { .number(Double(await counter.increment())) }
        let first = try await cache.through("sequential", load: loader, ttl: { _ in 60_000 }), second = try await cache.through("sequential", load: loader, ttl: { _ in 60_000 })
        XCTAssertEqual(first, .number(1)); XCTAssertEqual(second, .number(1))
        let started = BackendGitHubParityLatch(), release = BackendGitHubParityLatch(), joined = BackendGitHubParityCounter()
        let slow: @Sendable () async -> NativeRPCValue = { _ = await joined.increment(); await started.release(); await release.wait(); return .number(7) }
        async let a = cache.through("concurrent", load: slow, ttl: { _ in 60_000 })
        async let b = cache.through("concurrent", load: slow, ttl: { _ in 60_000 })
        async let c = cache.through("concurrent", load: slow, ttl: { _ in 60_000 })
        await started.wait(); await release.release()
        let values = try await [a, b, c], calls = await joined.value()
        XCTAssertEqual(values, [.number(7), .number(7), .number(7)]); XCTAssertEqual(calls, 1)
    }
    func testExpiredZeroTtlAndRefreshActuallyRunAgain() async throws {
        let clock = BackendGitHubParityClock(), cache = BackendGitHubCache(now: { clock.now() }), counter = BackendGitHubParityCounter()
        let load: @Sendable () async -> NativeRPCValue = { .number(Double(await counter.increment())) }
        _ = try await cache.through("zero", load: load, ttl: { _ in 0 }); _ = try await cache.through("zero", load: load, ttl: { _ in 0 })
        let calls = await counter.value(); XCTAssertEqual(calls, 2)
        let first = try await cache.through("refresh", load: load, ttl: { _ in 60_000 }), refreshed = try await cache.through("refresh", refresh: true, load: load, ttl: { _ in 60_000 })
        XCTAssertEqual(first, .number(3)); XCTAssertEqual(refreshed, .number(4))
    }
    func testFailedLoaderDoesNotPoisonKey() async throws {
        let cache = BackendGitHubCache(now: { 0 })
        do { _ = try await cache.through("k", load: { throw NativeRPCError(code: "fixture", message: "boom") }, ttl: { _ in 60_000 }); XCTFail("Failing loader succeeded") }
        catch { XCTAssertEqual(error.localizedDescription, "boom") }
        let value = try await cache.through("k", load: { .string("fine") }, ttl: { _ in 60_000 }); XCTAssertEqual(value, .string("fine"))
    }
    func testWholeClearAndPrefixClearKeepOtherKeys() async throws {
        let cache = BackendGitHubCache(now: { 0 }), counter = BackendGitHubParityCounter()
        let load: @Sendable () async -> NativeRPCValue = { .number(Double(await counter.increment())) }
        _ = try await cache.through("k", load: load, ttl: { _ in 60_000 }); await cache.clear(); _ = try await cache.through("k", load: load, ttl: { _ in 60_000 })
        let calls = await counter.value(); XCTAssertEqual(calls, 2)
        _ = try await cache.through("repo /a", load: { .string("a") }, ttl: { _ in 60_000 }); _ = try await cache.through("repo /b", load: { .string("b") }, ttl: { _ in 60_000 })
        await cache.clear(prefix: "repo /a")
        let b = try await cache.through("repo /b", load: { .string("changed") }, ttl: { _ in 60_000 }), a = try await cache.through("repo /a", load: { .string("changed") }, ttl: { _ in 60_000 })
        XCTAssertEqual(b, .string("b")); XCTAssertEqual(a, .string("changed"))
    }
    func testPrefixClearDisownsInflightAndKeepsFreshResult() async throws {
        let cache = BackendGitHubCache(now: { 0 }), started = BackendGitHubParityLatch(), gate = BackendGitHubParityLatch()
        let first = Task { try await cache.through("repo /a", load: { await started.release(); await gate.wait(); return .string("stale") }, ttl: { _ in 60_000 }) }
        await started.wait(); await cache.clear(prefix: "repo /a")
        let second = try await cache.through("repo /a", load: { .string("fresh") }, ttl: { _ in 60_000 })
        await gate.release(); _ = try await first.value
        let kept = try await cache.through("repo /a", load: { .string("unused") }, ttl: { _ in 60_000 })
        XCTAssertEqual(second, .string("fresh")); XCTAssertEqual(kept, .string("fresh"))
    }
    func testRefreshNewestLoaderWinsNotSlowestCompletion() async throws {
        let cache = BackendGitHubCache(now: { 0 }), started = BackendGitHubParityLatch(), gate = BackendGitHubParityLatch()
        let older = Task { try await cache.through("k", load: { await started.release(); await gate.wait(); return .string("older") }, ttl: { _ in 60_000 }) }
        await started.wait()
        let newer = try await cache.through("k", refresh: true, load: { .string("refreshed") }, ttl: { _ in 60_000 })
        await gate.release(); _ = try await older.value
        let kept = try await cache.through("k", load: { .string("unused") }, ttl: { _ in 60_000 })
        XCTAssertEqual(newer, .string("refreshed")); XCTAssertEqual(kept, .string("refreshed"))
    }
    func testTwoHundredEntryBoundEvictsOldestAndKeepsRecent() async throws {
        let cache = BackendGitHubCache(now: { 0 })
        _ = try await cache.through("oldest", load: { .string("first") }, ttl: { _ in 60_000 })
        for index in 0..<200 { _ = try await cache.through("filler \(index)", load: { .number(Double(index)) }, ttl: { _ in 60_000 }) }
        let old = try await cache.through("oldest", load: { .string("again") }, ttl: { _ in 60_000 }), recent = try await cache.through("filler 199", load: { .string("should not run") }, ttl: { _ in 60_000 })
        XCTAssertEqual(old, .string("again")); XCTAssertEqual(recent, .number(199))
    }
    func testExpiredCorpsesCannotEvictLiveEntry() async throws {
        let cache = BackendGitHubCache(now: { 0 })
        for index in 0..<400 { _ = try await cache.through("dead \(index)", load: { .number(Double(index)) }, ttl: { _ in 0 }) }
        _ = try await cache.through("alive", load: { .string("kept") }, ttl: { _ in 60_000 })
        let kept = try await cache.through("alive", load: { .string("reloaded") }, ttl: { _ in 60_000 }); XCTAssertEqual(kept, .string("kept"))
    }
}
