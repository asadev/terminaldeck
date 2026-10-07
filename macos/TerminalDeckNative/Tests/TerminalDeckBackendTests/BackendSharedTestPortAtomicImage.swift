import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendSharedTestPortAtomicImage: XCTestCase {
    func testAtomicSuccessDistinctWritersAndPosixFailure() throws {
        var files: [String: String] = [:], writes: [String] = [], renames = 0, unlinks = 0
        let ops = BackendSharedAtomicWriteOperations(writeFile: { path, value in files[path] = value; writes.append(path) }, rename: { from, to in renames += 1; files[to] = files.removeValue(forKey: from) }, unlink: { path in files[path] = nil; unlinks += 1 })
        let first = BackendSharedAtomicWrite(), second = BackendSharedAtomicWrite()
        try first.write(file: "/fixture/state.json", contents: "one", operations: ops)
        try second.write(file: "/fixture/state.json", contents: "two", operations: ops)
        XCTAssertEqual(renames, 2); XCTAssertEqual(unlinks, 0); XCTAssertEqual(Set(writes).count, 2)
        XCTAssertEqual(files, ["/fixture/state.json": "two"])
        try first.write(file: "/fixture/state.json", contents: "{\"first\":true}", operations: ops)
        try first.write(file: "/fixture/state.json", contents: "{\"second\":true}", operations: ops)
        XCTAssertEqual(files["/fixture/state.json"], "{\"second\":true}")
        XCTAssertEqual(Array(files.keys), ["/fixture/state.json"])
        let a = first.tempNameFor("C:\\app\\state.json", pid: 4242), b = first.tempNameFor("C:\\app\\state.json", pid: 4242), other = first.tempNameFor("C:\\app\\state.json", pid: 9999)
        XCTAssertTrue(a.contains("4242")); XCTAssertNotEqual(a, b); XCTAssertNotEqual(a, other); XCTAssertTrue(a.hasPrefix("C:\\app\\state.json.")); XCTAssertTrue(a.hasSuffix(".tmp"))
        // The string contract applies on Mac too; no Windows filesystem is used.
        var calls: [String] = []
        let refused = BackendSharedAtomicWriteOperations(writeFile: { _, _ in calls.append("write") }, rename: { _, _ in calls.append("rename"); throw NSError(domain: NSPOSIXErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "EPERM"]) }, unlink: { _ in calls.append("unlink") })
        XCTAssertThrowsError(try first.write(file: "/fixture/state.json", contents: "{}", operations: refused)) { XCTAssertTrue($0.localizedDescription.contains("EPERM")) }
        XCTAssertEqual(calls, ["write", "rename", "unlink"])
    }
    private func header(_ width: UInt32, _ height: UInt32) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13] + Array("IHDR".utf8)
        for value in [width, height] { bytes += [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
        return Data(bytes)
    }
    func testEveryPngSignatureChunkAndOwnDimensions() throws {
        let png = header(1600, 900)
        let image = try XCTUnwrap(BackendSharedMarkedImage.decodePngDataUrl(.string(BackendSharedMarkedImage.dataUrlPrefix + png.base64EncodedString())))
        XCTAssertEqual(image.width, 1600); XCTAssertEqual(image.height, 900)
        let three = header(3, 7)
        let small = try XCTUnwrap(BackendSharedMarkedImage.decodePngDataUrl(.string(BackendSharedMarkedImage.dataUrlPrefix + three.base64EncodedString())))
        XCTAssertEqual(small.bytes, three); XCTAssertEqual(small.width, 3); XCTAssertEqual(small.height, 7)
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0] + Array(repeating: UInt8(0), count: 40))
        XCTAssertNil(BackendSharedMarkedImage.readPngSize(jpeg))
        var wrongChunk = header(10, 10); wrongChunk.replaceSubrange(12..<16, with: Data("IDAT".utf8))
        XCTAssertNil(BackendSharedMarkedImage.readPngSize(wrongChunk))
        XCTAssertNil(BackendSharedMarkedImage.readPngSize(Data([0x89, 0x50, 0x4e, 0x47])))
        for media in ["image/jpeg", "text/html"] { XCTAssertNil(BackendSharedMarkedImage.decodePngDataUrl(.string("data:\(media);base64," + png.base64EncodedString()))) }
        let html = Data("<script>alert(1)</script>".utf8)
        XCTAssertNil(BackendSharedMarkedImage.decodePngDataUrl(.string(BackendSharedMarkedImage.dataUrlPrefix + html.base64EncodedString())))
        XCTAssertEqual(BackendSharedMarkedImage.markedName("localhost-3000-20260817-041530.png"), "localhost-3000-20260817-041530-marked.png")
        XCTAssertEqual(BackendSharedMarkedImage.markedName("page"), "page-marked.png")
    }
    func testEveryPngNonStringAndPredecodeLimit() {
        for value in [NativeRPCValue.null, .missing, .number(42), .object([]), .array([]), .bytes(Data(count: 4))] { XCTAssertNil(BackendSharedMarkedImage.decodePngDataUrl(value)) }
        let limit = 4 * ((BackendSharedMarkedImage.maxBytes + 2) / 3)
        let tooLarge = BackendSharedMarkedImage.dataUrlPrefix + String(repeating: "A", count: limit + 8)
        XCTAssertNil(BackendSharedMarkedImage.decodePngDataUrl(.string(tooLarge)))
    }
}
