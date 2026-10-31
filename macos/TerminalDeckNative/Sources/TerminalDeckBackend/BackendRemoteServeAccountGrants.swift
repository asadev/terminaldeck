import Foundation
import TerminalDeckNativeCore

/// Additions to the single existing trust owner, not a second grant store.
public struct BackendRemoteServeAccountGrant: Equatable, Sendable {
    public let deviceID: String
    public let all: Bool
    public let accounts: [String]
    public var wireValue: NativeRPCValue { .object([.init("deviceId", .string(deviceID)), .init("mode", .string(all ? "all" : "selected")), .init("accounts", .array(accounts.map(NativeRPCValue.string)))]) }
}

enum BackendRemoteServeAccountGrantStorage {
    /// ECMAScript String.trim whitespace and line terminators. In particular,
    /// BOM is whitespace, while NEL (U+0085) is an ordinary retained character.
    private static let ecmaWhitespace = CharacterSet(charactersIn: "\u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{00a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")
    static func trim(_ text: String) -> String { text.trimmingCharacters(in: ecmaWhitespace) }
    static func read(directory: URL, name: String, report: @Sendable (String) -> Void) -> NativeRPCValue? {
        let file = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            // Node's readFileSync('utf8') ceiling is a UTF-16 string length,
            // despite the constant being named MAX_FILE_BYTES.
            guard let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 4 * 256 * 1024 else { return nil }
            let data = try Data(contentsOf: file), text = String(decoding: data, as: UTF8.self)
            guard text.utf16.count <= 256 * 1024 else { report("[remote] the remote grant list is implausibly large; ignoring it"); return nil }
            return try NativeRPCValue.parseJSON(Data(text.utf8), maximumBytes: 4 * 256 * 1024)
        } catch { report("[remote] could not read the remote grant list: " + error.localizedDescription); return nil }
    }
    static func clean(_ values: [NativeRPCValue], maximum: Int, length: Int) -> [String] {
        var kept: [String] = []
        for value in values {
            guard let text = value.string else { continue }
            let id = trim(text)
            guard !id.isEmpty, id.utf16.count <= length, !kept.contains(id) else { continue }
            kept.append(id)
            if kept.count == maximum { break }
        }
        return kept
    }
    static func write(devices: [NativeRPCValue.Field], directory: URL, name: String) throws {
        let raw = NativeRPCValue.object([.init("version", .number(1)), .init("devices", .object(devices))])
        var data = try raw.encodedJSON(pretty: true); data.append(0x0A)
        try BackendRemoteServeSecretFile.write(directory: directory, file: directory.appendingPathComponent(name), contents: data)
    }
}

extension BackendRemoteTrustStore {
    /// Install at the existing trust owner's startup in place of the three
    /// foundation grant loads. It retains absent versus selected-empty and
    /// counts accepted devices, not malformed JSON keys, against the ceiling.
    public func remoteServeReloadDomainGrants(report: @escaping @Sendable (String) -> Void = { _ in }) throws {
        try requireOpen()
        folderGrants = [:]; accountGrants = [:]; sessionGrants = [:]
        let folders = BackendRemoteServeAccountGrantStorage.read(directory: directory, name: "remote-folders.json", report: report)
        for field in folders?["devices"].fields ?? [] {
            guard !field.key.isEmpty, folderGrants.count < 64, let values = field.value.elements else { continue }
            folderGrants[field.key] = BackendRemoteServeSessionPolicy.cleanFolders(values)
        }
        func decode(_ name: String, key: String, maximum: Int, length: Int) -> [String: Share] {
            let raw = BackendRemoteServeAccountGrantStorage.read(directory: directory, name: name, report: report)
            var rows: [String: Share] = [:]
            for field in raw?["devices"].fields ?? [] {
                guard !field.key.isEmpty, rows.count < 64, field.value.fields != nil else { continue }
                let all = field.value["mode"].string == "all"
                rows[field.key] = Share(all: all, ids: all ? [] : BackendRemoteServeAccountGrantStorage.clean(field.value[key].elements ?? [], maximum: maximum, length: length))
            }
            return rows
        }
        accountGrants = decode("remote-accounts.json", key: "accounts", maximum: 64, length: 200)
        sessionGrants = decode("remote-sessions.json", key: "sessions", maximum: 256, length: 128)
    }
    public func remoteServeAccountGrant(_ deviceID: String) -> BackendRemoteServeAccountGrant? {
        guard !deviceID.isEmpty, let row = accountGrants[deviceID] else { return nil }
        return .init(deviceID: deviceID, all: row.all, accounts: row.ids)
    }
    public func remoteServeAccountGrants() -> [BackendRemoteServeAccountGrant] {
        accountGrants.sorted { $0.key < $1.key }.map { .init(deviceID: $0.key, all: $0.value.all, accounts: $0.value.ids) }
    }
    /// Matches AccountGrants.set: mode other than exactly all is selected; an
    /// empty device or a 65th device returns the clean choice without a write.
    @discardableResult public func remoteServeSetAccountGrants(_ deviceID: String, mode: NativeRPCValue, accounts: [NativeRPCValue]) throws -> BackendRemoteServeAccountGrant {
        let all = mode.string == "all", ids = mode.string == "all" ? [] : BackendRemoteServeAccountGrantStorage.clean(accounts, maximum: 64, length: 200)
        let answer = BackendRemoteServeAccountGrant(deviceID: deviceID, all: all, accounts: ids)
        guard !deviceID.isEmpty, accountGrants[deviceID] != nil || accountGrants.count < 64 else { return answer }
        try requireOpen()
        var next = accountGrants; next[deviceID] = Share(all: all, ids: ids)
        try remoteServePersistAccounts(next); accountGrants = next
        return answer
    }
    @discardableResult public func remoteServeForgetAccountGrants(_ deviceID: String) throws -> Bool {
        guard accountGrants[deviceID] != nil else { return false }
        try requireOpen(); var next = accountGrants; next[deviceID] = nil
        try remoteServePersistAccounts(next); accountGrants = next; return true
    }
    @discardableResult public func remoteServeDropAccount(_ accountID: String) throws -> Bool {
        guard !accountID.isEmpty, accountGrants.values.contains(where: { $0.ids.contains(accountID) }) else { return false }
        try requireOpen(); var next = accountGrants
        for (id, row) in next where row.ids.contains(accountID) { next[id] = Share(all: row.all, ids: row.ids.filter { $0 != accountID }) }
        try remoteServePersistAccounts(next); accountGrants = next; return true
    }
    private func remoteServePersistAccounts(_ rows: [String: Share]) throws {
        try BackendRemoteServeAccountGrantStorage.write(devices: rows.sorted { $0.key < $1.key }.map { .init($0.key, .object([
            .init("mode", .string($0.value.all ? "all" : "selected")), .init("accounts", .array($0.value.ids.map(NativeRPCValue.string)))])) }, directory: directory, name: "remote-accounts.json")
    }
}
