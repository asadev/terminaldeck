import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendCopilotTrustTests: XCTestCase {
    private func fixture(_ run: (String, String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotTrust-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("copilot")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // copilot-trust.test.ts:22 `realpathSync(mkdtempSync(...))`: the realpath the code records (/private/var/...).
        let base = BackendCopilotStorageIO.resolved(root.path)
        try run(base + "/config/.claude.json", BackendCopilotStorageIO.resolved(folder.path))
    }
    private func write(_ file: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: file))
    }
    private func config(_ file: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: file))) }
    func testActualTrustFileFollowsAccountEnvironmentNotProfileDirectoryGuess() {
        XCTAssertEqual(BackendCopilotTrust.trustFile(overrides: [:], environment: [:], home: "/Users/person"), "/Users/person/.claude.json")
        XCTAssertEqual(BackendCopilotTrust.trustFile(overrides: [:], environment: ["CLAUDE_CONFIG_DIR": "/inherited"], home: "/Users/person"), "/inherited/.claude.json")
        XCTAssertEqual(BackendCopilotTrust.trustFile(overrides: ["CLAUDE_CONFIG_DIR": "/account"], environment: ["CLAUDE_CONFIG_DIR": "/inherited"], home: "/Users/person"), "/account/.claude.json")
        XCTAssertEqual(BackendCopilotTrust.trustFile(overrides: ["CLAUDE_CONFIG_DIR": " "], environment: ["CLAUDE_CONFIG_DIR": "/inherited"], home: "/Users/person"), "/Users/person/.claude.json")
    }
    func testRecordsAbsentTrustUsingResolvedFolderAndAtomicRename() throws {
        try fixture { file, folder in
            XCTAssertEqual(BackendCopilotTrust.trustFolder(file: file, folder: folder), .recorded)
            XCTAssertEqual(try config(file)["projects"][folder]["hasTrustDialogAccepted"], .bool(true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file + ".deck-" + String(ProcessInfo.processInfo.processIdentifier)))
            let link = URL(fileURLWithPath: folder).deletingLastPathComponent().appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: folder)
            XCTAssertEqual(BackendCopilotTrust.trustFolder(file: file, folder: link.path), .already)
            XCTAssertEqual(try config(file)["projects"].fields?.map(\.key), [folder])
        }
    }
    func testPreservesUnrelatedConfigAndExistingProjectFields() throws {
        try fixture { file, folder in
            let initial: NativeRPCValue = .object([.init("userID", .string("sample")), .init("onboarded", .bool(true)),
                .init("projects", .object([.init("/other", .object([.init("hasTrustDialogAccepted", .bool(true)), .init("allowedTools", .array([.string("Bash")]))])),
                    .init(folder, .object([.init("allowedTools", .array([.string("Read")]))]))]))])
            try write(file, initial.compact)
            XCTAssertEqual(BackendCopilotTrust.trustFolder(file: file, folder: folder), .recorded)
            let after = try config(file)
            XCTAssertEqual(after["userID"], initial["userID"])
            XCTAssertEqual(after["projects"]["/other"], initial["projects"]["/other"])
            XCTAssertEqual(after["projects"][folder]["allowedTools"], initial["projects"][folder]["allowedTools"])
        }
    }
    func testExistingYesAndNoAreDecisionsThatRemainByteIdentical() throws {
        try fixture { file, folder in
            for accepted in [true, false] {
                let text = NativeRPCValue.object([.init("projects", .object([.init(folder, .object([.init("hasTrustDialogAccepted", .bool(accepted))]))]))]).compact
                try write(file, text)
                XCTAssertEqual(BackendCopilotTrust.trustFolder(file: file, folder: folder), accepted ? .already : .refused)
                XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), text)
            }
        }
    }
    func testForeignOrBrokenConfigNeverGetsReplaced() throws {
        try fixture { file, folder in
            for text in ["{ invalid json", "[\"array\"]", "null", "7"] {
                try write(file, text)
                XCTAssertEqual(BackendCopilotTrust.trustFolder(file: file, folder: folder), .failed)
                XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), text)
            }
            try write(file, "{\"projects\":\"wrong shape\",\"keep\":true}")
            XCTAssertEqual(BackendCopilotTrust.trustFolder(file: file, folder: folder), .recorded)
            XCTAssertEqual(try config(file)["keep"], .bool(true))
            XCTAssertEqual(try config(file)["projects"][folder]["hasTrustDialogAccepted"], .bool(true))
        }
    }
}
