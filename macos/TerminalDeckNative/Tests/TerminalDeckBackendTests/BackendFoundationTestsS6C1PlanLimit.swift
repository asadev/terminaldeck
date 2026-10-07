import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// plan-limit.test.ts: the pure parsing half (panel, warning line, label
/// identity, billing banner). The tracker/IPC half is blocked, see NIGHT-REQUESTS.
final class BackendFoundationTestsS6C1PlanLimit: XCTestCase {
    private let panel = """

     ▐▛███▜▌   Claude Code v2.1.228
    ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
       Settings  Status   Config   Usage   Stats

       Session

       Total cost:            $0.0000
       Total duration (API):  0s

       Current session
       ██▌                                                5% used
       Resets 4am (Asia/Dubai)

       Current week (all models)
       ████████████████████████████████████████           80% used
       Resets Aug 14 at 2pm (Asia/Dubai)
       +50% weekly limits promo through Aug 19 · clau.de/cc-50-promo

       Current week (Fable)
       ██████████████████████████████████████████████████ 100% used
       Resets Aug 14 at 2pm (Asia/Dubai)

       What's contributing to your limits usage?

    """
    private let idle = """

     ▐▛███▜▌   Claude Code v2.1.228
    ▝▜█████▛▘  Opus 5 (1M context) with xhigh effort · Claude Max
      ▘▘ ▝▝    ~/Projects/terminaldeck

    ──────────────────────────────────────────────────────────────────────────────
    ❯
    ──────────────────────────────────────────────────────────────────────────────
      ⏵⏵ bypass permissions on (shift+tab to cycle)

    """
    private let bannerMax = "│      Opus 5 with xhigh effort · Claude Max ·       │"
    private let bannerAPI = "Claude Code v2.1.224 · Opus 5 with xhigh effort · Claude API"
    private let bannerNarrow = "│   Opus 5 (1M context) with xhig… · Claude Max ·    │"

    // MARK: the /usage panel
    func testFindsEveryLimitThePanelLists() throws {
        let parsed = try XCTUnwrap(BackendUsagePlanParser.parse(screen: panel))
        XCTAssertEqual(parsed.source, "usage-panel")
        XCTAssertEqual(parsed.limits.map(\.id), ["session", "week", "week:fable"])
    }
    func testKeepsThePercentagesAndTheCLIsOwnResetWording() throws {
        let limits = try XCTUnwrap(BackendUsagePlanParser.parse(screen: panel)).limits
        XCTAssertEqual(limits[0].id, "session"); XCTAssertEqual(limits[0].label, "Current session"); XCTAssertEqual(limits[0].scope, "session")
        XCTAssertEqual(limits[0].percent, 5); XCTAssertEqual(limits[0].resetsAt, "4am (Asia/Dubai)")
        XCTAssertEqual(limits[1].percent, 80); XCTAssertEqual(limits[1].resetsAt, "Aug 14 at 2pm (Asia/Dubai)")
    }
    func testReadsAnExhaustedLimitAs100() throws {
        let limit = try XCTUnwrap(BackendUsagePlanParser.parse(screen: panel)).limits[2]
        XCTAssertEqual(limit.label, "Current week (Fable)"); XCTAssertEqual(limit.percent, 100)
    }
    func testDoesNotLetThePromoLineBecomeAResetTime() throws {
        let limits = try XCTUnwrap(BackendUsagePlanParser.parse(screen: panel)).limits
        XCTAssertFalse(limits.contains { $0.resetsAt?.contains("promo") == true })
    }

    // MARK: a warning line
    func testParsesThePercentTheLimitAndTheResetOutOfOneSentence() throws {
        let text = "You've used 85% of your weekly limit · resets Aug 14 at 2pm"
        let parsed = try XCTUnwrap(BackendUsagePlanParser.parse(screen: text))
        XCTAssertEqual(parsed.source, "warning"); XCTAssertEqual(parsed.message, text); XCTAssertEqual(parsed.limits.count, 1)
        let l = parsed.limits[0]
        XCTAssertEqual(l.id, "week"); XCTAssertEqual(l.label, "weekly limit"); XCTAssertEqual(l.scope, "week"); XCTAssertEqual(l.percent, 85); XCTAssertEqual(l.resetsAt, "Aug 14 at 2pm")
    }
    func testReportsANamedLimitWithNoNumberRatherThanInventingOne() throws {
        let l = try XCTUnwrap(BackendUsagePlanParser.parse(screen: "⚠ Approaching Opus limit")).limits[0]
        XCTAssertEqual(l.id, "week:opus"); XCTAssertNil(l.percent)
    }
    func testHandlesATypographicApostrophe() throws {
        let l = try XCTUnwrap(BackendUsagePlanParser.parse(screen: "You’ve used 92% of your session limit")).limits[0]
        XCTAssertEqual(l.id, "session"); XCTAssertEqual(l.percent, 92); XCTAssertNil(l.resetsAt)
    }
    func testTakesTheNewestLineWhenTheScreenHoldsTwo() throws {
        let screen = ["You've used 40% of your weekly limit", "You've used 85% of your weekly limit"].joined(separator: "\n")
        XCTAssertEqual(try XCTUnwrap(BackendUsagePlanParser.parse(screen: screen)).limits[0].percent, 85)
    }

    // MARK: not mistaking agent output
    func testReportsNothingOnAnOrdinaryScreen() { XCTAssertNil(BackendUsagePlanParser.parse(screen: idle)) }
    func testIgnoresALimitTheAgentIsTalkingAbout() {
        XCTAssertNil(BackendUsagePlanParser.parse(screen: "You've hit your retry limit — backing off"))
        XCTAssertNil(BackendUsagePlanParser.parse(screen: "Approaching the GitHub API rate limit"))
    }
    func testAcceptsOnlyLabelsThatNameARealLimitWindow() {
        // isLimitLabel is folded into parse() here, so it is checked through the warning sentence.
        XCTAssertNotNil(BackendUsagePlanParser.parse(screen: "You've used 50% of your weekly limit"))
        XCTAssertNotNil(BackendUsagePlanParser.parse(screen: "Approaching Opus limit"))
        XCTAssertNil(BackendUsagePlanParser.parse(screen: "You've used 50% of your retry limit"))
    }
    func testLandsThePanelAndWarningSpellingsOfOneLimitOnOneKey() {
        XCTAssertEqual(BackendUsagePlanLimit.identify("week all models").id, BackendUsagePlanLimit.identify("weekly limit").id)
        XCTAssertEqual(BackendUsagePlanLimit.identify("session").id, BackendUsagePlanLimit.identify("session limit").id)
        XCTAssertEqual(BackendUsagePlanLimit.identify("week Opus").id, BackendUsagePlanLimit.identify("Opus limit").id)
    }

    // MARK: billing banner
    func testTellsASubscriptionFromAMeteredAccount() {
        XCTAssertEqual(BackendUsagePlanParser.billing(screen: bannerMax), "subscription")
        XCTAssertEqual(BackendUsagePlanParser.billing(screen: bannerNarrow), "subscription")
        XCTAssertEqual(BackendUsagePlanParser.billing(screen: bannerAPI), "api")
        XCTAssertEqual(BackendUsagePlanParser.billing(screen: "  Opus 5 with xhigh effort · Bedrock ·"), "api")
        XCTAssertEqual(BackendUsagePlanParser.billing(screen: "  Opus 5 with xhigh effort · API Usage Billing"), "api")
    }
    func testSaysNothingRatherThanGuessingAtATruncatedLabel() {
        XCTAssertNil(BackendUsagePlanParser.billing(screen: "│ Opus 5 with xhi… · Claude M… │"))
        XCTAssertNil(BackendUsagePlanParser.billing(screen: ""))
    }
    func testDoesNotReadABannerOutOfOrdinaryConversation() {
        XCTAssertNil(BackendUsagePlanParser.billing(screen: "I would go with more effort here. Claude API is fine."))
        XCTAssertNil(BackendUsagePlanParser.billing(screen: "Claude Max is the plan you want"))
    }
    func testFindsTheBannerOnTheRealIdleScreen() { XCTAssertEqual(BackendUsagePlanParser.billing(screen: idle), "subscription") }
}
