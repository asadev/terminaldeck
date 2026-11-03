import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// U144: files the app writes are cleaned up instead of piling up for ever.
final class LeftBehindFilesTests: XCTestCase {
    private actor NoCommands: BackendAppSessionCommandExecuting {
        func run(_ command: String, arguments: [String], environment: [String: String], cwd: String,
                 timeoutMilliseconds: Int, maximumBytes: Int) async -> BackendAppSessionCommandResult { .init(exitCode: 0) }
        func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws {}
    }
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LeftBehindFilesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func make(_ url: URL, folder: Bool = false, daysOld: Double = 0) throws {
        if folder { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        else { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("x".utf8).write(to: url) }
        if daysOld > 0 { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 24 * 3_600)], ofItemAtPath: url.path) }
    }
    private func names(_ folder: URL) -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []) }

    /// #113: erasing an Android emulator keeps no copy of its old data, and copies left by earlier erases go too.
    func testAndroidEraseLeavesNoCopyOfTheOldData() async throws {
        let avds = root.appendingPathComponent("avd"), device = avds.appendingPathComponent("Pixel.avd")
        try make(avds.appendingPathComponent("Pixel.ini"))
        for file in ["config.ini", "userdata-qemu.img", "cache.img", "snapshots/default/ram.img"] { try make(device.appendingPathComponent(file)) }
        try make(device.appendingPathComponent("TerminalDeck Reset OLD.noindex/userdata-qemu.img"))
        let service = BackendFIXESDeviceManagement(platform: .init(environment: ["ANDROID_AVD_HOME": avds.path], home: root.path, executor: NoCommands()))
        let row = NativeRPCValue.object([.init("id", .string("avd:Pixel")), .init("kind", .string("emulator")), .init("name", .string("Pixel")), .init("state", .string("shutdown"))])
        let answer = try await service.perform(.reset, id: "avd:Pixel", confirmed: true, rows: [row])
        XCTAssertEqual(answer["ok"].bool, true)
        XCTAssertNil(answer["backup"].string)
        XCTAssertEqual(names(device), ["config.ini"])
    }

    /// #363, #524: week-old briefs and replies go, unless a task waits on one; old per-start definitions go after a month.
    func testOldBriefsGoAndWaitingOnesStay() throws {
        let folder = root.appendingPathComponent("task-briefs")
        try make(folder.appendingPathComponent("1-old.md"), daysOld: 8)
        try make(folder.appendingPathComponent("2-reply-old.md"), daysOld: 8)
        try make(folder.appendingPathComponent("3-waiting.md"), daysOld: 8)
        try make(folder.appendingPathComponent("4-new.md"), daysOld: 1)
        try make(folder.appendingPathComponent("5-x-agent-definition.json"), daysOld: 31)
        try make(folder.appendingPathComponent("6-y-agent-definition.json"), daysOld: 8)
        try make(folder.appendingPathComponent("agent-definition-abc.json"), daysOld: 40)
        let specs = try BackendTaskPersistence(directory: folder, ownership: .exclusive)
        BackendTaskTypedBriefs.sweep(specs, keeping: ["3-waiting.md"])
        XCTAssertEqual(names(folder), ["3-waiting.md", "4-new.md", "6-y-agent-definition.json", "agent-definition-abc.json"])
        try make(folder.appendingPathComponent("7-old.md"), daysOld: 8)
        BackendTaskTypedBriefs.sweep(try BackendTaskPersistence(directory: folder, ownership: .readOnly), keeping: [])
        XCTAssertTrue(names(folder).contains("7-old.md"), "A read-only copy of the app removes nothing.")
    }

    /// #524: one definition file per imported agent, the same for every start.
    func testOneDefinitionFileNamePerAgent() {
        let one = BackendTAGAgentDefinitionLaunch.fileName(agentID: "agent-1", name: "inspector")
        XCTAssertEqual(one, BackendTAGAgentDefinitionLaunch.fileName(agentID: "agent-1", name: "inspector"))
        XCTAssertNotEqual(one, BackendTAGAgentDefinitionLaunch.fileName(agentID: "agent-2", name: "inspector"))
        XCTAssertTrue(one.hasPrefix("agent-definition-") && one.hasSuffix(".json"))
        XCTAssertFalse(one.hasSuffix("-agent-definition.json"), "Never swept as an old per-start file.")
    }

    /// #423: a handover keeps only its own record and message; a removed tab takes its folder with it.
    func testHandoverKeepsOnlyTheNewestCopyAndARemovedTabTakesItsFolder() throws {
        let data = root.appendingPathComponent("data"), tab = data.appendingPathComponent("session-handover/tab-1")
        for stamp in ["100", "200"] {
            for name in ["record-\(stamp).json", "record-\(stamp).md", "handover-\(stamp).md"] { try make(tab.appendingPathComponent(name)) }
        }
        try make(tab.appendingPathComponent("notes.txt"))
        BackendSessionAIHandover.keepNewest(in: tab, stamp: "200")
        XCTAssertEqual(names(tab), ["record-200.json", "record-200.md", "handover-200.md", "notes.txt"])
        BackendSessionAIHandover.forget(tab: "..", data: data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tab.path))
        BackendSessionAIHandover.forget(tab: "tab-1", data: data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tab.path))
    }

    /// #636: launch folders of runs whose process is gone are swept; this run's, a running one's and a recent
    /// unnamed one stay.
    func testLaunchFoldersOfGoneRunsAreSwept() throws {
        let base = root.appendingPathComponent("staysfixed/agents")
        let mine = "native-p\(getpid())-mine", alive = "native-p1-launchd", gone = "native-p99999999-gone"
        for name in [mine, alive, gone] { try make(base.appendingPathComponent(name + "/lease/claude.json")) }
        try make(base.appendingPathComponent("native-0a1b-old"), folder: true, daysOld: 8)
        try make(base.appendingPathComponent("native-0a1b-recent"), folder: true, daysOld: 1)
        try make(base.appendingPathComponent("other"), folder: true, daysOld: 30)
        BackendProjectToolComposition.sweep(base: base, keeping: mine)
        XCTAssertEqual(names(base), [mine, alive, "native-0a1b-recent", "other"])
    }

    /// #663: session memory folders that are not running and untouched for two weeks go; running or recent ones stay.
    func testStaleSessionMemoryFoldersGo() throws {
        let memory = root.appendingPathComponent("session-memory"), sessions = memory.appendingPathComponent("sessions")
        for (id, days) in [("old", 15.0), ("live", 15.0), ("recent", 2.0)] {
            try make(sessions.appendingPathComponent(id + "/state.json"), daysOld: days)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 24 * 3_600)], ofItemAtPath: sessions.appendingPathComponent(id).path)
        }
        DeckMemorySessionCenter.sweep(root: memory, live: ["live"])
        XCTAssertEqual(names(sessions), ["live", "recent"])
    }
}
