import Foundation

// The terminal's colours, chosen the way the web terminal chooses them
// (src/renderer/terminal-scheme.ts + src/shared/terminal-theme.ts):
//
//  - `appearance.terminalScheme` unset, empty or "follow-app" → the app's own
//    light or dark scheme ("Deck Dark" / "Deck Light"), following the theme.
//  - a built-in id → that scheme, whatever the app's light/dark is.
//  - a custom id → the person's own scheme, stored as JSON under
//    `appearance.terminalScheme.custom.<id>`; customs win an id collision.
//  - an id that no longer exists → back to following the app.

/// One colour scheme: the surface, the marks on it, and the sixteen ANSI colours.
public struct TerminalScheme: Equatable, Sendable {
    public let id: String
    public let name: String
    public let background: String
    public let foreground: String
    public let cursor: String
    public let cursorAccent: String
    public let selectionBackground: String
    /// black, red, green, yellow, blue, magenta, cyan, white, then the eight bright ones.
    public let ansi: [String]

    public init(id: String, name: String, background: String, foreground: String, cursor: String,
                cursorAccent: String, selectionBackground: String, ansi: [String]) {
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.cursorAccent = cursorAccent
        self.selectionBackground = selectionBackground
        self.ansi = ansi
    }

    /// The JSON keys of the sixteen, in wire order.
    public static let ansiSlots = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "brightBlack", "brightRed", "brightGreen", "brightYellow",
        "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
    ]

    /// Whether the ground is light (relative luminance above one half), as `isLightScheme`.
    public var isLight: Bool {
        guard let colour = TerminalColour(hex: background) else { return false }
        return colour.relativeLuminance > 0.5
    }
}

/// A colour from a scheme: `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`.
public struct TerminalColour: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex: String) {
        guard let normalised = Self.normalise(hex) else { return nil }
        let digits = Array(normalised.dropFirst())
        func channel(_ at: Int) -> Double {
            Double(Int(String(digits[at...(at + 1)]), radix: 16) ?? 0) / 255
        }
        self.init(red: channel(0), green: channel(2), blue: channel(4),
                  alpha: digits.count == 8 ? channel(6) : 1)
    }

    /// `normaliseColour`: lower-cased, `#rgb`/`#rgba` expanded; nil for anything that is not hex.
    public static func normalise(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.hasPrefix("#") else { return nil }
        let digits = text.dropFirst()
        guard [3, 4, 6, 8].contains(digits.count),
              digits.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        if digits.count == 3 || digits.count == 4 {
            return "#" + digits.map { "\($0)\($0)" }.joined()
        }
        return text
    }

    /// WCAG relative luminance of the opaque part.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

public enum TerminalSchemes {
    /// The settings key holding the chosen scheme id.
    public static let settingKey = "appearance.terminalScheme"
    /// Every custom scheme is a key under this prefix.
    public static let customPrefix = "appearance.terminalScheme.custom."
    /// The id that means "follow the app's own light/dark".
    public static let followApp = "follow-app"

    /// The app's own scheme for its light or dark theme.
    public static func app(dark: Bool) -> TerminalScheme {
        builtins[dark ? 0 : 1]
    }

    /// The scheme a settings map pins, or nil for "follow the app".
    public static func pinned(in values: [String: Any]) -> TerminalScheme? {
        guard let chosen = values[settingKey] as? String, !chosen.isEmpty, chosen != followApp else { return nil }
        if let custom = customs(in: values).first(where: { $0.id == chosen }) { return custom }
        return builtins.first { $0.id == chosen }
    }

    /// The person's own schemes. Anything unreadable under the prefix is skipped.
    public static func customs(in values: [String: Any]) -> [TerminalScheme] {
        var out: [TerminalScheme] = []
        for (key, value) in values where key.hasPrefix(customPrefix) {
            let id = String(key.dropFirst(customPrefix.count))
            guard !id.isEmpty, let text = value as? String, !text.isEmpty,
                  let data = text.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let scheme = scheme(id: id, from: raw) else { continue }
            out.append(scheme)
        }
        return out.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Every colour present and legal, and a name — nothing else is a scheme (`isTerminalScheme`).
    static func scheme(id: String, from raw: [String: Any]) -> TerminalScheme? {
        guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
        func colour(_ slot: String) -> String? { (raw[slot] as? String).flatMap(TerminalColour.normalise) }
        guard let background = colour("background"), let foreground = colour("foreground"),
              let cursor = colour("cursor"), let cursorAccent = colour("cursorAccent"),
              let selection = colour("selectionBackground") else { return nil }
        var ansi: [String] = []
        for slot in TerminalScheme.ansiSlots {
            guard let value = colour(slot) else { return nil }
            ansi.append(value)
        }
        return TerminalScheme(id: id, name: name, background: background, foreground: foreground, cursor: cursor,
                              cursorAccent: cursorAccent, selectionBackground: selection, ansi: ansi)
    }

    /// Everything the app ships, in the picker's order (generated from `BUILTIN_SCHEMES`).
    public static let builtins: [TerminalScheme] = [
        TerminalScheme(
            id: "deck-dark", name: "Deck Dark",
            background: "#191919", foreground: "#ededed", cursor: "#3b8fee", cursorAccent: "#191919", selectionBackground: "#3b8fee29",
            ansi: ["#2e3436", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
                   "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec"]),
        TerminalScheme(
            id: "deck-light", name: "Deck Light",
            background: "#e8e8e8", foreground: "#141414", cursor: "#1a66c4", cursorAccent: "#e8e8e8", selectionBackground: "#1a66c41a",
            ansi: ["#2e3436", "#cc0000", "#3b7405", "#7c6500", "#3465a4", "#75507b", "#057375", "#d3d7cf",
                   "#555753", "#951a1a", "#335413", "#534d1a", "#384e65", "#5d445b", "#135454", "#eeeeec"]),
        TerminalScheme(
            id: "pure-black", name: "Pure Black",
            background: "#000000", foreground: "#ededed", cursor: "#3b8fee", cursorAccent: "#000000", selectionBackground: "#3b8fee3d",
            ansi: ["#2e3436", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
                   "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec"]),
        TerminalScheme(
            id: "dark-grey", name: "Dark Grey",
            background: "#262626", foreground: "#ededed", cursor: "#3b8fee", cursorAccent: "#262626", selectionBackground: "#3b8fee33",
            ansi: ["#2e3436", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
                   "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec"]),
        TerminalScheme(
            id: "solarized-dark", name: "Solarized Dark",
            background: "#002b36", foreground: "#839496", cursor: "#93a1a1", cursorAccent: "#002b36", selectionBackground: "#073642",
            ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                   "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        TerminalScheme(
            id: "solarized-light", name: "Solarized Light",
            background: "#fdf6e3", foreground: "#657b83", cursor: "#586e75", cursorAccent: "#fdf6e3", selectionBackground: "#eee8d5",
            ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                   "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        TerminalScheme(
            id: "nord", name: "Nord",
            background: "#2e3440", foreground: "#d8dee9", cursor: "#d8dee9", cursorAccent: "#2e3440", selectionBackground: "#434c5e",
            ansi: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                   "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]),
        TerminalScheme(
            id: "dracula", name: "Dracula",
            background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2", cursorAccent: "#282a36", selectionBackground: "#44475a",
            ansi: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                   "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),
        TerminalScheme(
            id: "gruvbox-dark", name: "Gruvbox Dark",
            background: "#282828", foreground: "#ebdbb2", cursor: "#ebdbb2", cursorAccent: "#282828", selectionBackground: "#504945",
            ansi: ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
                   "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]),
        TerminalScheme(
            id: "one-half-dark", name: "One Half Dark",
            background: "#282c34", foreground: "#dcdfe4", cursor: "#dcdfe4", cursorAccent: "#282c34", selectionBackground: "#474e5d",
            ansi: ["#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#dcdfe4",
                   "#5a6374", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#dcdfe4"]),
        TerminalScheme(
            id: "one-half-light", name: "One Half Light",
            background: "#fafafa", foreground: "#383a42", cursor: "#383a42", cursorAccent: "#fafafa", selectionBackground: "#bfceff",
            ansi: ["#383a42", "#e45649", "#50a14f", "#c18301", "#0184bc", "#a626a4", "#0997b3", "#fafafa",
                   "#4f525d", "#df6c75", "#98c379", "#e4c07a", "#61afef", "#c577dd", "#56b5c1", "#ffffff"]),
        TerminalScheme(
            id: "tango", name: "Tango Dark",
            background: "#000000", foreground: "#d3d7cf", cursor: "#ffffff", cursorAccent: "#000000", selectionBackground: "#ffffff40",
            ansi: ["#000000", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
                   "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec"]),
        TerminalScheme(
            id: "campbell", name: "Campbell",
            background: "#0c0c0c", foreground: "#cccccc", cursor: "#ffffff", cursorAccent: "#0c0c0c", selectionBackground: "#ffffff40",
            ansi: ["#0c0c0c", "#c50f1f", "#13a10e", "#c19c00", "#0037da", "#881798", "#3a96dd", "#cccccc",
                   "#767676", "#e74856", "#16c60c", "#f9f1a5", "#3b78ff", "#b4009e", "#61d6d6", "#f2f2f2"]),
    ]
}
