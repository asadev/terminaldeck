import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// local-stage.test.ts against a real temporary folder.
final class BackendFoundationTestsS6C1LocalStage: XCTestCase {
    private struct S6C1Boom: Error {}
    private func transfers(_ folder: URL) -> BackendFilesystemTransfers {
        BackendFilesystemTransfers(authority: .init(scope: { _ in .local }), uploadsDirectory: { folder })
    }
    private func path(_ value: NativeRPCValue, file: StaticString = #filePath, line: UInt = #line) -> String? {
        XCTAssertEqual(value["ok"].bool, true, file: file, line: line); return value["path"].string
    }

    func testAnswersAPathThatExistsInTheGivenFolderWithTheBytes() async throws {
        let fixture = try BackendFoundationTestsBFixture("s6c1-stage-1")
        let out = await transfers(fixture.root).stage(name: "pasted.png", bytes: Data("pixels".utf8))
        let p = try XCTUnwrap(path(out))
        XCTAssertEqual(URL(fileURLWithPath: p).deletingLastPathComponent().resolvingSymlinksInPath().path, fixture.root.resolvingSymlinksInPath().path)
        XCTAssertEqual(try String(contentsOfFile: p, encoding: .utf8), "pixels")
    }

    func testSecondPasteOfTheSameNameLandsBesideTheFirst() async throws {
        let fixture = try BackendFoundationTestsBFixture("s6c1-stage-2"), t = transfers(fixture.root)
        let firstStaged = await t.stage(name: "pasted.png", bytes: Data("one".utf8))
        let first = try XCTUnwrap(path(firstStaged))
        let secondStaged = await t.stage(name: "pasted.png", bytes: Data("two".utf8))
        let second = try XCTUnwrap(path(secondStaged))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOfFile: first, encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOfFile: second, encoding: .utf8), "two")
    }

    func testCallerNamesAFileNeverALocation() async throws {
        let fixture = try BackendFoundationTestsBFixture("s6c1-stage-3")
        let staged = await transfers(fixture.root).stage(name: "../../../etc/passwd", bytes: Data("nope".utf8))
        let p = try XCTUnwrap(path(staged))
        let url = URL(fileURLWithPath: p)
        XCTAssertEqual(url.deletingLastPathComponent().resolvingSymlinksInPath().path, fixture.root.resolvingSymlinksInPath().path)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
    }

    func testRefusesAnEmptyClipboard() async throws {
        let fixture = try BackendFoundationTestsBFixture("s6c1-stage-4")
        let out = await transfers(fixture.root).stage(name: "x.png", bytes: Data())
        XCTAssertEqual(out["ok"].bool, false)
        XCTAssertEqual(out["message"].string, "There was nothing to send.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }

    func testAnswersASentenceRatherThanThrowingWhenTheFolderCannotBeMade() async throws {
        let fixture = try BackendFoundationTestsBFixture("s6c1-stage-5")
        try fixture.write("a-file", "x")
        let blocked = fixture.file("a-file/under/it")
        let out = await transfers(blocked).stage(name: "x.png", bytes: Data("x".utf8))
        XCTAssertEqual(out["ok"].bool, false)
        XCTAssertEqual(out["message"].string, "That could not be saved on this machine.")
        let failing = BackendFilesystemTransfers(authority: .init(scope: { _ in .local }), uploadsDirectory: { throw S6C1Boom() })
        let failedStage = await failing.stage(name: "x.png", bytes: Data("x".utf8))
        XCTAssertEqual(failedStage["ok"].bool, false)
    }
}
