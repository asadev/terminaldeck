import Foundation
import Security
import TerminalDeckNativeCore

/// What the protected store says about one local key. Only `missing` (the
/// item does not exist) may start the keychain-loss path. A key that exists
/// but cannot be read right now (locked keychain, permission prompt denied or
/// refused, device locked, any other status) is `blocked`: stop, change nothing.
public enum BackendCloudRecoveryKeyState: Equatable, Sendable {
    case present, missing, blocked(String)
    /// Keychain mapping. errSecItemNotFound is the only "does not exist".
    public static func keychain(status: OSStatus, data: Data?) -> Self {
        switch status {
        case errSecSuccess: return data?.isEmpty == false ? .present : .blocked("The login store key is empty.")
        case errSecItemNotFound: return .missing
        default: return .blocked("macOS did not let the app open its login store right now (Keychain status \(status)).")
        }
    }
    /// File mapping for the dev copy: only "no such file" is missing.
    public static func file(_ read: () throws -> Data?) -> Self {
        do {
            guard let data = try read() else { return .missing }
            return data.isEmpty ? .blocked("The dev copy's store key file is empty.") : .present
        } catch { return .blocked("The dev copy's store key file could not be read.") }
    }
}
/// Refusal that changes nothing: the person is asked to allow the login store.
public struct BackendCloudRecoveryBlocked: Error, LocalizedError, Equatable {
    public let reason: String
    public var errorDescription: String? {
        reason + " Your saved passwords on this Mac were not changed. " + BackendAccountVaultRecovery.permissionStep
    }
}

/// The login-store key is gone from this Mac and stores sealed with it cannot be opened. In the lean first
/// version nothing is switched to a new store; this refusal changes nothing and says so.
public struct BackendCloudRecoveryKeyLost: Error, LocalizedError, Equatable {
    /// The owners whose saved values cannot be opened ("server", "voice", "browser", "receiver").
    public let owners: [String]
    public var errorDescription: String? { BackendCloudRecoveryLocalStanding.keyLost(owners).words(cloudKeyHere: true) }
}
/// 13 Nov: saved sign-ins the earlier app sealed with its own key, not yet moved to this app's key. The earlier key
/// is on this Mac, so nothing is lost and nothing may be recovered, reset or replaced; the Servers page converts.
public struct BackendCloudRecoveryNotConverted: Error, LocalizedError, Equatable {
    public let owners: [String]
    public var errorDescription: String? { BackendCloudRecoveryLocalStanding.notConverted(owners).words(cloudKeyHere: true) }
}
/// This Mac's own saved passwords could not be checked (a file that cannot be read, or is too large). Nothing was
/// sent and nothing changed; it is never taken for "ready" (review A-M2).
public struct BackendCloudRecoveryCannotCheck: Error, LocalizedError, Equatable {
    public let owners: [String]
    public var errorDescription: String? { BackendCloudRecoveryLocalStanding.cannotCheck(owners).words(cloudKeyHere: true) }
}
/// What this Mac's own stores can truthfully say before Cloud's saved passwords are kept in them.
public enum BackendCloudRecoveryLocalStanding: Equatable, Sendable {
    /// Every store handed to the migration opens with a key this Mac has (or has no saved values yet).
    case ready
    /// A key exists but macOS does not let the app read it right now. "Allow login store" applies; nothing changed.
    case blocked(String)
    /// The key that opens these stores is gone from this Mac (the 7 Nov case). "Allow login store" cannot bring
    /// it back, so that button is not offered for this state.
    case keyLost([String])
    /// A store's file could not be read or is too large, so whether it opens is unknown. Never "ready": nothing joins,
    /// nothing is captured or marked as saved, and the page offers "Check again" (review A-M2).
    case cannotCheck([String])
    /// 13 Nov: a store the earlier app sealed with its own key, which is still on this Mac, is not converted yet.
    /// Never "key is gone", never "Allow login store", and no recover, reset or replace: converting is the only step.
    case notConverted([String])
    /// Only a key that exists but is blocked can be helped by "Allow login store".
    public var offersAllowLoginStore: Bool { if case .blocked = self { return true }; return false }
    /// The one truthful sentence for the Cloud page; nil when there is nothing to say. `cloudKeyHere`: this Mac
    /// holds the Cloud key for saved passwords (unlocking again would change nothing for this state).
    /// `cloudSetUp`: false when the account has no saved passwords in Cloud yet; then nothing is promised from
    /// Cloud and no recovery words or other device are offered (review S-A1).
    public func words(cloudKeyHere: Bool, cloudSetUp: Bool = true) -> String? {
        switch self {
        case .ready: return nil
        case .blocked(let reason): return BackendCloudRecoveryBlocked(reason: reason).errorDescription
        case .keyLost:
            let start = "Saved passwords are locked on this Mac: the key that opens this Mac's own saved passwords is gone."
            guard cloudSetUp else {
                return start + " Nothing on this Mac was changed or deleted. Saved passwords are not set up in Cloud yet, so there is nothing to bring back from there."
            }
            let kept = " Nothing on this Mac was changed or deleted. What you saved in Cloud is safe there and on your other devices."
            let next = cloudKeyHere
                ? " This version cannot bring them back onto this Mac yet."
                : " You can still unlock with your recovery words or from another device, but this version cannot bring them back onto this Mac yet."
            return start + kept + next
        case .notConverted:
            return BackendServersEarlierStanding.notConvertedSentence
                + " Nothing on this Mac was changed. Open Machines, then Servers, and choose Convert saved sign-ins."
        case .cannotCheck:
            return "Can't check this Mac's saved passwords right now: a saved-password file on this Mac could not be read."
                + " Nothing was sent to Cloud and nothing on this Mac was changed. Choose Check again."
        }
    }
}

/// Key bytes stay behind the existing local encryption owner. Tests inject a
/// memory-only owner; production uses AccountVaultRecovery's Keychain adapter.
public struct BackendCloudRecoveryLocalKeyOwner: Sendable {
    public let originalKey: @Sendable () -> BackendCloudRecoveryKeyState
    public let generationKey: @Sendable (String) -> BackendCloudRecoveryKeyState
    public let create: @Sendable (String) throws -> Void
    public let cipher: @Sendable (String) throws -> any BackendAccountVaultCipher
    public init(originalKey: @escaping @Sendable () -> BackendCloudRecoveryKeyState,
                generationKey: @escaping @Sendable (String) -> BackendCloudRecoveryKeyState,
                create: @escaping @Sendable (String) throws -> Void,
                cipher: @escaping @Sendable (String) throws -> any BackendAccountVaultCipher) {
        self.originalKey = originalKey; self.generationKey = generationKey; self.create = create; self.cipher = cipher
    }
}

/// Durable, non-secret routing information. Never renames, truncates, copies or
/// deletes the old encrypted stores. Each reset gets a separate local key and
/// separate files. A lost key therefore cannot turn a failed read into a save.
public actor BackendCloudRecoveryLocalStores {
    private struct Route: Codable {
        let version: Int
        let generation: String
        let owners: [String]
    }
    private let configuration: BackendAccountConfiguration
    private let keys: BackendCloudRecoveryLocalKeyOwner
    private let policy: CloudSecretsPolicy
    // Every owner is optional: only an owner handed in is ever probed, moved or named in a route. The hosted app
    // hands in no account vault (the session host helper is that vault's one writer; a second vault object in the
    // app would take the writer lease on the same file), so nothing here can read, adopt or rewrite it.
    private let vault: BackendAccountVault?
    private let passwords: BackendBrowserPasswords?
    private let servers: BackendServersCredentials?
    private let voice: BackendOSVoiceService?
    private let receiver: BackendRCVStore?
    private let requireReceiverInert: @Sendable () async throws -> Void
    private let requireWriter: @Sendable () throws -> Void
    /// false (the lean first version): a lost key never switches any owner to a new store. The unlock then only
    /// checks that this Mac's stores open, and refuses with the truth when they do not.
    private let adoptsLostKeyStores: Bool
    private var busy = false
    public init(configuration: BackendAccountConfiguration, keys: BackendCloudRecoveryLocalKeyOwner, policy: CloudSecretsPolicy,
                vault: BackendAccountVault?, passwords: BackendBrowserPasswords?, servers: BackendServersCredentials?, voice: BackendOSVoiceService?,
                receiver: BackendRCVStore?, requireReceiverInert: @escaping @Sendable () async throws -> Void,
                requireWriter: @escaping @Sendable () throws -> Void, adoptsLostKeyStores: Bool = true) {
        self.configuration = configuration; self.keys = keys; self.policy = policy; self.vault = vault
        self.passwords = passwords; self.servers = servers; self.voice = voice; self.receiver = receiver; self.requireReceiverInert = requireReceiverInert; self.requireWriter = requireWriter
        self.adoptsLostKeyStores = adoptsLostKeyStores
    }
    /// Read-only: asks the key owner for the key's state and tries to open each handed store with the key it has
    /// now. Creates nothing, switches nothing, never prompts. At app start call `resume()` first.
    public func standing() async -> BackendCloudRecoveryLocalStanding {
        let original = keys.originalKey()
        if case .blocked(let reason) = original { return .blocked(reason) }
        if let route = try? readRoute(), case .blocked(let reason) = keys.generationKey(route.generation) { return .blocked(reason) }
        // A probe that throws (unreadable file, over its size limit) is "can't check", never "ready" (review A-M2).
        var locked: [String] = [], unreadable: [String] = [], unconverted: [String] = []
        // 13 Nov: sign-ins the earlier app sealed with its own key are converted here when macOS need not ask; when
        // they still wait, they are "not converted", never "key is gone".
        if let servers {
            if servers.earlierAppStanding().pending { unconverted.append("server") }
            else { do { if try servers.cloudNeedsRecovery() { locked.append("server") } } catch { unreadable.append("server") } }
        }
        if let voice { do { if try await voice.cloudNeedsRecovery() { locked.append("voice") } } catch { unreadable.append("voice") } }
        if let passwords { do { if try await passwords.cloudNeedsRecovery() { locked.append("browser") } } catch { unreadable.append("browser") } }
        if let receiver { do { if try await receiver.cloudNeedsRecovery() { locked.append("receiver") } } catch { unreadable.append("receiver") } }
        // The shared login-store key is missing but a file it sealed is still on this Mac (for example the session
        // host's account vault, which this check never opens): the key is lost, not new. Cloud must never be the
        // first writer that makes a replacement key beside those files (review S-A2). Existence only; nothing is read.
        if original == .missing {
            for (owner, file) in sealedFiles where !locked.contains(owner) && !unconverted.contains(owner) && FileManager.default.fileExists(atPath: file.path) { locked.append(owner) }
        }
        if !locked.isEmpty { return .keyLost(locked.sorted()) }
        if !unconverted.isEmpty { return .notConverted(unconverted) }
        return unreadable.isEmpty ? .ready : .cannotCheck(unreadable.sorted())
    }
    /// Files sealed with the shared login-store key, by owner, whether or not that owner was handed in.
    private var sealedFiles: [(String, URL)] {
        let data = configuration.dataDirectory
        return [("account", data.appendingPathComponent(BackendAccountVault.directoryName, isDirectory: true).appendingPathComponent(BackendAccountVault.fileName)),
                ("browser", data.appendingPathComponent("browser-logins.bin")),
                // The Servers owner keeps its file in its own `servers` folder (13 Nov: the check looked one level up).
                ("server", servers?.file ?? data.appendingPathComponent("servers", isDirectory: true).appendingPathComponent(BackendServersCredentials.fileName)),
                ("voice", data.appendingPathComponent("voice-key.bin"))]
    }
    private var root: URL { configuration.dataDirectory.appendingPathComponent("cloud-local-stores", isDirectory: true) }
    private var manifest: URL { root.appendingPathComponent("current.json") }
    /// Called on startup before secret readers and after verified words/approval,
    /// before the logical download. It never reads the roster or subscription slots.
    public func resume() async throws {
        guard !busy else { throw CloudFailure.unavailable }
        busy = true; defer { busy = false }
        try requireWriter()
        // Lean first version: no owner is ever switched to another store file, not even by a leftover route (S-A3).
        guard adoptsLostKeyStores else { return }
        guard let route = try readRoute() else { return }
        try await activate(route)
    }
    public func recoverAfterVerifiedCloudUnlock() async throws {
        guard !busy else { throw CloudFailure.unavailable }
        busy = true; defer { busy = false }
        try requireWriter()
        try await policy.require(.secret, stage: .importRecords)
        guard adoptsLostKeyStores else {
            // Lean first version: no new key, no route, no owner switch. Either this Mac's stores open, or the
            // unlock stops here with the truth and the sources are not synchronised on this Mac.
            switch await standing() {
            case .ready: return
            case .blocked(let reason): throw BackendCloudRecoveryBlocked(reason: reason)
            case .keyLost(let owners): throw BackendCloudRecoveryKeyLost(owners: owners)
            case .cannotCheck(let owners): throw BackendCloudRecoveryCannotCheck(owners: owners)
            case .notConverted(let owners): throw BackendCloudRecoveryNotConverted(owners: owners)
            }
        }
        // A blocked (not lost) original key is the 7 Nov failure in reverse:
        // switching owners to fresh empty stores would strand every saved value.
        // Decide before reading any owner, so a blocked key changes nothing.
        let original = keys.originalKey()
        if case .blocked(let reason) = original { throw BackendCloudRecoveryBlocked(reason: reason) }
        if let old = try readRoute() {
            // An accessible generation is reused. A missing key gets a new
            // generation beside it; a blocked one stops here, changing nothing.
            switch keys.generationKey(old.generation) {
            case .blocked(let reason): throw BackendCloudRecoveryBlocked(reason: reason)
            case .missing: break
            case .present:
                try await activate(old)
                let newlyLocked = try await neededOwners(original: original)
                let owners = Array(Set(old.owners + newlyLocked)).sorted()
                if owners != old.owners.sorted() {
                    let expanded = Route(version: 1, generation: old.generation, owners: owners)
                    try BackendAccountVaultMigration.saveCloudRoute(JSONEncoder().encode(expanded), to: manifest)
                    try await activate(expanded)
                }
                return
            }
        }
        var owners = try await neededOwners(original: original)
        if let previous = try readRoute() { owners = Array(Set(owners + previous.owners.filter { handed.contains($0) })).sorted() }
        guard !owners.isEmpty else { return }
        let generation = UUID().uuidString.lowercased()
        try keys.create(generation)
        let cipher = try keys.cipher(generation)
        try cipher.prepareForWrites(existingVault: true)
        let probe = "TD-CLOUD-LOCAL-KEY-1"
        guard try cipher.decrypt(cipher.encrypt(probe, existingVault: true)) == probe else { throw CloudFailure.checksumMismatch }
        let route = Route(version: 1, generation: generation, owners: owners)
        let directory = root.appendingPathComponent(generation, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Migration API owns the atomic pointer. Read it back before changing
        // any live owner, so a crash can resume exactly this generation.
        try BackendAccountVaultMigration.saveCloudRoute(JSONEncoder().encode(route), to: manifest)
        guard try readRoute()?.generation == generation else { throw CloudFailure.checksumMismatch }
        try await activate(route)
    }
    private func neededOwners(original: BackendCloudRecoveryKeyState) async throws -> [String] {
        // Missing local files still need a usable local encryption owner before
        // the first cloud record can be materialized. Probe only the store key,
        // never any subscription slot or encrypted account-vault contents.
        // Only a key that is truly missing counts; `blocked` never reaches here.
        var owners: [String] = original == .present ? [] : handed.filter { $0 != "account" }
        if let vault, (try? await policy.require(.aiSubscription, stage: .capture)) != nil {
            if await vault.cloudNeedsRecovery() { owners.append("account") }
        }
        if let passwords, try await passwords.cloudNeedsRecovery() { owners.append("browser") }
        // An unconverted earlier-app store is never switched to a new one: its key is here (13 Nov).
        if let servers, servers.earlierAppStanding().pending { throw BackendCloudRecoveryNotConverted(owners: ["server"]) }
        if let servers, try servers.cloudNeedsRecovery() { owners.append("server") }
        if let voice, try await voice.cloudNeedsRecovery() { owners.append("voice") }
        if let receiver, try await receiver.cloudNeedsRecovery() { owners.append("receiver") }
        return Array(Set(owners)).sorted()
    }
    /// Owners handed to this migration. Nothing else is ever probed, moved or kept in a new route.
    private var handed: [String] {
        var owners: [String] = []
        if vault != nil { owners.append("account") }
        if passwords != nil { owners.append("browser") }
        if servers != nil { owners.append("server") }
        if voice != nil { owners.append("voice") }
        if receiver != nil { owners.append("receiver") }
        return owners
    }
    private func readRoute() throws -> Route? {
        guard let bytes = try BackendAccountFiles.boundedRead(manifest, maximum: 4096) else { return nil }
        let route = try JSONDecoder().decode(Route.self, from: bytes)
        guard route.version == 1, UUID(uuidString: route.generation)?.uuidString.lowercased() == route.generation,
              Set(route.owners).isSubset(of: ["account", "browser", "server", "voice", "receiver"]), Set(route.owners).count == route.owners.count else { throw CloudFailure.invalidRequest }
        return route
    }
    private func activate(_ route: Route) async throws {
        let cipher = try keys.cipher(route.generation)
        try cipher.prepareForWrites(existingVault: true)
        if route.owners.contains("receiver"), receiver != nil { try await requireReceiverInert() }
        let directory = root.appendingPathComponent(route.generation, isDirectory: true)
        let browser = BackendBrowserPasswordsCipher(available: { cipher.available() },
            decrypt: { try cipher.decrypt($0) }, encrypt: { try cipher.encrypt($0, existingVault: $1) })
        if route.owners.contains("account"), let vault, (try? await policy.require(.aiSubscription, stage: .importRecords)) != nil {
            try await vault.cloudAdopt(file: directory.appendingPathComponent("account-vault.bin"), cipher: cipher)
        }
        if route.owners.contains("browser"), let passwords { try await passwords.cloudAdopt(file: directory.appendingPathComponent("browser-logins.bin"), cipher: browser) }
        if route.owners.contains("server"), let servers { try servers.cloudAdopt(file: directory.appendingPathComponent("server-credentials.bin"), cipher: browser) }
        if route.owners.contains("voice"), let voice { try await voice.cloudAdopt(file: directory.appendingPathComponent("voice-key.bin"), cipher: BackendCloudRecoveryVoiceCipher(cipher: cipher)) }
        if route.owners.contains("receiver"), let receiver {
            try await receiver.cloudAdopt(persistence: BackendTaskPersistence(directory: directory, ownership: .exclusive), cipher: cipher)
        }
    }
}

private struct BackendCloudRecoveryVoiceCipher: BackendOSVoiceEncrypting {
    let cipher: any BackendAccountVaultCipher
    func prepareForWrites(existingVault: Bool) throws { try cipher.prepareForWrites(existingVault: existingVault) }
    func decrypt(_ blob: Data) throws -> String { try cipher.decrypt(blob) }
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { try cipher.encrypt(text, existingVault: existingVault) }
}
