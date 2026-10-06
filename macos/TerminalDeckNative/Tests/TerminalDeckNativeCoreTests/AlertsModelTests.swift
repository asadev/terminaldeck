import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Alerts sheet model (mirrors AlertsPanel.test.tsx)")
struct AlertsModelTests {
    let bloat = ProjectAlert(id: "a", kind: "context-bloat", severity: .warning, title: "Context is filling up")
    let blocked = ProjectAlert(id: "b", kind: "session-blocked", severity: .critical, title: "A session asked you")
    let tool = ProjectAlert(id: "c", kind: "provider-missing", severity: .critical, title: "Claude Code is not installed")
    let dirty = ProjectAlert(id: "d", kind: "dirty-tree", severity: .info, title: "Uncommitted changes")

    @Test func summaries() {
        #expect(AlertReport.summary(nil) == "Checking…")
        #expect(AlertReport.summary(AlertReport(alerts: [])) == "Nothing needs your attention.")
        #expect(AlertReport.summary(AlertReport(alerts: [bloat, blocked, tool, dirty])) == "2 needing you now, 1 worth fixing, 1 worth knowing")
    }

    @Test func insightsComeAndGo() {
        let full = AlertReport(alerts: [bloat, blocked, tool, dirty])
        #expect(full.withInsights(true) == full)
        let without = full.withInsights(false)
        #expect(without.alerts.map(\.id) == ["c", "d"])
        #expect(without.count(.critical) == 1 && without.count(.warning) == 0 && without.worst == .critical)
        let onlyInsights = AlertReport(alerts: [bloat])
        #expect(AlertReport.summary(onlyInsights.withInsights(false)) == "Nothing needs your attention.")
        let none = AlertReport(alerts: [tool])
        #expect(none.withInsights(false) == none)
    }

    @Test func groupsWorstFirst() {
        #expect(AlertReport(alerts: []).groups.isEmpty)
        let groups = AlertReport(alerts: [dirty, bloat, tool]).groups
        #expect(groups.map(\.severity) == [.critical, .warning, .info])
        #expect(AlertSeverity.critical.heading == "Needs you now" && AlertSeverity.info.heading == "Worth knowing")
    }

    @Test func sheetStates() throws {
        let json = #"{"projectPath":"/p","report":{"projectPath":"/p","alerts":[{"id":"x","kind":"loop","severity":"warning","title":"t","detail":"d","at":1,"action":{"kind":"focus-session","label":"Show it","target":"s1"}}],"counts":{"info":0,"warning":1,"critical":0},"worst":"warning","scannedAt":2},"busy":false,"error":null,"available":true,"showInsights":false}"#
        let request = try #require(DialogRequest(name: "alerts-sheet", open: true, seq: 1, data: Data(json.utf8)).decode(AlertsRequest.self))
        #expect(request.report?.alerts.first?.action?.label == "Show it")
        #expect(request.shown?.alerts.isEmpty == true, "a loop is an insight, and insights are off")
        #expect(request.quiet && !request.noProject)
        #expect(AlertsRequest(projectPath: nil, report: nil).noProject)
        #expect(AlertsRequest(projectPath: "/p", report: AlertReport(alerts: [tool]), error: "Could not scan").headline == "Could not scan")
        #expect(!AlertsRequest(projectPath: "/p", report: AlertReport(alerts: []), error: "x").quiet)
    }
}
