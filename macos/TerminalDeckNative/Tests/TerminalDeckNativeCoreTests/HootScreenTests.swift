import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Hoot's window (lane R): mirrors copilot-model.test.ts (stages), copilot-bar.test.ts
// (Restart's state line) and session-origin.test.ts (sessions it started).

@Suite("Hoot screen")
struct HootScreenTests {
    @Test func stagesFollowStateAndSignIn() {
        #expect(HootScreen.stage(status: nil, signIn: nil) == .stopped)
        #expect(HootScreen.stage(status: "stopped", signIn: "signed-in") == .stopped)
        #expect(HootScreen.stage(status: "starting", signIn: nil) == .starting)
        #expect(HootScreen.stage(status: "running", signIn: nil) == .checking)
        #expect(HootScreen.stage(status: "running", signIn: "signed-out") == .firstRun)
        #expect(HootScreen.stage(status: "running", signIn: "unknown") == .unverified)
        #expect(HootScreen.stage(status: "running", signIn: "signed-in") == .ready)
    }

    @Test func restartSaysTheStateFirst() {
        #expect(HootScreen.stateLine(stage: .stopped, loading: true, account: nil, recordsHeld: false) == "Checking…")
        #expect(HootScreen.stateLine(stage: .stopped, loading: false, account: nil, recordsHeld: false) == "Not running")
        #expect(HootScreen.stateLine(stage: .ready, loading: false, account: "me@x.com", recordsHeld: true) == "Running · me@x.com")
        #expect(HootScreen.stateLine(stage: .ready, loading: false, account: nil, recordsHeld: true) == "Running · signed in, its log held")
        #expect(HootScreen.stateLine(stage: .firstRun, loading: false, account: nil, recordsHeld: false) == "Running · signed out")
        #expect(HootScreen.restartHelp(stateLine: "Running · signed in")
                == "Running · signed in — restarting ends this conversation and starts a fresh one. Its folder and memory are untouched.")
        #expect(HootScreen.showsRestart(status: "running", elsewhere: false))
        #expect(!HootScreen.showsRestart(status: "running", elsewhere: true))
        #expect(!HootScreen.showsRestart(status: "starting", elsewhere: false))
    }

    @Test func noticesOnlyWhenTheyHaveSomethingToSay() {
        #expect(HootScreen.notices(stage: .ready, problem: nil, elsewhere: false).isEmpty)
        #expect(HootScreen.notices(stage: .firstRun, problem: nil, elsewhere: false).first?.title == "The account it runs as is signed out")
        #expect(HootScreen.notices(stage: .firstRun, problem: nil, elsewhere: false).first?.paragraphs.count == 2)
        #expect(HootScreen.notices(stage: .unverified, problem: nil, elsewhere: false).first?.kind == .unverified)
        #expect(HootScreen.notices(stage: .stopped, problem: "No Claude Code on this Mac.", elsewhere: false)
                == [HootScreen.Notice(kind: .problem, title: nil, paragraphs: ["No Claude Code on this Mac."])])
        #expect(HootScreen.notices(stage: .stopped, problem: nil, elsewhere: false).isEmpty)
        // About this computer's Hoot only.
        #expect(HootScreen.notices(stage: .firstRun, problem: nil, elsewhere: true).isEmpty)
    }

    @Test func turnsAreReadAndDated() {
        let rows = HootScreen.turns([["id": "r1", "at": "2026-10-06T02:55:00.000Z", "detail": "sessions.start"],
                                     ["id": "r2"], ["detail": "x"], "junk"])
        #expect(rows == [HootScreen.Turn(id: "r1", at: "2026-10-06T02:55:00.000Z", detail: "sessions.start")])
        #expect(HootScreen.turns("nope").isEmpty)
        let utc = TimeZone(identifier: "UTC")!
        let said = HootScreen.when("2026-10-06T02:55:00.000Z", locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(said.contains("10/6/26") && said.contains("2:55:00"))
        #expect(HootScreen.when("yesterday") == "yesterday")
    }

    @Test func startedSessionsFollowTheRailsRun() {
        let metas = HootScreen.metas([
            ["id": "a", "title": "shop", "origin": "copilot", "originRunId": "run-1"],
            ["id": "b", "title": "api", "origin": "copilot", "originRunId": ""],
            ["id": "c", "title": "mine"],
        ])
        #expect(metas[1].runId == nil)
        // No rail run yet: every session the copilot started, as listed.
        let plain = HootScreen.started(metas: metas, sidebar: nil)
        #expect(plain.map(\.id) == ["a", "b"])
        #expect(plain.map(\.label) == ["shop", "api"])
        // The rail's run: its order and its labels.
        let sidebar = SidebarState(groups: [], projects: [
            SidebarProject(id: HootScreen.startedGroup, title: "Hoot started", expanded: true, sessions: [
                SidebarItem(id: "b", title: "Session 2", kind: .session),
                SidebarItem(id: "a", title: "shop — fix", kind: .session),
            ]),
        ], selectedId: nil)
        let railed = HootScreen.started(metas: metas, sidebar: sidebar)
        #expect(railed.map(\.label) == ["Session 2", "shop — fix"])
        #expect(HootScreen.fromTurn("run-1", in: railed).map(\.id) == ["a"])
        #expect(HootScreen.fromTurn(nil, in: railed).isEmpty)
    }

    @Test func notRunningPage() {
        #expect(HootScreen.emptyTitle(stage: .starting) == "Starting Hoot…")
        #expect(HootScreen.emptyTitle(stage: .stopped) == "Hoot is not running")
    }
}
