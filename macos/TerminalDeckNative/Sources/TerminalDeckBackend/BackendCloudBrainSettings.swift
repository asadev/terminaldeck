import Foundation
import TerminalDeckNativeCore

public enum BackendCloudBrainSettings {
  public static func adapter(owner: BackendAppSettingsStore, account: CloudBrainAgentsAccount) -> CloudBrainAgentsAdapter {
    .init(row: "I11", domains: ["settings"], owner: .init(
      inventory: { try await owner.cloudAttach(account); return try await owner.cloudSettingsInventory() },
      snapshot: { cut in try await owner.cloudAttach(account); return try await owner.cloudSettingsSnapshot(cut: cut) },
      apply: { incoming in try await owner.cloudAttach(account); return try await owner.cloudSettingsImport(incoming) },
      retained: { try await owner.cloudSettingsRetained($0) },
      ownChanges: { try await owner.cloudSettingsOwnChanges(after: $0, limit: $1) },
      cursor: { try await owner.cloudSettingsCursor() },
      saveCursor: { try await owner.cloudSettingsSaveCursor($0) },
      notices: { await owner.cloudSettingsNotices() },
      detach: { await owner.cloudDetach() }))
  }
  public static func stateAdapter(owner: NativeStateStore, account: CloudBrainAgentsAccount) -> CloudBrainAgentsAdapter {
    .init(row: "I11", domains: ["native-state"], owner: .init(
      inventory: { try await owner.cloudAttach(account); return try await owner.cloudStateInventory() },
      snapshot: { cut in try await owner.cloudAttach(account); return try await owner.cloudStateSnapshot(cut: cut) },
      apply: { incoming in try await owner.cloudAttach(account); return try await owner.cloudStateImport(incoming) },
      retained: { try await owner.cloudStateRetained($0) },
      ownChanges: { try await owner.cloudStateOwnChanges(after: $0, limit: $1) },
      cursor: { try await owner.cloudStateCursor() },
      saveCursor: { try await owner.cloudStateSaveCursor($0) },
      notices: { await owner.cloudStateNotices() },
      detach: { await owner.cloudDetach() }))
  }
}

/// Lane L3 (14 Nov): the settings that are about HIM (row I21, its own row; I11 is the project list), on the one record
/// rule: per setting the newest wins, a joining Mac's first copy loses, the value replaced is kept for 30 days on this
/// Mac. Only `CloudBrainSettings.travels` travels (default deny); everything about this Mac, sign-ins, permissions,
/// keys and limits stays (`CloudBrainSettings.stays`). One record per setting: `setting:<key>` for the settings file,
/// `preference:<key>` for the app state's preferences.
public actor BackendCloudKindsSettings: CloudBrainRecordOwner {
    public static let domain = "settings"
    public static let inventoryRow = "I21"
    public static let sourceID = "app-settings-personal"
    public static let appKind = CloudBrainRecordKind(prefix: "setting:", table: CloudBrainMergeTables.setting, listedValues: ["value"])
    public static let preferenceKind = CloudBrainRecordKind(prefix: "preference:", table: CloudBrainMergeTables.setting, listedValues: ["value"])
    /// Same everywhere (15 Nov): the screens' choices (side-panel pins and their order, open sections, page views) and
    /// each project's own settings. Sent only while every computer of the account knows them (`newKindsOpen`).
    public static let choiceKind = CloudBrainRecordKind(prefix: "choice:", table: CloudBrainMergeTables.setting, listedValues: ["value"])
    public static let projectKind = CloudBrainRecordKind(prefix: "project-setting:", table: CloudBrainMergeTables.setting, listedValues: ["value"])
    public static let exclusions = [
        "Settings about one device stay on it: folders, window places and sizes, which screen the Island uses, and how the device itself is reached.",
        "Sign-ins, keys, hook and MCP settings travel only through saved passwords or not at all.",
    ]
    public static let wideningHeld = "The default AI chosen on another device is applied here only while devices are trusted automatically with your account."
    public static let notUsable = "The value set on another device is not one this Mac can use."
    public static let tooManySchemes = "This Mac already has the most colour schemes another device may add."

    private let appSettings: BackendAppSettingsStore
    private let state: NativeStateStore?
    /// After settings arrived: (settings file changed, preferences changed). The app sends the two EXISTING events.
    private let display: @Sendable (_ app: Bool, _ preferences: Bool) async -> Void
    private let fullAccess: @Sendable () async -> Bool?
    private let kept: BackendCloudKindsKept?
    private nonisolated let settle: BackendCloudKindsSettle
    /// This account's record store, read only: tells a first copy (no change time) from a real change (CLOUD-KINDS-2).
    private let records: CloudBrainAgentsStore?
    /// Settings this Mac has handed on at least once (chosen here, or applied from the Cloud). Kept in one small file:
    /// once a setting is in it, it always travels, also when he sets it back to its default.
    private let chosenFile: URL?
    private var chosen: Set<String>
    /// Same everywhere (15 Nov): the screens' choices; nil = not read on this device (fixtures).
    private let choices: BackendCloudKindsChoices?
    /// Same everywhere: every computer of the account runs a build that knows the newer settings (the delete rule's
    /// gate, `DeckMemoryStore.cloudDeleteRuleIsOpen`). Closed: they are not sent; arriving ones are still taken.
    private let newKindsOpen: @Sendable () async -> Bool

    public init(appSettings: BackendAppSettingsStore, state: NativeStateStore?, display: @escaping @Sendable (_ app: Bool, _ preferences: Bool) async -> Void = { _, _ in },
                fullAccess: @escaping @Sendable () async -> Bool? = { false }, kept: BackendCloudKindsKept? = nil,
                settle: BackendCloudKindsSettle = .init(quiet: 0, now: { 0 }), records: CloudBrainAgentsStore? = nil, chosenFile: URL? = nil,
                choices: BackendCloudKindsChoices? = nil, newKindsOpen: @escaping @Sendable () async -> Bool = { false }) {
        self.appSettings = appSettings; self.state = state; self.display = display; self.fullAccess = fullAccess
        self.kept = kept; self.settle = settle; self.records = records; self.chosenFile = chosenFile
        self.choices = choices; self.newKindsOpen = newKindsOpen
        var loaded: Set<String> = []
        if let chosenFile, let data = try? Data(contentsOf: chosenFile), let list = try? JSONDecoder().decode([String].self, from: data) { loaded = Set(list) }
        chosen = loaded
    }

    static func kind(_ source: CloudBrainSettings.Source) -> CloudBrainRecordKind {
        switch source {
        case .app: return appKind
        case .preference: return preferenceKind
        case .choice: return choiceKind
        case .project: return projectKind
        }
    }
    static func entity(_ source: CloudBrainSettings.Source, _ key: String) -> String { kind(source).entity(key) }
    static func parse(_ entity: String) -> (source: CloudBrainSettings.Source, key: String)? {
        for source in CloudBrainSettings.Source.allCases { if let key = kind(source).id(of: entity) { return (source, key) } }
        return nil
    }
    /// A value this device holds that may go: its rule's shape takes it (the first ten settings keep their old test:
    /// any plain one value; a value they cannot use is held on the other side).
    static func sendable(_ rule: CloudBrainSettings.Travels, _ value: NativeRPCValue) -> Bool {
        rule.newer ? rule.shape.accepts(value) : CloudBrainSettings.isScalar(value)
    }
    static func record(_ key: String, _ value: NativeRPCValue) -> NativeRPCValue {
        .object([.init("key", .string(key)), .init("value", value)])
    }
    /// The travelling settings this Mac holds now, as records, read straight from the two stores (never settled).
    private func current() async -> [String: NativeRPCValue] {
        var result: [String: NativeRPCValue] = [:]
        let open = await newKindsOpen()
        func add(_ source: CloudBrainSettings.Source, _ key: String, _ value: NativeRPCValue) {
            guard let rule = CloudBrainSettings.rule(source, key), open || !rule.newer, Self.sendable(rule, value) else { return }
            result[Self.entity(source, key)] = Self.record(key, value)
        }
        for field in await appSettings.get()["values"].fields ?? [] { add(.app, field.key, field.value) }
        if let state {
            for field in await state.getPreferences().fields ?? [] { add(.preference, field.key, field.value) }
        }
        // Same everywhere (15 Nov): the screens' choices and each project's own settings (by project id, never a folder).
        if open {
            for (key, value) in choices?.values() ?? [:] { add(.choice, key, value) }
            for project in await appSettings.projectSettingsAll().fields ?? [] {
                for field in project.value.fields ?? [] { add(.project, project.key + "/" + field.key, field.value) }
            }
        }
        return result
    }
    public func count() async -> Int? { await visible().count }
    /// Cloud file manager: the value of every travelling setting this Mac holds now, by its record (`setting:<key>` …),
    /// in plain words for the page's rows (`BackendCloudManagerSettings.value`). A read only: nothing is marked chosen.
    public func shownValues() async -> [String: String] {
        var said: [String: String] = [:]
        for (entity, record) in await current() { said[entity] = BackendCloudManagerSettings.value(recordId: entity, record["value"]) }
        return said
    }
    /// CLOUD-KINDS-2, rule 1: a setting that still has its default here and was never handed on is "never chosen": it
    /// is not this Mac's record at all (not sent as a first copy), so the account's value applies to it at once.
    private func visible() async -> [String: NativeRPCValue] {
        var result: [String: NativeRPCValue] = [:], added = false
        for (entity, record) in await current() {
            if !chosen.contains(entity) {
                guard let parsed = Self.parse(entity) else { continue }
                if CloudBrainSettings.isDefault(parsed.source, parsed.key, record["value"]) { continue }
                chosen.insert(entity); added = true
            }
            result[entity] = record
        }
        if added { saveChosen() }
        return result
    }
    private func saveChosen() {
        guard let chosenFile, let data = try? JSONEncoder().encode(chosen.sorted()) else { return }
        try? data.write(to: chosenFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: chosenFile.path)
    }
    /// CLOUD-KINDS-2, rule 2: the Cloud's value of this setting is a first copy (it has no change time: some Mac's
    /// setting as it was when Cloud was switched on there), never a change he made.
    private func isFirstCopy(_ entity: String) -> Bool {
        guard let records, let key = try? CloudBrainRecordKey(domain: Self.domain, entity: entity),
              let view = try? records.view(key, table: CloudBrainMergeTables.setting), let stamp = view.stamps["value"],
              let graph = try? records.graph(key) else { return false }
        return graph.isBaseline(stamp.op)
    }

    // MARK: CloudBrainRecordOwner

    public func cloudRecords() async throws -> [String: NativeRPCValue] {
        settle.pass(await visible(), same: { CloudBrainRecordAdapter.equal($0, $1) })
    }
    public func cloudPlan(entity: String, cloud: NativeRPCValue?) async throws -> CloudBrainRecordPlan {
        guard let parsed = Self.parse(entity) else { throw CloudRecordRefusal(reason: "This is not a setting record.") }
        let source = parsed.source, key = parsed.key
        let mine = await visible()[entity]
        guard let rule = CloudBrainSettings.rule(source, key) else {
            return .init(store: mine, waiting: CloudBrainSettings.stayReason(source, key) ?? CloudBrainSettings.unlistedReason)
        }
        // Reset to its default on another device: nothing changes here.
        guard let cloud else { return .init(store: mine) }
        guard cloud["key"].string == key, usable(source) else { return .init(store: mine, waiting: Self.notUsable) }
        let value = cloud["value"]
        // CLOUD-KINDS-3: another device can never fill the settings file with colour schemes.
        if mine == nil, key.hasPrefix(TerminalSchemes.customPrefix) {
            let values = await appSettings.get()["values"].fields ?? []
            if values.filter({ $0.key.hasPrefix(TerminalSchemes.customPrefix) }).count >= CloudBrainSettings.maximumCustomSchemes {
                return .init(store: nil, waiting: Self.tooManySchemes)
            }
        }
        // Rule 2: two Macs he set up differently both keep their own value; a first copy never replaces a value he
        // chose here, in either direction, and nothing is listed for it. His next change anywhere travels as usual.
        if let mine, !CloudBrainRecordAdapter.equal(mine["value"], value), isFirstCopy(entity) { return .init(store: mine) }
        var reason: String?
        if !rule.shape.accepts(value) { reason = Self.notUsable }
        else if rule.widening, mine.map({ !CloudBrainRecordAdapter.equal($0["value"], value) }) ?? true, await fullAccess() != true { reason = Self.wideningHeld }
        if let reason { return .init(store: mine, held: ["value": reason]) }
        return .init(store: Self.record(key, value))
    }
    /// This device has the place the setting is kept in.
    private func usable(_ source: CloudBrainSettings.Source) -> Bool {
        switch source {
        case .app, .project: return true
        case .preference: return state != nil
        case .choice: return choices != nil
        }
    }
    public func cloudWrite(entity: String, value: NativeRPCValue, expecting: NativeRPCValue?) async throws {
        guard let parsed = Self.parse(entity), CloudBrainSettings.rule(parsed.source, parsed.key) != nil, value["key"].string == parsed.key else {
            throw CloudFailure.invalidRequest
        }
        let source = parsed.source, key = parsed.key
        let before = await visible()[entity]
        guard CloudBrainRecordAdapter.equal(before, expecting) else {
            throw CloudRecordRefusal(reason: "This setting changed on this Mac while a change from another device was being applied; it is applied on the next try.")
        }
        let patch = NativeRPCValue.object([.init(key, value["value"])])
        do {
            switch source {
            case .app: _ = try await appSettings.patch(patch)
            case .preference:
                guard let state else { throw CloudRecordRefusal(reason: Self.notUsable) }
                _ = try await state.setPreferences(patch)
            case .choice:
                guard let choices else { throw CloudRecordRefusal(reason: Self.notUsable) }
                do { try choices.write(key, value["value"]) } catch { throw CloudRecordRefusal(reason: Self.notUsable) }
            case .project:
                // A project not on this device yet keeps its settings under its id: they show as soon as it is here.
                guard let parts = CloudBrainSettings.projectParts(key) else { throw CloudRecordRefusal(reason: Self.notUsable) }
                _ = try await appSettings.patchProject(parts.project, values: .object([.init(parts.key, value["value"])]))
            }
        } catch let error as NativeRPCError { throw CloudRecordRefusal(reason: "Not applied on this Mac: " + error.message) }
        if let before, !CloudBrainRecordAdapter.equal(before, value) { kept?.keep(record: entity, value: before) }
        if chosen.insert(entity).inserted { saveChosen() }
        settle.wrote(entity, value)
    }
    public func cloudImported(_ entities: [String]) async {
        let parsed = entities.compactMap(Self.parse)
        let app = parsed.contains { $0.source == .app || $0.source == .project }, preferences = parsed.contains { $0.source == .preference }
        if app || preferences { await display(app, preferences) }
        choices?.announce(parsed.filter { $0.source == .choice }.map(\.key))
    }
    /// CLOUD-KINDS-3: settings that arrived from the Cloud reach the screens through the same two events, with the same
    /// payloads, as a change made here: "settings:changed" with the stored settings (as `settings:set` answers) and
    /// "prefs:changed" with the saved preferences (as `writePreferencesAsync` answers). No new event, no new field.
    public static func announce(app: Bool, preferences: Bool, settings: BackendAppSettingsStore, state: NativeStateStore?,
                                publish: @Sendable (String, NativeRPCValue) async -> Void) async {
        if app { await publish("settings:changed", await settings.get()) }
        if preferences, let state { await publish("prefs:changed", await state.getPreferences()) }
    }
    /// A change of the device-trust setting looks at held default-AI choices again.
    public func cloudContext() async -> String {
        switch await fullAccess() {
        case true?: return "access:full"
        case false?: return "access:ask"
        case nil: return "access:?"
        }
    }

    public nonisolated func adapter(store: CloudBrainAgentsStore, account: CloudBrainAgentsAccount, origins: CloudBrainRecordOrigins) throws -> CloudBrainRecordAdapter {
        try CloudBrainRecordAdapter(domain: Self.domain, inventoryRow: Self.inventoryRow, sourceId: Self.sourceID,
            kinds: [Self.appKind, Self.preferenceKind, Self.choiceKind, Self.projectKind], store: store, account: account, owner: self, origins: origins, exclusions: Self.exclusions)
    }
}
