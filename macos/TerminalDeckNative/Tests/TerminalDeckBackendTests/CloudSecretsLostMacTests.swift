import Foundation
import CryptoKit
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// A lost Mac signed out from another device (Security design macos/night/codex/sign-out-lost-mac-design.md, B2-B4):
/// the first of his Macs that holds the key makes the new key by itself, seals it for every device IT trusts (never the
/// removed one, never a device it does not list with that key), in one call; his other devices take their copy by
/// themselves; nothing of his is lost on any path (the old key stays as that generation's archive key). Fixtures only.
@Suite("Cloud saved passwords — a lost Mac signed out from another device: the key changes by itself, nothing is lost")
@MainActor
struct CloudSecretsLostMacTests {
    struct Mac {
        let client: CloudSecretsFixtureClient
        let graph: BackendCloudSecretsGraph
        let trust: AutoTrustBox
    }
    struct Device {
        let client: CloudSecretsFixtureClient
        let trust: AutoTrustBox
        let registration: CloudDeviceRegistration
    }
    private func mac(_ server: CloudSecretsFixtureServer) async throws -> Mac {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true)
        let auto = CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) },
            answeredBefore: { box.answeredBefore($0, $1) }, remember: { box.remember($0, $1) })
        await client.coordinator.use(automatic: auto)
        await client.coordinator.use(rotationJitter: { 0 })
        await client.coordinator.use(sleep: { _ in })
        let graph = try BackendCloudSecretsGraph(recovery: client.coordinator, content: client.content, policy: client.policy,
            local: client.local, deviceId: client.device.deviceId, outbox: AutoOutbox(), stores: [],
            retainConflict: { _ in }, known: nil, restoreLocalStores: {}, turnsOnBySelf: true, deadAfter: 0, automatic: auto,
            pause: { ms in if ms > 5_000 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } })
        await graph.guardPresses { false }
        await graph.catchUp()
        return Mac(client: client, graph: graph, trust: box)
    }
    /// Another device of his (`platform` as the account lists it) that the Mac answers by itself.
    private func device(_ server: CloudSecretsFixtureServer, _ platform: CloudPlatform, name: String) async throws -> Device {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true)
        await client.coordinator.use(automatic: CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) }))
        await client.coordinator.use(rotationJitter: { 0 })
        await client.coordinator.use(sleep: { _ in })
        let own = client.device
        let listed = CloudDeviceRegistration(deviceId: own.deviceId, label: name, platform: platform, appVersion: "fixture",
                                             signPublicJwk: own.signPublicJwk, wrapPublicJwk: own.wrapPublicJwk)
        await server.register(listed)
        return Device(client: client, trust: box, registration: listed)
    }
    private func notice(_ type: String) -> CloudEvent {
        CloudEvent(v: 1, type: type, id: UUID().uuidString.lowercased(), payload: CloudValue(.object([])))
    }
    /// Pins both ways, then the device asks and the Mac answers by itself; the device holds the very key.
    private func handOver(_ m: Mac, _ d: Device, name: String = "Studio Mac") async throws {
        m.trust.trust(d.registration, name: d.registration.label)
        d.trust.trust(m.client.device, name: name)
        _ = try await d.client.coordinator.requestApproval()
        await m.graph.event(notice("approval"))
        #expect(try await d.client.coordinator.receiveApproval())
        #expect(await d.client.local.value?.root == m.client.local.value?.root)
    }

    // 1. Signed out from another device while it held the key: the Mac that is on makes the new key by itself on the
    //    `devices` notice (no sheet, no click), seals ONE copy each for his other Mac and his phone, none for the lost
    //    Mac and none for a device it no longer lists; each of them takes its copy by itself. Nothing is lost: every
    //    device keeps the old key as that generation's archive key, and the one left out keeps its old key.
    @Test func theMacThatIsOnChangesTheKeyAndHisOtherDevicesTakeTheirCopy() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useFriendlyNames([:])          // the account's device list: who holds the key
        let mini = try await mac(server)
        let first = try #require(await mini.client.local.value)
        let book = try await device(server, .macos, name: "MacBook Air")
        let phone = try await device(server, .ios, name: "iPhone")
        let lost = try await device(server, .macos, name: "MacBook Pro")
        let dropped = try await device(server, .macos, name: "Old iMac")
        for d in [book, phone, lost, dropped] { try await handOver(mini, d) }
        mini.trust.stop(dropped.registration.deviceId)               // no longer on the mini's own list
        await server.signOutKeyHolder(lost.registration.deviceId, name: "MacBook Pro")

        await mini.graph.event(notice("devices"))
        #expect(await server.rotations == 1)
        #expect(await server.epoch == first.epoch + 1)
        let sent = try #require(await server.rotateRequests.first)
        #expect(Set(sent.copies.map(\.targetDeviceId)) == [book.registration.deviceId, phone.registration.deviceId])
        #expect(await mini.client.ui.displays.isEmpty, "no sheet, no code")
        let made = try #require(await mini.client.local.value)
        #expect(made.epoch == first.epoch + 1 && made.root != first.root)
        #expect(await mini.client.local.archived(epoch: first.epoch)?.root == first.root, "old key kept as the archive key")

        for d in [book, phone] {
            #expect(try await d.client.coordinator.keyChange() == .tookCopy)
            #expect(await d.client.local.value?.root == made.root)
            #expect(await d.client.local.archived(epoch: first.epoch)?.root == first.root)
        }
        // The device the mini no longer lists got no copy: it keeps its old key (nothing deleted) and asks again later.
        #expect(try await dropped.client.coordinator.keyChange() == .nothing)
        #expect(await dropped.client.local.value?.root == first.root)
    }

    // 2. A copy is taken only from one of his COMPUTERS on this device's own list with that key: a copy from an author
    //    it does not list is left alone and its old key is kept.
    @Test func aCopyFromAnAuthorThisMacDoesNotListIsNeverTaken() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useFriendlyNames([:])          // the account's device list: who holds the key
        let mini = try await mac(server)
        let first = try #require(await mini.client.local.value)
        let book = try await device(server, .macos, name: "MacBook Air")
        let lost = try await device(server, .macos, name: "MacBook Pro")
        try await handOver(mini, book); try await handOver(mini, lost)
        await server.signOutKeyHolder(lost.registration.deviceId, name: "MacBook Pro")
        #expect(try await mini.client.coordinator.keyChange() == .rotated)
        book.trust.stop(mini.client.device.deviceId)
        #expect(try await book.client.coordinator.keyChange() == .nothing)
        #expect(await book.client.local.value?.root == first.root)
        #expect(await book.client.local.value?.epoch == first.epoch)
    }

    // 3. Two of his Macs hear the same notice: exactly one key change; the other takes its copy; both end on one key.
    @Test func twoMacsAtOnceMakeOneKeyChange() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useFriendlyNames([:])          // the account's device list: who holds the key
        let mini = try await mac(server)
        let book = try await device(server, .macos, name: "MacBook Air")
        let lost = try await device(server, .macos, name: "MacBook Pro")
        try await handOver(mini, book); try await handOver(mini, lost)
        mini.trust.trust(book.registration, name: "MacBook Air")
        await server.signOutKeyHolder(lost.registration.deviceId, name: "MacBook Pro")
        async let a = mini.client.coordinator.keyChange()
        async let b = book.client.coordinator.keyChange()
        let outcomes = Set([try await a, try await b])
        #expect(await server.rotations == 1)
        #expect(outcomes.contains(.rotated))
        // Nobody lost a key; the loser took its copy when the winner had checked its key itself, else it asks again.
        let miniKey = await mini.client.local.value, bookKey = await book.client.local.value
        #expect(miniKey != nil && bookKey != nil)
        if outcomes.contains(.tookCopy) { #expect(miniKey?.root == bookKey?.root) }
    }

    // 4. Nothing due: nothing changes. The removed Mac itself never starts one.
    @Test func nothingDueChangesNothing() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useFriendlyNames([:])          // the account's device list: who holds the key
        let mini = try await mac(server)
        let first = try #require(await mini.client.local.value)
        #expect(try await mini.client.coordinator.keyChange() == .nothing)
        await mini.graph.event(notice("devices"))
        #expect(await server.rotations == 0)
        #expect(await mini.client.local.value?.root == first.root)
    }

    // 5. The key change fails on the way (no answer): this Mac keeps the key it had, the Cloud keeps its generation.
    @Test func aFailedKeyChangeLosesNothing() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useFriendlyNames([:])          // the account's device list: who holds the key
        let mini = try await mac(server)
        let first = try #require(await mini.client.local.value)
        let lost = try await device(server, .macos, name: "MacBook Pro")
        try await handOver(mini, lost)
        await server.signOutKeyHolder(lost.registration.deviceId, name: "MacBook Pro")
        await server.fault("rotate")
        await #expect(throws: (any Error).self) { try await mini.client.coordinator.keyChange() }
        #expect(await mini.client.local.value?.root == first.root)
        #expect(await mini.client.local.value?.epoch == first.epoch)
        #expect(await server.epoch == first.epoch)
        // Next notice, with the service answering again: the change goes through.
        await server.fault(nil)
        #expect(try await mini.client.coordinator.keyChange() == .rotated)
    }

    // 6. A race lost to another Mac (version moved, or the change is no longer due) is "take its copy", never an error.
    @Test func losingTheRaceIsNotAnError() {
        #expect(CloudRecoveryCoordinator.lostTheRace(.versionChanged))
        #expect(CloudRecoveryCoordinator.lostTheRace(.remote(.init(code: "not_due", message: "", retryable: false, requestId: "r"))))
        #expect(CloudRecoveryCoordinator.lostTheRace(.remote(.init(code: "version_changed", message: "", retryable: false, requestId: "r"))))
        #expect(!CloudRecoveryCoordinator.lostTheRace(.unavailable))
    }

    // 7. D1 (decided by Decker for now, one flag): a new sign-in on a machine another device signed out does NOT get the
    //    key by itself; his Allow on another of his devices is the "Yes, it's mine": the account is told
    //    (confirm-mine), then the hand-over goes on. Every other device stays no-tap.
    @Test func aMachineSignedOutBeforeWaitsForYesItsMine() async throws {
        let server = CloudSecretsFixtureServer()
        let mini = try await mac(server)
        let back = try await device(server, .macos, name: "MacBook Pro")
        mini.trust.trust(back.registration, name: "MacBook Pro"); back.trust.trust(mini.client.device, name: "Studio Mac")
        await server.markSignedOutBefore(back.registration.deviceId)
        #expect(CloudRecoveryCoordinator.askOnASignedOutMachine)
        let pending = try await back.client.coordinator.requestApproval()
        await mini.graph.event(notice("approval"))
        #expect(await server.usedApprovals.isEmpty, "not answered by itself")
        #expect(await back.client.local.value == nil)
        // His "Yes, it's mine" (the Allow on the mini): told to the account first, then answered.
        try await mini.client.coordinator.approve(id: pending.approvalId)
        #expect(await server.confirmedMine == [back.registration.deviceId])
        #expect(await server.usedApprovals.contains(pending.approvalId))
        // An ordinary new Mac of his: still no tap.
        let other = try await device(server, .macos, name: "MacBook Air")
        try await handOver(mini, other)
    }

    // 8. The status field: the object form (d0c902d76); a wrong shape is "nothing due".
    @Test func aMalformedDueFieldIsNothingDue() throws {
        func parse(_ json: String) throws -> CloudSecretsRotationDue? { BackendCloudSecretsControl.rotationDue(try NativeRPCValue.parseJSON(Data(json.utf8))) }
        #expect(try parse(#"{"since":5,"removedDeviceId":"a","removedName":"MacBook","holders":["b","c"]}"#)?.holders == ["b", "c"])
        #expect(try parse(#"{"since":5,"removedDeviceId":"a","holders":[1]}"#) == nil)
        #expect(try parse(#"{"removedDeviceId":"a","holders":[]}"#) == nil)
        #expect(try parse("null") == nil)
        #expect(try parse("true") == nil, "a plain true is read only with the device list, by the route itself")
    }

    // 10. Review finding 2: a service that swaps a pinned device's wrapping key never receives the new key: no copy for
    //     it (its own signature over that key was never checked here); it asks again through the hand-over.
    @Test func aSwappedWrappingKeyNeverGetsACopy() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useFriendlyNames([:])
        let mini = try await mac(server)
        let book = try await device(server, .macos, name: "MacBook Air")
        let phone = try await device(server, .ios, name: "iPhone")
        let lost = try await device(server, .macos, name: "MacBook Pro")
        for d in [book, phone, lost] { try await handOver(mini, d) }
        let forged = try CloudSecretsFixtureKeys().registration(book.registration.deviceId)
        await server.swapWrapKey(book.registration.deviceId, to: forged.wrapPublicJwk)
        await server.signOutKeyHolder(lost.registration.deviceId, name: "MacBook Pro")
        #expect(try await mini.client.coordinator.keyChange() == .rotated)
        let sent = try #require(await server.rotateRequests.first)
        #expect(sent.copies.map(\.targetDeviceId) == [phone.registration.deviceId])
        let epoch = await server.epoch
        let marked = await mini.client.local.book?.hasAnswered(book.registration.deviceId, epoch: epoch) ?? true
        #expect(!marked, "not marked answered: its fresh request is still answered (and checked) by the hand-over")
    }

    // 11. Review finding 3: one copy the service will not take does not stop the key change; that device is not marked
    //     answered for the new key, so it is answered by itself when it asks again.
    @Test func aRefusedCopyDoesNotStopTheKeyChange() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useFriendlyNames([:])
        let mini = try await mac(server)
        let book = try await device(server, .macos, name: "MacBook Air")
        let phone = try await device(server, .ios, name: "iPhone")
        let lost = try await device(server, .macos, name: "MacBook Pro")
        for d in [book, phone, lost] { try await handOver(mini, d) }
        await server.refuseCopy(for: phone.registration.deviceId)
        await server.signOutKeyHolder(lost.registration.deviceId, name: "MacBook Pro")
        #expect(try await mini.client.coordinator.keyChange() == .rotated)
        #expect(await server.rotations == 1)
        let epoch = await server.epoch
        #expect(await mini.client.local.book?.hasAnswered(book.registration.deviceId, epoch: epoch) == true)
        #expect(await mini.client.local.book?.hasAnswered(phone.registration.deviceId, epoch: epoch) == false)
        #expect(try await book.client.coordinator.keyChange() == .tookCopy)
        // The phone asks again and is answered by itself under the new key.
        _ = try await phone.client.coordinator.requestApproval()
        await mini.graph.event(notice("approval"))
        #expect(try await phone.client.coordinator.receiveApproval())
        #expect(await phone.client.local.value?.root == mini.client.local.value?.root)
    }

    // 12. Review finding 6: after a key change the Mac re-sends under the new key EVERY saved-password item it holds,
    //     also one it only pulled from a device that is no longer in the account (the store keeps no origin, and the
    //     "already sent" and "just imported" marks are per key generation, CloudSecretsLogical.changedSnapshot).
    @Test func everyItemItHoldsIsSentAgainUnderTheNewKeyAlsoOnePulledFromAGoneDevice() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useFriendlyNames([:])
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true)
        let auto = CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) })
        await client.coordinator.use(automatic: auto)
        await client.coordinator.use(rotationJitter: { 0 }); await client.coordinator.use(sleep: { _ in })
        let store = AutoLogins(["own-1": "fixture-own-1", "own-2": "fixture-own-2"]), outbox = AutoOutbox()
        let graph = try BackendCloudSecretsGraph(recovery: client.coordinator, content: client.content, policy: client.policy,
            local: client.local, deviceId: client.device.deviceId, outbox: outbox, stores: [store],
            retainConflict: { _ in }, known: nil, restoreLocalStores: {}, turnsOnBySelf: true, deadAfter: 0, automatic: auto,
            pause: { ms in if ms > 5_000 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } })
        await graph.guardPresses { false }
        await graph.catchUp()
        let mini = Mac(client: client, graph: graph, trust: box)
        #expect(await outbox.sent.count == 2)
        // The item "pulled" earlier from the lost Mac sits in the mini's store like any other (the lost Mac wrote it).
        store.put("pulled-from-lost", "fixture-pulled")
        await graph.sourceChanged(store.sourceId)
        let lost = try await device(server, .macos, name: "MacBook Pro")
        try await handOver(mini, lost)
        await server.signOutKeyHolder(lost.registration.deviceId, name: "MacBook Pro")
        await server.forget(lost.registration.deviceId)
        let before = await outbox.sent.count
        await graph.event(notice("devices"))
        #expect(await server.rotations == 1)
        #expect(await outbox.sent.count - before == 3, "all three items, the pulled one included, under the new key")
    }

    // 13. Key-box sign-off finding 2: a key change due to a sign-out from another device never seals a copy to a browser
    //     (it may be the one still signed in on the stolen Mac); the browser asks afterwards and is answered under the
    //     usual rules (no click by default).
    @Test func aBrowserGetsNoCopyAfterASignOutAndAsksAgainAsUsual() async throws {
        let server = CloudSecretsFixtureServer()
        await server.useFriendlyNames([:])
        let mini = try await mac(server)
        let book = try await device(server, .macos, name: "MacBook Air")
        let browser = try await device(server, .web, name: "Chrome on Mac")
        let lost = try await device(server, .macos, name: "MacBook Pro")
        for d in [book, browser, lost] { try await handOver(mini, d) }
        await server.signOutKeyHolder(lost.registration.deviceId, name: "MacBook Pro")
        #expect(try await mini.client.coordinator.keyChange() == .rotated)
        let sent = try #require(await server.rotateRequests.first)
        #expect(sent.copies.map(\.targetDeviceId) == [book.registration.deviceId], "his Mac yes, the browser never")
        let epoch = await server.epoch
        let marked = await mini.client.local.book?.hasAnswered(browser.registration.deviceId, epoch: epoch) ?? true
        #expect(!marked)
        // The browser asks again: answered by itself, as any time, with the new key.
        _ = try await browser.client.coordinator.requestApproval()
        await mini.graph.event(notice("approval"))
        #expect(try await browser.client.coordinator.receiveApproval())
        #expect(await browser.client.local.value?.root == mini.client.local.value?.root)
        #expect(await browser.client.local.value?.epoch == epoch)
    }

    // 9. Signed out by another device (B4): only this device id's Cloud keys go (current key, every older generation,
    //    the seen mark, the hand-over book). The store never reaches anything else.
    @Test func aRemoteSignOutRemovesOnlyThisDevicesCloudKeys() async throws {
        let box = KeychainBox()
        let subject = CloudSubject(issuer: CloudWire.issuer, sub: CloudSecretsFixtureServer.sub)
        let store = BackendCloudSecretsProtectedStore(subject: subject, deviceId: "dev-1",
            read: { box.get("slot") }, write: { box.put("slot", $0) },
            archiveWrite: { box.put("archive-\($0)", $1) }, archiveRead: { box.get("archive-\($0)") },
            seenRead: { box.get("seen") }, seenWrite: { box.put("seen", $0) },
            bookRead: { box.get("book") }, bookWrite: { box.put("book", $0) },
            removeKeys: { epochs in for e in epochs { box.drop("archive-\(e)") }; box.drop("book"); box.drop("seen"); box.drop("slot") })
        let key = CloudSecretsLocalKey(subject: subject, deviceId: "dev-1", epoch: 3, version: CloudSequence(4), root: Data(repeating: 7, count: 32),
                                       recoveryPublicKey: .init(kty: "OKP", crv: "Ed25519", x: "x"))
        try await store.saveVerified(key)
        for e in 1...2 { try await store.archive(CloudSecretsLocalKey(subject: subject, deviceId: "dev-1", epoch: e, version: CloudSequence(UInt64(e)),
                                                                     root: Data(repeating: UInt8(e), count: 32), recoveryPublicKey: key.recoveryPublicKey)) }
        try await store.saveSeenCloudEpoch(3)
        try await store.saveHandOverBook(CloudSecretsHandOverBook())
        box.put("his-data", Data("kept".utf8))
        try await store.forgetAfterRemoteSignOut()
        #expect(box.keys() == ["his-data"])
        #expect(try await store.read() == nil)
    }
}

/// An in-memory stand-in for the Keychain items (no fixture ever opens the real Keychain).
final class KeychainBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func get(_ k: String) -> Data? { lock.withLock { items[k] } }
    func put(_ k: String, _ v: Data) { lock.withLock { items[k] = v } }
    func drop(_ k: String) { lock.withLock { _ = items.removeValue(forKey: k) } }
    func keys() -> [String] { lock.withLock { items.keys.sorted() } }
}
