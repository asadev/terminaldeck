import Foundation
import Testing
@testable import TerminalDeckNativeCore

private func json(_ text: String) -> Any {
    try! JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

private func artifact(_ relPath: String, writes: Int = 1, edits: Int = 0, sessions: [String] = ["s1"],
                      lastAt: Double = 0, bytes: Int? = 100) -> Artifact {
    Artifact(relPath: relPath, lastAt: lastAt, writes: writes, edits: edits, sessionIds: sessions,
             onDisk: bytes.map { ArtifactOnDisk(bytes: $0, modifiedAt: 0) })
}

@Suite("Artifacts — the engine's answers")
struct ArtifactsWireTests {
    @Test func decodesAListAnswer() throws {
        let raw = json(#"""
        {"ok":true,"root":"/Users/me/deck","scope":"all","sessionsScanned":7,"outsideProject":2,
         "truncated":false,"cancelled":false,"tookMs":812,
         "artifacts":[
           {"relPath":"proto/index.html","name":"index.html","firstAt":1000,"lastAt":2000,"writes":2,"edits":1,
            "lastChars":512,"lastTool":"Write","sessionIds":["a","b"],"onDisk":{"bytes":4096,"modifiedAt":1999}},
           {"relPath":"shots/gone.png","name":"gone.png","firstAt":1,"lastAt":"3000","writes":1,"edits":0,
            "lastChars":0,"lastTool":"Write","sessionIds":["a",7],"onDisk":null},
           {"name":"no path at all"}
         ],
         "sessions":[{"sessionId":"a","at":3000,"files":2},{"sessionId":"b","at":2000,"files":1},{"at":5}]}
        """#)
        guard case .done(let list) = ArtifactsWire.list(raw) else {
            Issue.record("expected a list"); return
        }
        #expect(list.root == "/Users/me/deck")
        #expect(list.scope == .all)
        #expect(list.sessionsScanned == 7)
        #expect(list.outsideProject == 2)
        #expect(list.artifacts.map(\.relPath) == ["proto/index.html", "shots/gone.png"])
        #expect(list.artifacts[0].onDisk == ArtifactOnDisk(bytes: 4096, modifiedAt: 1999))
        #expect(list.artifacts[0].sessionIds == ["a", "b"])
        #expect(list.artifacts[1].onDisk == nil)
        #expect(list.artifacts[1].lastAt == 3000)
        #expect(list.artifacts[1].sessionIds == ["a"])
        #expect(list.sessions.map(\.sessionId) == ["a", "b"])
        #expect(list.sessions[0].files == 2)
    }

    @Test func aMissingNameFallsBackToTheFileName() throws {
        let raw = json(#"{"ok":true,"root":"/r","artifacts":[{"relPath":"a/b/c.pdf"}],"sessions":[]}"#)
        guard case .done(let list) = ArtifactsWire.list(raw) else { Issue.record("expected a list"); return }
        #expect(list.artifacts[0].name == "c.pdf")
        #expect(list.scope == .project)
    }

    @Test func cancelledAndFailedAnswers() {
        let cancelled = ArtifactsWire.list(json(#"{"ok":false,"error":"cancelled","message":"Scan cancelled."}"#))
        #expect(cancelled == .cancelled)
        #expect(cancelled.failureMessage == "That scan was stopped before it finished. Read it again?")

        let failed = ArtifactsWire.list(json(#"{"ok":false,"error":"failed","message":"Could not read this project’s history."}"#))
        #expect(failed == .failed("Could not read this project’s history."))

        #expect(ArtifactsWire.list(json(#"[1,2]"#)) == .failed("The engine’s answer could not be read."))
        #expect(ArtifactsWire.list(json(#""nope""#)).failureMessage != nil)
    }

    @Test func decodesAHistoryAnswer() {
        let raw = json(#"""
        {"ok":true,"root":"/r","relPath":"index.html","totalChanges":3,"truncated":true,"cancelled":false,"tookMs":4,
         "changes":[
           {"at":3,"sessionId":"a","action":"edit","tool":"Edit","before":"a\n","after":"b\n","replaceAll":true,"clipped":false},
           {"at":2,"sessionId":"a","action":"write","tool":"Write","before":"","after":"<html>","replaceAll":false,"clipped":true},
           {"at":1,"action":"rename"}
         ]}
        """#)
        guard case .done(let history) = ArtifactsWire.history(raw) else { Issue.record("expected history"); return }
        #expect(history.changes.count == 2)
        #expect(history.changes[0].action == .edit)
        #expect(history.changes[0].replaceAll)
        #expect(history.changes[1].action == .write)
        #expect(history.changes[1].clipped)
        #expect(history.totalChanges == 3)
        #expect(history.truncated)
    }

    @Test func requestsCarryTheScope() {
        let list = ArtifactsWire.listRequest(cwd: "/p", scope: .all)
        #expect(list["cwd"] as? String == "/p")
        #expect(list["scope"] as? String == "all")
        let changes = ArtifactsWire.changesRequest(cwd: "/p", relPath: "a.html", scope: .project)
        #expect(changes["relPath"] as? String == "a.html")
        #expect(changes["scope"] as? String == "project")
    }

    @Test func sessionNames() {
        let raw = json(#"""
        [{"id":"t1","cwd":"/p/one","title":"Rewrite the hero","agentSessionId":"conv-1"},
         {"id":"t2","cwd":"/p/two","title":"two"},
         {"id":"t3","cwd":"/p/one","title":"","agentSessionId":"conv-3"},
         "junk"]
        """#)
        #expect(ArtifactsWire.sessionNames(raw) == ["conv-1": "Rewrite the hero"])
        #expect(ArtifactsWire.sessionNames(json("{}")).isEmpty)
    }
}

@Suite("Artifacts — what a row is")
struct ArtifactsKindTests {
    @Test func onlyPrototypesPicturesAndRecordingsAreArtifacts() {
        for path in ["index.html", "a/b.HTM", "x.png", "y.svg", "doc.pdf", "clip.mov", "voice.m4a"] {
            #expect(ArtifactRules.isArtifact(path), "\(path)")
        }
        for path in ["PLAN.md", "src/app.ts", "style.css", "data.json", ".gitignore", "Makefile", "notes.txt"] {
            #expect(!ArtifactRules.isArtifact(path), "\(path)")
        }
    }

    @Test func kindWords() {
        #expect(ArtifactRules.kindOf("a/index.html") == "Web page")
        #expect(ArtifactRules.kindOf("shot.PNG") == "Image")
        #expect(ArtifactRules.kindOf("deck.pdf") == "Document")
        #expect(ArtifactRules.kindOf("clip.mp4") == "Video")
        #expect(ArtifactRules.kindOf("beep.wav") == "Sound")
        #expect(ArtifactRules.kindOf(".gitignore") == "Setting")
        #expect(ArtifactRules.kindOf(".env.local") == "File")
        #expect(ArtifactRules.kindOf("Makefile") == "File")
        #expect(ArtifactRules.extensionOf(".env") == "")
    }

    @Test func previewKindsAndOpenLabels() {
        #expect(ArtifactRules.previewKindOf("index.html") == .page)
        #expect(ArtifactRules.previewKindOf("a.png") == .image)
        #expect(ArtifactRules.previewKindOf("README.md") == .document)
        #expect(ArtifactRules.previewKindOf("deck.pdf") == .text)
        #expect(ArtifactRules.previewKindOf("clip.mov") == .none)
        #expect(ArtifactRules.openLabel(.page) == "Run it in your browser")
        #expect(ArtifactRules.openLabel(.image) == "Open the picture")
        #expect(ArtifactRules.openLabel(.none) == "Open it on this machine")
    }

    @Test func pathParts() {
        #expect(ArtifactRules.directoryOf("a/b/c.html") == "a/b")
        #expect(ArtifactRules.directoryOf("c.html") == "")
        #expect(ArtifactRules.lastComponent("a/b/c.html") == "c.html")
    }
}

@Suite("Artifacts — grouping and filtering")
struct ArtifactsFilterTests {
    let list = ArtifactList(
        root: "/p",
        artifacts: [
            artifact("site/index.html", writes: 1, sessions: ["a"]),
            artifact("PLAN.md", writes: 3, sessions: ["a", "b"]),
            artifact("src/app.ts", writes: 0, edits: 4, sessions: ["b"]),
            artifact("shots/Hero.png", writes: 0, edits: 1, sessions: ["c"]),
            artifact("demo.mov", writes: 1, sessions: ["c"], bytes: nil),
        ],
        sessions: [
            ArtifactSession(sessionId: "a", at: 30, files: 2),
            ArtifactSession(sessionId: "b", at: 20, files: 2),
            ArtifactSession(sessionId: "c", at: 10, files: 2),
        ],
        sessionsScanned: 3)

    @Test func theRuleRunsOnceAndRecountsSessions() {
        let (found, hidden) = ArtifactRules.onlyArtifacts(list)
        #expect(hidden == 2)
        #expect(found.artifacts.map(\.relPath) == ["site/index.html", "shots/Hero.png", "demo.mov"])
        // b's whole contribution was prose and source: its chip goes.
        #expect(found.sessions.map(\.sessionId) == ["a", "c"])
        #expect(found.sessions.map(\.files) == [1, 2])
    }

    @Test func nothingToNarrowLeavesTheListAlone() {
        let clean = ArtifactList(root: "/p", artifacts: [artifact("a.html")], sessions: [ArtifactSession(sessionId: "s1", at: 1, files: 1)])
        let (found, hidden) = ArtifactRules.onlyArtifacts(clean)
        #expect(hidden == 0)
        #expect(found == clean)
    }

    @Test func madeChangedSessionAndName() {
        let found = ArtifactRules.onlyArtifacts(list).list.artifacts
        #expect(ArtifactRules.visible(found, kind: .made, session: nil, filter: "").map(\.relPath) == ["site/index.html", "demo.mov"])
        #expect(ArtifactRules.visible(found, kind: .changed, session: nil, filter: "").map(\.relPath) == ["shots/Hero.png"])
        #expect(ArtifactRules.visible(found, kind: .made, session: "c", filter: "").map(\.relPath) == ["demo.mov"])
        #expect(ArtifactRules.visible(found, kind: .made, session: nil, filter: "  SITE ").map(\.relPath) == ["site/index.html"])
        #expect(ArtifactRules.visible(found, kind: .changed, session: nil, filter: "hero").count == 1)
        let counts = ArtifactRules.counts(found)
        #expect(counts.made == 2)
        #expect(counts.changed == 1)
    }

    @Test func aSessionFilterOnlyLivesWhileItsChipIsDrawn() {
        let two = [ArtifactSession(sessionId: "a", at: 1, files: 1), ArtifactSession(sessionId: "b", at: 1, files: 1)]
        #expect(ArtifactRules.keptSession("a", sessions: two) == "a")
        #expect(ArtifactRules.keptSession("z", sessions: two) == nil)
        #expect(ArtifactRules.keptSession("a", sessions: Array(two.prefix(1))) == nil)
        #expect(ArtifactRules.keptSession(nil, sessions: two) == nil)
    }

    @Test func thePageOpensOnContent() {
        let rows = [artifact("a.html"), artifact("b.png")]
        #expect(ArtifactRules.selection(current: nil, visible: rows) == "a.html")
        #expect(ArtifactRules.selection(current: "b.png", visible: rows) == "b.png")
        #expect(ArtifactRules.selection(current: "gone.png", visible: rows) == "a.html")
        #expect(ArtifactRules.selection(current: "a.html", visible: []) == nil)
    }

    @Test func emptyListNotes() {
        #expect(ArtifactRules.noRowsNote(filter: "x", session: nil, kind: .made) == "Nothing matches that filter.")
        #expect(ArtifactRules.noRowsNote(filter: " ", session: "a", kind: .changed) == "Nothing matches that filter.")
        #expect(ArtifactRules.noRowsNote(filter: "", session: nil, kind: .made)
            == "No agent has made an artifact here yet. What it edited is under Changed.")
        #expect(ArtifactRules.noRowsNote(filter: "", session: nil, kind: .changed)
            == "Every artifact here was made by an agent rather than edited into.")
    }
}

@Suite("Artifacts — what the page says")
struct ArtifactsSentenceTests {
    @Test func summaryCountsTheChipOnScreen() {
        let found = ArtifactList(root: "/p",
                                 artifacts: [artifact("a.html"), artifact("b.html"), artifact("c.png", writes: 0, edits: 2)],
                                 sessions: [ArtifactSession(sessionId: "s1", at: 1, files: 3)])
        #expect(ArtifactRules.summarize(found, shown: 2, kind: .made) == "2 made here · 1 session")
        #expect(ArtifactRules.summarize(found, shown: 1, kind: .made) == "1 of 2 made here · 1 session")
        #expect(ArtifactRules.summarize(found, shown: 1, kind: .changed) == "1 changed · 1 session")
        let truncated = ArtifactList(root: "/p", artifacts: found.artifacts, sessions: [], truncated: true)
        #expect(ArtifactRules.summarize(truncated, shown: 2, kind: .made) == "2 made here · 0 sessions · older work not read")
    }

    @Test func aZeroCarriesItsEvidence() {
        let none = ArtifactList(root: "/Users/me/Templates", sessionsScanned: 0)
        #expect(ArtifactRules.nothingFound(none) == "Nothing written or edited in /Users/me/Templates — no sessions have been recorded for it yet.")
        let read = ArtifactList(root: "/p", sessionsScanned: 15, outsideProject: 40)
        #expect(ArtifactRules.nothingFound(read) == "Nothing written or edited in /p by its own sessions — 15 read, 40 changes to files outside it.")
        let one = ArtifactList(root: "/p", sessionsScanned: 1, outsideProject: 0)
        #expect(ArtifactRules.nothingFound(one) == "Nothing written or edited in /p by its own sessions — 1 read.")
        #expect(ArtifactRules.summarize(one, shown: 0, kind: .made) == ArtifactRules.nothingFound(one))
    }

    /// The sentence names the sessions the selected scope read — "40 sessions read" under
    /// Every session read as if this folder had forty of its own (on-screen check, 2026-10-06).
    @Test func theSentenceAgreesWithTheScope() {
        let every = ArtifactList(root: "/p", scope: .all, sessionsScanned: 40, outsideProject: 528)
        #expect(ArtifactRules.nothingFound(every)
            == "Nothing written or edited in /p by any session — 40 read across every project, 528 changes to files outside it.")
        let nothingOnThisMac = ArtifactList(root: "/p", scope: .all, sessionsScanned: 0)
        #expect(ArtifactRules.nothingFound(nothingOnThisMac) == "Nothing written or edited in /p — no sessions have been recorded on this Mac yet.")
        let own = ArtifactList(root: "/p", scope: .project, sessionsScanned: 2)
        #expect(ArtifactRules.nothingFound(own).contains("by its own sessions"))
        #expect(!ArtifactRules.nothingFound(own).contains("every project"))
    }

    @Test func aPageEmptiedByTheRuleSaysSo() {
        let list = ArtifactList(root: "/p", sessionsScanned: 3)
        #expect(ArtifactRules.nothingButFiles(list, hidden: 12)
            == "No prototypes in /p — 12 files of prose or source, which is what Files is for.")
        #expect(ArtifactRules.summarize(list, shown: 0, kind: .made, hidden: 1)
            == "No prototypes in /p — 1 file of prose or source, which is what Files is for.")
    }

    @Test func changeSummaryAndMeta() {
        #expect(ArtifactRules.changeSummary(artifact("a.html", writes: 2, edits: 5)) == "2 writes · 5 edits")
        #expect(ArtifactRules.changeSummary(artifact("a.html", writes: 1, edits: 0)) == "1 write")
        #expect(ArtifactRules.changeSummary(artifact("a.html", writes: 0, edits: 1)) == "1 edit")
        let now = 10 * 3_600_000.0
        let here = artifact("index.html", lastAt: now - 3 * 3_600_000, bytes: 2048)
        #expect(ArtifactRules.detailMeta(here, now: now) == "Web page · in the project root · last 3h ago · 2.0 KB")
        let gone = artifact("shots/a.png", lastAt: now - 120_000, bytes: nil)
        #expect(ArtifactRules.detailMeta(gone, now: now) == "Image · shots · last 2m ago · no longer on disk")
    }

    @Test func failuresInPlainWords() {
        #expect(ArtifactRules.readFailure("Error invoking remote method 'artifacts:list': boom") == "boom")
        #expect(ArtifactRules.readFailure("plain") == "plain")
        #expect(ArtifactRules.overdue("Reading this project’s history", seconds: 20)
            == "Reading this project’s history did not answer within 20 seconds.")
        #expect(ArtifactRules.overdue("Reading", seconds: 1) == "Reading did not answer within 1 second.")
        #expect(ArtifactRules.overdue("Reading", seconds: 2.5) == "Reading did not answer within 2.5 seconds.")
    }
}

@Suite("Artifacts — time windows and sizes")
struct ArtifactsTimeTests {
    let minute = 60_000.0
    let posix = Locale(identifier: "en_US")
    let utc = TimeZone(identifier: "UTC")!

    @Test func relativeLabels() {
        let now = 100 * 86_400_000.0
        #expect(ArtifactRules.relativeTime(0, now: now) == "")
        #expect(ArtifactRules.relativeTime(now - 30_000, now: now) == "just now")
        #expect(ArtifactRules.relativeTime(now + 5 * minute, now: now) == "just now")
        #expect(ArtifactRules.relativeTime(now - 5 * minute, now: now) == "5m ago")
        #expect(ArtifactRules.relativeTime(now - 59.6 * minute, now: now) == "60m ago")
        #expect(ArtifactRules.relativeTime(now - 90 * minute, now: now) == "2h ago")
        #expect(ArtifactRules.relativeTime(now - 23 * 60 * minute, now: now) == "23h ago")
        #expect(ArtifactRules.relativeTime(now - 4 * 1440 * minute, now: now) == "4d ago")
        #expect(ArtifactRules.relativeTime(now - 29 * 1440 * minute, now: now) == "29d ago")
    }

    @Test func pastAMonthItIsADate() {
        // 2026-08-21 12:00 UTC, read from 2026-10-05.
        let at = 1_787_313_600_000.0
        let now = 1_791_201_600_000.0
        #expect(ArtifactRules.relativeTime(at, now: now, locale: posix, timeZone: utc) == "Aug 21, 2026")
    }

    @Test func sessionChips() {
        let now = 1000 * minute
        let named = ArtifactSession(sessionId: "conv-1", at: now - 3 * 60 * minute, files: 4)
        #expect(ArtifactRules.sessionChipLabel(named, names: ["conv-1": "Rewrite the hero"], now: now) == "Rewrite the hero · 4 files")
        let unnamed = ArtifactSession(sessionId: "conv-2", at: now - 3 * 60 * minute, files: 1)
        #expect(ArtifactRules.sessionChipLabel(unnamed, names: [:], now: now) == "3h ago · 1 file")
    }

    @Test func sizes() {
        #expect(ArtifactRules.formatBytes(0) == "0 B")
        #expect(ArtifactRules.formatBytes(1023) == "1023 B")
        #expect(ArtifactRules.formatBytes(1024) == "1.0 KB")
        #expect(ArtifactRules.formatBytes(41 * 1024 + 512) == "41.5 KB")
        #expect(ArtifactRules.formatBytes(8_600_000) == "8.2 MB")
    }
}

@Suite("Artifacts — the History diff")
struct ArtifactsDiffTests {
    @Test func linesSplitLikeTheWeb() {
        #expect(ArtifactsDiff.splitLines("") == [])
        #expect(ArtifactsDiff.splitLines("a\nb\n") == ["a", "b"])
        #expect(ArtifactsDiff.splitLines("a\n\nb") == ["a", "", "b"])
        #expect(ArtifactsDiff.splitLines("a\r\nb") == ["a\r", "b"])
    }

    @Test func anEditLinesUp() {
        let (lines, truncated) = ArtifactsDiff.diff(before: "one\ntwo\nthree\nfour\n", after: "one\n2\nthree\nfour\nfive\n")
        #expect(!truncated)
        #expect(lines == [
            .init(.same, "one"), .init(.del, "two"), .init(.add, "2"),
            .init(.same, "three"), .init(.same, "four"), .init(.add, "five"),
        ])
    }

    @Test func pureInsertAndDelete() {
        #expect(ArtifactsDiff.diff(before: "", after: "x\ny").lines == [.init(.add, "x"), .init(.add, "y")])
        #expect(ArtifactsDiff.diff(before: "x\ny", after: "").lines == [.init(.del, "x"), .init(.del, "y")])
        #expect(ArtifactsDiff.diff(before: "same", after: "same").lines == [.init(.same, "same")])
    }

    @Test func tooLongIsOneBlockOutAndOneIn() {
        let big = (0..<601).map(String.init).joined(separator: "\n")
        let (lines, truncated) = ArtifactsDiff.diff(before: big, after: "x")
        #expect(truncated)
        #expect(lines.count == 601)
        #expect(lines.first == .init(.del, "0"))
        #expect(lines.last == .init(.add, "x"))
        guard case .edit(let shown, let more) = ArtifactsDiff.body(for: ArtifactChange(at: 1, action: .edit, before: big, after: "x")) else {
            Issue.record("expected an edit body"); return
        }
        #expect(shown.count == ArtifactsDiff.maxRenderedLines)
        #expect(more == "Too long to line up — shown as one block removed and one added.")
    }

    @Test func aWriteIsItsTextCapped() {
        let text = (1...302).map { "line \($0)" }.joined(separator: "\n") + "\n"
        guard case .write(let shown, let more) = ArtifactsDiff.body(for: ArtifactChange(at: 1, action: .write, after: text)) else {
            Issue.record("expected a write body"); return
        }
        #expect(shown.split(separator: "\n").count == 300)
        #expect(more == "2 more lines not shown.")
        guard case .write(_, let none) = ArtifactsDiff.body(for: ArtifactChange(at: 1, action: .write, after: "<p>hi</p>")) else {
            Issue.record("expected a write body"); return
        }
        #expect(none == nil)
    }
}

@Suite("Artifacts — where and which project")
struct ArtifactsPlaceTests {
    @Test func theFileStaysInsideTheProject() {
        #expect(ArtifactRules.fileURL(root: "/Users/me/deck", relPath: "site/index.html")?.path == "/Users/me/deck/site/index.html")
        #expect(ArtifactRules.fileURL(root: "/Users/me/deck/", relPath: "a b#c.png")?.path == "/Users/me/deck/a b#c.png")
        #expect(ArtifactRules.fileURL(root: "/Users/me/deck", relPath: "../secret.html") == nil)
        #expect(ArtifactRules.fileURL(root: "/Users/me/deck", relPath: "a/../../deck2/x.html") == nil)
        #expect(ArtifactRules.fileURL(root: "/Users/me/deck", relPath: "/etc/hosts") == nil)
        #expect(ArtifactRules.fileURL(root: "relative", relPath: "x.html") == nil)
        #expect(ArtifactRules.fileURL(root: "/Users/me/deck", relPath: "") == nil)
    }

    let projects = [
        SidebarProject(id: "/Users/me/alpha", title: "alpha", expanded: true, sessions: []),
        SidebarProject(id: "other", title: "Other", expanded: false, sessions: []),
        SidebarProject(id: "/Users/me/beta", title: "beta", expanded: false, sessions: []),
        SidebarProject(id: "machine:m1", title: "beta", expanded: false, sessions: []),
    ]

    @Test func thePageSaysWhichProject() {
        #expect(ArtifactRules.currentProject(pageProject: "/Users/me/beta", projects: projects) == "/Users/me/beta")
        // Even one that is not among the open projects: the page's word wins.
        #expect(ArtifactRules.currentProject(pageProject: "/x/gamma", projects: projects) == "/x/gamma")
    }

    @Test func theProjectIsReadOffTheSidebarState() {
        struct WithProject { var groups: [Int] = []; var project: String? }
        #expect(ArtifactRules.pageProject(in: WithProject(project: "/Users/me/beta")) == "/Users/me/beta")
        #expect(ArtifactRules.pageProject(in: WithProject(project: nil)) == nil)
        #expect(ArtifactRules.pageProject(in: WithProject(project: " ")) == nil)
        #expect(ArtifactRules.pageProject(in: SidebarState(groups: [], projects: [], selectedId: nil)) == nil)
        #expect(ArtifactRules.pageProject(in: nil) == nil)
    }

    @Test func withoutTheWordTheFirstOpenProject() {
        #expect(ArtifactRules.currentProject(pageProject: nil, projects: projects) == "/Users/me/alpha")
        #expect(ArtifactRules.currentProject(pageProject: "  ", projects: projects) == "/Users/me/alpha")
        let runsOnly = projects.filter { !ArtifactRules.isFolder($0.id) }
        #expect(ArtifactRules.currentProject(pageProject: nil, projects: runsOnly) == nil)
        #expect(ArtifactRules.currentProject(pageProject: nil, projects: []) == nil)
    }
}

@Suite("Artifacts — reading a page and remembering a scan")
struct ArtifactsReadAndCacheTests {
    @Test func whatTheFileReadSays() {
        #expect(ArtifactRules.describeRead(json(#"{"kind":"text","text":"<html></html>"}"#), bytes: 13) == .text("<html></html>"))
        #expect(ArtifactRules.describeRead(json(#"{"kind":"text","text":"  \n"}"#), bytes: 3) == .note("This file is empty."))
        #expect(ArtifactRules.describeRead(json(#"{"kind":"too-large","limit":2097152}"#), bytes: nil)
            == .note("Too big to preview here — over 2.0 MB. Open it in Files."))
        #expect(ArtifactRules.describeRead(json(#"{"kind":"binary"}"#), bytes: 2048)
            == .note("Not text (2.0 KB), so there is nothing to show inline."))
        #expect(ArtifactRules.describeRead(json(#"{"kind":"binary"}"#), bytes: nil)
            == .note("Not text, so there is nothing to show inline."))
        #expect(ArtifactRules.describeRead(json(#"{"kind":"weird"}"#), bytes: nil) == .error("That file could not be read."))
        #expect(ArtifactRules.describeRead(json("3"), bytes: nil) == .error("That file could not be read."))
    }

    @Test func aScanStaysFreshForTwoMinutes() {
        var cache = ArtifactsCache<Int>()
        let key = ArtifactsCache<Int>.key(root: "/p", scope: .all)
        #expect(key == "artifacts:list:/p|all")
        #expect(cache.recall(key, now: 0) == nil)
        cache.remember(key, 7, at: 1000)
        #expect(cache.recall(key, now: 1000)?.fresh == true)
        #expect(cache.recall(key, now: 1120)?.fresh == true)
        #expect(cache.recall(key, now: 1121)?.fresh == false)
        #expect(cache.recall(key, now: 5000)?.value == 7)
        #expect(cache.recall(key, now: 1000, freshFor: 0)?.fresh == false)
    }

    @Test func theOldestScanIsForgottenFirst() {
        var cache = ArtifactsCache<Int>()
        for i in 0..<(ArtifactsCache<Int>.maxEntries + 1) { cache.remember("k\(i)", i, at: 0) }
        #expect(cache.recall("k0", now: 0) == nil)
        #expect(cache.recall("k1", now: 0)?.value == 1)
        #expect(cache.recall("k\(ArtifactsCache<Int>.maxEntries)", now: 0) != nil)
    }
}
