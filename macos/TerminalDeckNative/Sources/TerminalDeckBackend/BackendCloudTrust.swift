import Foundation
import CryptoKit
import Security
import TerminalDeckNativeCore

/// Device trust on this Mac (lean scope item 4; design `cloud-device-trust-design.md` revision 2 with R1 to R6).
///
/// Every Mac keeps its own list of the device keys the person trusted ON THAT MAC. A pack of changes is used only
/// when its signature checks against a key on that list; the signer decides, never a field inside the pack and never
/// the service's word. The checking itself is the sync core's (`CloudPackVerdict`): this file hands it the stored key
/// of a trusted device and nothing else (`CloudDeviceTrustPort`). The list grows only by this Mac's own sign-in (its own key) and by a click in this Mac's
/// window. Nothing in this file is reachable from a tool, an RPC channel or a settings key.

/// How this Mac trusts the account's other devices (owner's decision, 13 Nov). A setting on each device, so it can be
/// tightened without a new build. Only WHO adds a key to this Mac's list changes; the list, the signature check,
/// held and refused packs stay exactly as they are.
public enum BackendCloudTrustMode: String, Sendable, CaseIterable {
    /// DEFAULT. Every device the account lists is put on this Mac's list with the key the service reports, the first
    /// time it is seen, with no sheet and no code. A device whose reported key later CHANGES is not re-trusted by
    /// itself: its changes wait until the person presses "Trust its new key". A device the person removed here is
    /// never added again by itself.
    case account
    /// Earlier behaviour exactly: the new-Mac sheet, the Trust sheet with the code, and changes held until trusted.
    case ask
    /// Read from this Mac's own setting text; anything unknown is the stricter "ask".
    public static func from(_ text: String?) -> Self {
        guard let text else { return .account }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) { case "account", "": return .account; default: return .ask }
    }
}

/// The text forms of design 2.1 and the 80-bit code of 2.2.
public enum BackendCloudDeviceCode {
    /// A device id exactly as it travels: a lower-case UUID. Anything else has no code, so a look-alike id (another
    /// case, extra characters, a line break) can never be shown with another device's code.
    public static func isDeviceId(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) { if byte != 45 { return false } }
            else if !((48...57).contains(byte) || (97...102).contains(byte)) { return false }
        }
        return true
    }
    /// SHA-256, lower-case hex, of the RFC 8785 form of the signing key with exactly four members: crv, kty, x, y.
    /// nil unless it is a real P-256 point written the one canonical way.
    public static func keyId(_ key: CloudPublicJWK) -> String? {
        guard key.kty == "EC", key.crv == "P-256", let yText = key.y,
              let x = BackendCloudAccountIdentity.unbase64(key.x), x.count == 32, BackendCloudAccountIdentity.base64(x) == key.x,
              let y = BackendCloudAccountIdentity.unbase64(yText), y.count == 32, BackendCloudAccountIdentity.base64(y) == yText,
              (try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)) != nil else { return nil }
        // Sorted names, no spaces; base64url text needs no escaping, so this is the RFC 8785 form.
        let canonical = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"" + key.x + "\",\"y\":\"" + yText + "\"}"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// The first 80 bits of SHA-256("TD-CLOUD-DEVICE-CODE-1\n" + deviceId + "\n" + keyId) as `XXXX XXXX XXXX XXXX XXXX`.
    public static func code(deviceId: String, keyId: String) -> String? {
        guard isDeviceId(deviceId), keyId.utf8.count == 64,
              keyId.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let digest = Array(SHA256.hash(data: Data(("TD-CLOUD-DEVICE-CODE-1\n" + deviceId + "\n" + keyId).utf8)))
        let characters = Array(digest.prefix(10).map { String(format: "%02X", $0) }.joined())
        return stride(from: 0, to: 20, by: 4).map { String(characters[$0..<($0 + 4)]) }.joined(separator: " ")
    }
    public static func code(deviceId: String, key: CloudPublicJWK) -> (keyId: String, code: String)? {
        guard let id = Self.keyId(key), let shown = Self.code(deviceId: deviceId, keyId: id) else { return nil }
        return (id, shown)
    }
}

/// Design 2.3. One per account on each device. Kept at sign-out. Never synced.
public struct BackendCloudTrustedList: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let deviceId: String
        public let signKey: CloudPublicJWK
        public let keyId: String
        /// The name the device gave when it was trusted. Display only.
        public let name: String
        /// "trusted" or "stopped". Only "trusted" lets a pack apply.
        public let trust: String
        /// "self" (this Mac made the key), "click" (the trust sheet), "restore" (the new-Mac sheet) or "account"
        /// (automatic trust: the account listed it, owner's decision of 13 Nov).
        public let how: String
        /// This Mac's clock, milliseconds.
        public let trustedAt: Int64
        public let stoppedAt: Int64?
        public let stopReason: String?
        /// The kind of device ("macos", "windows", "ios", "android", "web") as reported when its key was stored here,
        /// kept with the key and never changed afterwards (review blocker 1 of PASSWORDS-2: only a computer gets the
        /// saved-passwords key by itself). nil for entries stored before this was kept, until `notePlatforms` fills it
        /// once. A plain string, so an unknown kind can never make the list unreadable.
        public let platform: String?
        public init(deviceId: String, signKey: CloudPublicJWK, keyId: String, name: String, trust: String, how: String,
                    trustedAt: Int64, stoppedAt: Int64? = nil, stopReason: String? = nil, platform: String? = nil) {
            self.deviceId = deviceId; self.signKey = signKey; self.keyId = keyId; self.name = name; self.trust = trust
            self.how = how; self.trustedAt = trustedAt; self.stoppedAt = stoppedAt; self.stopReason = stopReason
            self.platform = platform
        }
        public var trusted: Bool { trust == "trusted" }
    }
    public let v: Int
    public let subject: CloudSubject
    public let revision: Int
    public let devices: [Entry]
    public init(v: Int = 1, subject: CloudSubject, revision: Int, devices: [Entry]) {
        self.v = v; self.subject = subject; self.revision = revision; self.devices = devices
    }
}

/// What a trust sheet showed when it was drawn (R1): the device, the key and the code computed from that key.
/// This, and nothing fetched later, is what a click stores. It can be made only inside this package (security
/// review S13): by the two sheets, from a row as it is drawn.
public struct BackendCloudTrustCapture: Sendable, Equatable {
    public let deviceId: String
    public let name: String
    public let signKey: CloudPublicJWK
    public let keyId: String
    public let code: String
    /// The kind of device the row reported (kept with the key, review blocker 1).
    public let platform: CloudPlatform?
    package init(deviceId: String, name: String, signKey: CloudPublicJWK, keyId: String, code: String, platform: CloudPlatform? = nil) {
        self.deviceId = deviceId; self.name = name; self.signKey = signKey; self.keyId = keyId; self.code = code; self.platform = platform
    }
    /// nil for a row no sheet may offer: not new, no readable key, a code another device also shows, or a device
    /// Cloud reports as removed.
    package init?(row: CloudDeviceTrustRow) {
        guard row.canBeTrusted, let code = row.code, let keyId = row.keyId, let key = row.signKey else { return nil }
        self.init(deviceId: row.deviceId, name: row.name, signKey: key, keyId: keyId, code: code, platform: row.platform)
    }
}

/// Why a trust click changed nothing. The words are shown on the Cloud page as they are.
public enum BackendCloudTrustRefusal: Error, Equatable, Sendable {
    case remoteInput, listChanged, sameCode, sameKey, listFull, unreadable, notSaved
    public var words: String {
        switch self {
        case .remoteInput: return "This Mac was just being controlled from another device, so nothing was trusted. Wait a moment and choose Trust again yourself."
        case .listChanged: return "Cloud's device list changed, so nothing was trusted. Compare the code again."
        case .sameCode: return "Two devices show the same code. Do not trust either."
        case .sameKey: return "Two devices use the same key. Do not trust either."
        case .listFull: return "This Mac's device list is full."
        case .unreadable: return "This Mac's trusted-device list could not be read, so changes from other devices wait. Unlock your keychain and try again."
        case .notSaved: return "This Mac could not save its trusted-device list. Nothing was changed."
        }
    }
}

/// Where the list lives: one Keychain item of its own per app copy, data folder and account. Never a file: the dev
/// copy's file fallback is not used for it, and the dev copy's item sits under its own service name, so it can never
/// read or replace the real app's list. Nothing deletes it (it is kept at sign-out).
public struct BackendCloudTrustSlot: Sendable {
    public let read: @Sendable () throws -> Data?
    public let write: @Sendable (Data) throws -> Void
    public init(read: @escaping @Sendable () throws -> Data?, write: @escaping @Sendable (Data) throws -> Void) {
        self.read = read; self.write = write
    }
    public static func names(appName: String, instanceId: String, subjectHash: String) -> (service: String, account: String) {
        (appName + " Cloud Trust", "trusted:" + instanceId + ":" + subjectHash)
    }
    public static func keychain(appName: String, instanceId: String, subjectHash: String) -> Self {
        let named = names(appName: appName, instanceId: instanceId, subjectHash: subjectHash)
        return keychainItem(service: named.service, account: named.account)
    }
    /// One generic-password item, never a password prompt (also the trust-mode sibling item).
    public static func keychainItem(service: String, account: String) -> Self {
        .init(read: {
            BackendCloudTrace.note("trust-read")
            // Never a password prompt: an item this build may not read is "cannot be read", and everything waits.
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true,
                                        kSecMatchLimit as String: kSecMatchLimitOne,
                                        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
            var found: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &found)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = found as? Data else { throw BackendCloudTrustRefusal.unreadable }
            return data
        }, write: { data in
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account,
                                        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
            let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updated == errSecSuccess { return }
            guard updated == errSecItemNotFound else { throw BackendCloudTrustRefusal.notSaved }
            let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                             kSecAttrAccount as String: account, kSecValueData as String: data,
                                             kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw BackendCloudTrustRefusal.notSaved }
        })
    }
}

/// "How this Mac trusts your other devices" (security gap 1, 13 Nov): kept in the Keychain, as a sibling of the
/// trusted-device list under the same service name, so nothing that can only write the Cloud folder can flip a Mac
/// from "Ask me" back to automatic. The old `cloud/trust-mode` file is read ONCE as a migration and then deleted;
/// after that the file is never read again (its presence or absence changes nothing). A Mac with no stored choice
/// is "automatic". An item this build cannot read is the stricter "ask" (and the file is left alone).
public struct BackendCloudTrustModeStore: Sendable {
    public let slot: BackendCloudTrustSlot
    public let legacyFile: URL?
    public init(slot: BackendCloudTrustSlot, legacyFile: URL?) { self.slot = slot; self.legacyFile = legacyFile }
    /// The sibling item: same service as the trusted-device lists, its own account name for this app copy.
    public static func names(appName: String, instanceId: String) -> (service: String, account: String) {
        (BackendCloudTrustSlot.names(appName: appName, instanceId: instanceId, subjectHash: "").service, "trust-mode:" + instanceId)
    }
    public static func keychain(appName: String, instanceId: String, legacyFile: URL?) -> Self {
        let named = names(appName: appName, instanceId: instanceId)
        return .init(slot: BackendCloudTrustSlot.keychainItem(service: named.service, account: named.account), legacyFile: legacyFile)
    }
    /// The stored choice. The first read with no item stores the old file's choice (or "automatic") and deletes the
    /// file, so a file written later is never consulted.
    public func load() -> BackendCloudTrustMode {
        let stored: Data?
        do { stored = try slot.read() } catch { return .ask }
        if let stored { removeLegacy(); return BackendCloudTrustMode.from(String(decoding: stored, as: UTF8.self)) }
        var mode = BackendCloudTrustMode.account
        if let legacyFile, FileManager.default.fileExists(atPath: legacyFile.path) {
            mode = BackendCloudTrustMode.from((try? String(contentsOf: legacyFile, encoding: .utf8)) ?? "ask")
        }
        guard (try? save(mode)) != nil else { return mode }
        removeLegacy()
        return mode
    }
    /// Only the Cloud page's guarded press calls this. Read back, like the trusted list.
    public func save(_ mode: BackendCloudTrustMode) throws {
        let bytes = Data(mode.rawValue.utf8)
        try slot.write(bytes)
        guard try slot.read() == bytes else { throw BackendCloudTrustRefusal.notSaved }
    }
    private func removeLegacy() {
        guard let legacyFile, FileManager.default.fileExists(atPath: legacyFile.path) else { return }
        try? FileManager.default.removeItem(at: legacyFile)
    }
}

/// The one owner of this Mac's trusted list for one account. It is also the list as the sync core reads it
/// (`CloudDeviceTrustPort`): the core asks for a device's stored key at the moment of applying each pack.
public actor BackendCloudTrustStore: CloudDeviceTrustPort {
    public static let limit = 256
    public nonisolated let subject: CloudSubject
    private let slot: BackendCloudTrustSlot
    private let now: @Sendable () -> Int64
    /// R3: true while a press cannot be taken as the person's own (the app's own remote-input path posted just now).
    /// No default (security review S2): whoever builds a list must say how a press is checked.
    private let pressRefused: @Sendable () -> Bool
    private var cached: BackendCloudTrustedList?
    public init(subject: CloudSubject, slot: BackendCloudTrustSlot,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                pressRefused: @escaping @Sendable () -> Bool) {
        self.subject = subject; self.slot = slot; self.now = now; self.pressRefused = pressRefused
    }
    /// The list as stored. Throws when the slot cannot be read or holds something this Mac must not use (another
    /// account's list, an unknown version, a damaged entry): callers then treat every device as not trusted.
    public func list() throws -> BackendCloudTrustedList {
        if let cached { return cached }
        guard let data = try slot.read() else {
            let empty = BackendCloudTrustedList(subject: subject, revision: 0, devices: [])
            cached = empty
            return empty
        }
        guard let stored = try? CloudWire.decode(BackendCloudTrustedList.self, from: data, maximumBytes: 409_600),
              stored.v == 1, stored.subject == subject, stored.devices.count <= Self.limit,
              Set(stored.devices.map { $0.deviceId }).count == stored.devices.count,
              Set(stored.devices.map { $0.keyId }).count == stored.devices.count,
              stored.devices.allSatisfy({ BackendCloudDeviceCode.isDeviceId($0.deviceId) && BackendCloudDeviceCode.keyId($0.signKey) == $0.keyId })
        else { throw BackendCloudTrustRefusal.unreadable }
        cached = stored
        return stored
    }
    private func save(_ devices: [BackendCloudTrustedList.Entry], after old: BackendCloudTrustedList) throws {
        let next = BackendCloudTrustedList(subject: subject, revision: old.revision + 1, devices: devices)
        let bytes = try CloudWire.canonical(next)
        do { try slot.write(bytes) } catch { cached = nil; throw BackendCloudTrustRefusal.notSaved }
        // Read back: the list is only what the slot really holds.
        guard let stored = try? slot.read(), stored == bytes else { cached = nil; throw BackendCloudTrustRefusal.notSaved }
        cached = next
    }
    /// Sign-in and every later start: this Mac's own identity joins the list (`how: self`). The Mac made that key,
    /// so no click is needed, and an earlier identity of this Mac stays trusted. Writes nothing when it is there.
    public func addSelf(_ registration: CloudDeviceRegistration) throws {
        guard BackendCloudDeviceCode.isDeviceId(registration.deviceId),
              let keyId = BackendCloudDeviceCode.keyId(registration.signPublicJwk) else { throw CloudFailure.invalidRequest }
        let old = try list()
        if let entry = old.devices.first(where: { $0.deviceId == registration.deviceId }) {
            // A stored key is never replaced.
            guard entry.keyId == keyId else { throw BackendCloudTrustRefusal.listChanged }
            return
        }
        // One key, one device: a key the list already holds for another device is never added again.
        guard !old.devices.contains(where: { $0.keyId == keyId }) else { throw BackendCloudTrustRefusal.sameKey }
        guard old.devices.count < Self.limit else { throw BackendCloudTrustRefusal.listFull }
        let entry = BackendCloudTrustedList.Entry(deviceId: registration.deviceId, signKey: registration.signPublicJwk, keyId: keyId,
                                                  name: BackendCloudTrustRows.plainName(registration.label), trust: "trusted", how: "self", trustedAt: now(),
                                                  platform: registration.platform.rawValue)
        try save(old.devices + [entry], after: old)
    }
    /// R3, asked at the moment of the press and before anything is awaited on the network: a press that follows the
    /// app's own remote input is not the person's.
    public func requirePress() throws {
        guard !pressRefused() else { throw BackendCloudTrustRefusal.remoteInput }
    }
    /// The ONLY way a device other than this Mac becomes trusted: the person's press in this Mac's own window.
    /// `captured` is what the sheet showed when it was drawn (R1): the key stored is that key. `latest`, a device
    /// list read after the press, can only cancel it; it never supplies a key. `restore` marks the new-Mac sheet.
    public func trust(_ captured: [BackendCloudTrustCapture], restore: Bool, latest: [CloudDeviceTrustRow]?) throws {
        guard !pressRefused() else { throw BackendCloudTrustRefusal.remoteInput }
        guard !captured.isEmpty, Set(captured.map { $0.deviceId }).count == captured.count else { throw CloudFailure.invalidRequest }
        let old = try list()
        var devices = old.devices
        // "Do not trust either" is the GROUP's alarm (run 14): the newest list is judged as a whole, so the press on
        // ANY device of a same-code or same-key group is refused, also when only its twin's line carries the mark.
        let newest = latest.map { BackendCloudTrustRows.alarmed($0) }
        for item in captured {
            // The code the person compared is the code of the key being stored, or nothing is stored.
            guard let keyId = BackendCloudDeviceCode.keyId(item.signKey), keyId == item.keyId,
                  BackendCloudDeviceCode.code(deviceId: item.deviceId, keyId: keyId) == item.code else { throw BackendCloudTrustRefusal.listChanged }
            // Two devices that show one code: neither can be trusted.
            let twinStored = devices.contains { $0.deviceId != item.deviceId && BackendCloudDeviceCode.code(deviceId: $0.deviceId, keyId: $0.keyId) == item.code }
            let twinTicked = captured.contains { $0.deviceId != item.deviceId && $0.code == item.code }
            guard !twinStored, !twinTicked else { throw BackendCloudTrustRefusal.sameCode }
            // Two devices with the SAME KEY: a signature could not say which of them made a pack. Neither is trusted,
            // whether the twin is already on the list, ticked beside it, or only shown by the newest device list.
            let keyStored = devices.contains { $0.deviceId != item.deviceId && $0.keyId == keyId }
            let keyTicked = captured.contains { $0.deviceId != item.deviceId && $0.keyId == item.keyId }
            guard !keyStored, !keyTicked else { throw BackendCloudTrustRefusal.sameKey }
            if let newest {
                guard let row = newest.first(where: { $0.deviceId == item.deviceId }), row.keyId == item.keyId else { throw BackendCloudTrustRefusal.listChanged }
                guard !row.sameCode else { throw BackendCloudTrustRefusal.sameCode }
                guard !row.sameKey else { throw BackendCloudTrustRefusal.sameKey }
                // Cloud reports the device as removed since the sheet was drawn: the press is cancelled (S5).
                guard !row.removed else { throw BackendCloudTrustRefusal.listChanged }
            }
            let entry = BackendCloudTrustedList.Entry(deviceId: item.deviceId, signKey: item.signKey, keyId: keyId, name: BackendCloudTrustRows.plainName(item.name),
                                                      trust: "trusted", how: restore ? "restore" : "click", trustedAt: now(),
                                                      platform: item.platform?.rawValue)
            if let index = devices.firstIndex(where: { $0.deviceId == item.deviceId }) {
                // A stored key is never replaced by a click; a device already trusted stays as it was.
                guard devices[index].keyId == keyId else { throw BackendCloudTrustRefusal.listChanged }
                if !devices[index].trusted { devices[index] = entry }
            } else {
                guard devices.count < Self.limit else { throw BackendCloudTrustRefusal.listFull }
                devices.append(entry)
            }
        }
        guard devices != old.devices else { return }
        try save(devices, after: old)
    }
    /// Automatic trust (owner, 13 Nov): every device of `rows` that a sheet could offer (new, readable key, no
    /// same-code or same-key alarm, not reported removed) and that this Mac has NEVER listed before is added with
    /// the key the service reports, `how: account`. A device already listed (trusted, or stopped by the person's
    /// Remove) is never touched: a changed key is not re-trusted here and a removed device does not come back.
    /// Returns the ids added. Not reachable from a tool: only the account's own status read calls it, in "account" mode.
    public func trustByAccount(_ rows: [CloudDeviceTrustRow]) throws -> [String] {
        let old = try list()
        var devices = old.devices
        var added: [String] = []
        for row in BackendCloudTrustRows.alarmed(rows) where row.canBeTrusted {
            guard let key = row.signKey, let keyId = BackendCloudDeviceCode.keyId(key), keyId == row.keyId,
                  !devices.contains(where: { $0.deviceId == row.deviceId || $0.keyId == keyId }),
                  devices.count < Self.limit else { continue }
            devices.append(.init(deviceId: row.deviceId, signKey: key, keyId: keyId, name: BackendCloudTrustRows.plainName(row.name),
                                 trust: "trusted", how: "account", trustedAt: now(), platform: row.platform?.rawValue))
            added.append(row.deviceId)
        }
        guard !added.isEmpty else { return [] }
        try save(devices, after: old)
        return added
    }
    /// "Remove" on the notice of a device that joined by itself: this Mac stops taking its changes. The entry stays,
    /// stopped, so automatic trust never adds it again. A press in this Mac's window only; never this Mac itself.
    public func stopTrusting(deviceId: String) throws {
        guard !pressRefused() else { throw BackendCloudTrustRefusal.remoteInput }
        let old = try list()
        guard let index = old.devices.firstIndex(where: { $0.deviceId == deviceId }), old.devices[index].how != "self" else { throw CloudFailure.invalidRequest }
        let was = old.devices[index]
        guard was.trusted else { return }
        var devices = old.devices
        devices[index] = .init(deviceId: was.deviceId, signKey: was.signKey, keyId: was.keyId, name: was.name, trust: "stopped", how: was.how,
                               trustedAt: was.trustedAt, stoppedAt: now(), stopReason: "removed", platform: was.platform)
        try save(devices, after: old)
    }
    /// Two-Mac proof (13 Nov): Cloud reports these devices as removed from the account (a device that signed out
    /// removes itself). Every trusted entry of theirs, an earlier sign-in of this very Mac included, is stopped, so
    /// this Mac no longer takes their changes and automatic trust never adds them again. This Mac's current identity
    /// is never touched. Only takes trust away, so it needs no press. Returns the ids stopped.
    @discardableResult
    public func stopRemovedByAccount(_ deviceIds: Set<String>, thisDeviceId: String?) throws -> [String] {
        let old = try list()
        var devices = old.devices
        var stopped: [String] = []
        for index in devices.indices where deviceIds.contains(devices[index].deviceId) && devices[index].deviceId != thisDeviceId && devices[index].trusted {
            let was = devices[index]
            devices[index] = .init(deviceId: was.deviceId, signKey: was.signKey, keyId: was.keyId, name: was.name, trust: "stopped", how: was.how,
                                   trustedAt: was.trustedAt, stoppedAt: now(), stopReason: "removed from account", platform: was.platform)
            stopped.append(was.deviceId)
        }
        guard !stopped.isEmpty else { return [] }
        try save(devices, after: old)
        return stopped
    }
    /// 15 Nov (passwords in the browser): a browser entry (kind "web") that was stopped because the account removed it
    /// (or he removed it here) is dropped from the list 30 days after it was stopped. A browser never comes back under
    /// the same id (a new key box is a new device), so nothing can return by itself; it only keeps private windows and
    /// cleared browsers from filling the list (limit 256). Computers and phones are never dropped. Returns the ids dropped.
    public static let browserKeptDays: Int64 = 30
    @discardableResult
    public func pruneRemovedBrowsers() throws -> [String] {
        let old = try list()
        let cutoff = now() - Self.browserKeptDays * 86_400_000
        let dropped = old.devices.filter { entry in
            entry.platform == CloudPlatform.web.rawValue && !entry.trusted && entry.how != "self"
                && (entry.stopReason == "removed" || entry.stopReason == "removed from account")
                && (entry.stoppedAt ?? Int64.max) <= cutoff
        }.map(\.deviceId)
        guard !dropped.isEmpty else { return [] }
        try save(old.devices.filter { !dropped.contains($0.deviceId) }, after: old)
        return dropped
    }
    /// MAC-NEXT-11 (an entry settled at 08:17 came back at 18:26 when the newer entry it was matched to left the list):
    /// an entry this rule once stopped STAYS stopped, remembered by its device id (its stop reason). It never comes
    /// back by itself; only a device that proves it is alive by signing something new after the settling (`alive`:
    /// device id -> when this Mac first met its new pack) may, and then only by the normal trust path: under automatic
    /// trust its stored key (and only that key) is trusted again; under "ask me" its row is shown for the person's press.
    /// 13 Nov leftover (the owner's Macs list five earlier entries of their own sign-ins, all trusted by press): an
    /// entry the account's list shows as STALE (`BackendCloudTrustRows.stale`: same name and kind as a newer entry with
    /// another key, not seen since that one joined) is never trusted. A trusted stale entry is stopped with the reason
    /// "stale"; like the removal rule this only takes trust away, so it needs no press. Should the account list show
    /// that device as active and not stale again, under the very key this Mac stored, only an entry THIS rule stopped
    /// is trusted again (nothing the person stopped, and never a new key). This Mac's current identity is never touched.
    @discardableResult
    public func settleStale(_ staleIds: Set<String>, activeKeys: [String: String], thisDeviceId: String?,
                            alive: [String: Int64] = [:], automatic: Bool = true) throws -> (stopped: [String], restored: [String]) {
        let old = try list()
        var devices = old.devices
        var stopped: [String] = [], restored: [String] = []
        for index in devices.indices where devices[index].deviceId != thisDeviceId {
            let was = devices[index]
            if staleIds.contains(was.deviceId), was.trusted {
                devices[index] = .init(deviceId: was.deviceId, signKey: was.signKey, keyId: was.keyId, name: was.name, trust: "stopped", how: was.how,
                                       trustedAt: was.trustedAt, stoppedAt: now(), stopReason: Self.staleReason, platform: was.platform)
                stopped.append(was.deviceId)
            } else if automatic, !staleIds.contains(was.deviceId), !was.trusted, was.stopReason == Self.staleReason,
                      Self.signedSince(was, alive: alive), activeKeys[was.deviceId] == was.keyId,
                      !devices.contains(where: { $0.deviceId != was.deviceId && $0.trusted && $0.keyId == was.keyId }) {
                devices[index] = .init(deviceId: was.deviceId, signKey: was.signKey, keyId: was.keyId, name: was.name, trust: "trusted", how: was.how,
                                       trustedAt: was.trustedAt, platform: was.platform)
                restored.append(was.deviceId)
            }
        }
        guard !stopped.isEmpty || !restored.isEmpty else { return ([], []) }
        try save(devices, after: old)
        return (stopped, restored)
    }
    public static let staleReason = "stale"
    /// The device signed something new after this Mac settled its entry as an earlier one.
    static func signedSince(_ entry: BackendCloudTrustedList.Entry, alive: [String: Int64]) -> Bool {
        guard let signed = alive[entry.deviceId] else { return false }
        return signed > (entry.stoppedAt ?? Int64.max)
    }
    /// "Remove" in Settings › Cloud › Reach (item 4, 13 Nov: one Remove means one thing): this Mac also stops taking
    /// the device's changes. A trusted entry is stopped; a device this Mac has not listed yet is listed as stopped with
    /// the key Cloud reports (`row`), so automatic trust never adds it later. This Mac itself, a device already
    /// stopped, and a device with no readable key are left as they are. A press in this Mac's window only.
    /// Returns whether the list changed.
    @discardableResult
    public func stopForReachRemoval(deviceId: String, row: CloudDeviceTrustRow?) throws -> Bool {
        guard !pressRefused() else { throw BackendCloudTrustRefusal.remoteInput }
        let old = try list()
        var devices = old.devices
        if let index = devices.firstIndex(where: { $0.deviceId == deviceId }) {
            let was = devices[index]
            guard was.how != "self", was.trusted else { return false }
            devices[index] = .init(deviceId: was.deviceId, signKey: was.signKey, keyId: was.keyId, name: was.name, trust: "stopped", how: was.how,
                                   trustedAt: was.trustedAt, stoppedAt: now(), stopReason: "removed", platform: was.platform)
        } else {
            guard BackendCloudDeviceCode.isDeviceId(deviceId), let row, row.deviceId == deviceId, row.standing == .new,
                  let key = row.signKey, let keyId = BackendCloudDeviceCode.keyId(key),
                  !devices.contains(where: { $0.keyId == keyId }), devices.count < Self.limit else { return false }
            let at = now()
            devices.append(.init(deviceId: deviceId, signKey: key, keyId: keyId, name: BackendCloudTrustRows.plainName(row.name), trust: "stopped",
                                 how: "account", trustedAt: at, stoppedAt: at, stopReason: "removed", platform: row.platform?.rawValue))
        }
        try save(devices, after: old)
        return true
    }
    /// The one button for a device whose reported key CHANGED (automatic mode): the person's press stores the key
    /// the row showed when it was drawn (R1), in place of the old one. A press in this Mac's window only.
    public func trustChangedKey(_ row: CloudDeviceTrustRow) throws {
        guard !pressRefused() else { throw BackendCloudTrustRefusal.remoteInput }
        guard row.keyChanged, !row.sameKey, !row.sameCode, !row.removed, let key = row.signKey,
              let keyId = BackendCloudDeviceCode.keyId(key), keyId == row.keyId else { throw BackendCloudTrustRefusal.listChanged }
        let old = try list()
        guard let index = old.devices.firstIndex(where: { $0.deviceId == row.deviceId }), old.devices[index].how != "self",
              old.devices[index].trusted else { throw BackendCloudTrustRefusal.listChanged }
        guard !old.devices.contains(where: { $0.deviceId != row.deviceId && $0.keyId == keyId }) else { throw BackendCloudTrustRefusal.sameKey }
        var devices = old.devices
        devices[index] = .init(deviceId: row.deviceId, signKey: key, keyId: keyId, name: BackendCloudTrustRows.plainName(row.name),
                               trust: "trusted", how: "click", trustedAt: now(),
                               platform: old.devices[index].platform ?? row.platform?.rawValue)
        try save(devices, after: old)
    }
    /// Review blocker 1 of PASSWORDS-2: an entry stored before the kind of device was kept gets it ONCE, from a row
    /// that reports the very key stored here (`build` gives a row a kind only then). A kind once kept never changes.
    /// Only fills a missing fact (it trusts nothing new), so it needs no press. Returns the ids filled.
    @discardableResult
    public func notePlatforms(_ rows: [CloudDeviceTrustRow]) throws -> [String] {
        let old = try list()
        var devices = old.devices
        var filled: [String] = []
        for index in devices.indices where devices[index].platform == nil {
            let was = devices[index]
            guard let row = rows.first(where: { $0.deviceId == was.deviceId }), !row.keyChanged, row.keyId == was.keyId,
                  let kind = row.platform else { continue }
            devices[index] = .init(deviceId: was.deviceId, signKey: was.signKey, keyId: was.keyId, name: was.name, trust: was.trust, how: was.how,
                                   trustedAt: was.trustedAt, stoppedAt: was.stoppedAt, stopReason: was.stopReason, platform: kind.rawValue)
            filled.append(was.deviceId)
        }
        guard !filled.isEmpty else { return [] }
        try save(devices, after: old)
        return filled
    }
    /// The sync core's question: the key stored on this Mac for `deviceId`, only while that entry is trusted. nil
    /// for an unknown or stopped device and when the list cannot be read (its packs then wait). Never the service's
    /// word: nothing here can reach the service.
    public func trustedSigningKey(deviceId: String) async -> CloudPublicJWK? {
        guard let found = entry(deviceId: deviceId), found.trusted else { return nil }
        return found.signKey
    }
    /// Has the person confirmed, by a press in THIS Mac's own window, at least one device other than this Mac that
    /// this Mac takes changes from? True only when the stored list holds a trusted entry made by the trust sheet
    /// ("click") or the new-Mac sheet ("restore"); this Mac's own identities ("self") never count. Answered from
    /// this Mac's list alone: never from the service, a tool or a field in a pack. Lane A2 review: an unreadable list
    /// answers nil ("could not read"), never "not confirmed", so a passing read error cannot decide for good.
    /// Lane A2 reads it at the moment an agent that is new to this Mac is applied (its project and seat arrive only
    /// then); the entry is always stored before the sync core is told to release that device's changes.
    public func hasDeviceTrustedByPress() -> Bool? {
        guard let stored = try? list() else { return nil }
        // Automatic trust: the person chose "Automatically, with my account" (the default), so a device the account
        // listed counts as confirmed too. In "ask" mode no "account" entry is ever made.
        return stored.devices.contains { $0.trusted && ($0.how == "click" || $0.how == "restore" || $0.how == "account") }
    }
    /// The stored entry, or nil when the device is not on the list or the list cannot be read (an unreadable list
    /// fails safe: everything waits).
    public func entry(deviceId: String) -> BackendCloudTrustedList.Entry? {
        (try? list())?.devices.first { $0.deviceId == deviceId }
    }
}

/// The Devices section's rows: the service's device list seen through this Mac's trusted list.
public enum BackendCloudTrustRows {
    public typealias Coder = @Sendable (_ deviceId: String, _ key: CloudPublicJWK) -> (keyId: String, code: String)?
    public static let unnamed = "Unnamed device"
    /// Security review M1: a device's name is text THE DEVICE chose, shown next to the code the person compares. It
    /// is cut down to one plain short line that cannot look like anything else on the sheet: letters, digits, spaces
    /// and a little plain punctuation only (no line break, control, direction or invisible character, no colon), no
    /// run that reads like a code, at most 40 characters. Every screen, sheet, status line, stored entry and tool
    /// answer uses this form and never the raw text.
    public static func plainName(_ raw: String) -> String {
        var cleaned = ""
        for scalar in raw.unicodeScalars.prefix(400) {
            let plain = scalar.properties.isAlphabetic || scalar.properties.numericType != nil || "-_.,'()&+".unicodeScalars.contains(scalar)
            cleaned.unicodeScalars.append(plain && !scalar.properties.isDefaultIgnorableCodePoint ? scalar : " ")
        }
        func hex(_ word: Substring) -> Bool { word.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.isASCIIHexDigit } }
        var words: [Substring] = []
        var run: [Substring] = []
        func flush() {
            // Three or more groups of four hex characters in a row read as a device code: they are dropped.
            if run.count < 3 { words += run }
            run = []
        }
        for word in cleaned.split(separator: " ") {
            if hex(word), word.count >= 12 { flush(); continue }      // a code written without spaces
            if hex(word), word.count == 4 { run.append(word) } else { flush(); words.append(word) }
        }
        flush()
        let line = words.joined(separator: " ")
        if line.isEmpty { return unnamed }
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }
    /// Security review S5: the first or the last group of four is the same on two different codes. Matching all 80
    /// bits is out of reach for an intruder; matching the two ends takes seconds, and the intruder knows the real
    /// Mac's code. The ids of every row whose code looks like another row's at either end.
    public static func lookAlike(_ rows: [CloudDeviceTrustRow]) -> Set<String> {
        var first: [Substring: Set<String>] = [:], last: [Substring: Set<String>] = [:], whole: [String: String] = [:]
        for row in rows {
            guard let code = row.code, code.count == 24 else { continue }
            whole[row.deviceId] = code
            first[code.prefix(4), default: []].insert(code)
            last[code.suffix(4), default: []].insert(code)
        }
        var found: Set<String> = []
        for (deviceId, code) in whole where (first[code.prefix(4)]?.count ?? 0) > 1 || (last[code.suffix(4)]?.count ?? 0) > 1 {
            found.insert(deviceId)
        }
        return found
    }
    /// Does the service list, under this Mac's own id, a key other than the one this Mac holds? (Security review M2.)
    public static func serviceShowsAnotherKeyForThisMac(devices: [CloudDevice], thisDeviceId: String?, thisKey: CloudPublicJWK?) -> Bool {
        guard let thisDeviceId, let thisKey, let mine = BackendCloudDeviceCode.keyId(thisKey) else { return false }
        return devices.contains { $0.deviceId == thisDeviceId && BackendCloudDeviceCode.keyId($0.signPublicJwk) != mine }
    }
    /// Two-Mac proof (13 Nov): after a Mac signs out and in again, the account can still list its earlier entry
    /// (the removal at sign-out failed, or happened offline). That entry is STALE: another active device of the same
    /// kind and the same name, with another key, was added after the entry was last seen. This Mac itself (its current
    /// identity) is never stale. A stale entry is never trusted automatically and is not shown.
    ///
    /// MAC-NEXT-11: entries are matched by the RECORDED name (`label`, the host name the device registered with), never
    /// by the friendly display name. A row the service marks as replaced (`supersededBy`) is stale. With `now`, an
    /// entry is also stale when another active entry of the same kind and recorded name, with another key, was seen at
    /// least 2 hours after it and it has been quiet for 2 hours (the service's own quiet window): its newer partner may
    /// have left the list since (the service retires replaced rows), which must not bring the earlier entry back.
    /// The quiet window applies to full devices only, never to viewers (phones, browsers).
    public static let quietMilliseconds: Int64 = 2 * 3_600_000
    public static func stale(devices: [CloudDevice], thisDeviceId: String?, now: Int64? = nil) -> Set<String> {
        var found: Set<String> = []
        for old in devices where old.status == .active && old.deviceId != thisDeviceId && old.supersededBy != nil { found.insert(old.deviceId) }
        for old in devices where old.status == .active && old.deviceId != thisDeviceId && !found.contains(old.deviceId) {
            let name = plainName(old.label), key = BackendCloudDeviceCode.keyId(old.signPublicJwk)
            let replaced = devices.contains { newer in
                newer.deviceId != old.deviceId && newer.status == .active && newer.platform == old.platform && plainName(newer.label) == name
                    && BackendCloudDeviceCode.keyId(newer.signPublicJwk) != key && newer.supersededBy == nil
                    && ((newer.registeredAt ?? Int64.min) > old.lastSeenAt
                        // The quiet window is for full devices only (Macs, PCs: they hold a copy). Viewers (phones,
                        // browsers) are often quiet for hours, and two phones both called "iPhone" are two real phones.
                        || !old.isViewer && !newer.isViewer
                            && now.map { $0 - old.lastSeenAt >= quietMilliseconds && newer.lastSeenAt - old.lastSeenAt >= quietMilliseconds } ?? false)
            }
            if replaced { found.insert(old.deviceId) }
        }
        return found
    }
    /// `thisKey` is the signing key THIS MAC holds for its current sign-in. This Mac's own row is always shown by
    /// that key (or by the entry this Mac stored for itself), never by the key the service lists under its id.
    /// `listReadable` false means this Mac's trusted list could not be read: nobody can be trusted from a sheet then.
    public static func build(devices: [CloudDevice], list: BackendCloudTrustedList?, thisDeviceId: String?,
                             thisKey: CloudPublicJWK? = nil, listReadable: Bool = true,
                             waiting: [String: Int] = [:], markKeyChanges: Bool = false, now: Int64? = nil, alive: [String: Int64] = [:],
                             code: Coder = { BackendCloudDeviceCode.code(deviceId: $0, key: $1) }) -> [CloudDeviceTrustRow] {
        let entries = list?.devices ?? []
        // MAC-NEXT-11: an entry this Mac settled as an earlier one stays hidden until that device signs something new.
        let settled = Set(entries.filter { !$0.trusted && $0.stopReason == BackendCloudTrustStore.staleReason
            && !BackendCloudTrustStore.signedSince($0, alive: alive) }.map(\.deviceId))
        // A device id the service lists twice has no readable key: neither line can be trusted.
        var counts: [String: Int] = [:]
        for device in devices { counts[device.deviceId, default: 0] += 1 }
        var seen: Set<String> = []
        var rows: [CloudDeviceTrustRow] = []
        let staleIds = stale(devices: devices, thisDeviceId: thisDeviceId, now: now).union(settled.subtracting([thisDeviceId ?? ""]))
        for device in devices where seen.insert(device.deviceId).inserted {
            let entry = entries.first { $0.deviceId == device.deviceId && $0.trusted }
            let isThisMac = device.deviceId == thisDeviceId
            // A trusted device is shown by the key this Mac stored, never by the one the service shows now. This Mac
            // itself is shown ONLY by a key it holds: with none at hand it shows no code at all (M2).
            let key: CloudPublicJWK? = isThisMac ? (thisKey ?? entry?.signKey) : (entry?.signKey ?? device.signPublicJwk)
            let named = counts[device.deviceId] == 1 ? key.flatMap { code(device.deviceId, $0) } : nil
            let standing: CloudDeviceTrustRow.Standing = isThisMac ? .thisMac : (entry == nil ? .new : .trusted)
            // With the list unreadable a new device keeps its code on screen but carries no key a press could store.
            let offered = named != nil && (listReadable || isThisMac)
            // Automatic mode only: Cloud reports another key than the one this Mac stored. The row then carries the
            // REPORTED key, so the one button stores what the person saw; nothing is stored without that press.
            if markKeyChanges, !isThisMac, let entry, entry.how != "self", counts[device.deviceId] == 1,
               let reported = BackendCloudDeviceCode.keyId(device.signPublicJwk), reported != entry.keyId,
               let shown = code(device.deviceId, device.signPublicJwk) {
                rows.append(.init(deviceId: device.deviceId, name: plainName(device.shownName), standing: standing, code: shown.code, keyId: shown.keyId,
                                  signKey: listReadable ? device.signPublicJwk : nil, knownSince: entry.trustedAt, addedAt: device.registeredAt,
                                  waiting: waiting[device.deviceId] ?? 0, removed: device.status == .revoked, byAccount: entry.how == "account",
                                  keyChanged: true, stale: staleIds.contains(device.deviceId)))
                continue
            }
            rows.append(.init(deviceId: device.deviceId, name: plainName(device.shownName), standing: standing, code: named?.code, keyId: named?.keyId,
                              signKey: offered ? key : nil, knownSince: entry?.trustedAt, addedAt: device.registeredAt,
                              waiting: waiting[device.deviceId] ?? 0, removed: device.status == .revoked,
                              byAccount: markKeyChanges && entry?.how == "account", stale: staleIds.contains(device.deviceId),
                              platform: entry == nil || BackendCloudDeviceCode.keyId(device.signPublicJwk) == entry?.keyId ? device.platform : nil))
        }
        // Every code and every key this Mac knows of: the rows, and trusted devices the service no longer lists.
        var owners: [String: Set<String>] = [:], keyOwners: [String: Set<String>] = [:]
        for row in rows {
            if let shown = row.code { owners[shown, default: []].insert(row.deviceId) }
            if let key = row.keyId { keyOwners[key, default: []].insert(row.deviceId) }
        }
        for entry in entries where !seen.contains(entry.deviceId) {
            if let named = code(entry.deviceId, entry.signKey) { owners[named.code, default: []].insert(entry.deviceId) }
            keyOwners[entry.keyId, default: []].insert(entry.deviceId)
        }
        rows = alarmed(rows, codes: owners, keys: keyOwners)
        func rank(_ row: CloudDeviceTrustRow) -> Int { row.standing == .thisMac ? 0 : (row.standing == .trusted ? 1 : 2) }
        return rows.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            // Security review S5: among new devices the OLDEST come first, so an intruder's fresh devices can never
            // push the person's own Macs down the list. A device with no reported date counts as the newest.
            if a.standing == .new, (a.addedAt ?? Int64.max) != (b.addedAt ?? Int64.max) { return (a.addedAt ?? Int64.max) < (b.addedAt ?? Int64.max) }
            if a.name != b.name { return a.name < b.name }
            return a.deviceId < b.deviceId
        }
    }
    /// "Do not trust either" is the GROUP's alarm (run 14: a list reached the screen with the alarm on the second of
    /// two devices only, and the first kept an enabled Trust button). Every row whose code another row of the same
    /// list also shows, or whose key another row also uses, carries the alarm, whichever of them was handed over
    /// marked; a mark a row already carries is never taken away. The Devices rows, both sheets and the press itself
    /// judge their list through this, so no device of a group can be trusted from any of them.
    public static func alarmed(_ rows: [CloudDeviceTrustRow]) -> [CloudDeviceTrustRow] {
        var codes: [String: Set<String>] = [:], keys: [String: Set<String>] = [:]
        for row in rows {
            if let shown = row.code { codes[shown, default: []].insert(row.deviceId) }
            if let key = row.keyId { keys[key, default: []].insert(row.deviceId) }
        }
        return alarmed(rows, codes: codes, keys: keys)
    }
    /// `codes` and `keys`: the device ids that show each code and use each key. Same order, same count as `rows`.
    private static func alarmed(_ rows: [CloudDeviceTrustRow], codes: [String: Set<String>], keys: [String: Set<String>]) -> [CloudDeviceTrustRow] {
        rows.map { row -> CloudDeviceTrustRow in
            let codeShared = row.code.map { (codes[$0]?.count ?? 0) > 1 } ?? false
            let keyShared = row.keyId.map { (keys[$0]?.count ?? 0) > 1 } ?? false
            let codeTwin = row.sameCode || codeShared
            let keyTwin = row.sameKey || keyShared
            guard codeTwin != row.sameCode || keyTwin != row.sameKey else { return row }
            return CloudDeviceTrustRow(deviceId: row.deviceId, name: row.name, standing: row.standing, code: row.code, keyId: row.keyId,
                                       signKey: row.signKey, knownSince: row.knownSince, addedAt: row.addedAt, waiting: row.waiting,
                                       sameCode: codeTwin, sameKey: keyTwin, removed: row.removed, byAccount: row.byAccount,
                                       keyChanged: row.keyChanged, stale: row.stale, platform: row.platform)
        }
    }
}
