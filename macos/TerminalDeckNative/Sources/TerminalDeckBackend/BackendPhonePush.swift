import CryptoKit
import Foundation
import TerminalDeckNativeCore

/// Alerts for a phone whose app is closed (31 Oct, phone round job "alerts"): capability `push`.
///
/// A paired phone registers here (`push.register`): its mailbox id, the AES key it made for this, its Apple or
/// Google push token if it has one, and which alerts it wants (needs you / finished / Hoot replied, and whether a
/// short preview may be shown). When a chat stops for an answer or finishes, or Hoot replies, this Mac seals the
/// alert under that phone's key and asks the relay (`POST /v1/push`, relay/src/push.ts) to deliver it: Apple or
/// Google wake the phone when they can, and the relay's mailbox keeps the sealed copy for the phone's background
/// check either way.
///
/// What leaves this Mac readable: for an iPhone only, the alert's title ("Claude needs you") and — only when that
/// phone turned on "Show a short preview" — up to 180 characters of the reply, with anything shaped like a key or
/// token blanked. Everything else, the chat's name included, is inside the sealed blob.
///
/// A phone that is connected with its app on screen is not pushed: it shows the news itself (and is in the chat).
public actor BackendPhonePush {
    public enum Kind: String, Sendable, CaseIterable { case needsYou = "needs-you", finished, hoot }

    /// One alert, as the Mac's chat engine noticed it.
    public struct Notice: Sendable, Equatable {
        public var kind: Kind
        /// The chat's session id, or `hoot`.
        public var session: String
        /// "Claude", "Codex", "Gemini" or "Hoot".
        public var agent: String
        /// The chat's name as its row shows it.
        public var title: String
        /// The folder the chat runs in (empty for Hoot): only phones that may reach it hear about it.
        public var folder: String
        /// The reply's last words, or what the agent is asking; shown only to phones that allow a preview.
        public var preview: String?
        public init(kind: Kind, session: String, agent: String, title: String, folder: String, preview: String? = nil) {
            self.kind = kind; self.session = session; self.agent = agent; self.title = title; self.folder = folder; self.preview = preview
        }
    }

    public struct Wants: Sendable, Equatable, Codable {
        public var needsYou = true, finished = true, hoot = true, preview = false
        public init(needsYou: Bool = true, finished: Bool = true, hoot: Bool = true, preview: Bool = false) {
            self.needsYou = needsYou; self.finished = finished; self.hoot = hoot; self.preview = preview
        }
        func allows(_ kind: Kind) -> Bool { switch kind { case .needsYou: needsYou; case .finished: finished; case .hoot: hoot } }
    }

    /// One phone's registration, kept in `<data>/remote/phone-alerts.json` (0600).
    public struct Registration: Sendable, Equatable, Codable {
        public var deviceID: String
        public var name: String
        public var platform: String
        public var mailbox: String
        public var key: String
        public var apns: String?
        public var apnsSandbox: Bool
        public var fcm: String?
        public var wants: Wants
        public var updatedAt: Double
        public var lastSent: Double?
        public var lastResult: String?
    }

    /// What this adapter asks of the app. Production: `init(directory:trust:endpoint:…)`.
    public struct Host: Sendable {
        /// Whether this device may hear about this alert: still approved, and the chat (or Hoot) visible to it.
        public var mayHear: @Sendable (_ deviceID: String, _ notice: Notice) async -> Bool
        /// The relay identity (`hostID` for routing a tap, `secret` for the relay's header), or nil with no relay.
        public var relay: @Sendable () async -> (hostID: String, secret: Data, base: URL)?
        /// One HTTPS request to the relay: a seam so the tests never reach it.
        public var post: @Sendable (_ url: URL, _ headers: [String: String], _ body: Data?) async throws -> (Int, Data)
        public var widgetSnapshot: @Sendable (String) async -> NativeRPCValue?
        public var macName: String
        public init(mayHear: @escaping @Sendable (String, Notice) async -> Bool,
                    relay: @escaping @Sendable () async -> (hostID: String, secret: Data, base: URL)?,
                    post: @escaping @Sendable (URL, [String: String], Data?) async throws -> (Int, Data) = BackendPhonePush.urlSessionPost,
                    macName: String, widgetSnapshot: @escaping @Sendable (String) async -> NativeRPCValue? = { _ in nil }) {
            self.widgetSnapshot = widgetSnapshot
            self.mayHear = mayHear; self.relay = relay; self.post = post; self.macName = macName
        }
    }

    public static let messages: Set<String> = ["push.register", "push.presence", "push.forget"]
    public static let capability = "push"

    private let file: URL?
    private let host: Host
    private let now: @Sendable () -> Date
    private var registrations: [String: Registration] = [:]
    /// Connected phones whose app is on screen, by connection.
    private var onScreen: [UUID: String] = [:]
    private var relayKnows: (apns: Bool, fcm: Bool, at: Date)?

    public init(file: URL?, host: Host, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file; self.host = host; self.now = now
        if let file, let data = try? Data(contentsOf: file),
           let rows = try? JSONDecoder().decode([Registration].self, from: data) {
            registrations = Dictionary(rows.map { ($0.deviceID, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    public func feature() -> BackendRemoteHostFeature {
        .init(capability: Self.capability, messageTypes: Self.messages, policy: .grantedDevice) { [weak self] message, context in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "Phone alerts stopped.") }
            return try await self.handle(message, context: context)
        }
    }

    public func disconnected(_ connection: UUID) { onScreen[connection] = nil }

    /// Rows for the Devices page and `remote.status` (no keys, no tokens).
    public func rows() -> [NativeRPCValue] {
        registrations.values.sorted { $0.deviceID < $1.deviceID }.map { row in
            .object([.init("deviceId", .string(row.deviceID)), .init("name", .string(row.name)), .init("platform", .string(row.platform)),
                     .init("delivery", .string(Self.delivery(row, apns: relayKnows?.apns ?? false, fcm: relayKnows?.fcm ?? false))),
                     .init("needsYou", .bool(row.wants.needsYou)), .init("finished", .bool(row.wants.finished)),
                     .init("hoot", .bool(row.wants.hoot)), .init("preview", .bool(row.wants.preview)),
                     .init("onScreen", .bool(onScreen.values.contains(row.deviceID))),
                     .init("lastSentAt", row.lastSent.map(NativeRPCValue.number) ?? .null),
                     .init("lastResult", row.lastResult.map(NativeRPCValue.string) ?? .null)])
        }
    }

    public func forget(deviceID: String) { if registrations.removeValue(forKey: deviceID) != nil { save() } }

    func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        switch message.type {
        case "push.presence":
            if message["onScreen"].bool == true { onScreen[context.connectionID] = context.deviceID } else { onScreen[context.connectionID] = nil }
            return []
        case "push.forget":
            forget(deviceID: context.deviceID)
            return [try await stateFrame(nil)]
        default:
            let wants = Wants(needsYou: message["needsYou"].bool ?? true, finished: message["finished"].bool ?? true,
                              hoot: message["hoot"].bool ?? true, preview: message["preview"].bool ?? false)
            var row = Registration(deviceID: context.deviceID, name: message["name"].string ?? registrations[context.deviceID]?.name ?? "Phone",
                                   platform: message["platform"].string ?? "ios", mailbox: try message["mailbox"].requireString("mailbox", nonempty: true),
                                   key: try message["key"].requireString("key", nonempty: true), apns: message["apns"].string,
                                   apnsSandbox: message["sandbox"].bool ?? false, fcm: message["fcm"].string, wants: wants,
                                   updatedAt: now().timeIntervalSince1970 * 1000)
            row.lastSent = registrations[context.deviceID]?.lastSent; row.lastResult = registrations[context.deviceID]?.lastResult
            guard Self.keyBytes(row.key) != nil else { throw NativeRPCError.invalidArguments("push.register with an unusable key") }
            registrations[context.deviceID] = row
            if message["onScreen"].bool == true { onScreen[context.connectionID] = context.deviceID }
            save()
            return [try await stateFrame(row)]
        }
    }

    /// `push.state`: how this phone's alerts will arrive when its app is closed.
    private func stateFrame(_ row: Registration?) async throws -> BackendRemoteServerMessage {
        let known = await relayStatus()
        let delivery = row.map { Self.delivery($0, apns: known.apns, fcm: known.fcm) } ?? "off"
        return try .init(.pushState, fields: [.init("delivery", .string(delivery)), .init("apns", .bool(known.apns)), .init("fcm", .bool(known.fcm))])
    }

    /// "instant" when Apple/Google can wake the phone; "mailbox" when only the background check will find it.
    static func delivery(_ row: Registration, apns: Bool, fcm: Bool) -> String {
        if row.apns != nil && apns || row.fcm != nil && fcm { return "instant" }
        return "mailbox"
    }

    private func relayStatus() async -> (apns: Bool, fcm: Bool) {
        if let known = relayKnows, now().timeIntervalSince(known.at) < 600 { return (known.apns, known.fcm) }
        guard let relay = await host.relay(),
              let answer = try? await host.post(relay.base.appendingPathComponent("v1/push/status"), [:], nil), answer.0 == 200,
              let value = try? NativeRPCValue.parseJSON(answer.1, maximumBytes: 4096) else { return (relayKnows?.apns ?? false, relayKnows?.fcm ?? false) }
        relayKnows = (value["apns"].bool == true, value["fcm"].bool == true, now())
        return (relayKnows!.apns, relayKnows!.fcm)
    }

    /// Tell every phone that wants it. Returns how many phones it was sent to (the tests and `remote.manage test-alert`).
    @discardableResult
    public func notify(_ notice: Notice, only deviceID: String? = nil) async -> Int {
        guard let relay = await host.relay() else { return 0 }
        var messages: [NativeRPCValue] = [], who: [String] = []
        for row in registrations.values.sorted(by: { $0.deviceID < $1.deviceID }) {
            if let deviceID, row.deviceID != deviceID { continue }
            let test = deviceID != nil && notice.session == "test"
            if !test {
                guard row.wants.allows(notice.kind), !onScreen.values.contains(row.deviceID) else { continue }
                guard await host.mayHear(row.deviceID, notice) else { continue }
            }
            guard let key = Self.keyBytes(row.key) else { continue }
            let widget = await host.widgetSnapshot(row.deviceID)
            guard let sealed = try? Self.seal(notice, wants: row.wants, hostID: relay.hostID, mac: host.macName, at: now(), key: key, widgetSnapshot: widget) else { continue }
            var fields: [NativeRPCValue.Field] = [.init("mailbox", .string(row.mailbox)), .init("sealed", .string(sealed)),
                .init("kind", .string(notice.kind.rawValue)), .init("collapse", .string(Self.collapse(notice))),
                .init("route", .object([.init("host", .string(relay.hostID)), .init("chat", .string(notice.session))]))]
            if let token = row.apns {
                fields.append(.init("apns", .object([.init("token", .string(token)), .init("sandbox", .bool(row.apnsSandbox))])))
                let alert = Self.alert(notice, wants: row.wants)
                fields.append(.init("alert", .object([.init("title", .string(alert.title)), .init("body", .string(alert.body))])))
            }
            if let token = row.fcm { fields.append(.init("fcm", .string(token))) }
            messages.append(.object(fields)); who.append(row.deviceID)
        }
        guard !messages.isEmpty else { return 0 }
        var sent = 0
        for start in stride(from: 0, to: messages.count, by: 8) {
            let batch = Array(messages[start..<min(start + 8, messages.count)]), ids = Array(who[start..<min(start + 8, who.count)])
            let body = Data(NativeRPCValue.object([.init("messages", .array(batch))]).compact.utf8)
            let answer = try? await host.post(relay.base.appendingPathComponent("v1/push"),
                [BackendRelayPacketCodec.secretHeader: BackendRemoteTrustStorage.base64URL(relay.secret), "content-type": "application/json"], body)
            let parsed = answer.flatMap { try? NativeRPCValue.parseJSON($0.1, maximumBytes: 65_536) }
            if let parsed { relayKnows = (parsed["apns"].bool == true, parsed["fcm"].bool == true, now()) }
            let results = parsed?["results"].elements ?? []
            for (index, id) in ids.enumerated() {
                let result = index < results.count ? results[index] : nil
                var outcome = answer.map { $0.0 == 200 ? "kept" : "refused \($0.0)" } ?? "relay unreachable"
                if let result {
                    let apns = result["apns"].string ?? "off", fcm = result["fcm"].string ?? "off"
                    outcome = apns == "sent" || fcm == "sent" ? "sent" : "kept"
                    // A token the phone no longer has: dropped, the mailbox still works; the phone sends a new one on its next connection.
                    if apns == "gone" { registrations[id]?.apns = nil }
                    if fcm == "gone" { registrations[id]?.fcm = nil }
                }
                if answer?.0 == 200 { sent += 1 }
                registrations[id]?.lastSent = now().timeIntervalSince1970 * 1000; registrations[id]?.lastResult = outcome
            }
        }
        save()
        return sent
    }

    /* ---- shapes ---------------------------------------------------------- */

    static func collapse(_ notice: Notice) -> String {
        let safe = notice.session.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_:.".unicodeScalars.contains($0) }
        return String(String.UnicodeScalarView(safe).prefix(48)) + (notice.kind == .finished ? ":f" : ":n")
    }

    /// The words Apple shows on an iPhone (the only readable part of an alert).
    static func alert(_ notice: Notice, wants: Wants) -> (title: String, body: String) {
        let title: String
        switch notice.kind {
        case .needsYou: title = "\(notice.agent) needs you"
        case .finished: title = "\(notice.agent) finished"
        case .hoot: title = "Hoot replied"
        }
        if wants.preview, let preview = notice.preview.map(redacted), !preview.isEmpty {
            return (title, String("\(notice.title): \(preview)".prefix(180)))
        }
        return (title, notice.kind == .needsYou ? "Open Terminal Deck to answer." : "Open Terminal Deck to see it.")
    }

    /// The sealed alert: AES-256-GCM, nonce + ciphertext + tag, base64url (CryptoKit's `combined`).
    static func seal(_ notice: Notice, wants: Wants, hostID: String, mac: String, at: Date, key: SymmetricKey, widgetSnapshot: NativeRPCValue? = nil) throws -> String {
        var fields: [NativeRPCValue.Field] = [.init("v", .number(1)), .init("k", .string(notice.kind.rawValue)),
            .init("agent", .string(notice.agent)), .init("title", .string(String(notice.title.prefix(120)))),
            .init("host", .string(hostID)), .init("session", .string(notice.session)), .init("mac", .string(String(mac.prefix(64)))),
            .init("at", .number((at.timeIntervalSince1970 * 1000).rounded()))]
        if wants.preview, let preview = notice.preview.map(redacted), !preview.isEmpty { fields.append(.init("preview", .string(String(preview.prefix(180))))) }
        if let widgetSnapshot { fields.append(.init("widgetSnapshot", widgetSnapshot)) }
        let plain = Data(NativeRPCValue.object(fields).compact.utf8)
        guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw NativeRPCError.malformed("seal") }
        let sealed = BackendRemoteTrustStorage.base64URL(combined)
        // Leave room for the APNs alert envelope; the full state is also available on the next relay connection.
        if let widgetSnapshot, sealed.utf8.count > 2000 {
            // Counts and percentages still refresh when unusually long names cannot fit an APNs envelope.
            let lean = widgetSnapshot.setting("needsYou", .array([])).setting("nextTask", .null)
            return try seal(notice, wants: wants, hostID: hostID, mac: mac, at: at, key: key,
                            widgetSnapshot: lean == widgetSnapshot ? nil : lean)
        }
        return sealed
    }

    static func keyBytes(_ text: String) -> SymmetricKey? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        guard let data = Data(base64Encoded: base), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// Anything that looks like a key, token or password is blanked before a preview leaves the Mac.
    static func redacted(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        for pattern in [#"(sk|pk|rk|ghp|gho|ghs|github_pat|xox[abpr]|AKIA|AIza)[-_A-Za-z0-9]{12,}"#, #"[A-Za-z0-9+/_=-]{32,}"#,
                        #"(?i)(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S+"#] {
            out = out.replacingOccurrences(of: pattern, with: "•••", options: .regularExpression)
        }
        return out
    }

    public static let urlSessionPost: @Sendable (URL, [String: String], Data?) async throws -> (Int, Data) = { url, headers, body in
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = body == nil ? "GET" : "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// `wss://relay…` → `https://relay…`.
    public static func httpBase(_ relayURL: String) -> URL? {
        guard var parts = URLComponents(string: relayURL) else { return nil }
        parts.scheme = parts.scheme == "ws" ? "http" : "https"
        parts.path = ""; parts.query = nil
        return parts.url
    }

    private func save() {
        guard let file else { return }
        let rows = registrations.values.sorted { $0.deviceID < $1.deviceID }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

public extension BackendPhonePush {
    /// Production: the trust store decides who may hear what; the relay identity is this Mac's.
    init(directory: URL, trust: BackendRemoteTrustStore, relayURL: String?, macName: String,
         widgetSnapshot: @escaping @Sendable (String) async -> NativeRPCValue? = { _ in nil }) {
        self.init(file: directory.appendingPathComponent("phone-alerts.json"), host: .init(mayHear: { deviceID, notice in
            guard await trust.isApproved(deviceID), let level = await trust.phoneAccess(deviceID) else { return false }
            if notice.kind == .hoot { return await trust.kindOf(deviceID) == .mine && level.permits("hoot.attach") }
            guard level != .hoot else { return false }
            guard await trust.canReachFolder(deviceID, folder: notice.folder) else { return false }
            return await trust.sessionShared(deviceID, session: notice.session)
        }, relay: {
            guard let relayURL, let base = BackendPhonePush.httpBase(relayURL), let identity = try? await trust.hostIdentity() else { return nil }
            return (identity.hostID, identity.hostSecret, base)
        }, macName: macName, widgetSnapshot: widgetSnapshot))
    }
}

extension BackendRemoteProtocol {
    /// `push.register` / `push.presence` / `push.forget`: shapes only.
    static func parsePush(_ r: BackendRemoteReader) throws -> NativeRPCValue? {
        var message = r.base
        func token(_ key: String, _ pattern: String) throws {
            guard !r[key].isNullish else { return }
            guard let value = r[key].string, value.range(of: pattern, options: .regularExpression) != nil else { throw r.bad("\(r.type) with an unusable \(key)") }
            message = message.setting(key, .string(value))
        }
        switch r.type {
        case "push.presence":
            return message.setting("onScreen", .bool(try r.boolean("onScreen", reason: "push.presence without onScreen")))
        case "push.forget":
            return message
        case "push.register":
            try token("mailbox", #"^[0-9a-f]{32}$"#)
            try token("key", #"^[A-Za-z0-9_-]{43}=?$"#)
            guard message["mailbox"] != .missing, message["key"] != .missing else { throw r.bad("push.register without a mailbox") }
            try token("apns", #"^[0-9a-f]{64,200}$"#)
            try token("fcm", #"^[A-Za-z0-9_:.-]{20,4096}$"#)
            try token("platform", #"^(ios|android)$"#)
            if let name = r["name"].string { message = message.setting("name", .string(String(name.prefix(64)))) }
            for key in ["sandbox", "needsYou", "finished", "hoot", "preview", "onScreen"] where r[key].bool != nil { message = message.setting(key, r[key]) }
            return message
        default:
            return nil
        }
    }
}
