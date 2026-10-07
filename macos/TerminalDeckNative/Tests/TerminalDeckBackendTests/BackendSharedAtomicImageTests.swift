import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendSharedAtomicImageTests: XCTestCase {
    func testAtomicWriteOneMacAttemptAndCleanup() {
        var log: [String] = []
        let operations = BackendSharedAtomicWriteOperations(writeFile: { path, _ in log.append("write " + path) }, rename: { _, _ in log.append("rename"); throw NSError(domain: NSPOSIXErrorDomain, code: 1) }, unlink: { _ in log.append("unlink") })
        let writer = BackendSharedAtomicWrite()
        XCTAssertThrowsError(try writer.write(file: "/tmp/state.json", contents: "{}", operations: operations))
        XCTAssertEqual(log.filter { $0 == "rename" }.count, 1); XCTAssertEqual(log.last, "unlink")
        let first = writer.tempNameFor("/tmp/state.json", pid: 4242), second = writer.tempNameFor("/tmp/state.json", pid: 4242)
        XCTAssertNotEqual(first, second); XCTAssertTrue(first.hasPrefix("/tmp/state.json.4242.")); XCTAssertTrue(first.hasSuffix(".tmp"))
        XCTAssertNotEqual(second, BackendSharedAtomicWrite().tempNameFor("/tmp/state.json", pid: 4242))
    }
    func testAtomicWriteActuallyReplacesTemporaryFixture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendSharedAtomic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        let writer = BackendSharedAtomicWrite()
        try writer.write(file: file.path, contents: "first")
        try writer.write(file: file.path, contents: "second")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["state.json"])
    }
    private func header(width: UInt32, height: UInt32) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13] + Array("IHDR".utf8)
        for value in [width, height] { bytes += [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
        return Data(bytes)
    }
    func testPngOwnHeaderAndMediaTypeBoundary() throws {
        let bytes = header(width: 2048, height: 1280)
        let image = try XCTUnwrap(BackendSharedMarkedImage.decodePngDataUrl(.string("data:image/png;base64," + bytes.base64EncodedString())))
        XCTAssertEqual(image.width, 2048); XCTAssertEqual(image.height, 1280); XCTAssertEqual(image.bytes, bytes)
        for bad in ["data:image/jpeg;base64," + bytes.base64EncodedString(), "data:image/png;base64,../../etc/passwd", "data:image/png;base64,"] { XCTAssertNil(BackendSharedMarkedImage.decodePngDataUrl(.string(bad))) }
        XCTAssertNil(BackendSharedMarkedImage.decodePngDataUrl(.number(5)))
        XCTAssertNil(BackendSharedMarkedImage.readPngSize(header(width: 0, height: 7)))
        XCTAssertNil(BackendSharedMarkedImage.readPngSize(Data([0x89, 0x50])))
        XCTAssertEqual(BackendSharedMarkedImage.markedName("page.png"), "page-marked.png")
        XCTAssertEqual(BackendSharedMarkedImage.markedName("page"), "page-marked.png")
    }
}
