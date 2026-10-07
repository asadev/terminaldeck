import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeSessionPolicyTests: XCTestCase {
    private func session(_ id: String = "s", cwd: String = "/work/app") throws -> BackendSessionMeta {
        let raw = NativeRPCValue.object([.init("id", .string(id)), .init("cwd", .string(cwd)), .init("title", .string("app")), .init("provider", .string("shell")), .init("exitCode", .null), .init("createdAt", .number(1)), .init("resumed", .bool(false))])
        return try JSONDecoder().decode(BackendSessionMeta.self, from: raw.encodedJSON())
    }
    func testEqualityAndContainmentHaveDifferentCreateRules() throws {
        XCTAssertTrue(BackendRemoteServeSessionPolicy.sameFolder("/work/app/./", "/work/app"))
        XCTAssertTrue(BackendRemoteServeSessionPolicy.withinFolder("/work/app", "/work/app/child"))
        XCTAssertFalse(BackendRemoteServeSessionPolicy.withinFolder("/work/app", "/work/app-next"))
        XCTAssertFalse(BackendRemoteServeSessionPolicy.sameFolder("/work/App", "/work/app"))
        XCTAssertTrue(BackendRemoteServeSessionPolicy.withinFolder("/", "/etc"))
        let refused = BackendRemoteServeSessionCreate.plan(.init(deviceID: "phone", cwd: "/work/app/child"), offered: ["/work/app"])
        if case .success = refused { XCTFail("Creation must require the exact offered folder") }
    }
    func testNoFolderUsesTheDevicesFirstAndPlainSize() throws {
        let result = BackendRemoteServeSessionCreate.plan(.init(deviceID: "phone", provider: "shell"), offered: ["/work/app", "/work/other"])
        let input = try result.get()
        XCTAssertEqual(input.cwd, "/work/app"); XCTAssertEqual(input.cols, 80); XCTAssertEqual(input.rows, 24)
        XCTAssertEqual(input.deviceID, "phone"); XCTAssertEqual(input.provider, "shell")
        XCTAssertNil(try BackendRemoteServeSessionCreate.plan(.init(deviceID: "phone"), offered: ["/work/app"]).get().provider)
    }
    func testRefusesEmptyAndNeverSubstitutesOrEchoes() {
        let missing = BackendRemoteServeSessionCreate.plan(.init(deviceID: "phone"), offered: [])
        if case .failure(let failure) = missing { XCTAssertEqual(failure.code, "unauthorized"); XCTAssertTrue(failure.message.contains("Choose one in its remote access settings")) } else { XCTFail("Empty means nowhere") }
        for path in ["~/work", ".", "/etc/<script>", "/work/app/../../.ssh"] {
            let result = BackendRemoteServeSessionCreate.plan(.init(deviceID: "phone", cwd: path, provider: "bad-agent"), offered: ["/work/app"])
            if case .failure(let refusal) = result { XCTAssertEqual(refusal.message, "This Mac is not offering that folder to this device. Pick one from the list it sent.") } else { XCTFail("Refused folder was accepted") }
        }
    }
    func testOwnerCanNameAnyAbsoluteButNotRelativeFolder() throws {
        let input = try BackendRemoteServeSessionCreate.plan(.init(deviceID: "owner", cwd: "/not-open"), offered: [], unrestricted: true).get()
        XCTAssertEqual(input.cwd, "/not-open")
        if case .success = BackendRemoteServeSessionCreate.plan(.init(deviceID: "owner", cwd: "relative"), offered: [], unrestricted: true) { XCTFail("Owner still needs an absolute path") }
    }
    func testProviderNamesAreExactAndFolderRefusalWins() {
        for name in ["", "Claude", "claude ", "copilot", "constructor", "__proto__"] { XCTAssertNil(BackendRemoteServeSessionCreate.knownProvider(name)) }
        for name in BackendRemoteServeSessionCreate.providers { XCTAssertEqual(BackendRemoteServeSessionCreate.knownProvider(name), name) }
        if case .failure(let refusal) = BackendRemoteServeSessionCreate.plan(.init(deviceID: "phone", provider: "evil-name"), offered: ["/work/app"]) {
            XCTAssertEqual(refusal.code, "unauthorized"); XCTAssertFalse(refusal.message.contains("evil-name")); XCTAssertTrue(refusal.message.contains("claude, codex, gemini, shell"))
        } else { XCTFail("Unknown provider was accepted") }
    }
    func testConfinementAndAgentFailuresKeepTheirOwnRemedies() {
        let confinement = BackendRemoteServeSessionCreate.refusal(BackendRemoteServeSessionCreate.SpawnFailure.confinement(detail: "sandbox-exec: private stderr"))
        XCTAssertEqual(confinement.code, "unavailable"); XCTAssertTrue(confinement.message.contains("Settings → Remote")); XCTAssertFalse(confinement.message.contains("sandbox-exec"))
        let agent = BackendRemoteServeSessionCreate.refusal(BackendRemoteServeSessionCreate.SpawnFailure.agent(message: "Claude Code is missing."))
        XCTAssertEqual(agent.code, "unauthorized"); XCTAssertEqual(agent.message, "Claude Code is missing. Install it on that Mac, or choose a different one in its settings.")
    }
    func testIncludeFailureCannotTurnARealSpawnIntoARefusal() async throws {
        let meta = try session("new")
        let creator = BackendRemoteServeSessionCreate(folders: { _ in ["/work/app"] }, spawn: { _ in meta }, noteStarted: { _, _ in throw Failure.nope })
        let answer = await creator.create(.init(deviceID: "phone"))
        XCTAssertEqual(answer.session?.id, "new"); XCTAssertEqual(try answer.message().value["session"]["status"], .string("idle"))
    }
    func testHiddenRegistryNeverAgesOutAndThrowsFailClosed() throws {
        let registry = BackendRemoteServeSessionHidden(); registry.hide(""); registry.hide("s")
        XCTAssertFalse(registry.contains("")); XCTAssertTrue(registry.contains("s")); registry.release("s"); XCTAssertFalse(registry.contains("s"))
        let row = try session()
        XCTAssertFalse(BackendRemoteServeSessionPolicy.visible(deviceID: "phone", session: row, hidden: { _ in throw Failure.nope }, reach: nil, shared: nil))
        XCTAssertFalse(BackendRemoteServeSessionPolicy.visible(deviceID: "phone", session: row, hidden: nil, reach: { _ in (false, ["/other"]) }, shared: { _, _ in true }))
        XCTAssertFalse(BackendRemoteServeSessionPolicy.visible(deviceID: "owner", session: row, hidden: nil, reach: { _ in (true, []) }, shared: { _, _ in false }))
        XCTAssertFalse(BackendRemoteServeSessionPolicy.visible(deviceID: "phone", session: row, hidden: nil, reach: nil, shared: { _, _ in throw Failure.nope }))
    }
    func testHiddenFolderPickerUsesCurrentHiddenCwds() throws {
        let registry = BackendRemoteServeSessionHidden(); registry.hide("hidden")
        let rows = [try session("ordinary"), try session("hidden", cwd: "/data/copilot")]
        XCTAssertEqual(BackendRemoteServeSessionPolicy.offeredFolders(["/work/app", "/data/copilot"], sessions: rows, hidden: { registry.contains($0) }), ["/work/app"])
    }
    private enum Failure: Error { case nope }
}
