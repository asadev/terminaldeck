import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// start-account.test.ts: `sessions.start` with an account, and the limits a
/// start carries, through the real catalogue tool (precheck, summary, run).
/// A wrong account name is refused with the real names, never started as
/// somebody else.
final class BackendDeckCoreTestPortS1StartAccountTests: BackendDeckCoreTestPortSecurityCase {
    private typealias F = BackendDeckCoreTestPortS1StartFixture
    private typealias Surface = BackendDeckCoreTestPortS1StartSurface

    /// start-account.test.ts `withAccounts()`.
    private func withAccounts() -> Surface {
        let surface = Surface.lane()
        surface.accountRows = [
            o([("id", .string("system:claude")), ("name", .string("Personal")), ("provider", .string("claude"))]),
            o([("id", .string("p-work")), ("name", .string("Work")), ("provider", .string("claude"))]),
            o([("id", .string("p-codex")), ("name", .string("Side")), ("provider", .string("codex"))]),
        ]
        return surface
    }
    /// sessions-lane.fixture.ts `contextFor(surface)`, optionally with the call's session limits.
    private func contextFor(_ limits: V = .missing) -> BackendDeckCoreSecurityCallContext {
        F.context(callID: "call-1", now: 10_000, owned: .init([]), limits: limits)
    }
    private func keys(_ value: V) -> [String] { (value.fields ?? []).map(\.key) }

    // TSCASE start-account.test.ts:32
    func testStartAccountL32StartsAsNamedAccountAndAccountDecidesAgent() async throws {
        let surface = withAccounts(), start = try F.start(surface)
        _ = try await start.run(o([("cwd", .string("/work/web")), ("account", .string("side"))]), contextFor())
        let first = try XCTUnwrap(surface.started.first)
        XCTAssertEqual(first["profileId"], .string("p-codex"))
        XCTAssertEqual(first["provider"], .string("codex"))
    }
    // TSCASE start-account.test.ts:39
    func testStartAccountL39UnknownNameRefusedBeforeStartNamingRealOnes() throws {
        let surface = withAccounts(), start = try F.start(surface), precheck = try XCTUnwrap(start.precheck), context = contextFor()
        assertError({ try precheck(self.o([("cwd", .string("/work/web")), ("account", .string("Holiday"))]), context) },
                    contains: "Personal (claude), Work (claude), Side (codex)")
        XCTAssertTrue(surface.started.isEmpty)
    }
    // TSCASE start-account.test.ts:48
    func testStartAccountL48AccountOfDifferentAgentRefused() throws {
        let surface = withAccounts(), start = try F.start(surface), precheck = try XCTUnwrap(start.precheck), context = contextFor()
        assertError({ try precheck(self.o([("cwd", .string("/work/web")), ("account", .string("Work")), ("provider", .string("codex"))]), context) },
                    contains: "claude login")
    }
    // TSCASE start-account.test.ts:56
    func testStartAccountL56HostThatCannotChooseSaysSo() throws {
        let surface = Surface.lane(), start = try F.start(surface), precheck = try XCTUnwrap(start.precheck), context = contextFor()
        assertError({ try precheck(self.o([("cwd", .string("/work/web")), ("account", .string("Work"))]), context) },
                    contains: "cannot choose an account")
    }
    // TSCASE start-account.test.ts:62
    func testStartAccountL62SentenceNamesTheAccount() throws {
        let start = try F.start(Surface.lane())
        XCTAssertEqual(try start.summary(o([("cwd", .string("/work/web")), ("provider", .string("claude")), ("account", .string("Work"))]), contextFor()),
                       "Start a claude session as Work in /work/web")
    }
    // TSCASE start-account.test.ts:71
    func testStartAccountL71LimitsComeFromCallOptionsAndNothingWhenNoneGiven() async throws {
        let surface = withAccounts(), start = try F.start(surface)
        let limited = contextFor(o([("deniedTools", .array([.string("WebFetch"), .string("WebFetch")])), ("noSkills", .bool(true))]))
        _ = try await start.run(o([("cwd", .string("/work/web")), ("provider", .string("claude"))]), limited)
        _ = try await start.run(o([("cwd", .string("/work/api")), ("provider", .string("claude"))]), contextFor())
        XCTAssertEqual(surface.started.count, 2)
        XCTAssertEqual(surface.started[0]["deniedTools"], .array([.string("WebFetch")]))
        XCTAssertEqual(surface.started[0]["noSkills"], .bool(true))
        XCTAssertFalse(keys(surface.started[1]).contains("deniedTools"))
        XCTAssertFalse(keys(surface.started[1]).contains("noSkills"))
    }
    // TSCASE start-account.test.ts:81
    func testStartAccountL81NeverFromArgumentsAndRefusesNonToolName() async throws {
        let surface = withAccounts(), start = try F.start(surface)
        let properties = try XCTUnwrap(start.tool.inputSchema["properties"].fields).map(\.key)
        XCTAssertFalse(properties.contains("blockTools"))
        let limited = contextFor(o([("deniedTools", .array([.string("--allowedTools")]))]))
        await assertAsyncError({ _ = try await start.run(self.o([("cwd", .string("/work/web"))]), limited) }, contains: "not a tool name")
        XCTAssertTrue(surface.started.isEmpty)
    }
}
