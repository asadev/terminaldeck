import Foundation
import TerminalDeckNativeCore

public struct BackendMachineRecord: Sendable, Equatable {
    public let id: String
    public let name: String
    public let hostID: String
    public let fingerprint: String
    public let platform: String
    public let pairedAt: Double
    public let lastConnectedAt: Double?
    public let drivesWindows: Bool
    public var value: NativeRPCValue { .object([.init("id", .string(id)), .init("name", .string(name)), .init("hostId", .string(hostID)),
        .init("fingerprint", .string(fingerprint)), .init("platform", .string(platform)), .init("pairedAt", .number(pairedAt)),
        .init("lastConnectedAt", lastConnectedAt.map(NativeRPCValue.number) ?? .null), .init("drivesWindows", .bool(drivesWindows))]) }
}
public struct BackendMachineSecrets: Sendable {
    public let hostID: String
    public let hostPublicKey: Data
    public let relayURL: String
    public let credential: String
    public let guestIdentity: BackendSealedIdentity
    public init(hostID: String, hostPublicKey: Data, relayURL: String, credential: String, guestIdentity: BackendSealedIdentity) {
        self.hostID = hostID; self.hostPublicKey = hostPublicKey; self.relayURL = relayURL; self.credential = credential; self.guestIdentity = guestIdentity
    }
}

/// Same durable records and downgrade-resistant off-switch as MachineStore.
/// open is explicit; construction cannot read credentials or start dialing.
public actor BackendMachineStore {
    public nonisolated let directory: URL
    private let clock: @Sendable () -> Double
    private var rows: [NativeRPCValue] = []
    private var denies: Set<String> = []
    private var opened = false
    private var lease: BackendRemoteTrustLease?
    /// Each machine's credential and guest private key (#439); machines.json keeps only public facts.
    private let secretStore: any BackendConnectedTasksSecrets
    public init(directory: URL, secrets: any BackendConnectedTasksSecrets = BackendConnectedTasksMemorySecrets(),
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) { self.directory = directory; self.secretStore = secrets; self.clock = clock }
    public func open() throws {
        guard !opened else { return }
        // Machine records hold independent guest private keys, so permission
        // protection/atomic writes are the same as remote trust secrets.
        let lockDirectory = directory.appendingPathComponent("native-machine-owner", isDirectory: true)
        lease = try BackendRemoteTrustLease(directory: lockDirectory)
        let file = directory.appendingPathComponent("machines.json")
        let raw: NativeRPCValue?
        do { raw = try BackendRemoteTrustStorage.read(file, maximumBytes: 262144) }
        catch { try BackendRemoteTrustStorage.quarantine(file); raw = nil }
        if let raw, raw["machines"].elements == nil { try BackendRemoteTrustStorage.quarantine(file) }
        let sidecar = (try? BackendRemoteTrustStorage.read(directory.appendingPathComponent("machine-window-denies.json"), maximumBytes: 65536)) ?? .object([])
        denies = Set((sidecar["denied"].elements?.compactMap(\.string) ?? []).filter { !$0.isEmpty && $0.utf16.count <= 200 }.prefix(64))
        var seen: Set<String> = []
        rows = []
        for row in (raw?["machines"].elements ?? []).prefix(64) {
            guard let decoded = decode(row), let id = decoded["id"].string, seen.insert(id).inserted else { continue }
            rows.append(denies.contains(id) ? decoded.setting("drivesWindows", .bool(false)) : decoded)
        }
        // #439: a credential and private key still written in the file move to the secret
        // store, and the file keeps only public facts. One that cannot be moved stays.
        var moved = false
        rows = rows.map { row in
            guard let id = row["id"].string, let credential = row["credential"].string, let privateKey = key(row["guestPrivateKey"]),
                  (try? writeSecrets(id, credential: credential, privateKey: privateKey)) != nil else { return row }
            moved = true; return row.removing("credential").removing("guestPrivateKey")
        }
        opened = true
        if moved { try? commit(rows) }
    }
    public func close() { opened = false; rows = []; denies = []; lease = nil }
    public func list() throws -> [BackendMachineRecord] {
        try requireOpen()
        return rows.compactMap(publicRecord).sorted { $0.pairedAt > $1.pairedAt }
    }
    public func secrets(_ id: String) throws -> BackendMachineSecrets {
        try requireOpen()
        guard let row = rows.first(where: { $0["id"].string == id }), let hostID = row["hostId"].string,
              let hostKey = key(row["hostPublicKey"]), let publicKey = key(row["guestPublicKey"]),
              let relay = row["relayUrl"].string, let dial = try dialSecrets(row, id: id) else { throw NativeRPCError(code: "unknown-machine", message: "That machine is not paired") }
        let (credential, privateKey) = dial, identity = try BackendSealedIdentity(privateKey: privateKey)
        guard BackendRemoteTrustStorage.equal(identity.publicKey, publicKey) else { throw NativeRPCError(code: "machine-key", message: "That machine's stored guest keys do not match") }
        return .init(hostID: hostID, hostPublicKey: hostKey, relayURL: relay, credential: credential, guestIdentity: identity)
    }
    public func remember(name: String, secrets: BackendMachineSecrets, platform: String) throws -> BackendMachineRecord {
        try requireOpen()
        guard BackendRelayPacketCodec.isHostID(secrets.hostID) else { throw NativeRPCError.invalidArguments("that is not a host id") }  // store.ts:375
        guard secrets.hostPublicKey.count == 32 else { throw NativeRPCError.invalidArguments("that is not an x25519 key") }  // store.ts:376
        guard !secrets.credential.isEmpty,
              secrets.credential.utf16.count <= 256 else { throw NativeRPCError.invalidArguments("The pairing result has an invalid identity or credential") }
        _ = try BackendRemoteRelayClient.target(secrets.relayURL)
        let row = NativeRPCValue.object([.init("id", .string(secrets.hostID)), .init("name", .string(cleanName(name) ?? "Another machine")),
            .init("hostId", .string(secrets.hostID)), .init("hostPublicKey", .string(secrets.hostPublicKey.base64EncodedString())),
            .init("relayUrl", .string(secrets.relayURL)), .init("guestPublicKey", .string(secrets.guestIdentity.publicKey.base64EncodedString())),
            .init("platform", .string(String(platform.prefix(32)))), .init("pairedAt", .number(clock())), .init("lastConnectedAt", .null), .init("drivesWindows", .bool(true))])
        var next = rows.filter { $0["id"].string != secrets.hostID }
        guard next.count < 64 else { throw NativeRPCError(code: "machine-capacity", message: "There is no room for another paired machine") }
        next.append(row)
        var nextDenies = denies; nextDenies.remove(secrets.hostID)
        // The credential and private key go to the secret store, never the file (#439).
        let secretID = Self.secretID(secrets.hostID), previous = try? secretStore.read(secretID)
        try writeSecrets(secrets.hostID, credential: secrets.credential, privateKey: secrets.guestIdentity.privateKey)
        do { try persistDenies(nextDenies); try commit(next) } catch {
            if let previous { try? secretStore.write(secretID, token: previous) } else { try? secretStore.remove(secretID) }
            throw error
        }
        denies = nextDenies
        return publicRecord(row)!
    }
    @discardableResult public func forget(_ id: String) throws -> Bool {
        try requireOpen()
        let next = rows.filter { $0["id"].string != id }
        guard next.count != rows.count else { return false }
        try commit(next); try? secretStore.remove(Self.secretID(id))
        var nextDenies = denies; nextDenies.remove(id); try persistDenies(nextDenies); denies = nextDenies; return true
    }
    @discardableResult public func rename(_ id: String, name: String) throws -> Bool {
        try requireOpen(); guard let name = cleanName(name), let index = rows.firstIndex(where: { $0["id"].string == id }) else { return false }
        var next = rows; next[index] = next[index].setting("name", .string(name)); try commit(next); return true
    }
    public func drivesWindows(_ id: String) throws -> Bool { try requireOpen(); guard let row = rows.first(where: { $0["id"].string == id }) else { return false }; return !denies.contains(id) && row["drivesWindows"].bool != false }
    @discardableResult public func setDrivesWindows(_ id: String, allowed: Bool) throws -> Bool {
        try requireOpen(); guard let index = rows.firstIndex(where: { $0["id"].string == id }) else { return false }
        var nextDenies = denies; if allowed { nextDenies.remove(id) } else { nextDenies.insert(id) }
        try persistDenies(nextDenies); denies = nextDenies
        var next = rows; next[index] = next[index].setting("drivesWindows", .bool(allowed)); try commit(next); return allowed
    }
    public func sawWelcome(_ id: String, platform: String) throws {
        try requireOpen(); guard let index = rows.firstIndex(where: { $0["id"].string == id }) else { return }
        var next = rows; next[index] = next[index].setting("lastConnectedAt", .number(clock()))
        if !platform.isEmpty { next[index] = next[index].setting("platform", .string(String(platform.prefix(32)))) }
        try commit(next)
    }
    private func commit(_ next: [NativeRPCValue]) throws { try BackendRemoteTrustStorage.write(.object([.init("version", .number(1)), .init("machines", .array(next))]), file: directory.appendingPathComponent("machines.json")); rows = next }
    private func persistDenies(_ next: Set<String>) throws { try BackendRemoteTrustStorage.write(.object([.init("version", .number(1)), .init("denied", .array(next.sorted().map(NativeRPCValue.string)))]), file: directory.appendingPathComponent("machine-window-denies.json")) }
    static func secretID(_ id: String) -> String { "machine-" + id }
    private func writeSecrets(_ id: String, credential: String, privateKey: Data) throws {
        let value = NativeRPCValue.object([.init("credential", .string(credential)), .init("guestPrivateKey", .string(privateKey.base64EncodedString()))])
        try secretStore.write(Self.secretID(id), token: String(decoding: try value.encodedJSON(), as: UTF8.self))
    }
    /// The dial secrets: from the row while an older file still holds them, else from the secret store.
    private func dialSecrets(_ row: NativeRPCValue, id: String) throws -> (String, Data)? {
        if let credential = row["credential"].string, let privateKey = key(row["guestPrivateKey"]) { return (credential, privateKey) }
        guard let text = try secretStore.read(Self.secretID(id)), let stored = try? NativeRPCValue.parseJSON(Data(text.utf8)),
              let credential = stored["credential"].string, !credential.isEmpty, credential.utf16.count <= 256, let privateKey = key(stored["guestPrivateKey"]) else { return nil }
        return (credential, privateKey)
    }
    private func key(_ value: NativeRPCValue) -> Data? { value.string.flatMap { $0.utf16.count <= 256 ? BackendRemoteTrustStorage.base64($0) : nil }.flatMap { $0.count == 32 ? $0 : nil } }
    private func cleanName(_ value: String) -> String? { let name = BackendRemoteProtocol.displayLabel(String(value.prefix(512)), maximumUnits: 64); return name.isEmpty ? nil : name }
    private func decode(_ row: NativeRPCValue) -> NativeRPCValue? {
        guard let id = row["id"].string, !id.isEmpty, let name = row["name"].string.flatMap(cleanName),
              let hostID = row["hostId"].string, BackendRelayPacketCodec.isHostID(hostID), key(row["hostPublicKey"]) != nil,
              key(row["guestPublicKey"]) != nil, let relay = row["relayUrl"].string, !relay.isEmpty, row["pairedAt"].number != nil else { return nil }
        if row.has("credential") || row.has("guestPrivateKey") {
            guard key(row["guestPrivateKey"]) != nil, let credential = row["credential"].string, !credential.isEmpty, credential.utf16.count <= 256 else { return nil }
        } else {
            // Kept in the secret store: a row whose secrets are surely gone is dropped; one the
            // store cannot read just now (a locked Keychain) is kept and asked again when it dials.
            do { guard try dialSecrets(row, id: id) != nil else { return nil } } catch {}
        }
        return row.setting("name", .string(name)).setting("platform", .string(String((row["platform"].string ?? "").prefix(32))))
            .setting("lastConnectedAt", row["lastConnectedAt"].number.map(NativeRPCValue.number) ?? .null).setting("drivesWindows", .bool(row["drivesWindows"].bool != false))
    }
    private func publicRecord(_ row: NativeRPCValue) -> BackendMachineRecord? {
        guard let id = row["id"].string, let name = row["name"].string, let hostID = row["hostId"].string, let key = key(row["hostPublicKey"]), let at = row["pairedAt"].number else { return nil }
        return .init(id: id, name: name, hostID: hostID, fingerprint: sealedFingerprint(key), platform: row["platform"].string ?? "", pairedAt: at,
            lastConnectedAt: row["lastConnectedAt"].number, drivesWindows: !denies.contains(id) && row["drivesWindows"].bool != false)
    }
    private func requireOpen() throws { guard opened else { throw NativeRPCError(code: "machine-store-closed", message: "Open the native machine store before using saved pairings") } }
}
