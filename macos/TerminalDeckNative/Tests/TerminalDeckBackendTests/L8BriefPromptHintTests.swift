import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// L8 (10 Oct, Asad's real app 0.20.2): Claude Code 2.1.x draws a dimmed example in its EMPTY prompt.
/// The screen text has no colours, so every new task worker looked like it had unsent text; the brief was
/// never typed and the launch was stopped after 120 s (exit 129).
final class L8BriefPromptHintTests: XCTestCase {
    let fresh = """
     ▐▛███▜▌   Claude Code v2.1.293
    ▝▜█████▛▘  Fable 5.1 with xhigh effort · Claude Max
      ▘▘ ▝▝    ~/ClaudeiMatch

    ────────────────────────────────────────────────────────────
    ❯ Try "create a util logging.py that..."
    ────────────────────────────────────────────────────────────
      ? for shortcuts
    """

    func testEmptyPromptHintIsAnEmptyPrompt() {
        guard case .ready = BackendTaskBriefDelivery.composer(fresh) else { return XCTFail("the hint read as typed text") }
        XCTAssertEqual(BackendSessionClassifier.classify(viewport: fresh), .waiting)
        XCTAssertNil(BackendDeckCoreBrief.refusal(BackendTaskBriefDelivery.composer(fresh)))
    }

    func testRealTypedTextStillRefuses() {
        let typed = fresh.replacingOccurrences(of: #"Try "create a util logging.py that...""#, with: "fix the login bug")
        guard case .typing(let text) = BackendTaskBriefDelivery.composer(typed) else { return XCTFail("typed text was not seen") }
        XCTAssertEqual(text, "fix the login bug")
        XCTAssertNotEqual(BackendSessionClassifier.classify(viewport: typed), .waiting)
    }

    func testBriefIsTypedIntoAHintedPromptAndSubmitted() async throws {
        final class Fake: BackendDeckCoreBriefSurface, @unchecked Sendable {
            let lock = NSLock(); var screen: String; var writes: [String] = []
            init(_ screen: String) { self.screen = screen }
            func listSessions() -> [NativeRPCValue] { [.object([.init("id", .string("s1")), .init("exitCode", .null)])] }
            func sessionScreen(id: String) async throws -> String? { lock.withLock { screen } }
            func writeToSession(id: String, data: String) async throws {
                lock.withLock {
                    writes.append(data)
                    if data != "\r", data != "\u{15}" { screen = screen.replacingOccurrences(of: #"Try "create a util logging.py that...""#, with: data) }
                }
            }
        }
        let surface = Fake(fresh)
        let line = BackendDeckCoreBrief.deliveryLine("/tmp/brief.md")
        let result = try await BackendDeckCoreBrief.deliver(surface: surface, sessionID: "s1", line: line, timeoutMs: 2_000, pollMs: 1,
            clock: .init(now: { Date().timeIntervalSince1970 * 1000 }, sleep: { _ in await Task.yield() }))
        XCTAssertEqual(result["delivered"], .bool(true), result["reason"].string ?? "")
        XCTAssertEqual(surface.writes, [line, "\r"])
    }

    func testHintDetectorIsNarrow() {
        XCTAssertTrue(BackendSessionClassifier.isEmptyPromptHint(#"Try "fix lint errors""#))
        XCTAssertFalse(BackendSessionClassifier.isEmptyPromptHint("Try the other branch"))
        XCTAssertFalse(BackendSessionClassifier.isEmptyPromptHint(#"Try "a" then "b""#))
    }
}
