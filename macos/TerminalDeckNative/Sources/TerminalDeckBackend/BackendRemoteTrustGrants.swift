import Foundation
import TerminalDeckNativeCore

public struct BackendRemoteDeviceReach: Sendable {
    public let kind: BackendRemoteDeviceKind
    public let unrestricted: Bool
    public let folders: [String]
    public let accounts: [String]?
    public let drivesWindows: Bool
}

extension BackendRemoteTrustStore {
    public func kindOf(_ id: String) -> BackendRemoteDeviceKind { kinds[id]?.kind ?? .guest }
    public func kindDecided(_ id: String) -> Bool { kinds[id] != nil }
    public func grantedFolders(_ id: String) -> [String]? { folderGrants[id] }
    public func accountAllowed(_ id: String, account: String) -> Bool { accountGrants[id].map { $0.all || $0.ids.contains(account) } ?? true }
    public func hasAnyAccount(_ id: String) -> Bool { accountGrants[id].map { $0.all || !$0.ids.isEmpty } ?? true }
    public func sessionShared(_ id: String, session: String) -> Bool { sessionGrants[id].map { $0.all || $0.ids.contains(session) } ?? true }
    public func drivesWindows(_ id: String) -> Bool { !windowDenied.contains(id) && (windowAllowed.contains(id) || kindOf(id) == .mine) }
    public func reach(_ id: String, offered: [String], home: String) -> BackendRemoteDeviceReach {
        let kind = kindOf(id)
        let folders = kind == .mine ? uniqueFolders(offered.isEmpty ? [home] : offered) : folderGrants[id] ?? []
        return .init(kind: kind, unrestricted: kind == .mine, folders: folders,
            accounts: accountGrants[id].flatMap { $0.all ? nil : $0.ids }, drivesWindows: drivesWindows(id))
    }
    public func canReachFolder(_ id: String, folder: String) -> Bool {
        if kindOf(id) == .mine { return true }
        return (folderGrants[id] ?? []).contains { Self.within($0, folder) }
    }
    func claimKind(_ id: String, kind: BackendRemoteDeviceKind) throws {
        if let existing = kinds[id] {
            guard existing.kind == kind else { throw BackendRemoteTrustFailure.denied("A device's approved kind cannot be silently changed.") }
            return
        }
        guard kinds.count < 64 else { throw BackendRemoteTrustFailure.storage("The device kind roster is full.") }
        var next = kinds; next[id] = KindRecord(kind: kind, decidedAt: clock())
        try saveDevices("remote-device-kinds.json", .object(next.sorted(by: { $0.key < $1.key }).map {
            .init($0.key, .object([.init("kind", .string($0.value.kind.rawValue)), .init("decidedAt", .number($0.value.decidedAt))]))
        }))
        kinds = next
    }
    public static func within(_ root: String, _ path: String) -> Bool {
        let folder = URL(fileURLWithPath: root).standardizedFileURL.path, child = URL(fileURLWithPath: path).standardizedFileURL.path
        return child == folder || child.hasPrefix(folder == "/" ? "/" : folder + "/")
    }
    private func uniqueFolders(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values where !value.isEmpty {
            let path = URL(fileURLWithPath: value).standardizedFileURL.path
            if !result.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == path }) { result.append(value) }
        }
        return result
    }
    private func cleanIDs(_ values: [String], max: Int, length: Int) -> [String] {
        var result: [String] = []
        for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !value.isEmpty && value.utf16.count <= length {
            if !result.contains(value) { result.append(value) }
            if result.count == max { break }
        }
        return result
    }
    private func saveDevices(_ name: String, _ value: NativeRPCValue) throws { try BackendRemoteTrustStorage.write(.object([.init("version", .number(1)), .init("devices", value)]), file: directory.appendingPathComponent(name)) }
    func loadGrants() {
        func read(_ name: String) -> NativeRPCValue { (try? BackendRemoteTrustStorage.read(directory.appendingPathComponent(name), maximumBytes: 262144)) ?? .object([]) }
        folderGrants = [:]
        for field in (read("remote-folders.json")["devices"].fields ?? []).prefix(64) {
            guard let values = field.value.elements else { continue }
            folderGrants[field.key] = Array(uniqueFolders(values.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("/") && $0.utf16.count <= 4096 }).prefix(64))
        }
        func shares(_ name: String, key: String, max: Int, length: Int) -> [String: Share] {
            var result: [String: Share] = [:]
            for field in (read(name)["devices"].fields ?? []).prefix(64) where field.value.fields != nil {
                let all = field.value["mode"].string == "all"
                result[field.key] = Share(all: all, ids: all ? [] : cleanIDs(field.value[key].elements?.compactMap(\.string) ?? [], max: max, length: length))
            }
            return result
        }
        sessionGrants = shares("remote-sessions.json", key: "sessions", max: 256, length: 128)
        accountGrants = shares("remote-accounts.json", key: "accounts", max: 64, length: 200)
        kinds = [:]
        for field in (read("remote-device-kinds.json")["devices"].fields ?? []).prefix(64) {
            guard let value = field.value["kind"].string, let kind = BackendRemoteDeviceKind(rawValue: value) else { continue }
            kinds[field.key] = KindRecord(kind: kind, decidedAt: field.value["decidedAt"].number ?? 0)
        }
        let windows = read("remote-windows.json")
        windowAllowed = Set(cleanIDs(windows["devices"].elements?.compactMap(\.string) ?? [], max: 64, length: 200))
        windowDenied = Set(cleanIDs(windows["denied"].elements?.compactMap(\.string) ?? [], max: 64, length: 200))
        windowAllowed.subtract(windowDenied)
        phoneAccessLevels = [:]
        for field in (read("remote-access.json")["devices"].fields ?? []).prefix(64) {
            if let raw = field.value.string, let level = BackendINT2PhoneAccessLevel(rawValue: raw) { phoneAccessLevels[field.key] = level }
        }
    }
}
