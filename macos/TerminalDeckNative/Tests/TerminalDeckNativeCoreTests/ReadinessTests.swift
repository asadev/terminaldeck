import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// The native AI readiness page's rules, mirroring `ReadinessPanel.test.tsx` and
/// `readiness-dismissed.test.ts`.
@Suite("Readiness rules")
struct ReadinessRulesTests {
    func check(_ id: String, _ status: ReadinessStatus, weight: Double = 1, gate: Bool = false,
               fix: ReadinessFix? = nil, opens: String? = nil) -> ReadinessCheck {
        ReadinessCheck(id: id, title: id, status: status, weight: weight, fix: fix, gate: gate, opens: opens)
    }

    @Test func failuresFirstThenWarningsThenPassesThenSkips() {
        let rows = [check("s", .skip), check("p", .pass), check("w", .warn), check("f", .fail)]
        #expect(ReadinessRules.sorted(rows).map(\.id) == ["f", "w", "p", "s"])
    }

    @Test func anUncleanGateLiftsAboveEveryOtherFailure() {
        let rows = [check("f", .fail, weight: 9), check("g", .warn, gate: true)]
        #expect(ReadinessRules.sorted(rows).map(\.id) == ["g", "f"])
        let passingGate = [check("f", .fail), check("g", .pass, gate: true)]
        #expect(ReadinessRules.sorted(passingGate).map(\.id) == ["f", "g"])
    }

    @Test func tiesGoByWeightAndKeepTheirOrderOtherwise() {
        let rows = [check("a", .fail, weight: 1), check("b", .fail, weight: 5), check("c", .fail, weight: 1)]
        #expect(ReadinessRules.sorted(rows).map(\.id) == ["b", "a", "c"])
    }

    @Test func nothingOnThePageIsUnActionable() {
        let fix = ReadinessFix(id: "x", label: "Create .gitignore")
        #expect(ReadinessRules.action(for: check("a", .fail, fix: fix, opens: "a"), canOpen: true) == .fix)
        #expect(ReadinessRules.action(for: check("a", .warn, opens: "README.md"), canOpen: true) == .open)
        #expect(ReadinessRules.action(for: check("a", .warn, opens: "README.md"), canOpen: false) == .none)
        #expect(ReadinessRules.action(for: check("a", .pass, fix: fix), canOpen: true) == .none)
        #expect(ReadinessRules.action(for: check("a", .fail), canOpen: true) == .none)
    }

    @Test func buildsAFileURLASystemOpenerAccepts() {
        #expect(ReadinessRules.fileURL(projectPath: "/Users/me/proj", relPath: "README.md") == "file:///Users/me/proj/README.md")
        #expect(ReadinessRules.fileURL(projectPath: "/Users/me/My Proj/", relPath: "README.md") == "file:///Users/me/My%20Proj/README.md")
        #expect(ReadinessRules.fileURL(projectPath: "C:\\Users\\me\\proj", relPath: ".gitignore") == "file:///C:/Users/me/proj/.gitignore")
        #expect(ReadinessRules.fileURL(projectPath: "/a", relPath: "note#1?.md") == "file:///a/note%231%3F.md")
    }

    @Test func theHeadlineSaysWhichRowsItCounts() {
        #expect(ReadinessRules.headline(score: 38, passing: 1, applicable: 5, skipped: 5)
                == "38 out of 100 — 1 of 5 applicable checks passing, weighted · 5 not applicable here.")
        #expect(ReadinessRules.headline(score: 100, passing: 10, applicable: 10, skipped: 0)
                == "100 out of 100 — 10 of 10 applicable checks passing, weighted.")
        #expect(ReadinessRules.headline(score: 0, passing: 0, applicable: 1, skipped: 9).contains("0 of 1 applicable check passing"))
    }

    @Test func pickingAnAgentSwapsTheRowAndTheScoreTogether() throws {
        let neutral = check("instructions", .fail)
        let claude = ReadinessForAgent(agent: "claude", label: "Claude Code", file: "CLAUDE.md",
                                       check: check("instructions", .pass), score: 90, band: .strong)
        let report = ReadinessReport(score: 60, band: .weak, checks: [neutral, check("lint", .warn)], agents: [claude])
        #expect(ReadinessRules.view(of: report, agent: nil).score == 60)
        let picked = ReadinessRules.view(of: report, agent: "claude")
        #expect(picked.score == 90 && picked.band == .strong && picked.checks[0].status == .pass && picked.agent?.file == "CLAUDE.md")
        #expect(ReadinessRules.view(of: report, agent: "nobody").agent == nil)
    }

    @Test func readsTheEnginesReport() throws {
        let json: [String: Any] = [
            "projectPath": "/p", "score": 63, "band": "weak", "cappedBy": NSNull(), "scannedAt": "now",
            "checks": [
                ["id": "gitignore", "title": ".gitignore covers the basics", "status": "fail", "weight": 2, "detail": "No .gitignore.",
                 "fix": ["id": "gitignore", "label": "Create .gitignore", "description": "Writes one.", "touches": [".gitignore"], "destructive": false],
                 "gate": false, "opens": NSNull()],
                ["id": "readme", "title": "README", "status": "warn", "weight": 1, "detail": "Short.", "fix": NSNull(), "gate": false, "opens": "README.md"],
            ] as [Any],
        ]
        let report = try #require(ReadinessReport(json: json))
        #expect(report.score == 63 && report.band == .weak && report.cappedBy == nil)
        #expect(report.checks[0].fix?.touches == [".gitignore"] && report.checks[0].opens == nil)
        #expect(report.checks[1].opens == "README.md" && report.checks[1].fix == nil)
        #expect(report.agents.isEmpty)
        #expect(ReadinessRules.ringFraction(140) == 1 && ReadinessRules.ringFraction(-5) == 0)
        #expect(ReadinessRules.ringLabel(score: 63, band: .weak) == "AI readiness score 63 out of 100 — Rough")
        #expect(ReadinessRules.hiddenWords(1) == "1 check hidden" && ReadinessRules.hiddenWords(3) == "3 checks hidden")
    }
}

@Suite("Readiness dismissals")
struct ReadinessDismissedTests {
    @Test func survivesAnythingThatIsNotTheMap() {
        for raw in [nil, "", "not json", "[]", "1", "{\"a\":\"b\"}"] as [String?] {
            #expect(ReadinessDismissed.parse(raw).isEmpty)
        }
        #expect(ReadinessDismissed.parse("{\"/a\":[\"x\",\"\",3],\"__proto__\":[\"y\"]}") == ["/a": ["x"]])
    }

    @Test func isKeyedPerProjectAndIdempotent() {
        let map = ReadinessDismissed.dismiss([:], scope: "/a", id: "lint")
        #expect(ReadinessDismissed.isDismissed(map, scope: "/a", id: "lint"))
        #expect(!ReadinessDismissed.isDismissed(map, scope: "/b", id: "lint"))
        #expect(ReadinessDismissed.dismiss(map, scope: "/a", id: "lint") == map)
    }

    @Test func bringsRowsBackOneOrAll() {
        var map = ReadinessDismissed.dismiss([:], scope: "/a", id: "x")
        map = ReadinessDismissed.dismiss(map, scope: "/a", id: "y")
        #expect(ReadinessDismissed.restore(map, scope: "/a", id: "x") == ["/a": ["y"]])
        #expect(ReadinessDismissed.restore(ReadinessDismissed.restore(map, scope: "/a", id: "x"), scope: "/a", id: "y").isEmpty)
        #expect(ReadinessDismissed.restoreAll(map, scope: "/a").isEmpty)
    }

    @Test func filesMachineWideRowsAwayFromAnyProjectAndRoundTrips() {
        let map = ReadinessDismissed.dismiss([:], scope: ReadinessDismissed.machineScope, id: "agent-cli:gemini@0.32.1")
        #expect(!ReadinessDismissed.isDismissed(map, scope: "/a", id: "agent-cli:gemini@0.32.1"))
        #expect(ReadinessDismissed.parse(ReadinessDismissed.serialize(map)) == map)
        #expect(ReadinessDismissed.key == "readiness.dismissed.v1")
    }
}
