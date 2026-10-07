import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Request 8 joins: sender authority, hidden-at-spawn ownership, the one raw
/// action writer, the records fence failing open visibly, and shutdown quiesce.
private actor BackendHootJoinFenceDriver: BackendCopilotSessionDriving {
    private(set) var fences: [BackendCopilotSessionFence?] = []
    private var alive: Set<String> = []
    private let refuseFence: Bool
    init(refuseFence: Bool) { self.refuseFence = refuseFence }
    func hasClaude() async throws -> Bool { true }
    func resolveProfile(projectPath: String) async throws -> BackendAccountProfile {
        BackendAccountProfile(id: "system", name: "Default", provider: "claude", configDir: "/synthetic/.claude", system: true, color: "#000000", createdAt: 0, lastUsedAt: nil, loginStore: nil, keptSlots: nil)
    }
    func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?) { ("signed-in", nil, nil) }
    func start(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta {
        fences.append(fence)
        if refuseFence && fence != nil { throw BackendCopilotSessionFenceLost(reason: "The app records fence did not hold writes to its protected log.") }
        let meta = BackendSessionMeta(id: "hoot-\(fences.count)", input: input, spawn: .init(provider: "claude", command: "/bin/echo", args: extraArguments, path: "/bin"), now: Date(timeIntervalSince1970: 1))
        alive.insert(meta.id); return meta
    }
    func isAlive(_ sessionID: String) async -> Bool { alive.contains(sessionID) }
    func stop(_ sessionID: String) async throws { alive.remove(sessionID) }
}
private struct BackendHootJoinHeldRecords: BackendCopilotSessionRecordsProviding {
    let root: URL
    func paths(userData: String) async throws -> BackendCopilotLayerRecords {
        try .init(paths: ["routines", "routine-state.json", "copilot-log", "remote/remote-device-kinds.json", "remote/remote-auth.json", "remote/access-keys.json", "plugin-grants.json"].map { root.appendingPathComponent($0).path })
    }
    func measure(userData: String) async -> BackendCopilotSessionFenceMeasurement { .init(fence: .init(), reason: nil) }
}

final class BackendHootJoinTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendHootJoin-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testSourceAuthorityTrustsOnlyItsOwnNativeSenders() throws {
        let authority = BackendHootJoinSourceAuthority(window: { context in
            guard context.ownerID == BackendCompositionRoot.appOwnerID else { throw NativeRPCError(code: "access-denied", message: "not the window") }
        })
        XCTAssertNotEqual(authority.islandOwnerID, authority.catcherOwnerID)
        XCTAssertEqual(try authority.source(authority.islandContext()), .island)
        XCTAssertEqual(try authority.source(authority.catcherContext()), .catcher)
        XCTAssertEqual(try authority.source(.init(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID)), .window)
        // The same owner strings from any other caller kind are not Hoot's.
        XCTAssertEqual(try authority.source(.init(caller: .page, ownerID: authority.islandOwnerID)), .unrelated)
        XCTAssertEqual(try authority.source(.init(caller: .pairedDevice, ownerID: authority.catcherOwnerID)), .unrelated)
        XCTAssertEqual(try authority.source(.init(caller: .internalEngine, ownerID: BackendCompositionRoot.appOwnerID)), .unrelated)
        XCTAssertEqual(try authority.source(.init(caller: .nativeApp, ownerID: "native-app:hoot-island:guess")), .unrelated)
        let closed = BackendHootJoinSourceAuthority(window: { _ in throw NativeRPCError(code: "access-denied", message: "window closed") })
        XCTAssertEqual(try closed.source(.init(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID)), .unrelated)
        authority.revoke()
        XCTAssertEqual(try authority.source(authority.islandContext()), .unrelated)
        XCTAssertEqual(try authority.source(.init(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID)), .unrelated)
    }

    func testSpawnBoundaryHidesBeforeExposureAndReleasesOnlyItsOwnIDs() {
        let hidden = BackendRemoteServeSessionHidden()
        let boundary = BackendHootJoinSpawnBoundary(hidden: hidden)
        hidden.hide("phone-run")
        boundary.exposureHook("desk-hoot")
        XCTAssertTrue(hidden.contains("desk-hoot")); XCTAssertTrue(boundary.hid("desk-hoot")); XCTAssertFalse(boundary.hid("phone-run"))
        boundary.processReaped("phone-run")
        XCTAssertTrue(hidden.contains("phone-run"), "another owner's hidden run stays hidden")
        boundary.processReaped("desk-hoot")
        XCTAssertFalse(hidden.contains("desk-hoot")); XCTAssertFalse(boundary.hid("desk-hoot"))
        boundary.beforeExposure("")
        XCTAssertFalse(hidden.contains(""))
        boundary.beforeExposure("never-spawned"); boundary.failedBeforeSpawn("never-spawned")
        XCTAssertFalse(hidden.contains("never-spawned"))
    }

    func testHiddenRegisterAddsTheDeskHootAnswerWithoutTurningItIntoARun() {
        let hidden = BackendRemoteServeSessionHidden()
        hidden.hide("phone-run")
        let token = hidden.addPredicate { $0 == "desk-hoot" }
        XCTAssertTrue(hidden.contains("desk-hoot")); XCTAssertTrue(hidden.contains("phone-run")); XCTAssertFalse(hidden.contains("ordinary"))
        XCTAssertFalse(hidden.listed("desk-hoot"), "isRunSession stays per-device only"); XCTAssertTrue(hidden.listed("phone-run"))
        hidden.removePredicate(token)
        XCTAssertFalse(hidden.contains("desk-hoot")); XCTAssertTrue(hidden.contains("phone-run"))
    }

    func testDeckCoreActionLogAppendsThroughTheSharedSink() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("copilot-log", isDirectory: true)
        let log = BackendDeckCoreSecurityActionLog(directory: directory)
        let sink = try BackendHootJoinRawSink.shared(directory: directory)
        XCTAssertTrue(log.rawSink === sink)
        await log.record(.object([.init("tool", .string("sessions_list"))]))
        BackendCopilotHome.appendAction(BackendCopilotPaths(userData: root.path), .init(action: "session.stopped"))
        let lines = try String(contentsOf: sink.file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix(#"{"v":1,"tool":"sessions_list""#)); XCTAssertTrue(lines[1].contains(#""action":"session.stopped""#))
        let broken = await log.broken(); XCTAssertFalse(broken)
    }

    func testOneSharedRawWriterKeepsHomeBytesAndToolRotation() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("copilot-log", isDirectory: true)
        let first = try BackendHootJoinRawSink.shared(directory: log), second = try BackendHootJoinRawSink.shared(directory: URL(fileURLWithPath: log.path + "/"))
        XCTAssertTrue(first === second, "one sink per canonical actions file")
        XCTAssertEqual(first.file.lastPathComponent, BackendDeckCoreSecurityActionLog.fileName)
        XCTAssertThrowsError(try BackendHootJoinRawSink(directory: URL(fileURLWithPath: "/")))
        // Home rows written through appendAction land in the shared file, same fields.
        let paths = BackendCopilotPaths(userData: root.path)
        XCTAssertEqual(paths.actions, first.file.path)
        BackendCopilotHome.appendAction(paths, .init(action: "session.started", detail: "cwd here", sessionId: "s-1"), now: Date(timeIntervalSince1970: 0))
        let text = try String(contentsOf: first.file, encoding: .utf8)
        XCTAssertEqual(text, #"{"at":"1970-01-01T00:00:00.000Z","action":"session.started","detail":"cwd here","sessionId":"s-1"}"# + "\n")
        // Tool policy rotates by projected size into generation .1 and keeps the new row.
        try first.append(Data(repeating: 0x61, count: 40) + Data([10]), policy: .tool(limit: 64, keep: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.file.path + ".1"))
        XCTAssertEqual(try Data(contentsOf: first.file).count, 41)
        XCTAssertThrowsError(try first.append(Data([10]), policy: .home(limit: 0)))
    }

    func testFencedLaunchThatLosesItsProofFailsOpenVisibly() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let driver = BackendHootJoinFenceDriver(refuseFence: true)
        let runtime = BackendCopilotSessionRuntime(dependencies: .init(userData: root.path, driver: driver, records: BackendHootJoinHeldRecords(root: root)))
        let state = try await runtime.ensure()
        XCTAssertEqual(state.status, .running)
        XCTAssertFalse(state.records.enforced)
        XCTAssertTrue(state.records.reason?.contains("could not be held against Hoot") == true)
        XCTAssertTrue(state.records.reason?.contains("did not hold writes") == true)
        let fences = await driver.fences
        XCTAssertEqual(fences.count, 2); XCTAssertNotNil(fences[0]); XCTAssertNil(fences[1])
        let started = BackendCopilotInspect.readActionLog(state.paths).rows.last
        XCTAssertEqual(started?.action, "session.started")
        XCTAssertTrue(started?.detail.contains("NOT held against it") == true)
        XCTAssertTrue(runtime.installedRecords is BackendHootJoinHeldRecords)
    }

    func testQuiesceStopsTheDeskHootAndRefusesLaterStarts() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let driver = BackendHootJoinFenceDriver(refuseFence: false)
        let runtime = BackendCopilotSessionRuntime(dependencies: .init(userData: root.path, driver: driver, records: BackendHootJoinHeldRecords(root: root)))
        let running = try await runtime.ensure()
        XCTAssertEqual(running.status, .running); XCTAssertTrue(running.records.enforced)
        let stopped = try await runtime.quiesceAndStop()
        XCTAssertEqual(stopped.status, .stopped)
        let closing = await runtime.isClosing; XCTAssertTrue(closing)
        do { _ = try await runtime.ensure(); XCTFail("a closing runtime must not start Hoot") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        let fences = await driver.fences; XCTAssertEqual(fences.count, 1)
    }

    func testFolderSupplyUsesTheHomeSettingAndSharedLog() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let settings = BackendAppSettingsStore(userData: root, writable: true)
        let supply = BackendHootJoinFolderSupply(dataRoot: root, settings: settings, runningIn: { "/running" }, pick: { start in start + "/picked" })
        let empty = try await supply.read(); XCTAssertEqual(empty, .null)
        try await supply.write("/Users/someone/Hoot")
        let chosen = try await supply.read(); XCTAssertEqual(chosen, .string("/Users/someone/Hoot"))
        try await supply.write(nil)
        let cleared = try await supply.read(); XCTAssertTrue(cleared == .null || cleared == .missing)
        let running = await supply.runningIn(); XCTAssertEqual(running, "/running")
        let picked = try await supply.pick(defaultPath: "/a"); XCTAssertEqual(picked, "/a/picked")
        await supply.log(.init(action: "folder.cleared", detail: "back to default"))
        XCTAssertEqual(BackendCopilotInspect.readActionLog(BackendCopilotPaths(userData: root.path)).rows.last?.action, "folder.cleared")
    }
}
