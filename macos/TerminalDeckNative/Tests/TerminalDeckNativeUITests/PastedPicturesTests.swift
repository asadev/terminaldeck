import Foundation
import XCTest
@testable import TerminalDeckNative

/// U144 (#535): a picture pasted into the chat box leaves no file behind.
final class PastedPicturesTests: XCTestCase {
    func testPastedPictureGoesWhenRemovedOrSentAndOldOnesAreSwept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PastedPicturesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stale = folder.appendingPathComponent(HootPastedFiles.prefix + "stale.png"), other = folder.appendingPathComponent("someone-else.png")
        for file in [stale, other] { try Data("x".utf8).write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 3_600)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 3_600)], ofItemAtPath: other.path)

        let pasted = try HootPastedFiles.make(Data("png".utf8), type: "png", in: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pasted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "A week-old pasted picture is swept.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "Files the box did not make are never touched.")

        HootPastedFiles.discard([pasted, other], in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pasted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}
