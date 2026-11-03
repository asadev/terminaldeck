import Foundation
import XCTest
@testable import TerminalDeckBackend

final class BackendOSStoreArchiveTests: XCTestCase {
    func testTarReadsFilesAndModes() throws {
        let bytes = try BackendOSStoreArchiveFixture.tarGzip([.init("item/SKILL.md", "# hello"), .init("item/", type: 53), .init("item/run", "echo hi", mode: 0o755)])
        let files = try XCTUnwrap(BackendOSStoreArchive.read(bytes).files)
        XCTAssertEqual(files.map(\.path), ["item/SKILL.md", "item/run"]); XCTAssertEqual(files[1].mode & 0o111, 0o111)
    }
    func testTarPaxAndLongNames() throws {
        let path = "item/" + String(repeating: "d", count: 120) + "/deep.md"
        let bytes = try BackendOSStoreArchiveFixture.tarGzip([.init("global", BackendOSStoreArchiveFixture.pax("comment", "abc"), type: 103), .init("Pax", BackendOSStoreArchiveFixture.pax("path", path), type: 120), .init("short", "deep")])
        XCTAssertEqual(BackendOSStoreArchive.read(bytes).files?.first?.path, path)
    }
    func testTarRefusesEveryNonFileTypeAndUnsafePath() throws {
        for entry in [BackendOSStoreArchiveFixture.Entry("../../x", "x"), .init("/etc/x", "x"), .init("item/link", type: 49), .init("item/link", type: 50), .init("item/device", type: 51), .init("item/fifo", type: 54)] {
            let bytes = try BackendOSStoreArchiveFixture.tarGzip([entry]); XCTAssertNil(BackendOSStoreArchive.read(bytes).files)
        }
    }
    func testTarDamagedHeadersTruncationCapsAndEmptyRefuse() throws {
        XCTAssertTrue(BackendOSStoreArchive.read(try BackendOSStoreArchiveFixture.tarGzip([.init("a", "a")], corruptChecksum: true)).why?.contains("damaged") == true)
        XCTAssertTrue(BackendOSStoreArchive.read(try BackendOSStoreArchiveFixture.tarGzip([.init("a", "a", statedSize: 900_000)])).why?.contains("cut short") == true)
        XCTAssertNil(BackendOSStoreArchive.read(try BackendOSStoreArchiveFixture.tarGzip([])).files)
        let bytes = try BackendOSStoreArchiveFixture.tarGzip([.init("a", String(repeating: "x", count: 4096))])
        XCTAssertNil(BackendOSStoreArchive.read(bytes, limits: .init(archiveBytes: 2_000_000, totalBytes: 1024, files: 20)).files)
        XCTAssertTrue(BackendOSStoreArchive.read(bytes, limits: .init(archiveBytes: 4, totalBytes: 16_000, files: 20)).why?.contains("larger") == true)
    }
    func testStoredZipAndEncryptedOrSymlinkRefusals() throws {
        let bytes = BackendOSStoreArchiveFixture.storedZip(name: "root/a.md", body: Data("a".utf8))
        XCTAssertEqual(BackendOSStoreArchive.read(bytes).files?.first?.bytes, Data("a".utf8))
        XCTAssertTrue(BackendOSStoreArchive.read(BackendOSStoreArchiveFixture.storedZip(name: "a", body: Data(), attributes: 0xa000 << 16)).why?.contains("symbolic link") == true)
        XCTAssertEqual(BackendOSStoreArchive.read(BackendOSStoreArchiveFixture.storedZip(name: "a", body: Data(), flags: 1)).why, "it is encrypted")
    }
    func testPathRulesAndWrapperSelection() {
        for path in ["", "a//b", "./a", "../a", "C:/a", "/a", "a\\b", "a\0b"] { XCTAssertNil(BackendOSStoreArchive.safePath(path)) }
        let files: [BackendOSStoreArchive.File] = [.init(path: "repo/terminaldeck.json", bytes: Data()), .init(path: "repo/skill/SKILL.md", bytes: Data())]
        let stripped = BackendOSStoreArchive.stripSingleRoot(files); XCTAssertEqual(stripped.map(\.path), ["terminaldeck.json", "skill/SKILL.md"])
        XCTAssertEqual(BackendOSStoreArchive.filesUnder(stripped, directory: "skill").map(\.path), ["SKILL.md"])
        let multiple: [BackendOSStoreArchive.File] = [.init(path: "one/a", bytes: Data()), .init(path: "two/b", bytes: Data())]
        XCTAssertEqual(BackendOSStoreArchive.stripSingleRoot(multiple), multiple)
    }
}
