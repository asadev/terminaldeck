import Foundation
import XCTest
@testable import TerminalDeckBackend

final class BackendRoutinesDefaultsTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendRoutinesDefaults-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func diskIDs(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }
    }
    private func seed(_ directory: URL, _ folder: String?) throws -> BackendRoutinesSeedResult {
        try BackendRoutinesDefaults.seed(directory: directory, folder: folder,
            existing: { try self.diskIDs(directory) },
            write: { id, text in try text.write(to: directory.appendingPathComponent(id + ".md"), atomically: false, encoding: .utf8) })
    }
    func testFreshSeedAndDeletionRemainOneTimeOffers() throws {
        let directory = try scratch()
        XCTAssertEqual(try seed(directory, "/work/api").written, BackendRoutinesDefaults.routines.map(\.id))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("overnight.md"))
        XCTAssertEqual(try seed(directory, "/work/api").written, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("overnight.md").path))
        let marker = try String(contentsOf: BackendRoutinesDefaults.seedMarkerPath(directory: directory), encoding: .utf8)
        XCTAssertTrue(marker.contains("\novernight\n"))
    }
    func testHandWrittenCollisionIsPreserved() throws {
        let directory = try scratch(), file = directory.appendingPathComponent("overnight.md")
        try "# mine\n".write(to: file, atomically: false, encoding: .utf8)
        XCTAssertFalse(try seed(directory, "/work/api").written.contains("overnight"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# mine\n")
    }
    func testNoProjectLeavesNoMarkerAndCanSeedLater() throws {
        let directory = try scratch(), result = try seed(directory, nil)
        XCTAssertEqual(result.skipped, "No project folder to point a routine at yet.")
        XCTAssertEqual(result.written, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackendRoutinesDefaults.seedMarkerPath(directory: directory).path))
        XCTAssertEqual(try seed(directory, "/work/api").written.count, 8)
    }
    func testStorageExclusionHasPathBoundary() {
        let state = "/Users/x/Library/Application Support/terminaldeck"
        XCTAssertEqual(BackendRoutinesDefaults.chooseSeedFolder(projects: [state + "/copilot", "/work/api"], stateRoot: state), "/work/api")
        XCTAssertEqual(BackendRoutinesDefaults.chooseSeedFolder(projects: [state + "-backup"], stateRoot: state), state + "-backup")
        XCTAssertNil(BackendRoutinesDefaults.chooseSeedFolder(projects: [state, state + "/copilot"], stateRoot: state))
    }
    func testShippedTriggersAndReadOnlyPrompts() {
        XCTAssertEqual(BackendRoutinesDefaults.routines.count, 8)
        let defaults = Dictionary(uniqueKeysWithValues: BackendRoutinesDefaults.routines.map { ($0.id, $0) })
        XCTAssertEqual(defaults["blocked-agent"]?.triggers, ["alert session-blocked"])
        XCTAssertEqual(defaults["stuck-session"]?.triggers, ["alert loop", "alert heavy-session"])
        XCTAssertEqual(defaults["quality-gate"]?.enabled, false)
        XCTAssertEqual(defaults["ai-marker"]?.enabled, false)
        for entry in BackendRoutinesDefaults.routines {
            XCTAssertTrue(entry.prompt.contains("## Do not"), entry.id)
            XCTAssertFalse(entry.prompt.contains("git commit"), entry.id)
            XCTAssertFalse(entry.prompt.contains("delete the file"), entry.id)
            XCTAssertTrue(entry.file(folder: "/work/api").hasSuffix("\n"))
        }
    }
    func testEveryShippedFileParsesWithoutWarnings() {
        let emitted = Set(["session-finished", "session-failed", "session-idle", "alert", "git-change", "file-change", "schedule", "manual"])
        for entry in BackendRoutinesDefaults.routines {
            let parsed = BackendRoutinesFormat.parseRoutine(entry.id, text: entry.file(folder: "/work/api"))
            XCTAssertTrue(parsed.ok, entry.id + ": " + parsed.problems.joined(separator: " "))
            XCTAssertEqual(parsed.warnings, [], entry.id)
            XCTAssertEqual(parsed.routine?.folder, "/work/api")
            for trigger in parsed.routine?.triggers ?? [] { XCTAssertTrue(emitted.contains(trigger.kind), entry.id) }
        }
    }
}
