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

    // Browser 27 — every one has a default below, so a host that cannot do it
    // natively falls back to the page's DOM events (or refuses, for files).
    /// A real click with modifier keys held. False: use the scripted fallback.
    func click(_ id: String, cssRect: CGRect, modifiers: BrowserClickModifiers) -> Bool
    /// A real double click. False: DOM events instead.
    func doubleClick(_ id: String, cssRect: CGRect) -> Bool
    /// The real pointer moved over the element. False: DOM events instead.
    func hover(_ id: String, cssRect: CGRect) -> Bool
    /// A real key chord (Control+A). False: the scripted key instead.
    func press(_ id: String, chord: BrowserKeyChord) -> Bool
    /// Hand local files to the element: a file field, a button that opens the
    /// file chooser, or a drop zone. `probe` is what the driver found there.
    func upload(_ id: String, selector: String, files: [String], probe: [String: Any]) async throws -> [String: Any]
    /// Full page, one element or a PDF; the plain picture is `screenshot(_:)`.
    func screenshot(_ id: String, options: BrowserScreenshotOptions) async throws -> (path: String, width: Int, height: Int, masked: Int)

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

public extension BrowserDriverHost {
    func click(_ id: String, cssRect: CGRect, modifiers: BrowserClickModifiers) -> Bool {
        modifiers.isEmpty ? click(id, cssRect: cssRect) : false
    }
    func doubleClick(_ id: String, cssRect: CGRect) -> Bool { false }
    func hover(_ id: String, cssRect: CGRect) -> Bool { false }
    func press(_ id: String, chord: BrowserKeyChord) -> Bool { chord.hasModifiers ? false : press(id, key: chord.spec) }
    func upload(_ id: String, selector: String, files: [String], probe: [String: Any]) async throws -> [String: Any] {
        throw BrowserDriverRefusal("this browser window cannot take files from an agent")
    }
    func screenshot(_ id: String, options: BrowserScreenshotOptions) async throws -> (path: String, width: Int, height: Int, masked: Int) {
        guard options.isPlain else { throw BrowserDriverRefusal("this browser window takes only the visible picture") }
        return try await screenshot(id)
    }
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
        case .screenshot: return try await screenshot(command, target)
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
                if probe["invalid"] as? Bool == true { throw BrowserDriverRefusal("that is not a selector this can read: \(waitFor)") }
                if probe["found"] as? Bool == true, probe["visible"] as? Bool == true { break }
                if host.now() >= deadline {
                    throw BrowserDriverRefusal("waited \(timeoutMs)ms and \(waitFor) never appeared. Read the page without waitFor to see what is actually there.")
                }
                await host.pause(ms: 80)
            }
        }

        let mode = try command.optionalString("mode")
        if let mode, !BrowserStepRules.readModes.contains(mode) {
            throw BrowserDriverRefusal("mode is one of: \(BrowserStepRules.readModes.joined(separator: ", "))")
        }
        if let mode, mode != "outline", mode != "text" {
            return try await readMode(mode, command, id)
        }
        if mode != "outline", let said = try command.optionalString("selector") {
            let fields = try await evaluate(id, BrowserDriverScripts.text,
                                            ["selector": BrowserElementRef.selector(for: said), "limit": try command.int("textChars", fallback: 4_000, min: 200, max: BrowserStepRules.maxOutlineTextChars)])
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

    /// Accessibility tree, links, tables, cleaned HTML, every match, structured rows, frames.
    func readMode(_ mode: String, _ command: BrowserDriverCommand, _ id: String) async throws -> [String: Any] {
        var args: [String: Any] = ["mode": mode]
        let said = try command.optionalString("selector")
        if let said { args["selector"] = BrowserElementRef.selector(for: said) }
        if mode == "matches" && said == nil { throw BrowserDriverRefusal("matches needs a selector") }
        let fallbackLimit = mode == "accessibility" ? 400 : mode == "tables" ? 500 : 200
        args["limit"] = try command.int("limit", fallback: fallbackLimit, min: 1, max: 5_000)
        if let match = try command.optionalString("match") { args["match"] = match }
        if mode == "html" { args["maxChars"] = try command.int("maxChars", fallback: 100_000, min: 1_000, max: 1_000_000) }
        if mode == "extract" {
            if let rows = try command.optionalString("rows") { args["rows"] = BrowserElementRef.selector(for: rows) }
            if let fields = command.args["fields"] {
                guard let object = fields as? [String: Any], !object.isEmpty, object.count <= 50, object.values.allSatisfy({ $0 is String }) else {
                    throw BrowserDriverRefusal("fields is an object of names to selectors, like {\"title\": \"h2\", \"link\": \"a@href\"} (at most 50)")
                }
                args["fields"] = object
            }
            if args["rows"] == nil && args["fields"] == nil { throw BrowserDriverRefusal("extract needs rows (one selector per record), fields (names to selectors), or both") }
        }
        if let attributes = command.args["attributes"] as? [Any] { args["attributes"] = attributes.compactMap { $0 as? String } }
        let raw = try await evaluate(id, BrowserDriverScripts.readMode, args)
        if raw["invalid"] as? Bool == true { throw BrowserDriverRefusal("that is not a selector this can read: \(said ?? "")") }
        guard raw["found"] as? Bool == true else {
            if let reason = raw["reason"] as? String { throw BrowserDriverRefusal(reason) }
            throw BrowserDriverRefusal("nothing on the page matches \(said ?? "")")
        }
        var value = raw; value["found"] = nil; value["mode"] = mode
        var summary: [String: Any] = ["mode": mode, "url": value["url"] ?? ""]
        for key in ["count", "total", "lines", "chars", "truncated"] { if let v = value[key] { summary[key] = v } }
        return BrowserDriverResult.value(value, summary: summary)
    }

    // MARK: browser_step

    /// How sure the driver must be before acting: the element exists; or is
    /// also visible, enabled and still; or is also what a click would land on.
    enum Readiness { case attached, visible, hit }

    func step(_ command: BrowserDriverCommand, _ target: BrowserDriverTarget) async throws -> [String: Any] {
        let (id, windowName) = try page(for: target)
        try refuseWhileHuman(id)
        let verb = (command.args["verb"] as? String) ?? ""
        guard BrowserStepRules.verbs.contains(verb) else {
            throw BrowserDriverRefusal("verb must be one of: \(BrowserStepRules.verbs.joined(separator: ", "))")
        }
        let said: String
        if BrowserStepRules.selectorOptional.contains(verb) {
            said = (try command.optionalString("selector") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            said = try command.string("selector").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if said.count > BrowserStepRules.maxSelectorChars {
            throw BrowserDriverRefusal("that selector is longer than \(BrowserStepRules.maxSelectorChars) characters")
        }
        let selector = said.isEmpty ? "" : BrowserElementRef.selector(for: said)
        let value = command.rawString("value")
        let values = (command.args["values"] as? [Any])?.compactMap { $0 as? String }
        if verb == "type" && value == nil {
            throw BrowserDriverRefusal("a type step needs `value` — the text to type. Send an empty string only to clear the field.")
        }
        if verb == "select" && (value ?? "").isEmpty && (values ?? []).isEmpty {
            throw BrowserDriverRefusal(value == nil ? "a select step needs `value` — the option to choose (or `values` for several)."
                                                    : "a select step needs an option to choose; `value` is empty")
        }
        let chord = verb == "press" ? try BrowserKeyChord.parse((try command.optionalString("key")) ?? "Enter") : nil
        // The clipboard is the person's: it can hold a password they just copied.
        if let chord, BrowserKeyChord.usesClipboard(chord) {
            throw BrowserDriverRefusal("copy and paste go through the person's clipboard, which can hold a password they just copied. Type the text with a type step instead, and read text with browser.read.")
        }
        let plan = verb == "type" ? try BrowserTypingPlan.make(value ?? "") : nil
        let modifiers = try BrowserClickModifiers.read(command.args["modifiers"])
        let timeoutMs = try command.int("timeoutMs", fallback: BrowserStepRules.defaultTimeoutMs, min: 500, max: 30_000)
        let force = command.flag("force")
        var files: [String] = []
        if verb == "upload" {
            guard let list = command.args["files"] as? [Any], !list.isEmpty else {
                throw BrowserDriverRefusal("an upload step needs `files` — a list of full paths to the files to hand to the page")
            }
            files = try list.map { item throws(BrowserDriverRefusal) -> String in
                guard let path = item as? String, !path.isEmpty else { throw BrowserDriverRefusal("every file is a full path, as a string") }
                return path
            }
            if files.count > BrowserUploadPolicy.maxFiles { throw BrowserDriverRefusal("at most \(BrowserUploadPolicy.maxFiles) files go in one step") }
        }
        let dropTo = verb == "drag" ? try command.optionalString("to") : nil
        if verb == "drag", dropTo == nil, command.args["x"] == nil, command.args["y"] == nil {
            throw BrowserDriverRefusal("a drag step needs `to` (where to drop it) or `x`/`y` (how far to move it)")
        }

        let nativeInput: Set<String> = ["click", "dblclick", "hover", "type", "press", "check", "uncheck", "submit"]
        if nativeInput.contains(verb) { _ = await host.reveal(id) }
        _ = await host.settle(id, timeoutMs: 5_000)

        var found: [String: Any] = [:]
        if !selector.isEmpty {
            let readiness: Readiness
            if force || verb == "upload" || verb == "scroll" { readiness = .attached }
            else if ["select", "rightclick", "drag", "focus", "clear"].contains(verb) { readiness = .visible }
            else { readiness = .hit }
            found = try await actionable(selector, said: said, in: id, timeoutMs: timeoutMs, readiness: readiness)
        }
        let label = (found["label"] as? String) ?? ""
        let rect = Self.rect(found["rect"])
        var extra: [String: Any] = [:]

        switch verb {
        case "click":
            try await click(id, rect, selector, modifiers: modifiers)
        case "dblclick":
            if !host.doubleClick(id, cssRect: rect) { extra = try await dom(id, ["action": "dblclick", "selector": selector]) }
        case "rightclick":
            extra = try await dom(id, ["action": "contextmenu", "selector": selector])
        case "hover":
            if !host.hover(id, cssRect: rect) { extra = try await dom(id, ["action": "hover", "selector": selector]) }
        case "focus":
            extra = try await dom(id, ["action": "focus", "selector": selector])
        case "clear":
            if found["secret"] as? Bool == true { throw secretField(said) }
            extra = try await dom(id, ["action": "clear", "selector": selector])
        case "check", "uncheck":
            let wanted = verb == "check" ? BrowserStepRules.wantsChecked(value) : false
            if (found["checked"] as? Bool ?? false) != wanted {
                try await click(id, rect, selector, modifiers: BrowserClickModifiers())
            }
        case "type":
            let type = ((found["type"] as? String) ?? "").lowercased()
            if found["secret"] as? Bool == true || type == "password" || type == "file" { throw secretField(said) }
            guard found["editable"] as? Bool == true else { throw BrowserDriverRefusal("\(said) is not a field that can be typed into") }
            try await click(id, rect, selector, modifiers: BrowserClickModifiers())
            _ = try? await evaluate(id, BrowserDriverScripts.focusAndSelect, ["selector": selector])
            if !(host.focusForTyping(id) && host.type(id, plan: plan ?? .clear)) {
                try await scripted(id, ["action": "type", "selector": selector, "value": value ?? ""])
            }
        case "select":
            var args: [String: Any] = ["selector": selector, "value": value ?? ""]
            if let values, !values.isEmpty { args["values"] = values }
            let answer = try await evaluate(id, BrowserDriverScripts.select, args)
            if answer["ok"] as? Bool != true {
                throw BrowserDriverRefusal((answer["reason"] as? String) ?? "that option could not be chosen")
            }
            if let chosen = answer["values"] { extra["values"] = chosen }
        case "press":
            if found["secret"] as? Bool == true { throw secretField(said) }
            let active = try await evaluate(id, BrowserDriverScripts.activeSecret, [:])
            if active["secret"] as? Bool == true { throw secretField("the focused field") }
            if !selector.isEmpty, found["editable"] as? Bool != true { try await click(id, rect, selector, modifiers: BrowserClickModifiers()) }
            try await press(id, chord!, selector)
        case "submit":
            try await click(id, rect, selector, modifiers: BrowserClickModifiers())
            try await press(id, try BrowserKeyChord.parse("Enter"), selector)
        case "scroll":
            let x = (command.args["x"] as? NSNumber)?.doubleValue ?? 0, y = (command.args["y"] as? NSNumber)?.doubleValue ?? 0
            guard abs(x) <= 100_000, abs(y) <= 100_000 else { throw BrowserDriverRefusal("that scroll is too far; at most 100000 pixels a step") }
            var args: [String: Any] = ["action": "scroll", "x": x, "y": y]
            if !selector.isEmpty { args["selector"] = selector }
            extra = try await dom(id, args)
        case "drag":
            var args: [String: Any] = ["action": "drag", "selector": selector]
            if let dropTo {
                let toSelector = BrowserElementRef.selector(for: dropTo)
                _ = try await actionable(toSelector, said: dropTo, in: id, timeoutMs: timeoutMs, readiness: force ? .attached : .visible)
                args["to"] = toSelector
            }
            if let x = command.args["x"] as? NSNumber { args["x"] = x.doubleValue }
            if let y = command.args["y"] as? NSNumber { args["y"] = y.doubleValue }
            extra = try await dom(id, args)
            extra["inputMode"] = "dom-events"
        case "upload":
            let tag = (found["tag"] as? String) ?? "", type = ((found["type"] as? String) ?? "").lowercased()
            if tag == "input", type == "file", files.count > 1, found["multiple"] as? Bool != true {
                throw BrowserDriverRefusal("\(said) takes one file, and \(files.count) were given")
            }
            extra = try await host.upload(id, selector: selector, files: files, probe: found)
        default:
            break
        }
        extra["ok"] = nil; extra["rect"] = nil

        await host.pause(ms: 60)
        var result: [String: Any] = ["verb": verb, "selector": said, "label": label, "url": host.pageURL(id)]
        for (key, item) in extra where result[key] == nil { result[key] = item }
        result["window"] = windowName ?? NSNull()
        var summary: [String: Any] = ["verb": verb, "selector": said, "label": label, "url": host.pageURL(id)]
        if let windowName { summary["window"] = windowName }
        if verb == "type", let value { summary["chars"] = value.count }
        if verb == "press", let chord { summary["key"] = chord.key }
        if verb == "upload" { summary["files"] = files.map { ($0 as NSString).lastPathComponent } }
        return BrowserDriverResult.value(result, summary: summary)
    }

    private func secretField(_ said: String) -> BrowserDriverRefusal {
        BrowserDriverRefusal("\(said) is a password, one-time-code or file field. Nothing will be typed into it. Call browser.handover with a sentence saying what the person should fill in, and they will do it themselves — you will not see what they type, and neither will the log. (Files go in with an upload step.)")
    }

    /// Wait for the element to exist, be visible, enabled, in view, still, and —
    /// for a click — be what is actually at its middle (not a spinner or a banner).
    func actionable(_ selector: String, said: String, in id: String, timeoutMs: Int, needsHit: Bool) async throws -> [String: Any] {
        try await actionable(selector, said: said, in: id, timeoutMs: timeoutMs, readiness: needsHit ? .hit : .visible)
    }

    func actionable(_ selector: String, said: String, in id: String, timeoutMs: Int, readiness: Readiness) async throws -> [String: Any] {
        let deadline = host.now() + Double(timeoutMs)
        var lastRect: CGRect?
        var why = "never appeared"
        var scrolled = false
        while true {
            let probe = try await evaluate(id, BrowserDriverScripts.probe, ["selector": selector])
            if probe["invalid"] as? Bool == true { throw BrowserDriverRefusal("that is not a selector this can read: \(said)") }
            if probe["found"] as? Bool == true {
                if readiness == .attached { return probe }
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
                } else if readiness == .hit && probe["hit"] as? Bool != true {
                    why = "is covered by something else on the page"
                } else {
                    return probe
                }
            }
            if host.now() >= deadline {
                throw BrowserDriverRefusal("waited \(timeoutMs)ms and \(said) \(why). Read the page to see what is actually there\(readiness == .attached ? "" : ", or pass force: true to act on it anyway").")
            }
            await host.pause(ms: 80)
        }
    }

    private func dom(_ id: String, _ args: [String: Any]) async throws -> [String: Any] {
        let answer = try await evaluate(id, BrowserDriverScripts.domAction, args)
        if answer["ok"] as? Bool != true {
            throw BrowserDriverRefusal((answer["reason"] as? String) ?? "the page did not take that")
        }
        return answer
    }

    public static func rect(_ raw: Any?) -> CGRect {
        guard let fields = raw as? [String: Any] else { return .zero }
        func number(_ key: String) -> Double { (fields[key] as? NSNumber)?.doubleValue ?? 0 }
        return CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
    }

    private func click(_ id: String, _ rect: CGRect, _ selector: String, modifiers: BrowserClickModifiers) async throws {
        if !host.click(id, cssRect: rect, modifiers: modifiers) {
            var args: [String: Any] = ["action": "click", "selector": selector]
            if !modifiers.isEmpty { args["modifiers"] = modifiers.flags }
            try await scripted(id, args)
        }
    }

    private func press(_ id: String, _ chord: BrowserKeyChord, _ selector: String) async throws {
        if !host.press(id, chord: chord) {
            var args: [String: Any] = ["action": "key", "key": chord.key, "modifiers": chord.modifierFlags]
            if !selector.isEmpty { args["selector"] = selector }
            try await scripted(id, args)
        }
    }

    private func scripted(_ id: String, _ args: [String: Any]) async throws {
        let answer = try await evaluate(id, BrowserDriverScripts.scriptedInput, args)
        if answer["ok"] as? Bool != true {
            throw BrowserDriverRefusal((answer["reason"] as? String) ?? "the page did not take that")
        }
    }

    // MARK: browser_screenshot

    func screenshot(_ command: BrowserDriverCommand, _ target: BrowserDriverTarget) async throws -> [String: Any] {
        let (id, windowName) = try page(for: target)
        try refuseWhileHuman(id)
        let options = try BrowserScreenshotOptions.read(command)
        _ = await host.settle(id, timeoutMs: 5_000)
        if let selector = options.selector {
            let said = (try command.optionalString("selector")) ?? selector
            _ = try await actionable(selector, said: said, in: id, timeoutMs: try command.int("timeoutMs", fallback: BrowserStepRules.defaultTimeoutMs, min: 500, max: 30_000), readiness: .visible)
        }
        let shot = options.isPlain ? try await host.screenshot(id) : try await host.screenshot(id, options: options)
        var value: [String: Any] = ["path": shot.path, "width": shot.width, "height": shot.height,
                                    "masked": shot.masked, "url": host.pageURL(id)]
        value["window"] = windowName ?? NSNull()
        var summary: [String: Any] = ["path": shot.path, "width": shot.width, "height": shot.height, "masked": shot.masked]
        if options.pdf { value["format"] = "pdf"; summary["format"] = "pdf" }
        if options.fullPage { value["fullPage"] = true }
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
