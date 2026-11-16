import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lean scope item 4: this Mac's own trusted-device list decides. Fixtures only: no Keychain, no network.
@Suite("Cloud device trust — this Mac's list decides, only a window press adds to it")
struct CloudTrustTests {
    static let subject = CloudSubject(issuer: "https://issuer.example.invalid/auth/v1", sub: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    static let idA = "10000000-0000-4000-8000-00000000000a"
    static let idB = "10000000-0000-4000-8000-00000000000b"

    private func key() -> (secret: P256.Signing.PrivateKey, jwk: CloudPublicJWK) {
        let secret = P256.Signing.PrivateKey(), point = secret.publicKey.x963Representation
        return (secret, CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])),
                                       y: BackendCloudAccountIdentity.base64(Data(point[33..<65]))))
    }
    private func device(_ id: String, _ name: String, _ jwk: CloudPublicJWK, added: Int64? = nil) -> CloudDevice {
        .init(deviceId: id, label: name, platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false,
              lastSeenAt: 0, signPublicJwk: jwk, wrapPublicJwk: jwk, registeredAt: added)
    }
    private func registration(_ id: String, _ jwk: CloudPublicJWK) -> CloudDeviceRegistration {
        .init(deviceId: id, label: "This Mac", platform: .macos, appVersion: "fixture", signPublicJwk: jwk, wrapPublicJwk: jwk)
    }
    private func capture(_ id: String, _ name: String, _ jwk: CloudPublicJWK) throws -> BackendCloudTrustCapture {
        let rows = BackendCloudTrustRows.build(devices: [device(id, name, jwk)], list: nil, thisDeviceId: nil)
        // Bound first: a `#require` inside a `#require` is a recursive macro expansion.
        let row = try #require(rows.first)
        return try #require(BackendCloudTrustCapture(row: row))
    }
    private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: the code

    @Test func theCodeIsTheFirst80BitsOfTheDesignFormula() throws {
        let made = key()
        let y = try #require(made.jwk.y)
        let keyId = try #require(BackendCloudDeviceCode.keyId(made.jwk))
        #expect(keyId == hex(Data("{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"\(made.jwk.x)\",\"y\":\"\(y)\"}".utf8)))
        let code = try #require(BackendCloudDeviceCode.code(deviceId: Self.idA, keyId: keyId))
        let digest = Array(SHA256.hash(data: Data("TD-CLOUD-DEVICE-CODE-1\n\(Self.idA)\n\(keyId)".utf8)))
        let expected = digest.prefix(10).map { String(format: "%02X", $0) }.joined()
        #expect(code.replacingOccurrences(of: " ", with: "") == expected)
        let groups = code.split(separator: " ")
        #expect(groups.count == 5)
        #expect(groups.allSatisfy({ $0.count == 4 }))
        #expect(code.count == 24)
    }
    @Test func aLookAlikeIdCannotReachAnotherDevicesCode() throws {
        let made = key(), other = key()
        let keyId = try #require(BackendCloudDeviceCode.keyId(made.jwk))
        let real = try #require(BackendCloudDeviceCode.code(deviceId: Self.idA, keyId: keyId))
        // Another spelling of the same id, or an id that would shift the line breaks, has no code at all.
        #expect(BackendCloudDeviceCode.code(deviceId: Self.idA.uppercased(), keyId: keyId) == nil)
        #expect(BackendCloudDeviceCode.code(deviceId: Self.idA + " ", keyId: keyId) == nil)
        #expect(BackendCloudDeviceCode.code(deviceId: Self.idA + "\n" + keyId, keyId: keyId) == nil)
        #expect(BackendCloudDeviceCode.code(deviceId: "{" + String(Self.idA.dropFirst().dropLast()) + "}", keyId: keyId) == nil)
        // Another id, or another key, is another code.
        #expect(BackendCloudDeviceCode.code(deviceId: Self.idB, keyId: keyId) != real)
        let otherKeyId = try #require(BackendCloudDeviceCode.keyId(other.jwk))
        #expect(BackendCloudDeviceCode.code(deviceId: Self.idA, keyId: otherKeyId) != real)
        // A key not written the one canonical way, or not a P-256 key, has no key id.
        #expect(BackendCloudDeviceCode.keyId(.init(kty: "EC", crv: "P-256", x: made.jwk.x + "=", y: made.jwk.y)) == nil)
        #expect(BackendCloudDeviceCode.keyId(.init(kty: "EC", crv: "P-384", x: made.jwk.x, y: made.jwk.y)) == nil)
        #expect(BackendCloudDeviceCode.keyId(.init(kty: "EC", crv: "P-256", x: made.jwk.x, y: nil)) == nil)
        // On the screen such a device shows no code and no sheet can offer it.
        let rows = BackendCloudTrustRows.build(devices: [device(Self.idA.uppercased(), "Fixture Mac", made.jwk)], list: nil, thisDeviceId: nil)
        let row = try #require(rows.first)
        #expect(row.code == nil)
        #expect(!row.canBeTrusted)
        #expect(BackendCloudTrustCapture(row: row) == nil)
    }

    // MARK: what the sync core is given

    @Test func theSyncCoreGetsAKeyOnlyForADeviceThisMacTrusts() async throws {
        // The sync core judges every pack with the key this returns (its own tests cover apply / held / refused with
        // the real engine). No key means the pack waits; nothing here can ask the service.
        let slot = CloudTrustFixtureSlot()
        let store = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        let stranger = key(), own = key()
        #expect(await store.trustedSigningKey(deviceId: Self.idA) == nil)
        let pressed = try capture(Self.idA, "MacBook Air", stranger.jwk)
        try await store.trust([pressed], restore: false, latest: nil)
        #expect(await store.trustedSigningKey(deviceId: Self.idA) == stranger.jwk)
        // "Own" is proved by signature: this Mac's id maps to the key THIS MAC made, so a pack that only claims the
        // id cannot check under it.
        try await store.addSelf(registration(Self.idB, own.jwk))
        #expect(await store.trustedSigningKey(deviceId: Self.idB) == own.jwk)
        // A trusted device's key is never handed out for another device id, and a look-alike id finds nothing.
        #expect(await store.trustedSigningKey(deviceId: "10000000-0000-4000-8000-00000000000c") == nil)
        #expect(await store.trustedSigningKey(deviceId: Self.idA.uppercased()) == nil)
        #expect(await store.trustedSigningKey(deviceId: "") == nil)
        // A list that cannot be read fails safe: no key for anyone, so everything waits.
        let blind = CloudTrustFixtureSlot()
        blind.put(slot.bytes()); blind.breakReads(true)
        let blindStore = BackendCloudTrustStore(subject: Self.subject, slot: blind.port(), pressRefused: { false })
        #expect(await blindStore.trustedSigningKey(deviceId: Self.idA) == nil)
        #expect(await blindStore.trustedSigningKey(deviceId: Self.idB) == nil)
    }
    @Test func aListForAnotherAccountOrADamagedOneIsNotUsed() async throws {
        let made = key()
        let pressed = try capture(Self.idA, "MacBook Air", made.jwk)
        let other = CloudSubject(issuer: Self.subject.issuer, sub: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let source = CloudTrustFixtureSlot()
        try await BackendCloudTrustStore(subject: other, slot: source.port(), pressRefused: { false }).trust([pressed], restore: false, latest: nil)
        let slot = CloudTrustFixtureSlot()
        slot.put(source.bytes())
        let store = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        await #expect(throws: BackendCloudTrustRefusal.unreadable) { _ = try await store.list() }
        #expect(await store.trustedSigningKey(deviceId: Self.idA) == nil)
        slot.put(Data("{\"v\":1,\"devices\":\"oops\"}".utf8))
        let damaged = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        await #expect(throws: BackendCloudTrustRefusal.unreadable) { _ = try await damaged.list() }
        // And nothing is written over it by a press.
        await #expect(throws: BackendCloudTrustRefusal.unreadable) { try await damaged.trust([pressed], restore: false, latest: nil) }
        #expect(slot.writes() == 0)
    }

    // MARK: the press

    @Test func theKeyStoredIsTheOneTheSheetShowed_R1() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let shown = key(), swapped = key()
        await f.server.setOthers([device(Self.idA, "MacBook Air", shown.jwk)])
        try await f.account.refresh()
        let rows = await f.account.state().trust
        let row = try #require(rows.first(where: { $0.deviceId == Self.idA }))
        #expect(row.standing == .new)
        let drawn = try #require(BackendCloudTrustCapture(row: row))
        // Cloud now shows another key for that device. The press is cancelled: nothing is stored, and above all not
        // the key the person never compared.
        await f.server.setOthers([device(Self.idA, "MacBook Air", swapped.jwk)])
        await #expect(throws: BackendCloudTrustRefusal.listChanged) { try await f.account.trustDevices([drawn]) }
        let afterSwap = try await f.trust.list()
        #expect(!afterSwap.devices.contains(where: { $0.deviceId == Self.idA }))
        // The device gone from Cloud's list cancels the press too.
        await f.server.setOthers([])
        await #expect(throws: BackendCloudTrustRefusal.listChanged) { try await f.account.trustDevices([drawn]) }
        // No answer from Cloud at the press: the key the sheet showed is stored, exactly that one.
        await f.server.setOthers([device(Self.idA, "MacBook Air", swapped.jwk)])
        await f.transport.setDeviceListOffline(true)
        try await f.account.trustDevices([drawn])
        let stored = try await f.trust.list()
        let entry = try #require(stored.devices.first(where: { $0.deviceId == Self.idA }))
        #expect(entry.signKey == shown.jwk)
        #expect(entry.keyId == drawn.keyId)
        #expect(entry.how == "click")
        #expect(entry.trusted)
        // Later the service's other key never replaces it: the row shows the stored key's code.
        await f.transport.setDeviceListOffline(false)
        try await f.account.refresh()
        let later = await f.account.state().trust
        let known = try #require(later.first(where: { $0.deviceId == Self.idA }))
        #expect(known.standing == .trusted)
        #expect(known.code == drawn.code)
        #expect(known.knownSince != nil)
        let kept = try await f.trust.list()
        #expect(kept.devices.first(where: { $0.deviceId == Self.idA })?.signKey == shown.jwk)
    }
    @Test func aCodeThatIsNotTheCodeOfTheKeyIsNeverStored_R1() async throws {
        let slot = CloudTrustFixtureSlot()
        let store = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        let shown = key(), other = key()
        let honest = try capture(Self.idA, "MacBook Air", shown.jwk)
        // The code of one key with the bytes of another: refused.
        let mixed = BackendCloudTrustCapture(deviceId: Self.idA, name: "MacBook Air", signKey: other.jwk, keyId: honest.keyId, code: honest.code)
        await #expect(throws: BackendCloudTrustRefusal.listChanged) { try await store.trust([mixed], restore: false, latest: nil) }
        let otherKeyId = try #require(BackendCloudDeviceCode.keyId(other.jwk))
        let relabelled = BackendCloudTrustCapture(deviceId: Self.idA, name: "MacBook Air", signKey: other.jwk, keyId: otherKeyId, code: honest.code)
        await #expect(throws: BackendCloudTrustRefusal.listChanged) { try await store.trust([relabelled], restore: false, latest: nil) }
        #expect(slot.writes() == 0)
        // Once trusted, a press with another key for the same device never replaces the stored key.
        try await store.trust([honest], restore: false, latest: nil)
        let rekeyed = try capture(Self.idA, "MacBook Air", other.jwk)
        await #expect(throws: BackendCloudTrustRefusal.listChanged) { try await store.trust([rekeyed], restore: false, latest: nil) }
        let list = try await store.list()
        #expect(list.devices.count == 1)
        #expect(list.devices.first?.signKey == shown.jwk)
    }
    @Test func twoDevicesThatShowOneCodeCannotBeTrusted() async throws {
        let a = key(), b = key()
        // An 80-bit collision cannot be made in a test, so the row builder is given a code function that collides.
        let colliding: BackendCloudTrustRows.Coder = { _, key in
            guard let id = BackendCloudDeviceCode.keyId(key) else { return nil }
            return (keyId: id, code: "AAAA BBBB CCCC DDDD EEEE")
        }
        let rows = BackendCloudTrustRows.build(devices: [device(Self.idA, "MacBook Air", a.jwk), device(Self.idB, "MacBook Air", b.jwk)],
                                               list: nil, thisDeviceId: nil, code: colliding)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy({ $0.sameCode && !$0.canBeTrusted }))
        #expect(rows.allSatisfy({ BackendCloudTrustCapture(row: $0) == nil }))
        // A new device that shows the code of a device this Mac already trusts (and the service no longer lists).
        let aKeyId = try #require(BackendCloudDeviceCode.keyId(a.jwk))
        let trusted = BackendCloudTrustedList(subject: Self.subject, revision: 1, devices: [
            .init(deviceId: Self.idA, signKey: a.jwk, keyId: aKeyId, name: "MacBook Air", trust: "trusted", how: "click", trustedAt: 1)])
        let twin = BackendCloudTrustRows.build(devices: [device(Self.idB, "MacBook Air", b.jwk)], list: trusted, thisDeviceId: nil, code: colliding)
        #expect(twin.first?.sameCode == true)
        // The list itself refuses a press when the newest device list carries the alarm.
        let slot = CloudTrustFixtureSlot()
        let store = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        let honest = try capture(Self.idA, "MacBook Air", a.jwk)
        let alarmed = CloudDeviceTrustRow(deviceId: Self.idA, name: "MacBook Air", standing: .new, code: honest.code, keyId: honest.keyId,
                                          signKey: a.jwk, sameCode: true)
        await #expect(throws: BackendCloudTrustRefusal.sameCode) { try await store.trust([honest], restore: false, latest: [alarmed]) }
        #expect(slot.writes() == 0)
    }
    @Test func everyDeviceOfASameCodeOrSameKeyGroupIsBlockedAndThePressOnTheFirstIsRefused_run14() async throws {
        // Run 14's pictures: the alarm reached the screen on the SECOND of two devices only, and the first kept an
        // enabled Trust button. "Do not trust either" is the group's: both are marked, neither can be captured, and
        // the list itself refuses the press on the first.
        let a = key(), b = key()
        let honest = try capture(Self.idA, "MacBook Air", a.jwk)
        let bKeyId = try #require(BackendCloudDeviceCode.keyId(b.jwk))
        let first = CloudDeviceTrustRow(deviceId: Self.idA, name: "MacBook Air", standing: .new, code: honest.code, keyId: honest.keyId,
                                        signKey: a.jwk)
        let second = CloudDeviceTrustRow(deviceId: Self.idB, name: "MacBook Air", standing: .new, code: honest.code, keyId: bKeyId,
                                         signKey: b.jwk, sameCode: true)
        #expect(first.canBeTrusted)
        let coded = BackendCloudTrustRows.alarmed([first, second])
        #expect(coded.count == 2)
        #expect(coded.allSatisfy({ $0.sameCode && !$0.canBeTrusted }))
        #expect(coded.allSatisfy({ BackendCloudTrustCapture(row: $0) == nil }))
        let slot = CloudTrustFixtureSlot()
        let store = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        await #expect(throws: BackendCloudTrustRefusal.sameCode) { try await store.trust([honest], restore: false, latest: [first, second]) }
        #expect(slot.writes() == 0)
        // The same for two devices that use ONE key (their codes differ): the mark arrives on the second only.
        let other = try capture(Self.idB, "Mac Studio", a.jwk)
        let keyed = CloudDeviceTrustRow(deviceId: Self.idB, name: "Mac Studio", standing: .new, code: other.code, keyId: other.keyId,
                                        signKey: a.jwk, sameKey: true)
        let shared = BackendCloudTrustRows.alarmed([first, keyed])
        #expect(shared.count == 2)
        #expect(shared.allSatisfy({ $0.sameKey && !$0.canBeTrusted }))
        #expect(shared.allSatisfy({ BackendCloudTrustCapture(row: $0) == nil }))
        await #expect(throws: BackendCloudTrustRefusal.sameKey) { try await store.trust([honest], restore: false, latest: [first, keyed]) }
        #expect(slot.writes() == 0)
        // A device alone in its list keeps its Trust button, and a list is never reordered or shortened.
        #expect(BackendCloudTrustRows.alarmed([first]) == [first])
    }
    @Test func thisMacIsShownOnlyByAKeyItHolds_M2() throws {
        // Security review M2: a dishonest service lists ITS key under this Mac's id, so both screens would show the
        // same wrong code. This Mac's row is computed from the key this Mac holds, never from the device list.
        let mine = key(), services = key(), other = key()
        let listed = [device(Self.idA, "This Mac", services.jwk), device(Self.idB, "MacBook Air", other.jwk)]
        let mineCode = try #require(BackendCloudDeviceCode.code(deviceId: Self.idA, key: mine.jwk))
        let servicesCode = try #require(BackendCloudDeviceCode.code(deviceId: Self.idA, key: services.jwk))
        let rows = BackendCloudTrustRows.build(devices: listed, list: nil, thisDeviceId: Self.idA, thisKey: mine.jwk)
        let own = try #require(rows.first(where: { $0.standing == .thisMac }))
        #expect(own.code == mineCode.code)
        #expect(own.code != servicesCode.code)
        #expect(BackendCloudTrustRows.serviceShowsAnotherKeyForThisMac(devices: listed, thisDeviceId: Self.idA, thisKey: mine.jwk))
        #expect(!BackendCloudTrustRows.serviceShowsAnotherKeyForThisMac(devices: [device(Self.idA, "This Mac", mine.jwk)], thisDeviceId: Self.idA, thisKey: mine.jwk))
        // The list cannot be read and no key is at hand: this Mac shows NO code rather than the service's.
        let blind = BackendCloudTrustRows.build(devices: listed, list: nil, thisDeviceId: Self.idA, thisKey: nil, listReadable: false)
        let blindOwn = try #require(blind.first(where: { $0.standing == .thisMac }))
        #expect(blindOwn.code == nil)
        // With the list unreadable nobody can be trusted from a sheet: the code stays on screen, no key goes with it.
        let stranger = try #require(blind.first(where: { $0.deviceId == Self.idB }))
        #expect(stranger.code != nil)
        #expect(!stranger.canBeTrusted)
        #expect(BackendCloudTrustCapture(row: stranger) == nil)
        // The list unreadable but this Mac's key at hand: its own code is still its own.
        let held = BackendCloudTrustRows.build(devices: listed, list: nil, thisDeviceId: Self.idA, thisKey: mine.jwk, listReadable: false)
        #expect(held.first(where: { $0.standing == .thisMac })?.code == mineCode.code)
        // The stored name is the plain form too.
        #expect(BackendCloudTrustRows.plainName("MacBook Air\nCode: 4F2A 91C3 B07E 55D1 8A2C") == "MacBook Air Code")
    }
    @Test func thePageSaysWhenTheListCannotBeReadOrCloudShowsAnotherKeyForThisMac_M2() async throws {
        let f = try CloudAccountFixture.make()
        let stranger = key(), services = key()
        await f.server.setOthers([device(Self.idA, "MacBook Air", stranger.jwk)])
        _ = try await f.signin()
        let healthy = await f.account.state()
        #expect(healthy.trustNotice == nil)
        let own = try #require(healthy.trust.first(where: { $0.standing == .thisMac }))
        let ownCode = try #require(own.code)
        #expect(healthy.trust.first(where: { $0.deviceId == Self.idA })?.canBeTrusted == true)
        // A dishonest service lists ITS key under this Mac's id: this Mac's code does not move, and the page says so.
        await f.server.setOwnKeyShown(services.jwk)
        try await f.account.refresh()
        let lied = await f.account.state()
        #expect(lied.trust.first(where: { $0.standing == .thisMac })?.code == ownCode)
        #expect(lied.trustNotice == "Cloud lists a different key for this Mac than the one this Mac holds. Compare codes only with the code this Mac shows here.")
        await f.server.setOwnKeyShown(nil)
        // The list cannot be read (a locked keychain, a re-signed build): said in plain words, this Mac still shows
        // its OWN code (from the key it holds), and no device can be trusted from a sheet.
        let blind = try CloudAccountFixture.make()
        await blind.server.setOthers([device(Self.idA, "MacBook Air", stranger.jwk)])
        blind.trustSlot.breakReads(true)
        _ = try await blind.signin()
        let state = await blind.account.state()
        #expect(state.trustNotice == "This Mac cannot read its list of trusted devices; changes from other devices are waiting.")
        let blindOwn = try #require(state.trust.first(where: { $0.standing == .thisMac }))
        let registered = try await blind.identity.deviceRegistration()
        #expect(blindOwn.code == BackendCloudDeviceCode.code(deviceId: registered.deviceId, key: registered.signPublicJwk)?.code)
        let waitingRow = try #require(state.trust.first(where: { $0.deviceId == Self.idA }))
        #expect(waitingRow.code != nil)
        #expect(!waitingRow.canBeTrusted)
        #expect(BackendCloudTrustCapture(row: waitingRow) == nil)
    }
    @Test func twoDevicesWithTheSameKeyCannotBeTrusted() async throws {
        // Sync trust core review, hand-back 2: with one key on two devices a signature cannot say which of them made
        // a pack. The codes differ (the id is part of the code), so the same-code alarm alone would miss it.
        let shared = key(), mine = key()
        let rows = BackendCloudTrustRows.build(devices: [device(Self.idA, "MacBook Air", shared.jwk), device(Self.idB, "Mac Studio", shared.jwk)],
                                               list: nil, thisDeviceId: nil)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy({ $0.sameKey && !$0.canBeTrusted }))
        #expect(rows.allSatisfy({ BackendCloudTrustCapture(row: $0) == nil }))
        #expect(rows.first?.code != rows.last?.code)
        // The list refuses whoever calls it: a twin already stored, a twin ticked beside it, a twin only the newest
        // device list shows, and this Mac's own identity arriving with a key another device already has.
        let slot = CloudTrustFixtureSlot()
        let store = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        let first = try capture(Self.idA, "MacBook Air", shared.jwk)
        let twinCode = try #require(BackendCloudDeviceCode.code(deviceId: Self.idB, keyId: first.keyId))
        let twin = BackendCloudTrustCapture(deviceId: Self.idB, name: "Mac Studio", signKey: shared.jwk, keyId: first.keyId, code: twinCode)
        await #expect(throws: BackendCloudTrustRefusal.sameKey) { try await store.trust([first, twin], restore: true, latest: nil) }
        #expect(slot.writes() == 0)
        let alarmed = CloudDeviceTrustRow(deviceId: Self.idA, name: "MacBook Air", standing: .new, code: first.code, keyId: first.keyId,
                                          signKey: shared.jwk, sameKey: true)
        await #expect(throws: BackendCloudTrustRefusal.sameKey) { try await store.trust([first], restore: false, latest: [alarmed]) }
        #expect(slot.writes() == 0)
        try await store.trust([first], restore: false, latest: nil)
        await #expect(throws: BackendCloudTrustRefusal.sameKey) { try await store.trust([twin], restore: false, latest: nil) }
        let selfTwin = registration(Self.idB, shared.jwk)
        await #expect(throws: BackendCloudTrustRefusal.sameKey) { try await store.addSelf(selfTwin) }
        let list = try await store.list()
        #expect(list.devices.count == 1)
        #expect(list.devices.first?.deviceId == Self.idA)
        #expect(await store.trustedSigningKey(deviceId: Self.idB) == nil)
        // A trusted device the service no longer lists still raises the alarm on a new device that shows its key.
        let later = BackendCloudTrustRows.build(devices: [device(Self.idB, "Mac Studio", shared.jwk)], list: list, thisDeviceId: nil)
        #expect(later.first?.sameKey == true)
        #expect(later.first?.canBeTrusted == false)
        // A stored list that already holds one key twice is not used at all (everything waits).
        let mineKeyId = try #require(BackendCloudDeviceCode.keyId(mine.jwk))
        let damaged = CloudTrustFixtureSlot()
        damaged.put(try CloudWire.canonical(BackendCloudTrustedList(subject: Self.subject, revision: 2, devices: [
            .init(deviceId: Self.idA, signKey: mine.jwk, keyId: mineKeyId, name: "One", trust: "trusted", how: "click", trustedAt: 1),
            .init(deviceId: Self.idB, signKey: mine.jwk, keyId: mineKeyId, name: "Two", trust: "trusted", how: "click", trustedAt: 1)])))
        let damagedStore = BackendCloudTrustStore(subject: Self.subject, slot: damaged.port(), pressRefused: { false })
        #expect(await damagedStore.trustedSigningKey(deviceId: Self.idA) == nil)
        #expect(BackendCloudTrustRefusal.sameKey.words == "Two devices use the same key. Do not trust either.")
    }
    @Test func aFullListRefusesAPress() async throws {
        var entries: [BackendCloudTrustedList.Entry] = []
        for index in 0..<BackendCloudTrustStore.limit {
            let made = key()
            let keyId = try #require(BackendCloudDeviceCode.keyId(made.jwk))
            entries.append(.init(deviceId: String(format: "20000000-0000-4000-8000-%012x", index), signKey: made.jwk,
                                 keyId: keyId, name: "Mac \(index)", trust: "trusted", how: "click", trustedAt: 1))
        }
        let slot = CloudTrustFixtureSlot()
        slot.put(try CloudWire.canonical(BackendCloudTrustedList(subject: Self.subject, revision: 7, devices: entries)))
        let store = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        let pressed = try capture(Self.idA, "MacBook Air", key().jwk)
        await #expect(throws: BackendCloudTrustRefusal.listFull) { try await store.trust([pressed], restore: false, latest: nil) }
        let list = try await store.list()
        #expect(list.revision == 7)
        #expect(list.devices.count == BackendCloudTrustStore.limit)
        #expect(slot.writes() == 0)
        #expect(BackendCloudTrustRefusal.listFull.words == "This Mac's device list is full.")
    }

    // MARK: sign-in, sign-out, the new-Mac sheet

    @Test func signingInAddsThisMacAndSignOutKeepsTheList() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let first = try await f.trust.list()
        #expect(first.devices.count == 1)
        let mine = try #require(first.devices.first)
        #expect(mine.how == "self")
        #expect(mine.trusted)
        let rows = await f.account.state().trust
        #expect(rows.count == 1)
        #expect(rows.first?.standing == .thisMac)
        #expect(rows.first?.code == BackendCloudDeviceCode.code(deviceId: mine.deviceId, keyId: mine.keyId))
        let writes = f.trustSlot.writes()
        try await f.account.refresh()
        #expect(f.trustSlot.writes() == writes) // already there: nothing is written again
        try await f.account.signOut()
        #expect(f.trustSlot.bytes() != nil)
        let kept = try await f.trust.list()
        #expect(kept == first)
        // Signing in again is a new device: a new `self` entry. Two-Mac proof (13 Nov): sign-out removed the earlier
        // identity from the account, so it is kept on the list as stopped, no longer trusted.
        _ = try await f.signin()
        let second = try await f.trust.list()
        #expect(second.devices.count == 2)
        #expect(second.devices.allSatisfy({ $0.how == "self" }))
        #expect(second.devices.filter(\.trusted).map(\.deviceId) == [try await f.identity.deviceRegistration().deviceId])
        #expect(second.devices.contains(where: { $0.deviceId == mine.deviceId && $0.keyId == mine.keyId }))
        #expect(Set(second.devices.map({ $0.deviceId })).count == 2)
    }
    @Test func aNewMacListsEveryDeviceAndTrustsOnlyWhatIsTicked() async throws {
        let f = try CloudAccountFixture.make()
        let first = key(), second = key()
        await f.server.setOthers([device(Self.idA, "Mac Studio", first.jwk, added: 1_000), device(Self.idB, "MacBook Air", second.jwk, added: 2_000)])
        _ = try await f.signin()
        let rows = await f.account.state().trust
        let others = rows.filter({ $0.standing == .new })
        #expect(others.count == 2)
        #expect(others.allSatisfy({ $0.code != nil && $0.canBeTrusted }))
        #expect(others.first?.deviceId == Self.idA) // oldest first (security review S5)
        // Signing in trusted nobody but this Mac.
        let before = try await f.trust.list()
        #expect(before.devices.count == 1)
        #expect(before.devices.first?.how == "self")
        // The person ticks one.
        let tickedRow = try #require(others.first(where: { $0.deviceId == Self.idA }))
        let ticked = try #require(BackendCloudTrustCapture(row: tickedRow))
        try await f.account.trustDevices([ticked], restore: true)
        let after = try await f.trust.list()
        let entry = try #require(after.devices.first(where: { $0.deviceId == Self.idA }))
        #expect(entry.how == "restore")
        #expect(!after.devices.contains(where: { $0.deviceId == Self.idB }))
        let shown = await f.account.state().trust
        #expect(shown.first(where: { $0.deviceId == Self.idA })?.standing == .trusted)
        #expect(shown.first(where: { $0.deviceId == Self.idB })?.standing == .new)
    }

    @Test func newDevicesAreListedOldestFirstAndARemovedOneCannotBeTrusted_S5() throws {
        let old = key(), fresh = key(), undated = key(), gone = key()
        let idC = "10000000-0000-4000-8000-00000000000c", idD = "10000000-0000-4000-8000-00000000000d"
        let removedDevice = CloudDevice(deviceId: idD, label: "Old iMac", platform: .macos, appVersion: "fixture", status: .revoked, secretsApproved: false,
                                        lastSeenAt: 0, signPublicJwk: gone.jwk, wrapPublicJwk: gone.jwk, registeredAt: 500)
        // An intruder's fresh devices can never push the person's own older Macs down the list.
        let rows = BackendCloudTrustRows.build(devices: [device(Self.idB, "Fresh", fresh.jwk, added: 9_000), device(idC, "Undated", undated.jwk),
                                                         device(Self.idA, "Old Mac", old.jwk, added: 1_000), removedDevice],
                                               list: nil, thisDeviceId: nil)
        let order = rows.map { $0.deviceId }
        #expect(order == [idD, Self.idA, Self.idB, idC])
        // A device Cloud reports as removed is shown as such: no sheet can offer it and a press for it stores nothing.
        let removedRow = try #require(rows.first(where: { $0.deviceId == idD }))
        #expect(removedRow.removed)
        #expect(removedRow.code != nil)
        #expect(!removedRow.canBeTrusted)
        #expect(BackendCloudTrustCapture(row: removedRow) == nil)
        let liveRow = try #require(rows.first(where: { $0.deviceId == Self.idA }))
        #expect(!liveRow.removed)
        #expect(liveRow.canBeTrusted)
    }
    @Test func aDeviceRemovedSinceTheSheetWasDrawnCancelsThePress_S5() async throws {
        let slot = CloudTrustFixtureSlot()
        let store = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        let made = key()
        let drawn = try capture(Self.idA, "MacBook Air", made.jwk)
        // The device list read at the press shows the same device and key, now reported as removed.
        let gone = CloudDevice(deviceId: Self.idA, label: "MacBook Air", platform: .macos, appVersion: "fixture", status: .revoked, secretsApproved: false,
                               lastSeenAt: 0, signPublicJwk: made.jwk, wrapPublicJwk: made.jwk, registeredAt: nil)
        let latest = BackendCloudTrustRows.build(devices: [gone], list: nil, thisDeviceId: nil)
        await #expect(throws: BackendCloudTrustRefusal.listChanged) { try await store.trust([drawn], restore: false, latest: latest) }
        let after = try await store.list()
        #expect(after.devices.isEmpty)
    }
    @Test func codesThatBeginOrEndAlikeAreMarked_S5() {
        func row(_ id: String, _ code: String?) -> CloudDeviceTrustRow {
            CloudDeviceTrustRow(deviceId: id, name: "Mac", standing: .new, code: code, keyId: nil, signKey: nil)
        }
        let idC = "10000000-0000-4000-8000-00000000000c", idD = "10000000-0000-4000-8000-00000000000d"
        // The real Mac, an intruder's device made to match its first and last group, and an unrelated device.
        let real = row(Self.idA, "4F2A 91C3 B07E 55D1 8A2C")
        let mimic = row(Self.idB, "4F2A 0000 1111 2222 8A2C")
        let other = row(idC, "0D11 91C3 B07E 55D1 77AB")
        let unreadable = row(idD, nil)
        let marked = BackendCloudTrustRows.lookAlike([real, mimic, other, unreadable])
        #expect(marked == [Self.idA, Self.idB])
        // Only the last group alike is enough; the middle groups alone are not.
        let tail = row(Self.idB, "1111 2222 3333 4444 8A2C")
        let byTail = BackendCloudTrustRows.lookAlike([real, tail])
        #expect(byTail == [Self.idA, Self.idB])
        #expect(BackendCloudTrustRows.lookAlike([real, other]).isEmpty)
        // The very same code on two devices is the same-code alarm's case, not this one.
        let twin = row(Self.idB, "4F2A 91C3 B07E 55D1 8A2C")
        #expect(BackendCloudTrustRows.lookAlike([real, twin]).isEmpty)
    }
    @Test func aListThatDidNotHoldTheComparedKeyIsSaidOnThePage_syncS8() async throws {
        let f = try CloudAccountFixture.make()
        let made = key()
        await f.server.setOthers([device(Self.idA, "MacBook Air", made.jwk)])
        _ = try await f.signin()
        let rows = await f.account.state().trust
        let row = try #require(rows.first(where: { $0.deviceId == Self.idA }))
        let drawn = try #require(BackendCloudTrustCapture(row: row))
        // The sync core answers `versionChanged`: this Mac's list did not hold exactly the key the person compared.
        await f.outbox.setListAlarm(true)
        try await f.account.trustDevices([drawn])
        let alarmed = await f.account.state()
        #expect(alarmed.trustNotice == BackendCloudAccount.listNotAsCompared)
        // It stays for this run, also after the next look at Cloud.
        await f.outbox.setListAlarm(false)
        try await f.account.refresh()
        let later = await f.account.state()
        #expect(later.trustNotice == BackendCloudAccount.listNotAsCompared)
    }
    @Test func aQuietTrustLeavesNoAlarm_syncS8() async throws {
        let f = try CloudAccountFixture.make()
        let made = key()
        await f.server.setOthers([device(Self.idA, "MacBook Air", made.jwk)])
        _ = try await f.signin()
        let rows = await f.account.state().trust
        let row = try #require(rows.first(where: { $0.deviceId == Self.idA }))
        let drawn = try #require(BackendCloudTrustCapture(row: row))
        try await f.account.trustDevices([drawn])
        let after = await f.account.state()
        #expect(after.trustNotice == nil)
    }

    @Test func onlyAPressInThisMacsWindowConfirmsTheDevicesThisMacTakesChangesFrom_laneA2FirstArrival() async throws {
        // Lane A2 asks this before an agent that is new to this Mac arrives with its project and seat.
        let slot = CloudTrustFixtureSlot()
        let store = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        let mine = key(), other = key(), third = key()
        let idC = "10000000-0000-4000-8000-00000000000c"
        #expect(await store.hasDeviceTrustedByPress() == false) // an empty list
        // This Mac's own identity is on the list without any press: it never counts.
        try await store.addSelf(registration(Self.idA, mine.jwk))
        #expect(await store.hasDeviceTrustedByPress() == false)
        // The trust sheet's press counts ...
        try await store.trust([try capture(Self.idB, "MacBook Air", other.jwk)], restore: false, latest: nil)
        #expect(await store.hasDeviceTrustedByPress() == true)
        // ... and so does the new-Mac sheet's, on a list of its own.
        let fresh = CloudTrustFixtureSlot()
        let restored = BackendCloudTrustStore(subject: Self.subject, slot: fresh.port(), pressRefused: { false })
        try await restored.trust([try capture(idC, "Mac Studio", third.jwk)], restore: true, latest: nil)
        #expect(await restored.hasDeviceTrustedByPress() == true)
        // A press that was refused stores nothing, so it confirms nothing.
        let refusedSlot = CloudTrustFixtureSlot()
        let refusing = BackendCloudTrustStore(subject: Self.subject, slot: refusedSlot.port(), pressRefused: { true })
        let pressed = try capture(Self.idB, "MacBook Air", other.jwk)
        await #expect(throws: BackendCloudTrustRefusal.remoteInput) { try await refusing.trust([pressed], restore: false, latest: nil) }
        #expect(await refusing.hasDeviceTrustedByPress() == false)
        // A list that cannot be read answers "could not read" (nil), never "not confirmed" (lane A2 review).
        let blind = CloudTrustFixtureSlot()
        blind.put(slot.bytes()); blind.breakReads(true)
        let unreadable = BackendCloudTrustStore(subject: Self.subject, slot: blind.port(), pressRefused: { false })
        #expect(await unreadable.hasDeviceTrustedByPress() == nil)
    }

    @Test func aStoppedEntryGivesNoKey() async throws {
        let slot = CloudTrustFixtureSlot()
        let store = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        let made = key(), halted = key()
        #expect(await store.trustedSigningKey(deviceId: Self.idA) == nil) // unknown: its packs wait
        let pressed = try capture(Self.idA, "MacBook Air", made.jwk)
        try await store.trust([pressed], restore: false, latest: nil)
        #expect(await store.trustedSigningKey(deviceId: Self.idA) == made.jwk)
        #expect(await store.trustedSigningKey(deviceId: Self.idB) == nil)
        // A stopped entry gives no key.
        let haltedKeyId = try #require(BackendCloudDeviceCode.keyId(halted.jwk))
        let stopped = CloudTrustFixtureSlot()
        stopped.put(try CloudWire.canonical(BackendCloudTrustedList(subject: Self.subject, revision: 3, devices: [
            .init(deviceId: Self.idB, signKey: halted.jwk, keyId: haltedKeyId, name: "Old Mac", trust: "stopped", how: "click", trustedAt: 1, stoppedAt: 2, stopReason: "person")])))
        let stoppedStore = BackendCloudTrustStore(subject: Self.subject, slot: stopped.port(), pressRefused: { false })
        #expect(await stoppedStore.trustedSigningKey(deviceId: Self.idB) == nil)
        // A list that cannot be read gives no key for anyone.
        let blind = CloudTrustFixtureSlot()
        blind.put(slot.bytes()); blind.breakReads(true)
        #expect(await BackendCloudTrustStore(subject: Self.subject, slot: blind.port(), pressRefused: { false }).trustedSigningKey(deviceId: Self.idA) == nil)
    }
    @Test func aTrustPressReleasesWithTheCapturedKeyAndThePageShowsWhatWaits() async throws {
        let f = try CloudAccountFixture.make()
        let first = key(), second = key(), third = key()
        let idC = "10000000-0000-4000-8000-00000000000c"
        await f.server.setOthers([device(Self.idA, "MacBook Air", first.jwk), device(Self.idB, "Mac Studio", second.jwk), device(idC, "iMac", third.jwk)])
        await f.outbox.setHeld([.init(deviceId: Self.idA, firstHeldSeq: CloudSequence(3), firstHeldSecretsSeq: nil, packs: 2, operations: 14,
                                      byDomain: [.init(domain: "brain/memory/i01", packs: 2, operations: 14)], firstSeenAt: 1, counting: false)])
        await f.outbox.setRefused([.init(sequence: CloudSequence(9), storageClass: .brain, deviceId: Self.idB, reason: CloudPackVerdict.badSignature, firstAt: 1, checks: 1)])
        await f.outbox.setProbe { await f.trust.trustedSigningKey(deviceId: $0) }
        _ = try await f.signin()
        let state = await f.account.state()
        #expect(state.heldChanges == 14)
        #expect(state.refusedPacks == 1)
        let waitingRow = try #require(state.trust.first(where: { $0.deviceId == Self.idA }))
        #expect(waitingRow.waiting == 14)
        #expect(waitingRow.standing == .new)
        // The press: the entry is stored first, then the core is told with the key the sheet showed.
        let drawn = try #require(BackendCloudTrustCapture(row: waitingRow))
        try await f.account.trustDevices([drawn])
        #expect(await f.outbox.trustedKeys[Self.idA] == first.jwk)
        #expect(await f.outbox.storedWhenTold[Self.idA] == true)
        let after = await f.account.state()
        #expect(after.heldChanges == 0)
        #expect(after.trust.first(where: { $0.deviceId == Self.idA })?.standing == .trusted)
        #expect(after.trust.first(where: { $0.deviceId == Self.idA })?.waiting == 0)
        // Several ticked together are one release pass.
        let rowB = try #require(after.trust.first(where: { $0.deviceId == Self.idB }))
        let rowC = try #require(after.trust.first(where: { $0.deviceId == idC }))
        let tickB = try #require(BackendCloudTrustCapture(row: rowB))
        let tickC = try #require(BackendCloudTrustCapture(row: rowC))
        try await f.account.trustDevices([tickB, tickC], restore: true)
        #expect(await f.outbox.released == [[Self.idB, idC]])
        // "Check again" judges every refused pack afresh; it trusts nobody.
        let listed = try await f.trust.list()
        try await f.account.sync(action: "check")
        #expect(await f.outbox.checkCalls == 1)
        #expect(await f.outbox.checkedEverything)
        let checked = await f.account.state()
        #expect(checked.refusedPacks == 0)
        let unchanged = try await f.trust.list()
        #expect(unchanged == listed)
    }
    @Test func aPressThatIsCancelledTellsTheSyncCoreNothing() async throws {
        let f = try CloudAccountFixture.make()
        let shown = key(), swapped = key()
        await f.server.setOthers([device(Self.idA, "MacBook Air", shown.jwk)])
        _ = try await f.signin()
        let rows = await f.account.state().trust
        let row = try #require(rows.first(where: { $0.deviceId == Self.idA }))
        let drawn = try #require(BackendCloudTrustCapture(row: row))
        await f.server.setOthers([device(Self.idA, "MacBook Air", swapped.jwk)])
        await #expect(throws: BackendCloudTrustRefusal.listChanged) { try await f.account.trustDevices([drawn]) }
        f.remoteInput.set(true)
        await #expect(throws: BackendCloudTrustRefusal.remoteInput) { try await f.account.trustDevices([drawn]) }
        #expect(await f.outbox.trustedKeys.isEmpty)
        #expect(await f.outbox.released.isEmpty)
    }

    // MARK: no tool can trust

    @Test func noToolSchemaCarriesATrustActionAndAToolCallChangesNoTrust() async throws {
        let f = try CloudAccountFixture.make()
        let stranger = key()
        await f.server.setOthers([device(Self.idA, "MacBook Air", stranger.jwk)])
        _ = try await f.signin()
        for tool in try BackendCloudAccountTools.definitions() {
            #expect(!tool.id.lowercased().contains("trust"))
            #expect(!tool.inputSchema.compact.lowercased().contains("trust"))
            #expect(!tool.inputSchema.compact.contains("deviceId"))
        }
        let before = try await f.trust.list()
        let writes = f.trustSlot.writes()
        let server = BackendNativeMCPServer()
        let entries = try await BackendCloudAccountTools.registrations(service: f.account, now: f.clock.now(), signin: { _ in })
        try await server.replaceTools(ownerID: BackendCloudAccountTools.owner, tools: entries)
        let endpoint = try await server.start()
        let token = String(repeating: "e", count: 64)
        let granted = Set(BackendCloudAccountTools.ids + BackendCloudAccountTools.ids.map { $0.replacingOccurrences(of: ".", with: "_") })
        let registration = try await server.register(token: token, grant: .init(attended: true, allowedTools: granted, allowedTiers: [.read, .act, .alter]))
        try await server.bind(registration, sessionID: "fixture-trust", machineID: "fixture-machine")
        let attempts: [NativeRPCValue] = [
            .object([]),
            .object([.init("action", .string("trust")), .init("deviceId", .string(Self.idA))]),
            .object([.init("action", .string("retry")), .init("trust", .array([.string(Self.idA)]))]),
            .object([.init("deviceId", .string(Self.idA)), .init("trust", .bool(true)), .init("standing", .string("trusted"))])
        ]
        // Sign-out last: it ends the session these calls run in.
        for name in ["cloud_status", "cloud_devices", "cloud_sync", "cloud_signin", "cloud_signout"] {
            for arguments in attempts {
                _ = try? await rpc(endpoint.url, token: token, method: "tools/call", params: .object([.init("name", .string(name)), .init("arguments", arguments)]))
            }
        }
        await server.stop()
        let after = try await f.trust.list()
        #expect(after == before)
        #expect(f.trustSlot.writes() == writes)
        #expect(!after.devices.contains(where: { $0.deviceId == Self.idA }))
        #expect(await f.trust.trustedSigningKey(deviceId: Self.idA) == nil)
    }
    private func rpc(_ url: URL, token: String, method: String, params: NativeRPCValue) async throws -> NativeRPCValue {
        guard url.host == "127.0.0.1" || url.host == "localhost" else { throw CloudFailure.unsafeConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", .number(1)), .init("method", .string(method)), .init("params", params)]).encodedJSON()
        let (data, _) = try await URLSession.shared.data(for: request)
        return try NativeRPCValue.parseJSON(data)
    }

    // MARK: the kind of device kept with the key (PASSWORDS-2 review, notePlatforms)

    /// The installed build's (43a62d07) entry and list shape, exactly: no `platform` field.
    private struct InstalledEntry: Codable, Equatable {
        let deviceId: String; let signKey: CloudPublicJWK; let keyId: String; let name: String; let trust: String; let how: String
        let trustedAt: Int64; let stoppedAt: Int64?; let stopReason: String?
    }
    private struct InstalledList: Codable, Equatable {
        let v: Int; let subject: CloudSubject; let revision: Int; let devices: [InstalledEntry]
    }
    private func trustRow(_ id: String, keyId: String?, key: CloudPublicJWK?, platform: CloudPlatform?, keyChanged: Bool = false) -> CloudDeviceTrustRow {
        .init(deviceId: id, name: "Fixture", standing: .trusted, code: nil, keyId: keyId, signKey: key, keyChanged: keyChanged, platform: platform)
    }

    @Test func aMissingKindIsFilledOnceAndOnlyFromTheSameKey() async throws {
        let a = key(), b = key(), c = key(), other = key()
        let idC = "10000000-0000-4000-8000-00000000000c"
        let keyA = try #require(BackendCloudDeviceCode.keyId(a.jwk)), keyB = try #require(BackendCloudDeviceCode.keyId(b.jwk))
        let keyC = try #require(BackendCloudDeviceCode.keyId(c.jwk)), keyOther = try #require(BackendCloudDeviceCode.keyId(other.jwk))
        // A list as the installed build writes it: three entries, none with a kind.
        let installed = InstalledList(v: 1, subject: Self.subject, revision: 4, devices: [
            .init(deviceId: Self.idA, signKey: a.jwk, keyId: keyA, name: "Mac mini", trust: "trusted", how: "account", trustedAt: 1, stoppedAt: nil, stopReason: nil),
            .init(deviceId: Self.idB, signKey: b.jwk, keyId: keyB, name: "MacBook", trust: "trusted", how: "click", trustedAt: 2, stoppedAt: nil, stopReason: nil),
            .init(deviceId: idC, signKey: c.jwk, keyId: keyC, name: "iPhone", trust: "trusted", how: "account", trustedAt: 3, stoppedAt: nil, stopReason: nil)])
        let slot = CloudTrustFixtureSlot()
        slot.put(try CloudWire.canonical(installed))
        let store = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        // A list written without the field still reads; every kind is missing.
        let read = try await store.list()
        #expect(read.devices.count == 3)
        #expect(read.devices.allSatisfy { $0.platform == nil })
        // A listed key that differs (A), or a key change (B), fills nothing; the same key (C) fills its kind.
        let filled = try await store.notePlatforms([
            trustRow(Self.idA, keyId: keyOther, key: other.jwk, platform: .macos),
            trustRow(Self.idB, keyId: keyB, key: b.jwk, platform: .macos, keyChanged: true),
            trustRow(idC, keyId: keyC, key: c.jwk, platform: .ios)])
        #expect(filled == [idC])
        var now = try await store.list()
        #expect(now.devices.first { $0.deviceId == Self.idA }?.platform == nil)
        #expect(now.devices.first { $0.deviceId == Self.idB }?.platform == nil)
        #expect(now.devices.first { $0.deviceId == idC }?.platform == "ios")
        // A row with no kind fills nothing either.
        #expect(try await store.notePlatforms([trustRow(Self.idA, keyId: keyA, key: a.jwk, platform: nil)]).isEmpty)
        // A kind once kept never changes, even when the service later says "macos" for the same key.
        let writes = slot.writes()
        #expect(try await store.notePlatforms([trustRow(idC, keyId: keyC, key: c.jwk, platform: .macos)]).isEmpty)
        #expect(slot.writes() == writes)
        now = try await store.list()
        #expect(now.devices.first { $0.deviceId == idC }?.platform == "ios")
        // Nothing else of an entry moves when its kind is filled.
        let entryC = try #require(now.devices.first { $0.deviceId == idC })
        #expect(entryC.signKey == c.jwk && entryC.keyId == keyC && entryC.name == "iPhone" && entryC.how == "account" && entryC.trustedAt == 3)
        // The list THIS build wrote still reads with the installed build's shape (its decoder ignores `platform`),
        // with every entry as it was.
        let bytes = try #require(slot.bytes())
        #expect(String(decoding: bytes, as: UTF8.self).contains("\"platform\":\"ios\""))
        let old = try CloudWire.decode(InstalledList.self, from: bytes, maximumBytes: 409_600)
        #expect(old.v == 1 && old.subject == Self.subject && old.revision == installed.revision + 1)
        #expect(old.devices == installed.devices)
        #expect(old.devices.allSatisfy { BackendCloudDeviceCode.keyId($0.signKey) == $0.keyId })
        // A fresh store (a restart) reads the same kinds back.
        let again = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        #expect(try await again.list().devices.map(\.platform) == [nil, nil, "ios"])
    }

    // MARK: where the list lives

    @Test func theListHasAKeychainSlotOfItsOwnPerCopyDataFolderAndAccount() {
        let real = BackendCloudTrustSlot.names(appName: BackendSharedBrand.name, instanceId: "instance-1", subjectHash: "subject-1")
        let dev = BackendCloudTrustSlot.names(appName: BackendDevCopy.name, instanceId: "instance-1", subjectHash: "subject-1")
        #expect(real.account == "trusted:instance-1:subject-1")
        #expect(real.service == BackendSharedBrand.name + " Cloud Trust")
        // The dev copy's item is its own: it can never read or replace the real app's list.
        #expect(dev.service == BackendDevCopy.name + " Cloud Trust")
        #expect(dev.service != real.service)
        // Not one of the services any other feature uses.
        #expect(!BackendDevCopy.keychainServices(appName: BackendSharedBrand.name).contains(real.service))
        #expect(!BackendDevCopy.keychainServices(appName: BackendDevCopy.name).contains(dev.service))
        // Another data folder or another account is another item.
        #expect(BackendCloudTrustSlot.names(appName: BackendSharedBrand.name, instanceId: "instance-2", subjectHash: "subject-1").account != real.account)
        #expect(BackendCloudTrustSlot.names(appName: BackendSharedBrand.name, instanceId: "instance-1", subjectHash: "subject-2").account != real.account)
    }
}
