import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendRemoteServeMachinesTestsSender: XCTestCase {
    private typealias F = BackendRemoteServeMachinesTestsFixture
    private func failure(_ file: URL) async -> String {
        let sender = BackendUploadSend(authorize: { file, _ in file }, onProgress: { _ in })
        let guest = F.guest() // Never connected: no channel, deadline or socket starts.
        do { _ = try await sender.send(file: file, directory: nil, guest: guest, context: .init(caller: .nativeApp, ownerID: "fixture")); XCTFail("A rejected drop was accepted"); return "" }
        catch { return error.localizedDescription }
    }
    func testMissingSourceRefusedBeforeAnnouncingUpload() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let message = await failure(directory.appendingPathComponent("gone.png"))
        XCTAssertEqual(message, "That file could not be read.")
    }
    func testDirectoryRefusedAsUploadSource() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let message = await failure(directory)
        XCTAssertFalse(message.isEmpty)
    }
    func testEmptyFileHasSourceSpecificRefusal() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let file = directory.appendingPathComponent("empty.txt"); try Data().write(to: file)
        let message = await failure(file); XCTAssertEqual(message, "That file is empty.")
    }
    func testOversizedSparseFileNamesCeilingBeforeAnnouncingUpload() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let file = directory.appendingPathComponent("huge.mov"); try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 536870913); try handle.close()
        let message = await failure(file)
        XCTAssertTrue(message.contains("too big")); XCTAssertTrue(message.contains("537 MB"))
    }
    func testDisconnectedMachineRefusedWithoutWaitingForReply() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let file = directory.appendingPathComponent("clip.mov"); try F.deterministicBytes(64).write(to: file)
        let message = await failure(file); XCTAssertEqual(message, "That machine is not connected.")
    }
    func testSupplementalIdleSenderIgnoresLateFramesAndCancel() async {
        let sender = BackendUploadSend(authorize: { file, _ in file }, onProgress: { _ in XCTFail("An idle sender published progress") })
        await sender.handle(.object([.init("t", .string("upload.ack")), .init("id", .string("old")), .init("bytes", .number(10))]))
        await sender.handle(.object([.init("t", .string("upload.done")), .init("id", .string("old")), .init("path", .string("/x")), .init("bytes", .number(1)), .init("sha256", .string("a"))]))
        let cancelled = await sender.cancel(); XCTAssertFalse(cancelled)
        // Completing the prior transfer in the source test still needs a fake
        // guest transport; this idle-path supplement does not claim that case.
    }
}
