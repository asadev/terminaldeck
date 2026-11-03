import Foundation
import XCTest
@preconcurrency import JavaScriptCore
@testable import TerminalDeckBackend

private final class BackendJSCoreRuntimeTestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func record(_ value: String) { lock.withLock { storage.append(value) } }
    var events: [String] { lock.withLock { storage } }
}
private struct BackendJSCoreRuntimeTestBootstrap: BackendJSCoreRuntimeBootstrap {
    let probe: BackendJSCoreRuntimeTestProbe
    func install(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) throws {
        probe.record(Thread.isMainThread ? "install-main" : "install-wrong-thread")
        context.evaluateScript("var retained = 41;")
        bridge.setInputHandlers(data: { data in
            probe.record(Thread.isMainThread ? "input-main:" + String(decoding: data, as: UTF8.self) : "input-wrong-thread")
            context.evaluateScript("retained += 1;")
        }, end: { probe.record("end-main") })
        let cancelled = bridge.schedule(delayMS: 1, repeatMS: nil) { probe.record("cancelled-timer-ran") }
        bridge.cancelTimer(cancelled)
        _ = bridge.schedule(delayMS: 1, repeatMS: nil) { probe.record(Thread.isMainThread ? "timer-main" : "timer-wrong-thread") }
    }
    func loadEntry(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) throws {
        probe.record("load:" + String(context.evaluateScript("retained + 1")?.toInt32() ?? 0))
    }
    func shutdown(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) { probe.record("shutdown-main") }
}
private struct BackendJSCoreRuntimeTimerLimitBootstrap: BackendJSCoreRuntimeBootstrap {
    let probe: BackendJSCoreRuntimeTestProbe
    func install(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) throws {
        // Calls the native bridge directly, never the JS setTimeout shim.
        var first = 0, accepted = 0
        for _ in 0..<BackendJSCoreRuntimeLimits.maximumTimers {
            let id = bridge.schedule(delayMS: 60_000, repeatMS: nil, callback: {})
            if first == 0 { first = id }
            if id != 0 { accepted += 1 }
        }
        probe.record("accepted:\(accepted)")
        probe.record("overflow:\(bridge.schedule(delayMS: 60_000, repeatMS: nil, callback: {}))")
        bridge.cancelTimer(first)
        let replacement = bridge.schedule(delayMS: 60_000, repeatMS: nil, callback: {})
        probe.record(replacement == 0 ? "replacement-refused" : "replacement-accepted")
        probe.record("overflow-after-replacement:\(bridge.schedule(delayMS: 60_000, repeatMS: 60_000, callback: {}))")
    }
    func loadEntry(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) throws { _ = context.evaluateScript("1 + 1") }
    func shutdown(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) {}
}
private struct BackendJSCoreRuntimeThrowingBootstrap: BackendJSCoreRuntimeBootstrap {
    func install(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) throws { context.evaluateScript("throw new Error('uncaught-fixture');") }
    func loadEntry(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) throws { XCTFail("Uncaught install exception must refuse before loading") }
    func shutdown(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration, bridge: BackendJSCoreRuntimeBridge) {}
}
final class BackendJSCoreRuntimeTests: XCTestCase {
    private func pumpOwnerRunLoop() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
    private func configuration() throws -> BackendJSCoreRuntimeConfiguration {
        try .init(entryURL: URL(fileURLWithPath: "/synthetic/plugin/main.js"), folderURL: URL(fileURLWithPath: "/synthetic/plugin"),
            dataURL: URL(fileURLWithPath: "/synthetic/data"), environment: ["LANG": "en_US.UTF-8", "GH_TOKEN": "synthetic-secret", "NODE_OPTIONS": "synthetic-options"])
    }
    func testRuntimeConfigurationPreservesOnlyComposedEnvironmentAndRejectsEscape() throws {
        let config = try configuration()
        XCTAssertEqual(config.environment["HOME"], "/synthetic/data"); XCTAssertEqual(config.environment["TMPDIR"], "/synthetic/data/tmp")
        XCTAssertEqual(config.environment["LANG"], "en_US.UTF-8"); XCTAssertNil(config.environment["GH_TOKEN"]); XCTAssertNil(config.environment["NODE_OPTIONS"])
        XCTAssertNil(config.environment["ELECTRON_RUN_AS_NODE"])
        XCTAssertThrowsError(try BackendJSCoreRuntimeConfiguration(entryURL: URL(fileURLWithPath: "/outside/main.js"), folderURL: config.folderURL, dataURL: config.dataURL, environment: [:]))
        XCTAssertThrowsError(try BackendJSCoreHelperRunner.configuration(arguments: ["helper"], environment: [:], cwd: "/synthetic/plugin"))
        XCTAssertThrowsError(try BackendJSCoreHelperRunner.configuration(arguments: ["helper", "/synthetic/plugin/main.js", "extra"], environment: ["HOME": "/synthetic/data"], cwd: "/synthetic/plugin"))
    }
    func testSourceWireConstantsAndByteFramingAtExactBoundary() throws {
        XCTAssertEqual(BackendJSCoreRuntimeLimits.handshakeMilliseconds, 10_000)
        XCTAssertEqual(BackendJSCoreRuntimeLimits.requestMilliseconds, 30_000)
        XCTAssertEqual(BackendJSCoreRuntimeLimits.messageBytes, 256 * 1024)
        XCTAssertEqual(BackendJSCoreRuntimeLimits.incomingRequests, 8)
        XCTAssertEqual(BackendJSCoreRuntimeLimits.shutdownMilliseconds, 1000)
        XCTAssertEqual(BackendJSCoreRuntimeLimits.maximumTimers, 1024)
        var budget = BackendJSCoreTransportLineBudget(maximumBytes: 64)
        try budget.accept(Data(repeating: 120, count: 64)); try budget.accept(Data([10]))
        try budget.accept(Data(repeating: 120, count: 64))
        XCTAssertThrowsError(try budget.accept(Data([120])))
        var multiple = BackendJSCoreTransportLineBudget(maximumBytes: 64)
        try multiple.accept(Data((String(repeating: "é", count: 32) + "\n" + String(repeating: "é", count: 32) + "\n").utf8))
    }
    @MainActor func testVMOwnerThreadInputEOFAndTimersShareRunLoopAndShutdownIsOnce() async throws {
        let probe = BackendJSCoreRuntimeTestProbe()
        let runtime = try BackendJSCoreRuntimeVM(configuration: configuration(), bootstrap: BackendJSCoreRuntimeTestBootstrap(probe: probe), output: { _ in }, stderr: { _ in }, exit: { _ in })
        try runtime.start()
        runtime.receive(Data("line\n".utf8)); runtime.endInput()
        pumpOwnerRunLoop()
        runtime.shutdown(); runtime.shutdown()
        XCTAssertEqual(probe.events.first, "install-main"); XCTAssertTrue(probe.events.contains("load:42"))
        XCTAssertTrue(probe.events.contains("input-main:line\n")); XCTAssertTrue(probe.events.contains("end-main")); XCTAssertTrue(probe.events.contains("timer-main"))
        XCTAssertFalse(probe.events.contains("cancelled-timer-ran")); XCTAssertEqual(probe.events.filter { $0 == "shutdown-main" }.count, 1)
        XCTAssertThrowsError(try runtime.start())
    }
    @MainActor func testUncaughtExceptionAndMissingBootstrapAreExplicitFailures() async throws {
        let runtime = try BackendJSCoreRuntimeVM(configuration: configuration(), bootstrap: BackendJSCoreRuntimeThrowingBootstrap(), output: { _ in }, stderr: { _ in }, exit: { _ in })
        XCTAssertThrowsError(try runtime.start()) { XCTAssertTrue($0.localizedDescription.contains("uncaught-fixture")) }
        let missing = try BackendJSCoreRuntimeVM(configuration: configuration(), bootstrap: BackendJSCoreRuntimeUnavailableBootstrap(), output: { _ in }, stderr: { _ in }, exit: { _ in })
        XCTAssertThrowsError(try missing.start()) { XCTAssertTrue($0.localizedDescription.contains("compatibility layer is unavailable")) }
    }
    @MainActor func testQueueOverflowHardExitDoesNotWaitForTheVMOrDiagnosticWriter() async throws {
        let probe = BackendJSCoreRuntimeTestProbe()
        let runtime = try BackendJSCoreRuntimeVM(configuration: configuration(), bootstrap: BackendJSCoreRuntimeTestBootstrap(probe: probe),
            output: { _ in XCTFail("Input overflow must not write stdout") },
            stderr: { _ in XCTFail("Hard exit must not wait for a potentially blocked diagnostic pipe") },
            exit: { probe.record("exit:\($0)") })
        runtime.receive(Data(repeating: 120, count: BackendJSCoreRuntimeLimits.queuedInputBytes + 1))
        XCTAssertEqual(probe.events, ["exit:1"])
        runtime.shutdown()
    }
    @MainActor func testNativeTimerOwnerRejectsBeyond1024AndCancellationReopensOneSlot() async throws {
        let probe = BackendJSCoreRuntimeTestProbe()
        let runtime = try BackendJSCoreRuntimeVM(configuration: configuration(), bootstrap: BackendJSCoreRuntimeTimerLimitBootstrap(probe: probe),
            output: { _ in }, stderr: { _ in }, exit: { _ in })
        try runtime.start()
        XCTAssertEqual(probe.events, ["accepted:1024", "overflow:0", "replacement-accepted", "overflow-after-replacement:0"])
        runtime.shutdown()
    }
    func testMissingHelperCannotFallBackToNode() throws {
        let factory = try BackendJSCoreTransportFactory(helperExecutable: URL(fileURLWithPath: "/synthetic/missing/TerminalDeckJSCoreHelper"))
        XCTAssertThrowsError(try factory.runtimePath())
        XCTAssertThrowsError(try BackendJSCoreTransportFactory(helperExecutable: URL(string: "https://example.invalid/helper")!))
    }
}
