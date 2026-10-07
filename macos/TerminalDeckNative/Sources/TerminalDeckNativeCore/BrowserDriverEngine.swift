import Foundation

/// What the driver needs from the browser — the native tabs in the app, or a
/// fake page in a test. Everything the six verbs decide lives in
/// `BrowserDriverEngine`; a host only does what it is told.
@MainActor
public protocol BrowserDriverHost: AnyObject {
    /// The engine's `browser:bindings`: which windows each session has.
    func bindings() async -> BrowserBindings
    /// Hoot's (or an owner AI app's) own tab, if it has one.
    var ownTabID: String? { get set }

    func tabExists(_ id: String) -> Bool
    /// A new tab loading `url`, in the strip but not brought forward.
    func createTab(url: URL, isolated: Bool) -> String
    /// Attach a tab to a session in the engine's map; its name there (B1…).
    func attach(_ id: String, to session: BrowserDriverSession) async -> String?
    func load(_ id: String, url: URL)
    func isIsolated(_ id: String) -> Bool
    func setIsolated(_ id: String, _ isolated: Bool)
    /// Wait for the page to stop loading; true when it did in time.
    func settle(_ id: String, timeoutMs: Int) async -> Bool
    func pageURL(_ id: String) -> String
    func title(_ id: String) -> String
    func displayTitle(_ id: String) -> String
    /// Run one of `BrowserDriverScripts` in the page.
    func evaluate(_ id: String, _ script: String) async throws -> Any?
    /// Bring the tab forward; true once it is on screen (real input possible).
    func reveal(_ id: String) async -> Bool

    /// Real input into the page. False when it is not on screen: the engine
    /// then uses the scripted fallback.
    func click(_ id: String, cssRect: CGRect) -> Bool
    func focusForTyping(_ id: String) -> Bool
    func type(_ id: String, plan: BrowserTypingPlan) -> Bool
    func press(_ id: String, key: BrowserKeySpec) -> Bool

    /// A PNG of the page with every secret field painted out, written where
    /// the agent's screenshots go.
    func screenshot(_ id: String) async throws -> (path: String, width: Int, height: Int, masked: Int)

    /// What the person is being asked on this tab, if anything.
    func handoverPrompt(_ id: String) -> String?
    /// Another tab the person is already being asked about (its title).
    func otherHandover(than id: String) -> String?
    /// Show the ask (if not already) and wait for Done / Stop / the tab closing /
    /// `windowMs` — "resumed", "stopped", "drive-ended" or "still-waiting".
    func handOver(_ id: String, prompt: String, windowMs: Int) async -> String

    func closeTab(_ id: String)
    func unbind(_ id: String)

    /// Milliseconds on a steady clock, and a pause — a test drives both.
    func now() -> Double
    func pause(ms: Int) async
}

/// The six verbs: arguments checked in the engine's own words, the page
/// resolved, the work done through the host, and the Electron driver's result
/// shapes returned (`{value, summary}` or `{error}`).
@MainActor
public final class BrowserDriverEngine {
    public let host: any BrowserDriverHost

    public init(host: any BrowserDriverHost) {
        self.host = host
    }

    /// The answer for one command: `{ value, summary }` or `{ error }`.
    public func answer(_ command: BrowserDriverCommand) async -> [String: Any] {
        do {
            return try await run(command)
        } catch let refusal as BrowserDriverRefusal {
            return BrowserDriverResult.error(refusal.message)
        } catch {
            return BrowserDriverResult.error("The page could not do that: \(error.localizedDescription)")
        }
    }

    func run(_ command: BrowserDriverCommand) async throws -> [String: Any] {
        guard let verb = command.verb else {
            throw BrowserDriverRefusal("\(command.verbName.isEmpty ? "That" : command.verbName) is not a browser verb this window answers.")
        }
        let target = try BrowserDriverTargeting.resolve(command, bindings: await host.bindings())
        switch verb {
        case .open: return try await open(command, target)
        case .read: return try await read(command, target)
        case .step: return try await step(command, target)
        case .screenshot: return try await screenshot(target)
        case .handover: return try await handover(command, target)
        case .close: return try close(target)
        }
    }

    // MARK: Pages

    func page(for target: BrowserDriverTarget) throws(BrowserDriverRefusal) -> (id: String, window: String?) {
        switch target {
        case .own:
            guard let id = host.ownTabID, host.tabExists(id) else {
                throw BrowserDriverRefusal("there is no page being driven; call browser.open first")
            }
            return (id, nil)
        case .window(let window, _):
            guard host.tabExists(window.tabID) else {
                throw BrowserDriverRefusal("\(window.name) is not open any more. Read the window list again before naming one.")
            }
            return (window.tabID, window.name)
        case .newWindow:
            throw BrowserDriverRefusal("name a window, or open one first")
        }
    }

    func refuseWhileHuman(_ id: String) throws(BrowserDriverRefusal) {
        if host.handoverPrompt(id) != nil {
            throw BrowserDriverRefusal("the person has this page right now. Wait — call browser.handover again to keep waiting, or say something to them. Do not try another way round.")
        }
    }

    private func evaluate(_ id: String, _ script: String, _ args: [String: Any]) async throws -> [String: Any] {
        (try await host.evaluate(id, BrowserDriverScripts.with(script, args: args)) as? [String: Any]) ?? [:]
    }

    // MARK: browser_open

    func open(_ command: BrowserDriverCommand, _ target: BrowserDriverTarget) async throws -> [String: Any] {
        let url = try BrowserStepRules.openableURL(try command.string("url"))
        switch target {
        case .newWindow(let session):
            let id = host.createTab(url: url, isolated: false)
            let name = await host.attach(id, to: session)
            let settled = await host.settle(id, timeoutMs: BrowserStepRules.settleMs)
            let line = name.map { "Opened \(url.absoluteString) in \($0)." } ?? "Opened \(url.absoluteString) in a new window."
            var value: [String: Any] = ["line": line, "attached": true, "url": host.pageURL(id),
                                        "title": host.title(id), "settled": settled]
            value["window"] = name ?? NSNull()
            var summary: [String: Any] = ["attached": true]
            if let name { summary["window"] = name }
            return BrowserDriverResult.value(value, summary: summary)

        case .own:
            let isolate = command.flag("isolate")
            var created = false
            let id: String
            if let own = host.ownTabID, host.tabExists(own) {
                try refuseWhileHuman(own)
                // Isolation is the page's cookie store: changing it replaces the page.
                if host.isIsolated(own) != isolate { host.setIsolated(own, isolate) }
                host.load(own, url: url)
                id = own
            } else {
                id = host.createTab(url: url, isolated: isolate)
                host.ownTabID = id
                created = true
            }
            let settled = await host.settle(id, timeoutMs: BrowserStepRules.settleMs)
            let value: [String: Any] = ["url": host.pageURL(id), "title": host.title(id), "settled": settled,
                                        "created": created, "window": NSNull()]
            return BrowserDriverResult.value(value, summary: ["url": host.pageURL(id), "title": host.title(id), "settled": settled])

        case .window(let window, _):
            let (id, _) = try page(for: target)
            try refuseWhileHuman(id)
            host.load(id, url: url)
            let settled = await host.settle(id, timeoutMs: BrowserStepRules.settleMs)
            let value: [String: Any] = ["url": host.pageURL(id), "title": host.title(id), "settled": settled,
                                        "created": false, "window": window.name]
            return BrowserDriverResult.value(value, summary: ["url": host.pageURL(id), "title": host.title(id),
                                                              "settled": settled, "window": window.name])
        }
    }

    // MARK: browser_read

    func read(_ command: BrowserDriverCommand, _ target: BrowserDriverTarget) async throws -> [String: Any] {
        let (id, _) = try page(for: target)
        try refuseWhileHuman(id)
        _ = await host.settle(id, timeoutMs: 5_000)
        let timeoutMs = try command.int("timeoutMs", fallback: 10_000, min: 500, max: 30_000)

        if let waitFor = try command.optionalString("waitFor") {
            let selector = BrowserElementRef.selector(for: waitFor)
            let deadline = host.now() + Double(timeoutMs)
            while true {
                let probe = try await evaluate(id, BrowserDriverScripts.probe, ["selector": selector])
                if probe["invalid"] as? Bool == true { throw BrowserDriverRefusal("that is not a valid CSS selector: \(waitFor)") }
                if probe["found"] as? Bool == true, probe["visible"] as? Bool == true { break }
                if host.now() >= deadline {
                    throw BrowserDriverRefusal("waited \(timeoutMs)ms and \(waitFor) never appeared. Read the page without waitFor to see what is actually there.")
                }
                await host.pause(ms: 80)
            }
        }

        if let said = try command.optionalString("selector") {
            let fields = try await evaluate(id, BrowserDriverScripts.text,
                                            ["selector": BrowserElementRef.selector(for: said), "limit": 4_000])
            guard fields["found"] as? Bool == true else { throw BrowserDriverRefusal("nothing on the page matches \(said)") }
            let secret = fields["secret"] as? Bool == true
            let text = secret ? "" : ((fields["text"] as? String) ?? "")
            return BrowserDriverResult.value(
                ["selector": said, "text": text, "truncated": fields["truncated"] as? Bool ?? false,
                 "secret": secret, "url": host.pageURL(id)],
                summary: ["selector": said, "chars": text.count])
        }

        let textChars = try command.int("textChars", fallback: BrowserStepRules.defaultOutlineTextChars,
                                        min: 200, max: BrowserStepRules.maxOutlineTextChars)
        let raw = try await host.evaluate(id, BrowserDriverScripts.with(BrowserDriverScripts.outline,
                                                                       args: ["limit": BrowserStepRules.outlineElementLimit,
                                                                              "textLimit": textChars]))
        let outline = BrowserOutline.clean(raw ?? [:])
        return BrowserDriverResult.value(outline, summary: [
            "url": outline["url"] ?? "",
            "elements": (outline["elements"] as? [Any])?.count ?? 0,
            "textChars": (outline["text"] as? String)?.count ?? 0,
        ])
    }

    // MARK: browser_step

    func step(_ command: BrowserDriverCommand, _ target: BrowserDriverTarget) async throws -> [String: Any] {
        let (id, windowName) = try page(for: target)
        try refuseWhileHuman(id)
        let verb = (command.args["verb"] as? String) ?? ""
        guard BrowserStepRules.verbs.contains(verb) else {
            throw BrowserDriverRefusal("verb must be one of: \(BrowserStepRules.verbs.joined(separator: ", "))")
        }
        let said = try command.string("selector").trimmingCharacters(in: .whitespacesAndNewlines)
        if said.count > BrowserStepRules.maxSelectorChars {
            throw BrowserDriverRefusal("that selector is longer than \(BrowserStepRules.maxSelectorChars) characters")
        }
        let selector = BrowserElementRef.selector(for: said)
        let value = command.rawString("value")
        if verb == "type" && value == nil {
            throw BrowserDriverRefusal("a type step needs `value` — the text to type. Send an empty string only to clear the field.")
        }
        if verb == "select" && (value ?? "").isEmpty {
            throw BrowserDriverRefusal(value == nil ? "a select step needs `value` — the option to choose."
                                                    : "a select step needs an option to choose; `value` is empty")
        }
        let keyName = (try command.optionalString("key")) ?? "Enter"
        let key = verb == "press" ? try BrowserKeySpec.forKey(keyName) : nil
        let plan = verb == "type" ? try BrowserTypingPlan.make(value ?? "") : nil
        let timeoutMs = try command.int("timeoutMs", fallback: BrowserStepRules.defaultTimeoutMs, min: 500, max: 30_000)

        _ = await host.reveal(id)
        _ = await host.settle(id, timeoutMs: 5_000)
        let found = try await actionable(selector, said: said, in: id, timeoutMs: timeoutMs, needsHit: verb != "select")
        let label = (found["label"] as? String) ?? ""
        let rect = Self.rect(found["rect"])

        switch verb {
        case "click":
            try await click(id, rect, selector)
        case "check":
            if (found["checked"] as? Bool ?? false) != BrowserStepRules.wantsChecked(value) {
                try await click(id, rect, selector)
            }
        case "type":
            let type = ((found["type"] as? String) ?? "").lowercased()
            if found["secret"] as? Bool == true || type == "password" || type == "file" {
                throw BrowserDriverRefusal("\(said) is a password, one-time-code or file field. Nothing will be typed into it. Call browser.handover with a sentence saying what the person should fill in, and they will do it themselves — you will not see what they type, and neither will the log.")
            }
            guard found["editable"] as? Bool == true else { throw BrowserDriverRefusal("\(said) is not a field that can be typed into") }
            try await click(id, rect, selector)
            _ = try? await evaluate(id, BrowserDriverScripts.focusAndSelect, ["selector": selector])
            if !(host.focusForTyping(id) && host.type(id, plan: plan ?? .clear)) {
                try await scripted(id, ["action": "type", "selector": selector, "value": value ?? ""])
            }
        case "select":
            let answer = try await evaluate(id, BrowserDriverScripts.select, ["selector": selector, "value": value ?? ""])
            if answer["ok"] as? Bool != true {
                throw BrowserDriverRefusal((answer["reason"] as? String) ?? "that option could not be chosen")
            }
        case "press":
            if found["editable"] as? Bool != true { try await click(id, rect, selector) }
            try await press(id, key!, keyName, selector)
        case "submit":
            try await click(id, rect, selector)
            try await press(id, try BrowserKeySpec.forKey("Enter"), "Enter", selector)
        default:
            break
        }

        await host.pause(ms: 60)
        var result: [String: Any] = ["verb": verb, "selector": said, "label": label, "url": host.pageURL(id)]
        result["window"] = windowName ?? NSNull()
        var summary: [String: Any] = ["verb": verb, "selector": said, "label": label, "url": host.pageURL(id)]
        if let windowName { summary["window"] = windowName }
        if verb == "type", let value { summary["chars"] = value.count }
        return BrowserDriverResult.value(result, summary: summary)
    }

    /// Wait for the element to exist, be visible, enabled, in view, still, and —
    /// for a click — be what is actually at its middle (not a spinner or a banner).
    func actionable(_ selector: String, said: String, in id: String, timeoutMs: Int, needsHit: Bool) async throws -> [String: Any] {
        let deadline = host.now() + Double(timeoutMs)
        var lastRect: CGRect?
        var why = "never appeared"
        var scrolled = false
        while true {
            let probe = try await evaluate(id, BrowserDriverScripts.probe, ["selector": selector])
            if probe["invalid"] as? Bool == true { throw BrowserDriverRefusal("that is not a valid CSS selector: \(said)") }
            if probe["found"] as? Bool == true {
                let rect = Self.rect(probe["rect"])
                let viewport = probe["viewport"] as? [String: Any]
                let height = (viewport?["height"] as? NSNumber)?.doubleValue ?? 0
                let width = (viewport?["width"] as? NSNumber)?.doubleValue ?? 0
                let inView = rect.minY >= 0 && rect.maxY <= height && rect.minX >= 0 && rect.maxX <= width
                if probe["visible"] as? Bool != true {
                    why = "is on the page but not visible"
                } else if probe["enabled"] as? Bool != true {
                    why = "is disabled"
                } else if !inView && !scrolled {
                    _ = try? await evaluate(id, BrowserDriverScripts.scrollIntoView, ["selector": selector])
                    scrolled = true
                    lastRect = nil
                    continue
                } else if lastRect != rect {
                    why = "kept moving"
                    lastRect = rect
                } else if needsHit && probe["hit"] as? Bool != true {
                    why = "is covered by something else on the page"
                } else {
                    return probe
                }
            }
            if host.now() >= deadline {
                throw BrowserDriverRefusal("waited \(timeoutMs)ms and \(said) \(why). Read the page to see what is actually there.")
            }
            await host.pause(ms: 80)
        }
    }

    public static func rect(_ raw: Any?) -> CGRect {
        guard let fields = raw as? [String: Any] else { return .zero }
        func number(_ key: String) -> Double { (fields[key] as? NSNumber)?.doubleValue ?? 0 }
        return CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
    }

    private func click(_ id: String, _ rect: CGRect, _ selector: String) async throws {
        if !host.click(id, cssRect: rect) {
            try await scripted(id, ["action": "click", "selector": selector])
        }
    }

    private func press(_ id: String, _ key: BrowserKeySpec, _ name: String, _ selector: String) async throws {
        if !host.press(id, key: key) {
            try await scripted(id, ["action": "key", "selector": selector, "key": name])
        }
    }

    private func scripted(_ id: String, _ args: [String: Any]) async throws {
        let answer = try await evaluate(id, BrowserDriverScripts.scriptedInput, args)
        if answer["ok"] as? Bool != true {
            throw BrowserDriverRefusal((answer["reason"] as? String) ?? "the page did not take that")
        }
    }

    // MARK: browser_screenshot

    func screenshot(_ target: BrowserDriverTarget) async throws -> [String: Any] {
        let (id, windowName) = try page(for: target)
        try refuseWhileHuman(id)
        _ = await host.reveal(id)
        _ = await host.settle(id, timeoutMs: 5_000)
        let shot = try await host.screenshot(id)
        var value: [String: Any] = ["path": shot.path, "width": shot.width, "height": shot.height,
                                    "masked": shot.masked, "url": host.pageURL(id)]
        value["window"] = windowName ?? NSNull()
        var summary: [String: Any] = ["path": shot.path, "width": shot.width, "height": shot.height, "masked": shot.masked]
        if let windowName { summary["window"] = windowName }
        return BrowserDriverResult.value(value, summary: summary)
    }

    // MARK: browser_handover

    func handover(_ command: BrowserDriverCommand, _ target: BrowserDriverTarget) async throws -> [String: Any] {
        let (id, _) = try page(for: target)
        let said = BrowserHandover.prompt(try command.string("prompt"))
        if let other = host.otherHandover(than: id) {
            throw BrowserDriverRefusal("the person is already being asked about \(other). Wait for that one before asking about this one.")
        }
        let started = host.now()
        let outcome = await host.handOver(id, prompt: said.isEmpty ? "Hoot needs you to do something on this page." : said,
                                          windowMs: BrowserStepRules.handoverWindowMs)
        let waitedMs = Int(host.now() - started)
        let url = host.tabExists(id) ? host.pageURL(id) : ""
        return BrowserDriverResult.value(
            ["resumed": outcome == "resumed", "reason": outcome, "url": url,
             "title": host.tabExists(id) ? host.title(id) : "", "waitedMs": waitedMs],
            summary: ["outcome": outcome, "waitedMs": waitedMs, "url": url])
    }

    // MARK: browser_close

    func close(_ target: BrowserDriverTarget) throws(BrowserDriverRefusal) -> [String: Any] {
        guard case .window(let window, _) = target else {
            throw BrowserDriverRefusal("your own tab is closed by the person, not by you. Name one of the session’s windows instead.")
        }
        if host.tabExists(window.tabID) {
            host.closeTab(window.tabID)
        } else {
            host.unbind(window.tabID)
        }
        return BrowserDriverResult.value(["closed": window.name], summary: ["window": window.name])
    }
}
