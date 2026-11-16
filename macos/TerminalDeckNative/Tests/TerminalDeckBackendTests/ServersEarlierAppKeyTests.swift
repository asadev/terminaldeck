import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// 13 Nov, the owner's MacBook: `servers/server-credentials.bin` was sealed by the earlier (Electron) app with its
/// own Safe Storage key and never moved to the Mac app's key. Fixtures are sealed the way that app sealed them
/// (Chromium safe-storage blob of `{"version":1,"entries":[…]}`, base64 on disk) with throwaway in-memory keys;
/// no Keychain item is read, created or changed.
@Suite("Servers: sign-ins from the earlier app")
struct ServersEarlierAppKeyTests {
    static let oldKey = Data("fixture-earlier-app-key-0001".utf8)
    static let newKey = Data("fixture-this-app-key-0002".utf8)
    static let secret = "fixture-server-password-XYZ"

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    private func folder() -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("servers-earlier-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }
    private static func cipher(_ key: Data) -> BackendBrowserPasswordsCipher {
        .init(available: { true }, decrypt: { try ChromiumSafeStorageCipher.decrypt($0, password: key) },
              encrypt: { text, _ in try ChromiumSafeStorageCipher.encrypt(text, password: key) })
    }
    /// What the earlier app wrote: safeStorage.encryptString(JSON) as base64.
    @discardableResult
    private func writeEarlierFile(in servers: URL, key: Data = Self.oldKey) throws -> Data {
        let json = "{\"version\":1,\"entries\":[{\"serverId\":\"box-1\",\"kind\":\"password\",\"password\":\"\(Self.secret)\"}]}"
        let bytes = Data(try ChromiumSafeStorageCipher.encrypt(json, password: key).base64EncodedString().utf8)
        try FileManager.default.createDirectory(at: servers, withIntermediateDirectories: true)
        try bytes.write(to: servers.appendingPathComponent(BackendServersCredentials.fileName))
        return bytes
    }
    private func earlier(_ lookup: BackendServersEarlierAppKey.Lookup, asked: Counter = Counter(), permitted: Data? = Self.oldKey) -> BackendServersEarlierAppKey {
        .init(quiet: { lookup }, withPermission: {
            asked.add()
            guard let permitted else { throw NativeRPCError(code: "keychain", message: "Denied in the fixture.") }
            return permitted
        })
    }
    private func owner(_ servers: URL, _ key: BackendServersEarlierAppKey?, mayWrite: Bool = true) -> BackendServersCredentials {
        .init(dataRoot: servers, cipher: Self.cipher(Self.newKey), policy: .init(mayRead: true, mayWrite: mayWrite),
              keyValidator: .init { _, _ in nil }, earlierKey: key)
    }
    private func names(_ folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
    private func backups(_ folder: URL) -> [String] { names(folder).filter { $0.contains(BackendServersEarlierAppMigration.backupMarker) } }

    @Test func convertsOnceKeepsTheBackupAndASecondRunChangesNothing() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let servers = root.appendingPathComponent("servers")
        let original = try writeEarlierFile(in: servers)
        let asked = Counter()
        let store = owner(servers, earlier(.key(Self.oldKey), asked: asked))
        #expect(try store.read("box-1") == .password(Self.secret))
        #expect(asked.count == 0) // never asked macOS: the quiet read was enough
        let file = servers.appendingPathComponent(BackendServersCredentials.fileName)
        let converted = try Data(contentsOf: file)
        #expect(converted != original)
        let blob = try #require(Data(base64Encoded: String(decoding: converted, as: UTF8.self)))
        #expect(try ChromiumSafeStorageCipher.decrypt(blob, password: Self.newKey).contains("box-1"))
        #expect(!String(decoding: converted, as: UTF8.self).contains(Self.secret))
        let kept = backups(servers)
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: servers.appendingPathComponent(kept[0])) == original)
        #expect(!names(servers).contains { $0.contains(DamagedFile.marker) })
        // Second run (a fresh start of the app): nothing to do, nothing written.
        let again = owner(servers, earlier(.key(Self.oldKey)))
        #expect(again.earlierAppStanding() == .clear)
        #expect(try again.read("box-1") == .password(Self.secret))
        #expect(try Data(contentsOf: file) == converted)
        #expect(backups(servers) == kept)
        // Saving works on the converted store.
        #expect(try again.save("box-2", credential: .password("other")).ok)
        #expect(backups(servers) == kept)
    }

    @Test func aKeyMacOSMustAskForWaitsForThePressAndChangesNothingUntilThen() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let servers = root.appendingPathComponent("servers")
        let original = try writeEarlierFile(in: servers)
        let asked = Counter()
        let store = owner(servers, earlier(.needsPermission, asked: asked))
        #expect(try store.read("box-1") == nil)
        #expect(store.earlierAppStanding() == .needsOK)
        let wire = store.earlierAppStanding().wireValue
        #expect(wire["canConvert"].bool == true)
        #expect(wire["sentence"].string?.hasPrefix(BackendServersEarlierStanding.notConvertedSentence) == true)
        // A save while unconverted never overwrites the earlier file.
        let save = try store.save("box-9", credential: .password("new"))
        #expect(!save.ok && save.message.hasPrefix(BackendServersEarlierStanding.notConvertedSentence))
        #expect(try Data(contentsOf: servers.appendingPathComponent(BackendServersCredentials.fileName)) == original)
        #expect(backups(servers).isEmpty)
        #expect(!names(servers).contains { $0.contains(DamagedFile.marker) })
        #expect(asked.count == 0)
        // The person's press.
        #expect(try store.convertEarlierAppSignIns() == .converted)
        #expect(asked.count == 1)
        #expect(try store.read("box-1") == .password(Self.secret))
        #expect(try store.save("box-9", credential: .password("new")).ok)
        #expect(backups(servers).count == 1)
        #expect(store.earlierAppStanding() == .clear)
        #expect(try store.convertEarlierAppSignIns() == .clear)
        #expect(asked.count == 1)
    }

    @Test func aDeniedPressChangesNothing() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let servers = root.appendingPathComponent("servers")
        let original = try writeEarlierFile(in: servers)
        let store = owner(servers, earlier(.needsPermission, permitted: nil))
        #expect(throws: NativeRPCError.self) { try store.convertEarlierAppSignIns() }
        #expect(try Data(contentsOf: servers.appendingPathComponent(BackendServersCredentials.fileName)) == original)
        #expect(backups(servers).isEmpty)
        #expect(store.earlierAppStanding() == .needsOK)
    }

    @Test func aWrongOrMissingEarlierKeyLeavesTheFileUntouched() throws {
        for lookup in [BackendServersEarlierAppKey.Lookup.key(Data("not-the-right-key".utf8)), .missing] {
            let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
            let servers = root.appendingPathComponent("servers")
            let original = try writeEarlierFile(in: servers)
            let store = owner(servers, earlier(lookup))
            #expect(store.earlierAppStanding() == .keyGone)
            #expect(store.earlierAppStanding().sentence?.hasPrefix(BackendServersEarlierStanding.keyGoneSentence) == true)
            #expect(try store.read("box-1") == nil)
            #expect(try Data(contentsOf: servers.appendingPathComponent(BackendServersCredentials.fileName)) == original)
            #expect(backups(servers).isEmpty)
        }
    }

    @Test func aCopyThatMayNotWriteSaysNotConvertedAndChangesNothing() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let servers = root.appendingPathComponent("servers")
        let original = try writeEarlierFile(in: servers)
        let store = owner(servers, earlier(.key(Self.oldKey)), mayWrite: false)
        #expect(store.earlierAppStanding() == .notConverted)
        #expect(try Data(contentsOf: servers.appendingPathComponent(BackendServersCredentials.fileName)) == original)
        #expect(backups(servers).isEmpty)
    }

    @Test func nothingSecretReachesTheLogOrTheWords() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let servers = root.appendingPathComponent("servers")
        try writeEarlierFile(in: servers)
        let log = root.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        fflush(stderr)
        let saved = dup(STDERR_FILENO); dup2(handle.fileDescriptor, STDERR_FILENO)
        let store = owner(servers, earlier(.key(Self.oldKey)))
        let standing = store.earlierAppStanding()
        fflush(stderr); dup2(saved, STDERR_FILENO); close(saved); try handle.close()
        #expect(standing == .converted)
        let written = try String(contentsOf: log, encoding: .utf8)
        #expect(written.contains("converted"))
        for secret in [Self.secret, String(decoding: Self.oldKey, as: UTF8.self), String(decoding: Self.newKey, as: UTF8.self)] {
            #expect(!written.contains(secret))
            #expect(!backups(servers).joined().contains(secret))
            for state in [BackendServersEarlierStanding.clear, .converted, .needsOK, .notConverted, .keyGone] {
                #expect(!String(decoding: (try? state.wireValue.encodedJSON()) ?? Data(), as: UTF8.self).contains(secret))
            }
        }
    }

    // MARK: Settings → Cloud: the local check and its words

    private func configuration(_ root: URL) throws -> BackendAccountConfiguration {
        let data = root.appendingPathComponent("data", isDirectory: true), home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return try BackendAccountConfiguration(dataDirectory: data, homeDirectory: home, appName: "Terminal Deck Fixture",
            appID: "terminaldeck", helperExecutable: root.appendingPathComponent("never-run-helper"), inheritedEnvironment: [:])
    }
    private func keys(_ original: BackendCloudRecoveryKeyState) -> BackendCloudRecoveryLocalKeyOwner {
        .init(originalKey: { original }, generationKey: { _ in .missing },
              create: { _ in throw CloudFailure.unavailable }, cipher: { _ in throw CloudFailure.unavailable })
    }
    private func check(_ servers: BackendServersCredentials?, configuration: BackendAccountConfiguration,
                       original: BackendCloudRecoveryKeyState = .present) async throws -> BackendCloudRecoveryLocalStanding {
        let client = try await CloudSecretsFixtureClient(server: CloudSecretsFixtureServer())
        let stores = BackendCloudRecoveryLocalStores(configuration: configuration, keys: keys(original), policy: client.policy, vault: nil,
            passwords: nil, servers: servers, voice: nil, receiver: nil, requireReceiverInert: {}, requireWriter: {}, adoptsLostKeyStores: false)
        return await stores.standing()
    }

    @Test func theCloudCheckSaysNotConvertedConvertedOrGone() async throws {
        // 1. Earlier key here, macOS must ask: not converted, never "gone", nothing but converting offered.
        do {
            let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
            let config = try configuration(root), servers = config.dataDirectory.appendingPathComponent("servers")
            let original = try writeEarlierFile(in: servers)
            let standing = try await check(owner(servers, earlier(.needsPermission)), configuration: config)
            #expect(standing == .notConverted(["server"]))
            #expect(!standing.offersAllowLoginStore)
            let words = try #require(standing.words(cloudKeyHere: true))
            #expect(words.hasPrefix("Saved server sign-ins from the earlier app have not been converted on this Mac yet."))
            #expect(!words.contains("gone") && !words.contains("recovery words") && !words.contains("another device"))
            #expect(BackendCloudRecoveryNotConverted(owners: ["server"]).errorDescription == words)
            #expect(try Data(contentsOf: servers.appendingPathComponent(BackendServersCredentials.fileName)) == original)
        }
        // 2. Earlier key readable without asking: the check converts, and the store is ready.
        do {
            let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
            let config = try configuration(root), servers = config.dataDirectory.appendingPathComponent("servers")
            try writeEarlierFile(in: servers)
            let store = owner(servers, earlier(.key(Self.oldKey)))
            #expect(try await check(store, configuration: config) == .ready)
            #expect(backups(servers).count == 1)
            #expect(try store.read("box-1") == .password(Self.secret))
        }
        // 3. Neither key opens it: "gone", and only then.
        do {
            let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
            let config = try configuration(root), servers = config.dataDirectory.appendingPathComponent("servers")
            try writeEarlierFile(in: servers, key: Data("a-third-key-nobody-has".utf8))
            let standing = try await check(owner(servers, earlier(.key(Self.oldKey))), configuration: config)
            #expect(standing == .keyLost(["server"]))
            #expect(standing.words(cloudKeyHere: true)?.contains("is gone") == true)
            #expect(backups(servers).isEmpty)
        }
    }

    @Test func theCheckLooksForTheServerFileInsideTheServersFolder() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let config = try configuration(root)
        try writeEarlierFile(in: config.dataDirectory.appendingPathComponent("servers"))
        // No Servers owner handed in and this app's key missing: the file where it really lives is found.
        #expect(try await check(nil, configuration: config, original: .missing) == .keyLost(["server"]))
    }
}
