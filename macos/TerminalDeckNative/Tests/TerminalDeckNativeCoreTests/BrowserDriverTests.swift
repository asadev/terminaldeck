import CoreGraphics
import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// A page that answers the driver's scripts from fixed data, records the input
/// it was sent, and keeps a fake clock.
@MainActor
final class FakeBrowserHost: BrowserDriverHost {
    struct Tab {
        var url: String
        var title: String
        var isolated: Bool
        var onScreen = true
        var handover: String?
    }

    var tabs: [String: Tab] = [:]
    var ownTabID: String?
    var view = BrowserBindings()
    var clock: Double = 0
    var nextTab = 0

    // What happened.
    var clicks: [CGRect] = []
    var typed: [BrowserTypingPlan] = []
    var keys: [BrowserKeySpec] = []
    var scripted: [[String: Any]] = []
    var scripts: [(name: String, args: [String: Any])] = []
    var closed: [String] = []
    var revealed: [String] = []

    // How the page answers.
    var probeAnswer: [String: Any] = [
        "found": true, "count": 1, "tag": "button", "type": "", "label": "Save", "secret": false,
        "visible": true, "enabled": true, "editable": false, "checked": false, "hit": true,
        "rect": ["x": 10, "y": 20, "width": 100, "height": 40],
        "viewport": ["width": 1000, "height": 800],
    ]
    var handoverOutcome = "resumed"

    func bindings() async -> BrowserBindings { view }
    func tabExists(_ id: String) -> Bool { tabs[id] != nil }

    func createTab(url: URL, isolated: Bool) -> String {
        nextTab += 1
        let id = "t\(nextTab)"
        tabs[id] = Tab(url: url.absoluteString, title: "Title \(nextTab)", isolated: isolated)
        return id
    }

    func attach(_ id: String, to session: BrowserDriverSession) async -> String? {
        let n = view.of(session).count + 1
        var windows = view.windows
        windows[BrowserBindings.key(session), default: []].append(BrowserBoundWindow(n: n, tabID: id))
        view = BrowserBindings(windows: windows)
        return BrowserWindowName.name(n)
    }

    func load(_ id: String, url: URL) { tabs[id]?.url = url.absoluteString }
    func isIsolated(_ id: String) -> Bool { tabs[id]?.isolated ?? false }
    func setIsolated(_ id: String, _ isolated: Bool) { tabs[id]?.isolated = isolated }
    func settle(_ id: String, timeoutMs: Int) async -> Bool { true }
    func pageURL(_ id: String) -> String { tabs[id]?.url ?? "" }
    func title(_ id: String) -> String { tabs[id]?.title ?? "" }
    func displayTitle(_ id: String) -> String { tabs[id]?.title ?? "" }

    func evaluate(_ id: String, _ script: String) async throws -> Any? {
        let name = BrowserDriverScripts.name(of: script) ?? "?"
        let args = BrowserDriverScripts.arguments(of: script)
        scripts.append((name, args))
        switch name {
        case "outline":
            return [
                "url": pageURL(id), "title": title(id), "text": "Hello", "textTruncated": false,
                "elements": [
                    ["kind": "field", "tag": "input", "type": "email", "label": "Email", "selector": "#email",
                     "ref": "e1", "secret": false, "enabled": true, "value": "a@b.c"],
                    ["kind": "field", "tag": "input", "type": "password", "label": "Password",
                     "selector": "[data-td-ref=\"e2\"]", "ref": "e2", "secret": true, "enabled": true, "value": "leak"],
                    ["kind": "button", "tag": "button", "type": "", "label": "Sign in", "selector": "#go",
                     "ref": "e3", "secret": false, "enabled": true],
                ],
                "matched": 3, "truncated": false,
            ] as [String: Any]
        case "probe": return probeAnswer
        case "text": return ["found": true, "secret": false, "text": "Total: 42", "truncated": false]
        case "select": return (args["value"] as? String) == "blue" ? ["ok": true, "value": "blue"] : ["ok": false, "reason": "no such option. The ones there are: red, blue"]
        case "scriptedInput":
            scripted.append(args)
            return ["ok": true]
        default: return ["ok": true, "found": true]
        }
    }

    func reveal(_ id: String) async -> Bool {
        revealed.append(id)
        return tabs[id]?.onScreen ?? false
    }

    func click(_ id: String, cssRect: CGRect) -> Bool {
        guard tabs[id]?.onScreen == true else { return false }
        clicks.append(cssRect)
        return true
    }

    func focusForTyping(_ id: String) -> Bool { tabs[id]?.onScreen == true }

    func type(_ id: String, plan: BrowserTypingPlan) -> Bool {
        guard tabs[id]?.onScreen == true else { return false }
        typed.append(plan)
        return true
    }

    func press(_ id: String, key: BrowserKeySpec) -> Bool {
        guard tabs[id]?.onScreen == true else { return false }
        keys.append(key)
        return true
    }

    func screenshot(_ id: String) async throws -> (path: String, width: Int, height: Int, masked: Int) {
        ("/data/copilot/screenshots/page-1.png", 2560, 1600, 1)
    }

    func handoverPrompt(_ id: String) -> String? { tabs[id]?.handover }
    func otherHandover(than id: String) -> String? {
        tabs.first { $0.key != id && $0.value.handover != nil }?.value.title
    }

    func handOver(_ id: String, prompt: String, windowMs: Int) async -> String {
        tabs[id]?.handover = prompt
        clock += 1_500
        if handoverOutcome != "still-waiting" { tabs[id]?.handover = nil }
        return handoverOutcome
    }

    func closeTab(_ id: String) {
        tabs[id] = nil
        closed.append(id)
    }

    func unbind(_ id: String) { closed.append("unbind:\(id)") }
    func now() -> Double { clock }
    func pause(ms: Int) async { clock += Double(ms) }
}

/// The engine's side of the wire: pushes `native-browser:command` and collects
/// what comes back on `native-browser:result`.
@MainActor
final class FakeEngine {
    let host = FakeBrowserHost()
    lazy var driver = BrowserDriverEngine(host: host)
    var results: [String: [String: Any]] = [:]
    var seq = 0

    @discardableResult
    func call(_ verb: String, _ args: [String: Any] = [:], session: BrowserDriverSession? = nil) async -> [String: Any] {
        seq += 1
        let id = "cmd-\(seq)"
        let sessionValue: Any = session.map { ["sessionId": $0.sessionId, "machineId": $0.machineId] } ?? NSNull()
        let pushed: [Any] = [["id": id, "verb": verb, "args": args, "session": sessionValue]]
        // Through JSON, as the event stream carries it.
        let wire = try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: pushed)) as! [Any]
        guard let command = BrowserDriverCommand.decode(wire) else { return [:] }
        let answer = await driver.answer(command)
        // The invoke's body must be JSON too.
        #expect(JSONSerialization.isValidJSONObject([id, answer]), "the result crosses the bridge as JSON")
        results[id] = answer
        return answer
    }
}

func resultValue(_ result: [String: Any]) -> [String: Any] { (result["value"] as? [String: Any]) ?? [:] }
func resultSummary(_ result: [String: Any]) -> [String: Any] { (result["summary"] as? [String: Any]) ?? [:] }
func resultError(_ result: [String: Any]) -> String? { result["error"] as? String }

@Suite("Browser driver — the six verbs against a fake engine")
@MainActor
struct BrowserDriverVerbTests {
    @Test func openReadStepScreenshotHandoverForHootsOwnTab() async {
        let engine = FakeEngine()

        // browser_open: makes Hoot's own tab.
        let opened = await engine.call("browser_open", ["url": "https://example.com/login"])
        #expect(resultError(opened) == nil)
        #expect(resultValue(opened)["url"] as? String == "https://example.com/login")
        #expect(resultValue(opened)["created"] as? Bool == true)
        #expect(resultValue(opened)["settled"] as? Bool == true)
        #expect(resultValue(opened)["window"] is NSNull)
        #expect(resultSummary(opened)["title"] as? String == "Title 1")
        #expect(engine.host.ownTabID == "t1")

        // Again: the same tab, navigated.
        let again = await engine.call("browser_open", ["url": "https://example.com/next"])
        #expect(resultValue(again)["created"] as? Bool == false)
        #expect(engine.host.tabs.count == 1)

        // browser_read: the outline, with a secret field's value never passed on.
        let read = await engine.call("browser_read")
        let outline = resultValue(read)
        #expect(Set(outline.keys) == ["url", "title", "text", "textTruncated", "elements", "matched", "truncated"])
        let elements = outline["elements"] as? [[String: Any]] ?? []
        #expect(elements.count == 3)
        #expect(elements[0]["value"] as? String == "a@b.c")
        #expect(elements[1]["secret"] as? Bool == true)
        #expect(elements[1]["value"] == nil, "a password's value is never read back")
        #expect(elements[2]["ref"] as? String == "e3")
        #expect(resultSummary(read)["elements"] as? Int == 3)
        #expect(engine.host.scripts.last?.args["textLimit"] as? Int == 4_000)

        // browser_step click by ref: real input, at the element's rect.
        let clicked = await engine.call("browser_step", ["verb": "click", "selector": "e3"])
        #expect(resultError(clicked) == nil)
        #expect(engine.host.clicks == [CGRect(x: 10, y: 20, width: 100, height: 40)])
        #expect(engine.host.scripts.contains { $0.name == "probe" && $0.args["selector"] as? String == "[data-td-ref=\"e3\"]" })
        #expect(resultValue(clicked)["verb"] as? String == "click")
        #expect(resultValue(clicked)["selector"] as? String == "e3", "the agent's own words come back")
        #expect(resultValue(clicked)["label"] as? String == "Save")
        #expect(resultValue(clicked)["url"] as? String == "https://example.com/next")
        #expect(engine.host.revealed.contains("t1"), "a step brings the tab forward first")

        // browser_screenshot.
        let shot = await engine.call("browser_screenshot")
        #expect(resultValue(shot)["path"] as? String == "/data/copilot/screenshots/page-1.png")
        #expect(resultValue(shot)["width"] as? Int == 2560)
        #expect(resultValue(shot)["masked"] as? Int == 1)
        #expect(resultValue(shot)["url"] as? String == "https://example.com/next")

        // browser_handover.
        let handed = await engine.call("browser_handover", ["prompt": "Sign in,\nthen press Done"])
        #expect(resultValue(handed)["resumed"] as? Bool == true)
        #expect(resultValue(handed)["reason"] as? String == "resumed")
        #expect(resultValue(handed)["waitedMs"] as? Int == 1_500)
        #expect(resultSummary(handed)["outcome"] as? String == "resumed")

        // browser_close: Hoot's own tab is the person's to close.
        let close = await engine.call("browser_close")
        #expect(resultError(close)?.contains("your own tab is closed by the person") == true)
    }

    @Test func aSessionOpensReadsStepsAndClosesItsWindow() async {
        let engine = FakeEngine()
        let session = BrowserDriverSession(sessionId: "s1")

        let none = await engine.call("browser_read", session: session)
        #expect(resultError(none) == BrowserDriverTargeting.noWindowYet)

        let opened = await engine.call("browser_open", ["url": "http://localhost:3000/"], session: session)
        #expect(resultValue(opened)["attached"] as? Bool == true)
        #expect(resultValue(opened)["window"] as? String == "B1")
        #expect(resultValue(opened)["line"] as? String == "Opened http://localhost:3000/ in B1.")
        #expect(resultSummary(opened)["window"] as? String == "B1")

        let second = await engine.call("browser_open", ["url": "http://localhost:5173/"], session: session)
        #expect(resultValue(second)["window"] as? String == "B2", "a session's open with no window always makes one")

        let text = await engine.call("browser_read", ["selector": "#total", "window": "b2"], session: session)
        #expect(resultValue(text)["text"] as? String == "Total: 42")
        #expect(resultValue(text)["url"] as? String == "http://localhost:5173/")
        #expect(resultSummary(text)["chars"] as? Int == 9)

        engine.host.probeAnswer["editable"] = true
        engine.host.probeAnswer["type"] = "text"
        let typed = await engine.call("browser_step", ["verb": "type", "selector": "#q", "value": "hello", "window": "B1"], session: session)
        #expect(resultError(typed) == nil)
        #expect(engine.host.typed == [.keys(["h", "e", "l", "l", "o"])])
        #expect(engine.host.scripts.contains { $0.name == "focusAndSelect" }, "what was in the field is selected first")
        #expect(resultValue(typed)["window"] as? String == "B1")
        #expect(resultSummary(typed)["chars"] as? Int == 5)

        let pressed = await engine.call("browser_step", ["verb": "press", "selector": "#q", "key": "Tab", "window": "B1"], session: session)
        #expect(resultError(pressed) == nil)
        #expect(engine.host.keys.last == BrowserKeySpec.pressable["Tab"])

        let other = await engine.call("browser_read", ["sessionId": "s2", "window": "B1"], session: session)
        #expect(resultError(other) == BrowserDriverTargeting.noSuchWindowOfItsOwn, "a session drives only its own windows")

        let closed = await engine.call("browser_close", ["sessionId": "s1", "window": "B1"], session: session)
        #expect(resultValue(closed)["closed"] as? String == "B1")
        #expect(engine.host.closed == ["t1"])

        let gone = await engine.call("browser_read", ["window": "B1"], session: session)
        #expect(resultError(gone) == "B1 is not open any more. Read the window list again before naming one.")
    }

    @Test func offScreenInputFallsBackToScript() async {
        let engine = FakeEngine()
        await engine.call("browser_open", ["url": "https://example.com/"])
        engine.host.tabs["t1"]?.onScreen = false
        engine.host.probeAnswer["editable"] = true
        await engine.call("browser_step", ["verb": "type", "selector": "#q", "value": "hi"])
        #expect(engine.host.typed.isEmpty)
        #expect(engine.host.scripted.contains { $0["action"] as? String == "click" })
        #expect(engine.host.scripted.contains { $0["action"] as? String == "type" && $0["value"] as? String == "hi" })
    }

    @Test func stepRefusalsInTheEnginesWords() async {
        let engine = FakeEngine()
        let noPage = await engine.call("browser_step", ["verb": "click", "selector": "#a"])
        #expect(resultError(noPage) == "there is no page being driven; call browser.open first")
        await engine.call("browser_open", ["url": "https://example.com/"])

        #expect(resultError(await engine.call("browser_step", ["verb": "hover", "selector": "#a"]))
                == "verb must be one of: click, type, select, check, press, submit")
        #expect(resultError(await engine.call("browser_step", ["verb": "type", "selector": "#a"]))?.hasPrefix("a type step needs `value`") == true)
        #expect(resultError(await engine.call("browser_step", ["verb": "select", "selector": "#a", "value": ""]))
                == "a select step needs an option to choose; `value` is empty")
        #expect(resultError(await engine.call("browser_step", ["verb": "press", "selector": "#a", "key": "F5"]))?
                .hasSuffix("Enter, Tab, Escape, Backspace, Delete, ArrowDown, ArrowUp, ArrowLeft, ArrowRight.") == true)
        #expect(resultError(await engine.call("browser_step", ["verb": "click", "selector": String(repeating: "a", count: 401)]))
                == "that selector is longer than 400 characters")

        engine.host.probeAnswer["type"] = "password"
        engine.host.probeAnswer["editable"] = true
        let secret = await engine.call("browser_step", ["verb": "type", "selector": "#pw", "value": "x"])
        #expect(resultError(secret)?.contains("password, one-time-code or file field") == true)
        #expect(engine.host.typed.isEmpty, "nothing is typed into a secret field")

        engine.host.probeAnswer["type"] = "text"
        let wrong = await engine.call("browser_step", ["verb": "select", "selector": "#colour", "value": "green"])
        #expect(resultError(wrong) == "no such option. The ones there are: red, blue")
        #expect(resultError(await engine.call("browser_step", ["verb": "select", "selector": "#colour", "value": "blue"])) == nil)

        engine.host.probeAnswer["hit"] = false
        let covered = await engine.call("browser_step", ["verb": "click", "selector": "#a", "timeoutMs": 500])
        #expect(resultError(covered) == "waited 500ms and #a is covered by something else on the page. Read the page to see what is actually there.")

        engine.host.probeAnswer = ["found": false, "count": 0, "invalid": true]
        #expect(resultError(await engine.call("browser_step", ["verb": "click", "selector": "##"])) == "that is not a valid CSS selector: ##")
    }

    @Test func checkClicksOnlyWhenTheStateDiffers() async {
        let engine = FakeEngine()
        await engine.call("browser_open", ["url": "https://example.com/"])
        engine.host.probeAnswer["checked"] = true
        await engine.call("browser_step", ["verb": "check", "selector": "#agree"])
        #expect(engine.host.clicks.isEmpty, "already checked")
        await engine.call("browser_step", ["verb": "check", "selector": "#agree", "value": "false"])
        #expect(engine.host.clicks.count == 1)
    }

    @Test func thePersonsTurnBlocksTheAgent() async {
        let engine = FakeEngine()
        await engine.call("browser_open", ["url": "https://example.com/"])
        engine.host.handoverOutcome = "still-waiting"
        let waiting = await engine.call("browser_handover", ["prompt": "Enter the code"])
        #expect(resultValue(waiting)["resumed"] as? Bool == false)
        #expect(resultValue(waiting)["reason"] as? String == "still-waiting")
        let blocked = await engine.call("browser_read")
        #expect(resultError(blocked)?.hasPrefix("the person has this page right now.") == true)
        let shot = await engine.call("browser_screenshot")
        #expect(resultError(shot)?.hasPrefix("the person has this page right now.") == true)
    }

    @Test func badCommands() async {
        let engine = FakeEngine()
        #expect(resultError(await engine.call("browser_teleport")) == "browser_teleport is not a browser verb this window answers.")
        #expect(BrowserDriverCommand.decode([["verb": "browser_read"]]) == nil, "no id, nothing to answer")
        #expect(BrowserDriverCommand.decode([]) == nil)
        #expect(resultError(await engine.call("browser_open", ["url": "file:///etc/passwd"])) == "only http and https pages can be opened, not file:")
        #expect(resultError(await engine.call("browser_open", ["url": "  "])) == "url is required and must be a non-empty string")
        #expect(resultError(await engine.call("browser_read", ["window": "B1"])) == "name sessionId and window together, or neither")
        #expect(resultError(await engine.call("browser_read", ["timeoutMs": "soon"])) != nil)
        #expect(resultError(await engine.call("browser_open", ["url": "https://a.test/", "newWindow": true]))
                == "newWindow needs the sessionId it should be attached to")
    }
}

@Suite("Browser driver — pure rules")
struct BrowserDriverRuleTests {
    @Test func refsAndSelectors() {
        #expect(BrowserElementRef.selector(for: "e12") == "[data-td-ref=\"e12\"]")
        #expect(BrowserElementRef.selector(for: " e3 ") == "[data-td-ref=\"e3\"]")
        #expect(BrowserElementRef.selector(for: "#email") == "#email")
        #expect(BrowserElementRef.selector(for: "e") == "e")
        #expect(BrowserElementRef.selector(for: "e1a") == "e1a")
        #expect(BrowserElementRef.selector(for: "em") == "em", "a tag name is not a ref")
    }

    @Test func windowNames() {
        #expect(BrowserWindowName.number("B2") == 2)
        #expect(BrowserWindowName.number(" b10 ") == 10)
        #expect(BrowserWindowName.number("3") == 3)
        #expect(BrowserWindowName.number("B") == nil)
        #expect(BrowserWindowName.number("B0") == nil)
        #expect(BrowserWindowName.number("C1") == nil)

        let view: [String: Any] = ["sessions": [
            ["sessionId": "s1", "machineId": "", "colour": 2, "windows": [
                ["n": 3, "browserTabId": "tab-c", "viewId": NSNull(), "url": "", "title": ""],
                ["n": 1, "browserTabId": "tab-a"],
            ]],
            ["sessionId": "s2", "machineId": "pc", "windows": [["n": 1, "browserTabId": "tab-x"]]],
            ["machineId": "no-session"],
        ]]
        let bindings = BrowserBindings.read(view)
        #expect(bindings.of(BrowserDriverSession(sessionId: "s1")).map(\.name) == ["B1", "B3"])
        #expect(bindings.of(BrowserDriverSession(sessionId: "s2", machineId: "pc")).first?.tabID == "tab-x")
        #expect(bindings.of(BrowserDriverSession(sessionId: "s2")).isEmpty, "the machine is part of who a session is")
    }

    @Test func keysTypingAndWhereAClickLands() throws {
        #expect(try BrowserKeySpec.forKey("Enter") == BrowserKeySpec(keyCode: 36, characters: "\r"))
        #expect(try BrowserKeySpec.forKey("ArrowDown").keyCode == 125)
        #expect(Set(BrowserKeySpec.pressable.keys) == Set(BrowserKeySpec.pressableNames))

        #expect(try BrowserTypingPlan.make("") == .clear)
        #expect(try BrowserTypingPlan.make("hé😀") == .keys(["h", "é", "😀"]))
        let long = String(repeating: "x", count: 201)
        #expect(try BrowserTypingPlan.make(long) == .insert(long))
        #expect(throws: BrowserDriverRefusal.self) { try BrowserTypingPlan.make(String(repeating: "x", count: 2_001)) }

        let rect = CGRect(x: 10, y: 20, width: 100, height: 40)
        #expect(BrowserInputGeometry.viewPoint(cssRect: rect, pageZoom: 1, magnification: 1, viewHeight: 500, flipped: true) == CGPoint(x: 60, y: 40))
        #expect(BrowserInputGeometry.viewPoint(cssRect: rect, pageZoom: 2, magnification: 1, viewHeight: 500, flipped: true) == CGPoint(x: 120, y: 80))
        #expect(BrowserInputGeometry.viewPoint(cssRect: rect, pageZoom: 1, magnification: 1, viewHeight: 500, flipped: false) == CGPoint(x: 60, y: 460))

        #expect(BrowserStepRules.wantsChecked(nil))
        #expect(BrowserStepRules.wantsChecked("true"))
        #expect(!BrowserStepRules.wantsChecked("false"))
    }

    @Test func scriptsCarryTheirArguments() {
        let script = BrowserDriverScripts.with(BrowserDriverScripts.probe, args: ["selector": "a[title=\"x\u{2028}y\"]"])
        #expect(BrowserDriverScripts.name(of: script) == "probe")
        #expect(!script.contains("/*__DECK_ARGS__*/null"))
        #expect(!script.contains("\u{2028}"), "a line separator would end the script's string early")
        #expect(BrowserDriverScripts.arguments(of: script)["selector"] as? String == "a[title=\"x\u{2028}y\"]")
        for (name, script) in [("outline", BrowserDriverScripts.outline), ("text", BrowserDriverScripts.text),
                               ("select", BrowserDriverScripts.select), ("secretRects", BrowserDriverScripts.secretRects),
                               ("scrollIntoView", BrowserDriverScripts.scrollIntoView),
                               ("focusAndSelect", BrowserDriverScripts.focusAndSelect),
                               ("scriptedInput", BrowserDriverScripts.scriptedInput)] {
            #expect(BrowserDriverScripts.name(of: script) == name)
            #expect(script.hasSuffix("})()"), "\(name) is one expression")
        }
        #expect(BrowserDriverScripts.outline.contains("data-td-ref"))
    }

    @Test func handoverPrompts() {
        #expect(BrowserHandover.prompt("Sign in\n\tplease\u{202e}") == "Sign in please")
        #expect(BrowserHandover.prompt(String(repeating: "a", count: 300)).count == 201)
    }

    @Test func outlineCleaningIsForgiving() {
        let clean = BrowserOutline.clean(["elements": [["type": "FILE", "value": "/secret/path"], "junk"]])
        let elements = clean["elements"] as? [[String: Any]] ?? []
        #expect(elements.count == 1)
        #expect(elements[0]["secret"] as? Bool == true)
        #expect(elements[0]["value"] == nil)
        #expect(clean["url"] as? String == "")
        #expect(clean["matched"] as? Int == 0)
    }
}
