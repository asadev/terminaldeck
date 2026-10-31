import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// DEPLOY-PIPELINE: the side-panel pill is there only while something deploys; the tools find the caller's own run.
@Suite("Deploy pipeline views and tools", .serialized)
@MainActor
struct DeployPipelineViewTests {
    private let release = DeployActor(kind: "agent", name: "Release", agentID: "release", sessionID: "s-release")

    private func height<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: 260))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test func thePillShowsOnlyWhileADeploymentRuns() throws {
        _ = NSApplication.shared
        let board = DeployBoard.shared, saved = board.ledger
        defer { board.change { $0 = saved } }
        board.change { $0 = DeployLedger() }
        #expect(height(DeploySidebarPill()) < 1)
        let now = Date().timeIntervalSince1970
        let run = board.change { $0.start(projectID: "p", by: release, origin: nil, at: now) }
        try board.change { try $0.report(runID: run.id, DeployStepReport(name: "Tests", tool: "swift test"), at: now) }
        #expect(height(DeploySidebarPill()) > 10)
        try board.change { try $0.finish(runID: run.id, at: now + 1) }
        #expect(height(DeploySidebarPill()) < 1)
    }

    @Test func theToolsReportIntoTheCallersOwnRun() throws {
        var ledger = DeployLedger()
        let now = Date().timeIntervalSince1970
        let mine = ledger.start(projectID: "p", by: release, origin: nil, at: now)
        let other = ledger.start(projectID: "q", by: DeployActor(kind: "session", name: "Codex", sessionID: "s-other"), origin: nil, at: now)
        let me = DeployCaller(actor: release, origin: nil, folder: nil, projectID: nil)
        #expect(NativeCompositionProduction.ownRun(ledger, me: me, project: nil, now: now)?.id == mine.id)
        // Hoot with no run of its own: the project's only live run.
        let hoot = DeployCaller(actor: DeployActor(kind: "hoot", name: "Hoot", agentID: "hoot"), origin: nil, folder: nil, projectID: nil)
        #expect(NativeCompositionProduction.ownRun(ledger, me: hoot, project: "q", now: now)?.id == other.id)
        #expect(NativeCompositionProduction.ownRun(ledger, me: hoot, project: nil, now: now) == nil)
        try ledger.report(runID: mine.id, DeployStepReport(name: "Tests", tool: "swift test", state: .done, passed: 12, failed: 0), at: now)
        let wire = NativeCompositionProduction.wire(try #require(ledger.run(mine.id)), full: true, names: ["p": "Project P"])
        #expect(wire["project"].string == "Project P" && wire["state"].string == "running")
        #expect(wire["steps"].elements?.first?.string == "Tests · (swift test) · done · 12 passed · 0 failed")
    }

    /// #615: every tool that finds the caller's own run by project declares project, so the narrowing is not dead.
    @Test func everyDeployToolDeclaresProject() {
        let schemas = Dictionary(NativeCompositionProduction.deployToolDefinitions().map { ($0.0, $0.3) }, uniquingKeysWith: { first, _ in first })
        for id in DeployLedger.toolIDs {
            #expect(schemas[id]?["properties"]["project"]["type"].string == "string", "\(id)")
        }
    }
}
