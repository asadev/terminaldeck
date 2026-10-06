import Foundation

// The settings table (`renderer/settings/settings-schema.ts`), for the native
// Settings sections: every setting, where it is stored, its control, its
// default, and the rules that read a stored value back (coerce, old names,
// preferences over the settings file). Generated from the web table and kept
// in its order, so a section lists its rows exactly as the page does.

public struct SettingOption: Equatable, Sendable, Identifiable {
    public var value: String
    public var label: String
    public var help: String?
    public var id: String { value }

    public init(value: String, label: String, help: String? = nil) {
        self.value = value
        self.label = label
        self.help = help
    }
}

public struct SettingNumberRange: Equatable, Sendable {
    public var min: Double
    public var max: Double
    public var step: Double
    public var unit: String?

    public init(min: Double, max: Double, step: Double, unit: String?) {
        self.min = min
        self.max = max
        self.step = step
        self.unit = unit
    }
}

public struct SettingDefinition: Equatable, Sendable, Identifiable {
    public enum Store: String, Equatable, Sendable { case prefs, extra }
    public enum Kind: String, Equatable, Sendable { case toggle, select, number, text }

    public var id: String
    public var section: String
    public var label: String
    public var help: String
    public var more: String?
    public var store: Store
    public var prefsKey: String?
    public var kind: Kind
    public var defaultValue: CodingAIJSON
    public var options: [SettingOption]
    public var number: SettingNumberRange?
    public var placeholder: String?
    public var emptyMeans: String?

    public init(id: String, section: String, label: String, help: String, more: String? = nil, store: Store,
                prefsKey: String? = nil, kind: Kind, defaultValue: CodingAIJSON, options: [SettingOption] = [],
                number: SettingNumberRange? = nil, placeholder: String? = nil, emptyMeans: String? = nil) {
        self.id = id
        self.section = section
        self.label = label
        self.help = help
        self.more = more
        self.store = store
        self.prefsKey = prefsKey
        self.kind = kind
        self.defaultValue = defaultValue
        self.options = options
        self.number = number
        self.placeholder = placeholder
        self.emptyMeans = emptyMeans
    }
}

/// One rail entry: its id, its name, and the line under its heading.
public struct SettingsSectionInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var blurb: String
}

public enum SettingsSchema {
    public static let all: [SettingDefinition] = [
        SettingDefinition(id: "general.restoreSessions",
            section: "general",
            label: "Pick up where you left off",
            help: "Reopens the projects and sessions you had open, continuing each conversation.",
            more: "Rather than starting each one over. A session whose folder or conversation is gone opens clean instead of failing.",
            store: .prefs,
            prefsKey: "restoreSessions",
            kind: .toggle,
            defaultValue: .bool(true)),
        SettingDefinition(id: "general.autoNameSessions",
            section: "general",
            label: "Name sessions from the conversation",
            help: "A tab takes the conversation’s title once it has one.",
            more: "Until then it keeps the folder name. Renaming a tab yourself always wins — this only fills in a name nobody has chosen.",
            store: .extra,
            kind: .toggle,
            defaultValue: .bool(true)),
        SettingDefinition(id: "general.confirmCloseWorking",
            section: "general",
            label: "Confirm before deleting a session",
            help: "Deleting a session, or the sessions in a project, asks first.",
            more: "The confirmation says what is at stake: a session mid-task loses that work, one that has already ended loses only its scrollback. Off, it goes straight away.",
            store: .extra,
            kind: .toggle,
            defaultValue: .bool(true)),
        SettingDefinition(id: "general.copyOnSelect",
            section: "general",
            label: "Copy on select",
            help: "Selecting text in a session copies it.",
            more: "The way a Unix terminal does. It applies to session terminals only, not to the chat box.",
            store: .extra,
            kind: .toggle,
            defaultValue: .bool(false)),
        SettingDefinition(id: "appearance.theme",
            section: "appearance",
            label: "Theme",
            help: "Dark, light, or whatever the desktop is set to.",
            store: .prefs,
            prefsKey: "theme",
            kind: .select,
            defaultValue: .string("dark"),
            options: [.init(value: "dark", label: "Dark"), .init(value: "light", label: "Light"), .init(value: "system", label: "System")]),
        SettingDefinition(id: "appearance.density",
            section: "appearance",
            label: "Density",
            help: "Compact tightens rows and spacing.",
            more: "The text size does not change with it — only the space around it.",
            store: .extra,
            kind: .select,
            defaultValue: .string("comfortable"),
            options: [.init(value: "comfortable", label: "Comfortable"), .init(value: "compact", label: "Compact")]),
        SettingDefinition(id: "appearance.terminalScheme",
            section: "appearance",
            label: "Terminal colours",
            help: "The colour scheme every session is drawn in.",
            more: "Pick one of the schemes, or edit any colour to make your own. Editing a scheme that came with the app makes you a copy of it rather than changing it for everybody.",
            store: .extra,
            kind: .text,
            defaultValue: .string("follow-app")),
        SettingDefinition(id: "appearance.terminalFontSize",
            section: "appearance",
            label: "Terminal font size",
            help: "Applies to every session terminal.",
            store: .extra,
            kind: .number,
            defaultValue: .number(13),
            number: .init(min: 9, max: 24, step: 1, unit: "px")),
        SettingDefinition(id: "appearance.terminalFontFamily",
            section: "appearance",
            label: "Terminal font",
            help: "A font family name, exactly as your system spells it.",
            store: .extra,
            kind: .text,
            defaultValue: .string(""),
            placeholder: "SF Mono",
            emptyMeans: "Leave empty to use the app's own monospace font."),
        SettingDefinition(id: "notifications.onNeedsInput",
            section: "notifications",
            label: "Tell me when a session needs me",
            help: "A banner when a session is waiting on you.",
            more: "A permission prompt, or a question the agent has asked. This is the one worth leaving on: a session waiting on an answer is a session doing nothing.",
            store: .extra,
            kind: .toggle,
            defaultValue: .bool(true)),
        SettingDefinition(id: "notifications.onComplete",
            section: "notifications",
            label: "Tell me when a session finishes",
            help: "A banner the moment an agent stops working.",
            store: .prefs,
            prefsKey: "notifyOnComplete",
            kind: .toggle,
            defaultValue: .bool(true)),
        SettingDefinition(id: "notifications.showInsightAlerts",
            section: "notifications",
            label: "Raise insight alerts",
            help: "What the Alerts panel notices on its own.",
            more: "A session filling its context window, a tool failing repeatedly, work that has stalled. These appear in the Alerts panel rather than as desktop banners.",
            store: .extra,
            kind: .toggle,
            defaultValue: .bool(true)),
        SettingDefinition(id: "notifications.onFinishSound",
            section: "notifications",
            label: "Play a sound when a session finishes",
            help: "A short sound the moment an agent stops working.",
            more: "Independent of the banner above: you can have the sound without the banner, or the banner without the sound.",
            store: .extra,
            kind: .toggle,
            defaultValue: .bool(false)),
        SettingDefinition(id: "notifications.soundName",
            section: "notifications",
            label: "Sound",
            help: "Which sound a finished session plays.",
            more: "Synthesised by the app — nothing is downloaded, and nothing is read from your sound library.",
            store: .extra,
            kind: .select,
            defaultValue: .string("chime"),
            options: [.init(value: "chime", label: "Chime", help: "Two soft notes."), .init(value: "blip", label: "Blip", help: "One short tone."), .init(value: "knock", label: "Knock", help: "Low and dull.")]),
        SettingDefinition(id: "notifications.onlyWhenUnfocused",
            section: "notifications",
            label: "Only when the app is in the background",
            help: "Off also banners a tab you are not looking at.",
            more: "While the window itself is in front. On, nothing interrupts you while you are already looking at the app.",
            store: .extra,
            kind: .toggle,
            defaultValue: .bool(true)),
        SettingDefinition(id: "agents.defaultProvider",
            section: "agents",
            label: "Default coding tool",
            help: "Runs when you start a session.",
            more: "Unless the project or the new-session dialog says otherwise. A tool that is not on your PATH is greyed out here rather than offered and then failing to start.",
            store: .prefs,
            prefsKey: "defaultProvider",
            kind: .select,
            defaultValue: .string("claude"),
            options: [.init(value: "claude", label: "Claude Code"), .init(value: "codex", label: "Codex CLI"), .init(value: "gemini", label: "Gemini CLI"), .init(value: "shell", label: "Plain shell")]),
        SettingDefinition(id: "browser.startUrl",
            section: "browser",
            label: "Start page",
            help: "Type an address, or leave it empty for the page that lists what is running here.",
            store: .extra,
            kind: .text,
            defaultValue: .string(""),
            placeholder: "http://localhost:3000"),
        SettingDefinition(id: "browser.persistSession",
            section: "browser",
            label: "Keep cookies and logins between runs",
            help: "Off signs the browser tab out every time you quit.",
            more: "It clears the browser tab’s cookies and storage on quit, so every run starts signed out of everything.",
            store: .extra,
            kind: .toggle,
            defaultValue: .bool(true)),
        SettingDefinition(id: "advanced.debugMode",
            section: "advanced",
            label: "Debug mode",
            help: "Turn it on if you are asked for it while reporting a problem.",
            more: "It adds the diagnostics to this pane: what the app is doing right now, the tail of the log, a support bundle, and where its files are kept. Nothing is sent anywhere.",
            store: .extra,
            kind: .toggle,
            defaultValue: .bool(false)),
    ]
    public static let sections: [SettingsSectionInfo] = [
        .init(id: "general", label: "General", blurb: "How sessions behave day to day."),
        .init(id: "appearance", label: "Appearance", blurb: "The window’s theme, and how a session is drawn."),
        .init(id: "notifications", label: "Notifications", blurb: "What the app tells you, and how."),
        .init(id: "agents", label: "Coding AI", blurb: "What runs your sessions, the logins it uses, and what is installed."),
        .init(id: "features", label: "Tools", blurb: "Extra tools a session can use."),
        .init(id: "linux", label: "Linux", blurb: "Which Linux a session in a Linux folder runs inside."),
        .init(id: "browser", label: "Browser", blurb: "The built-in browser tab and what it remembers."),
        .init(id: "scraping", label: "Scraping", blurb: "Workers, request rules, capture and the checks on what came back."),
        .init(id: "copilot", label: "Hoot", blurb: "Its files, its memory, what it did, and what it can reach."),
        .init(id: "ai-apps", label: "Connect an AI app", blurb: "Let AI apps on this Mac or on the internet use your sessions, with a key you can take back."),
        .init(id: "tasks", label: "Tasks", blurb: "The agents that take work from your CRM, and the CRMs allowed to send it."),
        .init(id: "plugins", label: "Plugins", blurb: "Programs you add yourself, each allowed only what you choose."),
        .init(id: "power", label: "Power", blurb: "Keep this machine running when you close it."),
        .init(id: "advanced", label: "Advanced", blurb: "When something is wrong, and starting over."),
        .init(id: "help", label: "Help", blurb: "What this app is, how it works, and what to do when it does not."),
    ]

    public static let maxTextLength = 512
    public static let maxKeyedLength = 2048
    /// A row of somebody's own colour scheme: stored under its own key, outside the table.
    public static let customSchemePrefix = "appearance.terminalScheme.custom."

    /// `RENAMED_IDS`: a value stored under an old name lands on the row it now belongs to.
    public static let renamed: [String: String] = [
        "notifications.sound": "notifications.onFinishSound",
        "general.soundOnFinish": "notifications.onFinishSound",
        "general.notifyOnAttention": "notifications.onNeedsInput",
        "general.showInsightAlerts": "notifications.showInsightAlerts",
        "general.defaultProvider": "agents.defaultProvider",
        "advanced.restoreSessions": "general.restoreSessions",
    ]

    public static func section(_ id: String) -> SettingsSectionInfo? { sections.first { $0.id == id } }

    /// `lookup`: by id, or by an old name.
    public static func setting(_ id: String) -> SettingDefinition? {
        if let found = all.first(where: { $0.id == id }) { return found }
        guard let current = renamed[id] else { return nil }
        return all.first { $0.id == current }
    }

    /// `settingsIn`: a section's rows, in table order.
    public static func settings(in section: String) -> [SettingDefinition] {
        all.filter { $0.section == section }
    }

    public static func isKeyed(_ id: String) -> Bool {
        id.hasPrefix(customSchemePrefix) && id.count > customSchemePrefix.count
    }

    /// `coerce`: the value if this setting can hold it, else nil.
    public static func coerce(_ setting: SettingDefinition, _ value: CodingAIJSON) -> CodingAIJSON? {
        switch setting.kind {
        case .toggle:
            if case .bool = value { return value }
            return nil
        case .select:
            guard let text = value.string, setting.options.contains(where: { $0.value == text }) else { return nil }
            return value
        case .number:
            guard let number = value.number, let range = setting.number else { return nil }
            let clamped = Swift.min(range.max, Swift.max(range.min, number))
            let steps = ((clamped - range.min) / range.step).rounded()
            return .number(Swift.min(range.max, range.min + steps * range.step))
        case .text:
            guard let text = value.string else { return nil }
            return .string(String(text.prefix(maxTextLength)))
        }
    }

    /// `valueOf`: the stored value, or the default.
    public static func value(_ values: [String: CodingAIJSON], _ setting: SettingDefinition) -> CodingAIJSON {
        coerce(setting, values[setting.id] ?? .null) ?? setting.defaultValue
    }

    public static func bool(_ values: [String: CodingAIJSON], _ id: String) -> Bool {
        guard let setting = setting(id) else { return false }
        return value(values, setting).bool ?? false
    }

    public static func string(_ values: [String: CodingAIJSON], _ id: String) -> String {
        guard let setting = setting(id) else { return "" }
        return value(values, setting).string ?? ""
    }

    public static func number(_ values: [String: CodingAIJSON], _ id: String) -> Double {
        guard let setting = setting(id) else { return 0 }
        return value(values, setting).number ?? 0
    }

    /// `DEFAULT_VALUES`.
    public static var defaults: [String: CodingAIJSON] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.defaultValue) })
    }

    /// `toStoredSettings`: the `{version, values}` envelope, or a bare map from an older build.
    public static func stored(_ settings: CodingAIJSON) -> [String: CodingAIJSON] {
        if let values = settings["values"].object { return values }
        return settings.object ?? [:]
    }

    /// `valuesFromPreferences`: the four settings that live in the preferences store.
    public static func valuesFromPreferences(_ prefs: CodingAIJSON) -> [String: CodingAIJSON] {
        var out: [String: CodingAIJSON] = [:]
        guard prefs.isObject else { return out }
        for setting in all where setting.store == .prefs {
            guard let key = setting.prefsKey, let value = coerce(setting, prefs[key]) else { continue }
            out[setting.id] = value
        }
        return out
    }

    /// `mergeSettings`: defaults, then what was stored (old names moved to new ones,
    /// impossible values back to their default), and unknown keys kept untouched.
    public static func merge(_ raw: [String: CodingAIJSON]) -> [String: CodingAIJSON] {
        var merged = defaults
        func put(_ key: String, _ value: CodingAIJSON) {
            guard let setting = all.first(where: { $0.id == key }) else {
                merged[key] = value
                return
            }
            merged[key] = coerce(setting, value) ?? setting.defaultValue
        }
        // Old names first, so a value stored under the current name wins.
        for (key, value) in raw where key != "__proto__" {
            if let current = renamed[key] { put(current, value) }
        }
        for (key, value) in raw where key != "__proto__" && renamed[key] == nil {
            put(key, value)
        }
        return merged
    }

    /// What the Settings window shows and hands to the main window: the settings
    /// file and the preferences, preferences winning for the keys they own.
    public static func values(settings: CodingAIJSON, preferences: CodingAIJSON) -> [String: CodingAIJSON] {
        var raw = stored(settings)
        for (key, value) in valuesFromPreferences(preferences) {
            raw[key] = value
            // The preference wins over the same row stored under an old name.
            for (old, current) in renamed where current == key { raw[old] = nil }
        }
        return merge(raw)
    }

    /// `splitPatch`: which store each changed value is written to, under its current id.
    public static func split(_ patch: [String: CodingAIJSON]) -> (prefs: [String: CodingAIJSON], extra: [String: CodingAIJSON], unknown: [String]) {
        var prefs: [String: CodingAIJSON] = [:]
        var extra: [String: CodingAIJSON] = [:]
        var unknown: [String] = []
        for (id, raw) in patch {
            if isKeyed(id) {
                switch raw {
                case .null: extra[id] = .null
                case .string(let text): extra[id] = .string(String(text.prefix(maxKeyedLength)))
                default: unknown.append(id)
                }
                continue
            }
            guard let setting = setting(id), let value = coerce(setting, raw) else {
                unknown.append(id)
                continue
            }
            if setting.store == .prefs, let key = setting.prefsKey {
                prefs[key] = value
            } else {
                extra[setting.id] = value
            }
        }
        return (prefs, extra, unknown.sorted())
    }

    /// The preferences half of every default — what "Reset all settings" writes there.
    public static var defaultPreferences: [String: CodingAIJSON] {
        split(defaults).prefs
    }

    /// The help line: a text setting left empty says what empty means.
    public static func help(_ setting: SettingDefinition, value: CodingAIJSON) -> String {
        if setting.kind == .text, let empty = setting.emptyMeans, (value.string ?? "") == "" {
            return "\(setting.help) \(empty)"
        }
        return setting.help
    }

    /// `numberWhileTyping`: a value to save now, or nil while it is not one yet.
    public static func numberWhileTyping(_ setting: SettingDefinition, _ raw: String) -> Double? {
        guard let range = setting.number else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let value = Double(text), value.isFinite else { return nil }
        guard value >= range.min && value <= range.max else { return nil }
        return value
    }

    /// `numberOnLeaving`: clamped into range, or nil for nothing typed.
    public static func numberOnLeaving(_ setting: SettingDefinition, _ raw: String) -> Double? {
        guard let range = setting.number else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let value = Double(text), value.isFinite else { return nil }
        return Swift.min(range.max, Swift.max(range.min, value))
    }

    /// The message the main window replaces its values with (`{type:'changed', values}`).
    public static func changedMessage(_ values: [String: CodingAIJSON]) -> CodingAIJSON {
        .object(["type": .string("changed"), "values": .object(values)])
    }
}

/// Settings that belong to an optional feature are drawn only while it is on
/// (`featureOwningSetting` + the page's `features.v2` store).
public enum SettingsFeatures {
    public static let storageKey = "features.v2"
    /// Setting id → the feature that owns it. Both features default to on.
    public static let owners: [String: String] = [
        "notifications.showInsightAlerts": "alerts",
        "browser.startUrl": "browser",
        "browser.persistSession": "browser",
    ]
    public static let defaultOn: Set<String> = ["alerts", "browser"]

    public static func isOn(_ feature: String, state: String?) -> Bool {
        let stored = state.map(CodingAIJSON.parse)?[feature].string
        if let stored, ["on", "off", "uninstalled"].contains(stored) { return stored == "on" }
        return defaultOn.contains(feature)
    }

    public static func settingOn(_ id: String, state: String?) -> Bool {
        guard let feature = owners[id] else { return true }
        return isOn(feature, state: state)
    }
}

/// The line at the foot of every Settings section.
public enum SettingsSaveState: Equatable, Sendable {
    case idle, saving, saved
    case failed(String)

    public var line: String {
        switch self {
        case .idle: return "Changes save as you make them."
        case .saving: return "Saving…"
        case .saved: return "Saved."
        case .failed(let message): return message
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
