import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Lane T — Hoot's rail panel and its chat (ChatView, ChatComposer, chat/attach, rail-panel).

@Suite struct ChatConversationTests {
    func message(_ id: String, _ role: ChatMessage.Role, _ text: String, at: Double = 1_000) -> ChatMessage {
        ChatMessage(id: id, role: role, text: text, at: at)
    }

    @Test func updatesDecodeOnlyWithAMessageList() {
        #expect(ChatUpdate.decode(["found": true]) == nil)
        let update = ChatUpdate.decode(["transcriptPath": "/t.jsonl", "found": true, "reset": true,
                                        "messages": [["id": "a", "role": "you", "text": "hi", "at": 5],
                                                     ["id": "b", "role": "robot", "text": "?"]],
                                        "unattributable": ["candidates": 2, "competing": 1]])
        #expect(update?.messages.map(\.id) == ["a"])
        #expect(update?.reset == true)
        #expect(update?.unattributable == ChatUnattributable(candidates: 2, competing: 1))
    }

    @Test func mergeReplacesByIdAndAppendsTheRest() {
        let merged = ChatRules.merge([message("a", .you, "one"), message("b", .agent, "two")],
                                     [message("b", .agent, "two, longer"), message("c", .you, "three")])
        #expect(merged.map(\.text) == ["one", "two, longer", "three"])
    }

    @Test func echoesSettleOnTheSameWordsOnly() {
        let echo = PendingEcho(id: "e1", text: "fix  the\nbug", at: 10_000)
        #expect(ChatRules.settle([echo], against: [message("a", .agent, "fix the bug", at: 10_000)]) == [echo])
        #expect(ChatRules.settle([echo], against: [message("a", .you, "please fix the bug now", at: 9_000)]).isEmpty)
        // Older than the slack: an earlier turn with the same words is not this send.
        #expect(ChatRules.settle([echo], against: [message("a", .you, "fix the bug", at: 4_000)]) == [echo])
        #expect(ChatRules.echoNote(waitedMs: 1_000) == "Sending…")
        #expect(ChatRules.echoNote(waitedMs: 12_000) == "Sent — the agent has not written it down yet")
    }

    @Test func dayBreaksOnlyAtANewDay() {
        let utc = TimeZone(identifier: "UTC")!
        let en = Locale(identifier: "en_GB")
        let monday = 1_759_744_800_000.0 // 2025-10-06 10:00 UTC
        #expect(ChatRules.dayBreak(monday, previous: 0, locale: en, timeZone: utc) == "Monday 6 October")
        #expect(ChatRules.dayBreak(monday + 3_600_000, previous: monday, locale: en, timeZone: utc) == nil)
        #expect(ChatRules.dayBreak(0, previous: 0) == nil)
        #expect(ChatRules.time(monday, locale: en, timeZone: utc) == "10:00")
        #expect(ChatRules.time(0) == "")
    }

    @Test func drawnMemoryKeepsTheLastEight() {
        var memory = ChatDrawnMemory()
        for i in 0..<9 { memory.remember("k\(i)", [message("m\(i)", .you, "x")]) }
        #expect(memory.recall("k0").isEmpty)
        #expect(memory.recall("k8").map(\.id) == ["m8"])
        memory.remember("", [message("z", .you, "x")])
        #expect(memory.recall("").isEmpty)
    }

    @Test func emptyStatesFollowThePagesOrder() {
        func state(shell: Bool = false, messages: Int = 0, scoped: Bool = true, target: Bool = false,
                   lookup: ChatLookup = .loading, key: String = "", found: Bool? = nil, odd: Bool = false) -> ChatEmptyState? {
            ChatEmptyState.of(shell: shell, wired: true, messages: messages, scoped: scoped, hasTarget: target,
                              lookup: lookup, key: key, found: found, unattributable: odd)
        }
        #expect(state(shell: true, messages: 3) == .shell)
        #expect(state(messages: 1) == nil)
        #expect(state() == .loading)
        #expect(state(lookup: .ambiguous(candidates: 2, competing: 1)) == .ambiguous)
        #expect(state(lookup: .none) == .noSessionTranscript)
        #expect(state(scoped: false) == .noProject)
        #expect(state(scoped: false, key: "/p") == .loading)
        #expect(state(scoped: false, key: "/p", found: false) == .noTranscript)
        #expect(state(scoped: false, key: "/p", found: true) == .silent)
        #expect(state(target: true, key: "/t", found: true, odd: true) == .ambiguous)
        #expect(ChatEmptyState.silent.detail(canType: true).hasSuffix("Type below to start it."))
        #expect(ChatEmptyState.noTranscript.detail(canType: false).hasSuffix("Send a first message in the terminal and it will appear here."))
    }

    @Test func folderSessionsNameTheLiveOne() {
        func info(_ id: String, exit: Int? = nil, created: Double?) -> TerminalSessionInfo {
            TerminalSessionInfo.decode(["id": id, "cwd": "/p", "title": id, "provider": "claude",
                                        "exitCode": exit as Any, "createdAt": created as Any])!
        }
        let sessions = [info("a", created: 300), info("b", exit: 0, created: 100), info("c", created: 200)]
        #expect(ChatFolder.liveSessionId(sessions, provided: nil) == nil)
        #expect(ChatFolder.liveSessionId([sessions[0], sessions[1]], provided: nil) == "a")
        #expect(ChatFolder.liveSessionId(sessions, provided: "x") == "x")
        #expect(ChatFolder.exited(sessions, id: "b"))
        #expect(ChatFolder.siblingStarts(sessions, own: 300) == [100, 200])
    }
}

@Suite struct ChatMarkdownTests {
    @Test func codeIsFoldedUnderItsLabel() {
        let blocks = ChatMarkdown.parse("Here:\n\n```swift\nlet a = 1\nlet b = 2\n```\nafter")
        #expect(blocks == [.paragraph("Here:"), .code(language: "swift", text: "let a = 1\nlet b = 2"), .paragraph("after")])
        #expect(ChatMarkdown.codeLabel(language: "swift", text: "let a = 1\nlet b = 2") == "swift · 2 lines")
        #expect(ChatMarkdown.codeLabel(language: nil, text: "x") == "code · 1 line")
        #expect(ChatMarkdown.parse("```\nnever closed") == [.code(language: nil, text: "never closed")])
    }

    @Test func headingsRulesQuotesAndParagraphs() {
        #expect(ChatMarkdown.parse("# Title #\nsoft\nbreak") == [.heading(level: 1, text: "Title"), .paragraph("soft break")])
        #expect(ChatMarkdown.parse("Setext\n---") == [.heading(level: 2, text: "Setext")])
        #expect(ChatMarkdown.parse("a\n\n***\n\nb") == [.paragraph("a"), .rule, .paragraph("b")])
        #expect(ChatMarkdown.parse("> quoted\nlazy\n\nout") == [.quote([.paragraph("quoted lazy")]), .paragraph("out")])
        #expect(ChatMarkdown.parse("hard  \nbreak") == [.paragraph("hard\nbreak")])
        #expect(ChatMarkdown.parse("#hashtag") == [.paragraph("#hashtag")])
    }

    @Test func listsNestAndNumber() {
        let blocks = ChatMarkdown.parse("3. three\n4. four\n   - inner\n\n- other")
        #expect(blocks == [
            .list(ordered: true, start: 3, items: [[.paragraph("three")],
                                                   [.paragraph("four"), .list(ordered: false, start: 1, items: [[.paragraph("inner")]])]]),
            .list(ordered: false, start: 1, items: [[.paragraph("other")]]),
        ])
    }

    @Test func tablesNeedTheirDelimiterRow() {
        #expect(ChatMarkdown.parse("| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 |") ==
                [.table(header: ["a", "b"], rows: [["1", "2"], ["3", ""]])])
        #expect(ChatMarkdown.parse("a | b\nnot a table") == [.paragraph("a | b not a table")])
    }

    @Test func imagesBecomeTheirWords() {
        #expect(ChatMarkdown.inlineSource("see ![chart](https://x/y.png) and ![](z.png)") == "see [chart](https://x/y.png) and [image](z.png)")
        #expect(ChatMarkdown.inlineSource("plain") == "plain")
    }
}

@Suite struct ChatAttachTests {
    @Test func mentionsAndPayloadsMatchThePage() {
        let file = ChatAttachment(path: "/p/a.swift", relPath: "a.swift", kind: .file, outside: false)
        let folder = ChatAttachment(path: "/p/src", relPath: "src", kind: .folder, outside: false)
        #expect(ChatAttach.compose([file, folder], typed: "  look  ") == "@\"/p/a.swift\" @\"/p/src/\" look")
        #expect(ChatAttach.compose([], typed: " hi ") == "hi")
        #expect(ChatAttach.terminalWrites("@\"/a\" x") == ["@\"/a\" x ", "\r"])
        #expect(ChatAttach.terminalWrites("plain") == ["plain", "\r"])
        #expect(ChatAttach.append("half", "typed") == "half typed")
        #expect(ChatAttach.append("half ", " typed ") == "half typed")
        #expect(ChatAttach.append("", "x") == "x")
    }

    @Test func addingFollowsTheRules() {
        var list: [ChatAttachment] = []
        let first = ChatAttach.add(list, root: "/p/", picks: [ChatPick(path: "/p/img.PNG", isDirectory: false),
                                                              ChatPick(path: "/elsewhere/dir", isDirectory: true),
                                                              ChatPick(path: "rel/x", isDirectory: false)], scope: .anywhere)
        list = first.attachments
        #expect(list.map(\.relPath) == ["img.PNG", "/elsewhere/dir"])
        #expect(list.map(\.kind) == [.image, .folder])
        #expect(list[1].outside)
        #expect(first.notice == ChatAttach.text(.notAbsolute))
        #expect(ChatAttach.add(list, root: "/p", path: "/p/img.PNG/", isDirectory: false) == .refused(.duplicate))
        #expect(ChatAttach.add(list, root: "/p", path: "/q/x", isDirectory: false) == .refused(.outsideRoot))
        let caution = ChatAttach.add([], root: "/p", picks: [ChatPick(path: "/q", isDirectory: true)], scope: .anywhere)
        #expect(caution.notice == ChatAttach.outsideFolderCaution)
        #expect(ChatAttach.remove(list, path: "/p/img.PNG").count == 1)
        #expect(ChatAttach.insideRoot("C:\\Work", "c:/work/a.txt"))
        #expect(ChatAttach.mention(ChatAttachment(path: "C:\\Work\\src", relPath: "", kind: .folder, outside: true)) == "@\"C:\\Work\\src\\\"")
    }

    @Test func theBoundaryDecidesWhatComesIn() {
        let boundary = ChatAttachBoundary.decode(["confined": true, "folder": "/sandbox", "projects": ["/p", 3]])
        #expect(boundary.projects == ["/p"])
        let split = boundary.split([ChatPick(path: "/p/a", isDirectory: false), ChatPick(path: "/etc/x", isDirectory: false)])
        #expect(split.allowed.map(\.path) == ["/p/a"])
        #expect(split.refused.map(\.path) == ["/etc/x"])
        #expect(boundary.browseStart(root: "/home") == "/sandbox")
        #expect(ChatAttachBoundary.decode(nil).browseStart(root: "/home") == "/home")
        let brought = ChatOutside.broughtIn(["brought": [["from": "/etc/x", "path": "/sandbox/x"]], "refused": 1],
                                            picks: [ChatPick(path: "/etc/x", isDirectory: false)])
        #expect(brought.picks == [ChatPick(path: "/sandbox/x", isDirectory: false)])
        #expect(ChatOutside.refusal(brought.refused) == "One file did not come in.")
        #expect(ChatOutside.refusal(3) == "3 files did not come in.")
        #expect(ChatOutside.pasted(["ok": false, "detail": "disk full"]) == .failed("That image could not be saved: disk full"))
        #expect(ChatOutside.pasted(["ok": false, "reason": "nothing"]) == .nothing)
    }

    @Test func menuWordsPerMode() {
        #expect(ChatAttachMenu.items(pathMode: false).map(\.label) == ["Add files", "Add folder", "Add an image"])
        #expect(ChatAttachMenu.items(pathMode: true).count == 2)
        #expect(ChatComposerText.placeholder(idle: true, shell: true) == "Open a session to write to it")
        #expect(ChatComposerText.label(shell: false) == "Message the agent")
    }
}

@Suite struct RailPanelTests {
    @Test func thePanelShowsForTheDrivenTabInFront() {
        let drive = DriveNow(state: .agent, tabId: "t1", step: "", url: "https://example.com/a")
        #expect(RailPanelRules.state(drive: drive, frontTab: "t1", folded: false, touring: false) == .panel)
        #expect(RailPanelRules.state(drive: drive, frontTab: "t1", folded: true, touring: false) == .folded)
        #expect(RailPanelRules.state(drive: drive, frontTab: "t2", folded: false, touring: false) == .away)
        #expect(RailPanelRules.state(drive: drive, frontTab: "t1", folded: false, touring: true) == .away)
        let idle = DriveNow(state: .idle, tabId: "t1", step: "", url: "")
        #expect(RailPanelRules.state(drive: idle, frontTab: "t1", folded: false, touring: false) == .away)
    }

    @Test func bindingAndSendingFollowThePage() {
        let bindings = BrowserBindings.read(["sessions": [["sessionId": "s1", "machineId": "m1",
                                                           "windows": [["n": 1, "browserTabId": "t1"]]]]])
        #expect(RailPanelRules.boundSession(bindings, tabId: "t1") == BrowserDriverSession(sessionId: "s1", machineId: "m1"))
        #expect(RailPanelRules.boundSession(bindings, tabId: "t9") == nil)
        #expect(RailPanelRules.payload("  go  ", submit: true) == "go\r")
        #expect(RailPanelRules.payload("   ", submit: true) == "")
        #expect(RailPanelRules.label(name: "") == "This page’s session")
        #expect(RailPanelRules.elsewhere(name: "Fixer", machine: nil).hasPrefix("Fixer runs on another machine."))
    }
}
