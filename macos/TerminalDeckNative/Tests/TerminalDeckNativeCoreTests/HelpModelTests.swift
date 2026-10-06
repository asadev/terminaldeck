import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Help (mirrors HelpPanel.test.tsx)")
struct HelpModelTests {
    let topics = [
        HelpTopic(id: "trouble-gh", section: "trouble", title: "GitHub says not signed in", blocks: [.text("Run `gh auth login` in {app}.")], keywords: ["auth"]),
        HelpTopic(id: "trouble-remote", section: "trouble", title: "Remote machine", blocks: [.bullets(["github remote is wrong"])]),
        HelpTopic(id: "start-1", section: "start", title: "Install", blocks: [.steps(["Open a project", "Start a session"])]),
    ]

    @Test func search() {
        #expect(Help.search("auth", in: topics).map(\.id).contains("trouble-gh"))
        #expect(Help.search("github remote", in: topics).map(\.id).contains("trouble-remote"))
        #expect(Help.search("github kangaroo", in: topics).isEmpty)
        #expect(Help.search("   ", in: topics).count == topics.count)
        #expect(Help.search("SESSION", in: topics).map(\.id) == ["start-1"], "case-insensitive, steps searched")
    }

    @Test func aboutMatches() {
        for q in ["a", "b", "u", "o", "ve", "auth", "path"] { #expect(!Help.matchesAbout(q), "\(q)") }
        for q in ["version", "electron", "chromium", "node", "build", "about", "v8", "ver"] { #expect(Help.matchesAbout(q), "\(q)") }
        #expect(Help.matchesAbout("build version"))
        #expect(!Help.matchesAbout("version kangaroo"))
        #expect(!Help.matchesAbout("   "))
    }

    @Test func fillsNameAndCode() {
        let runs = Help.fill("Run `gh auth login` in {app}.", appName: "Terminal Deck")
        #expect(runs.map(\.text) == ["Run ", "gh auth login", " in Terminal Deck."])
        #expect(runs.map(\.code) == [false, true, false])
        #expect(Help.resultLabel(1) == "1 result" && Help.resultLabel(3) == "3 results")
    }

    @Test func decodesThePagesContent() throws {
        let json = #"{"sections":[{"id":"start","label":"Getting started","hint":"From nothing."}],"topics":[{"id":"t","section":"start","title":"T","blocks":[{"kind":"code","code":"npm i"},{"kind":"note","text":"n"},{"kind":"steps","items":["a","b"]}]}]}"#
        let content = try JSONDecoder().decode(HelpContent.self, from: Data(json.utf8))
        #expect(content.sections.first?.label == "Getting started")
        #expect(content.topics.first?.blocks == [.code("npm i"), .note("n"), .steps(["a", "b"])])
    }

    @Test func aboutCard() throws {
        let info = try JSONDecoder().decode(AboutInfo.self, from: Data(#"{"name":"Terminal Deck","tagline":"t","version":"0.18.7","electron":"38","chrome":"140","node":"22","v8":"14","platform":"darwin","arch":"arm64","packaged":false}"#.utf8))
        #expect(info.rows.first! == ("Version", "0.18.7 (development build)"))
        #expect(info.copyText == "Terminal Deck 0.18.7 (dev)\nElectron 38 · Chromium 140 · Node 22\ndarwin arm64")
    }
}
