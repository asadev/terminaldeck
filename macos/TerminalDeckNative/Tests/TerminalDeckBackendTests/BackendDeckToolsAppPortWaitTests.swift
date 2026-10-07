import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckToolsAppPortManualClock: BackendDeckCoreEventsClock, @unchecked Sendable {
    private let lock = NSLock()
    private struct Timer { let due: Double, run: @Sendable () -> Void }
    private var time = 0.0, timers: [UUID: Timer] = [:], asked: [Double] = []
    private var installed: CheckedContinuation<Void, Never>?
    func now() -> Double { lock.withLock { time } }
    func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let observer = lock.withLock { asked.append(milliseconds); timers[id] = Timer(due: time + milliseconds, run: run); let observer = installed; installed = nil; return observer }
        observer?.resume(); return id
    }
    func cancel(_ handle: UUID) { lock.withLock { timers[handle] = nil } }
    func waitUntilInstalled() async { await withCheckedContinuation { continuation in let ready = lock.withLock { if !asked.isEmpty { return true }; installed = continuation; return false }; if ready { continuation.resume() } } }
    func deadlines() -> [Double] { lock.withLock { asked } }
    func advance(to next: Double) { let callbacks: [@Sendable () -> Void] = lock.withLock { time = next; let due = timers.filter { $0.value.due <= next }; for id in due.keys { timers[id] = nil }; return due.values.map(\.run) }; callbacks.forEach { $0() } }
    func remaining() -> Int { lock.withLock { timers.count } }
}
actor BackendDeckToolsAppPortDeferredValue {
    private var waiter: CheckedContinuation<NativeRPCValue, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var started = false
    func wait() async -> NativeRPCValue { started = true; entered?.resume(); entered = nil; return await withCheckedContinuation { waiter = $0 } }
    func waitUntilEntered() async { if started { return }; await withCheckedContinuation { entered = $0 } }
    func resolve(_ value: NativeRPCValue) { waiter?.resume(returning: value); waiter = nil }
}
actor BackendDeckToolsAppPortFixedFake: BackendDeckToolsAppFixedService {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    let deferred: BackendDeckToolsAppPortDeferredValue?
    private var trace: [NativeRPCValue] = []
    init(deferred: BackendDeckToolsAppPortDeferredValue? = nil) { self.deferred = deferred }
    nonisolated static var resultsValue: NativeRPCValue { try! F.json(#"{"runId":"r1","at":"2026-10-04T00:00:00.000Z","durationMs":3000,"verdict":"differences","headline":"1 difference nobody asked for.","against":"1.0.0","checked":"1.0.0 with uncommitted changes","differences":[{"id":"f-1","title":"The total changed.","needsPerson":true,"needsPersonWhy":"It touches money.","count":1,"changes":[{"what":"What it printed.","before":"Total: 10.00","after":"Total: 10.0","kind":"changed"}],"more":0}],"unchanged":"Everything else it looked at — 11 things — is unchanged.","notChecked":null,"unsteady":0,"detail":"The engine’s paragraph.","gaps":[],"pictures":{"f-1":[{"journey":"greet --help","before":"data:image/png;base64,AAAA","after":"data:image/png;base64,BBBB"}]}}"#) }
    private func record(_ op: String, _ args: [NativeRPCValue] = []) { trace.append(F.object([("op", .string(op)), ("args", .array(args))])) }
    func calls() -> [NativeRPCValue] { trace }
    func status(_ project: String) async throws -> NativeRPCValue { record("status", [.string(project)]); return try F.json(#"{"projectPath":"/work/api","available":true,"unavailable":null,"setUp":true,"configFile":"staysfixed.config.js","git":true,"agents":true,"guards":[{"name":"the total keeps its pennies","because":"It printed 10.0 once."}],"guardProblem":null,"reference":{"name":"1.0.0","setAt":"2026-10-01T00:00:00Z","forced":false},"last":null,"running":null}"#) }
    func readiness(_ project: String, refresh: Bool) async throws -> NativeRPCValue { throw BackendDeckToolsAppKit.unavailable("unused fake machine readiness") }
    func setup(_ project: String) async throws -> NativeRPCValue { throw BackendDeckToolsAppKit.unavailable("unused fake fixed setup") }
    func check(_ project: String, by: String) async throws -> NativeRPCValue { record("check", [.string(project), .string(by)]); if let deferred { return await deferred.wait() }; return Self.resultsValue }
    func progress(_ project: String) async throws -> NativeRPCValue? { deferred == nil ? nil : try F.json(#"{"startedAt":1,"step":"Booting 1.0.0.","steps":4,"by":"Hoot"}"#) }
    func stop(_ project: String) async throws -> Bool { true }
    func waitFor(_ project: String, milliseconds: Int) async throws -> NativeRPCValue? { record("waitFor", [.string(project), .number(Double(milliseconds))]); return Self.resultsValue }
    func results(_ project: String, full: Bool) async throws -> NativeRPCValue? { Self.resultsValue }
    func markGood(_ project: String, anyway: Bool) async throws -> NativeRPCValue { record("mark", [.string(project), .bool(anyway)]); return try F.json(#"{"ok":true,"marked":true,"already":false,"refused":null,"refusedFor":null,"summary":"Marked as good."}"#) }
    func setAgents(_ project: String, on: Bool) async throws -> NativeRPCValue { record("agents", [.string(project), .bool(on)]); return F.object([("agents", .bool(on)), ("setUp", .bool(true))]) }
}
@MainActor
final class BackendDeckToolsAppPortFixedTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private func tools(_ fake: BackendDeckToolsAppPortFixedFake, audit: BackendDeckCoreTestPortToolsAudit = .init(), clock: BackendDeckToolsAppPortManualClock = .init()) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppFixed.definitions(service: fake, access: F.access(audit), clock: clock) }
    func testFixedButtonsKeepExactTiers() throws { let defs = try tools(.init()); let expected: [String: BackendMCPTier] = ["fixed.status": .read, "fixed.setup": .alter, "fixed.check": .act, "fixed.results": .read, "fixed.stop": .act, "fixed.mark_good": .alter, "fixed.agents": .alter]; XCTAssertEqual(defs.count, expected.count); for tool in defs { XCTAssertEqual(tool.spec.tier, expected[tool.spec.id]) } }
    func testMarkGoodOwnerQuestionIncludesAcceptedDifferences() async throws { let audit = BackendDeckCoreTestPortToolsAudit(); _ = try await F.call(tools(.init(), audit: audit), "fixed.mark_good", #"{"project":"/work/api","anyway":true}"#); let consent = await audit.consent(); XCTAssertEqual(consent[0]["owner"], .bool(true)); XCTAssertTrue(consent[0]["sentence"].string!.contains("accepting the differences")) }
    func testEveryFixedToolHasDescribeIndexAndExactWireName() throws { for tool in try tools(.init()) { XCTAssertFalse(tool.index?.isEmpty ?? true); XCTAssertEqual(tool.spec.wireName, tool.spec.id.replacingOccurrences(of: ".", with: "_")) } }
    func testUnknownFixedFolderNeverRunsAnything() async throws { let fake = BackendDeckToolsAppPortFixedFake(); F.error(try await F.call(tools(fake), "fixed.check", #"{"project":"/etc"}"#), contains: "not a folder this app has open"); let calls = await fake.calls(); XCTAssertEqual(calls, []) }
    func testFinishedCheckReturnsOnlyDifferencesAndPictureCount() async throws { let fake = BackendDeckToolsAppPortFixedFake(), clock = BackendDeckToolsAppPortManualClock(), value = try F.value(await F.call(tools(fake, clock: clock), "fixed.check", #"{"project":"/work/api","wait":5}"#)), calls = await fake.calls(); XCTAssertEqual(value["verdict"], .string("differences")); XCTAssertEqual(value["differences"].elements![0]["picturesKept"], .number(1)); XCTAssertFalse(value.compact.contains("base64")); XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls[0]["op"], .string("check")); XCTAssertEqual(calls[0]["args"], .array([.string("/work/api"), .string("Hoot")])); XCTAssertEqual(clock.remaining(), 0) }
    func testOutlastingWaitReportsProgressAndKeepsCheckRunning() async throws {
        let deferred = BackendDeckToolsAppPortDeferredValue(), fake = BackendDeckToolsAppPortFixedFake(deferred: deferred), clock = BackendDeckToolsAppPortManualClock(), defs = try tools(fake, clock: clock)
        let call = Task { try await F.call(defs, "fixed.check", #"{"project":"/work/api","wait":0}"#) }
        await clock.waitUntilInstalled(); await deferred.waitUntilEntered(); XCTAssertEqual(clock.deadlines(), [0]); clock.advance(to: 0)
        let value = try F.value(await call.value); XCTAssertEqual(value["running"], .bool(true)); XCTAssertEqual(value["progress"]["step"], .string("Booting 1.0.0.")); XCTAssertTrue(value["next"].string!.contains("fixed.results"))
        await deferred.resolve(BackendDeckToolsAppPortFixedFake.resultsValue)
    }
    func testResultsWaitClampsAtSource120Seconds() async throws { let fake = BackendDeckToolsAppPortFixedFake(); _ = try await F.call(tools(fake), "fixed.results", #"{"project":"/work/api","wait":9999}"#); let calls = await fake.calls(); XCTAssertEqual(calls.first { $0["op"].string == "waitFor" }?["args"].elements?.last, .number(Double(BackendDeckToolsAppFixed.maxCheckWaitSeconds * 1000))) }
    // Original testFixedModelResultCountsPicturesWithoutExposingBytes covers full/summary/null model shaping.
    func testStatusNamesGuardsGoodBuildAndNextCall() async throws { let value = try F.value(await F.call(tools(.init()), "fixed.status", #"{"project":"/work/api"}"#)); XCTAssertEqual(value["setUp"], .bool(true)); XCTAssertEqual(value["guards"].elements![0]["name"], .string("the total keeps its pennies")); XCTAssertEqual(value["guards"].elements![0]["because"], .string("It printed 10.0 once.")); XCTAssertEqual(value["markedGood"]["build"], .string("1.0.0")); XCTAssertEqual(value["next"], .string("fixed.check")) }
    func testAgentsToggleRequiresRealBooleanAndCallsSourceService() async throws { let fake = BackendDeckToolsAppPortFixedFake(), defs = try tools(fake); F.error(try await F.call(defs, "fixed.agents", #"{"project":"/work/api","on":"yes"}"#), contains: "on is required and must be true or false"); _ = try await F.call(defs, "fixed.agents", #"{"project":"/work/api","on":false}"#); let calls = await fake.calls(); XCTAssertEqual(calls[0]["op"], .string("agents")); XCTAssertEqual(calls[0]["args"], .array([.string("/work/api"), .bool(false)])) }
    func testAskedByKeepsAllSourceCallerLabels() { XCTAssertEqual(BackendDeckToolsAppFixed.askedBy(.init(kind: .local)), "Hoot"); XCTAssertEqual(BackendDeckToolsAppFixed.askedBy(.init(kind: .key, keyName: "ChatGPT")), "ChatGPT"); XCTAssertEqual(BackendDeckToolsAppFixed.askedBy(.init(kind: .remote)), "a paired device"); XCTAssertEqual(BackendDeckToolsAppFixed.askedBy(.init(kind: .session)), "an agent session") }
}
actor BackendDeckToolsAppPortGitHubPendingFake: BackendDeckToolsAppGitHubService {
    let deferred = BackendDeckToolsAppPortDeferredValue()
    private var cancelled = false
    func didCancel() -> Bool { cancelled }
    private func unused() -> NativeRPCError { BackendDeckToolsAppKit.unavailable("unused fake GitHub operation") }
    func overview(_ folder: String) async throws -> NativeRPCValue { throw unused() }
    func refresh(_ folder: String) async throws -> NativeRPCValue { throw unused() }
    func repo(_ folder: String) async throws -> NativeRPCValue { throw unused() }
    func clearCache(_ folder: String) async throws { throw unused() }
    func authStatus(_ folder: String) async throws -> NativeRPCValue { throw unused() }
    func connect() async throws -> NativeRPCValue { throw unused() }
    func awaitAuth(_ folder: String) async throws -> NativeRPCValue { await deferred.wait() }
    func cancel(_ folder: String) async throws -> NativeRPCValue { cancelled = true; return .null }
    func disconnect(_ folder: String) async throws -> NativeRPCValue { throw unused() }
}
@MainActor
final class BackendDeckToolsAppPortGitHubWaitTests: XCTestCase {
    func testSignInWaitStopsAtCeilingAndDoesNotCancelFlow() async throws {
        typealias F = BackendDeckCoreTestPortToolsFixture
        let fake = BackendDeckToolsAppPortGitHubPendingFake(), clock = BackendDeckToolsAppPortManualClock(), defs = try BackendDeckToolsAppGitHub.definitions(service: fake, access: F.access(.init()), clock: clock)
        let call = Task { try await F.call(defs, "github.connect", #"{"do":"wait"}"#) }
        await clock.waitUntilInstalled(); await fake.deferred.waitUntilEntered()
        XCTAssertEqual(clock.deadlines(), [Double(BackendDeckToolsAppGitHub.signInWaitMs)])
        clock.advance(to: Double(BackendDeckToolsAppGitHub.signInWaitMs + 1))
        let value = try F.value(await call.value), cancelled = await fake.didCancel()
        XCTAssertEqual(value["finished"], .bool(false)); XCTAssertEqual(value["note"], .string("Not finished yet. The code is still waiting at github.com; call wait again.")); XCTAssertFalse(cancelled)
        await fake.deferred.resolve(.object([.init("connected", .bool(true))]))
    }
}
