import Foundation
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Unexpected data (a blank role, a date in another shape, month 13, a server listed twice) is shown or refused, never a crash.
@MainActor @Suite
struct UnexpectedDataTests {
    @Test func blankLineRoleShowsNoRole() {
        #expect(AGTProfileView.roleLine("\n") == "")
        #expect(AGTProfileView.roleLine("\n \n\n") == "")
        #expect(AGTProfileView.roleLine("\nReviews every change\nand more") == "Reviews every change")
    }

    @Test func datesPanelOpensOnThisMonthForADateInAnotherShape() {
        for odd in ["16/10/2026", "2026", "2026-13-01", "2026-00-05", ""] { #expect(TimelinePanel.monthOf(odd) == nil) }
        let month = TimelinePanel.monthOf("2026-10-16")
        #expect(month?.year == 2026 && month?.month == 9)
    }

    @Test func impossibleTaskDateIsShownAsWritten() {
        #expect(Routine.shortDate("2026-13-01") == "2026-13-01")
        #expect(Routine.shortDay("2026-13-01") == "2026-13-01")
        #expect(Routine.shortDate("2026-10-07") == "7 Oct")
        #expect(ActivityFeedRules.relativeDay("2026-13-01", today: "2026-10-18") == "2026-13-01")
    }

    @Test func serverListedTwiceKeepsItsFirstRow() {
        let links = NativeMACHINESServersDashboard.projectLinks(CodingAIJSON([
            ["id": "fixture-server", "projectId": "first"], ["id": "fixture-server", "projectId": "second"], ["id": "other"]]))
        #expect(links == ["fixture-server": "first", "other": "independent"])
    }
}
