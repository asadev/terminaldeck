import Foundation

/// The app settings a session terminal draws with, read the way the renderer
/// reads them (`useAppSettings` → `numberSetting` / `stringSetting` / `booleanSetting`):
/// `settings:get` answers `{values: {…}}` (or a bare map from an older build),
/// `prefs:get` answers the preferences store, and the theme lives in the second.
public struct TerminalPreferences: Equatable, Sendable {
    public enum Theme: String, Sendable { case dark, light, system }

    /// Appearance → Terminal font size, 9…24, default 13.
    public var fontSize: Int
    /// Appearance → Terminal font. Empty means the app's own monospace face.
    public var fontFamily: String
    /// General → Copy on select.
    public var copyOnSelect: Bool
    /// Appearance → Theme (from the preferences store).
    public var theme: Theme
    /// The pinned scheme, or nil to follow the app's light/dark.
    public var pinnedScheme: TerminalScheme?

    public static let defaultFontSize = 13
    public static let minFontSize = 9
    public static let maxFontSize = 24

    public static let fontSizeKey = "appearance.terminalFontSize"
    public static let fontFamilyKey = "appearance.terminalFontFamily"
    public static let copyOnSelectKey = "general.copyOnSelect"
    public static let themeKey = "appearance.theme"
    /// The preferences store's own key for the theme.
    public static let themePrefsKey = "theme"

    public init(fontSize: Int = TerminalPreferences.defaultFontSize, fontFamily: String = "",
                copyOnSelect: Bool = false, theme: Theme = .dark, pinnedScheme: TerminalScheme? = nil) {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.copyOnSelect = copyOnSelect
        self.theme = theme
        self.pinnedScheme = pinnedScheme
    }

    /// From the two stores' answers. Anything missing or malformed keeps its default.
    public static func from(settings: Any?, prefs: Any?) -> TerminalPreferences {
        let values = storedValues(settings)
        let preferences = prefs as? [String: Any] ?? [:]
        var out = TerminalPreferences()
        if let number = TerminalJSON.number(values[fontSizeKey]) { out.fontSize = clampFontSize(number) }
        if let family = values[fontFamilyKey] as? String { out.fontFamily = String(family.prefix(500)) }
        if let flag = TerminalJSON.bool(values[copyOnSelectKey]) { out.copyOnSelect = flag }
        let theme = (preferences[themePrefsKey] as? String).flatMap(Theme.init(rawValue:))
            ?? (values[themeKey] as? String).flatMap(Theme.init(rawValue:))
        out.theme = theme ?? .dark
        out.pinnedScheme = TerminalSchemes.pinned(in: values)
        return out
    }

    /// `toStoredSettings`: the envelope's `values`, or a bare map.
    public static func storedValues(_ raw: Any?) -> [String: Any] {
        guard let record = raw as? [String: Any] else { return [:] }
        return record["values"] as? [String: Any] ?? record
    }

    /// `coerce` for the number kind: clamped to 9…24, whole steps.
    public static func clampFontSize(_ value: Double) -> Int {
        guard value.isFinite else { return defaultFontSize }
        let clamped = min(Double(maxFontSize), max(Double(minFontSize), value))
        return Int((clamped - Double(minFontSize)).rounded()) + minFontSize
    }

    /// Whether the app is dark right now: the theme, or the system's when it is "system".
    public func isDark(systemIsDark: Bool) -> Bool {
        switch theme {
        case .dark: return true
        case .light: return false
        case .system: return systemIsDark
        }
    }

    /// What the terminal paints: the pinned scheme, or the app's own for its light/dark.
    public func scheme(systemIsDark: Bool) -> TerminalScheme {
        pinnedScheme ?? TerminalSchemes.app(dark: isDark(systemIsDark: systemIsDark))
    }

    /// The font names to try, in order, from a CSS-style family list ("JetBrains Mono, Menlo").
    /// Empty means the app's own monospace face.
    public var fontCandidates: [String] {
        fontFamily.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && !["monospace", "ui-monospace", "system-ui"].contains($0.lowercased()) }
    }
}
