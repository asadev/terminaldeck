import Foundation
import XCTest
@testable import TerminalDeckBackend

/// L8 (11 Oct): an app-started Claude session never opens on Claude Code's first-run screen, and the person's
/// config file loses nothing: only `hasCompletedOnboarding` changes, by a minimal text edit.
final class L8ClaudeFirstRunTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("L8FirstRun-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private let his = """
    {
      "numStartups": 412,
      "theme": "dark",
      "hasCompletedOnboarding": false,
      "projects": {
        "/Users/x/p": { "hasCompletedProjectOnboarding": true, "hasTrustDialogAccepted": true, "lastCost": 1.2500 }
      },
      "oauthAccount": { "emailAddress": "a@b.c" }
    }

    """

    func testOnlyTheOneFlagChangesByteForByteInThePersonsOwnFile() throws {
        let home = try folder(), file = home.appendingPathComponent(".claude.json")
        try Data(his.utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let line = BackendClaudeFirstRun.ensureOnboarded(configDirectory: nil, home: home.path)
        XCTAssertTrue(line?.contains("set only hasCompletedOnboarding=true") == true, line ?? "")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), his.replacingOccurrences(of: "\"hasCompletedOnboarding\": false", with: "\"hasCompletedOnboarding\": true"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNil(BackendClaudeFirstRun.ensureOnboarded(configDirectory: nil, home: home.path), "nothing to do the second time")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [".claude.json"], "no temporary file left")
    }

    func testAMissingKeyIsAddedAndNothingElseMoves() throws {
        let home = try folder(), file = home.appendingPathComponent(".claude.json")
        try Data("{\"numStartups\":3,\"theme\":\"light\"}".utf8).write(to: file)
        XCTAssertNotNil(BackendClaudeFirstRun.ensureOnboarded(configDirectory: nil, home: home.path))
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(value?["hasCompletedOnboarding"] as? Bool, true); XCTAssertEqual(value?["numStartups"] as? Int, 3); XCTAssertEqual(value?["theme"] as? String, "light")
    }

    func testThePersonsFileIsNeverCreatedButAnAppKeptLoginFolderIs() throws {
        let home = try folder()
        XCTAssertNil(BackendClaudeFirstRun.ensureOnboarded(configDirectory: nil, home: home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path))
        let kept = home.appendingPathComponent("profiles/work")
        XCTAssertNotNil(BackendClaudeFirstRun.ensureOnboarded(configDirectory: kept.path, home: home.path))
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: kept.appendingPathComponent(".claude.json"))) as? [String: Any]
        XCTAssertEqual(value?["hasCompletedOnboarding"] as? Bool, true)
    }

    func testLeftAloneWhileClaudeHoldsItsLockOrWhenTheEditWouldTouchAnythingElse() throws {
        let home = try folder(), file = home.appendingPathComponent(".claude.json")
        try Data(his.utf8).write(to: file)
        try Data().write(to: URL(fileURLWithPath: file.path + ".lock"))
        XCTAssertTrue(BackendClaudeFirstRun.ensureOnboarded(configDirectory: nil, home: home.path)?.contains("left alone") == true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), his)
        try FileManager.default.removeItem(atPath: file.path + ".lock")
        // The key exists only inside a nested object: the edit would change that object, so nothing is written.
        let nested = "{\"a\":{\"hasCompletedOnboarding\":false}}"
        try Data(nested.utf8).write(to: file)
        XCTAssertTrue(BackendClaudeFirstRun.ensureOnboarded(configDirectory: nil, home: home.path)?.contains("left alone") == true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), nested)
        try Data("not json".utf8).write(to: file)
        XCTAssertTrue(BackendClaudeFirstRun.ensureOnboarded(configDirectory: nil, home: home.path)?.contains("left alone") == true)
    }
}
