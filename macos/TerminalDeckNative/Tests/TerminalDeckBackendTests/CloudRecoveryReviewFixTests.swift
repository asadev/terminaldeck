import Foundation
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Review "saved passwords switched on", part A (lane V): A-M1, A-M2, S-A1, S-A2, S-A3. Fixture bytes only; no
/// Security calls; folders only under ~/Deck Dev/notes/cloud-test-20261112/v/, removed at the end.
private struct CloudRecoveryReviewFixCipher: BackendAccountVaultCipher {
    let password: Data
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func decrypt(_ blob: Data) throws -> String { try ChromiumSafeStorageCipher.decrypt(blob, password: password) }
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { try ChromiumSafeStorageCipher.encrypt(text, password: password) }
    var forStores: BackendBrowserPasswordsCipher {
        let cipher = self
        return .init(available: { true }, decrypt: { try cipher.decrypt($0) }, encrypt: { try cipher.encrypt($0, existingVault: $1) })
    }
}
private final class CloudRecoveryReviewFixKeys: @unchecked Sendable {
    private let lock = NSLock()
    private let original: BackendCloudRecoveryKeyState
    private var made = 0
    init(_ original: BackendCloudRecoveryKeyState) { self.original = original }
    var creations: Int { lock.withLock { made } }
    func owner() -> BackendCloudRecoveryLocalKeyOwner {
        .init(originalKey: { self.original },
              generationKey: { _ in .missing },
              create: { _ in self.lock.withLock { self.made += 1 } },
              cipher: { _ in throw CloudFailure.secretsLocked })
    }
}
private struct CloudRecoveryReviewFixMac {
    let root: URL
    let configuration: BackendAccountConfiguration
    let list: BackendServersStore
    let credentials: BackendServersCredentials
    let port: BackendCloudSecretsServerPort
    init(_ name: String, in folder: URL) throws {
        root = folder.appendingPathComponent(name, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true), home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: home, appName: "Terminal Deck Fixture",
            appID: "terminaldeck", helperExecutable: root.appendingPathComponent("never-run-helper"), inheritedEnvironment: [:])
        let policy = BackendServersStoragePolicy(mayRead: true, mayWrite: true)
        list = BackendServersStore(dataRoot: data, policy: policy, serverAccessEnabled: true)
        let cipher = CloudRecoveryReviewFixCipher(password: Data(repeating: 41, count: 32))
        credentials = BackendServersCredentials(dataRoot: data, cipher: cipher.forStores, policy: policy, keyValidator: .init(validate: { _, _ in nil }))
        port = BackendCloudSecretsServerPort(sourceId: "servers", credentials: credentials, servers: list)
    }
    var names: Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: configuration.dataDirectory.path)) ?? []) }
}
private actor CloudRecoveryReviewFixPort: CloudSecretsPort {
    let answer: CloudSecretsStatus?
    init(_ answer: CloudSecretsStatus?) { self.answer = answer }
    func status() throws -> CloudSecretsStatus {
        guard let answer else { throw CloudFailure.secretsLocked }
        return answer
    }
    func beginSetup() {}
    func requestApproval() throws -> CloudApproval { throw CloudFailure.unavailable }
    func openApproval(id: String) {}
    func beginRecovery() {}
    func beginReset() {}
    func exportLogical(source: String) throws -> [CloudSecretRecord] { throw CloudFailure.unavailable }
    func importLogical(_ records: [CloudSecretRecord], conflictPolicy: CloudConflictPolicy) throws -> CloudVerification { throw CloudFailure.unavailable }
    func classify(relativePath: String, sourceId: String) -> CloudSecretClassification { CloudSecretsPolicy.classify(relativePath: relativePath, sourceId: sourceId) }
    func protectProjectSettings(projectId: String, rootId: String, bytes: Data) throws -> CloudSecretRecord { throw CloudFailure.unavailable }
}

@Suite(.serialized)
struct CloudRecoveryReviewFixTests {
    private static func folder() throws -> URL {
        let approved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112/v")
        let made = approved.appendingPathComponent("review-fix-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }
    /// Removes this test's folder, and the shared "v" folder too when nothing else is left in it.
    private static func clean(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        let parent = folder.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true { try? FileManager.default.removeItem(at: parent) }
    }
    private static func status(state: CloudVaultState, ready: Bool) -> CloudSecretsStatus {
        .init(state: state, epoch: 1, version: CloudSequence(2), recoveryReady: ready, approvedDeviceCount: 1, pendingApprovals: [])
    }
    private static func ask(_ port: CloudRecoveryReviewFixPort, local: BackendCloudRecoveryLocalStanding?,
                            failures: [String] = []) async throws -> NativeRPCValue {
        let gate = CloudSecretsFixtureGate(clock: CloudSecretsFixtureServer.now)
        let policy = CloudSecretsPolicy(capabilities: { await gate.value() }, now: { CloudSecretsFixtureServer.now })
        var standing: (@Sendable () async -> BackendCloudRecoveryLocalStanding)? = nil
        if let local { standing = { @Sendable in local } }
        let tools = BackendCloudSecretsTools(secrets: port, policy: policy, browser: { _, _ in throw CloudFailure.unavailable }, localStanding: standing,
                                             saveFailures: { @Sendable in failures })
        let shown = try await tools.invoke("cloud.secrets", arguments: .init(.object([.init("action", .string("status"))])))
        return shown.raw
    }

    /// A-M1: with Cloud saying "ready" and this Mac holding the confirmed key, the tool still never says protected
    /// while this Mac's own key is gone, blocked or its files cannot be checked; it names the true state instead.
    @Test func cloudRecoveryStatusToolNeverSaysProtectedWhileThisMacsOwnStoresAreNotReady() async throws {
        let port = CloudRecoveryReviewFixPort(Self.status(state: .ready, ready: true))
        let cases: [(BackendCloudRecoveryLocalStanding, String)] = [
            (.keyLost(["server"]), "key_lost"), (.blocked("fixture: keychain locked"), "blocked"), (.cannotCheck(["server"]), "cant_check")
        ]
        for (local, expected) in cases {
            let shown = try await Self.ask(port, local: local)
            #expect(shown["protected"].bool == false)
            #expect(shown["state"].string == expected)
            let message = shown["message"].string ?? ""
            #expect(message == local.words(cloudKeyHere: true))
            #expect(!message.isEmpty)
            #expect(message != "Ready")
        }
        // The control: the same Cloud answer with this Mac's stores open is protected.
        let open = try await Self.ask(port, local: .ready)
        #expect(open["protected"].bool == true)
        #expect(open["state"].string == "protected")
    }

    /// B-M2: a saved password whose save to Cloud failed keeps the tool from saying protected; it says "gaps"
    /// and names it, and says protected again once nothing failed.
    @Test func cloudRecoveryStatusToolNeverSaysProtectedAfterAFailedSave() async throws {
        let port = CloudRecoveryReviewFixPort(Self.status(state: .ready, ready: true))
        let sentence = "Server passwords were not saved to Cloud: fixture failure."
        let failed = try await Self.ask(port, local: .ready, failures: [sentence])
        #expect(failed["protected"].bool == false)
        #expect(failed["state"].string == "gaps")
        #expect(failed["message"].string?.contains(sentence) == true)
        let clear = try await Self.ask(port, local: .ready, failures: [])
        #expect(clear["protected"].bool == true)
        #expect(clear["state"].string == "protected")
    }

    /// A-M1: not set up, no key on this Mac yet, and a status that cannot be read are each said as they are.
    @Test func cloudRecoveryStatusToolSaysNotSetUpLockedOrCantCheck() async throws {
        let unset = try await Self.ask(CloudRecoveryReviewFixPort(Self.status(state: .unset, ready: false)), local: .ready)
        #expect(unset["protected"].bool == false)
        #expect(unset["state"].string == "not_set_up")
        #expect(unset["message"].string?.contains("not set up in Cloud yet") == true)
        let locked = try await Self.ask(CloudRecoveryReviewFixPort(Self.status(state: .ready, ready: false)), local: .ready)
        #expect(locked["protected"].bool == false)
        #expect(locked["state"].string == "locked")
        #expect(locked["message"].string?.contains("nothing from this Mac is sent") == true)
        let unreadable = try await Self.ask(CloudRecoveryReviewFixPort(nil), local: .ready)
        #expect(unreadable["protected"].bool == false)
        #expect(unreadable["state"].string == "cant_check")
        #expect(unreadable["message"].string?.contains("Can't check saved passwords") == true)
    }

    /// A-M2: a saved-server-sign-in file that cannot be read (a folder in its place) or is too large is "can't
    /// check", never ready; the unlock stops there, and nothing joins, is captured, sent or changed on this Mac.
    @Test func cloudRecoveryAStoreThatCannotBeReadIsCantCheckAndNothingIsSent() async throws {
        let folder = try Self.folder()
        defer { Self.clean(folder) }
        for oversized in [false, true] {
            let mac = try CloudRecoveryReviewFixMac(oversized ? "big" : "unreadable", in: folder)
            if oversized {
                try Data(repeating: 65, count: 4 * 1024 * 1024 + 1).write(to: mac.credentials.file)
            } else {
                try FileManager.default.createDirectory(at: mac.credentials.file, withIntermediateDirectories: true)
            }
            let namesBefore = mac.names
            let keys = CloudRecoveryReviewFixKeys(.present)
            let remote = CloudSecretsFixtureServer()
            let author = try await CloudSecretsFixtureClient(server: remote)
            let target = try await CloudSecretsFixtureClient(server: remote)
            try await author.coordinator.setup()
            let migration = BackendCloudRecoveryLocalStores.lean(configuration: mac.configuration, keys: keys.owner(), policy: target.policy,
                servers: mac.port, voice: nil, requireWriter: {})
            let standing = await migration.standing()
            #expect(standing == .cannotCheck(["server"]))
            #expect(standing != .ready)
            #expect(!standing.offersAllowLoginStore)
            let words = standing.words(cloudKeyHere: false) ?? ""
            #expect(words.contains("Can't check"))
            #expect(words.contains("Check again"))
            #expect(!words.contains("Protected"))
            let journal = CloudSecretsFixtureJournal(), outbox = CloudSecretsFixtureOutbox()
            let adapter = CloudSecretsLogicalAdapter(store: mac.port.store, content: target.content, policy: target.policy,
                deviceId: target.device.deviceId, keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) })
            let service = try CloudSecretsService(recovery: target.coordinator, policy: target.policy, content: target.content,
                outbox: outbox, adapters: [adapter], prepareSynchronization: {},
                restoreLocalStores: { try await migration.recoverAfterVerifiedCloudUnlock() })
            await target.ui.setWords(await author.ui.phrase)
            var refused: [String]?
            do { try await service.beginRecovery() } catch let refusal as BackendCloudRecoveryCannotCheck { refused = refusal.owners }
            #expect(refused == ["server"])
            let pulls = await outbox.pulls
            let queued = await outbox.queued.count
            let kept = await journal.operations.count
            #expect(pulls == 0)
            #expect(queued == 0)
            #expect(kept == 0)
            #expect(keys.creations == 0)
            #expect(mac.names == namesBefore)
        }
    }

    /// S-A1: a lost local key on an account with no saved passwords in Cloud promises nothing from Cloud and offers
    /// neither recovery words nor another device; the status tool says the same.
    @Test func cloudRecoveryKeyLostWithNothingSetUpInCloudOffersNoWayThatCannotWork() async throws {
        let lost = BackendCloudRecoveryLocalStanding.keyLost(["server"])
        for here in [false, true] {
            let words = lost.words(cloudKeyHere: here, cloudSetUp: false) ?? ""
            #expect(words.contains("not set up in Cloud yet"))
            #expect(!words.contains("recovery words"))
            #expect(!words.contains("another device"))
            #expect(!words.contains("safe there"))
        }
        // Unchanged when Cloud has them.
        #expect(lost.words(cloudKeyHere: false)?.contains("recovery words or from another device") == true)
        let shown = try await Self.ask(CloudRecoveryReviewFixPort(Self.status(state: .unset, ready: false)), local: lost)
        #expect(shown["protected"].bool == false)
        #expect(shown["state"].string == "key_lost")
        #expect(shown["message"].string?.contains("not set up in Cloud yet") == true)
        #expect(shown["message"].string?.contains("recovery words") == false)
    }

    /// S-A2: the shared login-store key is missing, the server file is absent, but the session host's account vault
    /// file is still on this Mac: that is a lost key, not a fresh Mac, so Cloud never mints a replacement key.
    @Test func cloudRecoveryAMissingKeyWithASealedFileLeftIsKeyLostNotFresh() async throws {
        let folder = try Self.folder()
        defer { Self.clean(folder) }
        let mac = try CloudRecoveryReviewFixMac("vault-left", in: folder)
        let vaultFolder = mac.configuration.dataDirectory.appendingPathComponent(BackendAccountVault.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultFolder, withIntermediateDirectories: true)
        let vaultFile = vaultFolder.appendingPathComponent(BackendAccountVault.fileName)
        let sealed = Data("fixture-sealed-bytes".utf8)
        try sealed.write(to: vaultFile)
        let keys = CloudRecoveryReviewFixKeys(.missing)
        let gate = CloudSecretsFixtureGate(clock: CloudSecretsFixtureServer.now)
        let policy = CloudSecretsPolicy(capabilities: { await gate.value() }, now: { CloudSecretsFixtureServer.now })
        let migration = BackendCloudRecoveryLocalStores.lean(configuration: mac.configuration, keys: keys.owner(), policy: policy,
            servers: mac.port, voice: nil, requireWriter: {})
        let standing = await migration.standing()
        #expect(standing == .keyLost(["account"]))
        var refused = false
        do { try await migration.recoverAfterVerifiedCloudUnlock() } catch is BackendCloudRecoveryKeyLost { refused = true }
        #expect(refused)
        #expect(keys.creations == 0)
        #expect(!FileManager.default.fileExists(atPath: mac.credentials.file.path))
        #expect(!mac.names.contains("cloud-local-stores"))
        let after = try Data(contentsOf: vaultFile)
        #expect(after == sealed)
        // With the vault file gone too, the same Mac is simply fresh.
        try FileManager.default.removeItem(at: vaultFolder)
        let fresh = await migration.standing()
        #expect(fresh == .ready)
    }

    /// S-A3: in the lean version a leftover route never switches an owner to another store file at start.
    @Test func cloudRecoveryLeanResumeNeverActivatesALeftoverRoute() async throws {
        let folder = try Self.folder()
        defer { Self.clean(folder) }
        let mac = try CloudRecoveryReviewFixMac("route-left", in: folder)
        let saved = try mac.credentials.save("fixture-server", credential: .password("fixture-server-value"))
        #expect(saved.ok)
        let original = try Data(contentsOf: mac.credentials.file)
        let routeFolder = mac.configuration.dataDirectory.appendingPathComponent("cloud-local-stores", isDirectory: true)
        try FileManager.default.createDirectory(at: routeFolder, withIntermediateDirectories: true)
        let generation = UUID().uuidString.lowercased()
        let route = Data("{\"version\":1,\"generation\":\"\(generation)\",\"owners\":[\"server\"]}".utf8)
        try route.write(to: routeFolder.appendingPathComponent("current.json"))
        let keys = CloudRecoveryReviewFixKeys(.present)
        let gate = CloudSecretsFixtureGate(clock: CloudSecretsFixtureServer.now)
        let policy = CloudSecretsPolicy(capabilities: { await gate.value() }, now: { CloudSecretsFixtureServer.now })
        let migration = BackendCloudRecoveryLocalStores.lean(configuration: mac.configuration, keys: keys.owner(), policy: policy,
            servers: mac.port, voice: nil, requireWriter: {})
        var failed = false
        do { try await migration.resume() } catch { failed = true }
        #expect(!failed)
        #expect(keys.creations == 0)
        let read = try mac.credentials.read("fixture-server")
        #expect(read == .password("fixture-server-value"))
        let after = try Data(contentsOf: mac.credentials.file)
        #expect(after == original)
        let generationFolder = routeFolder.appendingPathComponent(generation, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: generationFolder.path))
    }
}
