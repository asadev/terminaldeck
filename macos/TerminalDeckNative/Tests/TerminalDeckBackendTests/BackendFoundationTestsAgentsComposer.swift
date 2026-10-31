import XCTest
@testable import TerminalDeckBackend

/// agent-controls.ts's reachable composer reader; other controls lack a
/// native SessionAccess/applyControl seam and are enumerated in the handoff.
final class BackendFoundationTestsAgentsComposer: XCTestCase {
    private let footer = "──── ultracode ─\n❯\n────\n  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    private func kind(_ screen: String) -> String {
        switch BackendTaskBriefDelivery.composer(screen) {
        case .ready: return "ready"
        case .typing: return "typing"
        case .choosing: return "choosing"
        case .working: return "working"
        case .unknown: return "unknown"
        }
    }
    // src/main/agent-controls.test.ts:547
    func testEmptyPromptIsReady() { XCTAssertEqual(kind(footer), "ready") }
    // src/main/agent-controls.test.ts:551
    func testDraftIsReadWithoutTypingOverIt() {
        let screen = "──── Update Claude Code terminal to new version ──\n❯ remind me to buy milk\n────\n\n  ⏵⏵ bypass permissions on (shift+tab to cycle)"
        guard case .typing(let text) = BackendTaskBriefDelivery.composer(screen) else { return XCTFail("Expected typing") }
        XCTAssertEqual(text, "remind me to buy milk")
    }
    // src/main/agent-controls.test.ts:559
    func testSelectedModalRowIsChoosingRatherThanDraftText() {
        guard case .choosing(let text) = BackendTaskBriefDelivery.composer("Switch model?\n   ❯ 1. Yes, switch to Sonnet 5\n     2. No, go back") else { return XCTFail("Expected choosing") }
        XCTAssertTrue(text.contains("Yes, switch to Sonnet 5"))
    }
    // src/main/agent-controls.test.ts:567
    func testTrustPromptOwnsTheKeyboard() { XCTAssertEqual(kind("   ❯ 1. Yes, I trust this folder\n     2. No, exit\n\n Enter to confirm · Esc to cancel"), "choosing") }
    // src/main/agent-controls.test.ts:572 (composer half; classify belongs to sessions owner).
    func testFullscreenCounterMeansWorkingEvenWithEmptyPrompt() {
        XCTAssertEqual(kind("⏺ Sleeping for 25 seconds\n  ⎿  $ sleep 25\n\n✶ Dilly-dallying… (5s · ↓ 90 tokens)\n\n" + footer), "working")
    }
    // src/main/agent-controls.test.ts:597
    func testFirstTurnFrameMeansWorkingBeforeCounterAppears() { XCTAssertEqual(kind("⏺\n✶ Galloping… \n  ⎿  Tip: Use /permissions to pre-approve\n❯ "), "working") }
    // src/main/agent-controls.test.ts:605
    func testFinishedTurnTimingDoesNotKeepControlsBusy() {
        for line in ["✻ Baked for 6s · 1 shell still running", "✻ Cogitated for 11s", "✻ Cooked for 1s"] { XCTAssertEqual(kind(line + "\n❯ "), "ready", line) }
    }
    // src/main/agent-controls.test.ts:617
    func testOrdinaryOutputBulletWithEllipsisIsNotWorking() { XCTAssertEqual(kind("⏺ Started sleep 20 in the background; I will report when it finishes…\n❯ "), "ready") }
    // src/main/agent-controls.test.ts:623
    func testInterruptMarkerMeansWorking() { XCTAssertEqual(kind("⏺ Reading agent-controls.ts…\n  ⎿  (esc to interrupt · 12s)\n❯ "), "working") }
    // src/main/agent-controls.test.ts:628
    func testFinishedTimingLineDoesNotMeanWorking() { XCTAssertEqual(kind("❯ hello\n⏺ Hi.\n✻ Cooked for 1s\n❯ "), "ready") }
    // src/main/agent-controls.test.ts:635
    func testBottomPromptWinsOverPriorMessageEcho() { XCTAssertEqual(kind("❯ hello\n⏺ Hi.\n❯ "), "ready") }
    // src/main/agent-controls.test.ts:642
    func testMissingPromptIsUnknown() { XCTAssertEqual(kind("apple@host tdprobe % "), "unknown") }
}
