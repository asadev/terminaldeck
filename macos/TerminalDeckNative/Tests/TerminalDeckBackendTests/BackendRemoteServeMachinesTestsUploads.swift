import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendRemoteServeMachinesTestsUploads: XCTestCase {
    private typealias F = BackendRemoteServeMachinesTestsFixture
    private func receive(_ receiver: BackendUploadReceive, _ tag: String, id: String = "up-1",
                         fields: [NativeRPCValue.Field] = [], context: BackendRemoteHostContext) async throws -> [NativeRPCValue] {
        try await receiver.handle(F.message(tag, [.init("id", .string(id))] + fields), context: context).map(\.value)
    }
    private func begin(_ receiver: BackendUploadReceive, name: String, size: Int, id: String = "up-1", context: BackendRemoteHostContext) async throws -> NativeRPCValue {
        let frames = try await receive(receiver, "upload.begin", id: id, fields: [.init("name", .string(name)), .init("size", .number(Double(size)))], context: context)
        return try XCTUnwrap(frames.first)
    }
    private func data(_ receiver: BackendUploadReceive, bytes: Data, id: String = "up-1", context: BackendRemoteHostContext) async throws -> [NativeRPCValue] {
        try await receive(receiver, "upload.data", id: id, fields: [.init("data", .string(bytes.base64EncodedString()))], context: context)
    }
    private func end(_ receiver: BackendUploadReceive, hash: String, id: String = "up-1", context: BackendRemoteHostContext) async throws -> NativeRPCValue {
        let frames = try await receive(receiver, "upload.end", id: id, fields: [.init("sha256", .string(hash))], context: context)
        return try XCTUnwrap(frames.first)
    }
    private func upload(_ receiver: BackendUploadReceive, bytes: Data, name: String, chunk: Int = 8, id: String = "up-1", context: BackendRemoteHostContext) async throws -> [NativeRPCValue] {
        var frames = [try await begin(receiver, name: name, size: bytes.count, id: id, context: context)]
        for at in stride(from: 0, to: bytes.count, by: chunk) {
            frames += try await data(receiver, bytes: bytes.subdata(in: at..<min(bytes.count, at + chunk)), id: id, context: context)
        }
        frames.append(try await end(receiver, hash: F.digest(bytes), id: id, context: context)); return frames
    }
    func testLandedFileUsesPromisedPathAndExactBytes() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let receiver = BackendUploadReceive(destination: { _, _ in directory }), context = F.context(), bytes = F.deterministicBytes(4096)
        let frames = try await upload(receiver, bytes: bytes, name: "holiday.mov", context: context)
        XCTAssertEqual(frames.first?["path"].string, directory.appendingPathComponent("holiday.mov").path)
        XCTAssertEqual(frames.last?["t"].string, "upload.done"); XCTAssertEqual(frames.last?["id"].string, "up-1")
        XCTAssertEqual(frames.last?["bytes"].number, Double(bytes.count)); XCTAssertEqual(frames.last?["path"], frames.first?["path"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("holiday.mov")), bytes); await receiver.stop()
    }
    func testDigestComputedOverLandedFile() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let receiver = BackendUploadReceive(destination: { _, _ in directory }), context = F.context(), bytes = F.deterministicBytes(1024)
        let frames = try await upload(receiver, bytes: bytes, name: "a.bin", context: context)
        XCTAssertEqual(frames.last?["sha256"].string, F.digest(try Data(contentsOf: directory.appendingPathComponent("a.bin"))))
        await receiver.stop()
    }
    func testFolderCreatedOnlyAtFirstUpload() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let target = directory.appendingPathComponent("not/there/yet", isDirectory: true)
        let receiver = BackendUploadReceive(destination: { _, _ in target })
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let ready = try await begin(receiver, name: "x.txt", size: 3, context: F.context())
        XCTAssertEqual(ready["t"].string, "upload.ready"); XCTAssertTrue(FileManager.default.fileExists(atPath: target.path)); await receiver.stop()
    }
    func testEachWrittenSliceAcknowledgedExactly() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let receiver = BackendUploadReceive(destination: { _, _ in directory }), bytes = F.deterministicBytes(64)
        let frames = try await upload(receiver, bytes: bytes, name: "a.bin", chunk: 16, context: F.context())
        let acknowledgements = frames.filter { $0["t"].string == "upload.ack" }
        XCTAssertEqual(acknowledgements.count, 4); XCTAssertEqual(acknowledgements.reduce(0) { $0 + ($1["bytes"].number ?? 0) }, 64)
        await receiver.stop()
    }
    func testSecondSameNameGetsSiblingAndNeverOverwritesFirst() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let receiver = BackendUploadReceive(destination: { _, _ in directory }), context = F.context()
        let first = F.deterministicBytes(32), second = F.deterministicBytes(48)
        _ = try await upload(receiver, bytes: first, name: "photo.jpg", context: context)
        let frames = try await upload(receiver, bytes: second, name: "photo.jpg", id: "up-2", context: context)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("photo.jpg")), first)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("photo (2).jpg")), second)
        XCTAssertEqual(frames.last?["path"].string, directory.appendingPathComponent("photo (2).jpg").path); await receiver.stop()
    }
    func testExistingFileNeverOverwritten() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        try Data("mine".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let receiver = BackendUploadReceive(destination: { _, _ in directory })
        _ = try await upload(receiver, bytes: Data("theirs".utf8), name: "notes.txt", context: F.context())
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("notes.txt")), Data("mine".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("notes (2).txt")), Data("theirs".utf8)); await receiver.stop()
    }
    func testCancelDeletesEveryPartialByte() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let receiver = BackendUploadReceive(destination: { _, _ in directory }), context = F.context()
        _ = try await begin(receiver, name: "big.mov", size: 1_000_000, context: context)
        _ = try await data(receiver, bytes: F.deterministicBytes(512), context: context)
        let cancelled = try await receive(receiver, "upload.cancel", context: context)
        XCTAssertTrue(cancelled.first?["message"].string?.lowercased().contains("cancel") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), []); await receiver.stop()
    }
    func testConnectionCloseDeletesAcknowledgedPartialFile() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let receiver = BackendUploadReceive(destination: { _, _ in directory }), context = F.context()
        _ = try await begin(receiver, name: "big.mov", size: 1_000_000, context: context)
        let ack = try await data(receiver, bytes: F.deterministicBytes(512), context: context)
        XCTAssertEqual(ack.first?["bytes"].number, 512)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["big.mov.part"])
        await receiver.close(connectionID: context.connectionID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), []); await receiver.stop()
    }
    func testChecksumMismatchSaysCorruptAndDeletesFile() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let receiver = BackendUploadReceive(destination: { _, _ in directory }), context = F.context()
        _ = try await begin(receiver, name: "a.bin", size: 256, context: context)
        _ = try await data(receiver, bytes: F.deterministicBytes(256), context: context)
        let failed = try await end(receiver, hash: String(repeating: "f", count: 64), context: context)
        XCTAssertEqual(failed["t"].string, "upload.failed"); XCTAssertTrue(failed["message"].string?.lowercased().contains("corrupt") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), []); await receiver.stop()
    }
    func testExcessBytesRefusedBeforeWriting() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let receiver = BackendUploadReceive(destination: { _, _ in directory }), context = F.context()
        _ = try await begin(receiver, name: "a.bin", size: 10, context: context)
        let failed = try await data(receiver, bytes: F.deterministicBytes(11), context: context)
        XCTAssertEqual(failed.first?["t"].string, "upload.failed"); XCTAssertTrue(failed.first?["message"].string?.lowercased().contains("more bytes") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), []); await receiver.stop()
    }
    func testShortEndNamesActualAndExpectedByteCount() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let receiver = BackendUploadReceive(destination: { _, _ in directory }), context = F.context()
        _ = try await begin(receiver, name: "a.bin", size: 100, context: context)
        _ = try await data(receiver, bytes: F.deterministicBytes(40), context: context)
        let failed = try await end(receiver, hash: String(repeating: "a", count: 64), context: context)
        XCTAssertEqual(failed["t"].string, "upload.failed"); XCTAssertTrue(failed["message"].string?.contains("40 of 100") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), []); await receiver.stop()
    }
    func testSecondUploadRefusedWithoutDisturbingFirst() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let receiver = BackendUploadReceive(destination: { _, _ in directory }), context = F.context()
        let first = try await begin(receiver, name: "a.bin", size: 1_000_000, context: context)
        let second = try await begin(receiver, name: "b.bin", size: 10, id: "up-2", context: context)
        XCTAssertEqual(first["t"].string, "upload.ready"); XCTAssertEqual(second["t"].string, "upload.failed")
        XCTAssertEqual(second["id"].string, "up-2"); XCTAssertTrue(second["message"].string?.lowercased().contains("already sending") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["a.bin.part"]); await receiver.stop()
    }
    func testCancelOvertakesSuspendedDestinationOpen() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let gate = BackendRemoteServeMachinesTestsGate()
        let receiver = BackendUploadReceive(destination: { _, _ in await gate.suspend(); return directory }), context = F.context()
        let opening = Task { try await self.receive(receiver, "upload.begin", fields: [.init("name", .string("a.bin")), .init("size", .number(10))], context: context) }
        await gate.waitUntilEntered()
        let cancelled = try await receive(receiver, "upload.cancel", context: context)
        await gate.release(); let opened = try await opening.value
        XCTAssertTrue(cancelled.first?["message"].string?.lowercased().contains("cancel") == true)
        XCTAssertTrue(opened.isEmpty); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), []); await receiver.stop()
    }
    func testUnknownUploadEndAlwaysGetsFailureReply() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let receiver = BackendUploadReceive(destination: { _, _ in directory })
        let failed = try await end(receiver, hash: String(repeating: "a", count: 64), id: "ghost", context: F.context())
        XCTAssertEqual(failed["t"].string, "upload.failed"); XCTAssertEqual(failed["id"].string, "ghost"); await receiver.stop()
    }
    func testHostileFilenameNeverBecomesPath() {
        for hostile in ["../../etc/passwd", "/etc/passwd", "C:\\Windows\\System32\\drivers\\etc\\hosts", "..\\..\\secret", "a/b/c.txt"] {
            let name = BackendUploadNames.safeName(hostile)
            XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.contains("\\")); XCTAssertFalse(name.isEmpty)
        }
    }
    func testEmptyHiddenAndTrailingDotNamesNormalized() {
        for invalid in ["..", ".", "", "   "] { XCTAssertEqual(BackendUploadNames.safeName(invalid), "file") }
        XCTAssertEqual(BackendUploadNames.safeName(".hidden.jpg"), "hidden.jpg")
        XCTAssertEqual(BackendUploadNames.safeName("report.txt."), "report.txt")
    }
    func testRealPhotoSpacesAndPunctuationPreserved() {
        for name in ["Screenshot 2026-08-14 at 02.31.png", "Asad's notes (final) & co.pdf"] { XCTAssertEqual(BackendUploadNames.safeName(name), name) }
    }
    func testFilenameByteCapKeepsExtensionAndWholeUnicodeScalar() {
        let capped = BackendUploadNames.safeName(String(repeating: "🙂", count: 200) + ".mov")
        XCTAssertLessThanOrEqual(capped.utf8.count, 255); XCTAssertTrue(capped.hasSuffix(".mov")); XCTAssertFalse(capped.contains("�"))
    }
}
