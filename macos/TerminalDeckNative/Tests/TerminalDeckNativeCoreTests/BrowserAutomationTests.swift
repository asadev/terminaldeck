import CoreGraphics
import Foundation
import JavaScriptCore
import Testing
@testable import TerminalDeckNativeCore

/// Browser 27: the Playwright-level verbs, read modes and capture options on the
/// fake engine, and the pure rules behind them (keys, uploads, network scrub,
/// HAR, blocking, URL waits, every script parses).
@MainActor
@Suite("Browser 27 — automation beyond the six verbs")
struct BrowserAutomationTests {
    @Test func newStepVerbsFallBackToPageEvents() async {
        let engine = FakeEngine()
        await engine.call("browser_open", ["url": "https://example.com/"])
        for verb in ["dblclick", "rightclick", "hover", "focus", "clear"] {
            #expect(resultError(await engine.call("browser_step", ["verb": verb, "selector": "#a"])) == nil, "\(verb)")
        }
        let actions = engine.host.scripts.filter { $0.name == "domAction" }.compactMap { $0.args["action"] as? String }
        #expect(actions == ["dblclick", "contextmenu", "hover", "focus", "clear"], "a host without native double-click or hover uses DOM events")

        let scrolled = await engine.call("browser_step", ["verb": "scroll", "y": 600])
        #expect(resultError(scrolled) == nil, "scroll needs no selector")
        #expect(engine.host.scripts.last?.args["y"] as? Double == 600)

        #expect(resultError(await engine.call("browser_step", ["verb": "drag", "selector": "#card"]))?.hasPrefix("a drag step needs `to`") == true)
        let dragged = await engine.call("browser_step", ["verb": "drag", "selector": "#card", "to": "#done"])
        #expect(resultValue(dragged)["inputMode"] as? String == "dom-events")
        #expect(engine.host.scripts.last?.args["to"] as? String == "#done")

        let unchecked = await engine.call("browser_step", ["verb": "uncheck", "selector": "#agree"])
        #expect(resultError(unchecked) == nil)
        #expect(engine.host.clicks.isEmpty, "already unchecked, so nothing is clicked")
    }

    @Test func keysAndChords() async throws {
        let engine = FakeEngine()
        await engine.call("browser_open", ["url": "https://example.com/"])
        #expect(resultError(await engine.call("browser_step", ["verb": "press", "key": "F5"])) == nil, "press needs no selector")
        #expect(engine.host.keys.last == BrowserKeyChord.named["F5"])
        await engine.call("browser_step", ["verb": "press", "key": "Control+A"])
        let chord = engine.host.scripted.last
        #expect(chord?["key"] as? String == "a")
        #expect((chord?["modifiers"] as? [String: Bool])?["control"] == true, "a chord the host cannot send natively is a scripted key with its modifiers")
        let paste = await engine.call("browser_step", ["verb": "press", "key": "Meta+V"])
        #expect(resultError(paste)?.contains("person's clipboard") == true)

        #expect(try BrowserKeyChord.parse("enter").key == "Enter")
        #expect(try BrowserKeyChord.parse("Shift+Tab").shift)
        #expect(try BrowserKeyChord.parse("Meta+Shift+k").spec.characters == "K")
        #expect(try BrowserKeyChord.parse("+").key == "+")
        #expect(try BrowserKeyChord.parse("Shift++").key == "+")
        #expect(throws: BrowserDriverRefusal.self) { try BrowserKeyChord.parse("Super+A") }
        #expect(throws: BrowserDriverRefusal.self) { try BrowserKeyChord.parse("Control+") }
        #expect(BrowserKeyChord.usesClipboard(try BrowserKeyChord.parse("Control+c")))
        #expect(!BrowserKeyChord.usesClipboard(try BrowserKeyChord.parse("c")))
    }

    @Test func uploadsGoThroughTheHost() async {
        let engine = FakeEngine()
        await engine.call("browser_open", ["url": "https://example.com/"])
        #expect(resultError(await engine.call("browser_step", ["verb": "upload", "selector": "#photo"]))?.hasPrefix("an upload step needs `files`") == true)
        let refused = await engine.call("browser_step", ["verb": "upload", "selector": "#photo", "files": ["/tmp/a.png"]])
        #expect(resultError(refused) == "this browser window cannot take files from an agent", "a host that cannot is honest about it")

        engine.host.probeAnswer["tag"] = "input"
        engine.host.probeAnswer["type"] = "file"
        engine.host.probeAnswer["visible"] = false
        let many = await engine.call("browser_step", ["verb": "upload", "selector": "#photo", "files": ["/tmp/a.png", "/tmp/b.png"]])
        #expect(resultError(many) == "#photo takes one file, and 2 were given", "a hidden single-file field is still found, and the count is checked")
    }

    @Test func readModes() async {
        let engine = FakeEngine()
        await engine.call("browser_open", ["url": "https://example.com/"])
        let tree = await engine.call("browser_read", ["mode": "accessibility"])
        #expect(resultError(tree) == nil)
        #expect(engine.host.scripts.last?.name == "readMode")
        #expect(engine.host.scripts.last?.args["limit"] as? Int == 400)
        #expect(resultValue(tree)["mode"] as? String == "accessibility")

        #expect(resultError(await engine.call("browser_read", ["mode": "everything"]))?.hasPrefix("mode is one of") == true)
        #expect(resultError(await engine.call("browser_read", ["mode": "matches"])) == "matches needs a selector")
        #expect(resultError(await engine.call("browser_read", ["mode": "extract"]))?.hasPrefix("extract needs rows") == true)
        let records = await engine.call("browser_read", ["mode": "extract", "rows": "li.item", "fields": ["name": "h2", "link": "a@href"]])
        #expect(resultError(records) == nil)
        #expect((engine.host.scripts.last?.args["fields"] as? [String: String])?["link"] == "a@href")
        #expect(resultError(await engine.call("browser_read", ["mode": "extract", "fields": ["n": 3]]))?.hasPrefix("fields is an object") == true)
    }

    @Test func screenshotOptions() async {
        let engine = FakeEngine()
        await engine.call("browser_open", ["url": "https://example.com/"])
        #expect(resultError(await engine.call("browser_screenshot", [:])) == nil, "the plain picture is unchanged")
        #expect(resultError(await engine.call("browser_screenshot", ["fullPage": true])) == "this browser window takes only the visible picture")
        #expect(resultError(await engine.call("browser_screenshot", ["format": "pdf", "selector": "#a"])) == "a PDF is the whole page; leave out selector")
        #expect(resultError(await engine.call("browser_screenshot", ["format": "gif"])) == "format is png or pdf")
    }

    @Test func uploadPolicy() {
        let home = "/Users/x"
        func refusal(_ path: String) -> String? {
            BrowserUploadPolicy.refusal(path: path, resolved: path, home: home, protectedRoots: ["/Users/x/Library/Application Support/Terminal Deck Dev B27"])
        }
        #expect(refusal("/Users/x/Pictures/cat.jpg") == nil)
        #expect(refusal("/Users/x/Desktop/report.pdf") == nil)
        #expect(refusal("relative.png")?.contains("not a full path") == true)
        #expect(refusal("/Users/x/.ssh/id_rsa") != nil)
        #expect(refusal("/Users/x/.aws/credentials") != nil)
        #expect(refusal("/Users/x/Library/Keychains/login.keychain-db") != nil)
        #expect(refusal("/Users/x/Library/Application Support/terminaldeck/store.key") != nil)
        #expect(refusal("/Users/x/Library/Application Support/Terminal Deck Dev B27/x.png") != nil)
        #expect(refusal("/etc/passwd") != nil)
        #expect(refusal("/Users/x/Documents/id_ed25519") != nil)
    }

    @Test func networkScrub() {
        let headers = BrowserNetworkScrub.headers(["Authorization": "Bearer x", "Content-Type": "application/json", "cookie": "a=b"])
        #expect(headers.value["authorization"] == "[hidden]")
        #expect(headers.value["cookie"] == "[hidden]")
        #expect(headers.value["content-type"] == "application/json")
        #expect(headers.hidden == 2)
        let json = BrowserNetworkScrub.body(#"{"user":"a","password":"p","nested":{"access_token":"t","next_page_token":"keep"},"items":[{"cvv":"1"}]}"#)
        #expect(json.hidden == 3)
        #expect(json.value?.contains("keep") == true)
        #expect(json.value?.contains("\"p\"") == false)
        let form = BrowserNetworkScrub.body("user=a&password=secret&remember=1")
        #expect(form.value == "user=a&password=[hidden]&remember=1")
        #expect(BrowserNetworkScrub.body("<html>password=1</html>").hidden == 0)
    }

    @Test func harLog() throws {
        let har = BrowserHAR.make(pageURL: "https://a.test/", title: "A", entries: [
            ["kind": "fetch", "method": "POST", "url": "https://a.test/api?q=1", "start": 1_000, "end": 1_250, "status": 201,
             "requestHeaders": ["content-type": "application/json"], "requestBody": "{}", "responseHeaders": ["content-type": "application/json"], "responseBody": "[]"],
        ], resources: [["url": "https://a.test/logo.png", "type": "img", "duration": 30, "start": 900, "status": 200, "size": 512]])
        let log = har["log"] as? [String: Any]
        let entries = log?["entries"] as? [[String: Any]] ?? []
        #expect(log?["version"] as? String == "1.2")
        #expect(entries.count == 2)
        #expect((entries.first?["request"] as? [String: Any])?["url"] as? String == "https://a.test/logo.png", "rows are in time order")
        let api = entries.last
        #expect(api?["time"] as? Double == 250)
        #expect(((api?["request"] as? [String: Any])?["queryString"] as? [[String: String]])?.first?["name"] == "q")
        #expect(((api?["response"] as? [String: Any])?["content"] as? [String: Any])?["text"] as? String == "[]")
        _ = try JSONSerialization.data(withJSONObject: har)
    }

    @Test func blockingAndURLPatterns() throws {
        #expect(try BrowserContentRules.urlFilter("**/*.png") == "^.*/.*\\.png$")
        #expect(try BrowserContentRules.urlFilter("doubleclick.net") == "doubleclick\\.net")
        #expect(try BrowserContentRules.urlFilter("/ads?\\.js/") == "ads?\\.js")
        #expect(throws: BrowserDriverRefusal.self) { try BrowserContentRules.urlFilter("/a|b/") }
        let list = try BrowserContentRules.blockList(["**/*.png"], types: ["image"])
        let rules = try JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]]
        #expect((rules?.first?["trigger"] as? [String: Any])?["resource-type"] as? [String] == ["image"])
        #expect(throws: BrowserDriverRefusal.self) { try BrowserContentRules.blockList(["x"], types: ["pictures"]) }

        #expect(try BrowserURLMatch.matcher("checkout")("https://shop.test/checkout/1"))
        #expect(try BrowserURLMatch.matcher("**/checkout/*")("https://shop.test/checkout/1"))
        #expect(try !BrowserURLMatch.matcher("**/checkout/*")("https://shop.test/cart"))
        #expect(try BrowserURLMatch.matcher("/order=\\d+/")("https://shop.test/?order=42"))
    }

    /// Every script the browser runs is valid JavaScript (WebKit's own parser).
    @Test func everyScriptParses() {
        let context = JSContext()!
        func parses(_ source: String) -> Bool {
            let script = JSStringCreateWithCFString(source as CFString)
            defer { JSStringRelease(script) }
            var exception: JSValueRef?
            return JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, &exception) && exception == nil
        }
        let expressions: [(String, String)] = [
            ("outline", BrowserDriverScripts.outline), ("probe", BrowserDriverScripts.probe), ("text", BrowserDriverScripts.text),
            ("select", BrowserDriverScripts.select), ("secretRects", BrowserDriverScripts.secretRects), ("secretState", BrowserDriverScripts.secretState),
            ("scrollIntoView", BrowserDriverScripts.scrollIntoView), ("focusAndSelect", BrowserDriverScripts.focusAndSelect),
            ("scriptedInput", BrowserDriverScripts.scriptedInput), ("domAction", BrowserDriverScripts.domAction), ("files", BrowserDriverScripts.files),
            ("readMode", BrowserDriverScripts.readMode), ("pickAt", BrowserDriverScripts.pickAt), ("recorder", BrowserDriverScripts.recorder),
            ("console", BrowserPageHooks.console(auto: true)), ("network", BrowserPageHooks.network(config: ["bodies": true])),
            ("emulate", BrowserPageHooks.emulate(["locale": "ur-PK"])), ("readConsole", BrowserPageHooks.with(BrowserPageHooks.readConsole, argument: 0)),
            ("configureNetwork", BrowserPageHooks.configureNetwork(["offline": true])), ("networkIdle", BrowserPageHooks.networkIdle),
        ]
        for (name, source) in expressions {
            #expect(parses(source), "\(name) parses")
            if name != "console" && name != "network" && name != "emulate" && name != "readConsole" && name != "configureNetwork" && name != "networkIdle" {
                #expect(BrowserDriverScripts.name(of: source) == name, "\(name) carries its name")
            }
        }
        let bodies: [(String, String)] = [
            ("evaluate", BrowserAsyncScripts.evaluate("document.title", asBody: false)),
            ("evaluate body", BrowserAsyncScripts.evaluate("const a = 1; return a + 1;", asBody: true)),
            ("wait", BrowserAsyncScripts.wait), ("waitForFunction", BrowserAsyncScripts.waitForFunction("() => window.ready === true")),
        ]
        for (name, body) in bodies { #expect(parses("(async function (args, arg) {\n" + body + "\n})"), "\(name) parses") }
        #expect(!parses("(async function (args, arg) {\n" + BrowserAsyncScripts.evaluate("const a = 1; return a;", asBody: false) + "\n})"),
                "statements are not an expression, so the runtime retries them as a function body")
    }
}
