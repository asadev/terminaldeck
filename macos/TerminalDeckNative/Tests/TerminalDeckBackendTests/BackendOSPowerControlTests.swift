import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendOSFakePowerCommands: BackendOSCommandRunning {
    var calls = 0, writes = 0
    var on = false
    let acceptsWrite: Bool
    init(acceptsWrite: Bool) { self.acceptsWrite = acceptsWrite }
    func counts() -> (Int, Int) { (calls, writes) }
    func run(command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        calls += 1
        var output = ""
        if command == "/usr/bin/osascript" { writes += 1; if acceptsWrite { on = arguments.last?.contains("disablesleep 1") == true } }
        else if arguments == ["-g", "batt"] { output = "Now drawing from 'AC Power'" }
        else if command == "/usr/bin/pmset" { output = "SleepDisabled \(on ? 1 : 0)" }
        return BackendGitOutcome(ok: true, stdout: output, stderr: "", missing: false, exitCode: 0, timedOut: false)
    }
}
private actor BackendOSFakeAssertionOwner {
    var starts = 0, stops = 0, held = false
    func start() -> Int { starts += 1; held = true; return 91 }
    func isHeld(_ id: Int) -> Bool { id == 91 && held }
    func stop(_ id: Int) { if id == 91 { stops += 1; held = false } }
    func counts() -> (Int, Int) { (starts, stops) }
    nonisolated func bindings() -> BackendOSPowerBindings { .init(startIdleBlocker: { await self.start() }, isIdleBlockerStarted: { await self.isHeld($0) }, stopIdleBlocker: { await self.stop($0) }, observePower: { _ in { } }, notify: { _, _ in }) }
}
final class BackendOSPowerControlTests: XCTestCase {
    func testConstructionIsInertAndStopDoesNotRewriteSystemSwitch() async throws {
        let commands = BackendOSFakePowerCommands(acceptsWrite: true), assertions = BackendOSFakeAssertionOwner()
        let control = BackendOSPowerControl(power: assertions.bindings(), executor: commands, home: "/fixture-home", authorizeChange: { _ in }, push: { _, _ in })
        let before = await commands.counts(), beforeAssertions = await assertions.counts()
        XCTAssertEqual(before.0, 0); XCTAssertEqual(beforeAssertions.0, 0)
        try await control.start()
        let state = try await control.refresh()
        XCTAssertEqual(state["idleBlocked"].bool, true); XCTAssertEqual(state["on"].bool, false)
        await control.stop()
        let after = await commands.counts(), afterAssertions = await assertions.counts()
        XCTAssertEqual(after.1, 0); XCTAssertEqual(afterAssertions.0, 1); XCTAssertEqual(afterAssertions.1, 1)
    }
    func testCommandExitZeroRequiresActualOSReadback() async throws {
        let commands = BackendOSFakePowerCommands(acceptsWrite: false), assertions = BackendOSFakeAssertionOwner()
        let control = BackendOSPowerControl(power: assertions.bindings(), executor: commands, home: "/fixture-home", authorizeChange: { _ in }, push: { _, _ in })
        let answer = try await control.set(on: true, context: NativeRPCContext(caller: .nativeApp, ownerID: "fixture"))
        XCTAssertEqual(answer["outcome"].string, "failed")
        XCTAssertEqual(answer["state"]["on"].bool, false)
        let counts = await commands.counts(); XCTAssertEqual(counts.1, 1)
    }
    func testGuestCannotTriggerAdministratorDialog() async throws {
        let commands = BackendOSFakePowerCommands(acceptsWrite: true), assertions = BackendOSFakeAssertionOwner()
        let control = BackendOSPowerControl(power: assertions.bindings(), executor: commands, home: "/fixture-home", authorizeChange: { _ in }, push: { _, _ in })
        do { _ = try await control.set(on: true, context: NativeRPCContext(caller: .pairedDevice, ownerID: "guest")); XCTFail("A guest cannot change system power") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
        let counts = await commands.counts(); XCTAssertEqual(counts.0, 0)
    }
}
