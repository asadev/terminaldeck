import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors src/renderer/staysfixed/StaysFixedPage.test.tsx.

private let now = StaysFixedRules.parse("2026-10-04T12:00:00Z")!

private func status(_ change: (inout StaysFixedStatus) -> Void = { _ in }) -> StaysFixedStatus {
    var s = StaysFixedWire.status(["available": true, "setUp": true, "agents": true], projectPath: "/work/shop")
    change(&s)
    return s
}

private let differences = StaysFixedWire.results([
    "runId": "r", "at": "2026-10-04T11:55:00Z", "durationMs": 3000, "verdict": "differences",
    "headline": "1 difference nobody asked for.", "against": "1.0.0", "checked": "1.0.0",
])!

@Suite("Stays Fixed — reading what crosses the bridge")
struct StaysFixedWireTests {
    @Test func fillsEveryMissingFieldWithItsEmptyValue() {
        let s = StaysFixedWire.status([String: Any](), projectPath: "/work/shop")
        #expect(s.projectPath == "/work/shop")
        #expect(!s.available)
        #expect(!s.setUp)
        #expect(s.guards.isEmpty)
        #expect(s.last == nil)
        #expect(s.running == nil)
        #expect(s.git)
        #expect(StaysFixedWire.status(nil, projectPath: "/x").projectPath == "/x")
    }

    @Test func readsTheCheckReadinessAndMarkAnswers() {
        let check = StaysFixedWire.check(["ok": false, "message": "Set it up first."])
        #expect(check.results == nil)
        #expect(check.message == "Set it up first.")
        #expect(StaysFixedWire.readiness(["ok": false, "message": "no"]).readiness == nil)
        let ready = StaysFixedWire.readiness(["ok": true, "readiness": ["ready": ["websites"], "gaps": [["name": "x", "fix": "git init", "byPerson": false]]]])
        #expect(ready.readiness?.gaps.first?.fix == "git init")
        #expect(ready.readiness?.ready == ["websites"])
        #expect(StaysFixedWire.mark(["refusedFor": "differences", "summary": "s"]).refusedFor == .differences)
        #expect(StaysFixedWire.mark(["refusedFor": "something else"]).refusedFor == nil)
        #expect(StaysFixedWire.mark([String: Any]()).summary == "It could not be marked.")
        #expect(StaysFixedWire.setup(["ok": false]).problem == "Set up did not finish.")
        #expect(StaysFixedWire.setup(["ok": true, "wrote": ["a", ""]]).wrote == ["a"])
    }

    @Test func readsResultsWithDifferencesAndPictures() {
        let raw: [String: Any] = [
            "verdict": "weird", "headline": "h",
            "differences": [["id": "d1", "title": "Home page", "count": 0, "more": 2,
                             "changes": [["what": "title", "before": "A", "after": "", "kind": "appeared"],
                                         ["what": "x", "kind": "nonsense"]]]],
            "pictures": ["d1": [["journey": "home", "before": "data:image/png;base64,AAAA", "after": nil]]],
            "gaps": [["what": "w", "why": "y", "unlockedBy": "u"]],
        ]
        let r = StaysFixedWire.results(raw)!
        #expect(r.verdict == .couldNotRun)
        #expect(r.differences[0].count == 1)
        #expect(r.differences[0].more == 2)
        #expect(r.differences[0].changes[0].kind == .appeared)
        #expect(r.differences[0].changes[0].after == nil)
        #expect(r.differences[0].changes[1].kind == .changed)
        #expect(StaysFixedRules.pictures(r, "d1").first?.journey == "home")
        #expect(StaysFixedRules.pictures(r, "none").isEmpty)
        #expect(StaysFixedRules.pictureData(r.pictures["d1"]?.first?.before) == Data([0, 0, 0]))
        #expect(StaysFixedWire.results([String: Any]()) == nil)
    }
}

@Suite("Stays Fixed — the head of the page")
struct StaysFixedHeadTests {
    @Test func saysNotCheckedCheckingOrTheLastVerdict() {
        #expect(StaysFixedRules.headline(status()) == "Not checked yet.")
        #expect(StaysFixedRules.headline(status { $0.running = FixedProgress(startedAt: 1, step: "x", steps: 1, by: "you") }) == "Checking…")
        #expect(StaysFixedRules.headline(status { $0.last = differences }) == "1 difference nobody asked for.")
    }

    @Test func stopsAskingForMarkAsGoodOnceMarked() {
        var notCompared = differences
        notCompared.verdict = .notCompared
        notCompared.headline = "Nothing to compare against yet. Mark this build as good to start."
        let marked = status {
            $0.last = notCompared
            $0.reference = FixedReference(name: "1.0.0", setAt: "2026-10-04T11:56:00Z", forced: false)
        }
        #expect(StaysFixedRules.markedSinceLastCheck(marked))
        #expect(StaysFixedRules.headline(marked) == "Ready. Run a check after your next change.")
        #expect(StaysFixedRules.statusTone(marked) == .positive)
        let anyway = status {
            $0.last = differences
            $0.reference = FixedReference(name: "1.0.0", setAt: "2026-10-04T11:56:00Z", forced: true)
        }
        #expect(StaysFixedRules.headline(anyway) == "Marked as good, with these differences as the new normal.")
    }

    @Test func saysWhenAndAgainstWhichGoodBuild() {
        #expect(StaysFixedRules.subline(status { $0.last = differences }, now: now) == "Checked 5m ago · No build is marked as good yet")
        #expect(StaysFixedRules.subline(status { $0.reference = FixedReference(name: "1.0.0", setAt: "2026-10-02T12:00:00Z", forced: false) }, now: now)
            == "Good build: 1.0.0, marked 2d ago")
    }

    @Test func namesWhoStartedACheckAndHowLong() {
        #expect(StaysFixedRules.startedBy(FixedProgress(startedAt: 0, step: "", steps: 0, by: "you")) == "You started this check")
        #expect(StaysFixedRules.startedBy(FixedProgress(startedAt: 0, step: "", steps: 0, by: "Hoot")) == "Hoot started this check")
        #expect(StaysFixedRules.elapsed(754_000) == "12:34")
        #expect(StaysFixedRules.elapsed(-5) == "0:00")
    }

    @Test func namesEveryAgentNeverOnlyOne() {
        #expect(StaysFixedRules.agentNames() == "Claude Code, Codex CLI and Gemini CLI")
        #expect(StaysFixedRules.listWords(["a"]) == "a")
        #expect(StaysFixedRules.listWords([]) == "")
        #expect(StaysFixedRules.listWords(["a", "b"]) == "a and b")
    }

    @Test func tonesAndSmallWords() {
        #expect(StaysFixedRules.verdictTone(.clean) == .positive)
        #expect(StaysFixedRules.verdictTone(.differences) == .warning)
        #expect(StaysFixedRules.verdictTone(.couldNotRun) == .critical)
        #expect(StaysFixedRules.verdictTone(nil) == .muted)
        #expect(StaysFixedRules.statusTone(status { $0.running = FixedProgress(startedAt: 0, step: "", steps: 0, by: "") }) == .muted)
        #expect(StaysFixedRules.count(1, "more change") == "1 more change")
        #expect(StaysFixedRules.count(3, "more change") == "3 more changes")
        #expect(StaysFixedRules.sentenceCase("websites") == "Websites")
        #expect(StaysFixedRules.sentenceCase("") == "")
        let marked = FixedMarkOutcome(ok: true, marked: true, already: false, refused: nil, refusedFor: nil, summary: "")
        #expect(StaysFixedRules.markTone(marked) == .positive)
        let refused = FixedMarkOutcome(ok: false, marked: false, already: false, refused: "r", refusedFor: .differences, summary: "")
        #expect(StaysFixedRules.markTone(refused) == .warning)
    }
}
