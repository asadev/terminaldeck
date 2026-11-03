import Foundation

// The app's keyboard shortcuts, ported one-to-one from src/renderer/keymap.ts:
// the same table (ids, keys, labels, scopes, groups), the same chord grammar and
// the same Mac/PC formatting. KeymapTests checks the table against keymap.ts itself,
// so the two cannot drift.

public enum KeyScope: String, CaseIterable, Sendable {
    case global, terminal, modal

    /// SCOPE_TITLES
    public var title: String {
        switch self {
        case .global: "Anywhere"
        case .terminal: "In a session"
        case .modal: "In a dialog"
        }
    }

    /// SCOPE_HINTS
    public var hint: String {
        switch self {
        case .global: "Works wherever you are in the app."
        case .terminal: "Claimed while a terminal has focus. Everything else reaches the agent."
        case .modal: "While a dialog or panel is open, it owns the keyboard."
        }
    }
}

public struct Chord: Equatable, Sendable {
    public var mod = false
    public var ctrl = false
    public var alt = false
    public var shift = false
    public var key: String

    public init(mod: Bool = false, ctrl: Bool = false, alt: Bool = false, shift: Bool = false, key: String) {
        self.mod = mod; self.ctrl = ctrl; self.alt = alt; self.shift = shift; self.key = key
    }

    /// parseChord: "mod+shift+k" → Chord. A modifier twice, or two keys, is nil.
    public static func parse(_ text: String) -> Chord? {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if parts.isEmpty { return text.trimmingCharacters(in: .whitespaces) == "+" ? Chord(key: "+") : nil }
        var chord = Chord(key: "")
        for part in parts {
            switch part {
            case "mod", "cmd", "meta":
                if chord.mod { return nil }
                chord.mod = true
            case "ctrl", "control":
                if chord.ctrl { return nil }
                chord.ctrl = true
            case "alt", "option", "opt":
                if chord.alt { return nil }
                chord.alt = true
            case "shift":
                if chord.shift { return nil }
                chord.shift = true
            default:
                if !chord.key.isEmpty { return nil }
                chord.key = part
            }
        }
        return chord.key.isEmpty ? nil : chord
    }

    /// chordToString
    public var text: String {
        var parts: [String] = []
        if mod { parts.append("mod") }
        if ctrl { parts.append("ctrl") }
        if alt { parts.append("alt") }
        if shift { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    private static let macKeyGlyphs: [String: String] = [
        "enter": "↩", "escape": "Esc", "tab": "⇥", "backspace": "⌫", "delete": "⌦",
        "up": "↑", "down": "↓", "left": "←", "right": "→", "space": "Space",
        "pageup": "⇞", "pagedown": "⇟", "home": "↖", "end": "↘",
    ]
    private static let pcKeyNames: [String: String] = [
        "enter": "Enter", "escape": "Esc", "tab": "Tab", "backspace": "Backspace", "delete": "Del",
        "up": "↑", "down": "↓", "left": "←", "right": "→", "space": "Space",
        "pageup": "PgUp", "pagedown": "PgDn", "home": "Home", "end": "End",
    ]

    /// keyLabel
    static func keyLabel(_ key: String, mac: Bool) -> String {
        if let named = (mac ? macKeyGlyphs : pcKeyNames)[key] { return named }
        if key.range(of: #"^f([1-9]|1[0-2])$"#, options: .regularExpression) != nil { return key.uppercased() }
        return key.count == 1 ? key.uppercased() : key
    }

    /// formatChord: "⌘⇧K" on a Mac, "Ctrl+Shift+K" elsewhere.
    public func formatted(mac: Bool = true) -> String {
        var modifiers: [String] = []
        func push(_ macSymbol: String, _ pcName: String) {
            let label = mac ? macSymbol : pcName
            if !modifiers.contains(label) { modifiers.append(label) }
        }
        if mod { push("⌘", "Ctrl") }
        if ctrl { push("⌃", "Ctrl") }
        if alt { push("⌥", "Alt") }
        if shift { push("⇧", "Shift") }
        let parts = modifiers + [Self.keyLabel(key, mac: mac)]
        return mac ? parts.joined() : parts.joined(separator: "+")
    }
}

public struct KeyBinding: Equatable, Identifiable, Sendable {
    public let id: String
    public let keys: [String]
    public let label: String
    public let scope: KeyScope
    public let group: String
    /// Passed through to the terminal rather than claimed by the app.
    public let passthrough: Bool
    /// "range": shown as one entry (⌘1–9).
    public let collapseRange: Bool

    public init(_ id: String, _ keys: [String], _ label: String, _ scope: KeyScope, _ group: String,
                passthrough: Bool = false, collapseRange: Bool = false) {
        self.id = id; self.keys = keys; self.label = label; self.scope = scope; self.group = group
        self.passthrough = passthrough; self.collapseRange = collapseRange
    }

    /// formatBinding
    public func formatted(mac: Bool = true) -> [String] {
        if collapseRange, keys.count > 1, let first = Chord.parse(keys[0]), let last = Chord.parse(keys[keys.count - 1]) {
            return ["\(first.formatted(mac: mac))–\(Chord.keyLabel(last.key, mac: mac))"]
        }
        var seen: [String] = []
        for key in keys {
            guard let chord = Chord.parse(key) else { continue }
            let text = chord.formatted(mac: mac)
            if !text.isEmpty, !seen.contains(text) { seen.append(text) }
        }
        return seen
    }
}

public struct KeymapGroup: Equatable, Sendable {
    public let scope: KeyScope
    public let title: String
    public let hint: String
    public let bindings: [KeyBinding]
}

public enum Keymap {
    /// KEYMAP, in the same order.
    public static let all: [KeyBinding] = [
        KeyBinding("session.new", ["mod+t"], "New session", .global, "Sessions"),
        KeyBinding("session.resume", ["mod+shift+r"], "Resume the last session here", .global, "Sessions"),
        KeyBinding("session.close", ["mod+w"], "Delete session", .global, "Sessions"),
        KeyBinding("session.newDialog", ["mod+shift+t"], "New session, with options", .global, "Sessions"),
        KeyBinding("session.jump", (1...9).map { "mod+\($0)" }, "Jump to an open session", .global, "Sessions", collapseRange: true),
        KeyBinding("session.next", ["ctrl+tab"], "Next session", .global, "Sessions"),
        KeyBinding("session.previous", ["ctrl+shift+tab"], "Previous session", .global, "Sessions"),
        KeyBinding("project.open", ["mod+o"], "Open a project", .global, "Project"),
        KeyBinding("palette.quickOpen", ["mod+p", "mod+shift+o"], "Quick open a file", .global, "Project"),
        KeyBinding("palette.commands", ["mod+k", "mod+shift+p"], "Command palette", .global, "Project"),
        KeyBinding("view.dashboard", ["mod+shift+d"], "Project dashboard", .global, "Panels"),
        KeyBinding("view.files", ["mod+shift+e"], "Files", .global, "Panels"),
        KeyBinding("view.git", ["mod+shift+g"], "Source control", .global, "Panels"),
        KeyBinding("view.search", ["mod+shift+f"], "Search past sessions", .global, "Panels"),
        KeyBinding("view.artifacts", ["mod+shift+a"], "Artifacts", .global, "Panels"),
        KeyBinding("view.inspector", ["mod+shift+i"], "Session inspector", .global, "Panels"),
        KeyBinding("view.swarm", ["mod+\\"], "Swarm view", .global, "Panels"),
        KeyBinding("view.sidebar", ["mod+b"], "Toggle the sidebar", .global, "Panels"),
        KeyBinding("pane.split", ["mod+d"], "Split the window", .global, "Panes"),
        KeyBinding("pane.focusLeft", ["mod+alt+left"], "Focus the pane to the left", .global, "Panes"),
        KeyBinding("pane.focusRight", ["mod+alt+right"], "Focus the pane to the right", .global, "Panes"),
        KeyBinding("app.preferences", ["mod+,"], "Settings", .global, "App"),
        KeyBinding("app.shortcuts", ["mod+/"], "Keyboard shortcuts", .global, "App"),
        KeyBinding("terminal.find", ["mod+f"], "Find in the terminal", .terminal, "Terminal"),
        KeyBinding("terminal.clear", ["mod+shift+k"], "Clear the terminal", .terminal, "Terminal"),
        KeyBinding("terminal.copy", ["mod+shift+c"], "Copy the selection", .terminal, "Terminal"),
        KeyBinding("terminal.interrupt", ["ctrl+c"], "Interrupt the agent", .terminal, "Terminal", passthrough: true),
        KeyBinding("terminal.escape", ["escape"], "Stop what the agent is doing", .terminal, "Terminal", passthrough: true),
        KeyBinding("modal.close", ["escape"], "Close", .modal, "Dialogs"),
        KeyBinding("modal.confirm", ["mod+enter"], "Confirm", .modal, "Dialogs"),
        KeyBinding("modal.next", ["down"], "Next item", .modal, "Dialogs"),
        KeyBinding("modal.previous", ["up"], "Previous item", .modal, "Dialogs"),
    ]

    /// groupedKeymap: Anywhere, In a session, In a dialog — empty scopes left out.
    public static func grouped(_ bindings: [KeyBinding] = all) -> [KeymapGroup] {
        KeyScope.allCases.compactMap { scope in
            let inScope = bindings.filter { $0.scope == scope }
            return inScope.isEmpty ? nil : KeymapGroup(scope: scope, title: scope.title, hint: scope.hint, bindings: inScope)
        }
    }

    /// searchKeymap: every term must appear in the label, group, id, shown chord or raw keys.
    public static func search(_ query: String, in bindings: [KeyBinding] = all, mac: Bool = true) -> [KeyBinding] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if terms.isEmpty { return bindings }
        return bindings.filter { binding in
            let haystack = ([binding.label, binding.group, binding.id] + binding.formatted(mac: mac) + binding.keys)
                .joined(separator: " ").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    /// chordFor: the first shown chord for a command, never a passthrough one.
    public static func chord(for id: String, mac: Bool = true) -> String? {
        guard let binding = all.first(where: { $0.id == id && !$0.passthrough }) else { return nil }
        return binding.formatted(mac: mac).first
    }

    /// tip: "Settings (⌘,)".
    public static func tip(_ label: String, _ id: String, mac: Bool = true) -> String {
        chord(for: id, mac: mac).map { "\(label) (\($0))" } ?? label
    }
}

// MARK: Shortcuts that belong to a feature (features/registry.ts)

/// The keymap commands a feature owns; when that feature is off or uninstalled its
/// chords are not offered (useLiveBindings / features.commandOn). Both default on.
public enum FeatureCommands {
    public static let owners: [(feature: String, defaultOn: Bool, commands: [String])] = [
        ("split", true, ["pane.split", "pane.focusLeft", "pane.focusRight", "pane.close"]),
        ("swarm", true, ["view.swarm"]),
    ]

    /// From the page's stored feature state (`features.v2`: { id: 'on' | 'off' | 'uninstalled' }).
    public static func hidden(featureState: [String: Any]) -> Set<String> {
        var out = Set<String>()
        for owner in owners {
            let stored = featureState[owner.feature] as? String
            let status = ["on", "off", "uninstalled"].contains(stored ?? "") ? stored! : (owner.defaultOn ? "on" : "uninstalled")
            if status != "on" { out.formUnion(owner.commands) }
        }
        return out
    }
}

extension Keymap {
    /// What the shortcuts sheet lists: every binding whose feature is on.
    public static func live(hidden: Set<String>) -> [KeyBinding] { all.filter { !hidden.contains($0.id) } }

    /// The sheet's count: "12" or "3 of 12" while searching.
    public static func countLabel(query: String, matches: Int, live: Int) -> String {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? "\(live)" : "\(matches) of \(live)"
    }

    /// The sheet's empty line.
    public static func emptyLabel(query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? "No shortcuts to show." : "Nothing matches “\(q)”."
    }
}

// MARK: - Resolving a key press (keymap.ts resolveCommand, for keys a native view gets)

/// One key press: keymap.ts `KeyLike`, already reduced to its token.
public struct KeyStroke: Equatable, Sendable {
    public var key: String
    public var meta = false
    public var ctrl = false
    public var alt = false
    public var shift = false

    public init(key: String, meta: Bool = false, ctrl: Bool = false, alt: Bool = false, shift: Bool = false) {
        self.key = key
        self.meta = meta
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
    }
}

extension Keymap {
    /// `stealsFromTerminal`: function keys, a modified Tab, and on a Mac any ⌘ chord.
    public static func stealsFromTerminal(_ chord: Chord, isMac: Bool = true) -> Bool {
        if isFunctionKey(chord.key) { return true }
        if chord.key == "tab" && (chord.mod || chord.ctrl || chord.alt) { return true }
        if isMac { return chord.mod }
        if !chord.mod && !chord.ctrl { return false }
        return chord.shift || chord.alt
    }

    /// `bindingsInScope`.
    public static func bindings(in scope: KeyScope, isMac: Bool = true, from bindings: [KeyBinding] = all) -> [KeyBinding] {
        if scope == .modal { return bindings.filter { $0.scope == .modal && !$0.passthrough } }
        return bindings.filter { binding in
            if binding.passthrough || binding.scope == .modal { return false }
            if binding.scope == .terminal { return scope == .terminal }
            if scope != .terminal { return true }
            return binding.keys.contains { Chord.parse($0).map { stealsFromTerminal($0, isMac: isMac) } ?? false }
        }
    }

    /// `chordMatches`: ⌘ is "mod" on a Mac, Ctrl elsewhere.
    public static func matches(_ chord: Chord, _ press: KeyStroke, isMac: Bool = true) -> Bool {
        let meta = isMac ? chord.mod : false
        let ctrl = isMac ? chord.ctrl : (chord.mod || chord.ctrl)
        return meta == press.meta && ctrl == press.ctrl && chord.alt == press.alt && chord.shift == press.shift
            && chord.key == press.key
    }

    /// `resolveCommand`: the binding a press runs in `scope`, first match in table order.
    public static func resolve(_ press: KeyStroke, scope: KeyScope, isMac: Bool = true, from bindings: [KeyBinding] = all) -> KeyBinding? {
        for binding in Self.bindings(in: scope, isMac: isMac, from: bindings) {
            for text in binding.keys {
                guard let chord = Chord.parse(text) else { continue }
                if scope == .terminal && binding.scope == .global && !stealsFromTerminal(chord, isMac: isMac) { continue }
                if matches(chord, press, isMac: isMac) { return binding }
            }
        }
        return nil
    }

    /// ⌘1–9 (the page reads the digit itself, since the keymap lists it as a range).
    public static func tabDigit(_ press: KeyStroke) -> Int? {
        guard press.meta || press.ctrl, !press.shift, !press.alt, let digit = Int(press.key), (1...9).contains(digit) else { return nil }
        return digit
    }

    static func isFunctionKey(_ key: String) -> Bool {
        guard key.hasPrefix("f"), let n = Int(key.dropFirst()) else { return false }
        return (1...12).contains(n) && key == "f\(n)"
    }

    /// `keyToken` from a Mac key code (the position, like `event.code`) and the
    /// characters typed without modifiers. Letters and digits come from the
    /// characters, so other layouts keep their own letters; with ⌥ or ⇧ turning
    /// them into something else, the key's position decides.
    public static func token(keyCode: UInt16, characters: String?) -> String {
        if let named = namedKeyCodes[keyCode] { return named }
        let raw = (characters ?? "").lowercased()
        if raw.count == 1, let scalar = raw.unicodeScalars.first,
           ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) { return raw }
        if let positional = positionKeyCodes[keyCode] { return positional }
        return raw
    }

    static let namedKeyCodes: [UInt16: String] = [
        53: "escape", 36: "enter", 76: "enter", 48: "tab", 51: "backspace", 117: "delete",
        126: "up", 125: "down", 123: "left", 124: "right", 115: "home", 119: "end",
        116: "pageup", 121: "pagedown", 49: "space",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    static let positionKeyCodes: [UInt16: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j", 40: "k", 37: "l", 46: "m",
        45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        44: "/", 42: "\\", 43: ",", 47: ".", 41: ";", 39: "'", 33: "[", 30: "]", 50: "`", 27: "-", 24: "=",
    ]
}
