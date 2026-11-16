import Foundation
import CryptoKit
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Owner, 15 Nov: "I need every single thing in cloud ... and in everywhere": saved passwords and secret files show in
/// his browser too (design: macos/night/codex/passwords-in-browser-design.md, C3). The Mac answers a browser of his
/// account (platform web) like one of his phones, but as its own kind: same signed request, once per key generation,
/// "Ask me on each new device" makes it wait for his click with the code, and the one switch "Keep saved passwords and
/// secret files off my phones and browsers" keeps it off. Inert until the service lets a browser ask. Fixtures only.
@Suite("Cloud saved passwords in the browser — the Mac answers a browser like a phone, as its own kind")
@MainActor
struct CloudSecretsBrowserAnswerTests {
    struct Mac {
        let client: CloudSecretsFixtureClient
        let graph: BackendCloudSecretsGraph
        let trust: AutoTrustBox
    }
    struct Asker {
        let client: CloudSecretsFixtureClient
        let trust: AutoTrustBox
        let registration: CloudDeviceRegistration
    }
    /// `pinned`: replaces what this Mac's list answers (an entry with no recorded kind).
    private func mac(_ server: CloudSecretsFixtureServer,
                     pinned: (@Sendable (String) -> CloudSecretsAutoTrust.Pinned?)? = nil) async throws -> Mac {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true)
        let auto = CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { id in pinned?(id) ?? box.pinned(id) },
            answeredBefore: { box.answeredBefore($0, $1) }, remember: { box.remember($0, $1) })
        await client.coordinator.use(automatic: auto)
        let graph = try BackendCloudSecretsGraph(recovery: client.coordinator, content: client.content, policy: client.policy,
            local: client.local, deviceId: client.device.deviceId, outbox: AutoOutbox(), stores: [],
            retainConflict: { _ in }, known: nil, restoreLocalStores: {}, turnsOnBySelf: true, deadAfter: 0, automatic: auto,
            pause: { ms in if ms > 5_000 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } })
        await graph.guardPresses { false }
        await graph.catchUp()
        return Mac(client: client, graph: graph, trust: box)
    }
    /// A device of his account that asks for the key, listed by the account as `platform`.
    private func asker(_ server: CloudSecretsFixtureServer, platform: CloudPlatform) async throws -> Asker {
        let client = try await CloudSecretsFixtureClient(server: server)
        let box = AutoTrustBox(on: true)
        await client.coordinator.use(automatic: CloudSecretsAutoTrust(on: { box.isOn() }, pinned: { box.pinned($0) }))
        let own = client.device
        let listed = CloudDeviceRegistration(deviceId: own.deviceId, label: platform == .web ? "Chrome on Mac" : "Fixture iPhone",
                                             platform: platform, appVersion: "fixture", signPublicJwk: own.signPublicJwk, wrapPublicJwk: own.wrapPublicJwk)
        await server.register(listed)
        return Asker(client: client, trust: box, registration: listed)
    }
    private func notice(_ type: String) -> CloudEvent {
        CloudEvent(v: 1, type: type, id: UUID().uuidString.lowercased(), payload: CloudValue(.object([])))
    }
    /// The Mac pins the asker with the kind given (default: as the account lists it); the asker pins the Mac.
    private func pair(_ m: Mac, _ a: Asker, recorded: CloudPlatform? = nil) {
        m.trust.trust(a.registration, name: a.registration.label, platform: recorded)
        a.trust.trust(m.client.device, name: "Studio Mac")
    }
    private func ask(_ m: Mac, _ a: Asker) async throws -> CloudApproval {
        let pending = try await a.client.coordinator.requestApproval()
        await m.graph.event(notice("approval"))
        return pending
    }

    // 1. His browser, pinned here as a browser, signed its own request: answered by itself, once per key generation,
    //    no code on either side; it opens the very key this Mac holds.
    @Test func hisBrowserIsAnsweredByItselfLikeAPhone() async throws {
        let server = CloudSecretsFixtureServer()
        let m = try await mac(server)
        let b = try await asker(server, platform: .web); pair(m, b)
        let pending = try await ask(m, b)
        #expect(await server.requestSignatures[pending.approvalId] != nil)
        #expect(await server.usedApprovals.count == 1)
        #expect(try await b.client.coordinator.receiveApproval())
        #expect(await b.client.local.value?.root == m.client.local.value?.root)
        #expect(await m.client.ui.displays.isEmpty)
        #expect(await m.client.local.book?.answered.contains { $0.hasPrefix(b.registration.deviceId.lowercased() + "@") } ?? false)
        // A second ask in the same key generation waits for his click (never a second automatic answer).
        _ = try await ask(m, b)
        #expect(await server.usedApprovals.count == 1)
    }

    // 2. The one switch "off my phones and browsers": a browser is neither answered nor offered; switched off again by
    //    his press, the waiting browser is answered.
    @Test func theSwitchKeepsThemOffBrowsersToo() async throws {
        let server = CloudSecretsFixtureServer()
        let m = try await mac(server)
        await m.graph.setPhonesOff(true)
        let b = try await asker(server, platform: .web); pair(m, b)
        _ = try await ask(m, b)
        #expect(await server.usedApprovals.isEmpty)
        #expect(await m.graph.page().approvals.isEmpty)
        await m.graph.setPhonesOff(false)
        await m.graph.event(notice("approval"))
        #expect(await server.usedApprovals.count == 1)
        #expect(BackendCloudSecretsWords.phonesOffSwitch == "Keep saved passwords and secret files off my phones and browsers")
    }

    // 3. "Ask me on each new device": a browser waits for his click, and the click shows the code to compare.
    @Test func underAskMeABrowserWaitsForHisClickWithTheCode() async throws {
        let server = CloudSecretsFixtureServer()
        let m = try await mac(server)
        _ = try await m.client.coordinator.setAskOnNewDevice(true)
        let b = try await asker(server, platform: .web); pair(m, b)
        let pending = try await ask(m, b)
        #expect(await server.usedApprovals.isEmpty)
        #expect(await m.graph.page().approvals.map(\.id) == [pending.approvalId])
        try await m.client.coordinator.approve(id: pending.approvalId)
        #expect(await m.client.ui.displays.first?.matchingCode == CloudSecretsCrypto.matchingCode(pending))
        #expect(await server.usedApprovals.count == 1)
    }

    // 4. A browser is its own kind: pinned here as a browser but listed as a phone or a Mac, or pinned as a phone and
    //    listed as a browser: never answered, never listed, the click refused.
    @Test func aBrowserNeverPassesAsAPhoneOrAMacNorTheReverse() async throws {
        for (recorded, listed) in [(CloudPlatform.web, CloudPlatform.ios), (.web, .android), (.web, .macos), (.ios, .web), (.macos, .web)] {
            let server = CloudSecretsFixtureServer()
            let m = try await mac(server)
            let a = try await asker(server, platform: listed); pair(m, a, recorded: recorded)
            let pending = try await ask(m, a)
            #expect(await server.usedApprovals.isEmpty)
            #expect(await m.graph.page().approvals.isEmpty)
            await #expect(throws: (any Error).self) { try await m.client.coordinator.approve(id: pending.approvalId) }
        }
    }

    // 5. A phone's ask behaves exactly as before: answered by itself; the switch keeps it off.
    @Test func aPhonesAskIsUnchanged() async throws {
        for platform in [CloudPlatform.ios, .android] {
            let server = CloudSecretsFixtureServer()
            let m = try await mac(server)
            let p = try await asker(server, platform: platform); pair(m, p)
            _ = try await ask(m, p)
            #expect(await server.usedApprovals.count == 1)
            #expect(try await p.client.coordinator.receiveApproval())
        }
        let server = CloudSecretsFixtureServer()
        let m = try await mac(server)
        await m.graph.setPhonesOff(true)
        let p = try await asker(server, platform: .ios); pair(m, p)
        _ = try await ask(m, p)
        #expect(await server.usedApprovals.isEmpty)
    }

    // 6. A kind this Mac did not record with the key (an entry from before kinds were kept) is refused, as today; the
    //    kinds themselves: only computer, phone and browser exist, nothing else is one.
    @Test func anUnknownKindIsRefused() async throws {
        #expect(CloudSecretsAutoTrust.kind(nil) == nil)
        #expect(CloudSecretsAutoTrust.kind(.web) == .browser && CloudSecretsAutoTrust.kind(.ios) == .phone && CloudSecretsAutoTrust.kind(.windows) == .computer)
        #expect(!CloudSecretsAutoTrust.sameKind(nil, .web) && !CloudSecretsAutoTrust.sameKind(.web, nil) && !CloudSecretsAutoTrust.sameKind(nil, nil))
        #expect(CloudSecretsAutoTrust.sameKind(.ios, .android))                                // one kind, as before
        let server = CloudSecretsFixtureServer()
        let holder = PinnedHolder()
        let m = try await mac(server, pinned: { holder.answer($0) })
        let b = try await asker(server, platform: .web)
        holder.set(b.registration.deviceId, .init(name: "Chrome on Mac", signKey: b.registration.signPublicJwk, platform: nil))
        b.trust.trust(m.client.device, name: "Studio Mac")
        let pending = try await ask(m, b)
        #expect(await server.usedApprovals.isEmpty)
        #expect(await m.graph.page().approvals.isEmpty)
        await #expect(throws: (any Error).self) { try await m.client.coordinator.approve(id: pending.approvalId) }
    }

    // 7. A removed browser leaves this Mac's trusted list 30 days after it was stopped; a removed phone or Mac never
    //    leaves, a browser stopped for another reason never leaves, a trusted browser never leaves.
    @Test func aRemovedBrowserIsPrunedAfterThirtyDays() async throws {
        let subject = CloudSubject(issuer: "https://identity.test", sub: "11111111-1111-4111-8111-111111111111")
        let day: Int64 = 86_400_000, t0: Int64 = 1_794_000_000_000
        func entry(_ n: Int, platform: CloudPlatform, trust: String, reason: String?, stoppedAt: Int64?) -> BackendCloudTrustedList.Entry {
            let key = P256.Signing.PrivateKey().publicKey.x963Representation
            let jwk = CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(key[1..<33])),
                                     y: BackendCloudAccountIdentity.base64(Data(key[33..<65])))
            return .init(deviceId: "5000000\(n)-0000-4000-8000-000000000000", signKey: jwk, keyId: BackendCloudDeviceCode.keyId(jwk)!,
                         name: "Device \(n)", trust: trust, how: "account", trustedAt: 1, stoppedAt: stoppedAt, stopReason: reason,
                         platform: platform.rawValue)
        }
        let entries = [
            entry(1, platform: .web, trust: "stopped", reason: "removed from account", stoppedAt: t0 - 31 * day),   // goes
            entry(2, platform: .web, trust: "stopped", reason: "removed", stoppedAt: t0 - 30 * day),                // goes
            entry(3, platform: .web, trust: "stopped", reason: "removed from account", stoppedAt: t0 - 29 * day),   // too soon
            entry(4, platform: .web, trust: "stopped", reason: BackendCloudTrustStore.staleReason, stoppedAt: t0 - 60 * day),
            entry(5, platform: .web, trust: "trusted", reason: nil, stoppedAt: nil),
            entry(6, platform: .ios, trust: "stopped", reason: "removed from account", stoppedAt: t0 - 60 * day),
            entry(7, platform: .macos, trust: "stopped", reason: "removed from account", stoppedAt: t0 - 60 * day),
        ]
        let slot = CloudTrustFixtureSlot()
        slot.put(try CloudWire.canonical(BackendCloudTrustedList(subject: subject, revision: 1, devices: entries)))
        let store = BackendCloudTrustStore(subject: subject, slot: slot.port(), now: { t0 }, pressRefused: { false })
        let dropped = try await store.pruneRemovedBrowsers()
        #expect(Set(dropped) == Set([entries[0].deviceId, entries[1].deviceId]))
        #expect(try await store.list().devices.map(\.deviceId) == entries[2...].map(\.deviceId))
        #expect(try await store.pruneRemovedBrowsers().isEmpty)                                // nothing more, nothing written
    }
}

/// What this Mac's list answers in test 6: an entry whose kind was never recorded.
final class PinnedHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: CloudSecretsAutoTrust.Pinned] = [:]
    func set(_ id: String, _ pinned: CloudSecretsAutoTrust.Pinned) { lock.withLock { entries[id] = pinned } }
    func answer(_ id: String) -> CloudSecretsAutoTrust.Pinned? { lock.withLock { entries[id] } }
}
