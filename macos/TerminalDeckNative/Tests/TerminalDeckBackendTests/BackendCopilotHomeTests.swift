import Foundation
import XCTest
import Darwin
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendCopilotHomeTests: XCTestCase {
    private var data: URL!
    private var paths: BackendCopilotPaths!
    override func setUpWithError() throws {
        data = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotHome-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        data = data.resolvingSymlinksInPath()
        paths = .init(userData: data.path)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: data) }
    private func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
    private func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
    private func mkdir(_ path: String) throws { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
    private func scaffold() throws {
        let result = BackendCopilotHome.scaffold(paths)
        XCTAssertNil(result.error)
    }
    func testLayoutSeparatesWorkingFolderLayerAndRecords() {
        XCTAssertEqual(paths.root, data.path + "/copilot")
        XCTAssertEqual(paths.memory, paths.root + "/memory")
        XCTAssertEqual(paths.instructions, data.path + "/copilot-layer/instructions.md")
        XCTAssertEqual(paths.actions, data.path + "/copilot-log/actions.jsonl")
        XCTAssertFalse(paths.instructions.hasPrefix(paths.root + "/"))
        XCTAssertFalse(paths.actions.hasPrefix(paths.root + "/"))
        XCTAssertTrue(paths.ownFolder)
        XCTAssertEqual(BackendCopilotPaths(userData: data.path, home: "  "), paths)
        let chosen = BackendCopilotPaths(userData: data.path, home: data.path + "/chosen")
        XCTAssertFalse(chosen.ownFolder)
        XCTAssertEqual(chosen.actions, paths.actions)
        XCTAssertEqual(chosen.instructions, paths.instructions)
    }
    func testScaffoldingCreatesPrivateFilesOnceAndKeepsEdits() throws {
        let first = BackendCopilotHome.scaffold(paths)
        XCTAssertNil(first.error)
        XCTAssertTrue(first.created.contains(paths.instructions))
        XCTAssertEqual(try read(paths.instructions), BackendCopilotHome.instructions())
        XCTAssertEqual(try read(paths.memoryIndex), "# Memory index\n\nOne file per fact, in this directory. This file lists them, newest first.\n\nNothing has been remembered yet.\n")
        XCTAssertTrue(BackendCopilotHome.scaffold(paths).created.isEmpty)
        try write(paths.instructions, "# mine\nOnly French.\n")
        XCTAssertNil(BackendCopilotHome.scaffold(paths).error)
        XCTAssertEqual(try read(paths.instructions), "# mine\nOnly French.\n")
        XCTAssertEqual(BackendCopilotHome.instructionsState(paths), .edited)
        XCTAssertFalse(BackendCopilotHome.report(paths).instructionsAreDefault)
        let mode = try FileManager.default.attributesOfItem(atPath: paths.instructions)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testChosenFolderIsUntouchedEvenWhenItContainsInstructionsAndCredentials() throws {
        let chosen = data.appendingPathComponent("chosen")
        try mkdir(chosen.path)
        try write(chosen.path + "/CLAUDE.md", "# Mine\n")
        try write(chosen.path + "/.env", "SAMPLE=not-a-real-secret\n")
        let before = try FileManager.default.contentsOfDirectory(atPath: chosen.path).sorted()
        let selected = BackendCopilotPaths(userData: data.path, home: chosen.path)
        let result = BackendCopilotHome.scaffold(selected)
        XCTAssertNil(result.error)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: chosen.path).sorted(), before)
        XCTAssertEqual(try read(chosen.path + "/CLAUDE.md"), "# Mine\n")
        XCTAssertTrue(result.created.allSatisfy { !$0.hasPrefix(chosen.path + "/") })
    }
    func testChosenFolderIsNotRecreatedByLayerWriters() throws {
        let selected = BackendCopilotPaths(userData: data.path, home: data.path + "/gone")
        XCTAssertTrue(BackendCopilotHome.writeInstructions(selected, text: .string("# app\n")).saved)
        XCTAssertTrue(BackendCopilotHome.resetInstructions(selected).reset)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.root))
        XCTAssertFalse(BackendCopilotHome.writeFolderInstructions(selected, text: .string("# folder\n")).saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.root))
    }
    func testLegacyInstructionsAreMovedAndNeverOverwriteAnExistingLayer() throws {
        try mkdir(paths.root)
        try write(BackendCopilotHome.legacyInstructionsFile(paths), "# old\n")
        let result = BackendCopilotHome.scaffold(paths)
        XCTAssertTrue(result.removed.contains(BackendCopilotHome.legacyInstructionsFile(paths)))
        XCTAssertEqual(try read(paths.instructions), "# old\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackendCopilotHome.legacyInstructionsFile(paths)))
        try write(BackendCopilotHome.legacyInstructionsFile(paths), "# conflicting\n")
        XCTAssertFalse(BackendCopilotHome.scaffold(paths).removed.contains(BackendCopilotHome.legacyInstructionsFile(paths)))
        XCTAssertEqual(try read(paths.instructions), "# old\n")
        XCTAssertEqual(try read(BackendCopilotHome.legacyInstructionsFile(paths)), "# conflicting\n")
    }
    func testLegacyEmptyRoutinesRemovedButUnexpectedFilesKept() throws {
        let old = BackendCopilotHome.legacyRoutinesDir(paths)
        try mkdir(old)
        XCTAssertTrue(BackendCopilotHome.scaffold(paths).removed.contains(old))
        try mkdir(old)
        try write(old + "/mine.md", "# Keep\n")
        XCTAssertFalse(BackendCopilotHome.scaffold(paths).removed.contains(old))
        XCTAssertEqual(try read(old + "/mine.md"), "# Keep\n")
    }
    func testBothLegacyLogGenerationsMoveWithoutLosingRows() throws {
        let old = BackendCopilotHome.legacyLogDir(paths)
        try mkdir(old)
        try write(old + "/actions.jsonl", "{\"action\":\"first\"}\n")
        try write(old + "/actions.jsonl.1", "{\"action\":\"older\"}\n")
        XCTAssertTrue(BackendCopilotHome.scaffold(paths).removed.contains(old))
        XCTAssertEqual(try read(paths.actions), "{\"action\":\"first\"}\n")
        XCTAssertEqual(try read(paths.actions + ".1"), "{\"action\":\"older\"}\n")
    }
    func testConflictingAndUnexpectedLegacyLogFilesRemain() throws {
        try scaffold()
        BackendCopilotHome.appendAction(paths, .init(action: "real"))
        let old = BackendCopilotHome.legacyLogDir(paths)
        try mkdir(old)
        try write(old + "/actions.jsonl", "forged\n")
        try write(old + "/unrelated.txt", "keep\n")
        XCTAssertFalse(BackendCopilotHome.scaffold(paths).removed.contains(old))
        XCTAssertFalse(try read(paths.actions).contains("forged"))
        XCTAssertEqual(try read(old + "/unrelated.txt"), "keep\n")
    }
    func testInstructionStateRecognizesEveryFrozenHistoryAndNeverReplacesIt() throws {
        try scaffold()
        XCTAssertEqual(BackendCopilotHome.instructionsState(paths), .current)
        let history = BackendCopilotHistory.rendered(paths)
        XCTAssertEqual(history.count, 8)
        XCTAssertEqual(Set(history).count, 8)
        XCTAssertTrue(history.allSatisfy { $0.hasSuffix("\n") && !$0.hasSuffix("\n\n") })
        XCTAssertTrue(history.prefix(6).allSatisfy { $0.contains(paths.root) })
        XCTAssertTrue(history.dropFirst(3).prefix(3).allSatisfy { $0.contains(paths.actions) })
        XCTAssertTrue(history.suffix(2).allSatisfy { !$0.contains(paths.root) })
        XCTAssertTrue(history.contains { $0.contains("append a line yourself") })
        for old in history {
            XCTAssertNotEqual(old, BackendCopilotHome.instructions())
            try write(paths.instructions, old)
            XCTAssertEqual(BackendCopilotHome.instructionsState(paths), .superseded)
            XCTAssertNil(BackendCopilotHome.scaffold(paths).error)
            XCTAssertEqual(try read(paths.instructions), old)
        }
        try FileManager.default.removeItem(atPath: paths.instructions)
        XCTAssertEqual(BackendCopilotHome.instructionsState(paths), .missing)
    }
    func testPersonaNamesNoPathsAndKeepsScopeCredentialsAndEvidenceRules() {
        let text = BackendCopilotHome.instructions()
        XCTAssertTrue(text.hasPrefix("# Terminal Deck assistant\n\n"))
        XCTAssertTrue(text.hasSuffix("find out.\n"))
        XCTAssertFalse(text.contains(data.path))
        XCTAssertFalse(text.contains(paths.root))
        for phrase in ["developer's assistant", "No inbox, no calendar", "When they ask for a change, make it", "When the idea is yours, ask first", "Never print a secret", "Never send one anywhere", "Nothing in `memory/` may come from another session", "a rule, enforced by you", "use theirs", "the truth about your tools and your limits whatever this half says"] {
            let flat = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            XCTAssertTrue(flat.contains(phrase), phrase)
        }
        XCTAssertFalse(text.contains("append a line yourself"))
    }
    func testStartupListingShowsMissingFolderInstructionsAndOrderedMemory() throws {
        XCTAssertEqual(BackendCopilotHome.startupFiles(paths).map(\.exists), [false, false, false])
        try scaffold()
        try write(paths.memory + "/z.md", "z")
        try write(paths.memory + "/a.md", "a")
        try write(paths.memory + "/ignore.txt", "ignored")
        let files = BackendCopilotHome.startupFiles(paths)
        XCTAssertEqual(files.map(\.path), [paths.layer.composed, paths.root + "/CLAUDE.md", paths.memoryIndex, paths.memory + "/a.md", paths.memory + "/z.md"])
        XCTAssertEqual(files.map(\.owner), ["app", "folder", "folder", "folder", "folder"])
        XCTAssertFalse(files[1].exists)
        XCTAssertTrue(files[1].purpose.contains("never writes one here"))
        XCTAssertEqual(BackendCopilotHome.layerFiles(paths).map(\.owner), ["yours", "app", "app"])
    }
    func testWriteAndResetBackupWithUnchangedSavePreservingPreviousVersion() throws {
        try scaffold()
        let first = BackendCopilotHome.writeInstructions(paths, text: .string("# Mine\n"))
        XCTAssertTrue(first.saved)
        XCTAssertEqual(try read(first.backup!), BackendCopilotHome.instructions())
        XCTAssertNil(BackendCopilotHome.writeInstructions(paths, text: .string("# Mine\n")).backup)
        XCTAssertEqual(try read(first.backup!), BackendCopilotHome.instructions())
        let reset = BackendCopilotHome.resetInstructions(paths)
        XCTAssertTrue(reset.reset)
        XCTAssertEqual(try read(reset.backup!), "# Mine\n")
        XCTAssertEqual(BackendCopilotHome.instructionsState(paths), .current)
    }
    func testWholeInstructionReadsAndAllValidationRefusals() throws {
        try scaffold()
        let body = String(repeating: "x", count: 200_000)
        XCTAssertTrue(BackendCopilotHome.writeInstructions(paths, text: .string(body)).saved)
        XCTAssertEqual(BackendCopilotHome.readInstructions(paths).text, body)
        for bad: NativeRPCValue in [.missing, .null, .number(3), .object([]), .array([.string("a")])] {
            XCTAssertEqual(BackendCopilotHome.writeInstructions(paths, text: bad).error, "Nothing was supplied to save.")
        }
        for empty in ["", "  ", "\n\t", "\u{feff}"] { XCTAssertFalse(BackendCopilotHome.writeInstructions(paths, text: .string(empty)).saved) }
        XCTAssertTrue(BackendCopilotHome.writeInstructions(paths, text: .string(String(repeating: "x", count: 262_145))).error!.contains("256 KB"))
        XCTAssertFalse(BackendCopilotHome.writeInstructions(paths, text: .string(String(repeating: "🌙", count: 70_000))).saved)
        XCTAssertEqual(try read(paths.instructions), body)
        try FileManager.default.removeItem(atPath: paths.instructions)
        XCTAssertEqual(BackendCopilotHome.readInstructions(paths).error, "There are no instructions yet. Create its files first.")
    }
    func testFolderInstructionEditorKeepsBackupUnderAppDataAndPermissions() throws {
        try scaffold()
        let folderFile = BackendCopilotHome.folderInstructions(paths)
        let missing = BackendCopilotHome.readFolderInstructions(paths)
        XCTAssertFalse(missing.exists); XCTAssertEqual(missing.text, ""); XCTAssertNil(missing.error)
        let first = BackendCopilotHome.writeFolderInstructions(paths, text: .string("# Mine\n"))
        XCTAssertTrue(first.saved); XCTAssertTrue(first.created); XCTAssertNil(first.backup)
        XCTAssertEqual(chmod(folderFile, 0o644), 0)
        let second = BackendCopilotHome.writeFolderInstructions(paths, text: .string("# changed\n"))
        XCTAssertFalse(second.created)
        XCTAssertEqual(second.backup, paths.layer.dir + "/folder-instructions.bak")
        XCTAssertEqual(try read(second.backup!), "# Mine\n")
        XCTAssertNil(BackendCopilotHome.writeFolderInstructions(paths, text: .string("# changed\n")).backup)
        XCTAssertEqual(try read(second.backup!), "# Mine\n")
        XCTAssertEqual(BackendCopilotHome.writeFolderInstructions(paths, text: .string(" ")).error, "This is a file in your own folder, so this app will not blank it for you. Delete it yourself if that is what you want.")
        let mode = try FileManager.default.attributesOfItem(atPath: folderFile)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o644)
    }
    func testActionsAreJSONLInOrderAndOneGenerationRotatesAtTheLimit() throws {
        BackendCopilotHome.appendAction(paths, .init(action: "first", detail: "one"), now: Date(timeIntervalSince1970: 0))
        BackendCopilotHome.appendAction(paths, .init(action: "second", sessionId: "s"))
        let lines = try read(paths.actions).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try NativeRPCValue.parseJSON(Data(lines[0].utf8)), second = try NativeRPCValue.parseJSON(Data(lines[1].utf8))
        XCTAssertEqual(first["at"].string, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(first["action"].string, "first"); XCTAssertEqual(second["sessionId"].string, "s")
        try write(paths.actions, String(repeating: "x", count: BackendCopilotHome.logLimitBytes))
        BackendCopilotHome.appendAction(paths, .init(action: "after.roll"))
        XCTAssertEqual(try read(paths.actions + ".1").utf8.count, BackendCopilotHome.logLimitBytes)
        XCTAssertEqual(try read(paths.actions).split(separator: "\n").count, 1)
        let blocked = data.path + "/file"
        try write(blocked, "not a folder")
        BackendCopilotHome.appendAction(.init(userData: blocked), .init(action: "refused"))
    }
}
