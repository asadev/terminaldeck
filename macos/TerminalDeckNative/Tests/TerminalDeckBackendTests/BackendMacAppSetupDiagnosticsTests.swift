import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendMacAppSetupDiagnosticsTests: XCTestCase {
    private func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
    struct Source: BackendMacAppSetupDiagnosticSource {
        let lines: [String]
        init(lines: [String] = []) { self.lines = lines }
        func about() async throws -> NativeRPCValue { BackendMacAppSetupDiagnostics.aboutInfo(version: "9.9.9", arch: "arm64", packaged: false) }
        func runtime() async throws -> NativeRPCValue { .object([.init("locale", .string("en-GB")), .init("uptimeSeconds", .number(12)), .init("system", .object([.init("os", .string("Darwin")), .init("release", .string("26")), .init("arch", .string("arm64")), .init("memoryTotalMb", .number(8192)), .init("memoryFreeMb", .number(2048)), .init("processRssMb", .number(50))]))]) }
        func logStatus() async throws -> NativeRPCValue { .object([.init("dir", .string("/test/logs")), .init("file", .string("/test/logs/main.log")), .init("bytes", .number(42))]) }
        func logTail(_ count: Int) async throws -> [String] { Array(lines.suffix(count)) }
        func prerequisites() async throws -> NativeRPCValue { .object([.init("tools", .array([]))]) }
        func loginPath() async throws -> String { "/opt/homebrew/bin:/usr/bin:/Users/testuser/.local/bin" }
        func paths() async throws -> NativeRPCValue { .object([.init("userData", .string("/test/state")), .init("logs", .string("/test/logs")), .init("state", .string("/test/state/state.json")), .init("home", .string("/Users/testuser"))]) }
        func preferences() async throws -> NativeRPCValue { .object([.init("theme", .string("dark")), .init("nested", .object([.init("value", .bool(true))]))]) }
        func environment() async throws -> [String: String] { ["PATH": "/usr/bin", "SHELL": "/bin/zsh", "MY_API_TOKEN": "swordfish99xyz"] }
    }
    private func ipc() -> NativeRPCValue { BackendMacAppSetupDiagnostics.ipcInfo(invoke: [], send: [], instrumented: true) }
    private func collect(_ lines: [String] = []) async throws -> NativeRPCValue { try await BackendMacAppSetupDiagnostics.collect(source: Source(lines: lines), ipc: ipc(), includeClis: false, redaction: .init(home: "/Users/testuser", username: "testuser"), now: 0) }
    func testGroupsChannelsByModule() { let modules = BackendMacAppSetupDiagnostics.groupChannels(["git:status", "git:diff", "cost:project", "brand:get"]); XCTAssertEqual(modules.compactMap { $0["name"].string }, ["brand", "cost", "git"]); XCTAssertEqual(modules[2]["channels"], .array([.string("git:diff"), .string("git:status")])) }
    func testReadsInvokeAndSendRegisteredChannels() async throws { let registry = NativeChannelRegistry(); try await registry.register("git:status", ownerID: "test") { _, _ in .null }; let subscription = try await registry.onSend("session:write", ownerID: "test") { _, _ in }; let result = BackendMacAppSetupDiagnostics.ipcInfo(invoke: await registry.channels(), send: await registry.sends(), instrumented: false); XCTAssertEqual(result["invokeChannels"], .number(1)); XCTAssertEqual(result["sendChannels"], .number(1)); XCTAssertEqual(result["modules"].elements!.compactMap { $0["name"].string }, ["git", "session"]); await subscription.cancelAndWait() }
    final class Clock: @unchecked Sendable { private let lock = NSLock(); private var value = 0.0; func tick() -> Double { lock.lock(); defer { lock.unlock() }; value += 0.125; return value } }
    private func metrics(_ clock: Clock = Clock()) -> BackendMacAppSetupIPCMetrics { .init(now: { 1000 }, monotonic: { clock.tick() }, redaction: .init(home: "/test/home", username: "test"), logFailure: { _, _ in throw NativeRPCError(code: "test", message: "full disk") }) }
    func testTimesEarlyAndLateHandlersOnceAndPreservesFailure() async throws {
        let registry = NativeChannelRegistry(), metrics = metrics(); try await registry.register("early:ok", ownerID: "test") { _, _ in .string("fine") }; await metrics.activate(sharedDispatcherUsesThisObserver: true); await metrics.activate(sharedDispatcherUsesThisObserver: true)
        let dispatcher = BackendMacAppSetupDiagnosticsDispatcher(existing: .init(registry: registry), metrics: metrics)
        try await registry.register("late:boom", ownerID: "test") { _, _ in throw NativeRPCError(code: "test", message: "exploded with ghp_" + "16C7e42F292c6912E7710c838347Ae178B4a") }
        await metrics.clear(); let answer = try await dispatcher.invoke(channel: "early:ok", arguments: [.string("argument-private")], context: .init(caller: .nativeApp, ownerID: "test")); XCTAssertEqual(answer, .string("fine"))
        do { _ = try await dispatcher.invoke(channel: "late:boom", arguments: [], context: .init(caller: .nativeApp, ownerID: "test")); XCTFail("original error must survive") } catch { XCTAssertTrue(error.localizedDescription.contains("exploded")) }
        let calls = await metrics.recent(); XCTAssertEqual(calls.compactMap { $0["channel"].string }, ["early:ok", "late:boom"]); XCTAssertEqual(calls[0]["ok"], .bool(true)); XCTAssertGreaterThanOrEqual(calls[0]["ms"].number!, 0); XCTAssertEqual(calls[1]["ok"], .bool(false)); XCTAssertFalse(calls[1]["error"].string!.contains("ghp_16C7")); XCTAssertFalse(NativeRPCValue.array(calls).compact.contains("argument-private")); XCTAssertFalse(NativeRPCValue.array(calls).compact.contains("fine"))
    }
    func testNativeSendListenerKeepsOriginalRemovalIdentity() async throws { let registry = NativeChannelRegistry(), subscription = try await registry.onSend("session:write", ownerID: "test") { _, _ in }; let before = await registry.hasSend("session:write"); XCTAssertTrue(before); await subscription.cancelAndWait(); let after = await registry.hasSend("session:write"); XCTAssertFalse(after) }
    actor Subscriber: BackendMacAppSetupDiagnosticSubscriber {
        var observers: [UUID: @Sendable () async -> Void] = [:], throwsOnSend = false
        func destroyed() async throws -> Bool { false }
        func send(_ record: NativeRPCValue) async throws { if throwsOnSend { throw NativeRPCError(code: "test", message: "window gone") } }
        func observeDestroyed(_ callback: @escaping @Sendable () async -> Void) async throws -> @Sendable () async throws -> Void { let id = UUID(); observers[id] = callback; return { await self.remove(id) } }
        func remove(_ id: UUID) { observers[id] = nil }
        func observerCount() -> Int { observers.count }
        func makeBroken() { throwsOnSend = true }
    }
    func testSubscribeUnsubscribeDoesNotAccumulateDestroyedListeners() async throws { let metrics = metrics(), client = Subscriber(); for _ in 0..<20 { _ = try await metrics.subscribe("window", client: client); await metrics.unsubscribe("window") }; let count = await client.observerCount(); XCTAssertEqual(count, 0) }
    func testCallerCannotOverrideRedactionOrRegistry() async throws { let options = BackendMacAppSetupDiagnostics.requestOptions(o([("includeClis", .bool(false)), ("redaction", o([("extraSecrets", .array([]))])), ("ipcMain", o([("evil", .bool(true))]))])); let result = try await BackendMacAppSetupDiagnostics.collect(source: Source(lines: ["GITHUB_TOKEN=ghp_" + "16C7e42F292c6912E7710c838347Ae178B4a"]), ipc: ipc(), includeClis: options.includeClis, logLines: options.logLines, redaction: .init(), now: 0); XCTAssertFalse(result.compact.contains("ghp_16C7e42F292c6912E7710c838347Ae178B4a")) }
    func testRequestedLogTailIsBoundedAndNullMeansDefault() async throws {
        let source = Source(lines: (0..<400).map { "line \($0)" })
        for value in [NativeRPCValue.number(0), .number(-5), .number(.nan), .null] { let options = BackendMacAppSetupDiagnostics.requestOptions(o([("includeClis", .bool(false)), ("logLines", value)])); let bundle = try await BackendMacAppSetupDiagnostics.collect(source: source, ipc: ipc(), includeClis: options.includeClis, logLines: options.logLines, redaction: .init(), now: 0); XCTAssertGreaterThan(bundle["log"]["lines"].elements!.count, 0); XCTAssertLessThanOrEqual(bundle["log"]["lines"].elements!.count, 400) }
        XCTAssertEqual(BackendMacAppSetupDiagnostics.requestOptions(o([("logLines", .number(7))])).logLines, 7); XCTAssertEqual(BackendMacAppSetupDiagnostics.requestOptions(o([])).logLines, 200); XCTAssertEqual(BackendMacAppSetupDiagnostics.requestOptions(o([("logLines", .null)])).logLines, 200); XCTAssertEqual(BackendMacAppSetupDiagnostics.requestOptions(.string("nonsense")).logLines, 200); XCTAssertEqual(BackendMacAppSetupDiagnostics.requestOptions(o([("logLines", .number(99999))])).logLines, 2000)
    }
    func testBundleRedactsLogTailAndHome() async throws { let result = try await collect(["request authorization=sk-ant-" + "api03-ZzZzKmQnR3tVzWyXsAbCdEfGh", "read /Users/testuser/Projects/terminaldeck/src/main/index.ts"]); XCTAssertFalse(result.compact.contains("sk-ant-api03-ZzZzKmQnR3tVzWyXsAbCdEfGh")); XCTAssertFalse(result.compact.contains("/Users/testuser")); XCTAssertEqual(result["log"]["lines"].elements!.count, 2); XCTAssertGreaterThan(result["redaction"]["count"].number!, 0) }
    func testBundleReportsSecretNamesOnlyAndSplitsPath() async throws { let result = try await collect(), environment = result["environment"]; XCTAssertTrue(environment["path"].elements!.contains(.string("/opt/homebrew/bin"))); XCTAssertFalse(environment["path"].compact.contains("/Users/testuser")); XCTAssertEqual(environment["secretsPresent"], .array([.string("MY_API_TOKEN")])); XCTAssertFalse(environment.compact.contains("swordfish99xyz")); XCTAssertFalse(environment["secretsPresent"].compact.contains("=")) }
    func testNativeBundleReportsActualVersionPathsAndRuntimeRetirement() async throws { let result = try await collect(); XCTAssertEqual(result["app"]["version"], .string("9.9.9")); XCTAssertEqual(result["app"]["electron"], .string("n/a")); XCTAssertEqual(result["app"]["node"], .string("n/a")); XCTAssertFalse(result["paths"]["userData"].string!.isEmpty); XCTAssertGreaterThan(result["system"]["memoryTotalMb"].number!, 0) }
    func testFormattedBundleLeaksNothingAndRetainsSections() async throws { let result = try await collect(["token=ghp_" + "16C7e42F292c6912E7710c838347Ae178B4a"]), text = BackendMacAppSetupDiagnostics.format(result); XCTAssertFalse(text.contains("ghp_16C7")); XCTAssertTrue(text.contains("# Terminal Deck diagnostics")); XCTAssertTrue(text.contains("## Paths")); XCTAssertTrue(text.contains("## Log")); XCTAssertTrue(text.contains("\"value\":true")) }
    func testPOSIXPathSplitsDirectories() { XCTAssertEqual(BackendMacAppSetupDiagnostics.pathEntries("/opt/homebrew/bin:/usr/bin"), ["/opt/homebrew/bin", "/usr/bin"]) }
    func testTrailingEmptyPathEntryIsDropped() { XCTAssertEqual(BackendMacAppSetupDiagnostics.pathEntries("/usr/bin:"), ["/usr/bin"]) }
    func testMacShellNamesMeasuredLoginShell() { XCTAssertEqual(BackendMacAppSetupDiagnostics.shellName(["SHELL": "/bin/zsh"]), "/bin/zsh") }
    func testMissingPOSIXShellIsNotInvented() { XCTAssertEqual(BackendMacAppSetupDiagnostics.shellName([:]), "") }
    func testMetricsBoundedRingIgnoresOwnReadsAndClearPreservesSequence() async { let metrics = metrics(); await metrics.activate(sharedDispatcherUsesThisObserver: true); for index in 0..<501 { let start = await metrics.started("work:\(index)"); await metrics.finish("work:\(index)", kind: "invoke", started: start) }; let before = await metrics.recent(); XCTAssertEqual(before.count, 500); XCTAssertEqual(before[0]["seq"], .number(2)); let debug = await metrics.started("debug:ipc-log"), log = await metrics.started("log:recent"); XCTAssertNil(debug); XCTAssertNil(log); await metrics.clear(); let start = await metrics.started("work:last"); await metrics.finish("work:last", kind: "invoke", started: start); let after = await metrics.recent(); XCTAssertEqual(after[0]["seq"], .number(502)) }
    func testBrokenSubscriberCannotTurnSuccessfulCallIntoFailure() async throws { let metrics = metrics(), client = Subscriber(); await metrics.activate(sharedDispatcherUsesThisObserver: true); _ = try await metrics.subscribe("window", client: client); await client.makeBroken(); let start = await metrics.started("good:call"); await metrics.finish("good:call", kind: "invoke", started: start); let calls = await metrics.recent(), count = await metrics.subscriberCount(); XCTAssertEqual(calls[0]["ok"], .bool(true)); XCTAssertEqual(count, 0) }
}

extension BackendMacAppSetupDiagnosticsTests {
    actor DelayedSubscriber: BackendMacAppSetupDiagnosticSubscriber {
        var callback: (@Sendable () async -> Void)?
        var observerCount = 0
        private var sendEntered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var sendWaiter: CheckedContinuation<Void, any Error>?
        func destroyed() async throws -> Bool { false }
        func send(_ record: NativeRPCValue) async throws {
            sendEntered = true; enteredWaiter?.resume(); enteredWaiter = nil
            try await withCheckedThrowingContinuation { sendWaiter = $0 }
        }
        func observeDestroyed(_ callback: @escaping @Sendable () async -> Void) async throws -> @Sendable () async throws -> Void {
            self.callback = callback; observerCount += 1
            return { await self.release() }
        }
        func release() { observerCount -= 1 }
        func savedDestroy() -> (@Sendable () async -> Void)? { callback }
        func waitForSend() async { if sendEntered { return }; await withCheckedContinuation { enteredWaiter = $0 } }
        func failSend() { sendWaiter?.resume(throwing: NativeRPCError(code: "test", message: "old window disappeared")); sendWaiter = nil }
    }
    func testLateOldDestroyCallbackCannotRemoveReplacementSubscriber() async throws {
        let metrics = metrics(), old = DelayedSubscriber(), replacement = Subscriber()
        _ = try await metrics.subscribe("same-owner", client: old)
        let destroy = await old.savedDestroy()
        await metrics.unsubscribe("same-owner")
        _ = try await metrics.subscribe("same-owner", client: replacement)
        await destroy?()
        let subscriptions = await metrics.subscriberCount(), observers = await replacement.observerCount()
        XCTAssertEqual(subscriptions, 1); XCTAssertEqual(observers, 1)
        await metrics.unsubscribe("same-owner")
    }
    func testDelayedOldSendFailureCannotRemoveReplacementSubscriber() async throws {
        let metrics = metrics(), old = DelayedSubscriber(), replacement = Subscriber()
        await metrics.activate(sharedDispatcherUsesThisObserver: true)
        _ = try await metrics.subscribe("same-owner", client: old)
        let start = await metrics.started("work:call")
        let finished = Task { await metrics.finish("work:call", kind: "invoke", started: start) }
        await old.waitForSend()
        await metrics.unsubscribe("same-owner")
        _ = try await metrics.subscribe("same-owner", client: replacement)
        await old.failSend(); await finished.value
        let subscriptions = await metrics.subscriberCount(), observers = await replacement.observerCount()
        XCTAssertEqual(subscriptions, 1); XCTAssertEqual(observers, 1)
        await metrics.unsubscribe("same-owner")
    }
}
