import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Command palette rules (mirrors CommandPalette.test.tsx)")
struct PaletteModelTests {
    @Test func listMovement() {
        #expect(Palette.nextIndex(4, count: 5, delta: 1, wrap: true) == 0)
        #expect(Palette.nextIndex(0, count: 5, delta: -1, wrap: true) == 4)
        #expect(Palette.nextIndex(0, count: 5, delta: 8, wrap: false) == 4)
        #expect(Palette.nextIndex(0, count: 5, delta: -8, wrap: false) == 0)
        #expect(Palette.nextIndex(4, count: 5, delta: -8, wrap: false) == 0)
        #expect(Palette.nextIndex(0, count: 40, delta: 8, wrap: false) == 8)
        #expect(Palette.nextIndex(20, count: 40, delta: -8, wrap: false) == 12)
        #expect(Palette.nextIndex(0, count: 0, delta: 1, wrap: true) == 0)
        #expect(Palette.nextIndex(0, count: 0, delta: -1, wrap: false) == 0)
        #expect(Palette.nextIndex(99, count: 5, delta: 1, wrap: true) == 0)
        #expect(Palette.nextIndex(-3, count: 5, delta: 0, wrap: false) == 0)
    }

    @Test func fileQueries() {
        #expect(Palette.parseFileQuery("index.ts:42") == ("index.ts", 42))
        #expect(Palette.parseFileQuery("index.ts") == ("index.ts", nil))
        #expect(Palette.parseFileQuery(":42") == (":42", nil))
        #expect(Palette.parseFileQuery("a:1:2") == ("a:1", 2))
        #expect(Palette.parseFileQuery("src:main") == ("src:main", nil))
        #expect(Palette.parseFileQuery("a.ts:0") == ("a.ts:0", nil))
        #expect(Palette.parseFileQuery("a.ts:99999999999999999999") == ("a.ts:99999999999999999999", nil))
    }

    @Test func modesFromThePrefix() {
        #expect(Palette.seed(mode: .files, projectRoot: "/p") == "")
        #expect(Palette.seed(mode: .files, projectRoot: nil) == ">")
        #expect(Palette.seed(mode: .sessions, projectRoot: "/p") == "?")
        #expect(Palette.mode(of: "?foo", projectRoot: "/p") == .sessions)
        #expect(Palette.mode(of: "?foo", projectRoot: nil) == .commands)
        #expect(Palette.mode(of: ">new", projectRoot: "/p") == .commands)
        #expect(Palette.mode(of: "app.ts", projectRoot: "/p") == .files)
        #expect(Palette.sigilLength("??x", sessionMode: true) == 2 && Palette.sigilLength(">x", sessionMode: false) == 1)
        #expect(Palette.term(of: "??deploy", projectRoot: "/p").text == "deploy" && Palette.sessionScope("??deploy") == "all")
        #expect(Palette.term(of: "app.ts:12", projectRoot: "/p") == ("app.ts", 12))
        #expect(Palette.label(.files) == "Quick open" && Palette.label(.commands) == "Command palette")
    }

    @Test func emptyMessages() {
        #expect(Palette.emptyMessage(mode: .sessions, term: "a", scope: "project") == "Type at least two characters. Quoted “phrases” and -exclusions work.")
        #expect(Palette.emptyMessage(mode: .sessions, term: "deploy", scope: "all") == "Nothing on this machine said “deploy”.")
        #expect(Palette.emptyMessage(mode: .sessions, term: "x", scope: "project", sessionsUnavailable: true) == "Past-session search is not connected to the main process.")
        #expect(Palette.emptyMessage(mode: .files, term: "", scope: "project", filesLoading: true) == "Reading project files…")
        #expect(Palette.emptyMessage(mode: .files, term: "zz", scope: "project") == "No matches for “zz”.")
        #expect(Palette.emptyMessage(mode: .commands, term: "", scope: "project") == "No commands available.")
    }

    @Test func recentsAndSnippets() {
        #expect(Palette.recentsFirst(["a", "b", "c"], recents: ["c", "gone"]) == ["c", "a", "b"])
        #expect(Palette.recentsFirst(["a"], recents: []) == ["a"])
        let snippet = SessionSnippet(text: "hello world", ranges: [.init(start: 6, length: 5), .init(start: 0, length: 0), .init(start: 99, length: 2)],
                                     truncatedStart: false, truncatedEnd: true)
        #expect(Palette.snippetRanges(snippet) == [MatchRange(start: 6, end: 11)])
        #expect(Palette.roleLabel("assistant") == "Reply" && Palette.roleLabel("user") == "You")
        #expect(Palette.relativeTime(1000, now: 1000 + 30_000) == "just now")
        #expect(Palette.relativeTime(1000, now: 1000 + 5 * 60_000) == "5m ago")
        #expect(Palette.relativeTime(1000, now: 1000 + 3 * 3_600_000) == "3h ago")
        #expect(Palette.relativeTime(0, now: 5) == "")
    }
}
