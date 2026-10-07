import Foundation
import Testing
@testable import TerminalDeckBackend

private final class BackendCopilotRemoteSayBox: @unchecked Sendable {
    let lock = NSLock()
    var writes: [String] = []
    var delayed: (@Sendable () -> Void)?
    var delay = 0
    var diagnostics: [String] = []
    func record(_ text: String) { lock.withLock { writes.append(text) } }
    func schedule(_ ms: Int, _ callback: @escaping @Sendable () -> Void) { lock.withLock { delay = ms; delayed = callback } }
}
@Suite("Phone prose is submitted as a separate Return key")
struct BackendCopilotRemoteSayTests: Sendable {
    @Test func sentenceAndCarriageReturnAreSeparateChunksWithMeasuredGap() throws {
        let box = BackendCopilotRemoteSayBox(), text = String(repeating: "x", count: 400)
        #expect(BackendCopilotRemoteSurface.submitWrites(text) == [text, "\r"])
        try BackendCopilotRemoteSurface.typeAndSubmit(text, write: { box.record($0) }, deferWrite: { box.schedule($0, $1) })
        #expect(box.writes == [text]); #expect(box.delay == 50)
        box.delayed?(); #expect(box.writes == [text, "\r"])
    }
    @Test func firstWriteThrowsAndDeferredFailureIsDiagnosedWithoutThrowing() throws {
        let box = BackendCopilotRemoteSayBox()
        #expect(throws: BackendSessionFailure.self) {
            try BackendCopilotRemoteSurface.typeAndSubmit("hello", write: { _ in throw BackendSessionFailure.missingSession }, deferWrite: { _, _ in })
        }
        try BackendCopilotRemoteSurface.typeAndSubmit("hello", write: { text in
            if text == "\r" { throw BackendSessionFailure.missingSession }; box.record(text)
        }, deferWrite: { _, callback in callback() }, onDeferredError: { text in box.lock.withLock { box.diagnostics.append(text) } })
        #expect(box.writes == ["hello"]); #expect(box.diagnostics.count == 1)
    }
}
