import Foundation

public enum CloudBrainSettings {
  /// Only reviewed personal preferences can become active on another machine.
  /// Other keys remain blocked until their owner classifies them as portable, machine-local or secret.
  /// (The older, never switched-on adapters read this set. What really travels since lane L3 is `travels` below.)
  public static let portableKeys: Set<String> = [
    "theme", "defaultProvider", "notifyOnComplete", "notifyOnInput", "fontSize", "fontFamily",
    "terminal.fontSize", "terminal.fontFamily", "terminal.cursorStyle", "terminal.cursorBlink",
    "appearance.theme", "appearance.fontSize", "appearance.reduceMotion", "sounds.enabled"
  ]
  public static func isScalar(_ value: NativeRPCValue) -> Bool {
    switch value { case .bool, .string: return true; case .number(let n): return n.isFinite; default: return false }
  }
  public static func portable(_ values: NativeRPCValue) -> NativeRPCValue {
    .object((values.fields ?? []).filter { portableKeys.contains($0.key) && isScalar($0.value) })
  }

  // MARK: Lane L3 (14 Nov), widened 15 Nov ("same everywhere"): the one list of what travels and what stays

  /// Where a setting is saved on a device:
  /// - `app`: the settings file's values (`settings.json`)
  /// - `preference`: the app state's preferences (`state.json` → `preferences`)
  /// - `choice` (15 Nov): what the app's screens remember (side-panel pins and their order, open sections, page views),
  ///   kept in the app's own defaults. Only keys on the list below: that store also holds the system's own entries.
  /// - `project` (15 Nov): one project's own settings (`settings.json` → `projectSettings`), key `<project id>/<key>`.
  public enum Source: String, Sendable, CaseIterable { case app, preference, choice, project }
  /// The value a travelling setting may take. A value from another device of any other shape is not applied (held).
  public enum Shape: Sendable, Equatable {
    case bool
    case number(ClosedRange<Double>)
    /// One plain line of at most this many characters.
    case text(Int)
    case choice(Set<String>)
    /// 15 Nov: any one value (on, off, a finite number, or text of at most this many characters; a text may hold line
    /// breaks and tabs, never other control characters). The shape of every setting that travels by default.
    case scalar(Int)
    /// 15 Nov: a list or a small structure (pins and their order, saved views), at most this many bytes written out.
    case json(Int)
    public func accepts(_ value: NativeRPCValue) -> Bool {
      switch (self, value) {
      case (.bool, .bool): return true
      case (.number(let range), .number(let n)): return n.isFinite && range.contains(n)
      case (.text(let maximum), .string(let s)):
        return s.count <= maximum && !s.unicodeScalars.contains { $0.properties.generalCategory == .control }
      case (.choice(let options), .string(let s)): return options.contains(s)
      case (.scalar, .bool): return true
      case (.scalar, .number(let n)): return n.isFinite
      case (.scalar(let maximum), .string(let s)): return s.count <= maximum && CloudBrainSettings.plainText(s)
      case (.json(let maximum), _):
        guard CloudBrainSettings.plainValue(value) else { return false }
        return value.compact.utf8.count <= maximum
      default: return false
      }
    }
  }
  /// Text with no control characters except line breaks and tabs.
  public static func plainText(_ s: String) -> Bool {
    !s.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" && $0 != "\r" }
  }
  /// Every text inside a value is plain and every number finite (no null at the top).
  public static func plainValue(_ value: NativeRPCValue) -> Bool {
    switch value {
    case .bool: return true
    case .number(let n): return n.isFinite
    case .string(let s): return plainText(s)
    case .array(let items): return items.allSatisfy { $0.isNullish || plainValue($0) }
    case .object(let fields): return fields.allSatisfy { plainText($0.key) && ($0.value.isNullish || plainValue($0.value)) }
    default: return false
    }
  }
  /// A setting about the person, not about this device: it travels.
  public struct Travels: Sendable, Equatable {
    public let source: Source
    /// The key, or the start of every key of a family when `family` is true.
    public let key: String
    public let family: Bool
    public let shape: Shape
    /// A value that could change which AI runs a new session: applied with no click under the default device-trust
    /// setting ("Automatically, with my account"), held under "Ask me for each new device" (the projects/agents rule).
    public let widening: Bool
    /// 15 Nov: travels since "same everywhere". Sent only while every computer of the account runs a build that knows
    /// it (the delete rule's gate, `cloudDeleteRuleIsOpen`); taken whenever it arrives.
    public let newer: Bool
    public init(_ source: Source, _ key: String, _ shape: Shape, family: Bool = false, widening: Bool = false, newer: Bool = false) {
      self.source = source; self.key = key; self.shape = shape; self.family = family; self.widening = widening; self.newer = newer
    }
    public func matches(_ source: Source, _ key: String) -> Bool {
      source == self.source && (family ? key.hasPrefix(self.key) && key.count > self.key.count : key == self.key)
    }
  }
  /// A setting that stays on each device, with the reason in plain words.
  public struct Stays: Sendable, Equatable {
    public let source: Source
    public let key: String
    public let family: Bool
    public let reason: String
    public init(_ source: Source, _ key: String, family: Bool = false, _ reason: String) {
      self.source = source; self.key = key; self.family = family; self.reason = reason
    }
    public func matches(_ source: Source, _ key: String) -> Bool {
      source == self.source && (family ? key.hasPrefix(self.key) : key == self.key)
    }
  }

  /// CLOUD-KINDS-3: at most this many custom colour schemes may arrive from other devices (the settings file holds 500
  /// entries in all; another device must never fill it).
  public static let maximumCustomSchemes = 50
  static let providers: Set<String> = ["claude", "codex", "gemini", "shell"]
  static let sounds: Set<String> = ["chime", "blip", "knock"]
  /// The longest text a setting of the settings file holds (`BackendAppSettingsStore.maxStringLength`).
  public static let longestText = 4096
  /// The largest list or structure a screen's choice may send (pins, saved views).
  public static let largestChoice = 16_384
  /// The settings with their own rule. Every other key of the settings file, the preferences and a project's own
  /// settings travels too (`rule`, 15 Nov), unless it is on `stays` or names something of this device only.
  public static let travels: [Travels] = [
    // Appearance
    .init(.preference, "theme", .choice(["dark", "light", "system"])),
    .init(.app, "appearance.theme", .choice(["dark", "light", "system"])),
    .init(.app, "appearance.terminalScheme", .text(128)),
    .init(.app, "appearance.terminalScheme.custom.", .text(4096), family: true),
    .init(.app, "appearance.terminalFontSize", .number(9...24)),
    .init(.app, "appearance.terminalFontFamily", .text(128)),
    .init(.app, "appearance.fontSize", .number(8...32)),
    .init(.app, "appearance.reduceMotion", .bool),
    // How sessions behave
    .init(.preference, "restoreSessions", .bool),
    .init(.preference, "newSessionMode", .text(64)),
    .init(.app, "general.autoNameSessions", .bool),
    .init(.app, "general.confirmCloseWorking", .bool),
    .init(.app, "general.copyOnSelect", .bool),
    // Notifications and sounds
    .init(.preference, "notifyOnComplete", .bool),
    .init(.app, "notifications.onComplete", .bool),
    .init(.app, "notifications.onNeedsInput", .bool),
    .init(.app, "notifications.onFinishSound", .bool),
    .init(.app, "notifications.soundName", .choice(sounds)),
    .init(.app, "notifications.sound", .bool),
    .init(.app, "notifications.onlyWhenUnfocused", .bool),
    .init(.app, "notifications.showInsightAlerts", .bool),
    .init(.app, "general.notifyOnAttention", .bool),
    .init(.app, "general.showInsightAlerts", .bool),
    .init(.app, "general.soundOnFinish", .bool),
    .init(.app, "sounds.enabled", .bool),
    // Browser
    .init(.app, "browser.startUrl", .text(2048)),
    // Dynamic Island and menu bar
    .init(.app, "copilot.islandLook", .text(64)),
    .init(.app, "copilot.islandQuiet", .text(256)),
    .init(.app, "copilot.islandShows", .text(64)),
    .init(.app, "copilot.islandWidthPreset", .text(64)),
    .init(.app, "copilot.menuBar", .bool),
    // Agent defaults
    .init(.preference, "defaultProvider", .choice(providers), widening: true),
    .init(.app, "general.defaultProvider", .choice(providers), widening: true),
    .init(.app, "agents.defaultProvider", .choice(providers), widening: true, newer: true),
    .init(.app, "hoot.provider", .scalar(64), widening: true, newer: true),
    .init(.project, "setup.hootLeads", .scalar(64), family: false, widening: true, newer: true),
    // Lead's decision (15 Nov): what an AI may do without asking and the routines' hourly limit travel too. Only he
    // changes them by hand; the newest change per setting wins, and a new or reset device never sends its defaults,
    // so it can never loosen or tighten the others by itself.
    .init(.app, "hoot.interactive", .bool, widening: true, newer: true),
    .init(.app, "copilot.interactive", .bool, widening: true, newer: true),
    .init(.app, "routines.maxRunsPerHour", .number(1...10_000), widening: true, newer: true),
    .init(.app, "hoot.permission.", .scalar(64), family: true, widening: true, newer: true),
    .init(.app, "hoot.policy.", .scalar(256), family: true, widening: true, newer: true),
    // 15 Nov: what the screens remember (owner: "even the side panel ... pinned on my Mac mini, pinned on my MacBook").
    .init(.choice, "sidebar.pagePins.v1", .json(largestChoice), newer: true),          // side-panel pages, order, More pages
    .init(.choice, "sidebar.pinnedTabs.v2", .json(largestChoice), newer: true),        // pinned sessions (shown once here)
    .init(.choice, "chat.archivedSessions.v1", .json(largestChoice), newer: true),     // archived chats
    .init(.choice, "chat.sessionPanel.open", .bool, newer: true),                      // open sections
    .init(.choice, "deploy.hootPanel.collapsed", .bool, newer: true),
    .init(.choice, "page.tasks.section21", .scalar(64), newer: true),                  // page views
    .init(.choice, "page.hoot.machine21", .scalar(256), newer: true),
    .init(.choice, "AGFRAME.view", .scalar(64), newer: true),
    .init(.choice, "AGFRAME.project", .scalar(256), newer: true),
    .init(.choice, "AGFRAME.filter21", .scalar(64), newer: true),
    .init(.choice, "AGFRAME.search21", .scalar(512), newer: true),
    .init(.choice, "agt.layout", .scalar(64), newer: true),
    .init(.choice, "agt.grouping", .scalar(64), newer: true),
    .init(.choice, "agt.declaredLead.notNow.", .bool, family: true, newer: true),
    .init(.choice, "td.tasks.viewState.v1", .scalar(largestChoice), newer: true),
    .init(.choice, "td.tasks.savedViews.v1", .json(largestChoice), newer: true),
    .init(.choice, "td.tasks.activeView.v1", .scalar(256), newer: true),
    .init(.choice, "td.tasks.favorites.v1", .json(largestChoice), newer: true),
    .init(.choice, "td.tasks.projectScope", .scalar(64), newer: true),
    .init(.choice, "td.tasks.selectedProjectID", .scalar(256), newer: true),
    .init(.choice, "catalog.artifacts.project", .scalar(256), newer: true),
    .init(.choice, "machines.servers.project", .scalar(256), newer: true),
    .init(.choice, "phone.record.talk", .bool, newer: true),                           // voice
    .init(.choice, "phone.record.words", .scalar(64), newer: true),
    .init(.choice, "phone.record.language", .scalar(64), newer: true),
    .init(.choice, "session-controls.effort.v1", .scalar(largestChoice), newer: true), // remembered effort
    .init(.choice, "features.v2", .scalar(largestChoice), newer: true),                // feature switches
    .init(.choice, "readiness.dismissed.v1", .scalar(largestChoice), newer: true),     // notices he closed
    .init(.choice, "hoot.setup.dismissed.v1", .bool, newer: true),
    .init(.choice, "td.sessionSimulator.annotateFullPanel", .bool, newer: true),
    .init(.choice, "devices.directScreen", .bool, newer: true),
    .init(.choice, "landing.draft.v1", .scalar(longestText), newer: true),             // the unsent text of New session
  ]
  static let windowReason = "A window's place and size on this device's screen."
  static let screenReason = "Which screen of this device it uses."
  static let reachReason = "How this device itself is reached: its own local port and relay."
  static let signInReason = "Names an AI app sign-in that exists on this device only (sign-ins travel through saved passwords)."
  static let folderReason = "A folder path on this device."
  static let installedReason = "Something installed on this device only."
  /// What stays on each device and why.
  public static let stays: [Stays] = [
    .init(.app, "IslandShowOn", screenReason),
    .init(.app, "copilot.islandWidth", windowReason),
    .init(.app, "copilot.islandHeight", windowReason),
    .init(.app, "remote.", family: true, reachReason),
    .init(.app, "accounts.", family: true, signInReason),
    .init(.preference, "accountLimits", signInReason),
    .init(.app, "features.install.", family: true, installedReason),
    .init(.app, "hoot.home", folderReason),
    .init(.app, "copilot.home", folderReason),
    .init(.app, "hoot.cli", installedReason),
    // What the screens remember about this device only (listed so the page can say why).
    .init(.choice, "session-start.lastFolder.v1", folderReason),
    .init(.choice, "session-start.defaults.v1", "Kept per folder of this device."),
    .init(.choice, "sidebar.removedFolders", folderReason),
    .init(.choice, "openScreenWindows", windowReason),
    .init(.choice, "settingsWindow.size.v2", windowReason),
    .init(.choice, "paneArrangement.v1", windowReason),
    .init(.choice, "native.window.buttons.v1", windowReason),
    .init(.choice, "nativeBrowser.tabs.v1", "The browser tabs open in this device's windows."),
    .init(.choice, "td.feedback.targets.v2", "Names browser tabs and phone panels open on this device."),
    .init(.choice, "landing.lastStart.v1", signInReason),
    .init(.choice, "landing.models.v1", "The models this device's installed AI apps report."),
    .init(.choice, "accounts.sessionsChosenIndividually", signInReason),
    .init(.choice, "simulators.last", "A simulator on this device."),
    .init(.choice, "catalog.mcp.project", "Belongs to the MCP page, whose servers are set up on each device."),
  ]
  /// The travelling rule for one setting, or nil: it stays on this device.
  /// 15 Nov (owner: "every single setting should be same"): a key of the settings file, the preferences or a project's
  /// own settings that is on neither list travels as one plain value; a screen's choice travels only when listed.
  public static func rule(_ source: Source, _ key: String) -> Travels? {
    let setting = source == .project ? projectParts(key)?.key : key
    guard let setting, !stays.contains(where: { $0.matches(source, key) }), !looksMachineOrSecret(setting), !isBookkeeping(setting) else { return nil }
    if let listed = travels.first(where: { $0.matches(source, setting) || (source == .project && $0.source == .project && $0.key == setting) }) {
      return source == .project ? .init(.project, key, listed.shape, widening: listed.widening, newer: true) : listed
    }
    switch source {
    case .choice: return nil
    case .project: return .init(.project, key, .scalar(longestText), newer: true)
    case .preference: return .init(.preference, key, .json(largestChoice), newer: true)
    case .app: return .init(.app, key, .scalar(longestText), newer: true)
    }
  }
  /// `<project id>/<key>`: the project's id (never a folder) and the setting's key.
  public static func projectParts(_ key: String) -> (project: String, key: String)? {
    guard let slash = key.firstIndex(of: "/") else { return nil }
    let project = String(key[..<slash]), setting = String(key[key.index(after: slash)...])
    guard !project.isEmpty, !setting.isEmpty, !project.hasPrefix("~"), !project.contains("/") else { return nil }
    return (project, setting)
  }
  public static let unlistedReason = "Not one of the screens' choices that travel: it stays on this device."
  /// Why a setting stays on this device (nil when it travels).
  public static func stayReason(_ source: Source, _ key: String) -> String? {
    if let listed = stays.first(where: { $0.matches(source, key) }) { return listed.reason }
    let setting = source == .project ? (projectParts(key)?.key ?? key) : key
    if looksMachineOrSecret(setting) { return "Folders, paths, windows, keys, tokens, hooks and MCP settings stay on each device." }
    if isBookkeeping(setting) { return "A note the app keeps about itself on this device, not a setting." }
    return rule(source, key) == nil ? unlistedReason : nil
  }
  /// The value a setting has when he never chose one (CLOUD-KINDS-2): the Settings table's default, the app state's
  /// shipped preferences, and the side panel's first pages. nil = no known default (a value that is present then
  /// counts as chosen).
  public static func defaultValue(_ source: Source, _ key: String) -> NativeRPCValue? {
    if source == .preference, let shipped = NativeStateStore.defaults["preferences"].fields?.first(where: { $0.key == key }) { return shipped.value }
    if source == .choice || source == .project { return nil }
    if source == .app, let known = appDefaults[key] { return known }
    let row = SettingsSchema.all.first { definition in
      switch (source, definition.store) {
      case (.preference, .prefs): return definition.prefsKey == key
      case (.app, .extra): return definition.id == key
      default: return false
      }
    }
    switch row?.defaultValue {
    case .bool(let value)?: return .bool(value)
    case .number(let value)?: return .number(value)
    case .string(let value)?: return .string(value)
    default: return nil
    }
  }
  /// Defaults of settings the Settings table does not list (the app reads them as these when absent).
  static let appDefaults: [String: NativeRPCValue] = [
    "hoot.interactive": .bool(true), "copilot.interactive": .bool(true), "routines.maxRunsPerHour": .number(60),
  ]
  /// 15 Nov: more than one value can mean "never chosen" (the side panel's first pages, with or without Cloud added).
  public static func isDefault(_ source: Source, _ key: String, _ value: NativeRPCValue) -> Bool {
    if source == .choice, key == "sidebar.pagePins.v1" {
      // The first pages of a new install or of an upgrade, each with or without Cloud added after Tasks.
      var shipped: [[String]] = []
      for first in [Sidebar21Pages.defaults, Sidebar21Pages.upgradeOrder] {
        var withCloud = first
        if !first.contains(Sidebar21Pages.cloudID) { withCloud.insert(Sidebar21Pages.cloudID, at: (first.firstIndex(of: "tasks").map { $0 + 1 }) ?? first.count) }
        shipped += [first, withCloud]
      }
      return shipped.contains { value == .array($0.map { .string($0) }) }
    }
    guard let shipped = defaultValue(source, key) else { return false }
    return shipped == value
  }
  /// Never travel, whatever list they appear on: folders, paths, window frames, sessions, keys and tokens.
  public static func looksMachineOrSecret(_ key: String) -> Bool {
    let lower = key.lowercased()
    return ["path", "folder", "cwd", "token", "secret", "password", "apikey", "api_key", "bounds", "window", "hook", "mcp",
            "socket", "deviceid", "device_id"]
      .contains { lower.contains($0) }
  }
  /// The app's own notes about itself (an upgrade done, when it last looked): not settings, never sent.
  public static func isBookkeeping(_ key: String) -> Bool {
    let lower = key.lowercased()
    return ["migrat", "lastseen", "lastrun", "lastcheck", "installedat"].contains { lower.contains($0) }
  }
}
