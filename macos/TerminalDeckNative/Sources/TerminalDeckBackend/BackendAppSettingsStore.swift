import Foundation
import Darwin
import TerminalDeckNativeCore

/// settings-store.ts. The app supplies the single data-folder writer; construction is inert.
public actor BackendAppSettingsStore {
    public static let version = 1, maxKeys = 500, maxKeyLength = 128, maxStringLength = 4096
    public static let snapshotFile = "settings.last-good.json"
    public static let browserPersistKey = "browser.persistSession", remoteEnabledKey = "remote.enabled"
    public let directory: URL
    private let writable: Bool
    private let now: @Sendable () -> Double
    private var cloudArchive: BackendCloudBrainAgentsArchive?
    private var cache: NativeRPCValue?
    private var carried: NativeRPCValue = .object([])
    private var backupBeforeWrite = false
    private var snapshotListeners: [(UUID, @Sendable (NativeRPCValue) -> Void)] = []

    public init(userData: URL, writable: Bool = false, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        directory = userData; self.writable = writable; self.now = now
    }
    public static func sanitize(_ raw: NativeRPCValue) -> NativeRPCValue {
        var result: [NativeRPCValue.Field] = []
        for field in raw.fields ?? [] {
            if result.count >= maxKeys { break }
            guard validKey(field.key) else { continue }
            switch field.value {
            case .bool: result.append(field)
            case .number(let n) where n.isFinite: result.append(field)
            case .string(let s): result.append(.init(field.key, .string(prefixUTF16(s, maxStringLength))))
            default: continue
            }
        }
        return .object(result)
    }
    public static func applyPatch(_ current: NativeRPCValue, _ patch: NativeRPCValue) -> NativeRPCValue {
        var next = current
        for field in patch.fields ?? [] where validKey(field.key) {
            if field.value.isNullish { next = next.removing(field.key); continue }
            let cleaned = sanitize(.object([field]))
            if cleaned.has(field.key) { next = next.setting(field.key, cleaned[field.key]) }
        }
        return sanitize(next)
    }
    /// U20 (#590): a patch whose new keys would pass `maxKeys` is refused, never cut off while the save reports success.
    static func patched(_ current: NativeRPCValue, _ patch: NativeRPCValue) throws -> NativeRPCValue {
        let next = applyPatch(current, patch)
        for field in patch.fields ?? [] where validKey(field.key) && !field.value.isNullish && sanitize(.object([field])).has(field.key) && !next.has(field.key) {
            throw NativeRPCError(code: "settings-full", message: "The settings already hold \(maxKeys) entries, so “\(field.key)” was not saved. Remove settings that are no longer used, then try again.")
        }
        return next
    }
    public func resetCache() { cache = nil; carried = .object([]); backupBeforeWrite = false }
    public func get() -> NativeRPCValue { envelope(load()) }
    public func observeSnapshot(_ listener: @escaping @Sendable (NativeRPCValue) -> Void) -> NativeRPCSubscription {
        let id = UUID(); snapshotListeners.append((id, listener)); listener(get())
        return NativeRPCSubscription(id: id) { [weak self] in await self?.removeSnapshotListener(id) }
    }
    private func removeSnapshotListener(_ id: UUID) { snapshotListeners.removeAll { $0.0 == id } }
    private func announceSnapshot() { let value = get(); for (_, listener) in snapshotListeners { listener(value) } }
    public func value(_ key: String) -> NativeRPCValue { load()[key] }
    /// Per-project values share the existing single writer, in a separate
    /// namespace. Global preferences retain their existing scalar format.
    public func projectSettings(_ projectID: String) -> NativeRPCValue {
        _ = load()
        let id = PROJProjects.resolve(projectID: projectID, folder: nil)
        return .object([.init("projectId", .string(id)), .init("values", Self.sanitize(carried["projectSettings"][id]))])
    }
    /// Same everywhere (15 Nov): every project's own settings, by project id, as `projectSettings(_:)` reads each one.
    public func projectSettingsAll() -> NativeRPCValue {
        _ = load()
        return .object((carried["projectSettings"].fields ?? []).map { .init($0.key, Self.sanitize($0.value)) })
    }
    public func patchProject(_ projectID: String, values: NativeRPCValue) throws -> NativeRPCValue {
        let global = load(), before = carried
        let id = PROJProjects.resolve(projectID: projectID, folder: nil)
        let projects = carried["projectSettings"].fields == nil ? NativeRPCValue.object([]) : carried["projectSettings"]
        carried = carried.setting("projectSettings", projects.setting(id, try Self.patched(projects[id], values)))
        do { try persist(global) } catch { carried = before; throw error }
        announceSnapshot()
        return projectSettings(id)
    }
    public func requireSupportedHootMigrationSource() throws {
        _ = load()
        guard !backupBeforeWrite else {
            throw NativeRPCError(code: "hoot-migration", message: "Hoot settings migration needs a readable, supported settings file.")
        }
    }
    public func patch(_ patch: NativeRPCValue) throws -> NativeRPCValue {
        let next = try Self.patched(load(), patch)
        try persist(next); cache = next; announceSnapshot(); return envelope(next)
    }
    /// Settings › Advanced › Start over. Kept (SETTINGS-TRUTH row 58): every project's own settings, and the protected
    /// keys no tool may change either (remote access, Hoot's own, safety, browser sessions, debug mode): before, a reset
    /// dropped project settings and removed `remote.enabled = false`, which turned remote access back on.
    public func reset() throws -> NativeRPCValue {
        let current = load()
        let kept = NativeRPCValue.object((current.fields ?? []).filter { BackendDeckToolsAppApplication.isProtected($0.key) })
        let projects = carried["projectSettings"]
        carried = projects.fields == nil ? .object([]) : .object([.init("projectSettings", projects)])
        try persist(kept); cache = kept; announceSnapshot(); return envelope(kept)
    }
    public func snapshot(preferences: NativeRPCValue, reason: String) throws -> NativeRPCValue {
        try requireWriter()
        var fromCache = false
        let settings: NativeRPCValue
        if let bytes = try? Data(contentsOf: file), let raw = try? NativeRPCValue.parseJSON(bytes) { settings = raw }
        else { settings = envelope(load()); fromCache = true }
        let at = now(), path = directory.appendingPathComponent(Self.snapshotFile)
        let payload = NativeRPCValue.object([.init("version", .number(1)), .init("at", .string(Self.iso(at))),
            .init("reason", .string(reason)), .init("settings", settings), .init("preferences", preferences), .init("fromCache", .bool(fromCache))])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try payload.encodedJSON(pretty: true); data.append(10)
        try data.write(to: path, options: .atomic)
        return .object([.init("path", .string(path.path)), .init("at", .number(at))])
    }
    // MARK: Cloud (lane A2). Reviewed personal preferences are shared; every later edit is a revision (finding 1).
    private var cloudImporting = false, cloudCaptureFailed = false
    public func cloudAttach(_ account: CloudBrainAgentsAccount) throws {
        if cloudArchive == nil { cloudArchive = .init(ownerDirectory: directory, namespace: "settings", domains: ["settings"]) }
        try cloudArchive!.attach(account)
    }
    public func cloudDetach() { cloudArchive?.detach() }
    private static func cloudRecords(values: NativeRPCValue, carried: NativeRPCValue) -> [CloudBrainAgentsRecord] {
        var records = (CloudBrainSettings.portable(values).fields ?? []).map {
            CloudBrainAgentsRecord(domain: "settings", id: $0.key, value: .object([.init("key", .string($0.key)), .init("value", $0.value)]))
        }
        for field in carried["projectSettings"].fields ?? [] {
            records.append(.init(domain: "settings", id: CloudBrainTasks.entity(kind: "project-settings", id: field.key),
                value: .object([.init("kind", .string("project-settings")), .init("projectId", .string(field.key)), .init("value", field.value)]), projectID: field.key))
        }
        return records
    }
    /// What settings.json holds now, read the way load() reads it.
    private func cloudDisk() throws -> (values: NativeRPCValue, carried: NativeRPCValue) {
        guard FileManager.default.fileExists(atPath: file.path) else { return (.object([]), .object([])) }
        guard let raw = try? NativeRPCValue.parseJSON(Data(contentsOf: file)), let fields = raw.fields, (raw["version"].number ?? 1) <= 1 else { throw CloudFailure.unavailable }
        return (Self.sanitize(raw["values"].fields != nil ? raw["values"] : raw), .object(fields.filter { $0.key != "version" && $0.key != "values" }))
    }
    private func cloudCaptureWritten(_ values: NativeRPCValue) {
        guard !cloudImporting, cloudArchive?.attached == true else { return }
        do { try cloudArchive!.capture(Self.cloudRecords(values: values, carried: carried), sourceID: "app-settings", complete: true) } catch { cloudCaptureFailed = true }
    }
    public func cloudSettingsInventory() throws -> [CloudCoverage] {
        let disk = try cloudDisk()
        var blocked = ["Per-project settings are kept in Cloud history but not restored on another device.", "Last-good settings snapshots are not exported by this adapter."]
        if (disk.values.fields ?? []).contains(where: { !CloudBrainSettings.portableKeys.contains($0.key) }) { blocked.append("Settings not yet classified as personal preferences stay on this Mac; their values were not exported.") }
        if cloudCaptureFailed { blocked.append("A save on this Mac could not be recorded for the Cloud yet; the next save or snapshot records it.") }
        return [try BackendCloudBrainAgentsSupport.coverage(row: "I11", sourceID: "app-settings", records: Self.cloudRecords(values: disk.values, carried: disk.carried),
            blocked: blocked, attention: cloudArchive?.attention() ?? [])]
    }
    public func cloudSettingsSnapshot(cut: CloudSnapshotCut) throws -> CloudBrainAgentsExport {
        guard cloudArchive?.attached == true else { throw CloudFailure.gateClosed }
        let disk = try cloudDisk()
        try cloudArchive!.capture(Self.cloudRecords(values: disk.values, carried: disk.carried), sourceID: "app-settings", complete: true)
        cloudCaptureFailed = false
        return .init(operations: try cloudArchive!.ownOperations(), coverage: try cloudSettingsInventory())
    }
    private static func cloudShape() -> CloudBrainAgentsShape { CloudBrainAgentsShape(show: { op, payload in
        if payload["kind"].string == "project-settings" {
            guard let project = payload["projectId"].string, CloudBrainTasks.entity(kind: "project-settings", id: project) == op.entityId else { throw CloudFailure.invalidRequest }
            return nil
        }
        guard payload["key"].string == op.entityId, CloudBrainSettings.portableKeys.contains(op.entityId), CloudBrainSettings.isScalar(payload["value"]),
              Set((payload.fields ?? []).map(\.key)) == ["key", "value"],
              BackendAppSettingsStore.sanitize(.object([.init(op.entityId, payload["value"])]))[op.entityId] == payload["value"] else { throw CloudFailure.invalidRequest }
        return payload
    }) }
    public func cloudSettingsImport(_ operations: [CloudOperation]) throws -> [CloudItemResult] {
        try requireWriter(); let values = load(); guard !backupBeforeWrite else { throw CloudFailure.unavailable }
        guard cloudArchive?.attached == true else { throw CloudFailure.gateClosed }
        let current = Dictionary(Self.cloudRecords(values: values, carried: carried).map { ($0.key, $0.value.raw) }, uniquingKeysWith: { first, _ in first })
        cloudImporting = true; defer { cloudImporting = false }
        return try cloudArchive!.importing(operations, current: { current[$0] }, shape: Self.cloudShape(), write: { try self.cloudWrite($0) })
    }
    private func cloudWrite(_ items: [CloudBrainAgentsProjection]) throws -> [String: NativeRPCValue?] {
        var patch = NativeRPCValue.object([])
        for item in items { if let image = item.image, let key = image["key"].string { patch = patch.setting(key, image["value"]) } }
        if !(patch.fields ?? []).isEmpty { _ = try self.patch(patch) }
        let after = Dictionary(Self.cloudRecords(values: load(), carried: carried).map { ($0.key, $0.value.raw) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(items.map { ($0.key, after[$0.key]) }, uniquingKeysWith: { first, _ in first })
    }
    public func cloudSettingsRetained(_ operations: [CloudOperation]) throws -> Bool { try cloudArchive?.retained(operations) ?? false }
    public func cloudSettingsVersions() throws -> [CloudOperation] { try cloudArchive?.revisions() ?? [] }
    public func cloudSettingsOwnChanges(after: String?, limit: Int) throws -> [CloudOperation] { guard let cloudArchive else { throw CloudFailure.gateClosed }; return try cloudArchive.ownChanges(after: after, limit: limit) }
    public func cloudSettingsCursor() throws -> String? { guard let cloudArchive else { throw CloudFailure.gateClosed }; return try cloudArchive.cursor() }
    public func cloudSettingsSaveCursor(_ value: String) throws { guard cloudArchive != nil else { throw CloudFailure.gateClosed }; try cloudArchive!.saveCursor(value) }
    public func cloudSettingsNotices() -> AsyncStream<Void> {
        guard cloudArchive != nil else { return AsyncStream { $0.finish() } }
        return cloudArchive!.notices()
    }
    private var file: URL { directory.appendingPathComponent("settings.json") }
    private func envelope(_ values: NativeRPCValue) -> NativeRPCValue { .object([.init("version", .number(1)), .init("values", values)]) }
    private func load() -> NativeRPCValue {
        if let cache { return cache }
        cache = .object([]); carried = .object([]); backupBeforeWrite = false
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch {
            let ns = error as NSError
            backupBeforeWrite = !(ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError)
            return cache!
        }
        guard let raw = try? NativeRPCValue.parseJSON(data), let fields = raw.fields else {
            backupBeforeWrite = true; return cache!
        }
        cache = Self.sanitize(raw["values"].fields != nil ? raw["values"] : raw)
        carried = .object(fields.filter { $0.key != "version" && $0.key != "values" })
        if let v = raw["version"].number, v > 1 { backupBeforeWrite = true }
        return cache!
    }
    private func persist(_ values: NativeRPCValue) throws {
        try requireWriter()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if backupBeforeWrite {
            _ = Darwin.rename(file.path, file.path + ".bak-" + String(Int64(now())))
            backupBeforeWrite = false
        }
        let payload = carried.setting("version", .number(1)).setting("values", values)
        try payload.encodedJSON(pretty: true).write(to: file, options: .atomic)
        cloudCaptureWritten(values)
    }
    private func requireWriter() throws {
        guard writable else { throw NativeRPCError(code: "unavailable", message: "Native settings persistence is unavailable until the app transfers its single writer") }
    }
    private static func validKey(_ key: String) -> Bool { key != "__proto__" && !key.isEmpty && key.utf16.count <= maxKeyLength }
    private static func prefixUTF16(_ text: String, _ count: Int) -> String { String(decoding: text.utf16.prefix(count), as: UTF16.self) }
    public static func iso(_ at: Double) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: at / 1000))
    }
}
