import Foundation
import XCTest
@testable import TerminalDeckBackend

final class BackendAppDeckignoreTests: XCTestCase {
    func testMergeNegationAncestorAndCacheVariants() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendAppIgnore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("dist/*\nsecret.txt\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("!dist/preview.html\nlogs/\n!logs/important.log\n".utf8).write(to: root.appendingPathComponent(".deckignore"))
        let service = BackendAppDeckignore()
        let merged = await service.ignore(root: root.path), alone = await service.ignore(root: root.path, includeGitignore: false)
        XCTAssertTrue(merged.ignored("secret.txt", directory: false)); XCTAssertFalse(alone.ignored("secret.txt", directory: false))
        XCTAssertFalse(merged.ignored("dist/preview.html", directory: false)); XCTAssertTrue(merged.ignored("dist/app.js", directory: false))
        XCTAssertEqual(merged.explain("logs/important.log", directory: false)["viaAncestor"].string, "logs")
        let again = await service.ignore(root: root.path); XCTAssertTrue(again === merged)
        await service.invalidate(root: root.path)
        let fresh = await service.ignore(root: root.path); XCTAssertFalse(fresh === merged)
        for index in 0..<70 { _ = await service.ignore(root: root.appendingPathComponent("absent-\(index)").path) }
        let evicted = await service.ignore(root: root.path); XCTAssertFalse(evicted === fresh)
    }
    func testExactByteCapAndLineProvenance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendAppIgnore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".deckignore")
        let text = String(repeating: "#", count: BackendAppDeckignore.maxBytes - 7) + "\n*.log\n"
        XCTAssertEqual(text.utf8.count, BackendAppDeckignore.maxBytes)
        try Data(text.utf8).write(to: file)
        let service = BackendAppDeckignore(), exact = await service.load(root: root.path)
        XCTAssertTrue(exact.ignored("a.log", directory: false)); XCTAssertEqual(exact.explain("a.log", directory: false)["rule"]["line"].number, 2)
        try Data((text + "x").utf8).write(to: file)
        let over = await service.load(root: root.path)
        XCTAssertEqual(over.sources.last?["skipped"].string, "too-large"); XCTAssertFalse(over.ignored("a.log", directory: false))
        XCTAssertTrue(over.explain("node_modules/a.js", directory: false)["alwaysIgnored"].bool == true)
    }
}
