import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// MAC-NEXT-11. (1) The MacBook settled five earlier entries at 08:17; after the rename at 18:26 one of them came back
/// as a fourth device. A settled entry stays settled; only a device that signs something new may return, by the normal
/// trust path. (2) A phone or a browser is a viewer: never "catching up", never waited on, a calm "signed in" notice.
@Suite("Cloud MAC-NEXT-11 — settled entries stay settled; phones and browsers are viewers")
struct CloudSettledEntriesAndViewersTests {
    static let subject = CloudSubject(issuer: "https://identity.test", sub: "11111111-1111-4111-8111-111111111111")
    static let book = "40000000-0000-4000-8000-000000000000"
    static let stale = (1...5).map { "4000000\($0)-0000-4000-8000-000000000000" }
    static let hour: Int64 = 3_600_000
    static let t0817: Int64 = 1_794_000_000_000
    static let t0503 = t0817 - 3 * hour - 14 * 60_000
    static let t1826 = t0817 + 10 * hour + 9 * 60_000

    static func jwk(_ key: P256.Signing.PrivateKey) -> CloudPublicJWK {
        let point = key.publicKey.x963Representation
        return CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])),
                              y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
    }
    final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var time: Int64
        init(_ time: Int64) { self.time = time }
        func now() -> Int64 { lock.withLock { time } }
        func set(_ value: Int64) { lock.withLock { time = value } }
    }
    struct World {
        let keys: [String: CloudPublicJWK]
        let trust: BackendCloudTrustStore
        let clock: Clock
        func device(_ id: String, added: Int64, seen: Int64, display: String? = nil, platform: CloudPlatform = .macos, role: String? = nil,
                    label: String = "asads-macbook-pro-21.local") -> CloudDevice {
            var made = CloudDevice(deviceId: id, label: label, platform: platform, appVersion: "0.22", status: .active, secretsApproved: false,
                                   lastSeenAt: seen, signPublicJwk: keys[id]!, wrapPublicJwk: keys[id]!, registeredAt: added)
            made.displayName = display; made.role = role
            return made
        }
        func active(_ devices: [CloudDevice]) -> [String: String] {
            Dictionary(devices.map { ($0.deviceId, BackendCloudDeviceCode.keyId($0.signPublicJwk)!) }, uniquingKeysWith: { a, _ in a })
        }
    }
    static func world() throws -> World {
        var keys: [String: CloudPublicJWK] = [:]
        for id in [book] + stale { keys[id] = jwk(P256.Signing.PrivateKey()) }
        let entries = ([book] + stale).map {
            BackendCloudTrustedList.Entry(deviceId: $0, signKey: keys[$0]!, keyId: BackendCloudDeviceCode.keyId(keys[$0]!)!, name: "asads-macbook-pro-21.local",
                                          trust: "trusted", how: $0 == book ? "self" : "click", trustedAt: 1)
        }
        let slot = CloudTrustFixtureSlot()
        slot.put(try CloudWire.canonical(BackendCloudTrustedList(subject: subject, revision: 1, devices: entries)))
        let clock = Clock(t0817)
        return World(keys: keys, trust: BackendCloudTrustStore(subject: subject, slot: slot.port(), now: { clock.now() }, pressRefused: { false }), clock: clock)
    }

    // His exact sequence: five earlier entries settled at 08:17; the live entry gets a friendly name at 18:26 and the
    // newer entry the last one was matched to leaves the list; nothing comes back.
    @Test func settledEntriesStaySettledAfterTheRename() async throws {
        let w = try Self.world()
        // 08:17: the live MacBook entry (registered 02:21) and a newer sign-in (06:00) the 5:03 entry was matched to.
        let newer = "40000009-0000-4000-8000-000000000000"
        var keys = w.keys; keys[newer] = Self.jwk(P256.Signing.PrivateKey())
        let world = World(keys: keys, trust: w.trust, clock: w.clock)
        let morning = [world.device(Self.book, added: Self.t0817 - 6 * Self.hour, seen: Self.t0817)]
            + Self.stale.dropLast().enumerated().map { i, id in world.device(id, added: 1_000 + Int64(i), seen: Self.t0817 - 7 * Self.hour) }
            + [world.device(Self.stale.last!, added: 900, seen: Self.t0503), world.device(newer, added: Self.t0817 - 2 * Self.hour - 1, seen: Self.t0817 - 2 * Self.hour)]
        let staleAt0817 = BackendCloudTrustRows.stale(devices: morning, thisDeviceId: Self.book, now: Self.t0817)
        #expect(Set(Self.stale).isSubset(of: staleAt0817))
        let first = try await world.trust.settleStale(staleAt0817.intersection(Self.stale), activeKeys: world.active(morning), thisDeviceId: Self.book)
        #expect(Set(first.stopped) == Set(Self.stale))

        // 18:26: the newer entry is retired (not listed), the live entry has its friendly name, the 5:03 entry is listed.
        world.clock.set(Self.t1826)
        let evening = [world.device(Self.book, added: Self.t0817 - 6 * Self.hour, seen: Self.t1826, display: "Asad's MacBook Pro"),
                       world.device(Self.stale.last!, added: 900, seen: Self.t0503)]
        // Even the old rule alone (no quiet window) finds nothing stale now: the settled entry still never comes back.
        #expect(BackendCloudTrustRows.stale(devices: evening, thisDeviceId: Self.book).isEmpty)
        for automatic in [true, false] {
            let again = try await world.trust.settleStale([], activeKeys: world.active(evening), thisDeviceId: Self.book, automatic: automatic)
            #expect(again.restored.isEmpty)
        }
        #expect(await world.trust.trustedSigningKey(deviceId: Self.stale.last!) == nil)
        let rows = BackendCloudTrustRows.build(devices: evening, list: try await world.trust.list(), thisDeviceId: Self.book,
                                               thisKey: world.keys[Self.book], markKeyChanges: true, now: Self.t1826)
        #expect(rows.filter { !$0.stale }.map(\.deviceId) == [Self.book])
        #expect(rows.first { $0.deviceId == Self.book }?.name == "Asad's MacBook Pro")
        // The matching uses the recorded host name: the 5:03 entry is stale by the quiet window, not by the friendly name.
        #expect(BackendCloudTrustRows.stale(devices: evening, thisDeviceId: Self.book, now: Self.t1826) == [Self.stale.last!])
        // Automatic trust never adds it back either.
        #expect(try await world.trust.trustByAccount(rows).isEmpty)
    }

    // Two phones both called "iPhone" are two phones: the 2-hour quiet window never sets a viewer aside. A Mac pair
    // with the same history still is.
    @Test func theQuietWindowNeverSetsAViewerAside() throws {
        let w = try Self.world()
        let now = Self.t1826, older = Self.stale[0], newer = Self.stale[1]
        for (platform, expected) in [(CloudPlatform.ios, Set<String>()), (.android, []), (.web, []), (.macos, [older])] {
            let label = platform == .macos ? "asads-macbook-pro-21.local" : "iPhone"
            let devices = [w.device(Self.book, added: 1, seen: now),
                           w.device(older, added: 10, seen: now - 3 * Self.hour, platform: platform, label: label),
                           w.device(newer, added: 20, seen: now, platform: platform, label: label)]
            #expect(BackendCloudTrustRows.stale(devices: devices, thisDeviceId: Self.book, now: now) == expected, "\(platform)")
        }
    }

    // The entry the older build trusted again (no stop reason left) is settled again on the next launch by itself.
    @Test func theWronglyRestoredEntryIsSettledAgain() async throws {
        let w = try Self.world()
        w.clock.set(Self.t1826 + Self.hour)
        let evening = [w.device(Self.book, added: Self.t0817 - 6 * Self.hour, seen: Self.t1826, display: "Asad's MacBook Pro"),
                       w.device(Self.stale.last!, added: 900, seen: Self.t0503)]
        let stale = BackendCloudTrustRows.stale(devices: evening, thisDeviceId: Self.book, now: w.clock.now())
        let settled = try await w.trust.settleStale(stale, activeKeys: w.active(evening), thisDeviceId: Self.book)
        #expect(settled.stopped == [Self.stale.last!])
        let rows = BackendCloudTrustRows.build(devices: evening, list: try await w.trust.list(), thisDeviceId: Self.book,
                                               thisKey: w.keys[Self.book], markKeyChanges: true, now: w.clock.now())
        #expect(rows.filter { !$0.stale }.map(\.deviceId) == [Self.book])
        // Its card is gone from Your Cloud too.
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: CloudGate(features: ["cloud"], storageEntitled: true), displayName: "Owner",
                                            devices: evening, trust: rows, cloudHead: CloudSequence(3), fetched: CloudSequence(3))
        let window = try #require(BackendCloudContentsBuilder.build(contents: CloudSyncContents(thisDevice: Self.book, items: [], packs: []),
                                                                    snapshot: snapshot, now: w.clock.now())).model
        #expect(window.devices.map(\.name) == ["Asad's MacBook Pro"])
    }

    // A settled device that really signs a new pack later follows the normal trust path.
    @Test func aSettledDeviceThatSignsSomethingNewComesBackByTheNormalPath() async throws {
        let w = try Self.world()
        let id = Self.stale[0]
        _ = try await w.trust.settleStale([id], activeKeys: w.active([w.device(id, added: 1, seen: 2)]), thisDeviceId: Self.book)
        let stoppedAt = w.clock.now()
        let listed = [w.device(Self.book, added: 10, seen: Self.t1826), w.device(id, added: 1, seen: Self.t1826)]
        // A pack it signed BEFORE the settling proves nothing.
        #expect(try await w.trust.settleStale([], activeKeys: w.active(listed), thisDeviceId: Self.book, alive: [id: stoppedAt - 1]).restored.isEmpty)
        // "Ask me": shown for the person's press (a new row), never trusted by itself.
        let fresh = [id: stoppedAt + 60_000]
        #expect(try await w.trust.settleStale([], activeKeys: w.active(listed), thisDeviceId: Self.book, alive: fresh, automatic: false).restored.isEmpty)
        let asked = BackendCloudTrustRows.build(devices: listed, list: try await w.trust.list(), thisDeviceId: Self.book, thisKey: w.keys[Self.book],
                                                now: Self.t1826, alive: fresh)
        #expect(asked.first { $0.deviceId == id }.map { !$0.stale && $0.standing == .new } == true)
        // Automatic trust: its stored key, and only that, is trusted again.
        #expect(try await w.trust.settleStale([], activeKeys: w.active(listed), thisDeviceId: Self.book, alive: fresh).restored == [id])
        #expect(await w.trust.trustedSigningKey(deviceId: id) == w.keys[id])
    }

    // Phones and browsers: a card with what it is and when it was last seen; never catching up; a calm notice.
    @Test func viewersAreNeverCatchingUpAndJoinCalmly() throws {
        let w = try Self.world()
        let now = Self.t1826
        let mini = Self.stale[0], phone = Self.stale[1], browser = Self.stale[2]
        var devices = [w.device(Self.book, added: 1, seen: now, display: "Asad's MacBook Pro"),
                       w.device(mini, added: 1, seen: now - 60_000, display: "Asad's Mac mini", label: "imatch-mac-mini.local"),
                       w.device(phone, added: 1, seen: now - 3_600_000, display: "TD iPhone", platform: .ios, role: "viewer", label: "TD iPhone"),
                       w.device(browser, added: 1, seen: now - 120_000, display: "Web", platform: .web, role: "viewer", label: "Web")]
        devices[1].lastPulledSeq = CloudSequence(10); devices[1].lastPulledAt = now - 10_000
        devices[2].lastPulledSeq = CloudSequence(1)
        let rows = [CloudDeviceTrustRow(deviceId: Self.book, name: "Asad's MacBook Pro", standing: .thisMac, code: nil, keyId: nil, signKey: nil),
                    CloudDeviceTrustRow(deviceId: mini, name: "Asad's Mac mini", standing: .trusted, code: nil, keyId: nil, signKey: nil),
                    CloudDeviceTrustRow(deviceId: phone, name: "TD iPhone", standing: .trusted, code: nil, keyId: nil, signKey: nil, byAccount: true),
                    CloudDeviceTrustRow(deviceId: browser, name: "Web", standing: .trusted, code: nil, keyId: nil, signKey: nil, byAccount: true)]
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: CloudGate(features: ["cloud"], storageEntitled: true), displayName: "Owner",
                                            devices: devices, trust: rows, cloudHead: CloudSequence(10), fetched: CloudSequence(10))
        let note = CloudSyncContents.Key(domain: "brain/memory/i01", sourceId: "memory/I01", recordId: "file/notes/a.md", projectId: nil)
        let contents = CloudSyncContents(thisDevice: Self.book, items: [.init(key: note, changes: [.init(deviceId: Self.book, at: now - 300_000)],
                                                                              standing: .inCloud, seq: CloudSequence(9))], packs: [])
        let window = try #require(BackendCloudContentsBuilder.build(contents: contents, snapshot: snapshot, now: now)).model
        #expect(window.devices.first { $0.name == "TD iPhone" }?.state == "Phone")
        #expect(window.devices.first { $0.name == "Web" }?.state == "Browser")
        #expect(window.devices.first { $0.name == "TD iPhone" }?.lastSeen == now - 3_600_000)
        #expect(window.catchingUp == nil)
        #expect(!window.items.flatMap(\.presence).contains { $0.contains("TD iPhone") || $0.contains("Web") })
        var input = BackendCloudOverviewInput(snapshot: snapshot, memory: .init(included: true))
        input.automaticTrust = true
        input.joined = [phone, mini]
        let overview = try #require(BackendCloudOverviewBuilder.build(input))
        #expect(overview.notices.contains { $0.text == "“TD iPhone” signed in to your account." })
        #expect(!overview.notices.contains { $0.text.contains("TD iPhone") && $0.text.contains("trust") })
    }
}
