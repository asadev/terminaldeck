import CoreGraphics
import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Tabs")
struct TabsTests {
    func body(_ json: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    @Test func fullTabsMessage() throws {
        let json = #"""
        {"type":"tabs","state":{"tabs":[
          {"id":"t1","title":"claude","symbol":"terminal","kind":"terminal","active":true,"status":"working","closable":true},
          {"id":"t2","title":"docs","symbol":"globe","kind":"browser","active":false,"unread":true,"closable":true},
          {"id":"hoot","title":"Hoot","symbol":"bird","kind":"hoot","active":false,"closable":false}
        ],"canNewTerminal":true,"canNewBrowser":false}}
        """#
        guard case .tabs(let state) = PageMessage.parse(body(json)) else {
            Issue.record("expected .tabs"); return
        }
        #expect(state.tabs.map(\.id) == ["t1", "t2", "hoot"])
        #expect(state.activeID == "t1")
        #expect(state.tabs[0].status == "working")
        #expect(state.tabs[0].closable)
        #expect(state.tabs[1].unread)
        #expect(!state.tabs[0].unread)
        #expect(state.tabs[2].isHoot)
        #expect(!state.tabs[2].closable)
        #expect(state.canNewTerminal)
        #expect(!state.canNewBrowser)
    }

    @Test func forgivingDefaults() {
        let json = #"{"type":"tabs","state":{"tabs":[{"id":"a"},{"title":"no id"},{"id":"b","kind":"browser","unread":3}]}}"#
        guard case .tabs(let state) = PageMessage.parse(body(json)) else {
            Issue.record("expected .tabs"); return
        }
        #expect(state.tabs.map(\.id) == ["a", "b"])
        #expect(state.tabs[0].kind == "session")
        #expect(state.tabs[0].symbol == "terminal")
        #expect(!state.tabs[0].closable, "closing is never assumed")
        #expect(!state.tabs[0].active)
        #expect(state.tabs[1].symbol == "globe")
        #expect(state.tabs[1].unread)
        #expect(state.activeID == nil)
        #expect(!state.canNewTerminal && !state.canNewBrowser)
    }

    @Test func tabsWithoutStateIsIgnored() {
        #expect(PageMessage.parse(body(#"{"type":"tabs"}"#)) == nil)
    }

    @Test func hootIsRecognisedByKindOrId() {
        #expect(TabItem(id: "hoot", title: "Hoot", kind: "panel").isHoot)
        #expect(TabItem(id: "x", title: "Hoot", kind: "hoot").isHoot)
        #expect(!TabItem(id: "x", title: "Hoot", kind: "panel").isHoot)
        #expect(SidebarItem(id: "hoot", title: "Hoot", kind: .panel).isHoot)
        #expect(SidebarItem(id: "h", title: "Hoot", kind: .hoot).isHoot)
        #expect(!SidebarItem(id: "tasks", title: "Tasks", kind: .panel).isHoot)
    }

    @Test func commands() {
        #expect(PageCommand.selectTab("t1").script == #"window.tdNative && window.tdNative.run('select-tab', "t1")"#)
        #expect(PageCommand.closeTab("t1").script == #"window.tdNative && window.tdNative.run('close-tab', "t1")"#)
        #expect(PageCommand.newTerminalTab.script == "window.tdNative && window.tdNative.run('new-terminal-tab')")
        #expect(PageCommand.newBrowserTab.script == "window.tdNative && window.tdNative.run('new-browser-tab')")
    }

    @Test func tabWidthsShareTheRoomThenScroll() {
        // Few tabs: capped, left-aligned.
        #expect(TabStripMetrics.tabWidth(count: 2, available: 900) == TabStripMetrics.maximumTab)
        // Enough tabs to fill: equal shares that fit exactly.
        let w = TabStripMetrics.tabWidth(count: 5, available: 700)
        #expect(w > TabStripMetrics.minimumTab && w < TabStripMetrics.maximumTab)
        #expect(TabStripMetrics.contentWidth(count: 5, tabWidth: w) <= 700)
        // Too many: never narrower than the minimum (the strip scrolls).
        #expect(TabStripMetrics.tabWidth(count: 40, available: 700) == TabStripMetrics.minimumTab)
        #expect(TabStripMetrics.tabWidth(count: 0, available: 700) == 0)
    }
}

@Suite("Screen windows")
struct ScreenRefTests {
    let engine = URL(string: "http://127.0.0.1:51234/?t=tok123")!

    func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    @Test func panelAndSessionURLs() throws {
        let panel = try #require(ScreenRef(kind: .panel, id: "tasks").url(engineURL: engine))
        #expect(panel.absoluteString == "http://127.0.0.1:51234/?t=tok123&screen=panel&id=tasks")
        let session = try #require(ScreenRef(kind: .session, id: "s-42").url(engineURL: engine))
        #expect(query(session) == ["t": "tok123", "screen": "session", "id": "s-42"])
    }

    @Test func idsAreEscapedCompletely() throws {
        let nasty = ["a&screen=panel", "x=y", "1+1", "has space", "a/b?c#d", "100%", "ünï🦉", "'\"<>", ""]
        for id in nasty {
            let url = try #require(ScreenRef(kind: .session, id: id).url(engineURL: engine), "\(id)")
            let q = query(url)
            #expect(q["id"] == id, "id changed in transit: \(url.absoluteString)")
            #expect(q["screen"] == "session", "id leaked into another field: \(url.absoluteString)")
            #expect(url.fragment == nil)
            #expect(url.host == "127.0.0.1" && url.port == 51234 && url.path == "/")
        }
        // A '+' must not be read as a space by URLSearchParams on the page side.
        let plus = try #require(ScreenRef(kind: .panel, id: "1+1").url(engineURL: engine))
        #expect(plus.absoluteString.hasSuffix("id=1%2B1"))
    }

    @Test func onlyOnTheEngine() {
        #expect(ScreenRef(kind: .panel, id: "x").url(engineURL: URL(string: "https://example.com/")!) == nil)
        let noToken = ScreenRef(kind: .panel, id: "x").url(engineURL: URL(string: "http://127.0.0.1:9/")!)
        #expect(noToken?.absoluteString == "http://127.0.0.1:9/?screen=panel&id=x")
    }

    @Test func windowValueRoundTrip() throws {
        let refs = [ScreenRef(kind: .panel, id: "hoot", isHoot: true),
                    ScreenRef(kind: .session, id: "/Users/a/p::s1"),
                    ScreenRef(kind: .panel, id: "ünï 🦉 \"q\"")]
        for ref in refs {
            let data = try JSONEncoder().encode(ref)
            #expect(try JSONDecoder().decode(ScreenRef.self, from: data) == ref)
        }
        #expect(ScreenRef.decodeList(ScreenRef.encodeList(refs)) == refs)
    }

    @Test func rememberedListIsForgiving() {
        #expect(ScreenRef.decodeList(nil) == [])
        #expect(ScreenRef.decodeList(Data("garbage".utf8)) == [])
        // Older saved values without isHoot still open.
        let old = Data(#"[{"kind":"panel","id":"tasks"}]"#.utf8)
        #expect(ScreenRef.decodeList(old) == [ScreenRef(kind: .panel, id: "tasks")])
        // Duplicates collapse: one window per screen.
        let dup = ScreenRef.encodeList([ScreenRef(kind: .panel, id: "a"), ScreenRef(kind: .panel, id: "a")])
        #expect(ScreenRef.decodeList(dup).count == 1)
    }

    @Test func whichScreenAnItemOrTabOpens() {
        #expect(ScreenRef.forSidebarItem(SidebarItem(id: "s1", title: "zsh", kind: .session)) == ScreenRef(kind: .session, id: "s1"))
        #expect(ScreenRef.forSidebarItem(SidebarItem(id: "tasks", title: "Tasks", kind: .panel)) == ScreenRef(kind: .panel, id: "tasks"))
        #expect(ScreenRef.forSidebarItem(SidebarItem(id: "hoot", title: "Hoot", kind: .hoot)) == ScreenRef(kind: .panel, id: "hoot", isHoot: true))
        #expect(ScreenRef.forTab(TabItem(id: "t1", title: "claude", kind: "terminal")).kind == .session)
        #expect(ScreenRef.forTab(TabItem(id: "b1", title: "docs", kind: "browser")).kind == .session)
        #expect(ScreenRef.forTab(TabItem(id: "memory", title: "Memory", kind: "panel")).kind == .panel)
        #expect(ScreenRef.forTab(TabItem(id: "hoot", title: "Hoot", kind: "hoot")) == ScreenRef(kind: .panel, id: "hoot", isHoot: true))
    }
}

@Suite("Hoot's owl")
struct HootArtTests {
    static let webMark = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("src/renderer/copilot/HootMark.tsx")

    @Test func everyPathParses() throws {
        for element in HootArt.elements {
            if case .path(let d) = element.shape {
                let path = try SVGPath.parse(d)
                #expect(!path.isEmpty, "\(d)")
                #expect(HootArt.viewBox.insetBy(dx: -4, dy: -4).contains(path.boundingBoxOfPath), "\(d) outside the 64×64 art")
            }
        }
    }

    @Test func relativeCommandsFollowTheCurrentPoint() throws {
        let path = try SVGPath.parse("M26 44 q3 3 6 0 q3 3 6 0")
        #expect(path.currentPoint == CGPoint(x: 38, y: 44))
    }

    @Test func drawsInTheRealColours() throws {
        let image = try #require(HootArt.image(pixels: 64))
        func pixel(_ x: Int, _ yFromTop: Int) -> (Int, Int, Int, Int) {
            let data = image.dataProvider!.data! as Data
            let i = yFromTop * image.bytesPerRow + x * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
        }
        func close(_ p: (Int, Int, Int, Int), _ hex: UInt32) -> Bool {
            abs(p.0 - Int((hex >> 16) & 0xFF)) < 6 && abs(p.1 - Int((hex >> 8) & 0xFF)) < 6 && abs(p.2 - Int(hex & 0xFF)) < 6 && p.3 == 255
        }
        #expect(close(pixel(32, 12), 0xF7882F), "body orange on the crown")
        #expect(close(pixel(52, 40), 0xE8701A), "darker orange wing")
        #expect(close(pixel(40, 48), 0xFFD3A8), "belly")
        #expect(close(pixel(23, 27), 0x2A1A10), "left pupil")
        #expect(close(pixel(32, 34), 0xB4500F), "beak")
        #expect(pixel(2, 2).3 == 0, "transparent corner — no background, so it sits on light or dark")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: webMark.path)))
    func staysTheSameOwlAsTheWebApp() throws {
        let source = try String(contentsOf: Self.webMark, encoding: .utf8)
        for element in HootArt.elements {
            if case .path(let d) = element.shape {
                #expect(source.contains("d=\"\(d)\""), "path no longer in HootMark.tsx: \(d)")
            }
        }
        for (name, hex) in [("body", "#F7882F"), ("bodyDark", "#E8701A"), ("belly", "#FFD3A8"), ("bellyLine", "#F2A86A"),
                            ("face", "#FFE7CF"), ("pupil", "#2A1A10"), ("frames", "#5A3418"), ("beak", "#B4500F")] {
            #expect(source.contains("\(name): '\(hex)'"), "colour \(name) changed in HootMark.tsx")
        }
    }
}

@Suite("Open-window message, Hoot in Settings, browser windows")
struct RoundFourTests {
    func body(_ json: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    @Test func openWindowMessage() {
        #expect(PageMessage.parse(body(#"{"type":"open-window","kind":"session","id":"s1","title":"claude"}"#))
                == .openWindow(ScreenRef(kind: .session, id: "s1"), title: "claude"))
        #expect(PageMessage.parse(body(#"{"type":"open-window","kind":"panel","id":"hoot"}"#))
                == .openWindow(ScreenRef(kind: .panel, id: "hoot", isHoot: true), title: nil))
        #expect(PageMessage.parse(body(#"{"type":"open-window","kind":"window","id":"x"}"#)) == nil, "unknown kind")
        #expect(PageMessage.parse(body(#"{"type":"open-window","kind":"panel","id":""}"#)) == nil, "no id")
        #expect(PageMessage.parse(body(#"{"type":"open-window","kind":"panel"}"#)) == nil)
    }

    @Test func pageModalMessage() {
        #expect(PageMessage.parse(body(#"{"type":"page-modal","open":true}"#)) == .pageModal(open: true))
        #expect(PageMessage.parse(body(#"{"type":"page-modal","open":false}"#)) == .pageModal(open: false))
        #expect(PageMessage.parse(body(#"{"type":"page-modal"}"#)) == nil, "no state, no change")
        #expect(PageMessage.parse(body(#"{"type":"page-modal","open":"yes"}"#)) == nil)
    }

    @Test func hootSectionInSettings() {
        let json = #"{"type":"settings-sections","sections":[{"id":"hoot","title":"Hoot","symbol":"bird"},{"id":"assistant","title":"Hoot","kind":"hoot"},{"id":"general","title":"General","symbol":"gearshape"}]}"#
        guard case .settingsSections(let sections, _) = PageMessage.parse(body(json)) else {
            Issue.record("expected sections"); return
        }
        #expect(sections.map(\.isHoot) == [true, true, false], "by id 'hoot' or kind 'hoot'")
    }

    @Test func kindNames() {
        #expect(SidebarItem.Kind.hoot.name == "hoot")
        #expect(SidebarItem.Kind.panel.name == "panel")
        #expect(SidebarItem.Kind.session.name == "session")
        #expect(SidebarItem.Kind.other("browser").name == "browser")
    }

    @Test func browserWindowsHaveNoPageAndAreNotReopened() throws {
        let engine = URL(string: "http://127.0.0.1:5000/?t=x")!
        let ref = ScreenRef(kind: .browser, id: "b1")
        #expect(ref.url(engineURL: engine) == nil, "a native browser tab has no page behind it")
        #expect(!ref.isRemembered)
        #expect(ScreenRef(kind: .session, id: "s").isRemembered)
        #expect(ref.screenKind == "browser")
        #expect(ScreenRef(kind: .panel, id: "hoot", isHoot: true).screenKind == "hoot")
        #expect(ScreenRef(kind: .panel, id: "tasks").screenKind == "panel")
        #expect(ScreenRef(kind: .session, id: "s").screenKind == "session")
        let data = try JSONEncoder().encode(ref)
        #expect(try JSONDecoder().decode(ScreenRef.self, from: data) == ref)
    }

    @Test func aTabCanBeRestatedAsActiveOrNot() {
        let tab = TabItem(id: "t", title: "claude", symbol: "terminal", kind: "session", active: true, unread: true, status: "working", closable: true)
        let off = tab.with(active: false)
        #expect(!off.active)
        #expect(off.with(active: true) == tab, "nothing else changes")
    }

    @Test func allItemsCoversGroupsAndProjects() {
        let state = SidebarState(groups: [SidebarGroup(id: "g", title: nil, items: [SidebarItem(id: "a", title: "A", kind: .panel)])],
                                 projects: [SidebarProject(id: "/p", title: "p", expanded: false,
                                                           sessions: [SidebarItem(id: "s", title: "S", kind: .session)])],
                                 selectedId: nil)
        #expect(state.allItems.map(\.id) == ["a", "s"])
        #expect(state.item(id: "s")?.kind == .session)
    }
}
