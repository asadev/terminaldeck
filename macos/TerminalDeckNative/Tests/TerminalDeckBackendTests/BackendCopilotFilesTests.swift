import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendCopilotFilesTests: XCTestCase {
    private var data: URL!
    private var paths: BackendCopilotPaths!
    override func setUpWithError() throws {
        data = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotFiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        paths = .init(userData: data.path)
        XCTAssertNil(BackendCopilotHome.scaffold(paths).error)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: data) }
    private func service() -> BackendCopilotFilesHere { let fixed = paths!; return .init(paths: { fixed }) }
    private func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
    private func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
    func testListUsesClosedIdsNeverPathsAndKeepsAbsentFolderRow() async throws {
        let rows = try await service().list()
        XCTAssertEqual(Array(rows.prefix(4)).map { $0["id"].string }, ["yours", "contract", "composed", "folder"])
        XCTAssertEqual(Array(rows.prefix(4)).map { $0["writable"].bool }, [true, false, false, true])
        XCTAssertFalse(rows[3]["exists"].bool!)
        XCTAssertEqual(rows[3]["name"].string, "CLAUDE.md")
        for row in rows { XCTAssertFalse(row.has("path")) }
    }
    func testListingScrubsOnlyDisplayControlsAndCapsRowsAndPurpose() async throws {
        for number in 0..<210 {
            try write(paths.memory + "/fact-\(number).md", "---\nname: fact\ndescription: \"hello\u{7} العربية \(String(repeating: "x", count: 260))\"\n---\nbody\n")
        }
        let rows = try await service().list()
        XCTAssertEqual(rows.count, BackendCopilotFilesHere.maxRows)
        for row in rows.dropFirst(4) {
            XCTAssertEqual(row["owner"].string, "folder")
            XCTAssertTrue(row["id"].string!.hasPrefix("memory:"))
            XCTAssertLessThanOrEqual(row["purpose"].string!.utf16.count, 240)
            XCTAssertFalse(row["purpose"].string!.contains("\u{7}"))
        }
    }
    func testWholeReadsRefuseOversizeInsteadOfTruncatingAndKeepMissingSemantics() async throws {
        let source = service()
        let folder = try await source.read(.layer("folder"))
        XCTAssertEqual(folder.text, ""); XCTAssertNil(folder.error)
        let contract = try await source.read(.layer("contract"))
        XCTAssertNotNil(contract.error)
        try write(paths.instructions, String(repeating: "é", count: 20_000))
        let huge = try await source.read(.layer("yours"))
        XCTAssertEqual(huge.text, ""); XCTAssertTrue(huge.error!.contains("32 KB"))
        try write(paths.memory + "/oversize.md", String(repeating: "x", count: 300_000))
        let memory = try await source.read(.memory("oversize.md"))
        XCTAssertEqual(memory.text, ""); XCTAssertEqual(memory.error, "That memory is too large to open on a device. Open it on the computer.")
    }
    func testGeneratedFilesAndUnknownIdNeverReachAWritablePath() async throws {
        let source = service()
        for id in ["contract", "composed"] {
            let result = try await source.write(.layer(id), text: "cannot replace")
            XCTAssertFalse(result.ok)
            XCTAssertTrue(result.error!.contains("written by the app every time Hoot starts"))
        }
        do { _ = try await source.read(.layer(paths.actions)); XCTFail("No arbitrary path may become an ID") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "invalid-arguments") }
        let escaped = try await source.read(.memory("../outside.md"))
        XCTAssertNotNil(escaped.error)
    }
    func testWriteRefusesExistingOversizeEvenIfIncomingBodyIsShort() async throws {
        let body = String(repeating: "x", count: 33_000)
        try write(paths.instructions, body)
        let result = try await service().write(.layer("yours"), text: "short")
        XCTAssertFalse(result.ok); XCTAssertTrue(result.error!.contains("larger than a device can be sent"))
        XCTAssertEqual(try read(paths.instructions), body)
        let rows = try await service().list()
        XCTAssertFalse(rows[0]["writable"].bool!)
    }
    func testEditsResetsAndMemoryDeletionAttributeThePairedPerson() async throws {
        let source = service()
        let saved = try await source.write(.layer("yours"), text: "# edited\n")
        XCTAssertTrue(saved.ok)
        let folder = try await source.write(.layer("folder"), text: "# folder\n")
        XCTAssertTrue(folder.ok)
        let unchanged = try await source.write(.layer("folder"), text: "# folder\n")
        XCTAssertTrue(unchanged.ok)
        try write(paths.memory + "/fact.md", "# old\n")
        let memory = try await source.write(.memory("fact.md"), text: "# new\n")
        XCTAssertTrue(memory.ok)
        let deleted = try await source.forget("fact.md")
        XCTAssertTrue(deleted.ok)
        let reset = try await source.reset()
        XCTAssertTrue(reset.ok)
        let log = try read(paths.actions)
        XCTAssertTrue(log.contains("from a paired device"))
        XCTAssertTrue(log.contains("nothing changed"))
        for action in ["instructions.edited", "folder-instructions.edited", "memory.edited", "memory.deleted", "instructions.reset"] { XCTAssertTrue(log.contains(action), action) }
        XCTAssertEqual(try read(paths.instructions), BackendCopilotHome.instructions())
    }
    func testPathLookupFollowsFolderChangeOnEveryCall() async throws {
        let second = data.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try write(second.path + "/CLAUDE.md", "# second\n")
        let selection = BackendCopilotFilesTestSelection(paths)
        let source = BackendCopilotFilesHere(paths: { await selection.paths })
        let first = try await source.read(.layer("folder"))
        XCTAssertEqual(first.text, "")
        await selection.choose(.init(userData: data.path, home: second.path))
        let next = try await source.read(.layer("folder"))
        XCTAssertEqual(next.text, "# second\n")
    }
}
private actor BackendCopilotFilesTestSelection {
    var paths: BackendCopilotPaths
    init(_ paths: BackendCopilotPaths) { self.paths = paths }
    func choose(_ value: BackendCopilotPaths) { paths = value }
}
