import Foundation
import TerminalDeckNativeCore

/// Lane L3, first slice (14 Nov): tasks (row I12) and settings (row I21) in the Cloud, on the same record rule as
/// projects and agents (newest wins per field, lists merge item by item, a joining Mac's first copy loses, the other
/// value is kept). Built for one signed-in account by the app's wiring (`NativeCloudBrainRegistration`); it registers
/// nothing by itself. Its own bookkeeping lives in `<cloud folder>/<account>/kinds`, apart from lane A2's.
public struct BackendCloudKinds: Sendable {
    public static let tasksRow = BackendCloudKindsTasks.inventoryRow
    public static let settingsRow = BackendCloudKindsSettings.inventoryRow
    public static let rows: Set<String> = [tasksRow, settingsRow]
    /// How often this Mac's tasks and settings are looked at for changes. A change is sent once it has stayed the same
    /// for `quiet` (a slider being dragged, a window being resized or an agent typing into a task sends ONE record).
    public static let every: Duration = .seconds(2)
    public static let quiet: Double = 2_000

    public static func domains(_ enabledRows: Set<String>) throws -> Set<String> {
        var domains: Set<String> = []
        if enabledRows.contains(tasksRow) { domains.insert(try CloudWire.domain(BackendCloudKindsTasks.domain)) }
        if enabledRows.contains(settingsRow) { domains.insert(try CloudWire.domain(BackendCloudKindsSettings.domain)) }
        return domains
    }

    public let tasks: BackendCloudKindsTasks?
    public let settings: BackendCloudKindsSettings?
    public let adapters: [CloudBrainRecordAdapter]
    public let activation: CloudBrainRecordActivation
    public let store: CloudBrainAgentsStore
    public let kept: BackendCloudKindsKept

    /// - `cloudFolder`: the app's Cloud folder (`NativeCloudLaunch.folder(dataRoot)`).
    /// - `taskStore`, `projects`: the app's one task list and this Mac's projects (id and folders), read only.
    /// - `appSettings`, `state`: the settings file and the app state that hold the travelling settings.
    /// - `tasksChanged`, `settingsChanged`: DISPLAY ONLY refreshes after an import; never the task change hub.
    /// - `fullAccess`: the device-trust setting is "Automatically, with my account" (Y2).
    /// - `choices`, `newKindsOpen` (same everywhere, 15 Nov): the screens' remembered choices, and the gate that lets the
    ///   settings added on 15 Nov go out (every computer of the account runs a build that knows them).
    /// Returns nil when neither row is switched on or neither owner exists.
    public static func make(enabledRows: Set<String>, cloudFolder: URL, subjectHash: String, deviceId: String,
                            serviceTime: @escaping @Sendable () -> Int64?,
                            taskStore: BackendTaskStore?, projects: @escaping @Sendable () async -> [BackendCloudKindsProject]?,
                            appSettings: BackendAppSettingsStore?, state: NativeStateStore?,
                            tasksChanged: @escaping @Sendable () async -> Void = {},
                            settingsChanged: @escaping @Sendable (_ app: Bool, _ preferences: Bool) async -> Void = { _, _ in },
                            fullAccess: @escaping @Sendable () async -> Bool? = { false },
                            choices: BackendCloudKindsChoices? = nil,
                            newKindsOpen: @escaping @Sendable () async -> Bool = { false },
                            now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                            every interval: Duration? = BackendCloudKinds.every) throws -> BackendCloudKinds? {
        let wantsTasks = enabledRows.contains(tasksRow) && taskStore != nil
        let wantsSettings = enabledRows.contains(settingsRow) && appSettings != nil
        guard wantsTasks || wantsSettings else { return nil }
        let account = try CloudBrainAgentsAccount(subjectHash: subjectHash, deviceID: deviceId)
        let folder = cloudFolder.standardizedFileURL
        let own = folder.appendingPathComponent(subjectHash).appendingPathComponent("kinds")
        let store = try CloudBrainAgentsStore(directory: own, account: account, clock: .service(serviceTime))
        // Which account each task or setting came from: one file for the Mac, beside (not inside) lane A2's.
        let origins = try CloudBrainRecordOrigins(cloudFolder: folder, account: subjectHash, fileName: "kinds-origins.json")
        let kept = try BackendCloudKindsKept(file: own.appendingPathComponent("replaced-values.json"), now: now)
        var adapters: [CloudBrainRecordAdapter] = []
        var tasks: BackendCloudKindsTasks?, settings: BackendCloudKindsSettings?
        if wantsTasks, let taskStore {
            let owner = BackendCloudKindsTasks(store: taskStore, projects: projects, display: tasksChanged, kept: kept,
                settle: BackendCloudKindsSettle(quiet: quiet, now: now))
            adapters.append(try owner.adapter(store: store, account: account, origins: origins)); tasks = owner
        }
        if wantsSettings, let appSettings {
            let owner = BackendCloudKindsSettings(appSettings: appSettings, state: state, display: settingsChanged, fullAccess: fullAccess,
                kept: kept, settle: BackendCloudKindsSettle(quiet: quiet, now: now), records: store,
                chosenFile: own.appendingPathComponent("settings-chosen.json"), choices: choices, newKindsOpen: newKindsOpen)
            adapters.append(try owner.adapter(store: store, account: account, origins: origins)); settings = owner
        }
        return .init(tasks: tasks, settings: settings, adapters: adapters,
            activation: try CloudBrainRecordActivation(adapters: adapters, store: store, every: interval), store: store, kept: kept)
    }

    /// The plain counts the Cloud pages show: tasks in this Mac's task list that travel, settings of his that travel.
    public func counts() async -> (tasks: Int?, settings: Int?) {
        (await tasks?.count(), await settings?.count())
    }
}

/// A project on this Mac as the tasks owner needs it: its id and its folders here (never sent).
public struct BackendCloudKindsProject: Sendable, Equatable {
    public let id: String
    public let folders: [String]
    public init(id: String, folders: [String]) { self.id = id; self.folders = folders }
}

/// "Send the settled value": a record is handed on only after it has stayed the same for `quiet` milliseconds. Until
/// then the owner keeps answering with the value it last handed on, so a value that flickers (a slider dragged, a
/// window resized, a task an agent keeps updating) becomes ONE record, not dozens. This is not grouping: every record
/// still goes on its own as soon as it settles. A record seen for the first time, and a removal, go at once.
public final class BackendCloudKindsSettle: @unchecked Sendable {
    private let lock = NSLock()
    private var shown: [String: NativeRPCValue] = [:]
    private var seen: [String: (value: NativeRPCValue, since: Double)] = [:]
    private let quiet: Double
    private let now: @Sendable () -> Double
    public init(quiet: Double, now: @escaping @Sendable () -> Double) { self.quiet = quiet; self.now = now }

    /// `same`: the part of a value whose change counts (a task's `updatedAt` alone never restarts the wait).
    public func pass(_ current: [String: NativeRPCValue], same: (NativeRPCValue, NativeRPCValue) -> Bool) -> [String: NativeRPCValue] {
        lock.withLock {
            if quiet <= 0 { shown = current; seen = [:]; return current }
            let time = now()
            var result: [String: NativeRPCValue] = [:]
            for (entity, value) in current {
                guard let before = shown[entity] else { shown[entity] = value; result[entity] = value; continue }
                if same(before, value) { shown[entity] = value; seen[entity] = nil; result[entity] = value; continue }
                if let waiting = seen[entity], same(waiting.value, value) {
                    if time - waiting.since >= quiet { shown[entity] = value; seen[entity] = nil; result[entity] = value }
                    else { result[entity] = before }
                } else {
                    seen[entity] = (value, time); result[entity] = before
                }
            }
            for entity in Array(shown.keys) where current[entity] == nil { shown[entity] = nil; seen[entity] = nil }
            return result
        }
    }
    /// A value written here from the Cloud is this Mac's value at once (never handed back as a change of its own).
    public func wrote(_ entity: String, _ value: NativeRPCValue?) {
        lock.withLock { shown[entity] = value; seen[entity] = nil }
    }
}

/// Lane L1's version keeper is not in this base, so the simplest keeper: when a value from another device replaces a
/// different value here, the value this Mac had is written to one small file on this Mac and kept for 30 days. Costs no
/// Cloud writes. Nothing reads it automatically; it is there so nothing he set is ever silently lost.
public final class BackendCloudKindsKept: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public let record: String
        public let value: String
        public let replacedAt: Int64
        public let keptUntil: Int64
    }
    public static let days: Int64 = 30
    public static let maximumEntries = 2_000
    private let lock = NSLock()
    private let file: URL
    private let now: @Sendable () -> Double
    public init(file: URL, now: @escaping @Sendable () -> Double) throws {
        self.file = file; self.now = now
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func read() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
    public func entries() -> [Entry] {
        lock.withLock { read().filter { $0.keptUntil > Int64(now()) } }
    }
    public func keep(record: String, value: NativeRPCValue) {
        lock.withLock {
            let at = Int64(now())
            var all = read().filter { $0.keptUntil > at }
            all.append(.init(record: record, value: value.compact, replacedAt: at, keptUntil: at + Self.days * 86_400_000))
            if all.count > Self.maximumEntries { all.removeFirst(all.count - Self.maximumEntries) }
            guard let data = try? JSONEncoder().encode(all) else { return }
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
