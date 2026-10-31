import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// DEPLOY-PIPELINE (Asad, 12 Oct): live and history of every deployment, its steps (tests included, with their numbers),
/// the tools really used and each step's result; nothing shown that did not happen.
@Suite("Deploy pipeline record")
struct DeployRecordTests {
    private let release = DeployActor(kind: "agent", name: "Release", agentID: "release", sessionID: "s-release")
    private let viaHoot = DeployOrigin(kind: "hoot", name: "Hoot", at: 1_000)

    @Test func aRunWithItsStepsSurvivesTheFileRoundTrip() throws {
        var ledger = DeployLedger()
        let run = ledger.start(projectID: "terminal-deck", title: "Installing Terminal Deck build 1c29bb8b", version: "Install 14",
                               commit: "1c29bb8b", by: release, origin: viaHoot, at: 1_000)
        try ledger.report(runID: run.id, DeployStepReport(name: "Tests", tool: "swift test", state: .done, result: "full suite",
                                                          log: "all green", passed: 5_792, failed: 0), at: 1_100)
        try ledger.finish(runID: run.id, at: 1_200)
        ledger.imports = ["route:terminal-deck"]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deploy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(DeployLedgerFile.name)
        try DeployLedgerFile.save(ledger, to: url)
        let back = DeployLedgerFile.load(url).ledger
        #expect(back == ledger)
        let step = try #require(back.runs.first?.steps.first)
        #expect(step.line == "5,792 passed · 0 failed · full suite")
        #expect(step.tool == "swift test" && step.log == "all green")
        #expect(back.runs.first?.byLine == "run by Release · asked via Hoot")
        // A file from a newer app with a state or tool this one does not know still opens.
        let odd = String(decoding: try Data(contentsOf: url), as: UTF8.self).replacingOccurrences(of: "\"done\"", with: "\"someday\"")
        try Data(odd.utf8).write(to: url)
        #expect(DeployLedgerFile.load(url).ledger.runs.count == 1)
    }

    /// U1 (#493): one run that no longer reads costs only that run, and a file that does not read at all is kept
    /// as a .damaged copy before anything is saved over it.
    @Test func aDamagedHistoryKeepsTheGoodRunsAndACopyOfTheFile() throws {
        var ledger = DeployLedger()
        _ = ledger.start(projectID: "web", by: release, origin: nil, at: 1)
        _ = ledger.start(projectID: "web", by: release, origin: nil, at: 2)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deploy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(DeployLedgerFile.name)
        try DeployLedgerFile.save(ledger, to: url)
        var raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var runs = try #require(raw["runs"] as? [Any]); runs[0] = ["broken": true]; raw["runs"] = runs
        try JSONSerialization.data(withJSONObject: raw).write(to: url)
        let partial = DeployLedgerFile.load(url)
        #expect(partial.ledger.runs.count == 1 && partial.writable && partial.problem != nil)
        let copies = { try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(DeployLedgerFile.name + DamagedFile.marker) } }
        #expect(try copies().count == 1)
        try Data("{ not json".utf8).write(to: url)
        let broken = DeployLedgerFile.load(url)
        #expect(broken.ledger.runs.isEmpty && broken.writable && broken.problem != nil)
        _ = DeployLedgerFile.load(url)
        #expect(try copies().count == 2)   // one copy per different damaged content, not one per read
    }

    @Test func startStepFinishShowOnlyWhatWasReportedInOrder() throws {
        var ledger = DeployLedger()
        let run = ledger.start(projectID: "web", by: release, origin: nil, at: 0)
        #expect(run.steps.isEmpty && run.isLive)   // no placeholder steps of ours
        try ledger.report(runID: run.id, DeployStepReport(name: "Build", tool: "Vercel"), at: 10)
        var now = try #require(ledger.run(run.id))
        #expect(now.steps.map(\.name) == ["Build"] && now.steps[0].state == .running && now.currentIndex == 0)
        #expect(now.steps[0].symbol == DeployToolIcon.symbol("Vercel"))
        try ledger.report(runID: run.id, DeployStepReport(name: "build", state: .done, result: "deployed to web.example.com · health 200"), at: 40)
        try ledger.report(runID: run.id, DeployStepReport(name: "Smoke check", tool: "curl", state: .done, result: "200"), at: 50)
        now = try #require(ledger.run(run.id))
        #expect(now.steps.map(\.name) == ["Build", "Smoke check"])
        #expect(now.steps[0].duration == 30 && now.steps[0].tool == "Vercel")
        // Reported only when it ended: it started when the step before it ended.
        #expect(now.steps[1].startedAt == 40)
        // An unknown tool keeps its own name and a neutral icon.
        #expect(now.steps[1].symbol == DeployToolIcon.neutral && now.steps[1].tool == "curl")
        let done = try ledger.finish(runID: run.id, result: "live", version: "v2", at: 60)
        #expect(done.state == .done && done.duration == 60 && done.version == "v2")
        #expect(throws: DeployFailure.self) { try ledger.report(runID: run.id, DeployStepReport(name: "late"), at: 70) }
        #expect(throws: DeployFailure.self) { try ledger.report(runID: "nope", DeployStepReport(name: "x"), at: 70) }
    }

    @Test func aFailedTestStepStopsThePipelineVisiblyAndARetryGoesOn() throws {
        var ledger = DeployLedger()
        let run = ledger.start(projectID: "terminal-deck", by: release, origin: nil,
                               plan: [("Tests", "swift test"), ("Release build", nil), ("Install", nil)], at: 0)
        #expect(run.steps.map(\.state) == [.waiting, .waiting, .waiting])
        try ledger.report(runID: run.id, DeployStepReport(name: "Tests", passed: 5_790, failed: 2), at: 30)
        var now = try #require(ledger.run(run.id))
        #expect(now.state == .failed && now.steps[0].state == .failed)
        #expect(now.steps[0].counts == "5,790 passed · 2 failed")
        #expect(now.stopped(1) && now.stopped(2) && !now.stopped(0))
        #expect(now.result?.hasPrefix("Stopped at Tests") == true)
        try ledger.report(runID: run.id, DeployStepReport(name: "Tests", state: .running), at: 40)
        now = try #require(ledger.run(run.id))
        #expect(now.state == .running && now.endedAt == nil && now.currentIndex == 0)
        // Finishing ends what still runs and marks the never-started steps skipped.
        let done = try ledger.finish(runID: run.id, state: .done, at: 90)
        #expect(done.steps.map(\.state) == [.done, .skipped, .skipped])
    }

    @Test func theSidePanelPillShowsOnlyWhileSomethingDeploys() throws {
        var ledger = DeployLedger()
        let name: (String) -> String = { $0 == "terminal-deck" ? "Terminal Deck" : $0 }
        #expect(DeployPill.line(ledger, projectName: name, at: 0) == nil)
        let run = ledger.start(projectID: "terminal-deck", by: release, origin: nil,
                               plan: ["Freeze", "Tests", "Build", "Install"].map { (name: $0, tool: String?.none) }, at: 0)
        for step in ["Freeze", "Tests", "Build"] { try ledger.report(runID: run.id, DeployStepReport(name: step, state: .done), at: 10) }
        try ledger.report(runID: run.id, DeployStepReport(name: "Install", state: .running), at: 20)
        #expect(DeployPill.line(ledger, projectName: name, at: 30)?.text == "Install")
        #expect(DeployPill.line(ledger, projectName: name, at: 30)?.full == "Deploying Terminal Deck · step 4 of 4 · Install")
        // A run nobody reported on for hours stops showing as live.
        #expect(DeployPill.line(ledger, projectName: name, at: 20 + DeployLedger.quietAfter + 1) == nil)
        try ledger.finish(runID: run.id, at: 40)
        #expect(DeployPill.line(ledger, projectName: name, at: 50) == nil)
    }

    /// #492: a run an AI started and never finished is closed after hours of quiet, not kept as Running forever.
    @Test func aReportedRunNobodyFinishedIsClosedAfterHoursOfQuiet() throws {
        var ledger = DeployLedger()
        let stale = ledger.start(projectID: "a", by: release, origin: nil, plan: [(name: "Build", tool: nil), (name: "Install", tool: nil)], at: 1_000)
        try ledger.report(runID: stale.id, DeployStepReport(name: "Build", state: .running), at: 1_100)
        #expect(ledger.closeQuiet(at: 1_100 + DeployLedger.quietAfter - 1) == 0)
        // The next deploy_start hours later closes it at its last news.
        let next = ledger.start(projectID: "a", by: release, origin: nil, at: 1_100 + DeployLedger.quietAfter)
        let closed = try #require(ledger.run(stale.id))
        #expect(closed.state == .skipped && closed.endedAt == 1_100 && closed.steps.map(\.state) == [.skipped, .skipped])
        #expect(closed.result == "no news for 6 h, closed by the app")
        #expect(ledger.run(next.id)?.isLive == true)
        // A run from a source is left to that source.
        ledger.merge([DeployRun(id: "github-actions:1", projectID: "a", source: "github-actions", by: DeployActor(kind: "source", name: "GitHub"),
                                state: .running, startedAt: 0)])
        #expect(ledger.closeQuiet(at: 1_000_000) == 1)
        #expect(ledger.run("github-actions:1")?.isLive == true && ledger.run(next.id)?.state == .skipped)
    }

    @Test func theLiveViewShowsWhereThePersonAskedAndFoldsAfter() throws {
        var ledger = DeployLedger()
        let hoot = ledger.start(projectID: "a", by: release, origin: viaHoot, at: 1_000)
        let lead = ledger.start(projectID: "a", by: release, origin: DeployOrigin(kind: "lead", name: "Decker", sessionID: "s-lead", at: 1_000), at: 1_000)
        #expect(ledger.hootPanel(at: 1_010).map(\.id) == [hoot.id])
        #expect(ledger.strip(forSession: "s-lead", at: 1_010)?.id == lead.id)
        #expect(ledger.strip(forSession: "s-release", at: 1_010) == nil)   // the Release agent's own session is not where he asked
        try ledger.finish(runID: hoot.id, at: 1_100)
        #expect(ledger.hootPanel(at: 1_100 + DeployLedger.foldedFor - 1).count == 1)
        #expect(ledger.hootPanel(at: 1_100 + DeployLedger.foldedFor + 1).isEmpty)
    }

    @Test func aGitHubActionsRunBecomesItsOwnJobsWithTheirResults() throws {
        let run = try NativeRPCValue.parseJSON(Data(#"""
        {"id": 991, "name": "Release", "display_title": "Ship 0.21", "path": ".github/workflows/release.yml", "event": "push",
         "status": "in_progress", "conclusion": null, "head_branch": "v0.21.0", "head_sha": "1c29bb8b0d2d9bda",
         "run_number": 42, "html_url": "https://github.com/acme/app/actions/runs/991",
         "created_at": "2026-10-12T00:00:00Z", "run_started_at": "2026-10-12T00:00:05Z", "updated_at": "2026-10-12T00:03:00Z",
         "repository": {"full_name": "acme/app"}, "head_commit": {"message": "Ship it\n\nlong body"}, "actor": {"login": "asad"}}
        """#.utf8))
        let jobs = try NativeRPCValue.parseJSON(Data(#"""
        [{"id": 1, "name": "Test", "status": "completed", "conclusion": "success", "html_url": "https://x/1",
          "started_at": "2026-10-12T00:00:10Z", "completed_at": "2026-10-12T00:01:10Z",
          "steps": [{"name": "Checkout", "status": "completed"}, {"name": "Run tests", "status": "completed"}]},
         {"id": 2, "name": "Upload to TestFlight", "status": "in_progress", "conclusion": null, "html_url": "https://x/2",
          "started_at": "2026-10-12T00:01:20Z", "completed_at": null,
          "steps": [{"name": "Archive", "status": "completed"}, {"name": "Upload", "status": "in_progress"}]}]
        """#.utf8)).elements
        #expect(DeployGitHubActions.isDeploy(run))
        let mapped = try #require(DeployGitHubActions.run(run, jobs: jobs, projectID: "app"))
        #expect(mapped.id == "github-actions:991" && mapped.state == .running && mapped.version == "v0.21.0" && mapped.commit == "1c29bb8")
        #expect(mapped.steps.map(\.name) == ["Code pushed", "Test", "Upload to TestFlight"])
        #expect(mapped.steps[0].result == "1c29bb8 · Ship it" && mapped.steps[0].link == "https://github.com/acme/app/commit/1c29bb8b0d2d9bda")
        #expect(mapped.steps[1].state == .done && mapped.steps[1].result == "2/2 steps passed" && mapped.steps[1].duration == 60)
        #expect(mapped.steps[2].state == .running && mapped.steps[2].result == "now: Upload")
        #expect(mapped.currentIndex == 2 && mapped.by.name == "GitHub Actions · started by asad")
        // A failed job says where; a plain CI workflow is not a deployment.
        let failed = DeployGitHubActions.step(try NativeRPCValue.parseJSON(Data(#"{"id": 3, "name": "Deploy", "status": "completed", "conclusion": "failure", "steps": [{"name": "Push image", "status": "completed", "conclusion": "failure"}]}"#.utf8)))
        #expect(failed.state == .failed && failed.result == "failed at Push image")
        let ci = try NativeRPCValue.parseJSON(Data(#"{"id": 5, "name": "CI", "path": ".github/workflows/ci.yml", "event": "pull_request", "head_branch": "main"}"#.utf8))
        #expect(!DeployGitHubActions.isDeploy(ci))
        // Merging a newer read replaces the source's run; a reported run is never overwritten.
        var ledger = DeployLedger()
        ledger.merge([mapped])
        var newer = mapped; newer.state = .done; newer.endedAt = mapped.startedAt + 300
        ledger.merge([newer])
        #expect(ledger.runs.count == 1 && ledger.runs[0].state == .done)
    }

    @Test func theInstallHistoryIsReadFromTheTeamBoardWithItsRealSteps() throws {
        let board = """
        FREEZE ORCH-MEMORY 2026-10-11 08:11 SECOND FREEZE for the second install. NOBODY saves.
        RELEASE BUILT ORCH-MEMORY 2026-10-11 08:21 second build: macos/night/local-build/Terminal Deck.app (signed deep/strict, built 08:11–08:21).
        SUITE 2 M2-FLOW 2026-10-11 08:22 full suite once on the second frozen tree, slot 2 (08:12–08:20), no source edits. Every test target BUILDS. 9,145 tests run (XCTest 5,718). FAILING: 1 (was 44).
        OLD-HOST PROOF 2 L8-HOST 2026-10-11 08:28 ALL 14 LINES PASS on the SECOND release app.
        INSTALLED ORCH-MEMORY 2026-10-11 08:27 SECOND INSTALL into /Applications at 08:25 (hash d340bdb20aa5ef91; data backup x). Quit of the 06:21 build by osascript: closed (2 kept). Hoot awake; ERROR lines 0.
        UNFREEZE ORCH-MEMORY 2026-10-11 08:40
        FREEZE ORCH 2026-10-12 03:13 ELEVENTH FREEZE for install 11 (relay MCP flag fix). NOBODY saves.
        INSTALLED ORCH 2026-10-12 03:27 ELEVENTH INSTALL hash 4942146b69577d39 (relay MCP flag). Checks green (Hoot awake, ERROR 0, session 60270 kept). Committed.
        """
        let runs = DeployRouteLog.runs(board, projectID: "terminal-deck", timeZone: TimeZone(identifier: "Asia/Dubai")!)
        #expect(runs.count == 2)
        let second = try #require(runs.first)
        #expect(second.version == "Install 1" && second.commit == "d340bdb2" && second.state == .done)
        #expect(second.steps.map(\.name) == ["Freeze the code", "Release build", "Signing check", "Tests", "Old-host safety proof",
                                             "Back up the app and data", "Quit the app", "Swap in the new app and reopen", "Checks after the install"])
        let tests = try #require(second.steps.first { $0.name == "Tests" })
        #expect(tests.passed == 9_144 && tests.failed == 1 && tests.state == .failed && tests.result == "failed: 1 test")
        #expect(second.steps.first { $0.name == "Old-host safety proof" }?.result == "14/14 lines passed")
        #expect(second.duration.map { Int($0.rounded()) } == 16 * 60)
        // Every step sits inside the run, in order.
        for step in second.steps { #expect((step.startedAt ?? 0) >= second.startedAt && (step.endedAt ?? .infinity) <= second.endedAt!) }
        let eleventh = runs[1]
        #expect(eleventh.title == "relay MCP flag fix")
        #expect(eleventh.steps.map(\.name) == ["Freeze the code", "Swap in the new app and reopen", "Checks after the install", "Commit"])
        #expect(eleventh.steps.first { $0.name == "Checks after the install" }?.result == "Hoot awake · errors 0 · sessions kept")
    }
}
