import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Browser address field")
struct BrowserAddressTests {
    func url(_ input: String) -> String? {
        if case .url(let url) = BrowserAddress.resolve(input) { return url.absoluteString }
        return nil
    }

    func search(_ input: String) -> String? {
        if case .search(let url, _) = BrowserAddress.resolve(input) { return url.absoluteString }
        return nil
    }

    @Test func emptyAndBlank() {
        #expect(BrowserAddress.resolve("") == .empty)
        #expect(BrowserAddress.resolve("   \n ") == .empty)
        #expect(BrowserAddress.resolve("  ").target == nil)
    }

    @Test func devServersOpenWithoutAScheme() {
        // `localhost:3000` parses as scheme "localhost" — the case the rules exist for.
        #expect(url("localhost:3000") == "http://localhost:3000/")
        #expect(url("localhost:5173/app?x=1") == "http://localhost:5173/app?x=1")
        #expect(url("localhost") == "http://localhost/")
        #expect(url("127.0.0.1:8080") == "http://127.0.0.1:8080/")
        #expect(url("0.0.0.0:4000") == "http://0.0.0.0:4000/")
        #expect(url("[::1]:3000") != nil)
        #expect(url("myapp.local:8080") == "http://myapp.local:8080/")
    }

    @Test func fullAndBareAddresses() {
        #expect(url("https://example.com") == "https://example.com/")
        #expect(url("HTTP://Example.COM/Path") == "http://example.com/Path")
        #expect(url("example.com") == "http://example.com/")
        #expect(url("docs.example.co.uk/a/b#c") == "http://docs.example.co.uk/a/b#c")
        #expect(url("example.com.") == "http://example.com./")
        #expect(url("//example.com/x") == "http://example.com/x")
    }

    @Test func searchesGoToTheWebBrowsersEngine() {
        #expect(search("cats") == "https://duckduckgo.com/?q=cats")
        #expect(search("how do I center a div") == "https://duckduckgo.com/?q=how%20do%20I%20center%20a%20div")
        #expect(search("1.5") == "https://duckduckgo.com/?q=1.5")
        #expect(search("v2.0") == "https://duckduckgo.com/?q=v2.0")
        #expect(search("a..b") != nil)
        #expect(search("c++ & rust?") == "https://duckduckgo.com/?q=c%2B%2B%20%26%20rust%3F")
        if case .search(_, let query) = BrowserAddress.resolve("  what is swift  ") {
            #expect(query == "what is swift", "the query is shown back untouched, not encoded")
        } else {
            Issue.record("expected a search")
        }
    }

    @Test func otherSchemesAreNeverOpened() {
        #expect(search("javascript:alert(1)") == "https://duckduckgo.com/?q=javascript%3Aalert(1)")
        #expect(search("mailto:someone@example.com") != nil)
        #expect(search("file:///etc/passwd") != nil)
        #expect(search("http://") != nil, "a scheme with no host is text")
    }

    @Test func searchTemplateWithoutPlaceholderAppends() {
        #expect(BrowserSearch.url(for: "a b", template: "https://search.test/?q=")?.absoluteString
                == "https://search.test/?q=a%20b")
        #expect(BrowserSearch.encodeURIComponent("A-z_0.!~*'()") == "A-z_0.!~*'()")
        #expect(BrowserSearch.encodeURIComponent("é/?") == "%C3%A9%2F%3F")
    }
}

@Suite("Browser tabs")
struct BrowserTabsTests {
    @Test func persistenceRoundTrip() {
        var list = BrowserTabList()
        list.insert(BrowserTabRecord(id: "a", url: "http://localhost:3000/", title: "App"))
        list.insert(BrowserTabRecord(id: "b", url: "", title: ""))
        list.insert(BrowserTabRecord(id: "c", url: "https://example.com/", title: "Example",
                                     profile: "work", isolated: true))
        list.select("b")

        let restored = BrowserTabsStore.decode(BrowserTabsStore.encode(list))
        #expect(restored == list)
        #expect(restored.tabs.map(\.id) == ["a", "b", "c"])
        #expect(restored.selectedID == "b")
        #expect(restored.record("c")?.profile == "work")
        #expect(restored.record("c")?.isolated == true)
        #expect(restored.record("a")?.isolated == false)
    }

    @Test func decodingIsForgiving() {
        #expect(BrowserTabsStore.decode(nil).tabs.isEmpty)
        #expect(BrowserTabsStore.decode(Data("not json".utf8)).tabs.isEmpty)
        let json = #"""
        {"version":1,"selected":"gone","tabs":[
          {"id":"x","url":"javascript:alert(1)","title":"bad scheme"},
          {"url":"https://no-id.test/"},
          {"id":"y","url":"https://ok.test/","title":"OK"},
          {"id":"y","url":"https://dupe.test/"},
          {"id":"z","url":"","title":"Start"}
        ]}
        """#
        let list = BrowserTabsStore.decode(Data(json.utf8))
        #expect(list.tabs.map(\.id) == ["y", "z"])
        #expect(list.record("y")?.url == "https://ok.test/")
        #expect(list.selectedID == "y", "a missing selection falls back to the first tab")
    }

    @Test func insertCloseMove() {
        var list = BrowserTabList()
        list.insert(BrowserTabRecord(id: "a"))
        list.insert(BrowserTabRecord(id: "b"))
        list.insert(BrowserTabRecord(id: "c"))
        list.select("a")
        list.insert(BrowserTabRecord(id: "n"), after: "a", select: false)
        #expect(list.tabs.map(\.id) == ["a", "n", "b", "c"])
        #expect(list.selectedID == "a")

        list.move("c", to: 0)
        #expect(list.tabs.map(\.id) == ["c", "a", "n", "b"])
        list.move("c", by: 1)
        #expect(list.tabs.map(\.id) == ["a", "c", "n", "b"])
        list.move("b", by: 5)
        #expect(list.tabs.map(\.id) == ["a", "c", "n", "b"], "a move past the end stays at the end")

        list.select("n")
        list.close("n")
        #expect(list.selectedID == "b", "closing the chosen tab chooses its right-hand neighbour")
        list.close("b")
        #expect(list.selectedID == "c", "…else its left")
        list.close("a")
        list.close("c")
        #expect(list.selectedID == nil)
        #expect(list.tabs.isEmpty)
    }

    @Test func updateAndNeighbour() {
        var list = BrowserTabList(tabs: [BrowserTabRecord(id: "a"), BrowserTabRecord(id: "b")], selectedID: "b")
        list.update("a", url: "https://x.test/", title: "X", profile: "p", isolated: true)
        #expect(list.record("a") == BrowserTabRecord(id: "a", url: "https://x.test/", title: "X", profile: "p", isolated: true))
        #expect(list.neighbour(1) == "a", "wraps round")
        #expect(list.neighbour(-1) == "a")
    }
}

@Suite("Browser downloads")
struct BrowserDownloadNamingTests {
    @Test func namesAreMadeSafe() {
        #expect(BrowserDownloadNaming.name("report.pdf") == "report.pdf")
        #expect(BrowserDownloadNaming.name("../../etc/passwd") == "etc passwd")
        #expect(BrowserDownloadNaming.name("a:b*c?\"<>|.txt") == "abc.txt")
        #expect(BrowserDownloadNaming.name(".hidden") == "hidden")
        #expect(BrowserDownloadNaming.name("name. . ") == "name")
        #expect(BrowserDownloadNaming.name("\u{0}evil\n\tname.txt") == "evilname.txt")
        #expect(BrowserDownloadNaming.name("") == "download")
        #expect(BrowserDownloadNaming.name("...") == "download")
        #expect(BrowserDownloadNaming.name(String(repeating: "x", count: 200)).count == 120)
    }

    @Test func freeNamesNeverOverwrite() {
        let onDisk: Set<String> = ["/d/report.pdf", "/d/report (2).pdf"]
        let path = BrowserDownloadNaming.freePath(directory: "/d", suggested: "report.pdf",
                                                  exists: { onDisk.contains($0) })
        #expect(path == "/d/report (3).pdf")

        let running = BrowserDownloadNaming.freePath(directory: "/d/", suggested: "a.zip",
                                                     exists: { _ in false }, taken: ["/d/a.zip"])
        #expect(running == "/d/a (2).zip", "a download still running holds its name")

        #expect(BrowserDownloadNaming.freePath(directory: "/d", suggested: "README",
                                               exists: { $0 == "/d/README" }) == "/d/README (2)")
        #expect(BrowserDownloadNaming.freePath(directory: "/d", suggested: "x.tar.gz",
                                               exists: { $0 == "/d/x.tar.gz" }) == "/d/x.tar (2).gz")
        let full = BrowserDownloadNaming.freePath(directory: "/d", suggested: "f.txt", exists: { _ in true },
                                                  now: Date(timeIntervalSince1970: 1))
        #expect(full == "/d/f (1000).txt", "after 100 names, a timestamp")
    }
}

@Suite("Browser extras")
struct BrowserExtrasTests {
    @Test func zoomSteps() {
        #expect(BrowserZoom.step(1, by: 1) == 1.1)
        #expect(BrowserZoom.step(1, by: -1) == 0.9)
        #expect(BrowserZoom.step(0.5, by: -1) == 0.5)
        #expect(BrowserZoom.step(2, by: 1) == 2)
        #expect(BrowserZoom.step(1.3, by: 1) == 1.5, "steps from the nearest step")
        #expect(BrowserZoom.percent(0.67) == "67%")
    }

    @Test func screenshotFileName() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 14, minute: 22, second: 3))!
        let zone = TimeZone(identifier: "UTC")!
        #expect(BrowserShot.fileName(url: URL(string: "http://localhost:3000/x"), now: date, timeZone: zone)
                == "localhost-3000-20261005-142203.png")
        #expect(BrowserShot.fileName(url: URL(string: "https://example.com/"), now: date, timeZone: zone)
                == "example.com-20261005-142203.png")
        #expect(BrowserShot.fileName(url: nil, now: date, timeZone: zone) == "page-20261005-142203.png")
    }

    @Test func theLineASessionReceives() {
        let line = BrowserShot.compose(instruction: "look\nhere", path: "/Users/me/Pictures/Terminal Deck/a.png",
                                       url: URL(string: "http://localhost:3000/"), title: "My\tApp",
                                       width: 1280, height: 800)
        #expect(line == #"look here [browser screenshot of http://localhost:3000/ ("My App"): /Users/me/Pictures/Terminal Deck/a.png (1280 x 800)]"#)
        let bare = BrowserShot.compose(instruction: "  ", path: "/p.png", url: nil, title: "", width: 1, height: 2)
        #expect(bare == "[browser screenshot: /p.png (1 x 2)]")
        #expect(BrowserText.oneLine("a\u{1b}[2Jb\u{2028}c") == "a [2Jb c")
    }

    @Test func terminalWritesSubmitSeparately() {
        #expect(BrowserTerminalSend.writes("hello") == ["hello", "\r"])
        #expect(BrowserTerminalSend.writes("see @file") == ["see @file ", "\r"])
    }

    @Test func devPortsRows() {
        let value: [Any] = [
            ["port": 5173, "process": "node", "guessed": false, "ours": false],
            ["port": 3000, "process": "", "guessed": true, "ours": false],
            ["port": 4000, "process": "Terminal Deck", "guessed": false, "ours": true],
            ["port": "8080", "process": "python3"],
            ["port": 0], ["process": "no port"], "junk",
        ]
        let ports = BrowserDevPort.read(value)
        #expect(ports.map(\.port) == [4000, 5173, 8080, 3000], "named first, then by number")
        #expect(ports.first { $0.port == 4000 }?.ours == true)
        #expect(ports.first { $0.port == 5173 }?.summary == "5173 node")
        #expect(ports.first { $0.port == 3000 }?.summary == "3000")
        #expect(BrowserDevPort.read("nope").isEmpty)
    }

    @Test func sessionChoicesAreNamedLikeTheWebPicker() {
        let value: [Any] = [
            ["id": "s1", "cwd": "/Users/me/proj", "title": "proj", "exitCode": NSNull()],
            ["id": "s2", "cwd": "/Users/me/proj", "title": "Fix login", "exitCode": NSNull()],
            ["id": "s3", "cwd": "/Users/me/proj", "title": "proj", "exitCode": 0],
            ["id": "s4", "cwd": "", "title": ""],
            ["cwd": "/no/id"],
        ]
        let choices = BrowserSessionChoice.read(value)
        #expect(choices.map(\.id) == ["s1", "s2", "s4"], "exited sessions are left out")
        #expect(choices[0].label == "proj · Session 1")
        #expect(choices[1].label == "Fix login")
        #expect(choices[2].label == "Session 1")
    }

    @Test func devicesFitTheRoom() {
        let phone = BrowserDevicePreset.byID("phone")!
        let fit = BrowserDevicePreset.fit(width: phone.width, height: phone.height, landscape: false, into: (1000, 700))
        #expect(fit.width == 390 && fit.height == 700 && fit.clamped)
        let turned = BrowserDevicePreset.fit(width: phone.width, height: phone.height, landscape: true, into: (1000, 700))
        #expect(turned.width == 844 && turned.height == 390 && !turned.clamped)
        #expect(BrowserDevicePreset.all.count == 6)
    }

    @Test func profilesAndTheirStores() {
        let value: [String: Any] = [
            "activeId": "work",
            "profiles": [
                ["id": "default", "name": "Default", "isDefault": true, "avatar": ""],
                ["id": "work", "name": "work stuff", "avatar": "🚀"],
                ["name": "no id"],
            ],
        ]
        let state = BrowserProfile.read(value)
        #expect(state.activeID == "work")
        #expect(state.profiles.map(\.id) == ["default", "work"])
        #expect(state.profiles[0].badge == "D")
        #expect(state.profiles[1].badge == "🚀")

        let a = BrowserProfile.storeIdentifier(for: "work")
        #expect(a == BrowserProfile.storeIdentifier(for: "work"), "the same profile always opens the same store")
        #expect(a != BrowserProfile.storeIdentifier(for: "home"))
        #expect(a != BrowserProfile.storeIdentifier(for: ""))
        #expect(a.uuidString.dropFirst(14).first == "5", "a name-based UUID")
    }
}
