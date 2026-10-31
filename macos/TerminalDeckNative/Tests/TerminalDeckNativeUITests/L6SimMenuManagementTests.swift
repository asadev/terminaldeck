import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Records commands; never runs xcrun/adb/avdmanager.
private actor L6SimCommands: BackendAppSessionCommandExecuting {
    struct Call: Sendable, Equatable { let command: String; let args: [String] }
    var calls: [Call] = []
    var fail = false
    var detached = 0
    func setFail() { fail = true }
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String,
             timeoutMilliseconds: Int, maximumBytes: Int) async -> BackendAppSessionCommandResult {
        calls.append(.init(command: command, args: arguments))
        return fail ? .init(stderr: "Stub failure", exitCode: 1) : .init(stdout: "", exitCode: 0)
    }
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws {
        detached += 1
    }
}

/// #108 (L6-SIMMENU, from Codex FIXES's drafted tests): the Simulators menu's
/// management over a stub executor. Nothing touches a real simulator.
final class L6SimMenuManagementTests: XCTestCase {
    private let id = "ios:00000000-0000-0000-0000-000000000108"
    private let udid = "00000000-0000-0000-0000-000000000108"
    private func row(_ deviceID: String, kind: String = "simulator", state: String = "shutdown") -> NativeRPCValue {
        .object([.init("id", .string(deviceID)), .init("kind", .string(kind)), .init("name", .string("Stub iPhone")), .init("state", .string(state))])
    }
    private func service(_ commands: L6SimCommands) -> BackendFIXESDeviceManagement {
        .init(platform: .init(environment: [:], home: "/private/tmp/L6-SIMMENU-tests.noindex/stub-home", executor: commands))
    }
    private func refused(_ work: () async throws -> Void, _ message: String) async {
        do { try await work(); XCTFail(message) } catch {}
    }

    func testRenameUsesSeparateArgvWithoutBoot() async throws {
        let commands = L6SimCommands()
        _ = try await service(commands).perform(.rename, id: id, name: "Stub phone $(not a command)", rows: [row(id)])
        let calls = await commands.calls
        XCTAssertEqual(calls, [.init(command: "xcrun", args: ["simctl", "rename", udid, "Stub phone $(not a command)"])])
    }

    func testResetAndDeleteRequireConfirmation() async {
        let commands = L6SimCommands()
        for action in [BackendFIXESDeviceManagement.Action.reset, .delete] {
            await refused({ _ = try await self.service(commands).perform(action, id: self.id, rows: [self.row(self.id)]) }, "Unconfirmed \(action) ran")
        }
        let calls = await commands.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testRunningEraseShutsDownThenErases() async throws {
        let commands = L6SimCommands()
        _ = try await service(commands).perform(.reset, id: id, confirmed: true, rows: [row(id, state: "ready")])
        let calls = await commands.calls.map(\.args)
        XCTAssertEqual(calls, [["simctl", "shutdown", udid], ["simctl", "erase", udid]])
    }

    func testDeleteRunsSimctlDelete() async throws {
        let commands = L6SimCommands()
        _ = try await service(commands).perform(.delete, id: id, confirmed: true, rows: [row(id)])
        let calls = await commands.calls.map(\.args)
        XCTAssertEqual(calls, [["simctl", "delete", udid]])
    }

    func testUnlistedDeviceAndPhoneOnACableAreRefused() async {
        let commands = L6SimCommands()
        for rows in [[], [row(id, kind: "physical")]] {
            await refused({ _ = try await self.service(commands).perform(.delete, id: self.id, confirmed: true, rows: rows) }, "Unlisted or physical device changed")
        }
        let calls = await commands.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testFolderReadRunsNoCommand() async throws {
        let commands = L6SimCommands()
        let folder = try await service(commands).folder(id, rows: [row(id)])
        XCTAssertTrue(folder.path.hasSuffix("CoreSimulator/Devices/" + udid))
        let calls = await commands.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testFailureIsReportedNotSuccess() async {
        let commands = L6SimCommands(); await commands.setFail()
        do { _ = try await service(commands).perform(.delete, id: id, confirmed: true, rows: [row(id)]); XCTFail("Failed command reported success") }
        catch { XCTAssertEqual(error.localizedDescription, "Stub failure") }
    }

    func testMalformedIDRejectedBeforeAnyCommand() async {
        let commands = L6SimCommands(), invalid = "ios:../../elsewhere"
        await refused({ _ = try await self.service(commands).perform(.delete, id: invalid, confirmed: true, rows: [self.row(invalid)]) }, "Unsafe id accepted")
        let calls = await commands.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testRestartShutsDownThenBootsTheSameSimulator() async throws {
        let commands = L6SimCommands()
        _ = try await service(commands).perform(.restart, id: id, rows: [row(id, state: "ready")])
        let calls = await commands.calls.map(\.args)
        XCTAssertEqual(calls.first, ["simctl", "shutdown", udid])
        XCTAssertEqual(calls.dropFirst().first, ["simctl", "boot", udid])
    }

    func testRestartRefusesAnOffSimulator() async {
        let commands = L6SimCommands()
        await refused({ _ = try await self.service(commands).perform(.restart, id: self.id, rows: [self.row(self.id)]) }, "Off simulator restarted")
        let calls = await commands.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testPresenterRefusesPlainlyWithoutAWindow() async {
        do { try await BackendFIXESDevicePresenter().show(row(id), destination: "tab", sessionID: nil); XCTFail("Shown without a window") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Open Terminal Deck")) }
    }

    func testSimulatorToolFamilyMatchesTheSpec() {
        XCTAssertEqual(BackendFIXESSimulatorMCP.ids, ["simulators.list", "simulators.start", "simulators.shutdown", "simulators.restart",
                                                      "simulators.open", "simulators.rename", "simulators.erase", "simulators.delete"])
        XCTAssertEqual(BackendDeckCoreCatalogueDescribe.areaOf("simulators.erase"), "devices")
    }
}
