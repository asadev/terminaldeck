import Foundation
import CryptoKit
import TerminalDeckNativeCore

public enum BackendRemoteDeviceKind: String, Sendable { case mine, guest }
public struct BackendRemoteDevice: Equatable, Sendable {
    public let id: String
    public let name: String
    public let addedAt: Double
    public let lastSeenAt: Double?
    public let approved: Bool
    public let revoked: Bool
    public let fingerprint: String?
    public var status: String { revoked ? "revoked" : approved ? "approved" : "pending" }
    public var value: NativeRPCValue { .object([.init("id", .string(id)), .init("name", .string(name)), .init("addedAt", .number(addedAt)),
        .init("lastSeenAt", lastSeenAt.map(NativeRPCValue.number) ?? .null), .init("approved", .bool(approved)), .init("revoked", .bool(revoked)),
        .init("status", .string(status)), .init("fingerprint", fingerprint.map(NativeRPCValue.string) ?? .null)]) }
}
public struct BackendRemotePairingOffer: Sendable { public let token: String; public let expiresAt: Double }
public struct BackendRemoteCredential: Sendable { public let credential: String; public let device: BackendRemoteDevice }
public enum BackendRemoteTrustFailure: Error, Sendable { case denied(String), storage(String), closed }

/// Same files/credential hashing as RemoteAuth, not a parallel trust database.
/// open() is explicit; construction never reads credentials or creates files.
public actor BackendRemoteTrustStore {
    struct Credential: Sendable {
        let n: Int, r: Int, p: Int, keylen: Int
        let salt: String, hash: String
        var value: NativeRPCValue { .object([.init("n", .number(Double(n))), .init("r", .number(Double(r))), .init("p", .number(Double(p))),
            .init("keylen", .number(Double(keylen))), .init("salt", .string(salt)), .init("hash", .string(hash))]) }
    }
    struct StoredDevice: Sendable {
        let id: String
        var name: String
        let addedAt: Double
        var lastSeenAt: Double?
        var approved: Bool
        var revoked: Bool
        var credential: Credential
        var publicKey: String?
        var key: Data? { publicKey.flatMap(BackendRemoteTrustStorage.base64).flatMap { $0.count == 32 ? $0 : nil } }
        var publicDevice: BackendRemoteDevice { .init(id: id, name: name, addedAt: addedAt, lastSeenAt: lastSeenAt, approved: approved, revoked: revoked,
            fingerprint: key.map(sealedFingerprint)) }
        var value: NativeRPCValue { .object([.init("id", .string(id)), .init("name", .string(name)), .init("addedAt", .number(addedAt)),
            .init("lastSeenAt", lastSeenAt.map(NativeRPCValue.number) ?? .null), .init("approved", .bool(approved)), .init("revoked", .bool(revoked)),
            .init("credential", credential.value), .init("publicKey", publicKey.map(NativeRPCValue.string) ?? .missing)]) }
    }
    struct Token: Sendable { let hash: Data; let expiresAt: Double; var used: Bool }
    struct Attempt: Sendable { var failures = 0; var blockedUntil = 0.0; var updatedAt = 0.0 }
    struct KindRecord: Sendable { let kind: BackendRemoteDeviceKind; let decidedAt: Double }
    struct Share: Sendable { var all: Bool; var ids: [String] }

    public nonisolated let directory: URL
    let clock: @Sendable () -> Double
    var lease: BackendRemoteTrustLease?
    var identity: BackendRemoteHostIdentity?
    var devices: [StoredDevice] = []
    var tokens: [Token] = []
    var liveOffer: (hash: Data, expiresAt: Double, misses: Int)?
    var attempts: [String: Attempt] = [:]
    var decoySalt = Data()
    var folderGrants: [String: [String]] = [:]
    var sessionGrants: [String: Share] = [:]
    var accountGrants: [String: Share] = [:]
    var kinds: [String: KindRecord] = [:]
    var windowAllowed: Set<String> = [], windowDenied: Set<String> = []
    public var onChanged: (@Sendable () -> Void)?

    public init(directory: URL, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) { self.directory = directory; self.clock = clock }
    public func setChangeHandler(_ handler: (@Sendable () -> Void)?) { onChanged = handler }
    public func open() throws {
        if lease != nil { return }
        let held = try BackendRemoteTrustLease(directory: directory)
        do {
            let loaded = try BackendRemoteTrustStorage.identity(directory: directory)
            try loadDevices()
            loadGrants()
            decoySalt = try BackendRemoteTrustStorage.random(16)
            identity = loaded; lease = held
        } catch { throw error }
    }
    public func close() { cancelPairing(); lease = nil; identity = nil; devices = []; attempts = [:]; decoySalt = Data() }
    public func hostIdentity() throws -> BackendRemoteHostIdentity { try requireOpen(); guard let identity else { throw BackendRemoteTrustFailure.closed }; return identity }
    public func listDevices() -> [BackendRemoteDevice] { devices.map(\.publicDevice) }
    public func device(_ id: String) -> BackendRemoteDevice? { devices.first { $0.id == id }?.publicDevice }
    public func isApproved(_ id: String) -> Bool { devices.contains { $0.id == id && $0.approved && !$0.revoked } }
    public func handshakePolicy() -> (knownKeys: Set<Data>, permitUnknown: Bool) {
        (Set(devices.filter { !$0.revoked }.compactMap(\.key)), pairingOpen())
    }
    public func deviceHoldsKey(_ id: String, key: Data) -> Bool { devices.first { $0.id == id }?.key.map { BackendRemoteTrustStorage.equal($0, key) } ?? false }

    public func createPairingOffer() throws -> BackendRemotePairingOffer {
        try requireOpen()
        let now = clock()
        tokens.removeAll { now >= $0.expiresAt }
        while tokens.count >= 16 { tokens.removeFirst() }
        let random = [UInt8](try BackendRemoteTrustStorage.random(16))
        let code: String
        do { code = try BackendShortCode.codeFromBytes(random) } catch { throw BackendRemoteTrustFailure.storage("Could not create unbiased pairing randomness") }
        let digest = Data(SHA256.hash(data: Data(code.utf8))), expiry = now + 60000
        tokens.append(Token(hash: digest, expiresAt: expiry, used: false))
        liveOffer = (digest, expiry, 0)
        return .init(token: code, expiresAt: expiry)
    }
    public func cancelPairing() { liveOffer = nil }
    public func pairingOpen() -> Bool {
        guard let live = liveOffer, clock() < live.expiresAt else { liveOffer = nil; return false }
        return true
    }
    /// Misses belong to the offer, not the peer's freely minted relay key.
    private func offers(_ text: String) -> Bool {
        guard pairingOpen(), var offer = liveOffer else { return false }
        if BackendRemoteTrustStorage.equal(Data(SHA256.hash(data: Data(text.utf8))), offer.hash) { return true }
        offer.misses += 1
        liveOffer = offer.misses >= 5 ? nil : offer
        return false
    }
    public func redeem(_ token: String, name: String, address: String, publicKey: Data?) async throws -> BackendRemoteCredential {
        try requireOpen()
        guard !token.isEmpty, token.utf16.count <= 512, offers(token) else { throw BackendRemoteTrustFailure.denied("That pairing code is not right.") }
        let now = clock(), keys = [addressKey(address)]
        guard blocked(keys, now: now) == 0 else { throw BackendRemoteTrustFailure.denied("Too many failed attempts. Try again later.") }
        let hash = Data(SHA256.hash(data: Data(token.utf8)))
        var found: Int?
        for index in tokens.indices { if BackendRemoteTrustStorage.equal(tokens[index].hash, hash) { found = index } }
        guard let index = found else { failed(keys, now: now); throw BackendRemoteTrustFailure.denied("That pairing code is not right.") }
        let spent = tokens[index].used; tokens[index].used = true
        guard !spent, now < tokens[index].expiresAt else { throw BackendRemoteTrustFailure.denied("That pairing code has already been used or has expired.") }
        guard let name = cleanName(name) else { throw BackendRemoteTrustFailure.denied("The device name is unusable.") }
        let key = publicKey.flatMap { $0.count == 32 ? $0 : nil }
        let previous = key.flatMap { wanted in devices.first { !$0.revoked && $0.key.map { BackendRemoteTrustStorage.equal($0, wanted) } == true } }
        let roster = rosterWithRoom()
        guard previous != nil || roster.count < 64 else { throw BackendRemoteTrustFailure.denied("This host has too many paired devices.") }
        let secret = try BackendRemoteTrustStorage.random(32), salt = try BackendRemoteTrustStorage.random(16)
        let credential = try await makeCredential(secret, salt: salt)
        try requireOpen()
        if let previous, devices.first(where: { $0.id == previous.id })?.revoked != false {
            throw BackendRemoteTrustFailure.denied("This device was revoked while pairing.")
        }
        // The code is consumed before any asynchronous hash or persistence.
        cancelPairing()
        let deviceID = try previous?.id ?? mintDeviceID()
        let record = StoredDevice(id: deviceID, name: name, addedAt: previous?.addedAt ?? now,
            lastSeenAt: previous?.lastSeenAt, approved: previous?.approved ?? false, revoked: false, credential: credential,
            publicKey: key?.base64EncodedString() ?? previous?.publicKey)
        let currentRoster = rosterWithRoom()
        guard previous != nil || currentRoster.count < 64 else { throw BackendRemoteTrustFailure.denied("This host has too many paired devices.") }
        var next = currentRoster.filter { $0.id != record.id }; next.append(record)
        try commit(next)
        clearFailures(keys)
        return .init(credential: record.id + "." + BackendRemoteTrustStorage.base64URL(secret), device: record.publicDevice)
    }
    public func verify(_ text: String, address: String, peerKey: Data?) async throws -> BackendRemoteDevice {
        try requireOpen()
        guard text.utf16.count <= 512, let dot = text.firstIndex(of: "."), dot != text.startIndex else { throw BackendRemoteTrustFailure.denied("This device is not allowed in.") }
        let id = String(text[..<dot]), encoded = String(text[text.index(after: dot)...])
        guard BackendRemoteTrustStorage.decodeURL(id) != nil, let secret = BackendRemoteTrustStorage.decodeURL(encoded), !secret.isEmpty else { throw BackendRemoteTrustFailure.denied("This device is not allowed in.") }
        let now = clock(), limits = ["device:" + id, addressKey(address)]
        guard blocked(limits, now: now) == 0 else { throw BackendRemoteTrustFailure.denied("Too many failed attempts. Try again later.") }
        let captured = devices.first { $0.id == id }
        let params = captured?.credential ?? Credential(n: 16384, r: 8, p: 1, keylen: 32, salt: decoySalt.base64EncodedString(), hash: "")
        let salt = BackendRemoteTrustStorage.base64(params.salt) ?? Data()
        let actual = try await Task.detached(priority: .utility) { try BackendPairingDerivation.scrypt(password: secret, salt: salt, n: params.n, r: params.r, p: params.p, length: params.keylen) }.value
        try requireOpen()
        guard let old = captured, let expected = BackendRemoteTrustStorage.base64(old.credential.hash), BackendRemoteTrustStorage.equal(actual, expected),
              let index = devices.firstIndex(where: { $0.id == id }), devices[index].credential.hash == old.credential.hash else {
            failed(limits, now: now); throw BackendRemoteTrustFailure.denied("This device is not allowed in.")
        }
        guard !devices[index].revoked else { failed(limits, now: now); throw BackendRemoteTrustFailure.denied("This device is not allowed in.") }
        guard devices[index].approved else { throw BackendRemoteTrustFailure.denied("This device is waiting to be approved. Approve it in the app on this Mac, then reconnect.") }
        if let peerKey, !deviceHoldsKey(id, key: peerKey) { failed(limits, now: now); throw BackendRemoteTrustFailure.denied("This device is not allowed in.") }
        clearFailures(limits)
        let previous = devices[index].lastSeenAt
        devices[index].lastSeenAt = now
        if previous == nil || now - (previous ?? 0) >= 60000 {
            do { try persist(devices) } catch { devices[index].lastSeenAt = previous }
        }
        return devices[index].publicDevice
    }
    public func enrollmentAllowed(address: String) -> Bool { blocked(["enroll:" + addressKey(address)], now: clock()) == 0 }
    public func noteEnrollmentFailure(address: String) { failed(["enroll:" + addressKey(address)], now: clock()) }
    /// Call only after the supplied system-login verifier proves the login.
    public func enrollVerifiedDevice(name: String, address: String, publicKey: Data) async throws -> BackendRemoteCredential {
        try requireOpen()
        guard publicKey.count == 32, let name = cleanName(name), enrollmentAllowed(address: address) else { throw BackendRemoteTrustFailure.denied("Sign-in could not be accepted.") }
        let previous = devices.first { !$0.revoked && $0.key.map { BackendRemoteTrustStorage.equal($0, publicKey) } == true }
        guard previous != nil || rosterWithRoom().count < 64 else { throw BackendRemoteTrustFailure.denied("This host has too many paired devices.") }
        let secret = try BackendRemoteTrustStorage.random(32), salt = try BackendRemoteTrustStorage.random(16)
        let credential = try await makeCredential(secret, salt: salt)
        try requireOpen()
        if let previous, devices.first(where: { $0.id == previous.id })?.revoked != false { throw BackendRemoteTrustFailure.denied("This device was revoked while signing in.") }
        let id = try previous?.id ?? mintDeviceID()
        try claimKind(id, kind: .mine)
        let record = StoredDevice(id: id, name: name, addedAt: previous?.addedAt ?? clock(), lastSeenAt: previous?.lastSeenAt,
            approved: true, revoked: false, credential: credential, publicKey: publicKey.base64EncodedString())
        var next = rosterWithRoom().filter { $0.id != id }; next.append(record)
        guard next.count <= 64 else { throw BackendRemoteTrustFailure.denied("This host has too many paired devices.") }
        try commit(next); clearFailures(["enroll:" + addressKey(address)])
        return .init(credential: id + "." + BackendRemoteTrustStorage.base64URL(secret), device: record.publicDevice)
    }
    @discardableResult
    public func approve(_ id: String, kind: BackendRemoteDeviceKind) throws -> Bool {
        try requireOpen()
        guard let index = devices.firstIndex(where: { $0.id == id }), !devices[index].revoked else { return false }
        try claimKind(id, kind: kind)
        if devices[index].approved { return false }
        var next = devices; next[index].approved = true; try commit(next); return true
    }
    @discardableResult
    public func revoke(_ id: String) throws -> Bool {
        try requireOpen()
        guard let index = devices.firstIndex(where: { $0.id == id }), !devices[index].revoked else { return false }
        var next = devices; next[index].revoked = true; try commit(next); clearFailures(["device:" + id]); return true
    }
    func requireOpen() throws { guard lease != nil else { throw BackendRemoteTrustFailure.closed } }
    private func makeCredential(_ secret: Data, salt: Data) async throws -> Credential {
        let hash = try await Task.detached(priority: .utility) { try BackendPairingDerivation.scrypt(password: secret, salt: salt, n: 16384, r: 8, p: 1, length: 32) }.value
        return Credential(n: 16384, r: 8, p: 1, keylen: 32, salt: salt.base64EncodedString(), hash: hash.base64EncodedString())
    }
    private func mintDeviceID() throws -> String {
        for _ in 0..<64 {
            let id = BackendRemoteTrustStorage.base64URL(try BackendRemoteTrustStorage.random(12))
            if id.first?.isLetter == true || id.first?.isNumber == true { return id }
        }
        throw BackendRemoteTrustFailure.storage("Could not mint a device id")
    }
    private func cleanName(_ name: String) -> String? {
        let source = String(name.prefix(512))
        let text = String(String.UnicodeScalarView(source.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = String(text.prefix(64)); return cleaned.isEmpty ? nil : cleaned
    }
    private func rosterWithRoom() -> [StoredDevice] {
        var next = devices
        if next.count >= 64, let index = next.enumerated().filter({ $0.element.revoked }).min(by: { $0.element.addedAt < $1.element.addedAt })?.offset { next.remove(at: index) }
        return next
    }
    private func addressKey(_ address: String) -> String { "addr:" + String(address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(64)) }
    private func blocked(_ keys: [String], now: Double) -> Double { keys.map { max(0, (attempts[$0]?.blockedUntil ?? 0) - now) }.max() ?? 0 }
    private func failed(_ keys: [String], now: Double) {
        for key in keys {
            var attempt = attempts[key] ?? Attempt()
            if now >= attempt.blockedUntil && (attempt.blockedUntil != 0 || now - attempt.updatedAt > 900000) { attempt.failures = 0; attempt.blockedUntil = 0 }
            attempt.failures += 1; attempt.updatedAt = now
            if attempt.failures >= 5 { attempt.blockedUntil = now + 900000 }
            attempts[key] = attempt
        }
        attempts = attempts.filter { now - $0.value.updatedAt <= 900000 || $0.value.blockedUntil > now }
        if attempts.count > 1024 { for key in attempts.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }).prefix(attempts.count - 1024).map(\.key) { attempts[key] = nil } }
    }
    private func clearFailures(_ keys: [String]) { for key in keys { attempts[key] = nil } }
    private func commit(_ next: [StoredDevice]) throws { try persist(next); devices = next; onChanged?() }
    private func persist(_ rows: [StoredDevice]) throws { try BackendRemoteTrustStorage.write(.object([.init("version", .number(1)), .init("devices", .array(rows.map(\.value)))]), file: directory.appendingPathComponent("remote-auth.json")) }
    private func loadDevices() throws {
        let file = directory.appendingPathComponent("remote-auth.json")
        let raw: NativeRPCValue?
        do { raw = try BackendRemoteTrustStorage.read(file, maximumBytes: 262144) }
        catch { try BackendRemoteTrustStorage.quarantine(file); devices = []; return }
        guard let raw else { devices = []; return }
        guard let rows = raw["devices"].elements else { try BackendRemoteTrustStorage.quarantine(file); devices = []; return }
        var found: [StoredDevice] = []
        for value in rows.prefix(64) {
            guard let id = value["id"].string, id.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
                  let name = value["name"].string.flatMap(cleanName), let addedAt = value["addedAt"].number,
                  let credential = decodeCredential(value["credential"]) else { continue }
            if let index = found.firstIndex(where: { $0.id == id }) { found[index].approved = false; found[index].revoked = true; continue }
            let key = value["publicKey"].string.flatMap { $0.utf16.count <= 256 ? $0 : nil }
            found.append(StoredDevice(id: id, name: name, addedAt: addedAt, lastSeenAt: value["lastSeenAt"].number,
                approved: value["approved"].bool == true, revoked: value["revoked"].bool != false, credential: credential, publicKey: key))
        }
        var byKey: [Data: StoredDevice] = [:]
        for row in found where !row.revoked {
            guard let key = row.key else { continue }
            if let previous = byKey[key] {
                if row.approved && !previous.approved || row.approved == previous.approved && (row.lastSeenAt ?? row.addedAt) > (previous.lastSeenAt ?? previous.addedAt) { byKey[key] = row }
            } else { byKey[key] = row }
        }
        devices = found.filter { $0.revoked || $0.key == nil || byKey[$0.key!]?.id == $0.id }
        if devices.count != found.count { try persist(devices) }
    }
    private func decodeCredential(_ value: NativeRPCValue) -> Credential? {
        guard let salt = value["salt"].string, let hash = value["hash"].string, salt.utf16.count <= 256, hash.utf16.count <= 256,
              let n = integer(value["n"], 2, 262144), n & (n - 1) == 0,
              let r = integer(value["r"], 1, 32), let p = integer(value["p"], 1, 16), let length = integer(value["keylen"], 16, 128) else { return nil }
        return Credential(n: n, r: r, p: p, keylen: length, salt: salt, hash: hash)
    }
    private func integer(_ value: NativeRPCValue, _ min: Int, _ max: Int) -> Int? { guard let n = value.number, n.rounded() == n, n >= Double(min), n <= Double(max) else { return nil }; return Int(n) }
}
