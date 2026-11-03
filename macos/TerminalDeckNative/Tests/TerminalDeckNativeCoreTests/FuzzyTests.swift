import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Fuzzy matcher (mirrors src/renderer/fuzzy.test.ts)")
struct FuzzyTests {
    func hits(_ text: String, _ query: String) -> String {
        guard let result = Fuzzy.match(text, query) else { return "<no match>" }
        let units = Array(text.utf16)
        return result.ranges.map { String(decoding: units[$0.start..<$0.end], as: UTF16.self) }.joined(separator: "|")
    }
    func score(_ text: String, _ query: String) -> Int { Fuzzy.match(text, query)?.score ?? Int.min }

    @Test func basics() {
        #expect(Fuzzy.match("readme", "readme")?.ranges == [MatchRange(start: 0, end: 6)])
        #expect(hits("CommandPalette", "cmplt") == "C|m|P|l|t")
        #expect(Fuzzy.match("abc", "abd") == nil)
        #expect(Fuzzy.match("abc", "cab") == nil)
        #expect(Fuzzy.match("ab", "abc") == nil)
        #expect(hits("café-menu.ts", "café") == "café")
        #expect(hits("src/components/CommandPalette.tsx", "cp") == "C|P")
        #expect(Fuzzy.match("app.css", "app")?.ranges == [MatchRange(start: 0, end: 3)])
    }

    @Test func scoring() {
        #expect(score("abc.txt", "abc") > score("a_b_c.txt", "abc"))
        #expect(score("abc", "abc") > score("a-b-c", "abc"))
        #expect(score("ab", "ab") > score("a_b", "ab"))
        #expect(score("axb", "ab") > score("axxxxb", "ab"))
        #expect(score("my-store.ts", "store") > score("restore.ts", "store"))
        #expect(score("index.ts", "index") > score("reindex.ts", "index"))
        #expect(score("parseValue", "value") > score("parsevalue", "value"))
        #expect(score("v2.sql", "2") > score("v12.sql", "2"))
        #expect(score("a-xb", "ab") > score("xa-b", "ab"))
        #expect(score("CommandPalette", "cp") > score("occupy", "cp"))
        #expect(Fuzzy.match("README.md", "readme") != nil)
        #expect(score("abc", "abc") - score("ABC", "abc") == Fuzzy.Scores.caseMatch * 3)
    }

    @Test func smartCaseAndTerms() {
        #expect(Fuzzy.match("palette.ts", "Palette") == nil)
        #expect(Fuzzy.match("CommandPalette.tsx", "Palette") != nil)
        #expect(Fuzzy.match("palette.ts", "Palette", smartCase: false) != nil)
        #expect(Fuzzy.match("Git: Show status", "git status") != nil)
        #expect(Fuzzy.match("Show status bar", "git status") == nil)
    }

    @Test func ranking() {
        let files = ["src/main/pty-manager.ts", "src/main/file-search.ts", "src/renderer/components/CommandPalette.tsx",
                     "src/renderer/components/CommandPalette.css", "src/renderer/components/TabBar.tsx", "src/renderer/fuzzy.ts",
                     "src/renderer/fuzzy.test.ts", "src/shared/types.ts", "package.json"]
        func order(_ q: String) -> [String] { Fuzzy.rank(files, q, path: true) { $0 }.map(\.item) }
        #expect(order("fuzzy.ts").first == "src/renderer/fuzzy.ts")
        #expect(order("cmdpal").first == "src/renderer/components/CommandPalette.tsx")
        #expect(order("zzzz").isEmpty)
        #expect(Fuzzy.rank(files, "s", limit: 3, path: true) { $0 }.count == 3)
        #expect(Fuzzy.rank(files, "", limit: 4, path: true) { $0 }.map(\.item) == Array(files.prefix(4)), "empty query keeps the order")
        let commands = ["New Session", "New Session in Folder", "Close Session"]
        #expect(Fuzzy.rank(commands, "ns") { $0 }.first?.item == "New Session")
    }

    @Test func segmentsAndClamping() {
        let segments = Fuzzy.segments("CommandPalette", [MatchRange(start: 0, end: 1), MatchRange(start: 7, end: 8)])
        #expect(segments.map(\.text) == ["C", "ommand", "P", "alette"])
        #expect(segments.map(\.matched) == [true, false, true, false])
        #expect(Fuzzy.clamp([MatchRange(start: 2, end: 6), MatchRange(start: 8, end: 9)], from: 4, to: 8) == [MatchRange(start: 0, end: 2)])
        #expect(Fuzzy.basenameStart("a/b/c.ts") == 4 && Fuzzy.basenameStart("c.ts") == 0)
    }
}
