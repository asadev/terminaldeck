import Foundation
import JavaScriptCore
import Testing
@testable import TerminalDeckNativeCore

// The page ↔ native contract, as Lane E2 implements it on the web side.

@Suite("Page messages")
struct PageMessageTests {

    // WebKit hands over Foundation objects; JSON parsed by Foundation is the same shape.
    func body(_ json: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    @Test func ready() {
        #expect(PageMessage.parse(body(#"{"type":"ready"}"#)) == .ready)
    }

    @Test func titleWithAndWithoutSubtitle() {
        #expect(PageMessage.parse(body(#"{"type":"title","value":"  td-native-shell \n"}"#)) == .title("td-native-shell", subtitle: nil))
        #expect(PageMessage.parse(body(#"{"type":"title","value":"claude","subtitle":"~/Projects/td"}"#)) == .title("claude", subtitle: "~/Projects/td"))
        #expect(PageMessage.parse(body(#"{"type":"title","value":"x","subtitle":null}"#)) == .title("x", subtitle: nil))
        #expect(PageMessage.parse(body(#"{"type":"title","value":"x","subtitle":"  "}"#)) == .title("x", subtitle: nil))
        #expect(PageMessage.parse(body(#"{"type":"title"}"#)) == nil)
    }

    @Test func subtitleNeverRepeatsTheTitle() {
        #expect(PageMessage.parse(body(#"{"type":"title","value":"Tasks","subtitle":"tasks"}"#)) == .title("Tasks", subtitle: nil))
    }

    @Test func titleIsCapped() {
        let long = String(repeating: "x", count: 500)
        #expect(PageMessage.parse(["type": "title", "value": long]) == .title(String(repeating: "x", count: PageMessage.maxTitleLength), subtitle: nil))
    }

    @Test func fullSidebar() throws {
        let json = #"""
        {"type":"sidebar","state":{
          "groups":[
            {"id":"main","title":null,"items":[
              {"id":"hoot","title":"Hoot","symbol":"bird","kind":"hoot","unread":true},
              {"id":"tasks","title":"Tasks","symbol":"checklist","kind":"panel"},
              {"id":"memory","title":"Memory","symbol":"brain","kind":"panel","subtitle":"12 notes"}
            ]},
            {"id":"tools","title":"Tools","items":[]}
          ],
          "projects":[
            {"id":"/Users/a/Projects/td","title":"td","expanded":true,"sessions":[
              {"id":"s1","title":"claude","symbol":"terminal","kind":"session","status":"working","unread":2},
              {"id":"s2","title":"zsh","symbol":"terminal","kind":"session","unread":0}
            ]},
            {"id":"/Users/a/Projects/site","expanded":false,"sessions":[]}
          ],
          "selectedId":"s1"}}
        """#
        guard case .sidebar(let state) = PageMessage.parse(body(json)) else {
            Issue.record("expected .sidebar"); return
        }
        #expect(state.groups.map(\.id) == ["main", "tools"])
        #expect(state.groups[0].title == nil)
        #expect(state.groups[1].title == "Tools")
        #expect(state.groups[0].items.map(\.kind) == [.hoot, .panel, .panel])
        #expect(state.groups[0].items[0].unread == true)
        #expect(state.groups[0].items[1].unread == false)
        #expect(state.groups[0].items[2].subtitle == "12 notes")
        #expect(state.projects.count == 2)
        #expect(state.projects[0].expanded)
        #expect(state.projects[0].sessions.map(\.id) == ["s1", "s2"])
        #expect(state.projects[0].sessions[0].status == "working")
        #expect(state.projects[0].sessions[0].unread == true, "a count > 0 is unread")
        #expect(state.projects[0].sessions[1].unread == false)
        #expect(state.projects[1].title == "site", "missing title falls back to the folder name")
        #expect(!state.projects[1].expanded)
        #expect(state.selectedId == "s1")
    }

    @Test func emptySidebarIsStillASidebar() {
        #expect(PageMessage.parse(body(#"{"type":"sidebar","state":{"groups":[],"projects":[],"selectedId":null}}"#))
                == .sidebar(SidebarState(groups: [], projects: [], selectedId: nil)))
    }

    @Test func oneBadRowDoesNotLoseTheSidebar() {
        let json = #"""
        {"type":"sidebar","state":{"groups":[{"id":"g","title":"G","items":[
          {"title":"no id"},
          {"id":"ok","title":"Fine","kind":"panel"},
          42
        ]}],"projects":[{"title":"no path"}],"selectedId":7}}
        """#
        guard case .sidebar(let state) = PageMessage.parse(body(json)) else {
            Issue.record("expected .sidebar"); return
        }
        #expect(state.groups[0].items.map(\.id) == ["ok"])
        #expect(state.projects.isEmpty)
        #expect(state.selectedId == "7")
    }

    @Test func missingOrUnknownFieldsGetSafeDefaults() {
        let json = #"{"type":"sidebar","state":{"groups":[{"id":"g","items":[{"id":"x","kind":"widget"},{"id":"y","kind":"session","symbol":""}]}]}}"#
        guard case .sidebar(let state) = PageMessage.parse(body(json)) else {
            Issue.record("expected .sidebar"); return
        }
        let items = state.groups[0].items
        #expect(items[0].kind == .other("widget"))
        #expect(items[0].symbol == "circle")
        #expect(items[0].title == "")
        #expect(items[1].symbol == "terminal")
        #expect(state.projects.isEmpty)
        #expect(state.selectedId == nil)
    }

    @Test func sidebarWithoutStateIsIgnored() {
        #expect(PageMessage.parse(body(#"{"type":"sidebar"}"#)) == nil)
        #expect(PageMessage.parse(body(#"{"type":"sidebar","state":"nope"}"#)) == nil)
    }

    @Test func openSettings() {
        #expect(PageMessage.parse(body(#"{"type":"open-settings","url":"/settings?embed=1"}"#)) == .openSettings(url: "/settings?embed=1", section: nil))
        #expect(PageMessage.parse(body(#"{"type":"open-settings","url":"/settings","section":"agents"}"#)) == .openSettings(url: "/settings", section: "agents"))
        #expect(PageMessage.parse(body(#"{"type":"open-settings"}"#)) == nil)
        #expect(PageMessage.parse(body(#"{"type":"open-settings","url":""}"#)) == nil)
    }

    @Test func settingsSections() {
        let json = #"{"type":"settings-sections","sections":[{"id":"general","title":"General","symbol":"gearshape"},{"id":"agents","title":"Agents","symbol":"cpu"},{"title":"no id"}],"selected":"agents"}"#
        #expect(PageMessage.parse(body(json)) == .settingsSections([
            SettingsSection(id: "general", title: "General", symbol: "gearshape"),
            SettingsSection(id: "agents", title: "Agents", symbol: "cpu"),
        ], selected: "agents"))
        #expect(PageMessage.parse(body(#"{"type":"settings-sections"}"#)) == .settingsSections([], selected: nil))
    }

    @Test func unknownOrMalformedMessages() {
        #expect(PageMessage.parse(body(#"{"type":"something-new"}"#)) == nil)
        #expect(PageMessage.parse(body(#"{"value":"no type"}"#)) == nil)
        #expect(PageMessage.parse("ready") == nil)
        #expect(PageMessage.parse(42) == nil)
    }
}

@Suite("Page commands")
struct PageCommandTests {

    @Test func plainCommandsKeepTheOriginalForm() {
        #expect(PageCommand.newSession.script == "window.tdNative && window.tdNative.run('new-session')")
        #expect(PageCommand.openProject.script == "window.tdNative && window.tdNative.run('open-project')")
        #expect(PageCommand.openSettings.script == "window.tdNative && window.tdNative.run('open-settings')")
    }

    @Test func namesMatchTheContract() {
        #expect(PageCommand.select("a").name == "select")
        #expect(PageCommand.closeSession("a").name == "close-session")
        #expect(PageCommand.newSessionIn("/p").name == "new-session-in")
        #expect(PageCommand.closeProject("/p").name == "close-project")
        #expect(PageCommand.toggleProject("/p").name == "toggle-project")
        #expect(PageCommand.settingsSection("general").name == "settings-section")
        #expect(PageCommand.select("s1").script == #"window.tdNative && window.tdNative.run('select', "s1")"#)
    }

    /// Runs each generated script in a real JavaScript engine and checks the page
    /// would receive exactly the name and argument we meant — whatever the path holds.
    @Test func argumentsSurviveARealJavaScriptEngine() throws {
        let nasty = [
            "/Users/a/Projects/td",
            "/Users/a/My \"quoted\" project",
            #"C:\Users\a\back\slash"#,
            "it's",
            "line\nbreak\rand\ttab",
            "</script><script>alert(1)</script>",
            "'); alert(1); ('",
            "\u{2028}\u{2029}",
            "emoji 🦉 and ünïcödé",
            "\u{0001}\u{001F}\u{007F}",
            "",
        ]
        let context = try #require(JSContext())
        context.evaluateScript("""
            var window = { tdNative: { run: function (name, arg) {
              window.got = { name: name, arg: arg, count: arguments.length };
            } } };
            """)
        let commands = nasty.flatMap { [PageCommand.select($0), .closeSession($0), .newSessionIn($0), .closeProject($0), .toggleProject($0), .settingsSection($0),
                                        .selectTab($0), .closeTab($0)] }
            + [.newSession, .openProject, .openSettings, .newTerminalTab, .newBrowserTab]

        for command in commands {
            context.evaluateScript("window.got = null")
            context.exception = nil
            context.evaluateScript(command.script)
            #expect(context.exception == nil, "script threw: \(command.script)")
            let got = try #require(context.evaluateScript("window.got"))
            #expect(got.forProperty("name").toString() == command.name)
            if let argument = command.argument {
                #expect(got.forProperty("count").toInt32() == 2)
                #expect(got.forProperty("arg").toString() == argument, "argument changed in transit: \(command.script)")
            } else {
                #expect(got.forProperty("count").toInt32() == 1)
            }
        }
    }

    @Test func nativeScreensListSurvivesARealJavaScriptEngine() throws {
        let ids = ["artifacts", "simulators", "session", "browser", "it's \"odd\"\n</script>"]
        let command = PageCommand.nativeScreens(ids)
        #expect(command.name == "native-screens")
        #expect(PageCommand.nativeScreens(["a", "b"]).script == #"window.tdNative && window.tdNative.run('native-screens', ["a", "b"])"#)
        let context = try #require(JSContext())
        context.evaluateScript("var window = { tdNative: { run: function (name, list) { window.got = { name: name, list: list } } } };")
        context.evaluateScript(command.script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("window.got.name").toString() == "native-screens")
        #expect(context.evaluateScript("Array.isArray(window.got.list)").toBool())
        #expect(context.evaluateScript("window.got.list").toArray() as? [String] == ids)
        context.evaluateScript(PageCommand.nativeScreens([]).script)
        #expect(context.evaluateScript("window.got.list.length").toInt32() == 0, "an empty list is still a list")
    }

    @Test func absentBridgeIsHarmless() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var window = {}")
        context.evaluateScript(PageCommand.select("x").script)
        #expect(context.exception == nil)
    }
}

@Suite("Settings location")
struct SettingsLocationTests {
    let engine = URL(string: "http://127.0.0.1:51234/?t=abc")!

    @Test func relativeURLsStayOnTheEngine() {
        #expect(SettingsLocation.resolve("/settings?embed=1", engineURL: engine)?.absoluteString == "http://127.0.0.1:51234/settings?embed=1")
        #expect(SettingsLocation.resolve("settings.html#agents", engineURL: engine)?.absoluteString == "http://127.0.0.1:51234/settings.html#agents")
        #expect(SettingsLocation.resolve("?view=settings&t=abc", engineURL: engine)?.absoluteString == "http://127.0.0.1:51234/?view=settings&t=abc")
    }

    @Test func anythingElseIsRefused() {
        for bad in ["https://evil.example/settings", "//evil.example/x", "http://127.0.0.1:9999/settings",
                    "javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi"] {
            #expect(SettingsLocation.resolve(bad, engineURL: engine) == nil, "\(bad)")
        }
    }
}
