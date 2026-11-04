import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BrowserSecurity27Tests: BackendDeckCoreTestPortSecurityCase {
    private func step(tier: BackendMCPTier = .act, holder: BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityControl?>? = nil) throws -> BackendDeckCoreSecurityToolPolicy {
        .init(tool: try .init(id: "browser.step", wireName: "browser_step", description: "Browser input", inputSchema: o([
            ("type", .string("object")), ("properties", o([("window", o([("type", .string("string"))]))]))
        ]), tier: tier), summary: { _, _ in "Browser input" }, run: { args, context in
            if let control = holder?.get() {
                _ = try await control.prepareEffect(context: context, tool: "browser.step", arguments: args, tier: .alter, sentence: "Use the site", ownerMustAnswer: false)
            }
            return .init(value: .bool(true))
        })
    }

    func testStepsShareOneCallerBudgetAcrossTabsWithoutSpendingOrdinaryChanges() async throws {
        let f = try rig(budgets: .init(changes: .init(limit: 1, windowMilliseconds: 300_000),
            browserSteps: .init(limit: 2, windowMilliseconds: 300_000)), extras: [step()])
        let one = await f.call("browser_step", o([("window", .string("B1"))]))
        let wrapped = await f.call("tools_run", o([("name", .string("browser_step")), ("arguments", o([("window", .string("B2"))]))]))
        XCTAssertTrue(one.ok, one.error ?? ""); XCTAssertTrue(wrapped.ok, wrapped.error ?? "")
        let third = await f.call("browser.step", o([("window", .string("B3"))]))
        XCTAssertEqual(third.refusal, .rateLimited)
        let other = await f.call("browser_step", .object([]), .init(caller: .init(kind: .session, tiers: [.read, .act, .alter], sessionID: "other", machineID: "")))
        XCTAssertTrue(other.ok, other.error ?? "")
        let ordinary = await f.call("log_note", o([("note", .string("one change"))]))
        let next = await f.call("log_note", o([("note", .string("another change"))]))
        XCTAssertTrue(ordinary.ok, ordinary.error ?? ""); XCTAssertEqual(next.refusal, .rateLimited)
        f.clock.advance(300_000)
        let after = await f.call("browser_step")
        XCTAssertTrue(after.ok, after.error ?? "")
    }

    func testReadBasedToolUsesBrowserBudgetWhenTheSiteRaisesItsTier() async throws {
        let holder = BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityControl?>(nil)
        let f = try rig(budgets: .init(changes: .init(limit: 1, windowMilliseconds: 300_000),
            browserSteps: .init(limit: 2, windowMilliseconds: 300_000)), extras: [step(tier: .read, holder: holder)])
        holder.set(f.control)
        for _ in 0..<2 { let result = await f.call("browser_step"); XCTAssertTrue(result.ok, result.error ?? "") }
        let third = await f.call("browser_step")
        XCTAssertEqual(third.refusal, .rateLimited)
        let ordinary = await f.call("log_note", o([("note", .string("still allowed"))]))
        XCTAssertTrue(ordinary.ok, ordinary.error ?? "")
        XCTAssertEqual(BackendDeckCoreSecurityBudgets().browserSteps.limit, 300)
        XCTAssertEqual(BackendDeckCoreSecurityBudgets().browserSteps.windowMilliseconds, 300_000)
        XCTAssertEqual(BackendDeckCoreSecurityBudgets().changes.limit, 30)
    }

    func testSessionToolsRefuseProfileScriptsAndStorageBeforeTheRuntime() async throws {
        let f = BackendDeckCoreTestPortSessionsBrowserFixture()
        try f.attach("person-profile")
        let context = NativeRPCContext(caller: .internalEngine, ownerID: "|s1")
        for op in ["evaluate", "storage", "route", "requests", "console", "dialogs", "emulate"] {
            do {
                _ = try await f.service.page(context, operation: op, arguments: o([("window", .string("B1"))]))
                XCTFail("Profile control reached the runtime: \(op)")
            } catch let error as NativeRPCError {
                XCTAssertEqual(error.code, "not-permitted")
                XCTAssertTrue(error.message.contains("isolated"), error.message)
            }
        }
        do {
            _ = try await f.service.page(context, operation: "evaluate", arguments: o([("window", .string("W1"))]))
            XCTFail("A session selected a person's W window")
        } catch {}
    }
}
