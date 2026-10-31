import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 18 Oct, Part 20 (U72): usage and cost readings.
final class UsageReadingsTests: XCTestCase, @unchecked Sendable {
    private func codexHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("usage-codex-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    private func rollout(_ home: URL, day: String, name: String, cwd: String, id: String, minutesAgo: Double) throws {
        let folder = home.appendingPathComponent("sessions/2026/10/" + day)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta = NativeRPCValue.object([.init("type", .string("session_meta")),
            .init("payload", .object([.init("id", .string(id)), .init("cwd", .string(cwd)), .init("instructions", .string(String(repeating: "x", count: 900)))]))])
        let file = folder.appendingPathComponent(name + ".jsonl")
        var data = try meta.encodedJSON(); data.append(10)
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: file.path)
    }

    // #75: a long Codex history no longer fails the context reading; the newest rollouts are read first.
    func testLongCodexHistoryStillFindsTheNewestRolloutForTheFolder() throws {
        let home = try codexHome()
        for index in 0..<40 { try rollout(home, day: "01", name: "old-\(index)", cwd: "/elsewhere", id: "old-\(index)", minutesAgo: Double(1_000 + index)) }
        try rollout(home, day: "18", name: "mine", cwd: "/work/project", id: "mine", minutesAgo: 1)
        // About four rollout heads fit this budget: the old way read every head and failed once it ran out.
        let found = try BackendUsageCodex.projectCandidates(home: home.path, cwd: "/work/project", conversationID: nil, byteBudget: 4_000)
        XCTAssertEqual(found.map(\.conversationID), ["mine"])
        let named = try BackendUsageCodex.projectCandidates(home: home.path, cwd: "/work/project", conversationID: "mine", byteBudget: 4_000)
        XCTAssertEqual(named.map(\.conversationID), ["mine"])
        // A folder last used long ago: the budget runs out and the answer is "none found", never an error.
        try rollout(home, day: "01", name: "ancient", cwd: "/work/ancient", id: "ancient", minutesAgo: 5_000)
        XCTAssertTrue(try BackendUsageCodex.projectCandidates(home: home.path, cwd: "/work/ancient", conversationID: nil, byteBudget: 4_000).isEmpty)
    }

    // #652: a change still waiting out its debounce survives a re-install of the watch.
    func testPendingChangeSurvivesReinstall() throws {
        let home = try codexHome(), file = home.appendingPathComponent("transcript.jsonl")
        try Data("one\n".utf8).write(to: file)
        let fired = expectation(description: "the change is delivered")
        fired.assertForOverFulfill = false
        let watch = BackendUsageFileWatch { fired.fulfill() }
        XCTAssertEqual(try watch.install(paths: [file.path]), 1)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("two\n".utf8)); try handle.close()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(try watch.install(paths: [file.path]), 1)
        wait(for: [fired], timeout: 5)
        watch.stop()
    }

    // #669: with too many scans kept, the one asked for longest ago goes, never the one in use.
    func testScanEvictionDropsTheLeastRecentlyUsed() {
        let keys = (0..<14).map { "scan-\($0)" }
        var used: [String: UInt64] = [:]
        for (index, key) in keys.enumerated() { used[key] = UInt64(100 + index) }
        used["scan-0"] = 999   // just looked at in another window
        used["scan-5"] = 1     // not asked for in a long time
        XCTAssertEqual(Set(BackendCostService.evicted(keys, keeping: "scan-13", used: used, limit: 12)), ["scan-5", "scan-1"])
        XCTAssertTrue(BackendCostService.evicted(Array(keys.prefix(12)), keeping: "scan-0", used: used, limit: 12).isEmpty)
    }
}
