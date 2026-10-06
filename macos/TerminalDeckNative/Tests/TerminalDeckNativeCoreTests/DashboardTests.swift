import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors src/renderer/dashboard/layout.test.ts, board.test.ts, useBoard.test.ts and
// the pure parts of widgets.test.tsx, plus the native grid's settle (gridstack's float:false).

private func layout(_ widgets: [DashboardWidget] = []) -> DashboardLayout {
    var l = DashboardRules.createLayout("/work/deck")
    l.widgets = widgets
    return l
}

private func w(_ id: String, _ x: Int, _ y: Int, _ width: Int = 6, _ h: Int = 6, type: WidgetType = .github) -> DashboardWidget {
    DashboardWidget(id: id, type: type, x: x, y: y, w: width, h: h)
}

private func noOverlaps(_ l: DashboardLayout) -> Bool {
    for (i, a) in l.widgets.enumerated() {
        for b in l.widgets.dropFirst(i + 1) where DashboardRules.overlaps(a, b) { return false }
    }
    return true
}

@Suite("Overview — the grid (layout.ts)")
struct DashboardLayoutTests {
    @Test func everySpecFitsTheGrid() {
        for type in WidgetType.allCases {
            let spec = DashboardRules.specs[type]!
            #expect(spec.minW <= spec.w && spec.w <= DashboardRules.columns)
            #expect(spec.minH <= spec.h)
        }
    }

    @Test func overlapsIsFalseOnASharedEdgeAndSymmetric() {
        let a = w("a", 0, 0, 6, 6)
        #expect(!DashboardRules.overlaps(a, w("b", 6, 0)))
        #expect(!DashboardRules.overlaps(a, w("b", 0, 6)))
        #expect(DashboardRules.overlaps(a, w("b", 5, 5, 3, 3)))
        #expect(DashboardRules.overlaps(a, w("b", 1, 1, 2, 2)))
        #expect(DashboardRules.overlaps(w("b", 5, 5, 3, 3), a))
    }

    @Test func findFreeSlot() {
        #expect(DashboardRules.findFreeSlot(layout(), w: 6, h: 6) == (0, 0))
        #expect(DashboardRules.findFreeSlot(layout([w("a", 0, 0)]), w: 6, h: 6) == (6, 0))
        #expect(DashboardRules.findFreeSlot(layout([w("a", 0, 0, 8, 6)]), w: 6, h: 6) == (0, 6))
        let holed = layout([w("a", 0, 0, 4, 6), w("c", 8, 0, 4, 6)])
        #expect(DashboardRules.findFreeSlot(holed, w: 4, h: 6) == (4, 0))
        #expect(DashboardRules.findFreeSlot(layout(), w: 6, h: 6, fromY: 3).y >= 3)
        #expect(DashboardRules.findFreeSlot(layout([w("a", 0, 0)]), w: 6, h: 6, ignoreId: "a") == (0, 0))
        #expect(DashboardRules.findFreeSlot(layout(), w: 99, h: 2) == (0, 0))
    }

    @Test func defaultLayoutSeedsUsageAndGit() {
        let d = DashboardRules.defaultLayout("/work/deck")
        #expect(d.widgets.map(\.type) == [.cost, .git])
        #expect(d.widgets.map(\.id) == ["cost-default", "git-default"])
        #expect(d.projectPath == "/work/deck")
        #expect(noOverlaps(d))
        #expect(!d.widgets.contains { $0.type == .sessions })
        #expect(!DashboardRules.pickable().contains(.sessions))
        // A saved layout may still hold the retired tile.
        let saved = DashboardRules.parse(["widgets": [["id": "s", "type": "sessions", "x": 0, "y": 0]]], projectPath: "/p")
        #expect(saved.widgets.first?.type == .sessions)
    }

    @Test func addWidget() {
        let one = DashboardRules.add(layout(), type: .git, id: "g")
        #expect(one.widgets[0].x == 0 && one.widgets[0].y == 0)
        let placed = DashboardRules.add(layout(), type: .git, id: "g", x: 6, y: 2)
        #expect(placed.widgets[0].x == 6 && placed.widgets[0].y == 2)
        let slid = DashboardRules.add(layout([w("a", 0, 0)]), type: .git, id: "g", x: 0, y: 0)
        #expect(slid.widgets[1].y >= 0 && noOverlaps(slid))
        #expect(DashboardRules.add(layout(), type: .git, id: "g", x: 11, y: 0).widgets[0].x == 6)
        let tiny = DashboardRules.add(layout(), type: .git, id: "g", w: 1, h: 1).widgets[0]
        #expect(tiny.w == 3 && tiny.h == 3)
        #expect(DashboardRules.add(layout(), type: .git, id: "g", w: 99).widgets[0].w == 12)
        let dup = DashboardRules.add(one, type: .github, id: "g")
        #expect(dup == one)
        #expect(DashboardRules.add(one, type: .git) == one)
        let two = DashboardRules.add(DashboardRules.add(layout(), type: .github), type: .github)
        #expect(two.widgets.count == 2)
        #expect(DashboardRules.canAdd(one, .git) == false)
        #expect(DashboardRules.canAdd(two, .github))
    }

    @Test func removeMoveResize() {
        let l = layout([w("a", 0, 0), w("b", 6, 0)])
        #expect(DashboardRules.remove(l, id: "a").widgets.map(\.id) == ["b"])
        #expect(DashboardRules.remove(l, id: "zz") == l)

        let free = layout([w("a", 0, 0)])
        #expect(DashboardRules.move(free, id: "a", x: 6, y: 3).widgets[0].x == 6)
        let clamped = DashboardRules.move(free, id: "a", x: 50, y: -4).widgets[0]
        #expect(clamped.x == 6 && clamped.y == 0)
        let collided = DashboardRules.move(l, id: "a", x: 6, y: 0)
        #expect(noOverlaps(collided))
        #expect(collided.widgets[0].y >= 0)
        #expect(DashboardRules.move(l, id: "a", x: 0, y: 0) == l)
        #expect(DashboardRules.move(l, id: "zz", x: 1, y: 1) == l)

        #expect(DashboardRules.resize(free, id: "a", w: 8, h: 8).widgets[0].w == 8)
        let wall = DashboardRules.resize(layout([w("a", 6, 0)]), id: "a", w: 12, h: 6).widgets[0]
        #expect(wall.x == 6 && wall.w == 6)
        #expect(DashboardRules.resize(free, id: "a", w: 1, h: 1).widgets[0].w == 3)
        #expect(DashboardRules.resize(l, id: "a", w: 8, h: 6) == l)
        #expect(DashboardRules.resize(free, id: "a", w: 6, h: 6) == free)
    }

    @Test func applyPlacements() {
        let l = layout([w("a", 0, 0), w("b", 6, 0)])
        let swapped = DashboardRules.applyPlacements(l, [WidgetPlacement(id: "a", x: 6), WidgetPlacement(id: "b", x: 0)])
        #expect(swapped.widgets.map(\.x) == [6, 0])
        #expect(DashboardRules.applyPlacements(l, [WidgetPlacement(id: "a", y: 2)]).widgets[0].w == 6)
        #expect(DashboardRules.applyPlacements(l, []) == l)
        #expect(DashboardRules.applyPlacements(l, [WidgetPlacement(id: "zz", x: 3)]) == l)
        #expect(DashboardRules.applyPlacements(l, [WidgetPlacement(id: "a", x: 0, y: 0)]) == l)
        #expect(DashboardRules.applyPlacements(l, [WidgetPlacement(id: "a", x: -9, y: 99_999)]).widgets[0].y == DashboardRules.maxRow)
        #expect(DashboardRules.applyPlacements(l, [WidgetPlacement(id: "a", x: 1), WidgetPlacement(id: "a", x: 2)]).widgets[0].x == 2)
    }

    @Test func serialiseAndParse() {
        let l = DashboardRules.add(DashboardRules.defaultLayout("/p"), type: .readiness, id: "r")
        let body = DashboardRules.serialise(l)
        #expect(body["version"] as? Int == 1)
        let json = try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: body))
        #expect(DashboardRules.parse(json, projectPath: "/p") == l)
        #expect(DashboardRules.parse(nil, projectPath: "/p") == DashboardRules.defaultLayout("/p"))
        #expect(DashboardRules.parse(["widgets": []], projectPath: "/p").widgets.isEmpty)
        #expect(DashboardRules.parse(["projectPath": "/elsewhere", "widgets": []], projectPath: "/p").projectPath == "/p")
        let junk = DashboardRules.parse(["widgets": [1, "x", ["type": "nope"], ["type": "git", "id": "g"], ["type": "github", "id": "g"], ["type": "github"]]], projectPath: "/p")
        #expect(junk.widgets.count == 3)
        #expect(Set(junk.widgets.map(\.id)).count == 3)
        #expect(junk.widgets[0].id == "g")
        #expect(noOverlaps(junk))
        let overlapping = DashboardRules.parse(["widgets": [["type": "git", "id": "a", "x": 0, "y": 0], ["type": "cost", "id": "b", "x": 0, "y": 0]]], projectPath: "/p")
        #expect(overlapping.widgets[0].x == 0 && overlapping.widgets[0].y == 0)
        #expect(noOverlaps(overlapping))
        let wide = DashboardRules.parse(["widgets": [["type": "git", "id": "a", "x": 40, "y": 0, "w": 30]]], projectPath: "/p").widgets[0]
        #expect(wide.x + wide.w <= 12)
        let twice = DashboardRules.parse(["widgets": [["type": "git", "id": "a"], ["type": "git", "id": "b"]]], projectPath: "/p")
        #expect(twice.widgets.count == 2)
    }

    @Test func boundedWork() {
        let tall = DashboardRules.parse(["widgets": [["type": "git", "id": "a", "h": 10_000_000, "y": 10_000_000]]], projectPath: "/p").widgets[0]
        #expect(tall.h == DashboardRules.maxWidgetRows)
        #expect(tall.y == DashboardRules.maxRow)
        let many = DashboardRules.parse(["widgets": (0..<500).map { ["type": "github", "id": "g\($0)"] }], projectPath: "/p")
        #expect(many.widgets.count == DashboardRules.maxWidgets)
    }

    @Test func selectors() {
        let l = layout([w("b", 6, 0), w("a", 0, 0), w("c", 0, 6, 6, 3)])
        #expect(DashboardRules.rows(l) == 9)
        #expect(DashboardRules.readingOrder(l).map(\.id) == ["a", "b", "c"])
    }

    @Test func neverTwoWidgetsInOneCellOverALongSession() {
        var rng = SystemRandomNumberGenerator()
        var l = DashboardRules.defaultLayout("/p")
        for step in 0..<400 {
            let ids = l.widgets.map(\.id)
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: l = DashboardRules.add(l, type: [.github, .readiness, .cost, .git].randomElement()!)
            case 1: if let id = ids.randomElement() { l = DashboardRules.remove(l, id: id) }
            case 2: if let id = ids.randomElement() { l = DashboardRules.move(l, id: id, x: Int.random(in: -2...14), y: Int.random(in: -2...20)) }
            case 3: if let id = ids.randomElement() { l = DashboardRules.resize(l, id: id, w: Int.random(in: 0...14), h: Int.random(in: 0...12)) }
            default: if let id = ids.randomElement() {
                l = DashboardRules.preview(l, id: id, x: Int.random(in: 0...11), y: Int.random(in: 0...20), w: 6, h: 6)
            }
            }
            #expect(noOverlaps(l), "step \(step)")
        }
    }
}

@Suite("Overview — settling the grid (gridstack float:false)")
struct DashboardSettleTests {
    @Test func floatsWidgetsUpIntoFreeRows() {
        let settled = DashboardRules.settle(layout([w("a", 0, 5), w("b", 6, 9)]))
        #expect(settled.widgets.map(\.y) == [0, 0])
    }

    @Test func pushesWidgetsOutOfADraggedOnesWay() {
        let l = layout([w("a", 0, 0), w("b", 6, 0)])
        let dragged = DashboardRules.preview(l, id: "b", x: 0, y: 0, w: 6, h: 6)
        let b = dragged.widgets.first { $0.id == "b" }!
        let a = dragged.widgets.first { $0.id == "a" }!
        #expect(b.x == 0 && b.y == 0)
        #expect(a.y == 6)
        #expect(noOverlaps(dragged))
    }

    @Test func resizingPushesTheNeighbourDown() {
        let l = layout([w("a", 0, 0), w("b", 6, 0)])
        let wider = DashboardRules.preview(l, id: "a", x: 0, y: 0, w: 9, h: 6)
        #expect(wider.widgets.first { $0.id == "a" }?.w == 9)
        #expect(wider.widgets.first { $0.id == "b" }?.y == 6)
        #expect(noOverlaps(wider))
    }
}

@Suite("Overview — the running-sessions board (board.ts)")
struct BoardTests {
    let now = 10_000_000.0
    let minute = 60_000.0

    func s(_ id: String, _ status: String, since: Double = 0, started: Double = 0) -> BoardSession {
        BoardSession(id: id, title: id, projectPath: "/work/deck", status: status, statusSince: since, startedAt: started)
    }

    @Test func attention() {
        #expect(BoardRules.attention("input") == .blocked)
        #expect(BoardRules.attention("completed") == .finished)
        #expect(BoardRules.attention("waiting") == .ready)
        #expect(BoardRules.attention("idle") == .ready)
        #expect(BoardRules.attention("working") == .working)
        #expect(BoardRules.attention("exited") == .exited)
        #expect(BoardRules.attention("something new") == .ready)
    }

    @Test func sortPutsWaitingOnYouFirst() {
        let sorted = BoardRules.sort([s("w", "working", since: 5), s("b", "input", since: 9), s("f", "completed", since: 3)])
        #expect(sorted.map(\.id) == ["b", "f", "w"])
        let blocked = BoardRules.sort([s("new", "input", since: 9), s("old", "input", since: 1)])
        #expect(blocked.map(\.id) == ["old", "new"])
        let working = BoardRules.sort([s("old", "working", since: 1), s("new", "working", since: 9)])
        #expect(working.map(\.id) == ["new", "old"])
    }

    @Test func countsAndSummary() {
        let counts = BoardRules.count([s("a", "input"), s("b", "completed"), s("c", "working"), s("d", "idle"), s("e", "exited")])
        #expect(counts.wantsYou == 2)
        #expect(counts.total == 5)
        #expect(BoardRules.summaryParts(counts).map(\.text) == ["1 needs you", "1 finished", "1 working", "1 at a prompt", "1 exited"])
        let two = BoardRules.count([s("a", "input"), s("b", "input"), s("c", "working")])
        #expect(BoardRules.summaryParts(two).map(\.text) == ["2 need you", "1 working"])
        #expect(BoardRules.summaryParts(two).first?.attention == .blocked)
    }

    @Test func formatElapsed() {
        #expect(BoardRules.formatElapsed(200) == "1s")
        #expect(BoardRules.formatElapsed(45_000) == "45s")
        #expect(BoardRules.formatElapsed(5 * minute) == "5m")
        #expect(BoardRules.formatElapsed(60 * minute) == "1h")
        #expect(BoardRules.formatElapsed(90 * minute) == "1h 30m")
        #expect(BoardRules.formatElapsed(24 * 60 * minute) == "1d")
        #expect(BoardRules.formatElapsed(26 * 60 * minute) == "1d 2h")
        #expect(BoardRules.formatElapsed(-1) == "")
        #expect(BoardRules.formatElapsed(.nan) == "")
    }

    @Test func stateSentence() {
        #expect(BoardRules.stateSentence(s("a", "input", since: now - 5 * minute), now: now) == "Waiting on you for 5m")
        #expect(BoardRules.stateSentence(s("a", "completed", since: now - minute), now: now) == "Finished its turn for 1m")
        #expect(BoardRules.stateSentence(s("a", "idle", since: now - minute), now: now) == "At a prompt")
        #expect(BoardRules.stateSentence(s("a", "working"), now: now) == "Working")
        #expect(BoardRules.stateSentence(s("a", "exited", since: now - 3 * minute), now: now) == "Exited 3m ago")
        #expect(BoardRules.stateSentence(s("a", "exited"), now: now) == "Exited")
    }

    @Test func labels() {
        #expect(BoardRules.providerLabel("claude") == "Claude Code")
        #expect(BoardRules.providerLabel("aider") == "aider")
        #expect(BoardRules.folderOf("/Users/me/deck") == "deck")
        #expect(BoardRules.folderOf("C:\\work\\shop") == "shop")
        #expect(BoardRules.folderOf("/Users/me/deck/") == "deck")
        #expect(BoardRules.label(.blocked) == "Needs you")
        #expect(BoardRules.label(.ready) == "Ready")
    }

    @Test func namesNumberPerFolderAndMarkTwins() {
        let sessions = [BoardSession(id: "a1-x", title: "deck", projectPath: "/w/deck"),
                        BoardSession(id: "b2-y", title: "Fix the relay", projectPath: "/w/deck"),
                        BoardSession(id: "c3-z", title: "Fix the relay", projectPath: "/w/deck")]
        let (names, twins) = BoardRules.names(sessions)
        #expect(names["a1-x"] == "Session 1")
        #expect(names["b2-y"] == "Fix the relay")
        #expect(twins == ["b2-y", "c3-z"])
        #expect(BoardRules.shortSessionId("b2-y") == "b2")
        #expect(BoardRules.sessionLabel("me@host:~/x", index: 1, folderName: "x") == "Session 2")
    }

    @Test func metaNamesTheAccount() {
        let mine = BoardSession(id: "a", title: "t", projectPath: "/w", provider: "codex", account: BoardAccount(id: "personal", name: "Personal"), startedAt: now - 5 * minute)
        #expect(BoardRules.meta(mine, now: now) == "Codex · Personal · started 5m ago")
        let system = BoardSession(id: "a", title: "t", projectPath: "/w", provider: "claude", account: BoardAccount(id: "system", name: "x"))
        #expect(BoardRules.meta(system, now: now) == "Claude Code · Your own Claude Code install")
    }

    @Test func workFromSummary() {
        let usage: [String: Any] = ["input": 1000, "output": 2000, "cacheWrite5m": 500, "cacheWrite1h": 0, "cacheRead": 40_000]
        let summary: [String: Any] = ["sessions": [["sessionId": "abc", "requests": 12, "usage": usage, "context": ["percent": 62], "lastActivityAt": now]]]
        let work = BoardRules.work(summary, sessionId: "abc", transcriptPath: "/t/abc.jsonl")
        #expect(work?.tokens == 43_500)
        #expect(work?.requests == 12)
        #expect(work?.contextPercent == 62)
        let first: [String: Any] = ["sessions": [["sessionId": "abc", "requests": 1, "usage": usage]]]
        #expect(BoardRules.work(first, sessionId: "abc", transcriptPath: "")?.contextPercent == nil)
        #expect(BoardRules.work(first, sessionId: "xyz", transcriptPath: "") == nil)
        #expect(BoardRules.work(nil, sessionId: "abc", transcriptPath: "") == nil)
        #expect(BoardRules.work(["sessions": "not an array"], sessionId: "abc", transcriptPath: "") == nil)
    }

    @Test func readsASessionFromTheEngine() {
        let meta = BoardRules.sessionMeta(["id": "t1", "cwd": "/w/deck", "title": "", "provider": "codex", "createdAt": 5,
                                           "exitCode": NSNull(), "profileId": "p", "profileName": "Personal"])
        #expect(meta?.title == "deck")
        #expect(meta?.status == "idle")
        #expect(meta?.account == BoardAccount(id: "p", name: "Personal"))
        #expect(BoardRules.sessionMeta(["id": "t1", "cwd": "/w", "exitCode": 0])?.status == "exited")
        #expect(BoardRules.sessionMeta(["id": "t1"]) == nil)
    }
}

@Suite("Overview — attaching each session's work (useBoard.ts)")
struct BoardWorkTests {
    let now = 100_000_000.0
    let minute = 60_000.0
    let here = "/Users/apple/Projects/deck"

    func file(_ id: String, _ created: Double, _ modified: Double? = nil) -> TranscriptFile {
        TranscriptFile(path: "/store/\(id).jsonl", sessionId: id, createdAt: created, modifiedAt: modified ?? created)
    }

    func folder(_ files: [TranscriptFile], _ ids: [String]) -> BoardRules.FolderWork {
        let usage: [String: Any] = ["input": 4000, "output": 6000]
        return BoardRules.FolderWork(files: files, summary: ["sessions": ids.map { ["sessionId": $0, "requests": 7, "usage": usage] }])
    }

    func live(_ id: String, path: String? = nil, status: String = "working", resumed: Bool = false) -> BoardSession {
        BoardSession(id: id, title: id, projectPath: path ?? here, status: status, startedAt: now - 10 * minute, resumed: resumed)
    }

    @Test func attachesTheConversationThatBeganAfterTheTab() {
        let card = BoardRules.attachWork([live("tab-1")], folders: [here: folder([file("own", now - 9 * minute)], ["own"])])[0]
        #expect(card.work?.transcriptPath == "/store/own.jsonl")
        #expect(card.work?.requests == 7)
        #expect(card.work?.tokens == 10_000)
    }

    @Test func showsNothingForAConversationThatPredatesTheSession() {
        let card = BoardRules.attachWork([live("tab-1")], folders: [here: folder([file("stranger", now - 180 * minute, now)], ["stranger"])])[0]
        #expect(card.work == nil)
        #expect(BoardRules.attachWork([live("tab-1")], folders: [:])[0].work == nil)
    }

    @Test func givesAContinuedSessionTheConversationItContinued() {
        let card = BoardRules.attachWork([live("tab-1", resumed: true)], folders: [here: folder([file("older", now - 180 * minute, now)], ["older"])])[0]
        #expect(card.work?.transcriptPath == "/store/older.jsonl")
    }

    @Test func folderPlan() {
        let other = "/Users/apple/Projects/science-locus"
        let plan = BoardRules.folderPlan([live("a"), live("b"), live("c", path: other)], folders: [:])
        #expect(plan.count == 2)
        #expect(Set(plan.map(\.cwd)) == [here, other])
        let one = BoardRules.folderPlan([live("a")], folders: [:])[0]
        let two = BoardRules.folderPlan([live("a"), live("b")], folders: [:])[0]
        #expect(one.sessionKey != two.sessionKey)
        #expect(BoardRules.folderPlan([live("b"), live("a")], folders: [:])[0].sessionKey == two.sessionKey)
        #expect(one.awaiting)
        #expect(!BoardRules.folderPlan([live("a")], folders: [here: folder([file("own", now - 9 * minute)], ["own"])])[0].awaiting)
        #expect(!BoardRules.folderPlan([live("a", status: "exited")], folders: [:])[0].awaiting)
        #expect(!BoardRules.folderPlan([live("a", status: "exited")], folders: [:])[0].live)
        #expect(BoardRules.folderPlan([live("a", status: "exited"), live("b")], folders: [:])[0].live)
    }
}

@Suite("Overview — the widgets' words (widgets.tsx)")
struct WidgetWordTests {
    @Test func formatTokens() {
        #expect(DashboardWords.formatTokens(4_622_270_000) == "4.62B")
        #expect(DashboardWords.formatTokens(1_000_000_000) == "1B")
        #expect(DashboardWords.formatTokens(0) == "0")
        #expect(DashboardWords.formatTokens(999) == "999")
        #expect(DashboardWords.formatTokens(41_800) == "41.8k")
        #expect(DashboardWords.formatTokens(1_500_000) == "1.5M")
        #expect(DashboardWords.formatTokens(999_950) == "1M")
        #expect(DashboardWords.formatTokens(999_999_500) == "1B")
        #expect(DashboardWords.formatTokens(-4_622_270_000) == "-4.62B")
    }

    @Test func pluralAndPercent() {
        #expect(DashboardWords.plural(1, "session") == "session")
        #expect(DashboardWords.plural(0, "session") == "sessions")
        #expect(DashboardWords.plural(3, "is", "are") == "are")
        #expect(DashboardWords.formatPercent(0.004) == "<1%")
        #expect(DashboardWords.formatPercent(0) == "0%")
        #expect(DashboardWords.formatPercent(0.926) == "93%")
    }

    @Test func usageFromTheEngine() {
        let raw: [String: Any] = [
            "usage": ["input": 1000, "output": 1000, "cacheWrite5m": 1000, "cacheWrite1h": 0, "cacheRead": 7000],
            "requests": 3, "sessions": [["sessionId": "abcdef123", "context": ["percent": 75, "tokens": 150_000, "window": 200_000], "models": ["opus"]]],
            "activeSessionId": "abcdef123", "usageByModel": ["haiku": ["input": 1], "opus": ["input": 9]],
        ]
        let view = UsageRules.view(raw)
        #expect(view.tokens.total == 10_000)
        #expect(view.tokens.cacheHitRate == 7000.0 / 9000.0)
        #expect(view.models == ["opus", "haiku"])
        #expect(view.context?.model == "opus")
        #expect(DashboardWords.contextTone(view.context?.percent) == .warn)
        #expect(UsageRules.lines(view.tokens).map(\.label) == ["Fresh input", "Cache writes", "Cache reads", "Output"])
        #expect(UsageRules.note(view) == "10k tokens across 3 requests — every request your agents made in this folder, counted once, from their own session records.")
        #expect(UsageRules.contextNote(view.context!) == "Most recent session here, on opus — 150k of its 200k window.")
        #expect(UsageRules.quietNote(view) == "78% of the prompt came from cache, re-read each turn rather than sent again. Models seen: opus, haiku.")
        let empty = UsageRules.view(["scanning": true])
        #expect(empty.requests == 0)
        #expect(UsageRules.emptyTitle(empty) == "Still scanning…")
    }

    @Test func gitWords() {
        #expect(GitWidgetRules.changeLabel(kind: "modified", code: " M") == "Modified")
        #expect(GitWidgetRules.changeLabel(kind: "unknown", code: " X") == "X")
        #expect(GitWidgetRules.changeLabel(kind: "unknown", code: "  ") == "?")
        #expect(GitWidgetRules.notRepoTitle("not-a-repo") == "Nothing to track here")
        #expect(GitWidgetRules.notRepoTitle(nil) == "Source control is unavailable")
        let status = GitWidgetRules.status(["repo": true, "branch": ["detached": true, "oid": "abcdef1234"],
                                            "staged": [["path": "a"], ["path": "b"]], "conflicted": [["path": "c"]], "untracked": [["path": "d"]]])
        #expect(GitWidgetRules.branchName(status) == "detached at abcdef1")
        let (shown, hidden) = GitWidgetRules.visibleFiles(status, limit: 2)
        #expect(shown.map(\.path) == ["c", "a"])
        #expect(hidden == 2)
        #expect(GitWidgetRules.visibleFiles(status, limit: -5).hidden == 4)
        #expect(GitWidgetRules.branchName(GitWidgetRules.status(["repo": true])) == "no branch yet")
    }

    @Test func readinessAndGithub() {
        let view = ReadinessWidgetRules.view(["score": 64.6, "band": "Getting there",
                                              "checks": [["id": "a", "status": "pass"], ["id": "b", "status": "fail", "gate": true], ["status": "odd"]]])
        #expect(view.score == 65)
        #expect(ReadinessWidgetRules.tone(view.score) == .warn)
        #expect(ReadinessWidgetRules.sorted(view.checks).map(\.status) == ["fail", "pass", "skip"])
        #expect(ReadinessWidgetRules.passing(view.checks) == "1/2")
        #expect(view.checks[2].id == "2")

        let gh = GithubWidgetRules.view(["ok": true, "repo": ["nameWithOwner": "asadev/deck"],
                                         "pulls": ["ok": true, "value": [["number": 1, "title": "PR 1"], ["title": "no number"]]],
                                         "issues": ["ok": false, "message": "issues off"]])
        #expect(gh.repo == "asadev/deck")
        #expect(gh.items.count == 2)
        #expect(gh.items[1].number == 0)
        #expect(gh.items[0].key != gh.items[1].key)
        #expect(gh.partial == ["issues off"])
        #expect(GithubWidgetRules.view(nil).failure == "No answer from gh.")
        #expect(GithubWidgetRules.view(["ok": false]).failure == "GitHub is unavailable.")
    }

    @Test func featureSwitches() {
        let state = DashboardRules.featureState(#"{"usage":"off","github":"uninstalled","readiness":"on","x":5}"#)
        #expect(!DashboardRules.widgetOn(.cost, features: state))
        #expect(!DashboardRules.widgetOn(.github, features: state))
        #expect(DashboardRules.widgetOn(.readiness, features: state))
        #expect(DashboardRules.widgetOn(.git, features: state))
        #expect(DashboardRules.widgetOn(.cost, features: [:]))
        #expect(DashboardRules.featureState(nil).isEmpty)
    }
}
