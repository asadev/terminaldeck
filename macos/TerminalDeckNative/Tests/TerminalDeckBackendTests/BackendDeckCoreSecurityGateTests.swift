import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreSecurityGateTests: XCTestCase {
    private func temporary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckCoreSecurityGate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }; return dir
    }
    private func policy(_ id: String = "settings.write", tier: BackendMCPTier = .alter, aliases: [String] = [], spendsDeviceInput: Bool = false,
                        mustAnswer: Bool = false, precheck: (@Sendable (NativeRPCValue, BackendDeckCoreSecurityCallContext) throws -> Void)? = nil,
                        run: @escaping BackendDeckCoreSecurityToolPolicy.Handler) throws -> BackendDeckCoreSecurityToolPolicy {
        .init(tool: try .init(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: id,
              inputSchema: .object([.init("type", .string("object")), .init("properties", .object([])), .init("additionalProperties", .bool(false))]), tier: tier),
              aliases: aliases, spendsDeviceInput: spendsDeviceInput, summary: { _, _ in "Change the theme" }, precheck: precheck,
              ownerMustAnswer: mustAnswer ? { @Sendable (_: NativeRPCValue) throws -> Bool in true } : nil, run: run)
    }
    private let questionTool = "settings.write"
    func testNoApproverAndThrowingApproverRefuseImmediately() async {
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in false })
        let no = await broker.request(tool: questionTool, tier: .alter, summary: "Change", arguments: .object([]))
        XCTAssertFalse(no.granted); XCTAssertEqual(no.reason, .noApprover)
        let pending = await broker.list(); XCTAssertTrue(pending.isEmpty)
        let broken = BackendDeckCoreSecurityConsentBroker(ask: { _ in throw NativeRPCError.invalidArguments("gone") })
        let refused = await broken.request(tool: questionTool, tier: .alter, summary: "Change", arguments: .object([])); XCTAssertEqual(refused.reason, .noApprover)
    }
    func testTimeoutRejectsLateApproval() async {
        let seen = BackendDeckCoreSecurityTestBox<[BackendDeckCoreSecurityConsentRequest]>([])
        let broker = BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: 5, ask: { question in seen.edit { $0.append(question) }; return true })
        let outcome = await broker.request(tool: questionTool, tier: .alter, summary: "Change", arguments: .object([]))
        XCTAssertEqual(outcome.reason, .timeout)
        let accepted = await broker.respond(id: seen.get().first?.id ?? "missing", approved: true, by: "window"); XCTAssertFalse(accepted)
    }
    func testAsyncDeliveryDoesNotExtendQuestionDeadline() async {
        let clock = BackendDeckCoreSecurityTestBox<Double>(1000)
        let broker = BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: 10, now: { clock.get() }, ask: { _ in clock.set(1020); return true })
        let outcome = await broker.request(tool: questionTool, tier: .alter, summary: "Change", arguments: .object([]))
        XCTAssertEqual(outcome.reason, .timeout)
    }
    func testDeviceCannotAnswerAnotherDeviceButDesktopCan() async {
        let asked = expectation(description: "question delivered")
        let seen = BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityConsentRequest?>(nil)
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { question in seen.set(question); asked.fulfill(); return true })
        let call = Task { await broker.request(tool: "settings.write", tier: .alter, summary: "Change", arguments: .object([]), origin: "device:one") }
        await fulfillment(of: [asked], timeout: 1)
        let id = seen.get()?.id ?? "missing"
        let wrong = await broker.respond(id: id, approved: true, by: "device:two"); XCTAssertFalse(wrong)
        let owner = await broker.respond(id: id, approved: true, by: "window"); XCTAssertTrue(owner)
        let outcome = await call.value; XCTAssertTrue(outcome.granted); XCTAssertEqual(outcome.by, "window")
        XCTAssertTrue(BackendDeckCoreSecurityConsentBroker.mayAnswerFor(origin: "key:k", by: "device:one"))
        XCTAssertFalse(BackendDeckCoreSecurityConsentBroker.mayAnswerFor(origin: "window", by: "device:one"))
    }
    func testCallerCancellationClosesQuestionAndApprovalCannotLand() async {
        let asked = expectation(description: "question delivered")
        let seen = BackendDeckCoreSecurityTestBox<String?>(nil)
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { question in seen.set(question.id); asked.fulfill(); return true })
        let cancellation = BackendMCPCancellation()
        let call = Task { await broker.request(tool: "settings.write", tier: .alter, summary: "Change", arguments: .object([]), cancellation: cancellation) }
        await fulfillment(of: [asked], timeout: 1); cancellation.cancel()
        let approved = await broker.respond(id: seen.get() ?? "missing", approved: true, by: "window"); XCTAssertFalse(approved)
        let outcome = await call.value; XCTAssertEqual(outcome.reason, .callerGone)
    }
    func testPendingCapShutdownAndCallerSurfaceGuard() async throws {
        let count = BackendDeckCoreSecurityTestBox<Int>(0); let asked = expectation(description: "three delivered"); asked.expectedFulfillmentCount = 3
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in count.edit { $0 += 1 }; asked.fulfill(); return true })
        let calls = (0..<3).map { _ in Task { await broker.request(tool: "settings.write", tier: .alter, summary: "Change", arguments: .object([])) } }
        await fulfillment(of: [asked], timeout: 1)
        let fourth = await broker.request(tool: "settings.write", tier: .alter, summary: "Change", arguments: .object([])); XCTAssertEqual(fourth.reason, .tooManyPending)
        do { try await broker.callerGone("window"); XCTFail("Window must use approverGone") } catch {}
        await broker.stop(); for call in calls { let outcome = await call.value; XCTAssertEqual(outcome.reason, .shuttingDown) }
        let later = await broker.request(tool: "settings.write", tier: .alter, summary: "Change", arguments: .object([])); XCTAssertEqual(later.reason, .shuttingDown)
    }
    func testGateNoApproverLeavesOperationUntouchedAndWritesOneRefusalRow() async throws {
        let ran = BackendDeckCoreSecurityTestBox<Int>(0); let log = BackendDeckCoreSecurityActionLog(directory: try temporary())
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in false })
        let p = try policy { _, _ in ran.edit { $0 += 1 }; return .init(value: .bool(true)) }
        let control = try BackendDeckCoreSecurityControl(log: log, consent: broker, policies: [p])
        let result = await control.call(name: "settings_write", arguments: .object([]))
        XCTAssertEqual(result.refusal, .noApprover); XCTAssertEqual(ran.get(), 0)
        let rows = await log.tail(); XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0]["confirmed"]["granted"], .bool(false))
    }
    func testUnattendedRefusalAndPrecheckOrdering() async throws {
        let asked = BackendDeckCoreSecurityTestBox<Int>(0)
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in asked.edit { $0 += 1 }; return true })
        let p = try policy { _, _ in XCTFail("Refused operation must never run"); return .init(value: .null) }
        let protected = try policy("protected", precheck: { _, _ in throw BackendDeckCoreSecurityRefusal(.notPermitted, "protected setting") }, run: { _, _ in .init(value: .null) })
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: try temporary()), consent: broker, policies: [p, protected])
        let no = await control.unattendedCall(name: "settings.write", arguments: .object([])); XCTAssertEqual(no.refusal, .unattended); XCTAssertTrue(no.error?.contains("Do not retry it") == true)
        let permanent = await control.unattendedCall(name: "protected", arguments: .object([])); XCTAssertEqual(permanent.refusal, .notPermitted); XCTAssertEqual(asked.get(), 0)
    }
    func testStandingKeyApprovalNamesKeyAndMustAnswerCannotBypass() async throws {
        let count = BackendDeckCoreSecurityTestBox<Int>(0)
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in count.edit { $0 += 1 }; return false })
        let ordinary = try policy { _, _ in .init(value: .object([.init("ok", .bool(true))]), summary: .object([.init("changed", .number(1))])) }
        let forced = try policy("password.fill", tier: .read, mustAnswer: true, run: { _, _ in .init(value: .null) })
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: try temporary()), consent: broker, policies: [ordinary, forced])
        let caller = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter], keyID: "key1", keyName: "ChatGPT", askFirst: false)
        let done = await control.call(name: "settings.write", arguments: .object([]), options: .init(caller: caller))
        XCTAssertTrue(done.ok); XCTAssertEqual(done.row["confirmed"]["by"], .string("standing:key:key1")); XCTAssertTrue(done.row["detail"].string?.contains("without asking") == true)
        let forcedResult = await control.call(name: "password.fill", arguments: .object([]), options: .init(caller: caller))
        XCTAssertEqual(forcedResult.refusal, .noApprover); XCTAssertEqual(count.get(), 1)
    }
    func testEscalationCannotLowerTierAndChecksGrantBeforePrecheckBudget() async throws {
        let prechecks = BackendDeckCoreSecurityTestBox<Int>(0)
        let tool = try BackendMCPTool(id: "sessions.send", wireName: "sessions_send", description: "send", inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .act)
        let p = BackendDeckCoreSecurityToolPolicy(tool: tool, summary: { _, _ in "Send" }, precheck: { _, _ in prechecks.edit { $0 += 1 } }, escalate: { _, _ in .alter }, run: { _, _ in .init(value: .null) })
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: try temporary()), consent: .init(ask: { _ in false }), policies: [p])
        let caller = BackendDeckCoreSecurityCaller(kind: .remote, tiers: [.read, .act], deviceID: "phone")
        let result = await control.call(name: "sessions_send", arguments: .object([]), options: .init(caller: caller))
        XCTAssertEqual(result.refusal, .notGranted); XCTAssertEqual(prechecks.get(), 0); XCTAssertEqual(result.row["baseTier"], .string("act"))
    }
    func testKeyBudgetsSeparateDeviceBudgetAndWindowCutoff() async throws {
        let clock = BackendDeckCoreSecurityTestBox<Double>(1000)
        let read = try policy("projects.list", tier: .read, run: { _, _ in .init(value: .null) })
        let tap = try policy("devices.tap", tier: .act, spendsDeviceInput: true, run: { _, _ in .init(value: .null) })
        let change = try policy("sessions.start", tier: .act, run: { _, _ in .init(value: .null) })
        let budgets = BackendDeckCoreSecurityBudgets(all: .init(limit: 4, windowMilliseconds: 60_000), changes: .init(limit: 1, windowMilliseconds: 300_000), deviceInput: .init(limit: 3, windowMilliseconds: 300_000))
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: try temporary()), consent: .init(ask: { _ in false }), policies: [read, tap, change], budgets: budgets, now: { clock.get() })
        let key = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act], keyID: "k")
        for _ in 0..<4 { let r = await control.call(name: "projects.list", arguments: .object([]), options: .init(caller: key)); XCTAssertTrue(r.ok) }
        let denied = await control.call(name: "projects.list", arguments: .object([]), options: .init(caller: key)); XCTAssertEqual(denied.refusal, .rateLimited)
        let local = await control.call(name: "devices.tap", arguments: .object([])); XCTAssertTrue(local.ok)
        let start = await control.call(name: "sessions.start", arguments: .object([])); XCTAssertTrue(start.ok)
        clock.set(61_000); let after = await control.call(name: "projects.list", arguments: .object([]), options: .init(caller: key)); XCTAssertTrue(after.ok)
    }
    func testAliasesRunTargetLogsInnerOnceAndSchemaEnforced() async throws {
        let log = BackendDeckCoreSecurityActionLog(directory: try temporary())
        let renamed = try policy("hoot.state", tier: .read, aliases: ["copilot.state", "copilot_state"], run: { _, _ in .init(value: .bool(true)) })
        let run = try policy("tools.run", tier: .read, run: { _, _ in throw NativeRPCError.invalidArguments("should intercept") })
        let control = try BackendDeckCoreSecurityControl(log: log, consent: .init(ask: { _ in false }), policies: [renamed, run])
        let called = await control.call(name: "tools.run", arguments: .object([.init("name", .string("copilot_state")), .init("arguments", .string("{}"))]))
        XCTAssertTrue(called.ok); XCTAssertEqual(called.row["tool"], .string("hoot.state"))
        let rows = await log.tail(); XCTAssertEqual(rows.count, 1)
        let bad = await control.call(name: "hoot.state", arguments: .object([.init("unknown", .string("x"))])); XCTAssertFalse(bad.ok)
        // schema.ts throws Refused('not-permitted') for an unknown argument (schema.test.ts:39 "is refused"),
        // and control.ts records a Refused as outcome "refused" (control.ts:1002-1011).
        XCTAssertEqual(bad.row["outcome"], .string("refused")); XCTAssertEqual(bad.refusal, .notPermitted)
    }
    func testTourGateRefusesBeforeSpendingAndNativeIdentityDefaults() async throws {
        let driving = BackendDeckCoreSecurityTestBox<Bool>(true)
        let p = try policy("sessions.start", tier: .act, run: { _, context in context.noteStarted("s1"); return .init(value: .null) })
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: try temporary()), consent: .init(ask: { _ in false }), policies: [p], budgets: .init(all: .init(limit: 1, windowMilliseconds: 60_000)), driving: { driving.get() })
        let no = await control.call(name: "sessions.start", arguments: .object([])); XCTAssertEqual(no.refusal, .whileDriving)
        driving.set(false); let yes = await control.call(name: "sessions.start", arguments: .object([])); XCTAssertTrue(yes.ok)
        let starter = await control.starterOf(sessionID: "s1"); XCTAssertEqual(starter, "copilot")
        XCTAssertTrue(BackendDeckCoreSecurityCaller.local.actsAsOwner)
        XCTAssertFalse(BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read]).actsAsOwner)
    }
    func testSharedRoutineCancellationStillGivesDistinctCallContexts() async throws {
        let scopes = BackendDeckCoreSecurityTestBox<[BackendMCPCancellation]>([])
        let p = try policy("projects.list", tier: .read, run: { _, context in scopes.edit { $0.append(context.cancellation) }; return .init(value: .null) })
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: temporary()), consent: .init(ask: { _ in false }), policies: [p])
        let options = BackendDeckCoreSecurityCallOptions(cancellation: .init())
        async let first = control.call(name: "projects.list", arguments: .object([]), options: options)
        async let second = control.call(name: "projects.list", arguments: .object([]), options: options)
        let (one, two) = await (first, second); XCTAssertTrue(one.ok); XCTAssertTrue(two.ok)
        let values = scopes.get(); XCTAssertEqual(values.count, 2)
        if values.count == 2 { XCTAssertNotEqual(ObjectIdentifier(values[0]), ObjectIdentifier(values[1])) }
    }
}
