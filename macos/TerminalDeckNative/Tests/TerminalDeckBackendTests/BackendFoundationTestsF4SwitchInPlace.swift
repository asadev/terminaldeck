import Foundation
import XCTest
@testable import TerminalDeckBackend

/// Port of src/main/account-vault/switch-in-place.test.ts against BackendAccountSwitchInPlace,
/// in a fresh temporary folder, with injected seat/keychain/clock (no real keychain, no sleeping).
final class BackendFoundationTestsF4SwitchInPlace: XCTestCase, @unchecked Sendable {
    private typealias S = BackendAccountSwitchInPlace
    private var dir = ""
    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tdip-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        dir = url.path
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }
    private func path(_ name: String) -> String { (dir as NSString).appendingPathComponent(name) }
    private func mode(_ file: String) throws -> Int { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber).intValue & 0o777 }
    private func mtime(_ file: String) throws -> Date { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date) }
    private func setTime(_ file: String, _ date: Date) throws { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file) }

    // switch-in-place.test.ts:33
    func testCreatesEmptyObjectWhenThereIsNoPlaintextStore() throws {
        XCTAssertEqual(S.nudge(dir), .created)
        XCTAssertEqual(try String(contentsOfFile: path(S.nudgeFile), encoding: .utf8), S.nudgeBody)
        XCTAssertEqual(try mode(path(S.nudgeFile)), 0o600)
    }
    // switch-in-place.test.ts:39
    func testOnlyChangesTheTimeOfOneThatExistsALoginInItIsNeverTouched() throws {
        let file = path(S.nudgeFile), login = "{\"claudeAiOauth\":{\"accessToken\":\"x\"}}"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data(login.utf8), attributes: [.posixPermissions: 0o600]))
        try setTime(file, Date().addingTimeInterval(-60))
        let before = try mtime(file)
        XCTAssertEqual(S.nudge(dir), .touched)
        XCTAssertGreaterThan(try mtime(file), before)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), login)
    }
    // switch-in-place.test.ts:50
    func testTakesBackOnlyAFileThatStillHoldsExactlyWhatWasPutThere() throws {
        let file = path(S.nudgeFile)
        S.nudge(dir)
        XCTAssertTrue(S.clearNudge(file)); XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        try "{\"claudeAiOauth\":{}}".write(toFile: file, atomically: false, encoding: .utf8)
        XCTAssertFalse(S.clearNudge(file)); XCTAssertTrue(FileManager.default.fileExists(atPath: file))
    }
    // switch-in-place.test.ts:62
    func testIsTheCLIsLockInThatFolderWhileItIsFresh() throws {
        XCTAssertFalse(S.refreshInProgress(dir))
        try FileManager.default.createDirectory(atPath: path(S.refreshLock), withIntermediateDirectories: false)
        XCTAssertTrue(S.refreshInProgress(dir))
        try setTime(path(S.refreshLock), Date().addingTimeInterval(-120))
        XCTAssertFalse(S.refreshInProgress(dir))
    }

    private struct World { let deps: S.Dependencies; let order: BackendF4Box<[String]>; let serving: BackendF4Box<String> }
    /// switch-in-place.test.ts `world()`.
    private func world(_ change: (inout S.Dependencies, BackendF4Box<[String]>) -> Void = { _, _ in }) -> World {
        let order = BackendF4Box<[String]>([]), serving = BackendF4Box("a"), clock = BackendF4Box<Double>(1_000_000)
        let directory = dir
        let seat = S.SeatView(launchAccountID: "a", launchDirectory: directory, storeDirectory: directory)
        var deps = S.Dependencies(
            seat: { $0 == "s1" ? seat : nil }, source: { _ in .vault }, adopting: { _, _ in false }, held: { _ in true },
            keep: { _, _, _ in true }, keychain: nil, user: "me",
            retarget: { _, account in order.update { $0.append("retarget:" + account) }; serving.value = account; return true },
            launchDir: { _ in directory }, sha256: { $0 }, now: { clock.value },
            wait: { ms in clock.update { $0 += ms }; order.update { $0.append("wait:\(Int(ms))") } })
        change(&deps, order)
        return World(deps: deps, order: order, serving: serving)
    }
    private let account = S.Account(id: "b", name: "Work", configDir: "/cfg/b")

    // switch-in-place.test.ts:108
    func testRetargetsTheSeatThenNudgesNothingElse() async throws {
        let w = world()
        let result = await S.switchInPlace(sessionID: "s1", account: account, dependencies: w.deps)
        guard case .switched(let nudged, _, let waited) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(nudged, .created); XCTAssertEqual(waited, 0)
        XCTAssertEqual(w.order.value, ["retarget:b"]); XCTAssertEqual(w.serving.value, "b")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(S.nudgeFile)))
    }
    // switch-in-place.test.ts:117
    func testWaitsForARefreshInTheSessionsFolderToFinishBeforeRetargeting() async throws {
        try FileManager.default.createDirectory(atPath: path(S.refreshLock), withIntermediateDirectories: false)
        let polls = BackendF4Box(0), lock = path(S.refreshLock)
        let w = world { deps, order in
            deps.wait = { _ in
                polls.update { $0 += 1 }; order.update { $0.append("wait") }
                if polls.value == 3 { try? FileManager.default.removeItem(atPath: lock) }
            }
        }
        let result = await S.switchInPlace(sessionID: "s1", account: account, dependencies: w.deps)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(w.order.value, ["wait", "wait", "wait", "retarget:b"])
    }
    // switch-in-place.test.ts:132
    func testGoesAheadAfterTheCeilingRatherThanWaitOnALockThatNeverClears() async throws {
        try FileManager.default.createDirectory(atPath: path(S.refreshLock), withIntermediateDirectories: false)
        let w = world()
        let result = await S.switchInPlace(sessionID: "s1", account: account, dependencies: w.deps)
        guard case .switched(_, _, let waited) = result else { return XCTFail("\(result)") }
        XCTAssertGreaterThanOrEqual(waited, S.refreshWaitMilliseconds)
    }
    // switch-in-place.test.ts:140
    func testASessionWithNoSeatIsNotSwitchedInPlace() async {
        let w = world()
        let result = await S.switchInPlace(sessionID: "other", account: account, dependencies: w.deps)
        XCTAssertFalse(result.ok); XCTAssertEqual(w.order.value, [])
    }
    // switch-in-place.test.ts:146
    func testAnAccountMadeBeforeTheVaultIsMovedInFirstFromItsOwnKeychainItem() async {
        let kept = BackendF4Box<[[String?]]>([]), asked = BackendF4Box<[[String]]>([])
        let w = world { deps, order in
            deps.held = { _ in false }; deps.adopting = { _, _ in true }
            deps.keep = { id, _, value in kept.update { $0.append([id, value]) }; order.update { $0.append("kept") }; return true }
            deps.keychain = { argv, _ in asked.update { $0.append(argv) }; return .init(code: 0, stdout: "LOGIN-B\n", stderr: "") }
        }
        let result = await S.switchInPlace(sessionID: "s1", account: account, dependencies: w.deps)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(asked.value.first, ["find-generic-password", "-a", "me", "-w", "-s", "Claude Code-credentials-/cfg/b"])
        XCTAssertEqual(kept.value, [["b", "LOGIN-B"]])
        XCTAssertEqual(w.order.value, ["kept", "retarget:b"])
    }
    // switch-in-place.test.ts:168
    func testRefusesAndLeavesTheSessionAloneWhenThatAccountHasNoLogin() async {
        let w = world { deps, _ in
            deps.held = { _ in false }; deps.adopting = { _, _ in true }
            deps.keychain = { _, _ in .init(code: 44, stdout: "", stderr: "not found") }
        }
        let result = await S.switchInPlace(sessionID: "s1", account: account, dependencies: w.deps)
        guard case .refused(let why) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(why.contains("Work is not signed in yet"), why)
        XCTAssertEqual(w.order.value, [])
    }
    // switch-in-place.test.ts:180
    func testChecksALoginTheAgentKeepsExistsWithoutEverAskingForTheSecret() async {
        let asked = BackendF4Box<[[String]]>([])
        let w = world { deps, _ in
            deps.source = { _ in .keychain(directory: nil) }
            deps.keychain = { argv, _ in asked.update { $0.append(argv) }; return .init(code: 0, stdout: "attributes", stderr: "") }
        }
        let result = await S.switchInPlace(sessionID: "s1", account: .init(id: "system", name: "Personal", configDir: "/Users/me/.claude"), dependencies: w.deps)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(asked.value, [["find-generic-password", "-a", "me", "-s", "Claude Code-credentials"]])
    }
    // switch-in-place.test.ts:195
    func testRefusesAnAccountWhoseKeptLoginIsOutOfReach() async {
        let w = world { deps, _ in deps.source = { _ in nil } }
        let result = await S.switchInPlace(sessionID: "s1", account: account, dependencies: w.deps)
        XCTAssertFalse(result.ok); XCTAssertEqual(w.order.value, [])
    }
}
