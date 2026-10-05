import Foundation

/// A command into the page: `window.tdNative.run(name)` or `window.tdNative.run(name, arg)`.
/// Only the fixed names below exist; the argument is always encoded as a JS string literal.
public struct PageCommand: Equatable, Sendable {
    public let name: String
    public let argument: String?
    /// A list argument (`native-screens`), sent as a JS array of strings.
    public let list: [String]?

    private init(_ name: String, _ argument: String? = nil, list: [String]? = nil) {
        self.name = name
        self.argument = argument
        self.list = list
    }

    // Main window
    public static let newSession = PageCommand("new-session")
    public static let openProject = PageCommand("open-project")
    public static let openSettings = PageCommand("open-settings")
    public static func select(_ id: String) -> PageCommand { PageCommand("select", id) }
    public static func closeSession(_ id: String) -> PageCommand { PageCommand("close-session", id) }
    public static func newSessionIn(_ projectPath: String) -> PageCommand { PageCommand("new-session-in", projectPath) }
    public static func closeProject(_ projectPath: String) -> PageCommand { PageCommand("close-project", projectPath) }
    public static func toggleProject(_ projectPath: String) -> PageCommand { PageCommand("toggle-project", projectPath) }

    // Tab strip
    public static let newTerminalTab = PageCommand("new-terminal-tab")
    public static let newBrowserTab = PageCommand("new-browser-tab")
    public static func selectTab(_ id: String) -> PageCommand { PageCommand("select-tab", id) }
    public static func closeTab(_ id: String) -> PageCommand { PageCommand("close-tab", id) }

    // Settings window
    public static func settingsSection(_ id: String) -> PageCommand { PageCommand("settings-section", id) }

    /// Every page: the screens the native window draws itself, so the page stops
    /// mounting them underneath.
    public static func nativeScreens(_ ids: [String]) -> PageCommand { PageCommand("native-screens", list: ids) }

    /// The exact script evaluated in the page.
    public var script: String {
        if let list {
            let items = list.map(Self.javaScriptString).joined(separator: ", ")
            return "window.tdNative && window.tdNative.run('\(name)', [\(items)])"
        }
        guard let argument else {
            return "window.tdNative && window.tdNative.run('\(name)')"
        }
        return "window.tdNative && window.tdNative.run('\(name)', \(Self.javaScriptString(argument)))"
    }

    /// A double-quoted JavaScript string literal that evaluates back to exactly `text`
    /// (paths and ids can hold quotes, backslashes, newlines, U+2028…).
    public static func javaScriptString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<": out += "\\u003C"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// Messages the page posts to the `tdNative` script message handler.
public enum PageMessage: Equatable, Sendable {
    /// The page is mounted and `window.tdNative.run` works.
    case ready
    /// Window title, plus a subtitle only when there is one that isn't the title again.
    case title(String, subtitle: String?)
    /// The whole sidebar, sent on every change.
    case sidebar(SidebarState)
    /// The tab strip for the toolbar, sent on every change.
    case tabs(TabsState)
    /// Open (or focus) the native Settings window at this same-origin relative URL.
    case openSettings(url: String, section: String?)
    /// From the Settings page: its sections and which one is showing.
    case settingsSections([SettingsSection], selected: String?)
    /// The page's own pop-out: show this screen in a window of its own.
    case openWindow(ScreenRef, title: String?)
    /// The page opened (or closed) a dialog: while open, the page comes in front of
    /// any native screen in that window.
    case pageModal(open: Bool)

    public static let handlerName = "tdNative"
    public static let maxTitleLength = 200

    /// `body` is what WebKit hands over (NSDictionary of JSON-like values).
    public static func parse(_ body: Any) -> PageMessage? {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
        switch type {
        case "ready":
            return .ready

        case "title":
            guard let raw = dict["value"] as? String else { return nil }
            let title = cleanTitle(raw)
            var subtitle = (dict["subtitle"] as? String).map(cleanTitle).flatMap(\.nonEmpty)
            if let s = subtitle, s.caseInsensitiveCompare(title) == .orderedSame { subtitle = nil }
            return .title(title, subtitle: subtitle)

        case "sidebar":
            guard let state: SidebarState = decode(dict["state"]) else { return nil }
            return .sidebar(state)

        case "tabs":
            guard let state: TabsState = decode(dict["state"]) else { return nil }
            return .tabs(state)

        case "open-settings":
            guard let url = (dict["url"] as? String)?.nonEmpty else { return nil }
            return .openSettings(url: url, section: (dict["section"] as? String)?.nonEmpty)

        case "page-modal":
            guard let open = dict["open"] as? Bool else { return nil }
            return .pageModal(open: open)

        case "open-window":
            guard let kindName = dict["kind"] as? String, let kind = ScreenRef.Kind(rawValue: kindName),
                  let id = (dict["id"] as? String)?.nonEmpty
            else { return nil }
            let title = (dict["title"] as? String).map(cleanTitle).flatMap(\.nonEmpty)
            return .openWindow(ScreenRef(kind: kind, id: id, isHoot: id == "hoot"), title: title)

        case "settings-sections":
            guard let wrapper: SectionsWrapper = decode(dict) else { return nil }
            return .settingsSections(wrapper.sections, selected: wrapper.selected)

        default:
            return nil
        }
    }

    private struct SectionsWrapper: Decodable {
        let sections: [SettingsSection]
        let selected: String?
        enum CodingKeys: String, CodingKey { case sections, selected }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sections = c.lossyArray(.sections)
            selected = c.lossyString(.selected).flatMap(\.nonEmpty)
        }
    }

    /// Re-encodes WebKit's Foundation objects as JSON and decodes them.
    /// `isValidJSONObject` first: JSONSerialization raises (crashes) on anything else.
    private static func decode<T: Decodable>(_ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func cleanTitle(_ raw: String) -> String {
        let flat = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(maxTitleLength))
    }
}

/// Where the Settings window loads: a relative URL from the page, resolved against
/// the engine's address, and refused unless it stays on the engine's own origin.
public enum SettingsLocation {
    public static func resolve(_ relative: String, engineURL: URL) -> URL? {
        guard let origin = EngineOrigin(url: engineURL),
              let url = URL(string: relative, relativeTo: engineURL)?.absoluteURL,
              origin.contains(url)
        else { return nil }
        return url
    }
}
