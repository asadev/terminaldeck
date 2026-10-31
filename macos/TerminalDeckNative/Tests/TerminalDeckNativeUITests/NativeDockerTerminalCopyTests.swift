import AppKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class NativeDockerTerminalCopyTests: XCTestCase {
    @MainActor final class Uploads {
        var waiting: [CheckedContinuation<(folder: String, paths: [String]), Error>] = []
    }

    /// U56 (#474): a terminal that ends while a file is copied in forgets that copy,
    /// so the next drop copies instead of waiting forever.
    func testEndedTerminalForgetsAnUnfinishedCopy() async throws {
        let uploads = Uploads()
        let transport = NativeDockerTerminalTransport(open: { _, _ in "exec-1" }, write: { _, _ in }, resize: { _, _, _ in }, close: { _ in },
                                                      subscribe: { _, _ in {} },
                                                      upload: { _ in try await withCheckedThrowingContinuation { uploads.waiting.append($0) } })
        let model = NativeDockerTerminalModel(transport: transport)
        model.copyIn(.files([(name: "a.txt", data: Data("a".utf8))]))
        XCTAssertTrue(model.isCopying)
        for _ in 0..<50 where uploads.waiting.isEmpty { await Task.yield() }
        XCTAssertEqual(uploads.waiting.count, 1)

        model.stop()
        XCTAssertFalse(model.isCopying)
        XCTAssertNil(model.note)

        model.copyIn(.files([(name: "b.txt", data: Data("b".utf8))]))
        XCTAssertTrue(model.isCopying)
        XCTAssertTrue(model.note?.hasPrefix("Copying b.txt") == true, model.note ?? "")
        for _ in 0..<50 where uploads.waiting.count < 2 { await Task.yield() }
        // The first copy answers late: it no longer touches the second one.
        uploads.waiting[0].resume(returning: (folder: "/app", paths: ["/app/a.txt"]))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.isCopying)
        uploads.waiting[1].resume(returning: (folder: "/app", paths: ["/app/b.txt"]))
        for _ in 0..<50 where model.isCopying { await Task.yield() }
        XCTAssertFalse(model.isCopying)
        XCTAssertEqual(model.note, "Copied into /app: b.txt")
    }
}
