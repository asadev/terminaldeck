import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Source-compatible remote/access-keys.json. Views never contain hashes or signing secrets.
public actor BackendDeckCoreSecurityAccessKeys {
    public static let fileName = "access-keys.json"
    public static let keyPrefix = "ak_"
    public static let maximumKeys = 50
    public static let maximumName = 60
    public static let maximumFolders = 20
    public let file: URL
    private let now: @Sendable () -> Double
    private var state: NativeRPCValue = .object([.init("v", .number(1)), .init("internet", .bool(false)), .init("port", .null), .init("keys", .array([]))])
    private var loaded = false
    private var problem: String?
    private var lastFlush: Double = 0
    private var dirty = false
    private var listeners: [UUID: @Sendable () -> Void] = [:]
    private var authorityListeners: [UUID: @Sendable (Set<String>, Bool) -> Void] = [:]
    public init(directory: URL, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        file = directory.appendingPathComponent(Self.fileName); self.now = now
    }
    /// Explicit load lets app composition wait until the old writer relinquishes ownership.
    public func load() {
        guard !loaded else { return }; loaded = true
        do {
            guard let data = try BackendAccountFiles.boundedRead(file, maximum: 4 * 1024 * 1024) else { return }
            let raw = try NativeRPCValue.parseJSON(data)
            guard raw.fields != nil, raw["v"].number == 1 else { throw NativeRPCError.malformed("not a version-1 key file") }
            let keys = (raw["keys"].elements ?? []).compactMap(Self.storedKey).prefix(Self.maximumKeys)
            let port = raw["port"].number
            state = .object([.init("v", .number(1)), .init("internet", .bool(raw["internet"].bool == true)),
                             .init("port", port != nil && port!.rounded(.towardZero) == port! ? .number(port!) : .null), .init("keys", .array(Array(keys)))])
        } catch {
            problem = "The saved access keys could not be read, so none of them work. Make new keys for the apps that need one."
            // Copy, never move or overwrite, the unreadable source.
            try? FileManager.default.copyItem(at: file, to: URL(fileURLWithPath: file.path + ".unreadable-\(Int(now()))"))
        }
    }
    private func ready() { if !loaded { load() } }
    private var records: [NativeRPCValue] { state["keys"].elements ?? [] }
    public func loadProblem() -> String? { ready(); return problem }
    public func list() -> [NativeRPCValue] { ready(); return records.sorted { ($0["createdAt"].number ?? 0) > ($1["createdAt"].number ?? 0) }.map(Self.view) }
    public func get(id: String) -> NativeRPCValue? { ready(); return records.first { $0["id"].string == id }.map(Self.view) }
    public func internet() -> Bool { ready(); return state["internet"].bool == true }
    public func port() -> Int? { ready(); guard let n = state["port"].number, n >= Double(Int.min), n < Double(Int.max) else { return nil }; return Int(n) }
    public func create(_ input: NativeRPCValue) throws -> NativeRPCValue {
        ready()
        guard records.count < Self.maximumKeys else { throw Self.refused("There are already 50 keys. Revoke one you no longer use first.") }
        let name = try Self.cleanName(input["name"])
        let level = try Self.level(input["level"])
        let secret = Self.keyPrefix + BackendRemoteTrustStorage.base64URL(try BackendRemoteTrustStorage.random(32))
        var key = NativeRPCValue.object([.init("id", .string(UUID().uuidString.lowercased())), .init("name", .string(name)), .init("level", .string(level)),
            .init("askFirst", .bool(input["askFirst"].bool != false)), .init("folders", try Self.cleanFolders(input["folders"])),
            .init("tasks", .bool(false)), .init("hash", .string(Self.hash(secret))), .init("createdAt", .number(now())),
            .init("lastUsedAt", .null), .init("lastApp", .null), .init("lastVia", .null),
            .init("notify", .object([.init("mode", .string("wait")), .init("url", .null), .init("secret", .null)]))])
        if input["crmOnly"].bool == true { key = key.setting("crmOnly", .bool(true)) }
        state = state.setting("keys", .array(records + [key])); try save()
        return .object([.init("key", .string(secret)), .init("view", Self.view(key))])
    }
    public func rename(id: String, name: NativeRPCValue) throws -> NativeRPCValue { try change(id) { try $0.setting("name", .string(Self.cleanName(name))) } }
    public func setLevel(id: String, level: NativeRPCValue) throws -> NativeRPCValue { let level = try Self.level(level); return try change(id) { $0.setting("level", .string(level)) } }
    public func setAskFirst(id: String, askFirst: NativeRPCValue) throws -> NativeRPCValue { try change(id) { $0.setting("askFirst", .bool(askFirst.bool != false)) } }
    public func setFolders(id: String, folders: NativeRPCValue) throws -> NativeRPCValue { try change(id) { try $0.setting("folders", Self.cleanFolders(folders)) } }
    public func setTasks(id: String, on: NativeRPCValue) throws -> NativeRPCValue { try change(id) { $0.setting("tasks", .bool(on.bool == true)) } }
    public func revoke(id: String) throws -> Bool {
        ready(); let next = records.filter { $0["id"].string != id }
        guard next.count != records.count else { return false }
        state = state.setting("keys", .array(next)); try save(); return true
    }
    public func setInternet(_ on: NativeRPCValue) throws -> Bool { ready(); state = state.setting("internet", .bool(on.bool == true)); try save(); return on.bool == true }
    public func setPort(_ port: Int) throws { ready(); guard (1...65535).contains(port), state["port"].number != Double(port) else { return }; state = state.setting("port", .number(Double(port))); try save(announce: false) }
    public func setNotify(id: String, input: NativeRPCValue) throws -> NativeRPCValue {
        guard let mode = input["mode"].string, ["off", "wait", "webhook"].contains(mode) else { throw Self.refused("Choose how this app hears about its sessions: off, waiting, or a webhook.") }
        var minted: String?
        let view = try change(id) { key in
            var notify = key["notify"].setting("mode", .string(mode))
            if mode == "webhook" {
                let supplied = input["url"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = supplied.flatMap({ $0.isEmpty ? nil : $0 }) ?? notify["url"].string else { throw Self.refused("Give the web address to post notifications to.") }
                if let problem = Self.webhookURLProblem(url) { throw Self.refused(problem) }
                let secret: String
                if let existing = notify["secret"].string { secret = existing }
                else { secret = "whsec_" + (try BackendRemoteTrustStorage.random(32)).base64EncodedString(); minted = secret }
                notify = notify.setting("url", .string(url)).setting("secret", .string(secret))
            }
            return key.setting("notify", notify)
        }
        return .object([.init("view", view), .init("secret", minted.map(NativeRPCValue.string) ?? .null)])
    }
    public func rotateWebhookSecret(id: String) throws -> NativeRPCValue {
        let secret = "whsec_" + (try BackendRemoteTrustStorage.random(32)).base64EncodedString()
        let view = try change(id) { $0.setting("notify", $0["notify"].setting("secret", .string(secret))) }
        return .object([.init("view", view), .init("secret", .string(secret))])
    }
    public func notifySettings(id: String) -> NativeRPCValue? { ready(); return records.first { $0["id"].string == id }?["notify"] }
    public func match(_ offered: String?) -> NativeRPCValue? {
        ready(); guard let offered, offered.hasPrefix(Self.keyPrefix) else { return nil }
        let digest = Data(SHA256.hash(data: Data(offered.utf8)))
        var found: NativeRPCValue?
        for key in records {
            let bytes = Self.unhex(key["hash"].string ?? "")
            let matches = BackendRemoteTrustStorage.equal(digest, bytes)
            if matches && found == nil { found = key }
        }
        return found.map(Self.view)
    }
    public func caller(id: String, nameAtArrival: String) -> BackendDeckCoreSecurityCaller {
        guard let key = get(id: id) else { return .init(kind: .key, tiers: [], keyID: id, keyName: nameAtArrival) }
        return .init(kind: .key, tiers: Self.tiersFor(key["level"].string ?? "look"), keyID: id, keyName: key["name"].string,
                     askFirst: key["askFirst"].bool, tasks: key["tasks"].bool == true, folders: key["folders"].elements?.compactMap(\.string))
    }
    public func noteUsed(id: String, via: String, app: String?) {
        ready(); let at = now(); let label = Self.cleanAppLabel(app)
        var changed = false
        let next = records.map { key -> NativeRPCValue in
            guard key["id"].string == id else { return key }
            changed = (label != nil && label != key["lastApp"].string) || via != key["lastVia"].string
            return key.setting("lastUsedAt", .number(at)).setting("lastVia", .string(via)).setting("lastApp", label.map(NativeRPCValue.string) ?? key["lastApp"])
        }
        state = state.setting("keys", .array(next)); dirty = true
        guard changed || at - lastFlush >= 60_000 else { return }
        do { try save() } catch { dirty = true }
    }
    public func flush() throws { ready(); if dirty { try save(announce: false) } }
    public func onChange(_ listener: @escaping @Sendable () -> Void) -> UUID { let id = UUID(); listeners[id] = listener; return id }
    public func removeObserver(_ id: UUID) { listeners[id] = nil; authorityListeners[id] = nil }
    /// Internal door watcher receives a snapshot synchronously after the durable change.
    public func onAuthorityChange(_ listener: @escaping @Sendable (Set<String>, Bool) -> Void) -> UUID { let id = UUID(); authorityListeners[id] = listener; return id }
    private func change(_ id: String, _ edit: (NativeRPCValue) throws -> NativeRPCValue) throws -> NativeRPCValue {
        ready(); guard let index = records.firstIndex(where: { $0["id"].string == id }) else { throw Self.refused("That key no longer exists. It may have been revoked.") }
        var next = records; next[index] = try edit(next[index]); state = state.setting("keys", .array(next)); try save(); return Self.view(next[index])
    }
    private func save(announce: Bool = true) throws {
        lastFlush = now(); dirty = false
        try BackendAccountFiles.writeAtomic(try state.encodedJSON(pretty: true) + Data([10]), to: file)
        if announce {
            let ids = Set(records.compactMap { $0["id"].string })
            for listener in authorityListeners.values { listener(ids, state["internet"].bool == true) }
            for listener in listeners.values { listener() }
        }
    }
    public nonisolated static func tiersFor(_ level: String) -> Set<BackendMCPTier> {
        switch level { case "full": return [.read, .act, .alter]; case "work": return [.read, .act]; default: return [.read] }
    }
    public nonisolated static func cleanName(_ raw: NativeRPCValue) throws -> String {
        guard let text = raw.string else { throw refused("Give the key a name, such as the app it is for.") }
        let name = clean(text)
        guard !name.isEmpty else { throw refused("Give the key a name, such as the app it is for.") }
        guard name.utf16.count <= maximumName else { throw refused("Keep the name under 60 characters.") }
        return name
    }
    public nonisolated static func cleanAppLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }; let label = clean(raw); guard !label.isEmpty else { return nil }
        return label.utf16.count > 80 ? prefixUTF16(label, 79) + "…" : label
    }
    private nonisolated static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private nonisolated static func cleanFolders(_ raw: NativeRPCValue) throws -> NativeRPCValue {
        if raw.isNullish { return .null }
        guard let values = raw.elements else { throw refused("Folders must be a list.") }
        var seen: Set<String> = []; let folders = values.compactMap(\.string).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
        guard folders.count <= maximumFolders else { throw refused("A key can be limited to at most 20 folders.") }
        return folders.isEmpty ? .null : .array(folders.map(NativeRPCValue.string))
    }
    private nonisolated static func level(_ raw: NativeRPCValue) throws -> String {
        guard let level = raw.string, ["look", "work", "full"].contains(level) else { throw refused("Choose what the app may do: look, work, or full control.") }; return level
    }
    public nonisolated static func webhookURLProblem(_ raw: String) -> String? {
        guard let url = URL(string: raw), let scheme = url.scheme, url.host != nil else { return "That is not a web address." }
        if url.user != nil || url.password != nil { return "Leave the user name and password out of the address." }
        if scheme.lowercased() == "https" { return nil }
        if scheme.lowercased() == "http", ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host?.lowercased() ?? "") { return nil }
        return "Use an https:// address. Plain http:// is only allowed to this Mac (localhost)."
    }
    private nonisolated static func storedKey(_ raw: NativeRPCValue) -> NativeRPCValue? {
        guard let id = raw["id"].string, !id.isEmpty, let hash = raw["hash"].string,
              hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let level = try? level(raw["level"]), let name = try? cleanName(raw["name"]), let folders = try? cleanFolders(raw["folders"]) else { return nil }
        let n = raw["notify"]
        let url = n["url"].string.flatMap { webhookURLProblem($0) == nil ? $0 : nil }
        let secret = n["secret"].string.flatMap { $0.hasPrefix("whsec_") ? $0 : nil }
        var mode = ["off", "webhook"].contains(n["mode"].string ?? "") ? n["mode"].string! : "wait"
        if mode == "webhook" && (url == nil || secret == nil) { mode = "wait" }
        var key = NativeRPCValue.object([.init("id", .string(id)), .init("name", .string(name)), .init("level", .string(level)),
            .init("hash", .string(hash)), .init("folders", folders), .init("askFirst", .bool(raw["askFirst"].bool != false)), .init("tasks", .bool(raw["tasks"].bool == true)),
            .init("createdAt", .number(raw["createdAt"].number ?? 0)), .init("lastUsedAt", raw["lastUsedAt"].number.map(NativeRPCValue.number) ?? .null),
            .init("lastApp", cleanAppLabel(raw["lastApp"].string).map(NativeRPCValue.string) ?? .null),
            .init("lastVia", ["this-mac", "internet"].contains(raw["lastVia"].string ?? "") ? raw["lastVia"] : .null),
            .init("notify", .object([.init("mode", .string(mode)), .init("url", url.map(NativeRPCValue.string) ?? .null), .init("secret", secret.map(NativeRPCValue.string) ?? .null)]))])
        if raw["crmOnly"].bool == true { key = key.setting("crmOnly", .bool(true)) }; return key
    }
    private nonisolated static func view(_ key: NativeRPCValue) -> NativeRPCValue {
        key.removing("hash").setting("crmOnly", .bool(key["crmOnly"].bool == true))
            .setting("grantedScopes", .array(BackendTAGAccessScope.grantedScopes(key).map(NativeRPCValue.string)))
            .setting("notify", key["notify"].removing("secret").setting("hasSecret", .bool(key["notify"]["secret"].string != nil)))
    }
    private nonisolated static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private nonisolated static func unhex(_ text: String) -> Data { var bytes: [UInt8] = []; var at = text.startIndex; while at < text.endIndex { let end = text.index(at, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex; if let byte = UInt8(text[at..<end], radix: 16) { bytes.append(byte) }; at = end }; return Data(bytes) }
    private nonisolated static func refused(_ message: String) -> NativeRPCError { .init(code: "key-refused", message: message) }
    nonisolated static func prefixUTF16(_ text: String, _ maximum: Int) -> String { String(decoding: text.utf16.prefix(maximum), as: UTF16.self) }
}
