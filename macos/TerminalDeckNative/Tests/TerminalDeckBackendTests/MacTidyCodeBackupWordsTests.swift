import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Mac tidy (15 Nov): the Code rows say from which Mac the last backup came and link the GitHub repository by name.
/// Pure values and an in-memory or scratch ledger only; nothing reaches Git or GitHub.
final class MacTidyCodeBackupWordsTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func row() -> BackendCodeBackupProject {
        var row = BackendCodeBackupProject(id: "p1", name: "Notes")
        row.hasFolder = true; row.isRepository = true; row.home = "someone/notes"; row.branch = "main"
        return row
    }

    func testLastBackedUpNamesThisMacWhenItSentTheNewestBackup() {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        var row = row()
        row.lastBackedUpAt = ms - 3_600_000
        XCTAssertEqual(BackendCodeBackupWords.lastBackedUp(row, now: now, timeZone: utc).hasSuffix(" from Mac mini"), false, "no Mac known: date only")
        row.sentAt = ms - 600_000; row.sentFrom = "Mac mini"
        XCTAssertEqual(BackendCodeBackupWords.lastBackedUp(row, now: now, timeZone: utc),
                       "Last backed up " + BackendCodeBackupWords.when(ms - 600_000, now: now, timeZone: utc) + " from Mac mini")
        // Something newer reached GitHub from elsewhere: only its date, no Mac name that would be wrong.
        row.lastBackedUpAt = ms - 60_000
        XCTAssertFalse(BackendCodeBackupWords.lastBackedUp(row, now: now, timeZone: utc).contains(" from "))
    }

    func testTheRepositoryLinkIsItsGitHubPage() {
        XCTAssertEqual(BackendCodeBackupActions.link(host: "github.com", home: "someone/notes"), "https://github.com/someone/notes")
        XCTAssertNil(BackendCodeBackupActions.link(host: "github.com", home: nil))
        XCTAssertNil(BackendCodeBackupActions.link(host: "github.com", home: "not-a-repository"))
    }

    func testTheLedgerKeepsWhenThisMacSentAndReadsOlderFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mac-tidy-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(BackendCodeBackupLedger.fileName)
        // An older build's file has no "sent": it still reads, with everything else kept.
        try Data(#"{"modes":{"p1":"off"},"firstBackupDone":true}"#.utf8).write(to: file)
        let old = BackendCodeBackupLedger(file: file)
        XCTAssertEqual(old.mode("p1"), .off); XCTAssertTrue(old.firstBackupDone); XCTAssertNil(old.sentAt("p1"))
        old.setSent("p1", at: 42)
        XCTAssertEqual(BackendCodeBackupLedger(file: file).sentAt("p1"), 42)
        XCTAssertEqual(BackendCodeBackupLedger(file: file).mode("p1"), .off)
    }

    func testNotFoundOnGitHubIsPlainWords() {
        XCTAssertFalse(BackendCodeBackupWords.notFoundOnGitHub.contains("/"))
        XCTAssertTrue(BackendCodeBackupWords.notFoundOnGitHub.contains("Back up now"), "names the one button that fixes it")
    }
}
