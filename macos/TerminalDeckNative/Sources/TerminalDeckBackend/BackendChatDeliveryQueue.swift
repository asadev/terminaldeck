import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Save the whole outgoing message before crossing an await or socket. A lost reply never
/// makes that same identity a fresh send. Identical text with a new identity is a new message.
final class BackendChatDeliveryQueue: Sendable {
    private static let lock = NSRecursiveLock()
    let directory: URL
    init(directory: URL) { self.directory = directory }

    static func identity(_ supplied: String?) -> String {
        guard let supplied, !supplied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return UUID().uuidString.lowercased() }
        return supplied
    }
    private let limit = 500
    private let confirmedRetryWindow: TimeInterval = 600
    private let retention: TimeInterval = 86_400
    private func file(_ id: String) -> URL {
        directory.appendingPathComponent(hash(id) + ".json")
    }
    private func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private struct Entry {
        let url: URL
        let value: NativeRPCValue
        let date: Double
        var message: NativeRPCValue { value["message"] }
        var confirmed: Bool { value["confirmed"].bool == true }
    }
    // A fixed-size retirement filter prevents deleted claims from becoming sendable again.
    // Collisions safely hold a new send; they never release an old one.
    private func retire(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { return }
        var bits = try retiredBits()
        for entry in entries {
            let id = entry.message["clientMessageId"].string ?? ""
            for position in positions(id) { bits[position] = 1 }
            // An aged-out uncertain fallback must not become a fresh id-less send.
            if !entry.confirmed, let key = retryKey(id) {
                for position in positions(key) { bits[position] = 1 }
            }
        }
        let target = directory.appendingPathComponent("retired.bin")
        try bits.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        for entry in entries { try FileManager.default.removeItem(at: entry.url) }
    }
    private func retryKey(_ id: String) -> String? {
        let parts = id.split(separator: ":")
        guard id.hasPrefix("retry-"), parts.count == 3 else { return nil }
        return String(parts[0])
    }
    private func retiredBits() throws -> Data {
        let url = directory.appendingPathComponent("retired.bin")
        guard FileManager.default.fileExists(atPath: url.path) else { return Data(repeating: 0, count: 65536) }
        let bits = try Data(contentsOf: url)
        guard bits.count == 65536 else { throw NativeRPCError.invalidArguments("The saved delivery history cannot be read. Your message was held.") }
        return bits
    }
    private func positions(_ id: String) -> [Int] {
        let digest = Array(SHA256.hash(data: Data(id.utf8)))
        return stride(from: 0, to: 8, by: 2).map { Int(digest[$0]) * 256 + Int(digest[$0 + 1]) }
    }
    private func load(now: Date) throws -> [Entry] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        let entries = try files.filter { $0.pathExtension == "json" }.map { url in
            let value = try NativeRPCValue.parseJSON(Data(contentsOf: url), maximumBytes: BackendHOSTProtocol.maximumRequestBytes + 4096)
            let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? now
            return Entry(url: url, value: value, date: value["updatedAt"].number ?? date.timeIntervalSince1970)
        }
        let expired = entries.filter { now.timeIntervalSince1970 - $0.date > retention }
        try retire(expired)
        var kept = entries.filter { now.timeIntervalSince1970 - $0.date <= retention }
        for group in Dictionary(grouping: kept, by: { $0.message["id"].string ?? "" }).values where group.count > limit {
            let excess = Array(group.sorted { $0.date < $1.date }.prefix(group.count - limit))
            try retire(excess)
            let removed = Set(excess.map(\.url))
            kept.removeAll { removed.contains($0.url) }
        }
        return kept
    }
    /// Resolve compatibility fingerprints against saved claims, before claiming the socket write.
    func resolve(_ message: NativeRPCValue, now: Date = Date()) throws -> NativeRPCValue {
        try Self.lock.withLock {
            let entries = try load(now: now)
            guard let request = message["clientMessageId"].string, request.hasPrefix("retry-request:") else { return message }
            let parts = request.split(separator: ":")
            guard parts.count == 2 else { throw NativeRPCError.invalidArguments("Invalid retry identity.") }
            let key = "retry-" + parts[1]
            let bits = try retiredBits()
            guard !positions(key).allSatisfy({ bits[$0] != 0 }) else {
                throw NativeRPCError(code: "uncertain-delivery", message: "An earlier identical send could not be confirmed. Your message is held. Use a new message id for a new send.")
            }
            let prefix = key + ":"
            if let saved = entries.filter({
                ($0.message["clientMessageId"].string ?? "").hasPrefix(prefix) &&
                    (!$0.confirmed || now.timeIntervalSince1970 - $0.date <= confirmedRetryWindow)
            }).max(by: { $0.date < $1.date }) {
                return message.setting("clientMessageId", saved.message["clientMessageId"])
            }
            return message.setting("clientMessageId", .string(prefix + String(now.timeIntervalSince1970) + ":" + UUID().uuidString.lowercased()))
        }
    }
    func claim(_ message: NativeRPCValue, now: Date = Date()) throws -> (message: NativeRPCValue, confirmed: Bool) {
        try Self.lock.withLock {
            let resolved = try resolve(message, now: now)
            return (resolved, try begin(resolved, now: now))
        }
    }
    /// false claims a new send; true means it already finished. Read current history then.
    func begin(_ message: NativeRPCValue, now: Date = Date()) throws -> Bool {
        try Self.lock.withLock {
            var entries = try load(now: now)
            let id = try message["clientMessageId"].requireString("message id", nonempty: true)
            // Match the saved operation itself; URL spelling can differ after reload.
            if let saved = entries.first(where: { $0.message["clientMessageId"].string == id }) {
                guard saved.message == message else { throw NativeRPCError.invalidArguments("This message id already belongs to another message.") }
                if saved.confirmed {
                    // Persist retry activity so a lost replay reply keeps the same window after reload.
                    if retryKey(id) != nil { try save(message, confirmed: true, now: now) }
                    return true
                }
                throw NativeRPCError(code: "uncertain-delivery", message: "Delivery has not been confirmed. Your message is held in the queue to avoid sending it twice.")
            }
            let bits = try retiredBits()
            let parts = id.split(separator: ":")
            let expiredRetry = id.hasPrefix("retry-") && parts.count == 3 && (Double(parts[1]).map { now.timeIntervalSince1970 - $0 > retention } ?? false)
            guard !positions(id).allSatisfy({ bits[$0] != 0 }), !expiredRetry else {
                throw NativeRPCError(code: "uncertain-delivery", message: "This delivery record expired. Your message is held to avoid sending it twice. Use a new message id for a new send.")
            }
            entries = entries.filter { $0.message["id"] == message["id"] }
            if entries.count >= limit {
                // Never evict an uncertain claim to admit another send.
                guard let oldest = entries.filter({ $0.confirmed && now.timeIntervalSince1970 - $0.date > confirmedRetryWindow }).min(by: { $0.date < $1.date }) else {
                    throw NativeRPCError(code: "uncertain-delivery", message: "This conversation has too many recent or unconfirmed sends. Your message is held.")
                }
                try retire([oldest])
            }
            try save(message, confirmed: false, now: now)
            return false
        }
    }
    private func save(_ message: NativeRPCValue, confirmed: Bool, now: Date) throws {
        let target = file(try message["clientMessageId"].requireString("message id"))
        try NativeRPCValue.object([.init("message", message), .init("confirmed", .bool(confirmed)),
            .init("updatedAt", .number(now.timeIntervalSince1970))]).encodedJSON().write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    func finish(_ message: NativeRPCValue, now: Date = Date()) throws {
        try Self.lock.withLock {
            let entries = try load(now: now)
            guard entries.contains(where: { $0.message == message }) else {
                throw NativeRPCError(code: "uncertain-delivery", message: "The delivery record expired before confirmation. Your message is held.")
            }
            try save(message, confirmed: true, now: now)
            _ = try load(now: now)
        }
    }
    /// Delete message contents but keep hashed identities so a delayed retry cannot send again.
    func forgetConversation(_ id: String) throws {
        try Self.lock.withLock {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try retire(load(now: Date()).filter { $0.message["id"].string == id })
        }
    }
    /// Only a definite refusal before delivery may be tried again. Keep unknown failures saved.
    func refused(_ message: NativeRPCValue, error: Error) {
        guard let error = error as? NativeRPCError,
              ["busy", "invalid-arguments", "access-denied", "decision-held", "provider-input-limit"].contains(error.code) else { return }
        Self.lock.withLock { try? FileManager.default.removeItem(at: file(message["clientMessageId"].string ?? "")) }
    }

}

/// Compatibility identity for callers that cannot yet retain a client message id.
/// Length framing hashes the exact UTF-8 bytes without putting identity into chat text.
public enum BackendChatRetryIdentity {
    public static func messageID(_ supplied: String?, caller: String, conversation: String, text: String,
                                 frame: NativeRPCValue = .object([]), now: Date = Date()) -> String {
        if let supplied, !supplied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return supplied }
        var bytes = Data()
        func append(_ value: String) {
            let data = Data(value.utf8)
            bytes.append(Data("\(data.count):".utf8)); bytes.append(data)
        }
        append("chat-retry-v1"); append(caller); append(conversation); append(text)
        var hasMarker = false
        for key in ["clientSequence", "sequence", "sentAt", "timestamp"] {
            let value = frame[key]
            if let string = value.string { append(key); append("string"); append(string); hasMarker = true }
            else if let number = value.number, number.isFinite { append(key); append("number"); append(String(number)); hasMarker = true }
        }
        // Attachments and context are exact payload bytes, too; changed payloads are distinct sends.
        for key in ["attachments", "context", "references"] where !frame[key].isNullish {
            append(key); append(String(decoding: (try? frame[key].encodedJSON()) ?? Data(), as: UTF8.self))
        }
        let key = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if hasMarker { return "retry-marker-" + key }
        return "retry-request:" + key
    }
    public static func caller(_ caller: BackendDeckToolsAppCaller) -> String {
        // Connection ids change on reconnect; authenticated device/key/session ids do not.
        [caller.kind.rawValue, caller.machineID ?? "", caller.keyID ?? caller.keyName ?? "", caller.sessionID ?? ""]
            .map { "\($0.utf8.count):" + $0 }.joined()
    }
}
