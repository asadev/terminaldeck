import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U120: the readiness checklist's button says what it does (#159), and a session whose first message
/// failed is still followed (#545).
@MainActor final class AIRReadinessChecklistTests: XCTestCase {
    func testTheRowButtonSaysWhatItWillDo() {
        XCTAssertEqual(NativeAIRReadinessText.primary(isCode: true, canReview: true, automaticFix: true), .review)
        // The panel screen has no review handler: the git row asks an AI, and says so.
        XCTAssertEqual(NativeAIRReadinessText.primary(isCode: true, canReview: false, automaticFix: false).label, "Ask an AI…")
        XCTAssertEqual(NativeAIRReadinessText.primary(isCode: false, canReview: true, automaticFix: true).label, "Fix it")
        XCTAssertEqual(NativeAIRReadinessText.primary(isCode: false, canReview: true, automaticFix: false).label, "Ask an AI…")
    }

    func testASessionWhoseFirstMessageFailedIsStillFollowed() throws {
        let failed = try NativeAIRLaunch.from(["id": "s9", "promptDelivered": false, "promptSent": false, "message": "The prompt did not arrive."])
        XCTAssertEqual(failed, NativeAIRLaunch(id: "s9", problem: "The prompt did not arrive."))
        XCTAssertNil(try NativeAIRLaunch.from(["id": "s8", "promptSent": true]).problem)
        XCTAssertThrowsError(try NativeAIRLaunch.from(["promptDelivered": true]))

        let model = NativeAIRReadinessModel(dependencies: .init(invoke: { channel, _ in throw NativeAIRReadinessError("No transport: " + channel) },
                                                               launchSession: { _ in throw NativeAIRReadinessError("No launch") }))
        let check = ReadinessCheck(id: "test-script", title: "Tests", status: .fail, detail: "Missing.", fix: nil, gate: false, opens: nil)
        model.opened(failed, for: check)
        XCTAssertTrue(model.aiSessions.contains("s9"), "its end still triggers a re-check")
        XCTAssertEqual(model.results["test-script"]?.ok, false)
        XCTAssertEqual(model.results["test-script"]?.message, "The prompt did not arrive.")
    }
}
