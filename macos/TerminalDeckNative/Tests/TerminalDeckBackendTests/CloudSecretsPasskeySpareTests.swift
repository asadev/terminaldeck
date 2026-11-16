import Foundation
import CryptoKit
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// PASSWORDS-2 slice 2: his passkey as the spare key. A fixture passkey stands in for Touch ID: its PRF output is an
/// HMAC of the salt under a secret only it holds, and its assertion is a P-256 signature the fixture service checks
/// with the public key kept at "add". Real AES-GCM sealing, the fixture service, no Keychain, no network.
@Suite("Cloud saved passwords — passkey spare key")
@MainActor
struct CloudSecretsPasskeySpareTests {
    private func mac(_ server: CloudSecretsFixtureServer, passkey: FixturePasskey?, deadAfter: Int64 = 0) async throws
        -> (client: CloudSecretsFixtureClient, graph: BackendCloudSecretsGraph, trust: AutoTrustBox) {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true)
        let auto = CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) })
        await client.coordinator.use(automatic: auto)
        let graph = try BackendCloudSecretsGraph(recovery: client.coordinator, content: client.content, policy: client.policy,
            local: client.local, deviceId: client.device.deviceId, outbox: AutoOutbox(), stores: [AutoLogins([:])],
            retainConflict: { _ in }, known: nil, restoreLocalStores: {}, turnsOnBySelf: true, startAgainAvailable: true,
            deadAfter: deadAfter, automatic: auto, passkey: passkey,
            pause: { ms in if ms > 5_000 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } })
        return (client, graph, box)
    }

    @Test func theSpareOpensOnlyWithItsOwnPasskeyAccountAndGeneration() throws {
        let root = Data(repeating: 7, count: 32), prf = Data(repeating: 9, count: 32), sub = CloudSecretsFixtureServer.sub
        let spare = try CloudSecretsSpareCrypto.seal(root: root, prf: prf, sub: sub, credentialId: "cred-1", epoch: 1, createdAt: 1, deviceName: "Mac mini")
        #expect(try CloudSecretsSpareCrypto.open(spare, prf: prf, sub: sub) == root)
        #expect(throws: (any Error).self) { try CloudSecretsSpareCrypto.open(spare, prf: Data(repeating: 8, count: 32), sub: sub) }
        #expect(throws: (any Error).self) { try CloudSecretsSpareCrypto.open(spare, prf: prf, sub: "22222222-2222-4222-8222-222222222222") }
        let moved = CloudSecretsSpare(v: 1, kind: "passkey", credentialId: "cred-2", epoch: 1, nonce: spare.nonce,
                                      ciphertext: spare.ciphertext, tag: spare.tag, createdAt: 1, deviceName: "Mac mini")
        #expect(throws: (any Error).self) { try CloudSecretsSpareCrypto.open(moved, prf: prf, sub: sub) }
        let older = CloudSecretsSpare(v: 1, kind: "passkey", credentialId: "cred-1", epoch: 2, nonce: spare.nonce,
                                      ciphertext: spare.ciphertext, tag: spare.tag, createdAt: 1, deviceName: "Mac mini")
        #expect(throws: (any Error).self) { try CloudSecretsSpareCrypto.open(older, prf: prf, sub: sub) }
    }

    // Made once per generation, with only the system's passkey sheet; the service keeps a copy it cannot open.
    @Test func theSpareIsMadeOnceWithOnlyTheSystemSheet() async throws {
        let server = CloudSecretsFixtureServer(), passkey = FixturePasskey(server: server)
        let a = try await mac(server, passkey: passkey)
        await a.graph.catchUp()
        await a.graph.catchUp()
        #expect(await passkey.sheets == 1)
        let kept = try #require(await server.spares.first)
        #expect(await server.spares.count == 1)
        #expect(throws: (any Error).self) { try CloudSecretsSpareCrypto.open(kept, prf: Data(repeating: 0, count: 32), sub: CloudSecretsFixtureServer.sub) }
        #expect(await a.client.ui.displays.isEmpty)
        #expect(await a.client.ui.confirmationCount == 0)
    }

    // The stricter setting: a new Mac opens with one Touch ID, no other device, no code.
    @Test func underTheStricterSettingANewMacOpensWithThePasskey() async throws {
        let server = CloudSecretsFixtureServer(), passkey = FixturePasskey(server: server)
        let a = try await mac(server, passkey: passkey)
        await a.graph.catchUp()
        await a.graph.setAskOnNewDevice(true)
        let b = try await mac(server, passkey: passkey)
        a.trust.trust(b.client.device, name: "MacBook Pro"); b.trust.trust(a.client.device, name: "Mac mini")
        await b.graph.catchUp()
        let waiting = await b.graph.page()
        #expect(waiting.waitsForClick && waiting.opensWithPasskey)
        // INT2: the page's control lives in the app target (not visible here); CloudPageNames3UITests checks that these
        // facts give .openWithPasskey.
        #expect(lockedOrAnew(waiting.standing))
        await b.graph.perform(.openWithPasskey)
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
        #expect(await server.approved.contains(b.client.device.deviceId))
        // Only its own waiting code (shown under the stricter setting, review blocker 3); no second code to compare.
        #expect(await b.client.ui.displays.count == 1)
        #expect(await b.client.ui.transferPrompts.isEmpty)
        #expect(await server.usedApprovals.isEmpty)                 // nobody answered: the passkey did it
    }

    // Nobody else can open the copy: the passkey opens the SAME copy (nothing lost, no new generation).
    @Test func whenNobodyCanOpenThePasskeyOpensTheCopyThatIsThere() async throws {
        let server = CloudSecretsFixtureServer(), passkey = FixturePasskey(server: server)
        let a = try await mac(server, passkey: passkey)
        await a.graph.catchUp()
        let root = try #require(await a.client.local.value?.root)
        await server.forget(a.client.device.deviceId); await server.dropApproved(a.client.device.deviceId)
        let b = try await mac(server, passkey: passkey)
        await b.graph.catchUp()
        let dead = await b.graph.page()
        #expect(dead.cannotOpen && dead.opensWithPasskey && lockedOrAnew(dead.standing)) // INT2: control checked in CloudPageNames3UITests
        await b.graph.perform(.openWithPasskey)
        #expect(await b.client.local.value?.root == root)
        #expect(await server.epoch == 1)
    }

    // Another passkey (different PRF) never opens it, and nothing is saved.
    @Test func anotherPasskeyNeverOpensIt() async throws {
        let server = CloudSecretsFixtureServer(), passkey = FixturePasskey(server: server)
        let a = try await mac(server, passkey: passkey)
        await a.graph.catchUp()
        let other = FixturePasskey(server: server, sharing: passkey)   // same credential id, other secret
        let b = try await mac(server, passkey: other)
        await #expect(throws: (any Error).self) { try await b.client.coordinator.openWithSpare(passkey: other) }
        #expect(await b.client.local.value == nil)
    }

    // Service fit (7ff81baac), C8: the exact text this device signs for /spare/add, as the service builds it.
    @Test func theSpareSignatureCoversExactlyTheServicesText() throws {
        let spare = CloudSecretsSpare(v: 1, kind: "passkey", credentialId: "cred-1", epoch: 3, nonce: "bm9uY2U", ciphertext: "Y2lwaGVy",
                                      tag: "dGFn", createdAt: 7, deviceName: "Mac mini")
        let hash = CloudSecretsCrypto.hash(Data(#"{"ciphertext":"Y2lwaGVy","createdAt":7,"credentialId":"cred-1","deviceName":"Mac mini","epoch":3,"kind":"passkey","nonce":"bm9uY2U","tag":"dGFn","v":1}"#.utf8))
        let text = try CloudSecretsProof.spare(sub: "sub-1", by: "device-1", epoch: 3, credentialId: "cred-1", spare: spare)
        #expect(String(decoding: text, as: UTF8.self)
            == #"{"by":"device-1","credentialId":"cred-1","epoch":3,"purpose":"TD-PASSWORDS-SPARE-1","spareHash":"\#(hash)","sub":"sub-1"}"#)
    }

    // Service fit, C4 + C6 + C7 + C8: one spare per generation, made with ONE challenge and this Mac's signature; the
    // maker is named from the service's own record (never the name inside the sealed copy); later looks ask no
    // challenge while the service's status already says a spare is there.
    @Test func oneSignedSparePerGenerationNamedByTheService() async throws {
        let server = CloudSecretsFixtureServer(), passkey = FixturePasskey(server: server)
        await server.useServiceFacts()
        let a = try await mac(server, passkey: passkey)
        await a.graph.catchUp()
        #expect(await passkey.sheets == 1)
        #expect(await server.spares.count == 1)
        #expect(await server.spareAdded?.by == a.client.device.deviceId)
        #expect(await server.spareChallengeCount == 1)
        await a.graph.catchUp()
        _ = await a.client.coordinator.offerSpareOnce(passkey: passkey)
        #expect(await server.spareChallengeCount == 1)
        #expect(await passkey.sheets == 1)
        #expect(await a.graph.page().spareMade == BackendCloudSecretsWords.spareMade(nil, at: CloudSecretsFixtureServer.now))
        // A second Mac holding the key never adds a second spare of this generation, and names the maker as the
        // service records it, under the name the account now gives that device.
        let b = try await mac(server, passkey: passkey)
        a.trust.trust(b.client.device, name: "MacBook Pro"); b.trust.trust(a.client.device, name: "Mac mini")
        await b.graph.catchUp()
        await a.graph.event(CloudEvent(v: 1, type: "approval", id: UUID().uuidString.lowercased(), payload: CloudValue(.object([]))))
        await b.graph.event(CloudEvent(v: 1, type: "vault", id: UUID().uuidString.lowercased(), payload: CloudValue(.object([]))))
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
        #expect(await server.spares.count == 1)
        #expect(await passkey.sheets == 1)
        try await server.relabel(a.client.device.deviceId, label: "Mac mini", appVersion: "fixture")
        #expect(await b.graph.page().spareMade == BackendCloudSecretsWords.spareMade("Mac mini", at: CloudSecretsFixtureServer.now))
        // The service refuses a spare not signed by the adding device itself (a sign-in alone cannot plant one).
        let made = try #require(await server.spares.first)
        await server.clearSpares()
        await #expect(throws: (any Error).self) {
            let challenge = try await a.client.control.spareChallenge(requestId: UUID().uuidString.lowercased())
            let forged = try await CloudSecretsFixtureKeys().signDevicePayload(CloudSecretsProof.spare(sub: CloudSecretsFixtureServer.sub,
                by: a.client.device.deviceId, epoch: made.epoch, credentialId: made.credentialId, spare: made))
            try await a.client.control.addSpare(.init(requestId: UUID().uuidString.lowercased(), challengeId: challenge.challengeId,
                credentialId: made.credentialId, attestationObject: "oA", clientDataJSON: challenge.challenge, spare: made,
                signature: CloudSecretsCrypto.encode(forged)))
        }
        #expect(await server.spares.isEmpty)
    }
}

extension CloudSecretsFixtureServer {
    func clearSpares() { spares = []; spareAdded = nil }
}

/// A passkey in memory: one credential, a PRF secret and a P-256 assertion key (registered with the fixture service).
actor FixturePasskey: CloudSecretsPasskeyPort {
    private let server: CloudSecretsFixtureServer
    private let secret: SymmetricKey
    private let signing = P256.Signing.PrivateKey()
    private var credential: Data?
    private let shared: Data?
    /// PASSWORDS-5: this passkey's credential id, and the passkeys this device holds (the system refuses to make one
    /// while an excluded one is held, ASAuthorizationError 1006).
    private let id: Data
    private var holds: Set<Data> = []
    var sheets = 0
    init(server: CloudSecretsFixtureServer, sharing other: FixturePasskey? = nil, id: String = "fixture-credential") {
        self.server = server; secret = SymmetricKey(size: .bits256)
        self.id = Data(id.utf8)
        shared = other == nil ? nil : Data("fixture-credential".utf8)
    }
    func holding(_ ids: [String]) { holds = Set(ids.map { Data($0.utf8) }) }
    nonisolated func available() async -> Bool { true }
    private func prf(_ salt: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: salt, using: secret)) }
    /// PASSWORDS-5: the credential ids the last sheet was told to exclude.
    var excluded: [Data] = []
    /// PASSWORDS-5: hold the sheet open until `answer()` (he answers it) or `cancel()` (this app withdraws it).
    var holdSheet = false
    var withdrawn = 0
    private var open: CheckedContinuation<Bool, Never>?
    private var shownWaiters: [CheckedContinuation<Void, Never>] = []
    func hold(_ value: Bool = true) { holdSheet = value }
    /// Returns once a held sheet is on screen.
    func untilShown() async {
        if open != nil { return }
        await withCheckedContinuation { shownWaiters.append($0) }
    }
    func answer() { open?.resume(returning: true); open = nil }
    func cancel() async {
        guard let waiting = open else { return }
        open = nil; withdrawn += 1
        waiting.resume(returning: false)
    }
    func create(challenge: Data, userId: Data, userName: String, salt: Data, excluded: [Data]) async throws -> CloudSecretsPasskeyCreated {
        sheets += 1
        self.excluded = excluded
        if !holds.isDisjoint(with: excluded) { throw CloudSecretsPasskeyExcluded() }
        if holdSheet {
            let answered = await withCheckedContinuation { (waiting: CheckedContinuation<Bool, Never>) in
                open = waiting
                let waiters = shownWaiters; shownWaiters = []
                for waiter in waiters { waiter.resume() }
            }
            guard answered else { throw CancellationError() }
        }
        let id = shared ?? self.id
        credential = id
        await server.registerPasskey(CloudSecretsCrypto.encode(id), key: try CloudSecretsCrypto.publicJWK(signing.publicKey.x963Representation))
        return .init(credentialId: id, attestationObject: Data([0xa0]), clientDataJSON: challenge, prf: prf(salt))
    }
    func use(challenge: Data, allowed: [Data], salt: Data) async throws -> CloudSecretsPasskeyUsed {
        sheets += 1
        guard let id = allowed.first else { throw CloudFailure.invalidRequest }
        let authenticatorData = Data(repeating: 1, count: 37)
        let signature = try signing.signature(for: authenticatorData + challenge).rawRepresentation
        return .init(credentialId: id, authenticatorData: authenticatorData, clientDataJSON: challenge, signature: signature, prf: prf(salt))
    }
}

/// INT2: the page states whose one control can be "Open with my passkey" (NativeCloudSecretsSection.control).
private func lockedOrAnew(_ standing: BackendCloudSecretsPage.Standing) -> Bool {
    switch standing { case .locked, .startedAnew: return true; default: return false }
}
