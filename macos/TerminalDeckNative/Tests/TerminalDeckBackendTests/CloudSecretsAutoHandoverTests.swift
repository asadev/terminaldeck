import Foundation
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Owner's decision (14 Nov): saved passwords are on by default and open by themselves on his devices; review of
/// 6e8f1d50 (blocker 1, points 2–8). Fixtures only: in-memory keys, the fixture service (with the pending service
/// change: signed requests), no Keychain, no network, no real-time waits (`pause` returns at once).
@Suite("Cloud saved passwords — on by default, automatic hand-over")
@MainActor
struct CloudSecretsAutoHandoverTests {
    struct Device {
        let client: CloudSecretsFixtureClient
        let graph: BackendCloudSecretsGraph
        let trust: AutoTrustBox
        let logins: AutoLogins
        let outbox: AutoOutbox
    }
    private func device(_ server: CloudSecretsFixtureServer, automatic: Bool = true, deadAfter: Int64 = 0,
                        startAgain: Bool = false, logins: [String: String] = [:]) async throws -> Device {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: automatic)
        let auto = CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) },
            answeredBefore: { box.answeredBefore($0, $1) }, remember: { box.remember($0, $1) })
        await client.coordinator.use(automatic: auto)
        let store = AutoLogins(logins), outbox = AutoOutbox()
        let graph = try BackendCloudSecretsGraph(recovery: client.coordinator, content: client.content, policy: client.policy,
            local: client.local, deviceId: client.device.deviceId, outbox: outbox, stores: [store],
            retainConflict: { _ in }, known: nil, restoreLocalStores: {}, turnsOnBySelf: true, startAgainAvailable: startAgain,
            deadAfter: deadAfter, automatic: auto,
            // The short look-again (5 s) returns at once; the 10-minute re-ask never comes during a test.
            pause: { ms in if ms > 5_000 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } })
        return Device(client: client, graph: graph, trust: box, logins: store, outbox: outbox)
    }
    private func notice(_ type: String) -> CloudEvent {
        CloudEvent(v: 1, type: type, id: UUID().uuidString.lowercased(), payload: CloudValue(.object([])))
    }
    /// What the person saw on a device: sheets, codes and words.
    private func nothingShown(_ d: Device) async -> Bool {
        let ui = d.client.ui
        let words = await ui.confirmationCount, shown = await ui.displays, codes = await ui.transferPrompts, finished = await ui.finished
        return words == 0 && shown.isEmpty && codes.isEmpty && finished == nil
    }
    private func pair(_ a: Device, _ b: Device, nameA: String = "Studio Mac", nameB: String = "MacBook Air") {
        a.trust.trust(b.client.device, name: nameB)
        b.trust.trust(a.client.device, name: nameA)
    }

    // On by default: the first device makes the key with no words, no sheet; its logins go into the new vault.
    @Test func firstDeviceTurnsOnByItselfAndItsLoginsGoIn() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await device(server, logins: ["one": "fixture-login-1", "two": "fixture-login-2"])
        await a.graph.catchUp()
        #expect(await server.epoch == 1)
        #expect(await server.recovery?.isPlaceholder == true)     // the required recovery copy holds no key
        #expect(await a.client.local.value?.acknowledged == true)
        #expect(await a.client.local.value?.recoveryWords == false)
        #expect(await nothingShown(a))
        let page = await a.graph.page()
        #expect(page.standing == .protected && BackendCloudSecretsWords.state(page) == "On")
        #expect(NativeTestControl.none == NativeTestControl.of(page))
        // Existing logins on this Mac: still there, and both were sent sealed into the vault.
        #expect(a.logins.values() == ["one": "fixture-login-1", "two": "fixture-login-2"])
        #expect(await a.outbox.sent.count == 2)
        await a.graph.catchUp()
        #expect(await server.epoch == 1)
    }

    // Blocker 1: the service accepted the set-up, then the read-back or the local save failed.
    @Test func anInterruptedSetUpOpensByItselfAtTheNextStart() async throws {
        for point in ["envelope", "localSave"] {
            let server = CloudSecretsFixtureServer()
            let a = try await device(server, deadAfter: 1_000_000)
            if point == "localSave" { await a.client.local.rejectWrites() } else { await server.fault(point) }
            await a.graph.catchUp()
            #expect(await server.epoch == 1)                      // Cloud took it ...
            #expect(await a.client.local.value == nil)            // ... the key did not reach this Mac
            await a.client.local.acceptWrites(); await server.fault(nil)
            await a.graph.catchUp()
            let key = try #require(await a.client.local.value)
            #expect(key.acknowledged == true && key.recoveryWords == false)
            #expect(await server.approved.contains(a.client.device.deviceId))
            #expect(await a.graph.page().standing == .protected)
        }
    }

    @Test func secondDeviceOpensByItselfWhenTheFirstIsOnline() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await device(server), b = try await device(server)
        await a.graph.catchUp()
        pair(a, b)
        await b.graph.catchUp()                                   // B asks by itself and signs its request
        #expect(await server.requestSignatures.count == 1)
        #expect(BackendCloudSecretsWords.state(await b.graph.page()) == "Opening…")
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.count == 1)
        await b.graph.event(notice("vault"))
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
        #expect(await b.client.local.value?.recoveryWords == false)
        #expect(await nothingShown(a))
        #expect(await nothingShown(b))
        // Point 8: the name from A's own trusted list, not the service's label ("Fixture Mac").
        let opened = await a.graph.page().openedOn
        #expect(opened.count == 1 && opened[0].hasPrefix("Saved passwords opened on MacBook Air, "))
    }

    @Test func staysQuietWhileNoOtherDeviceIsOnlineAndOpensWhenOneComes() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await device(server), b = try await device(server)
        await a.graph.catchUp()
        pair(a, b)
        await b.graph.catchUp()                                   // A is "offline": nobody hears B's request
        let waiting = await b.graph.page()
        #expect(waiting.standing == .locked && waiting.opensBySelf && !waiting.cannotOpen)
        #expect(BackendCloudSecretsWords.state(waiting) == "Opening…" && BackendCloudSecretsWords.advice(waiting) == nil)
        #expect(NativeTestControl.of(waiting) == .none)
        #expect(await nothingShown(b))
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: CloudGate(features: ["cloud"], storageEntitled: true), displayName: "Fixture",
            coverage: [CloudCoverage(sourceId: "memory/I01", inventoryRow: "I01", complete: true, items: 3, bytes: 10, blockedReasons: [])],
            cloudHead: CloudSequence(5), fetched: CloudSequence(5))
        let summary = try #require(BackendCloudOverviewBuilder.build(BackendCloudOverviewInput(snapshot: snapshot, memory: .init(included: true), passwords: waiting)))
        #expect(summary.rows.first { $0.kind == .passwords }?.state == "Opening…")
        #expect(!summary.waiting.contains { $0.id.hasPrefix("passwords") } && !summary.notices.contains { $0.id.hasPrefix("passwords") })
        await a.graph.event(notice("hello"))                      // A comes online and answers what waited
        await b.graph.event(notice("vault"))
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
    }

    // Point 4: the first Mac answers straight after its own set-up (the second asked while it was setting up).
    @Test func theFirstMacAnswersStraightAfterItsSetUp() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await device(server), b = try await device(server, deadAfter: 1_000_000)
        pair(a, b)
        await server.holdNextPossession()
        let setUp = Task { await a.graph.catchUp() }
        while await server.epoch == 0 { await Task.yield() }
        await b.graph.catchUp()                                   // vault there, nobody approved yet: not "dead", asks
        #expect(await !b.graph.page().cannotOpen)
        #expect(await server.approvals.count == 1)
        await server.releasePossession()
        await setUp.value                                         // A finished and answered by itself: no event needed
        #expect(await server.usedApprovals.count == 1)
        await b.graph.event(notice("vault"))
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
    }

    @Test func twoMacsSettingUpAtTheSameMomentEndWithOneKey() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await device(server, deadAfter: 1_000_000), b = try await device(server, deadAfter: 1_000_000)
        pair(a, b)
        async let first: Void = a.graph.catchUp()
        async let second: Void = b.graph.catchUp()
        _ = await (first, second)
        #expect(await server.epoch == 1)
        for d in [a, b] { await d.graph.event(notice("approval")); await d.graph.event(notice("hello")) }
        for d in [a, b] { await d.graph.event(notice("vault")) }
        let rootA = try #require(await a.client.local.value?.root), rootB = try #require(await b.client.local.value?.root)
        #expect(rootA == rootB)
    }

    @Test func underAskMeTheClickAndTheCodesStay() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await device(server, automatic: false), b = try await device(server, automatic: false)
        await a.graph.catchUp()
        pair(a, b)
        await b.graph.catchUp()
        #expect(await server.approvals.isEmpty)                   // "Ask me": nothing is asked by itself
        // Point 7: a silently set-up account never offers recovery words; the one control is "Ask another device".
        #expect(NativeTestControl.of(await b.graph.page()) == .ask)
        let pending = try await b.client.coordinator.requestApproval()
        #expect(await b.client.ui.displays.count == 1)            // B's code
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.isEmpty)
        try await a.client.coordinator.approve(id: pending.approvalId)
        #expect(await a.client.ui.displays.count == 2)
        await b.graph.event(notice("vault"))
        #expect(await b.client.ui.transferPrompts.count == 1)
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
    }

    // Point 7, mixed: the new Mac is on "Ask me", the answering Mac is automatic. The request is unsigned, so it is
    // never answered by itself; it waits on A's page and A's click shows the code: never a dead end.
    @Test func aRequestFromAnAskMeMacWaitsForTheClickOnAnAutomaticMac() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await device(server), b = try await device(server, automatic: false)
        await a.graph.catchUp()
        pair(a, b)
        let pending = try await b.client.coordinator.requestApproval()
        #expect(await server.requestSignatures.isEmpty)
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.isEmpty)
        #expect(await a.graph.page().approvals.map(\.id) == [pending.approvalId])
        try await a.client.coordinator.approve(id: pending.approvalId)
        #expect(await a.client.ui.displays.count == 2)            // the allow sheet and the code
    }

    @Test func aDeviceThisMacDoesNotListOrHasRemovedIsNeverAnswered() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await device(server), b = try await device(server)
        await a.graph.catchUp()
        b.trust.trust(a.client.device, name: "Studio Mac")
        await b.graph.catchUp()
        await a.graph.event(notice("approval"))                   // 1. not on A's own list
        #expect(await server.usedApprovals.isEmpty)
        #expect(await a.graph.page().approvals.count == 1)        // shown for his click (with codes), never answered
        a.trust.trust(b.client.device, name: "MacBook Air"); a.trust.stop(b.client.device.deviceId)
        await a.graph.event(notice("devices"))                    // 2. on A's list but stopped
        #expect(await server.usedApprovals.isEmpty)
        a.trust.trust(b.client.device, name: "MacBook Air")
        await server.forget(b.client.device.deviceId)
        await a.graph.event(notice("approval"))                   // 3. removed from the account
        #expect(await server.usedApprovals.isEmpty)
        #expect(await b.client.local.value == nil)
        // INT2 fix: a device removed from the account is not listed at all (its Allow could only fail: the service no
        // longer gives its keys); the request is never denied, it runs out by itself.
        #expect(await a.graph.page().approvals.isEmpty)
    }

    // Point 2: a hostile service swaps the WRAPPING key of a trusted device and makes the request's key hash match.
    @Test func aSwappedWrappingKeyWithAMatchingHashIsNeverAnswered() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await device(server), b = try await device(server)
        await a.graph.catchUp()
        pair(a, b)
        await b.graph.catchUp()
        let approval = try #require(await server.approvals.values.first)
        let attacker = CloudSecretsFixtureKeys()
        let real = b.client.device
        let swapped = CloudDeviceRegistration(deviceId: real.deviceId, label: real.label, platform: real.platform, appVersion: real.appVersion,
            signPublicJwk: real.signPublicJwk, wrapPublicJwk: try attacker.registration(real.deviceId).wrapPublicJwk)
        await server.substitute(swapped)
        await server.forgeApprovalHash(approval.approvalId, try CloudSecretsCrypto.keyHash(swapped))
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.isEmpty)               // signing key pinned and hash matching: still refused
        // Without the swap the very same request is answered, sealed only to B's own key.
        await server.substitute(nil)
        await server.forgeApprovalHash(approval.approvalId, approval.targetKeyHash)
        await a.graph.event(notice("approval"))
        let envelope = try #require(await server.envelopes[real.deviceId])
        let key = try #require(await a.client.local.value)
        await #expect(throws: (any Error).self) {
            _ = try await CloudSecretsCrypto.unwrapDevice(envelope, sub: CloudSecretsFixtureServer.sub, targetDeviceId: real.deviceId,
                epoch: key.epoch, version: key.version, author: a.client.device.deviceId, authorKey: a.client.device.signPublicJwk, keys: attacker)
        }
        let opened = try await CloudSecretsCrypto.unwrapDevice(envelope, sub: CloudSecretsFixtureServer.sub, targetDeviceId: real.deviceId,
            epoch: key.epoch, version: key.version, author: a.client.device.deviceId, authorKey: a.client.device.signPublicJwk, keys: b.client.keys)
        #expect(try CloudSecretsCrypto.decode(opened.rootKey, count: 32) == key.root)
    }

    // Point 3: one automatic answer per device per key generation.
    @Test func eachDeviceIsAnsweredByItselfOncePerKeyGeneration() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await device(server), b = try await device(server)
        await a.graph.catchUp()
        pair(a, b)
        await b.graph.catchUp()
        await a.graph.event(notice("approval"))
        await b.graph.event(notice("vault"))
        #expect(await server.usedApprovals.count == 1)
        await b.client.local.loseKey()
        let again = try await b.client.coordinator.requestApproval()   // signed again, same device, same generation
        #expect(await server.requestSignatures[again.approvalId] != nil)
        await a.graph.event(notice("approval"))
        #expect(await server.usedApprovals.count == 1)            // waits for a person
        #expect(await a.graph.page().approvals.map(\.id) == [again.approvalId])
    }

    @Test func theNewDeviceTakesTheKeyOnlyFromADeviceItsOwnListHolds() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await device(server), b = try await device(server)
        await a.graph.catchUp()
        a.trust.trust(b.client.device, name: "MacBook Air")       // B's list does NOT hold A
        await b.graph.catchUp()
        await a.graph.event(notice("approval"))
        await b.graph.event(notice("vault"))
        #expect(await b.client.local.value == nil)
        #expect(await nothingShown(b))
        b.trust.trust(a.client.device, name: "Studio Mac")
        await b.graph.event(notice("vault"))
        #expect(await b.client.local.value?.root == a.client.local.value?.root)
    }

    // Point 5: no device can open the Cloud copy: said once; "Start again" makes a fresh copy, nothing local deleted.
    @Test func whenNobodyCanOpenTheCopyThePageSaysSoAndStartAgainMakesAFreshOne() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await device(server)
        await a.graph.catchUp()
        await server.forget(a.client.device.deviceId); await server.dropApproved(a.client.device.deviceId)  // his only device is gone
        let b = try await device(server, startAgain: true, logins: ["kept": "fixture-login-3"])
        await b.graph.catchUp()
        let dead = await b.graph.page()
        #expect(dead.cannotOpen && !dead.opensBySelf)
        #expect(BackendCloudSecretsWords.state(dead) == "The Cloud copy of your saved passwords can't be opened. Your logins on this Mac are safe.")
        #expect(NativeTestControl.of(dead) == .startAgain)
        var withoutTicket = dead; withoutTicket.startAgainAvailable = false
        #expect(NativeTestControl.of(withoutTicket) == .none)
        await b.graph.perform(.startAgain)
        #expect(await server.epoch == 2)
        #expect(await server.archives == 1)                       // the old copy is kept by the service as an archive
        #expect(await b.client.local.value?.epoch == 2)
        #expect(await b.graph.page().standing == .protected)
        #expect(b.logins.values() == ["kept": "fixture-login-3"])
        #expect(await b.outbox.sent.count == 1)
        #expect(await nothingShown(b))
    }

    // Point 6: sign-out never claims recovery words after a silent set-up; an older account still has them.
    @Test func signOutTellsTheTruthAboutRecoveryWords() async throws {
        let server = CloudSecretsFixtureServer()
        let silent = try await device(server)
        await silent.graph.catchUp()
        let state = await silent.client.coordinator.signOutState()
        #expect(state.keyOnThisMac && state.recoveryWordsOnFile == false && state.withoutWords)
        #expect(try await silent.graph.recoveryWordsConfirmed())  // nothing to confirm: the warning says what is lost
        #expect(await !silent.graph.page().offersRecoveryWords)
        let older = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: older)
        try await client.coordinator.setup()                      // the earlier set-up with words
        let words = await client.coordinator.signOutState()
        #expect(words.recoveryWordsOnFile == true && !words.withoutWords)
    }
}

/// The page's ONE control, read the way the section reads it.
enum NativeTestControl: Equatable {
    case none, turnOn, startAgain, ask, askAgain, askOrWords, other
    static func of(_ page: BackendCloudSecretsPage) -> Self {
        switch page.standing {
        case .notSetUp: return page.problem != nil || page.turnOnFailed ? .turnOn : .none
        case .locked, .startedAnew:
            if page.cannotOpen { return page.startAgainAvailable ? .startAgain : .none }
            if page.opensBySelf { return .none }
            return page.offersRecoveryWords ? .askOrWords : .ask
        case .waitingForCloud: return .askAgain
        case .protected: return page.couldNotCheck ? .other : .none
        default: return .other
        }
    }
}

/// This Mac's own setting, trusted-device list and "answered by itself" record, as the app hands them over.
final class AutoTrustBox: @unchecked Sendable {
    private let lock = NSLock()
    private var automatic: Bool
    private var entries: [String: CloudSecretsAutoTrust.Pinned] = [:]
    private var stopped: Set<String> = []
    private var answered: Set<String> = []
    init(on: Bool) { automatic = on }
    func isOn() -> Bool { lock.withLock { automatic } }
    /// `platform`: the kind of device this Mac recorded with the key (default: what the device registered as).
    func trust(_ device: CloudDeviceRegistration, name: String, platform: CloudPlatform? = nil) {
        lock.withLock {
            entries[device.deviceId] = .init(name: name, signKey: device.signPublicJwk, platform: platform ?? device.platform)
            stopped.remove(device.deviceId)
        }
    }
    func stop(_ id: String) { lock.withLock { _ = stopped.insert(id) } }
    func pinned(_ id: String) -> CloudSecretsAutoTrust.Pinned? { lock.withLock { stopped.contains(id) ? nil : entries[id] } }
    func answeredBefore(_ id: String, _ epoch: Int) -> Bool { lock.withLock { answered.contains(id + "@\(epoch)") } }
    func remember(_ id: String, _ epoch: Int) { lock.withLock { _ = answered.insert(id + "@\(epoch)") } }
    func resetAnswered() { lock.withLock { answered.removeAll() } }
}

extension CloudSecretsFixtureServer {
    /// The account no longer lists the device (removed from the account).
    func forget(_ id: String) { devices[id] = nil }
    func dropApproved(_ id: String) { approved.remove(id); envelopes[id] = nil }
}

/// A source that really holds logins (by record id), so the merge into a new vault can be checked.
final class AutoLogins: CloudSecretsLogicalStore, @unchecked Sendable {
    let sourceId = "api"
    let inventoryRow = "I13"
    let domain = CloudSecretsDomain.apiKey
    private let lock = NSLock()
    private var held: [String: String]
    init(_ logins: [String: String]) { held = logins }
    func values() -> [String: String] { lock.withLock { held } }
    /// An item that arrived from another device (a pull lands in the store like any other value).
    func put(_ id: String, _ value: String) { lock.withLock { held[id] = value } }
    func capture() async throws -> [CloudSecretRecord] {
        lock.withLock { held }.sorted { $0.key < $1.key }.map { id, value in
            CloudSecretRecord(sourceId: sourceId, recordId: id, domain: domain.rawValue,
                              payload: .init(.object([.init("key", .string(value))])))
        }
    }
    func validate(_ record: CloudSecretRecord) async throws {}
    func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus { .alreadyPresent }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool { true }
}

actor AutoOutbox: CloudOutboxPort {
    var joined: Set<String> = []
    /// Operations sent (sealed) to Cloud.
    var sent: [String] = []
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt {
        sent += operations.map { $0.entityId }
        return .init(operationIds: operations.map { $0.opId }, queued: operations.count, bytes: 0, savedAt: CloudSecretsFixtureServer.now)
    }
    func coverage(sourceId: String) async throws -> CloudCoverage { throw CloudFailure.unavailable }
    func flush() async throws -> [CloudReceipt] { [] }
    func restoreProgress() async throws -> CloudRestoreProgress { throw CloudFailure.unavailable }
    func contextReady(projectId: String) async throws -> CloudContextReady { throw CloudFailure.unavailable }
    func register(adapter: any CloudDomainAdapter) async throws {
        guard let secret = adapter as? CloudSecretsLogicalAdapter else { throw CloudFailure.unsupportedFormat }
        joined.insert(secret.sourceId)
    }
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { throw CloudFailure.unavailable }
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt { throw CloudFailure.unavailable }
    func pull() async throws -> [CloudImportReceipt] { [] }
    func setPaused(_ paused: Bool) async throws {}
}
