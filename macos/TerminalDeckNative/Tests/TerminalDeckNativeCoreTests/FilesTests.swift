import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// The native Files page's rules, mirroring `FileTree.test.tsx`, `FileViewer.test.tsx`
/// and the Files page tests in `PanelView`.
@Suite("Files tree")
struct FilesTreeTests {
    func listing(_ names: [(String, Bool)], dir: String = "", defaultFile: String? = nil) -> DirListing {
        DirListing(relPath: dir, entries: names.map { FsEntry(name: $0.0, relPath: dir.isEmpty ? $0.0 : "\(dir)/\($0.0)", isDir: $0.1) },
                   defaultFile: defaultFile)
    }

    @Test func opensOncePerProjectOnlyFromTheRootAndOnlyWithNothingOpen() {
        #expect(FilesRules.shouldAutoOpen(autoSelect: true, dir: "", root: "/p", openedFor: nil, selected: nil))
        #expect(!FilesRules.shouldAutoOpen(autoSelect: true, dir: "src", root: "/p", openedFor: nil, selected: nil))
        #expect(!FilesRules.shouldAutoOpen(autoSelect: true, dir: "", root: "/p", openedFor: nil, selected: "a.ts"))
        #expect(!FilesRules.shouldAutoOpen(autoSelect: true, dir: "", root: "/p", openedFor: "/p", selected: nil))
        #expect(!FilesRules.shouldAutoOpen(autoSelect: false, dir: "", root: "/p", openedFor: nil, selected: nil))
    }

    @Test func isLoadingUntilListedAndEmptyOnlyWhenListedEmpty() {
        var tree = FileTreeState()
        #expect(tree.rootState == .loading)
        tree.loadStarted("")
        #expect(tree.rootState == .loading)
        tree.loaded("", listing([]))
        #expect(tree.rootState == .empty)
        tree.failed("", "Reading this folder did not answer within 10 seconds.")
        #expect(tree.rootState == .error("Reading this folder did not answer within 10 seconds."))
        var ready = FileTreeState()
        ready.loaded("", listing([("a.ts", false)]))
        ready.loadStarted("")
        #expect(ready.rootState == .ready(count: 1))
    }

    @Test func foldersOpenUnderneathAndTheKeyboardWalksTheRows() {
        var tree = FileTreeState()
        tree.loaded("", listing([("src", true), ("README.md", false)]))
        #expect(tree.focused == "src")
        let src = tree.rows[0].entry
        #expect(tree.toggle(src) == .load)
        tree.loadStarted("src")
        tree.loaded("src", listing([("a.ts", false)], dir: "src"))
        #expect(tree.rows.map(\.entry.relPath) == ["src", "src/a.ts", "README.md"])
        #expect(tree.rows[1].depth == 1)
        #expect(tree.toggle(src) == .collapse)
        #expect(tree.effect(of: .down) == .focus("src/a.ts"))
        tree.focus("src/a.ts")
        #expect(tree.effect(of: .left) == .focus("src"))
        tree.focus("src")
        #expect(tree.effect(of: .left) == .collapse("src"))
        tree.collapse("src")
        #expect(tree.toggle(src) == .expand)
        #expect(tree.effect(of: .right) == .toggle(src))
        #expect(tree.effect(of: .end) == .focus("README.md"))
        #expect(tree.effect(of: .home) == .focus("src"))
        #expect(tree.effect(of: .activate) == .activate(src))
        #expect(FileTreeState.parent(of: "src/a.ts") == "src" && FileTreeState.parent(of: "a.ts") == "")
    }

    @Test func aFailedFolderClosesAndSaysWhy() {
        var tree = FileTreeState()
        tree.loaded("", listing([("src", true)]))
        tree.loadStarted("src")
        tree.failed("src", "Permission denied")
        #expect(!tree.expanded.contains("src") && tree.errors["src"] == "Permission denied")
        let blocked = FsEntry(name: "out", relPath: "out", isDir: true, symlink: true, blocked: true)
        #expect(tree.toggle(blocked) == .none)
        #expect(FilesRules.rowTitle(blocked) == "out — link leaves the project, or loops")
    }

    @Test func thePageLayoutFollowsTheRoot() {
        #expect(FilesRules.layout(.loading) == .treeAndViewer)
        #expect(FilesRules.layout(.ready(count: 2)) == .treeAndViewer)
        #expect(FilesRules.layout(.empty) == .blank)
        #expect(FilesRules.layout(.error("x")) == .treeOnly)
        #expect(FilesRules.blankReason(root: "/p", showIgnored: false) == "Nothing in /p that your .gitignore does not exclude.")
        #expect(FilesRules.blankReason(root: "/p", showIgnored: true) == "Nothing at all in /p, ignored files included.")
    }

    @Test func readsTheEnginesAnswers() throws {
        let list = try #require(DirListing(json: ["relPath": "", "truncated": true, "defaultFile": "README.md", "entries": [
            ["name": "src", "relPath": "src", "kind": "dir", "symlink": false, "blocked": false],
            ["name": "README.md", "relPath": "README.md", "kind": "file", "symlink": false, "blocked": false],
            ["name": "bad"],
        ] as [Any]]))
        #expect(list.entries.map(\.isDir) == [true, false] && list.truncated && list.defaultFile == "README.md")
        #expect(FileRead(json: ["kind": "text", "relPath": "a", "text": "x", "bytes": 1, "lines": 1]) == .text(relPath: "a", text: "x", bytes: 1))
        #expect(FileRead(json: ["kind": "too-large", "relPath": "a", "bytes": 9, "limit": 5]) == .tooLarge(relPath: "a", bytes: 9, limit: 5))
        #expect(FileRead(json: ["kind": "nope"]) == nil)
    }
}

@Suite("Files viewer")
struct FilesViewerTests {
    func kinds(_ source: String, _ language: Language) -> [TokenKind: [String]] {
        var out: [TokenKind: [String]] = [:]
        for token in Highlighter.tokenize(source, language) { out[token.kind, default: []].append(token.text) }
        return out
    }

    @Test func everyLanguageGivesBackExactlyTheTextItWasGivenWithNoEmptyTokens() {
        let nasty = "\"unterminated\n'also\n/* never closed\n`tick\n#!\n@\n0x\n—ünïcödé\r\n"
        for language in [Language.js, .json, .css, .shell, .yaml, .markdown] {
            let tokens = Highlighter.tokenize(nasty, language)
            #expect(tokens.map(\.text).joined() == nasty)
            #expect(tokens.allSatisfy { !$0.text.isEmpty })
        }
    }

    @Test func findsCommentsStringsNumbersAndReservedWords() {
        let js = kinds("const a = 42 // note\nimport x from 'y'", .js)
        #expect(js[.keyword]?.contains("const") == true && js[.keyword]?.contains("import") == true)
        #expect(js[.number] == ["42"] && js[.string] == ["'y'"] && js[.comment] == ["// note"])
        #expect(kinds("colour=#fff\n", .shell)[.comment] == nil)
        #expect(kinds("echo hi # real comment\n", .shell)[.comment] == ["# real comment"])
        let apostrophe = kinds("// don't\nconst after = 1\n", .js)
        #expect(apostrophe[.string] == nil && apostrophe[.keyword]?.contains("const") == true)
        #expect(kinds("name: release\n- run: npm test\n", .yaml)[.meta] == ["name", "run"])
        let md = kinds("# Title\n\n```\ncode\n```\ntext\n", .markdown)
        #expect(md[.meta] == ["# Title\n"] && md[.string] == ["code\n"] && md[.plain]?.contains("text\n") == true)
        #expect(kinds("@media screen { .a { top: 0 } }", .css)[.keyword] == ["@media"])
        let plain = Highlighter.tokenize("foo bar baz qux quux\n", .js)
        #expect(plain.count == 1 && plain[0].kind == .plain)
    }

    @Test func knowsTheLanguagesAndLeavesTheRestUncoloured() {
        #expect(Highlighter.language(of: "src/a.tsx") == .js)
        #expect(Highlighter.language(of: "README.MD") == .markdown)
        #expect(Highlighter.language(of: "ci.yml") == .yaml)
        #expect(Highlighter.language(of: "main.rs") == nil)
        #expect(Highlighter.language(of: ".bashrc") == nil)
    }

    @Test func wordsTheFileAsAPersonReadsIt() {
        #expect(FilesRules.formatBytes(512) == "512 B")
        #expect(FilesRules.formatBytes(2048) == "2.0 KB")
        #expect(FilesRules.formatBytes(5 * 1024 * 1024) == "5.0 MB")
        #expect(FilesRules.viewerMeta(lines: 3, read: .text(relPath: "a", text: "x", bytes: 24)) == "3 lines · 24 B")
        #expect(FilesRules.viewerMeta(lines: nil, read: nil) == "")
        #expect(FilesRules.viewerMeta(lines: 1, read: .binary(relPath: "a", bytes: 9)) == "")
        #expect(FilesRules.binaryLine(bytes: 2048) == "Binary file — 2.0 KB. Nothing readable to show.")
        #expect(FilesRules.errorLine("gone") == "Could not open this file — gone")
        #expect(FilesRules.extensionOf("src/a.test.ts") == "ts" && FilesRules.extensionOf(".env") == "")
    }

    @Test func dropsTheLastNewlineAndCapsTheLines() {
        let doc = FilesRules.document("# Demo\n\nA demo project.\n")
        #expect(doc.source == "# Demo\n\nA demo project." && doc.count == 3 && doc.shown == 3)
        #expect(FilesRules.document("").count == 1)
        let long = (1...(FilesRules.maxViewLines + 5)).map(String.init).joined(separator: "\n")
        let capped = FilesRules.document(long)
        #expect(capped.count == FilesRules.maxViewLines + 5 && capped.shown == FilesRules.maxViewLines)
        #expect(capped.source.hasSuffix("\n\(FilesRules.maxViewLines)"))
        #expect(FilesRules.gutter(3) == "1\n2\n3")
        #expect(FilesRules.maxCachedBytes == 256 * 1024)
    }
}
