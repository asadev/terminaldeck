import Foundation

// Agents driving the native browser — the pure half.
//
// The engine (src/main/native-shell/native-browser.ts) keeps the agents' six
// browser tools exactly as the Electron app has them — names, schemas, tiers,
// `mayDrive`, and the first-change-on-a-public-website question — and sends
// each call here instead of to Chromium:
//
//     event   native-browser:command   [{ id, verb, args, session }]
//     invoke  native-browser:result    [id, { value, summary? }]   or   [id, { error }]
//
// `verb` is the tool's wire name (`browser_open`, `browser_read`, `browser_step`,
// `browser_screenshot`, `browser_handover`, `browser_close`), `args` is what the
// agent passed, `session` is `{ sessionId, machineId }` for a session or null for
// Hoot / an AI app acting as the owner. Every `value` carries the page's `url`
// where there is one: the engine remembers it to decide whether the next step
// is a first change on a public website (put to the person) or not.
//
// Result shapes are the Electron driver's (`src/main/browser-driver.ts`), so an
// agent cannot tell which browser it drove. Window names (B1, B2) are the
// engine's own binding map (`browser:bindings`), so `sessions.list` and this
// side agree on what B2 is.

/// The six verbs, by their wire names.
public enum BrowserDriverVerb: String, Sendable, CaseIterable {
    case open = "browser_open"
    case read = "browser_read"
    case step = "browser_step"
    case screenshot = "browser_screenshot"
    case handover = "browser_handover"
    case close = "browser_close"
}

/// Who is calling: a session (which may drive only its own windows), or nil for
/// Hoot or an AI app acting as the person.
public struct BrowserDriverSession: Equatable, Sendable {
    public let sessionId: String
    public let machineId: String

    public init(sessionId: String, machineId: String = "") {
        self.sessionId = sessionId
        self.machineId = machineId
    }
}

/// A refusal, said in one plain sentence — what the agent reads.
public struct BrowserDriverRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// One command from the engine.
public struct BrowserDriverCommand: @unchecked Sendable {
    public let id: String
    public let verbName: String
    public let verb: BrowserDriverVerb?
    public let args: [String: Any]
    public let session: BrowserDriverSession?

    /// The event's arguments (`[{id, verb, args, session}]`). Nil when there is no
    /// id — nothing could be answered, so nothing is done.
    public static func decode(_ eventArgs: [Any]) -> BrowserDriverCommand? {
        guard let body = eventArgs.first as? [String: Any],
              let id = body["id"] as? String, !id.isEmpty else { return nil }
        let verbName = (body["verb"] as? String) ?? ""
        var session: BrowserDriverSession?
        if let raw = body["session"] as? [String: Any], let sessionId = raw["sessionId"] as? String, !sessionId.isEmpty {
            session = BrowserDriverSession(sessionId: sessionId, machineId: (raw["machineId"] as? String) ?? "")
        }
        return BrowserDriverCommand(id: id, verbName: verbName, verb: BrowserDriverVerb(rawValue: verbName),
                                    args: (body["args"] as? [String: Any]) ?? [:], session: session)
    }

    // The engine's own argument rules (`str`, `optStr`, `optInt` in browser-tools.ts).

    public func string(_ key: String) throws(BrowserDriverRefusal) -> String {
        guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserDriverRefusal("\(key) is required and must be a non-empty string")
        }
        return value
    }

    public func optionalString(_ key: String) throws(BrowserDriverRefusal) -> String? {
        let value = args[key]
        if value == nil || value is NSNull { return nil }
        guard let text = value as? String else { throw BrowserDriverRefusal("\(key) must be a string") }
        return text.isEmpty ? nil : text
    }

    /// Present even when empty — `type` with `value: ""` clears the field.
    public func rawString(_ key: String) -> String? { args[key] as? String }

    public func int(_ key: String, fallback: Int, min: Int, max: Int) throws(BrowserDriverRefusal) -> Int {
        let value = args[key]
        if value == nil || value is NSNull { return fallback }
        guard let number = value as? NSNumber, !(value is Bool), number.doubleValue.isFinite else {
            throw BrowserDriverRefusal("\(key) must be a number")
        }
        return Swift.min(Swift.max(Int(number.doubleValue.rounded(.towardZero)), min), max)
    }

    public func flag(_ key: String) -> Bool { (args[key] as? Bool) ?? false }
}

/// What goes back on `native-browser:result`.
public enum BrowserDriverResult {
    public static func value(_ value: [String: Any], summary: [String: Any] = [:]) -> [String: Any] {
        ["value": value, "summary": summary]
    }

    public static func error(_ sentence: String) -> [String: Any] { ["error": sentence] }
}

// MARK: - Windows

/// One window bound to a session in the engine's map.
public struct BrowserBoundWindow: Equatable, Sendable {
    public let n: Int
    public let tabID: String
    public var name: String { BrowserWindowName.name(n) }

    public init(n: Int, tabID: String) {
        self.n = n
        self.tabID = tabID
    }
}

public enum BrowserWindowName {
    /// `B2` — the engine's `slotName`.
    public static func name(_ n: Int) -> String { "B\(n)" }

    /// The number in a name said back: `B2`, `b2`, `2`, ` B2 ` (the engine's lenient reading).
    public static func number(_ said: String) -> Int? {
        var text = said.trimmingCharacters(in: .whitespaces)
        if text.first == "B" || text.first == "b" { text.removeFirst() }
        guard !text.isEmpty, text.allSatisfy(\.isASCII), let n = Int(text), n > 0 else { return nil }
        return n
    }
}

/// The engine's `browser:bindings` view: which windows each session has.
public struct BrowserBindings: Equatable, Sendable {
    public private(set) var windows: [String: [BrowserBoundWindow]] = [:]

    public init(windows: [String: [BrowserBoundWindow]] = [:]) {
        self.windows = windows
    }

    public static func key(_ session: BrowserDriverSession) -> String { "\(session.sessionId)\u{0}\(session.machineId)" }

    public func of(_ session: BrowserDriverSession) -> [BrowserBoundWindow] {
        (windows[Self.key(session)] ?? []).sorted { $0.n < $1.n }
    }

    /// `{sessions: [{sessionId, machineId, windows: [{n, browserTabId, …}]}]}`
    public static func read(_ value: Any) -> BrowserBindings {
        guard let view = value as? [String: Any], let sessions = view["sessions"] as? [Any] else { return BrowserBindings() }
        var out: [String: [BrowserBoundWindow]] = [:]
        for row in sessions {
            guard let fields = row as? [String: Any], let sessionId = fields["sessionId"] as? String, !sessionId.isEmpty else { continue }
            let session = BrowserDriverSession(sessionId: sessionId, machineId: (fields["machineId"] as? String) ?? "")
            let windows = ((fields["windows"] as? [Any]) ?? []).compactMap { raw -> BrowserBoundWindow? in
                guard let window = raw as? [String: Any], let n = (window["n"] as? NSNumber)?.intValue,
                      let tab = window["browserTabId"] as? String, !tab.isEmpty else { return nil }
                return BrowserBoundWindow(n: n, tabID: tab)
            }
            out[key(session), default: []] += windows
        }
        return BrowserBindings(windows: out)
    }
}

/// Which page a command is about.
public enum BrowserDriverTarget: Equatable, Sendable {
    /// The caller's own tab (Hoot / an AI app acting as the person).
    case own
    /// One of a session's windows.
    case window(BrowserBoundWindow, BrowserDriverSession)
    /// `browser_open` that makes a new window for this session.
    case newWindow(BrowserDriverSession)
}

/// The engine's `boundOf` rules, in its own words.
public enum BrowserDriverTargeting {
    public static let noSuchWindow =
        "that session has no window by that name. sessions.list says which windows each session has."
    public static let noSuchWindowOfItsOwn =
        "no window by that name is attached to this session. browser.open with no window opens one and " +
        "attaches it, and the person can attach one they already have from that window’s own menu."
    public static let noWindowYet =
        "no browser window is attached to this session. browser.open with no window opens one and " +
        "attaches it, and the person can attach one they already have from that window’s own menu."

    public static func resolve(_ command: BrowserDriverCommand, bindings: BrowserBindings) throws(BrowserDriverRefusal) -> BrowserDriverTarget {
        let named = try command.optionalString("window")
        let namedSession = try command.optionalString("sessionId")
        let isOpen = command.verb == .open

        if let caller = command.session {
            if let namedSession, namedSession != caller.sessionId { throw BrowserDriverRefusal(noSuchWindowOfItsOwn) }
            if isOpen && command.flag("isolate") {
                throw BrowserDriverRefusal("isolate only applies to Hoot’s own tab. A session’s window is a page in the strip and it keeps the partition it was built with.")
            }
            if isOpen, command.flag("newWindow"), named != nil {
                throw BrowserDriverRefusal("name window or newWindow, not both")
            }
            guard let named else {
                // A session's open with no window always makes one (the engine's openForSession).
                if isOpen { return .newWindow(caller) }
                guard let first = bindings.of(caller).first else { throw BrowserDriverRefusal(noWindowYet) }
                return .window(first, caller)
            }
            guard let window = find(named, in: bindings.of(caller)) else { throw BrowserDriverRefusal(noSuchWindowOfItsOwn) }
            return .window(window, caller)
        }

        if isOpen, command.flag("isolate"), named != nil || command.flag("newWindow") {
            throw BrowserDriverRefusal("isolate only applies to your own tab. A session’s window is a page the person opened, and it keeps the partition it was built with.")
        }
        if isOpen, command.flag("newWindow") {
            guard let namedSession else { throw BrowserDriverRefusal("newWindow needs the sessionId it should be attached to") }
            if named != nil { throw BrowserDriverRefusal("name window or newWindow, not both") }
            return .newWindow(BrowserDriverSession(sessionId: namedSession))
        }
        if namedSession == nil && named == nil { return .own }
        guard let namedSession, let named else { throw BrowserDriverRefusal("name sessionId and window together, or neither") }
        let session = BrowserDriverSession(sessionId: namedSession)
        guard let window = find(named, in: bindings.of(session)) else { throw BrowserDriverRefusal(noSuchWindow) }
        return .window(window, session)
    }

    static func find(_ said: String, in windows: [BrowserBoundWindow]) -> BrowserBoundWindow? {
        guard let n = BrowserWindowName.number(said) else { return nil }
        return windows.first { $0.n == n }
    }
}

// MARK: - Steps

/// The engine's limits and verbs for `browser_step` (`browser-driver.ts`).
public enum BrowserStepRules {
    public static let verbs = ["click", "type", "select", "check", "press", "submit"]
    public static let maxSelectorChars = 400
    public static let maxTypeChars = 2_000
    /// Up to this many characters are typed key by key; longer text is inserted at once.
    public static let perKeyLimit = 200
    public static let defaultTimeoutMs = 10_000
    public static let defaultOutlineTextChars = 4_000
    public static let maxOutlineTextChars = 40_000
    public static let outlineElementLimit = 60
    public static let settleMs = 15_000
    public static let handoverWindowMs = 45_000

    /// `check` with no value, or anything but "false", means checked.
    public static func wantsChecked(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return true }
        return value != "false"
    }

    /// What `browser_open` may load: http(s) with a host (the engine's `normalizeUrl`).
    public static func openableURL(_ text: String) throws(BrowserDriverRefusal) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased() else {
            throw BrowserDriverRefusal("that is not a URL: \(trimmed)")
        }
        guard scheme == "http" || scheme == "https" else {
            throw BrowserDriverRefusal("only http and https pages can be opened, not \(scheme):")
        }
        guard let host = parts.host, !host.isEmpty, let url = parts.url else {
            throw BrowserDriverRefusal("that URL has no host: \(trimmed)")
        }
        return url
    }
}

/// An element as the outline names it: a short ref (`e12`) stamped on the element
/// for the page's lifetime, or any CSS selector.
public enum BrowserElementRef {
    public static let attribute = "data-td-ref"

    /// What to look up for what the agent passed as `selector`.
    public static func selector(for said: String) -> String {
        let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
        if isRef(trimmed) { return "[\(attribute)=\"\(trimmed)\"]" }
        return trimmed
    }

    public static func isRef(_ text: String) -> Bool {
        text.count >= 2 && text.first == "e" && text.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// How a key the agent names becomes a key event in the page.
public struct BrowserKeySpec: Equatable, Sendable {
    /// The Mac's virtual key code.
    public let keyCode: UInt16
    /// The characters the key produces (AppKit's function-key characters for arrows and Delete).
    public let characters: String

    public init(keyCode: UInt16, characters: String) {
        self.keyCode = keyCode
        self.characters = characters
    }

    /// The engine's `PRESSABLE_KEYS`, mapped to the Mac's keys.
    public static let pressable: [String: BrowserKeySpec] = [
        "Enter": BrowserKeySpec(keyCode: 36, characters: "\r"),
        "Tab": BrowserKeySpec(keyCode: 48, characters: "\t"),
        "Escape": BrowserKeySpec(keyCode: 53, characters: "\u{1b}"),
        "Backspace": BrowserKeySpec(keyCode: 51, characters: "\u{7f}"),
        "Delete": BrowserKeySpec(keyCode: 117, characters: "\u{F728}"),
        "ArrowDown": BrowserKeySpec(keyCode: 125, characters: "\u{F701}"),
        "ArrowUp": BrowserKeySpec(keyCode: 126, characters: "\u{F700}"),
        "ArrowLeft": BrowserKeySpec(keyCode: 123, characters: "\u{F702}"),
        "ArrowRight": BrowserKeySpec(keyCode: 124, characters: "\u{F703}"),
    ]

    /// In the engine's order, for the refusal that lists them.
    public static let pressableNames = ["Enter", "Tab", "Escape", "Backspace", "Delete", "ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight"]

    public static func forKey(_ name: String) throws(BrowserDriverRefusal) -> BrowserKeySpec {
        guard let spec = pressable[name] else {
            throw BrowserDriverRefusal("\(name) is not a key this can press. The ones it can are: \(pressableNames.joined(separator: ", ")).")
        }
        return spec
    }
}

/// How `type` puts text into a field (after selecting what is there).
public enum BrowserTypingPlan: Equatable, Sendable {
    /// Empty value: delete what is selected.
    case clear
    /// One key event per character.
    case keys([String])
    /// Long text: inserted in one go, as a paste would be.
    case insert(String)

    public static func make(_ value: String) throws(BrowserDriverRefusal) -> BrowserTypingPlan {
        if value.isEmpty { return .clear }
        if value.count > BrowserStepRules.maxTypeChars {
            throw BrowserDriverRefusal("that is longer than the \(BrowserStepRules.maxTypeChars) characters a step will type")
        }
        if value.count <= BrowserStepRules.perKeyLimit { return .keys(value.map(String.init)) }
        return .insert(value)
    }
}

/// Where a click lands: the middle of the element, from the page's CSS pixels to
/// the web view's own points.
public enum BrowserInputGeometry {
    public static func viewPoint(cssRect: CGRect, pageZoom: Double, magnification: Double,
                                 viewHeight: Double, flipped: Bool) -> CGPoint {
        let scale = pageZoom * magnification
        let x = (cssRect.midX) * scale
        let yFromTop = (cssRect.midY) * scale
        return CGPoint(x: x.rounded(), y: (flipped ? yFromTop : viewHeight - yFromTop).rounded())
    }
}

/// The page outline `browser_read` answers with — the script's output, cleaned:
/// a secret field's value is never passed on.
public enum BrowserOutline {
    public static func clean(_ raw: Any) -> [String: Any] {
        let fields = (raw as? [String: Any]) ?? [:]
        let elements: [[String: Any]] = ((fields["elements"] as? [Any]) ?? []).compactMap { item in
            guard var element = item as? [String: Any] else { return nil }
            let type = ((element["type"] as? String) ?? "").lowercased()
            let secret = (element["secret"] as? Bool) == true || type == "password" || type == "file"
            element["secret"] = secret
            if secret { element["value"] = nil }
            return element
        }
        return [
            "url": (fields["url"] as? String) ?? "",
            "title": (fields["title"] as? String) ?? "",
            "text": (fields["text"] as? String) ?? "",
            "textTruncated": (fields["textTruncated"] as? Bool) ?? false,
            "elements": elements,
            "matched": (fields["matched"] as? NSNumber)?.intValue ?? 0,
            "truncated": (fields["truncated"] as? Bool) ?? false,
        ]
    }
}

/// What the person is asked in a handover: one line, no direction-changing
/// characters, capped (the engine's `sanitizeHandoverPrompt`).
public enum BrowserHandover {
    public static let maxPromptChars = 200
    public static let outcomes = ["resumed", "stopped", "still-waiting", "drive-ended"]

    public static func prompt(_ raw: String) -> String {
        let flat = String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar -> Unicode.Scalar in
            let v = scalar.value
            let strip = v <= 0x1f || (0x7f...0x9f).contains(v) || v == 0x200e || v == 0x200f
                || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v)
            return strip ? " " : scalar
        }))
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
        return flat.count > maxPromptChars ? String(flat.prefix(maxPromptChars)) + "\u{2026}" : flat
    }
}
