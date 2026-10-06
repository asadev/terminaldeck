import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors shared/scan.test.ts, copilot/driving/tour.test.ts, TourRecap.test.ts,
// browser-trace.test.ts, driving/terminal-region.test.ts, geometry.test.ts and
// shared/quote-match.test.ts.

private struct Lines: TerminalBufferReader {
    var lines: [String]
    var first = 0
    var cols = 80
    var end: Int { lines.count }
    func line(_ index: Int) -> String? { index >= 0 && index < lines.count ? lines[index] : nil }
}

@Suite("Driving — the scan")
struct DriveScanTests {
    @Test func holdsEveryStopForTheSameTime() {
        var s = Scan.reduce(ScanState(), .play(at: 0, count: 3))
        #expect(s.status == .travelling)
        s = Scan.reduce(s, .arrive(at: 10))
        #expect(s.status == .scanning)
        s = Scan.reduce(s, .tick(at: 10 + Scan.holdMs - 1))
        #expect(s.index == 0)
        s = Scan.reduce(s, .tick(at: 10 + Scan.holdMs + 1))
        #expect(s.index == 1)
        #expect(s.status == .travelling)
        #expect(Scan.holdMs >= 200 && Scan.holdMs <= 400)
    }

    @Test func doesNotStartTheClockUntilTheBoxIsDrawn() {
        var s = Scan.reduce(ScanState(), .play(at: 0, count: 2))
        s = Scan.reduce(s, .tick(at: 500))
        #expect(s.index == 0)
        #expect(s.elapsedMs == 0)
    }

    @Test func stopsOnAnythingTheyDidAndStaysStopped() {
        var s = Scan.reduce(Scan.reduce(ScanState(), .play(at: 0, count: 3)), .arrive(at: 1))
        s = Scan.reduce(s, .pause(at: 2, reason: .clicked))
        #expect(s.status == .paused)
        #expect(s.pausedBy == .clicked)
        s = Scan.reduce(s, .tick(at: 900))
        #expect(s.status == .paused)
        s = Scan.reduce(s, .resume(at: 950))
        #expect(s.status == .scanning)
    }

    @Test func handsOverWhenTheyStepBack() {
        var s = Scan.reduce(Scan.reduce(ScanState(), .play(at: 0, count: 3)), .arrive(at: 1))
        s = Scan.reduce(s, .next(at: 2, travel: true))
        s = Scan.reduce(s, .back(at: 3, travel: true))
        #expect(s.index == 0)
        #expect(s.status == .paused)
        #expect(s.pausedBy == .steppedBack)
    }

    @Test func discardsAGapThatMeansTheWindowStopped() {
        var s = Scan.reduce(Scan.reduce(ScanState(), .play(at: 0, count: 3)), .arrive(at: 0))
        s = Scan.reduce(s, .tick(at: Scan.maxTickGapMs + 100))
        #expect(s.status == .paused)
        #expect(s.pausedBy == .stalled)
        #expect(s.stalls == 1)
        #expect(s.index == 0)
    }

    @Test func recordsEveryStopOnceAndRecounts() {
        var s = Scan.reduce(ScanState(), .play(at: 0, count: 3))
        s = Scan.reduce(s, .arrive(at: 1))
        s = Scan.reduce(s, .arrive(at: 2))
        #expect(s.seen == [0])
        s = Scan.reduce(s, .jump(at: 3, index: 2, travel: true))
        s = Scan.reduce(s, .arrive(at: 4))
        #expect(s.seen == [0, 2])
        s = Scan.reduce(s, .recount(at: 5, count: 2, index: 1))
        #expect(s.seen == [0])
        #expect(s.index == 1)
        #expect(Scan.reduce(s, .recount(at: 6, count: 0, index: 0)).status == .finished)
    }

    @Test func progressAndWords() {
        var s = Scan.reduce(Scan.reduce(ScanState(), .play(at: 0, count: 4)), .arrive(at: 0))
        s = Scan.reduce(s, .tick(at: Scan.holdMs / 2))
        #expect(abs(Scan.progress(s) - 0.125) < 0.0001)
        #expect(Scan.statusSentence(s) == "Scanning · 1 of 4")
        s = Scan.reduce(s, .pause(at: 200, reason: .typed))
        #expect(Scan.statusSentence(s) == "Held — you typed · Space to carry on")
        #expect(Scan.statusSentence(Scan.reduce(s, .stop(at: 300))) == "Done — the answer is in the chat")
        #expect(Scan.statusSentence(ScanState()) == "")
        #expect(!Scan.isScanning(ScanState()))
        #expect(Scan.pauseSentence(.consent) == "Held — something needs your permission")
        #expect(Scan.reduce(ScanState(), .play(at: 0, count: 0)).status == .finished)
    }

    @Test func groupsBySessionAndCountsWhatWasShown() {
        let stops = [
            TourStopRecord(index: 0, sessionId: "a", sessionTitle: "Deploy", kind: "screen", cwd: "", why: "failed", quote: "q", note: "n1", shownAt: 1, degraded: false),
            TourStopRecord(index: 1, sessionId: "b", sessionTitle: "Docs", kind: "screen", cwd: "", why: "finished", quote: "", note: "n2", shownAt: nil, degraded: false),
            TourStopRecord(index: 2, sessionId: "a", sessionTitle: "Deploy", kind: "screen", cwd: "", why: "looping", quote: "", note: "n3", shownAt: 2, degraded: false),
        ]
        let grouped = Scan.groupBySession(stops)
        #expect(grouped.map(\.sessionId) == ["a", "b"])
        #expect(grouped[0].lines.count == 2)
        #expect(Scan.answerSummary(grouped) == "2 things across 1 session.")
        #expect(Scan.answerSummary(Scan.groupBySession(stops, background: true)) == "3 things across 2 sessions.")
        #expect(Scan.answerSummary([]) == "Nothing was shown.")
    }

    @Test func theEnginePublishesShapeChangesAndTicksByFrame() {
        var clock = 0.0
        var pending: (() -> Void)?
        let engine = ScanEngine(now: { clock }, requestFrame: { tick in pending = tick; return NSObject() }, cancelFrame: { _ in pending = nil })
        var published = 0
        engine.subscribe { published += 1 }
        engine.dispatch(.play(at: 0, count: 2))
        #expect(published == 1)
        #expect(pending != nil)
        engine.dispatch(.arrive(at: 0))
        clock = 100
        pending?()
        #expect(engine.peek().elapsedMs == 100)
        #expect(published == 2)
        clock = 400
        pending?()
        #expect(engine.getState().index == 1)
        engine.destroy()
    }
}

@Suite("Driving — the tour")
struct DriveTourTests {
    let record: [String: Any] = ["v": 1, "id": "t1", "startedAt": 1000, "endedAt": NSNull(), "question": "What broke?",
                                 "headline": "Two things", "stops": [], "stoppedAfter": NSNull(), "dropped": [], "askedBy": "user"]

    @Test func takesAWellFormedTourAndRefusesTheRest() {
        let tour = DriveTour.read(["record": record, "stops": [["sessionId": "s1", "note": "n", "why": "failed", "kind": "screen", "quote": "error"],
                                                               ["sessionId": "s1", "note": "n", "why": "failed", "kind": "screen"]]])
        #expect(tour?.stops.count == 1)
        #expect(tour?.record.question == "What broke?")
        #expect(DriveTour.read("nope") == nil)
        #expect(DriveTour.read(["record": ["v": 2, "id": "x", "stops": []], "stops": []]) == nil)
        #expect(DriveTour.read(["record": record, "stops": [["kind": "screen"]]]) == nil)
    }

    @Test func pointsEachStopAtTheRightThing() {
        let screen = TourStop(sessionId: "s", note: "", why: "", kind: .screen(quote: "q"))
        #expect(DriveTour.focus(screen, cwd: nil) == .terminal(sessionId: "s", quote: "q"))
        let message = TourStop(sessionId: "s", note: "", why: "", kind: .message(messageId: "m1", quote: "q"))
        #expect(DriveTour.focus(message, cwd: nil) == .anchor(.message(messageId: "m1")))
        let git = TourStop(sessionId: "s", note: "", why: "", kind: .anchor(at: "git-file", path: "a.ts"))
        #expect(DriveTour.focus(git, cwd: "/w") == .anchor(.gitFile(cwd: "/w", path: "a.ts")))
        #expect(DriveTour.focus(git, cwd: nil) == nil)
        #expect(DriveTour.focus(TourStop(sessionId: "s", note: "", why: "", kind: .anchor(at: "future", path: nil)), cwd: "/w") == nil)
        #expect(DriveTour.focus(TourStop(sessionId: "s", note: "", why: "", kind: .anchor(at: "usage", path: nil)), cwd: nil) == .anchor(.usage(sessionId: "s")))
        #expect(DriveTour.goesToGit(git))
        #expect(DriveAnchor.gitFile(cwd: "/w", path: "a.ts").id == "git-file:/w:a.ts")
        #expect(DriveAnchor.sessionRow(sessionId: "s").id == "session-row:s")
    }

    @Test func rebuildsTargetsFromARecord() {
        func stop(_ kind: String, quote: String = "", messageId: String? = nil, at: String? = nil, path: String? = nil, cwd: String = "") -> TourStopRecord {
            TourStopRecord(index: 0, sessionId: "s", sessionTitle: "", kind: kind, cwd: cwd, messageId: messageId, at: at, path: path,
                           why: "", quote: quote, note: "", shownAt: nil, degraded: false)
        }
        #expect(DriveTour.focus(stop("screen", quote: "q")) == .terminal(sessionId: "s", quote: "q"))
        #expect(DriveTour.focus(stop("screen")) == nil)
        #expect(DriveTour.focus(stop("anchor", at: "git-file", path: "a", cwd: "/w")) == .anchor(.gitFile(cwd: "/w", path: "a")))
        #expect(DriveTour.focus(stop("anchor", at: "git-file", path: "a")) == nil)
    }

    @Test func confessesHonestly() {
        var r = DriveTour.record(record)!
        r.stops = (0..<4).map { TourStopRecord(index: $0, sessionId: "s", sessionTitle: "", kind: "screen", cwd: "", why: "", quote: "", note: "", shownAt: nil, degraded: false) }
        #expect(DriveTour.stoppedSentence(r) == "")
        r.stoppedAfter = 1
        #expect(DriveTour.stoppedSentence(r) == "Stopped after 2 of 4.")
        r.stoppedAfter = 3
        #expect(DriveTour.stoppedSentence(r) == "")
        #expect(DriveTour.droppedSentence([DroppedStop(title: "a", why: "session-gone", detail: ""), DroppedStop(title: "b", why: "session-gone", detail: "")])
            == "2 stops dropped — the session had gone.")
        #expect(DriveTour.droppedSentence([DroppedStop(title: "a", why: "session-gone", detail: ""), DroppedStop(title: "b", why: "over-budget", detail: "")])
            == "2 stops dropped — the checks did not hold.")
        #expect(DriveTour.droppedSentence([]) == "")
        #expect(DriveTour.reasonLabel("blocked-on-you") == "Waiting on you")
        #expect(DriveTour.reasonLabel("brand-new") == "brand-new")
        #expect(DriveTour.degradeSentence(.anchorMissing) == "The thing this points at is not on screen right now.")
    }

    @Test func reportsTheWholeRecordBack() {
        var r = DriveTour.record(["v": 1, "id": "t", "extra": "kept", "stops": [["index": 0, "sessionId": "s", "kind": "screen", "custom": 7]]])!
        r.stops[0].shownAt = 123
        r.endedAt = 456
        let wire = r.wire
        #expect(wire["extra"] as? String == "kept")
        #expect(wire["endedAt"] as? Double == 456)
        let stop = (wire["stops"] as? [[String: Any]])?.first
        #expect(stop?["custom"] as? Int == 7)
        #expect(stop?["shownAt"] as? Double == 123)
    }

    @Test func recapRecords() {
        var closed = record
        closed["endedAt"] = 2000
        let found = DriveTour.records([record, closed, "junk", ["v": 1, "id": "x"]])
        #expect(found.map(\.id) == ["t1"])
        #expect(found.first?.endedAt == 2000)
        var r = DriveTour.record(closed)!
        r.stops = [
            TourStopRecord(index: 0, sessionId: "a", sessionTitle: "", kind: "screen", cwd: "", why: "", quote: "", note: "first", shownAt: nil, degraded: false),
            TourStopRecord(index: 1, sessionId: "b", sessionTitle: "", kind: "screen", cwd: "", why: "", quote: "", note: "other", shownAt: nil, degraded: false),
            TourStopRecord(index: 2, sessionId: "a", sessionTitle: "", kind: "screen", cwd: "", why: "", quote: "", note: "second", shownAt: nil, degraded: false),
        ]
        #expect(DriveTour.nthStop(r, sessionId: "a", position: 1)?.note == "second")
        #expect(DriveTour.nthStop(r, sessionId: "a", position: 2) == nil)
        #expect(DriveTour.isScanRow(["tool": "tour.play"]))
        #expect(!DriveTour.isScanRow(["tool": "browser.open"]))
    }

    @Test func theBrowserTheAgentDrives() {
        #expect(DriveNow.of(["state": "agent", "tabId": "t", "step": "Clicking", "url": "https://x.com"])?.step == "Clicking")
        #expect(DriveNow.of(["state": "robot"]) == nil)
        #expect(DriveNow.shortUrl("https://www.example.com/a/b?token=1") == "example.com/a/b")
        #expect(DriveNow.shortUrl("https://example.com/") == "example.com")
        #expect(DriveNow.shortUrl("not a url") == "not a url")
        #expect(DriveNow.shortUrl("") == "")
    }
}

@Suite("Driving — boxes and quotes")
struct DriveGeometryTests {
    let metrics = TerminalMetrics(screen: DriveRect(x: 100, y: 50, width: 800, height: 400), cols: 80, rows: 20)

    @Test func placesARegionOnTheGrid() {
        let region = BufferRegion(line: 10, lines: 2, startCol: 4, endCol: 20)
        let top = QuoteMatch.rect(region, viewportY: 10, metrics: metrics)!
        #expect(top.rect == DriveRect(x: 140, y: 50, width: 160, height: 40))
        let lower = QuoteMatch.rect(region, viewportY: 5, metrics: metrics)!
        #expect(lower.rect.y == 150)
        let clipped = QuoteMatch.rect(BufferRegion(line: 29, lines: 3, startCol: 0, endCol: 10), viewportY: 10, metrics: metrics)!
        #expect(!clipped.edges.bottom)
        #expect(QuoteMatch.rect(region, viewportY: 10, metrics: TerminalMetrics(screen: DriveRect(x: 0, y: 0, width: 0, height: 0), cols: 80, rows: 20)) == nil)
        #expect(QuoteMatch.rect(BufferRegion(line: 0, lines: 1, startCol: 0, endCol: 1), viewportY: 50, metrics: metrics) == nil)
    }

    @Test func normalisesAndFindsQuotes() {
        #expect(QuoteMatch.normalizeLine("  a \t  b\u{0007}c  ") == "a b c")
        #expect(QuoteMatch.normalizeLine("Keep Case") == "Keep Case")
        #expect(QuoteMatch.needle("\n\n  first line  \nsecond") == "first line")
        let reader = Lines(lines: ["$ build", "error: thing", "", "$ build", "error: thing", "  at file.ts:3   ", "", "done"])
        let found = QuoteMatch.locate(reader, quote: "error: thing\nat file.ts:3")
        #expect(found?.line == 4)
        #expect(found?.lines == 2)
        #expect(QuoteMatch.locate(reader, quote: "missing") == nil)
        #expect(QuoteMatch.locate(reader, quote: "   ") == nil)
        let padded = QuoteMatch.locate(Lines(lines: ["a", "first", "", "  second", "z"]), quote: "first\nsecond")
        #expect(padded?.lines == 3)
        #expect(QuoteMatch.contains("x\n  the   quote here\ny", quote: "the quote"))
        #expect(QuoteMatch.stripAnsi("\u{1b}[31mred\u{1b}[0m") == "red")
    }

    @Test func clipsAndPads() {
        let clipped = DriveGeometry.clip(DriveRect(x: -10, y: 0, width: 50, height: 20), to: DriveRect(x: 0, y: 0, width: 100, height: 100))!
        #expect(clipped.rect == DriveRect(x: 0, y: 0, width: 40, height: 20))
        #expect(!clipped.edges.left && clipped.edges.top)
        #expect(DriveGeometry.clip(DriveRect(x: 200, y: 0, width: 5, height: 5), to: DriveRect(x: 0, y: 0, width: 100, height: 100)) == nil)
        #expect(DriveGeometry.pad(DriveRect(x: 10, y: 10, width: 10, height: 10), 4) == DriveRect(x: 6, y: 6, width: 18, height: 18))
        #expect(DriveGeometry.union([DriveRect(x: 0, y: 0, width: 10, height: 10), DriveRect(x: 20, y: 5, width: 5, height: 20)]) == DriveRect(x: 0, y: 0, width: 25, height: 25))
        #expect(DriveGeometry.corners(DriveEdges(top: true, right: false, bottom: true, left: true), radius: 6) == (6, 0, 0, 6))
        #expect(DriveGeometry.outside(DriveGeometry.outlineBands(DriveRect(x: 10, y: 10, width: 10, height: 10), weight: 2), DriveRect(x: 10, y: 10, width: 10, height: 10)))
    }

    @Test func theDimKeepsThingsReadable() {
        let kept = DimBudget.luminanceKept("#ffffff", scrim: "rgba(0, 0, 0, 0.26)")! // tokens.css --drive-dim
        #expect(kept > DimBudget.minLuminanceKept && kept < DimBudget.maxLuminanceKept)
        #expect(DimBudget.dimmedContrast(fg: "#ffffff", bg: "#000000", scrim: "rgba(0,0,0,0.5)")! > DimBudget.minContrast)
        #expect(DimBudget.parse("blue") == nil)
    }
}

@MainActor
final class FakeWindow: DriveNavigating, DriveFocusing {
    var tabs: [String] = []
    var panels: [String] = []
    var focused: [FocusTarget] = []
    var lit: [Bool] = []
    var cleared = 0
    var failures: [FocusTarget: FocusFailure] = [:]
    func selectTab(_ sessionId: String) { tabs.append(sessionId) }
    func showPanel(_ id: String, focus: String?) { panels.append(id) }
    func cwdOf(_ sessionId: String) -> String? { "/work" }
    func setFocus(_ target: FocusTarget, lit: Bool) { focused.append(target); self.lit.append(lit) }
    func setLit(_ lit: Bool) { self.lit.append(lit) }
    func clearFocus() { cleared += 1 }
    func failure(_ target: FocusTarget) -> FocusFailure? { failures[target] }
    func scrollTo(_ target: FocusTarget) {}
}

@MainActor
@Suite("Driving — the tour player")
struct DriveTourPlayerTests {
    func message(_ stops: Int) -> TourMessage {
        let raw: [String: Any] = ["v": 1, "id": "t", "startedAt": 0, "question": "q", "headline": "h", "dropped": [],
                                  "stops": (0..<stops).map { ["index": $0, "sessionId": "s\($0)", "sessionTitle": "S\($0)", "kind": "screen", "quote": "q\($0)"] }]
        return TourMessage(record: DriveTour.record(raw)!,
                           stops: (0..<stops).map { TourStop(sessionId: "s\($0)", note: "n\($0)", why: "failed", kind: .screen(quote: "q\($0)")) })
    }

    final class Clock {
        var ms = 0.0
        var timers: [(at: Double, run: () -> Void, live: Bool)] = []
        func schedule(_ after: Double, _ run: @escaping () -> Void) -> () -> Void {
            timers.append((ms + after, run, true))
            let i = timers.count - 1
            return { [weak self] in self?.timers[i].live = false }
        }
        func advance(_ by: Double) {
            ms += by
            for i in timers.indices where timers[i].live && timers[i].at <= ms {
                timers[i].live = false
                timers[i].run()
            }
        }
    }

    func play(_ stops: Int, window: FakeWindow, clock: Clock, reports: @escaping (TourReport, TourRecord) -> Void = { _, _ in }) -> TourPlayer {
        let engine = ScanEngine(now: { clock.ms }, requestFrame: { _ in NSObject() }, cancelFrame: { _ in })
        return TourPlayer(message: message(stops), copilotSessionId: "hoot", engine: engine, navigator: window, focus: window,
                          report: reports, now: { clock.ms }, perfNow: { clock.ms }, schedule: clock.schedule)
    }

    @Test func goesToTheFirstStopAndWaitsForItsBox() {
        let window = FakeWindow(), clock = Clock()
        var kinds: [TourReport] = []
        let player = play(2, window: window, clock: clock) { kind, _ in kinds.append(kind) }
        #expect(kinds == [.started])
        // The web enters the first stop twice (the engine's first publish, then playTour); same on screen.
        #expect(Set(window.tabs) == ["s0"])
        #expect(Set(window.focused) == [.terminal(sessionId: "s0", quote: "q0")])
        #expect(player.view.scan.status == .travelling)
        player.reported(drawn: true, why: nil)
        #expect(player.view.scan.status == .scanning)
        #expect(player.view.record.stops[0].shownAt == 0)
        #expect(window.lit.last == true)
    }

    @Test func showsAStopWithoutABoxAfterTheGrace() {
        let window = FakeWindow(), clock = Clock()
        let player = play(2, window: window, clock: clock)
        player.reported(drawn: false, why: .offScreen)
        clock.advance(TourPlayer.arriveGraceMs + 1)
        #expect(player.view.degraded?.index == 0)
        #expect(player.view.degraded?.why == .offScreen)
        #expect(player.view.scan.status == .scanning)
    }

    @Test func movesOnAndEndsWithTheRecordAndBackToHoot() {
        let window = FakeWindow(), clock = Clock()
        var last: TourRecord?
        let player = play(2, window: window, clock: clock) { _, record in last = record }
        player.reported(drawn: true, why: nil)
        player.command(.next)
        #expect(Array(Set(window.tabs)).sorted() == ["s0", "s1"])
        #expect(window.tabs.last == "s1")
        player.command(.stop)
        #expect(player.view.ended)
        #expect(last?.endedAt != nil)
        #expect(last?.stoppedAfter == 0)
        #expect(window.cleared == 1)
        #expect(window.tabs.last == "hoot")
    }

    @Test func spaceHoldsAndCarriesOn() {
        let window = FakeWindow(), clock = Clock()
        let player = play(3, window: window, clock: clock)
        #expect(player.key(" "))
        #expect(player.view.scan.status == .paused)
        #expect(!player.key("a"))
        #expect(player.key(" "))
        #expect(player.view.scan.status != .paused)
    }

    @Test func dropsStopsWhoseTextIsGoneOnResume() {
        let window = FakeWindow(), clock = Clock()
        let player = play(3, window: window, clock: clock)
        player.reported(drawn: true, why: nil)
        player.interrupt(.clicked)
        window.failures[.terminal(sessionId: "s0", quote: "q0")] = .quoteNotFound
        player.command(.toggle)
        #expect(player.view.stops.count == 2)
        #expect(player.view.droppedHere.first?.title == "n0")
        #expect(player.view.scan.count == 2)
    }

    @Test func gitStopsGoThroughTheGitView() {
        let window = FakeWindow(), clock = Clock()
        let raw: [String: Any] = ["v": 1, "id": "t", "stops": [["index": 0, "sessionId": "s", "kind": "anchor", "at": "git-file", "path": "a.ts"]]]
        let engine = ScanEngine(now: { clock.ms }, requestFrame: { _ in NSObject() }, cancelFrame: { _ in })
        _ = TourPlayer(message: TourMessage(record: DriveTour.record(raw)!, stops: [TourStop(sessionId: "s", note: "n", why: "files-changed", kind: .anchor(at: "git-file", path: "a.ts"))]),
                       copilotSessionId: nil, engine: engine, navigator: window, focus: window, report: { _, _ in },
                       now: { clock.ms }, perfNow: { clock.ms }, schedule: clock.schedule)
        #expect(Set(window.panels) == ["git"])
        #expect(Set(window.focused) == [.anchor(.gitFile(cwd: "/work", path: "a.ts"))])
    }
}

@Suite("Driving — resolving a target")
struct DriveResolveTests {
    let viewport = DriveRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func anchorsPageAndTerminals() {
        var cached: BufferRegion?
        let frames = ["git-file:/w:a.ts": DriveRect(x: 10, y: 20, width: 100, height: 20), "usage:s": DriveRect(x: 990, y: 0, width: 50, height: 10)]
        let git = DriveFocusResolver.resolve(.anchor(.gitFile(cwd: "/w", path: "a.ts")), viewport: viewport, frame: { frames[$0] }, page: nil, terminal: { _ in nil }, cached: &cached)
        #expect(git.rect == DriveRect(x: 6, y: 16, width: 108, height: 28))
        #expect(DriveFocusResolver.resolve(.anchor(.message(messageId: "m")), viewport: viewport, frame: { frames[$0] }, page: nil, terminal: { _ in nil }, cached: &cached) == .failed(.anchorMissing))
        #expect(DriveFocusResolver.resolve(.page, viewport: viewport, frame: { _ in nil }, page: nil, terminal: { _ in nil }, cached: &cached) == .failed(.noPage))
        #expect(DriveFocusResolver.resolve(.terminal(sessionId: "x", quote: "q"), viewport: viewport, frame: { _ in nil }, page: nil, terminal: { _ in nil }, cached: &cached) == .failed(.notRegistered))

        let reader = Lines(lines: ["$ npm test", "FAIL src/a.test.ts", "done"])
        let screen = DriveRect(x: 100, y: 100, width: 800, height: 200)
        let term = DriveTerminalView(reader: reader, metrics: TerminalMetrics(screen: screen, cols: 80, rows: 10), viewportY: 0, alternateBuffer: false, rendered: true)
        let found = DriveFocusResolver.resolve(.terminal(sessionId: "s", quote: "FAIL src/a.test.ts"), viewport: viewport, frame: { _ in nil }, page: nil, terminal: { _ in term }, cached: &cached)
        #expect(found.rect != nil)
        #expect(cached?.line == 1)
        var full = term
        full.alternateBuffer = true
        #expect(DriveFocusResolver.resolve(.terminal(sessionId: "s", quote: "FAIL"), viewport: viewport, frame: { _ in nil }, page: nil, terminal: { _ in full }, cached: &cached) == .failed(.alternateBuffer))
        #expect(DriveFocusResolver.resolve(.terminal(sessionId: "s", quote: "missing"), viewport: viewport, frame: { _ in nil }, page: nil, terminal: { _ in term }, cached: &cached) == .failed(.quoteNotFound))
        #expect(DriveFocusResolver.scrollLine(for: "FAIL src", in: term) == 0)
    }
}
