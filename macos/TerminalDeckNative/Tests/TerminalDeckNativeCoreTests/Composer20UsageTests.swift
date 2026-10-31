import Testing
@testable import TerminalDeckNativeCore

@Suite("Composer20: plain account usage summaries")
struct Composer20UsageTests {
    @Test(arguments: ["claude", "codex"])
    func theFiveHourAndWeeklyWindowsSayUsedAndReset(provider: String) {
        let account = UsageAccountRef(provider: provider, id: "work", name: "Work")
        let report = UsageReport(readings: [
            .init(id: "five", account: account, window: .fiveHour, used: 0.25, resets: .at(2_000), reportedAt: 1_000),
            .init(id: "week", account: account, window: .weekly, used: 0.8, resets: .described("Friday at 9:00 AM"), reportedAt: 1_000)
        ], account: account)
        let rows = SessionChatUsageSummary.rows(report, now: 1_000, formatReset: { _, _ in "3:00 PM" })
        #expect(rows.map(\.summary) == ["5-hour window: 25% used. Resets 3:00 PM.", "Weekly window: 80% used. Resets Friday at 9:00 AM."])
        #expect(rows.map(\.percent) == [25, 80])
    }

    @Test func missingExpiredAndOldReadingsNeverPretendToBeCurrentZeroUsage() {
        #expect(SessionChatUsageSummary.rows(nil).isEmpty)
        let report = UsageReport(readings: [
            .init(id: "expired", window: .fiveHour, used: 0.95, resets: .at(1_000), reportedAt: 1),
            .init(id: "missing", window: .weekly, used: nil, resets: .notReported),
            .init(id: "old", window: .fiveHour, used: 0.2, resets: .at(99_000_000), reportedAt: 1)
        ])
        let rows = SessionChatUsageSummary.rows(report, now: 9_000_000)
        #expect(rows[0].percent == nil && rows[0].summary.contains("has reset"))
        #expect(rows[1].summary == "Weekly window: Usage not reported. Reset time not reported.")
        #expect(rows[2].percent == 20 && rows[2].note != nil)
    }

    @Test func geminiOnlyShowsExistingReadingsAndKeepsOtherWindowNames() {
        let account = UsageAccountRef(provider: "gemini", id: "work", name: "Work")
        #expect(SessionChatUsageSummary.rows(UsageReport(readings: [], account: account)).isEmpty)
        let report = UsageReport(readings: [.init(id: "daily", account: account, window: .other, label: "Daily limit", used: 0.01, resets: .described("midnight"))])
        #expect(SessionChatUsageSummary.rows(report, now: 1_000).first?.summary == "Daily limit: 1% used. Resets midnight.")
    }
}
