import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Lane T — the usage bar (mirrors usage-bar-model.test.ts and UsageBar.test.tsx).

@Suite("Usage bar")
struct UsageBarTests {
    private let hour = 3_600_000.0

    @Test func reportsDecodeAndDropUnknownSources() throws {
        let raw: [String: Any] = ["sessionId": "s", "reason": "", "readings": [
            ["id": "w", "window": "weekly", "label": "Current week", "used": ["state": "reported", "fraction": 0.42],
             "resets": ["state": "at", "at": 5_000], "observedAt": 100, "source": "claude-usage-api",
             "account": ["id": "p1", "name": "Work", "provider": "claude"]],
            ["id": "x", "source": "made-up"],
        ]]
        let report = try #require(UsageReport.decode(raw))
        #expect(report.readings.count == 1)
        #expect(report.readings[0].used == 0.42 && report.readings[0].reportedAt == 100)
        #expect(report.reason == nil)
        #expect(report.reportedAccount?.name == "Work")
        #expect(UsageReport.decode(["readings": "no"]) == nil)
    }

    @Test func windowNames() {
        func reading(_ window: UsageWindowReading.Window, minutes: Double? = nil, label: String = "") -> UsageWindowReading {
            UsageWindowReading(id: "r", window: window, windowMinutes: minutes, label: label, used: nil, resets: .notReported)
        }
        #expect(reading(.fiveHour).short == "5h")
        #expect(reading(.weekly).short == "Week")
        #expect(reading(.other, minutes: 2880).short == "2d")
        #expect(reading(.other, minutes: 120).short == "2h")
        #expect(reading(.other, minutes: 45).short == "45m")
        #expect(reading(.other).short == "Limit")
    }

    @Test func readoutsSayWhatIsKnown() {
        let fixed: (Double, Double) -> String = { _, _ in "5 pm" }
        let now = 10 * hour
        let live = UsageReadout.of(UsageWindowReading(id: "a", window: .fiveHour, used: 0.75, resets: .at(now + hour),
                                                      observedAt: now, reportedAt: now), now: now, format: fixed)
        #expect(live.state == .live && live.value == "75%" && live.level == .warning && live.bar)
        #expect(live.detail == "75% used · renews 5 pm · read just now")
        let aged = UsageReadout.of(UsageWindowReading(id: "a", window: .fiveHour, used: 0.1, resets: .at(now + hour),
                                                      reportedAt: now - hour), now: now, format: fixed)
        #expect(aged.state == .aged)
        let expired = UsageReadout.of(UsageWindowReading(id: "a", window: .fiveHour, used: 0.5, resets: .at(now - 1),
                                                         reportedAt: now - 3 * hour), now: now, format: fixed)
        #expect(expired.state == .expired && expired.value == "Not reported" && !expired.bar)
        #expect(expired.detail == "Last 50% 3h ago · reset 5 pm")
        let unmeasured = UsageReadout.of(UsageWindowReading(id: "a", window: .weekly, used: nil, resets: .described("Monday")), now: now)
        #expect(unmeasured.state == .unmeasured && unmeasured.detail == "Renews Monday")
        let noReset = UsageReadout.of(UsageWindowReading(id: "a", window: .weekly, used: 0.004, resets: .notReported, reportedAt: now), now: now)
        #expect(noReset.state == .noReset && noReset.value == "<1%")
        #expect(UsageBarRules.worst([live, aged])?.percent == 75)
    }

    @Test func theContextWindow() throws {
        let now = 1_000_000.0
        let reading = try #require(ContextReading.decode(["state": "ok", "tokens": 142_000, "window": 1_000_000, "percent": 14.2,
                                                          "model": "claude-opus-5", "modelLabel": "Opus 5", "reportedAt": now,
                                                          "source": ["sessionId": "abc", "chosen": "inferred", "rivals": 1]]))
        #expect(reading.isFresh(now: now))
        #expect(!reading.isFresh(now: now + 10 * 60_000))
        #expect(reading.figure() == "142k")
        #expect(reading.share == 14.2)
        let panel = try #require(reading.panel(now: now))
        #expect(panel.headline == "142k / 1M (14%)")
        #expect(panel.segments.map(\.key) == ["used", "free"])
        #expect(panel.facts.map(\.label) == ["Model"])
        #expect(reading.provenance(now: now).contains("which this app picked as the folder’s most recent conversation"))
        #expect(reading.summary(now: now)?.hasPrefix("Context 142k of 1M (14%).") == true)
        #expect(ContextReading.decode(["state": "weird"]) == nil)
        let none = ContextReading(state: .nothingYet, tokens: nil, window: nil, percent: nil, reportedAt: now)
        #expect(none.figure() == nil && none.panel(now: now) == nil)
    }

    @Test func panelsOpenOnHoverAndHoldOnAPress() {
        var state = UsagePanelState.shut
        state = state.next(.hover(.plan))
        #expect(state.open == .plan && !state.pinned)
        #expect(UsagePanelState.opensPlan(.shut, state))
        let pinned = state.next(.press(.plan))
        #expect(pinned.pinned)
        #expect(pinned.next(.leave) == pinned)
        #expect(pinned.next(.hover(.context)) == pinned)
        #expect(pinned.next(.press(.plan)) == .shut)
        #expect(state.next(.leave) == .shut)
    }

    @Test func statusAndNotes() {
        #expect(UsageBarRules.planStatus(unwired: false, withheld: nil, noLimits: false, blocked: nil, fetching: true, reported: false) == "reading")
        #expect(UsageBarRules.planStatus(unwired: false, withheld: "x", noLimits: true, blocked: nil, fetching: false, reported: false) == "withheld")
        #expect(UsageBarRules.panelNote(unwired: false, withheld: nil, blocked: nil, failed: true, detail: "Nope.", reason: nil, rows: 3) == "Nope.")
        #expect(UsageBarRules.panelNote(unwired: false, withheld: nil, blocked: nil, failed: false, detail: nil, reason: "Why", rows: 2) == nil)
        let answer = UsageBarRules.outcome(["ok": false, "outcome": "no-limits"])
        #expect(answer.settled && answer.noLimits && answer.detail == "This login has no subscription limits, so there is nothing to read.")
        #expect(UsageBarRules.title(readouts: [], whose: "Claude Code", unwired: false, withheld: nil, blocked: nil, report: nil)
                == "Claude Code — Asking this session what it has used…")
    }
}
