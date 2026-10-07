import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendCopilotInspectTests: XCTestCase {
    private func fixture() throws -> (URL, BackendCopilotPaths) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotInspect-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, BackendCopilotPaths(userData: root.path))
    }
    func testFrontMatterQuotesIncompleteBlockAndPlainText() {
        XCTAssertEqual(BackendCopilotInspect.parseFrontMatter("---\nname: fact\ndescription: \"builds with pnpm\"\ntype: convention\nscope: global\nverified: 2026-08-17\n---\n"),
            ["name": "fact", "description": "builds with pnpm", "type": "convention", "scope": "global", "verified": "2026-08-17"])
        XCTAssertEqual(BackendCopilotInspect.parseFrontMatter("---\ntype: decision\n"), ["type": "decision"])
        XCTAssertEqual(BackendCopilotInspect.parseFrontMatter("# plain"), [:])
        XCTAssertEqual(BackendCopilotInspect.parseFrontMatter("---oops\ntype: bad"), [:])
    }
    func testNamesAreSingleFilesAndRefusedOperationsPreserveOtherFiles() throws {
        let (root, paths) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(BackendCopilotHome.scaffold(paths).error)
        let before = try BackendCopilotServiceFiles.readText(paths.instructions)
        let valid = ["science_locus_uses_pnpm.md", "MEMORY.md", "no-redis-2026.md"]
        for name in valid { XCTAssertTrue(BackendCopilotInspect.isMemoryName(.string(name))) }
        let invalid: [NativeRPCValue] = ["../CLAUDE.md", "..%2fCLAUDE.md", "sub/dir.md", "/etc/passwd", "C:\\Windows\\win.ini", ".md", "notes.txt", "a\0.md", ""].map(NativeRPCValue.string) + [.number(42), .null]
        for name in invalid {
            XCTAssertFalse(BackendCopilotInspect.isMemoryName(name))
            XCTAssertEqual(BackendCopilotInspect.readMemoryFact(paths, name: name)["ok"].bool, false)
            XCTAssertEqual(BackendCopilotInspect.writeMemoryFact(paths, name: name, text: .string("rewrite"))["ok"].bool, false)
            XCTAssertEqual(BackendCopilotInspect.deleteMemoryFact(paths, name: name)["ok"].bool, false)
        }
        XCTAssertEqual(try BackendCopilotServiceFiles.readText(paths.instructions), before)
        XCTAssertEqual(BackendCopilotInspect.readActionLog(paths).rows.count, 0)
    }
    func testAbsentMemoryAndLogAreOrdinaryEmptyStates() throws {
        let (root, paths) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let report = BackendCopilotInspect.readMemory(paths)
        XCTAssertFalse(report.exists); XCTAssertNil(report.error); XCTAssertEqual(report.facts, [])
        let log = BackendCopilotInspect.readActionLog(paths)
        XCTAssertFalse(log.exists); XCTAssertEqual(log.bytes, 0); XCTAssertEqual(log.rows, [])
        XCTAssertTrue(log.outsideCopilotFolder)
        XCTAssertTrue(paths.log.hasPrefix(paths.root)); XCTAssertFalse(paths.log.hasPrefix(paths.root + "/"))
    }
    func testMemoryNewestFirstAndFrontMatterProjection() throws {
        let (root, paths) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = BackendCopilotHome.scaffold(paths)
        let older = URL(fileURLWithPath: paths.memory).appendingPathComponent("old.md")
        let newer = URL(fileURLWithPath: paths.memory).appendingPathComponent("new.md")
        try Data("---\ndescription: \"pnpm\"\ntype: convention\nscope: global\nverified: 2026-08-17\n---\n".utf8).write(to: newer)
        try Data("old".utf8).write(to: older)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: paths.memoryIndex)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: newer.path)
        let report = BackendCopilotInspect.readMemory(paths)
        XCTAssertEqual(report.facts.map(\.name), ["new.md", "MEMORY.md", "old.md"])
        XCTAssertEqual(report.facts.first?.scope, "global"); XCTAssertEqual(report.facts.first?.verified, "2026-08-17")
        XCTAssertEqual(report.facts.first?.index, false); XCTAssertEqual(report.facts[1].index, true)
    }
    func testEditorPreservesBytesDoesNotCreateCapsUtf8AndAttributesActor() throws {
        let (root, paths) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = BackendCopilotHome.scaffold(paths)
        let file = URL(fileURLWithPath: paths.memory).appendingPathComponent("fact.md")
        try Data("original".utf8).write(to: file)
        for value in [NativeRPCValue.missing, .null, .number(7), .object([])] {
            XCTAssertEqual(BackendCopilotInspect.writeMemoryFact(paths, name: .string("fact.md"), text: value)["ok"].bool, false)
        }
        XCTAssertEqual(BackendCopilotInspect.writeMemoryFact(paths, name: .string("invented.md"), text: .string("plant"))["ok"].bool, false)
        let exact = String(repeating: "x", count: BackendCopilotInspect.maxMemoryReadBytes)
        XCTAssertEqual(BackendCopilotInspect.writeMemoryFact(paths, name: .string("fact.md"), text: .string(exact))["ok"].bool, true)
        XCTAssertEqual(BackendCopilotInspect.writeMemoryFact(paths, name: .string("fact.md"), text: .string(exact + "x"))["ok"].bool, false)
        let unicode = String(repeating: "é", count: BackendCopilotInspect.maxMemoryReadBytes / 2 + 1)
        XCTAssertEqual(BackendCopilotInspect.writeMemoryFact(paths, name: .string("fact.md"), text: .string(unicode))["ok"].bool, false)
        let corrected = "---\nscope: /new\nverified: today\n---\n\nchanged\n"
        let result = BackendCopilotInspect.writeMemoryFact(paths, name: .string("fact.md"), text: .string(corrected), where: "a phone")
        XCTAssertEqual(result["ok"].bool, true)
        XCTAssertEqual(try BackendCopilotServiceFiles.readText(file.path), corrected)
        XCTAssertEqual(BackendCopilotInspect.readMemory(paths).facts.first { $0.name == "fact.md" }?.scope, "/new")
        let edited = try XCTUnwrap(BackendCopilotInspect.readActionLog(paths).rows.last)
        XCTAssertEqual(edited.detail, "you edited memory/fact.md from a phone"); XCTAssertNil(edited.tool)
    }
    func testReadUtf16CapDeleteNonrecursiveAndMissingSaveNeverResurrects() throws {
        let (root, paths) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = BackendCopilotHome.scaffold(paths)
        let file = URL(fileURLWithPath: paths.memory).appendingPathComponent("large.md")
        try Data(String(repeating: "x", count: BackendCopilotInspect.maxMemoryReadBytes + 10).utf8).write(to: file)
        let read = BackendCopilotInspect.readMemoryFact(paths, name: .string("large.md"))
        XCTAssertEqual(read["truncated"].bool, true); XCTAssertEqual(read["text"].string?.utf16.count, BackendCopilotInspect.maxMemoryReadBytes)
        let removed = BackendCopilotInspect.deleteMemoryFact(paths, name: .string("large.md"))
        XCTAssertEqual(removed["ok"].bool, true); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(BackendCopilotInspect.readActionLog(paths).rows.last?.detail, "you deleted memory/large.md from Settings")
        XCTAssertEqual(BackendCopilotInspect.deleteMemoryFact(paths, name: .string("large.md"))["ok"].bool, false)
        let saved = BackendCopilotInspect.writeMemoryFact(paths, name: .string("large.md"), text: .string("resurrect"))
        XCTAssertTrue(saved["error"].string?.contains("no longer there") == true)
        let directory = URL(fileURLWithPath: paths.memory).appendingPathComponent("folder.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(BackendCopilotInspect.deleteMemoryFact(paths, name: .string("folder.md"))["ok"].bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }
    func testBothWritersTornRowsRotationAndLimits() throws {
        let (root, paths) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = BackendCopilotHome.scaffold(paths)
        let app = "{\"at\":\"old\",\"action\":\"home.created\",\"detail\":\"yesterday\"}"
        let tool = "{\"at\":\"new\",\"action\":\"tool.settings.write\",\"tool\":\"settings.write\",\"tier\":\"alter\",\"outcome\":\"refused\",\"confirmed\":{\"required\":true,\"granted\":false,\"reason\":\"not-permitted-unattended\"},\"caller\":{\"kind\":\"remote\"},\"ms\":42}"
        try BackendCopilotServiceFiles.writeText(app + "\n", path: paths.actions + ".1")
        try BackendCopilotServiceFiles.writeText(tool + "\n{torn\n", path: paths.actions)
        let report = BackendCopilotInspect.readActionLog(paths, want: 10)
        XCTAssertEqual(report.rows.map(\.at), ["old", "new"])
        XCTAssertNil(report.rows[0].tool); XCTAssertNil(report.rows[0].confirmed)
        XCTAssertEqual(report.rows[1].confirmationRequired, true); XCTAssertEqual(report.rows[1].confirmed, false)
        XCTAssertEqual(report.rows[1].refusedReason, "not-permitted-unattended"); XCTAssertEqual(report.rows[1].caller, "remote"); XCTAssertEqual(report.rows[1].ms, 42)
        XCTAssertTrue(BackendCopilotInspect.readActionLog(paths, want: 1).more)
        XCTAssertEqual(BackendCopilotInspect.readActionLog(paths, want: .nan).rows.count, 2)
        for junk in ["null", "[]", "{\"at\":\"x\"}", "{\"action\":\"x\"}"] { XCTAssertNil(BackendCopilotInspect.parseActionRow(junk)) }
        try BackendCopilotServiceFiles.writeText(Array(repeating: app, count: 2001).joined(separator: "\n"), path: paths.actions)
        XCTAssertEqual(BackendCopilotInspect.readActionLog(paths, want: .greatestFiniteMagnitude).rows.count, 2000)
    }
    func testAllRevealPlaceKeysAndUnavailableFinder() async throws {
        let (root, paths) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = BackendCopilotHome.scaffold(paths)
        for place in BackendCopilotPlace.allCases { XCTAssertTrue(place.path(paths, userData: root.path).hasPrefix(root.path)) }
        XCTAssertEqual(BackendCopilotPlace.contract.path(paths, userData: root.path), paths.layer.contract)
        XCTAssertEqual(BackendCopilotPlace.composed.path(paths, userData: root.path), paths.layer.composed)
        let deps = BackendCopilotInspectDependencies(userData: root.path, paths: { paths })
        let unknown = try await BackendCopilotInspect.reveal(deps, place: .string("../../anything"))
        XCTAssertEqual(unknown["opened"].bool, false); XCTAssertEqual(unknown["path"], .null)
        let rootResult = try await BackendCopilotInspect.reveal(deps, place: .string("root"))
        XCTAssertEqual(rootResult["message"].string, "This host has no file manager to open — it is a server.")
        let missing = try await BackendCopilotInspect.reveal(deps, place: .string("composed"))
        XCTAssertEqual(missing["message"].string, "That has not been created yet, so there is nothing to open.")
    }
}
