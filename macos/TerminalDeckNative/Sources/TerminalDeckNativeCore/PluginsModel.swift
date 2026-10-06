import Foundation

/// Settings → Plugins, as data: what the engine's `plugins:state` answers and the
/// words the section prints. A port of `src/shared/plugins.ts`,
/// `src/renderer/plugins/plugins-model.ts` and the pure parts of
/// `src/renderer/settings/sections/PluginsSection.tsx`, narrowed the same way.
public enum PluginCatalog {
    /// `BRAND.assistant`.
    public static let assistant = "Hoot"

    /// `PLUGIN_CAPABILITIES`, in order.
    public static let capabilities = ["tasks.read", "goals.read", "knowledge.read", "notify", "tools.contribute"]

    /// `PROJECT_SCOPED`: the capabilities granted per project.
    public static let projectScoped: Set<String> = ["knowledge.read"]

    /// `CAPABILITY_WORDS`.
    public static func words(_ capability: String) -> String {
        switch capability {
        case "tasks.read": return "Read your tasks"
        case "goals.read": return "Read your goals"
        case "knowledge.read": return "Read what is recorded about the projects you choose"
        case "notify": return "Show you notifications"
        case "tools.contribute": return "Give \(assistant) new tools"
        default: return capability
        }
    }

    /// `PLUGIN_TOOL_TIERS`.
    public static let tiers = ["read", "act", "alter"]

    /// `projectName`: the last part of a path.
    public static func projectName(_ path: String) -> String {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        return parts.last ?? path
    }
}

public enum PluginState: String, Sendable, CaseIterable {
    case off, needsOk = "needs-ok", changed, running, stopped, broken

    /// `STATE_WORDS`.
    public var words: String {
        switch self {
        case .off: return "Off"
        case .needsOk: return "Not allowed"
        case .changed: return "Changed"
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .broken: return "Cannot be used"
        }
    }
}

public struct PluginTool: Equatable, Sendable {
    public let name: String
    public let wire: String
    public let title: String
    public let tier: String
}

public struct PluginItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let version: String
    public let enabled: Bool
    public let state: PluginState
    public let note: String
    public let declared: [String]
    public let granted: [String]
    public let projects: [String]
    public let allowed: Bool
    public let tools: [PluginTool]

    /// The line under the capabilities when there are tools: "Tools for Hoot: Title (tier), …".
    public var toolsLine: String? {
        guard !tools.isEmpty else { return nil }
        return "Tools for \(PluginCatalog.assistant): " + tools.map { "\($0.title) (\($0.tier))" }.joined(separator: ", ")
    }

    /// One capability's line: "Read your tasks — allowed", with the projects when granted per project.
    public func capabilityLine(_ capability: String) -> String {
        let isGranted = granted.contains(capability)
        let where_ = isGranted && PluginCatalog.projectScoped.contains(capability) && !projects.isEmpty
            ? ": " + projects.map(PluginCatalog.projectName).joined(separator: ", ")
            : ""
        return "\(PluginCatalog.words(capability))\(where_) — \(isGranted ? "allowed" : "not allowed")"
    }

    /// The label of the Allow/Change button (`editing` is whether the form is open).
    public func editLabel(editing: Bool) -> String {
        if editing { return "Close" }
        if allowed { return "Change" }
        return state == .changed ? "Allow again…" : "Allow…"
    }

    public static let nothingAsked = "Asks for nothing beyond running."
}

public struct PluginsState: Equatable, Sendable {
    public let folder: String
    public let confinement: String
    public let projects: [String]
    public let plugins: [PluginItem]

    /// `toPluginsState`: nil for anything that is not a state with a plugin list.
    public static func from(_ raw: CodingAIJSON) -> PluginsState? {
        guard raw.isObject, let list = raw["plugins"].array else { return nil }
        return PluginsState(
            folder: raw["folder"].string ?? "",
            confinement: raw["confinement"].string ?? "",
            projects: strings(raw["projects"]),
            plugins: list.compactMap(plugin)
        )
    }

    private static func strings(_ value: CodingAIJSON) -> [String] {
        (value.array ?? []).compactMap(\.string)
    }

    private static func plugin(_ raw: CodingAIJSON) -> PluginItem? {
        guard raw.isObject, let id = raw["id"].text,
              let state = PluginState(rawValue: raw["state"].string ?? "") else { return nil }
        let tools: [PluginTool] = (raw["tools"].array ?? []).compactMap { one in
            guard one.isObject, let name = one["name"].text, let wire = one["wire"].text,
                  let tier = one["tier"].string, PluginCatalog.tiers.contains(tier) else { return nil }
            return PluginTool(name: name, wire: wire, title: one["title"].text ?? name, tier: tier)
        }
        return PluginItem(
            id: id,
            name: raw["name"].text ?? id,
            summary: raw["summary"].string ?? "",
            version: raw["version"].string ?? "",
            enabled: raw["enabled"].isTrue,
            state: state,
            note: raw["note"].string ?? "",
            declared: strings(raw["declared"]).filter(PluginCatalog.capabilities.contains),
            granted: strings(raw["granted"]).filter(PluginCatalog.capabilities.contains),
            projects: strings(raw["projects"]),
            allowed: raw["allowed"].isTrue,
            tools: tools
        )
    }
}

/// `toPluginsResult`: what a change answered.
public struct PluginsResult: Equatable, Sendable {
    public let ok: Bool
    public let message: String?
    public let state: PluginsState?

    public static let unreadable = "The app answered with something this page cannot read."

    public static func from(_ raw: CodingAIJSON) -> PluginsResult {
        guard raw.isObject else { return PluginsResult(ok: false, message: unreadable, state: nil) }
        return PluginsResult(ok: raw["ok"].isTrue, message: raw["message"].string, state: PluginsState.from(raw["state"]))
    }
}

/// The Allow form's arithmetic (`AllowForm`).
public struct PluginAllowDraft: Equatable, Sendable {
    public var chosen: [String]
    public var places: [String]
    public let plugin: PluginItem

    public init(plugin: PluginItem) {
        self.plugin = plugin
        chosen = plugin.allowed ? plugin.granted : plugin.declared
        places = plugin.allowed ? plugin.projects : []
    }

    /// `toggle`: on puts it last (once); off takes it out.
    public static func toggle(_ list: [String], _ value: String, _ on: Bool) -> [String] {
        on ? list.filter { $0 != value } + [value] : list.filter { $0 != value }
    }

    public mutating func setCapability(_ capability: String, _ on: Bool) { chosen = Self.toggle(chosen, capability, on) }
    public mutating func setProject(_ project: String, _ on: Bool) { places = Self.toggle(places, project, on) }

    public var scoped: Bool { chosen.contains(where: PluginCatalog.projectScoped.contains) }

    /// Whether saving asks to confirm (a dialog the engine shows): anything new is being granted.
    public var asks: Bool {
        !plugin.allowed
            || chosen.contains(where: { !plugin.granted.contains($0) })
            || (scoped && places.contains(where: { !plugin.projects.contains($0) }))
    }

    public var missingPlace: Bool { scoped && places.isEmpty }

    public var buttonLabel: String { asks ? "Allow…" : "Save" }

    /// The button's hover line.
    public var buttonHelp: String? {
        if missingPlace { return "Choose at least one project, or turn that one off." }
        return asks ? "You are asked to confirm in a dialog." : nil
    }

    /// What `plugins:allow` is sent: `{ capabilities, projects }`.
    public var input: [String: Any] {
        ["capabilities": chosen, "projects": scoped ? places : []]
    }
}
