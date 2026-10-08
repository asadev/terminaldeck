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
    public func resetCache() { cache = nil; carried = .object([]); backupBeforeWrite = false }
    public func get() -> NativeRPCValue { envelope(load()) }
    public func observeSnapshot(_ listener: @escaping @Sendable (NativeRPCValue) -> Void) -> NativeRPCSubscription {
        let id = UUID(); snapshotListeners.append((id, listener)); listener(get())
        return NativeRPCSubscription(id: id) { [weak self] in await self?.removeSnapshotListener(id) }
    }
    private func removeSnapshotListener(_ id: UUID) { snapshotListeners.removeAll { $0.0 == id } }
    private func announceSnapshot() { let value = get(); for (_, listener) in snapshotListeners { listener(value) } }
    public func value(_ key: String) -> NativeRPCValue { load()[key] }
    public func requireSupportedHootMigrationSource() throws {
        _ = load()
        guard !backupBeforeWrite else {
            throw NativeRPCError(code: "hoot-migration", message: "Hoot settings migration needs a readable, supported settings file.")
        }
    }
    public func patch(_ patch: NativeRPCValue) throws -> NativeRPCValue {
        let next = Self.applyPatch(load(), patch)
        try persist(next); cache = next; announceSnapshot(); return envelope(next)
    }
    public func reset() throws -> NativeRPCValue {
        _ = load(); carried = .object([])
        let empty = NativeRPCValue.object([])
        try persist(empty); cache = empty; announceSnapshot(); return envelope(empty)
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
