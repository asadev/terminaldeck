import Foundation

/// The person's own "not now" to Hoot's setup questions. Only the person's close is
/// remembered; the app's own closes never are, and a remembered "not now" answers a
/// later offer with close, never with "done". Asking again from Settings forgets it.
public enum HootSetupMemory {
    public static let key = "hoot.setup.dismissed.v1"
    /// The answer to the page's offer, or nil to show the questions.
    public static func answer(toOffer defaults: UserDefaults = .standard) -> String? {
        defaults.bool(forKey: key) ? "close" : nil
    }
    public static func answered(closing: Bool, byPerson: Bool, defaults: UserDefaults = .standard) {
        if closing, byPerson { defaults.set(true, forKey: key) }
    }
    public static func askAgain(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

/// Native defaults and presentation share one owner; an emergency override stays explicit.
public enum HootReadyDefaults {
    public static func enabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[NativeLaunchSwitches.hootDisabled] != "1"
    }
    public static let providerOrder: [HootChatProvider] = [.claude, .codex, .gemini]
    public static let signInLine = "Sign in to Claude, Codex or Gemini to start:"
    public static let mainTabID = "hoot"

    /// A presentation tab, independent of the hidden CLI's session identifier.
    public static func open(in state: TabsState, title: String = "Hoot") -> TabsState {
        let id = state.tabs.first(where: { $0.kind == "hoot" })?.id ?? mainTabID
        var tabs = state.tabs.filter { $0.kind != "hoot" }.map { copy($0, active: false) }
        let position = state.tabs.firstIndex(where: { $0.kind == "hoot" }) ?? tabs.count
        tabs.insert(.init(id: id, title: title, kind: "hoot", active: true, closable: true), at: min(position, tabs.count))
        return .init(tabs: tabs, canNewTerminal: state.canNewTerminal, canNewBrowser: state.canNewBrowser,
                     layout: selecting(id, layout: state.layout), accountSwitch: state.accountSwitch)
    }
    /// Closing the tab puts Hoot away. This deliberately has no process action.
    public static func close(in state: TabsState) -> TabsState {
        guard let index = state.tabs.firstIndex(where: { $0.kind == "hoot" }) else { return state }
        let closed = state.tabs[index], rest = state.tabs.filter { $0.kind != "hoot" }
        let next = closed.active && !rest.isEmpty ? rest[min(index, rest.count - 1)].id : state.activeID
        return .init(tabs: rest.map { copy($0, active: $0.id == next) }, canNewTerminal: state.canNewTerminal,
                     canNewBrowser: state.canNewBrowser, layout: replacing(closed.id, with: next, layout: state.layout),
                     accountSwitch: state.accountSwitch)
    }
    private static func copy(_ tab: TabItem, active: Bool) -> TabItem {
        .init(id: tab.id, title: tab.title, symbol: tab.symbol, kind: tab.kind, active: active,
              unread: tab.unread, status: tab.status, closable: tab.closable, server: tab.server)
    }
    private static func selecting(_ id: String, layout: WindowLayout?) -> WindowLayout? {
        guard let layout else { return nil }
        guard let root = layout.root else { return layoutCopy(layout, root: nil) }
        let pane = layout.focusedPaneId ?? layout.primaryPaneId ?? root.leaves.first?.id
        return layoutCopy(layout, root: map(root) { leaf, tab in leaf == pane ? id : tab })
    }
    private static func replacing(_ id: String, with next: String?, layout: WindowLayout?) -> WindowLayout? {
        guard let layout, let root = layout.root else { return layout }
        return layoutCopy(layout, root: map(root) { _, tab in tab == id ? next : tab })
    }
    private static func map(_ node: PaneNode, change: (String, String?) -> String?) -> PaneNode {
        switch node {
        case .leaf(let id, let tab): .leaf(id: id, tabId: change(id, tab))
        case .split(let id, let horizontal, let ratio, let first, let second):
            .split(id: id, horizontal: horizontal, ratio: ratio, first: map(first, change: change), second: map(second, change: change))
        }
    }
    private static func layoutCopy(_ layout: WindowLayout, root: PaneNode?) -> WindowLayout {
        .init(mode: layout.mode, swarm: false, root: root, focusedPaneId: layout.focusedPaneId,
              primaryPaneId: layout.primaryPaneId, modeSwitch: layout.modeSwitch, splitOffer: layout.splitOffer,
              swarmSessions: layout.swarmSessions)
    }
}

public struct HootReadyPreferences: Sendable, Equatable {
    public var provider: HootChatProvider?
    public var profileID: String?
    public var model: String?
    public var effort: String?
    /// The CLI's own permission mode for the selected provider (nil = the CLI default, "asks first").
    public var permissionMode: String?
    /// "standard", "1m" (Claude Code models with a 1M window) or "max" (Codex models with a larger window).
    public var contextWindow: String?
    /// Claude Code's Fast mode for Hoot (offered only when Claude Code reports it for the account).
    public var fastMode: Bool?
    public init(provider: HootChatProvider? = nil, profileID: String? = nil, model: String? = nil, effort: String? = nil,
                permissionMode: String? = nil, contextWindow: String? = nil, fastMode: Bool? = nil) {
        self.provider = provider; self.profileID = profileID; self.model = model; self.effort = effort
        self.permissionMode = permissionMode; self.contextWindow = contextWindow; self.fastMode = fastMode
    }
    public init(wire: NativeRPCValue) throws {
        _ = try wire.requireObject("Hoot choices")
        guard Set(wire.fields?.map(\.key) ?? []).isSubset(of: ["provider", "profileId", "model", "effort", "permissionMode", "contextWindow", "fastMode"]) else {
            throw NativeRPCError.invalidArguments("Unknown Hoot choice.")
        }
        func text(_ key: String) throws -> String? {
            if wire[key].isNullish { return nil }
            let value = try wire[key].requireString(key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count <= 512, !value.contains("\0"), !value.contains("\n") else { throw NativeRPCError.invalidArguments("Invalid Hoot \(key).") }
            return value.isEmpty ? nil : value
        }
        let selected = try text("provider")
        if let selected, HootChatProvider(rawValue: selected) == nil { throw NativeRPCError.invalidArguments("Choose Claude, Codex or Gemini.") }
        let window = try text("contextWindow")
        if let window, !["standard", "1m", "max"].contains(window) { throw NativeRPCError.invalidArguments("Choose a standard, 1M or largest context window.") }
        self.init(provider: selected.flatMap(HootChatProvider.init(rawValue:)), profileID: try text("profileId"), model: try text("model"),
                  effort: try text("effort"), permissionMode: try text("permissionMode"), contextWindow: window == "standard" ? nil : window,
                  fastMode: try { () throws -> Bool? in
                      if wire["fastMode"].isNullish { return nil }
                      guard let on = wire["fastMode"].bool else { throw NativeRPCError.invalidArguments("Fast mode is on or off.") }
                      return on }())
    }
    public var wireValue: NativeRPCValue {
        .object([.init("provider", provider.map { .string($0.rawValue) } ?? .null),
                 .init("profileId", profileID.map(NativeRPCValue.string) ?? .null),
                 .init("model", model.map(NativeRPCValue.string) ?? .null), .init("effort", effort.map(NativeRPCValue.string) ?? .null),
                 .init("permissionMode", permissionMode.map(NativeRPCValue.string) ?? .null),
                 .init("contextWindow", contextWindow.map(NativeRPCValue.string) ?? .null),
                 .init("fastMode", fastMode.map(NativeRPCValue.bool) ?? .null)])
    }
}

/// The models Hoot offers per Coding AI, and which Claude Code models offer a 1M context window.
/// Other models can still be typed; these are the menu's choices.
public enum HootModelCatalog {
    public struct Model: Sendable, Equatable, Identifiable {
        public let id: String, name: String, supportsOneMillion: Bool
    }
    /// No written model list: pickers show only what the live source returns (BackendHootModelSource).
    public static func models(_ provider: HootChatProvider) -> [Model] { [] }
    /// The model the CLI is launched with: a chosen 1M window becomes Claude Code's "[1m]" suffix.
    public static func launchModel(provider: HootChatProvider, model: String?, contextWindow: String?) -> String? {
        guard contextWindow == "1m", provider == .claude, let model, supportsOneMillion(provider: provider, model: model) else { return model }
        return model.hasSuffix("[1m]") ? model : model + "[1m]"
    }
    public static func supportsOneMillion(provider: HootChatProvider, model: String?) -> Bool {
        guard provider == .claude, let model else { return false }
        let base = model.replacingOccurrences(of: "[1m]", with: "")
        // Claude Code's 1M window applies to its Opus, Sonnet and Fable lines (aliases or full ids).
        return ["opus", "sonnet", "fable"].contains(base) || base.hasPrefix("claude-opus") || base.hasPrefix("claude-sonnet") || base.hasPrefix("claude-fable")
    }
}

