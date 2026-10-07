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
    public func setFolderGrants(_ id: String, folders: [String]) throws {
        try requireOpen(); try knownDevice(id)
        let cleaned = uniqueFolders(folders.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.hasPrefix("/") && $0.utf16.count <= 4096 }).prefix(64)
        var next = folderGrants; next[id] = Array(cleaned)
        try saveDevices("remote-folders.json", .object(next.sorted(by: { $0.key < $1.key }).map { .init($0.key, .array($0.value.map(NativeRPCValue.string))) }))
        folderGrants = next; onChanged?()
    }
    public func setSessionGrants(_ id: String, all: Bool, sessions: [String]) throws {
        try requireOpen(); try knownDevice(id)
        var next = sessionGrants; next[id] = Share(all: all, ids: all ? [] : cleanIDs(sessions, max: 256, length: 128))
        try saveShares("remote-sessions.json", next, key: "sessions"); sessionGrants = next; onChanged?()
    }
    public func includeStartedSession(_ id: String, session: String) throws {
        guard var grant = sessionGrants[id], !grant.all, !grant.ids.contains(session), grant.ids.count < 256 else { return }
        grant.ids.append(session)
        var next = sessionGrants; next[id] = grant
        try saveShares("remote-sessions.json", next, key: "sessions"); sessionGrants = next; onChanged?()
    }
    public func setAccountGrants(_ id: String, all: Bool, accounts: [String]) throws {
        try requireOpen(); try knownDevice(id)
        var next = accountGrants; next[id] = Share(all: all, ids: all ? [] : cleanIDs(accounts, max: 64, length: 200))
        try saveShares("remote-accounts.json", next, key: "accounts"); accountGrants = next; onChanged?()
    }
    public func setWindowGrant(_ id: String, drives: Bool) throws {
        try requireOpen(); try knownDevice(id)
        var allowed = windowAllowed, denied = windowDenied
        if drives { allowed.insert(id); denied.remove(id) } else { allowed.remove(id); denied.insert(id) }
        try BackendRemoteTrustStorage.write(.object([.init("version", .number(1)), .init("devices", .array(allowed.sorted().map(NativeRPCValue.string))),
            .init("denied", .array(denied.sorted().map(NativeRPCValue.string)))]), file: directory.appendingPathComponent("remote-windows.json"))
        windowAllowed = allowed; windowDenied = denied; onChanged?()
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
    public func forgetGrants(_ id: String) throws {
        try requireOpen()
        var folders = folderGrants, sessions = sessionGrants, accounts = accountGrants, nextKinds = kinds
        folders[id] = nil; sessions[id] = nil; accounts[id] = nil; nextKinds[id] = nil
        try saveDevices("remote-folders.json", .object(folders.map { .init($0.key, .array($0.value.map(NativeRPCValue.string))) }))
        try saveShares("remote-sessions.json", sessions, key: "sessions")
        try saveShares("remote-accounts.json", accounts, key: "accounts")
        try saveDevices("remote-device-kinds.json", .object(nextKinds.map { .init($0.key, .object([.init("kind", .string($0.value.kind.rawValue)), .init("decidedAt", .number($0.value.decidedAt))])) }))
        folderGrants = folders; sessionGrants = sessions; accountGrants = accounts; kinds = nextKinds
        windowAllowed.remove(id); windowDenied.remove(id)
        try BackendRemoteTrustStorage.write(.object([.init("version", .number(1)), .init("devices", .array(windowAllowed.sorted().map(NativeRPCValue.string))),
            .init("denied", .array(windowDenied.sorted().map(NativeRPCValue.string)))]), file: directory.appendingPathComponent("remote-windows.json"))
        onChanged?()
    }
    public static func within(_ root: String, _ path: String) -> Bool {
        let folder = URL(fileURLWithPath: root).standardizedFileURL.path, child = URL(fileURLWithPath: path).standardizedFileURL.path
        return child == folder || child.hasPrefix(folder == "/" ? "/" : folder + "/")
    }
    private func knownDevice(_ id: String) throws { guard devices.contains(where: { $0.id == id }), !id.isEmpty else { throw BackendRemoteTrustFailure.denied("The device is not in the trust roster.") } }
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
    private func saveShares(_ name: String, _ shares: [String: Share], key: String) throws {
        try saveDevices(name, .object(shares.sorted(by: { $0.key < $1.key }).map {
            .init($0.key, .object([.init("mode", .string($0.value.all ? "all" : "selected")), .init(key, .array($0.value.ids.map(NativeRPCValue.string)))]))
        }))
    }
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
    }
}
