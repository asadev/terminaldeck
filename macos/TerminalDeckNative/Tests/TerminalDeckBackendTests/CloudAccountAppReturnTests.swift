import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Owner, 13 Nov: sign-in comes back through the official website to `terminaldeck://cloud/return/<token>?code&state`
/// and finishes by itself, with no sheet, but only when it answers the sign-in THIS app started. Then the account's
/// devices are trusted automatically ("Automatically, with my account"), except a device whose key changed.
@Suite("Cloud sign-in through the website, and account trust")
struct CloudAccountAppReturnTests {
    static let idA = "10000000-0000-4000-8000-00000000000a"
    static let idB = "10000000-0000-4000-8000-00000000000b"
    static let idC = "10000000-0000-4000-8000-00000000000c"

    private func key() -> CloudPublicJWK {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        return CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])),
                              y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
    }
    private func device(_ id: String, _ name: String, _ jwk: CloudPublicJWK, status: CloudDeviceStatus = .active) -> CloudDevice {
        .init(deviceId: id, label: name, platform: .macos, appVersion: "fixture", status: status, secretsApproved: false,
              lastSeenAt: 1_794_000_000_000, signPublicJwk: jwk, wrapPublicJwk: jwk, registeredAt: 1_793_000_000_000)
    }
    private struct Started { let url: URL; let token: String; let state: String }
    private func start(_ f: CloudAccountFixture) async throws -> Started {
        let url = try await f.account.beginAppSignIn()
        try await f.server.authorize(url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        return .init(url: url, token: items.first { $0.name == "callback" }!.value!, state: items.first { $0.name == "state" }!.value!)
    }
    private func signIn(_ f: CloudAccountFixture, mode: BackendCloudTrustMode) async throws {
        await f.account.setTrustMode(mode)
        let started = try await start(f)
        #expect(try await f.account.finishAppReturn(token: started.token, code: "fixture-code", state: started.state))
    }

    // MARK: the return

    @Test func theAppSignInSendsTheWebsitesParametersAndNoPort() async throws {
        let f = try CloudAccountFixture.make()
        let started = try await start(f)
        let items = URLComponents(url: started.url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(Set(items.map(\.name)) == ["challenge", "state", "callback", "platform", "device"])
        #expect(items.first { $0.name == "platform" }?.value == "macos")
        // Gap 2: the website's page names the device with the registration's own label, and nothing else.
        #expect(items.first { $0.name == "device" }?.value == "Fixture Mac")
        #expect(started.token.count == 22)
        #expect(started.state.count == 43)
        #expect(items.first { $0.name == "challenge" }?.value?.count == 43)
        #expect(await f.account.hasPendingSignIn())
    }
    @Test func theExchangeCarriesTheAppCallbackAndLoopbackIsEncodedAsBefore() throws {
        let app = String(decoding: try CloudWire.canonical(CloudHandoffExchange(code: "c", verifier: "v", callback: .app(platform: "macos", pathToken: "t"))), as: UTF8.self)
        #expect(app == #"{"callback":{"kind":"app","pathToken":"t","platform":"macos"},"code":"c","verifier":"v"}"#)
        let loopback = String(decoding: try CloudWire.canonical(CloudHandoffExchange(code: "c", verifier: "v", callback: .init(port: 49555, pathToken: "t"))), as: UTF8.self)
        #expect(loopback == #"{"callback":{"pathToken":"t","port":49555},"code":"c","verifier":"v"}"#)
    }
    @Test func theReturnOfThisAppsOwnSignInFinishesWithNoSheet() async throws {
        let f = try CloudAccountFixture.make()
        let lines = Lines()
        await f.account.setStageLog { await lines.add($0) }
        let started = try await start(f)
        #expect(try await f.account.finishAppReturn(token: started.token, code: "fixture-code", state: started.state))
        #expect(await f.account.state().visible(at: f.clock.now()))
        #expect(await f.server.registered != nil)
        #expect(f.store.writes() > 0)
        #expect(await f.account.hasPendingSignIn() == false)
        // One plain line per stage; never the token, the state or the code.
        let all = await lines.values
        #expect(all.contains("cloud sign-in: finished"))
        #expect(all.allSatisfy { $0.hasPrefix("cloud sign-in: ") && !$0.contains(started.token) && !$0.contains(started.state) && !$0.contains("fixture-code") })
    }
    @Test func aReturnThatDoesNotAnswerThisAppsSignInDoesNothing() async throws {
        let f = try CloudAccountFixture.make()
        // No sign-in started: nothing to answer.
        #expect(try await f.account.finishAppReturn(token: String(repeating: "A", count: 22), code: "fixture-code", state: String(repeating: "B", count: 43)) == false)
        let started = try await start(f)
        let calls = await f.server.calls
        let before = await f.account.state()
        // Another token, another state, an empty code: refused without a request and without any change.
        #expect(try await f.account.finishAppReturn(token: String(repeating: "A", count: 22), code: "fixture-code", state: started.state) == false)
        #expect(try await f.account.finishAppReturn(token: started.token, code: "fixture-code", state: String(repeating: "B", count: 43)) == false)
        #expect(try await f.account.finishAppReturn(token: started.token, code: "", state: started.state) == false)
        #expect(await f.server.calls == calls)
        #expect(await f.account.state() == before)
        #expect(f.store.writes() == 0)
        // The pending sign-in is still the person's own: its real return still finishes.
        #expect(await f.account.hasPendingSignIn())
        // Past its five minutes, even its own return does nothing.
        f.clock.advance(301_000)
        #expect(try await f.account.finishAppReturn(token: started.token, code: "fixture-code", state: started.state) == false)
        #expect(f.store.writes() == 0)
    }
    @Test func aReplayedReturnDoesNothing() async throws {
        let f = try CloudAccountFixture.make()
        let started = try await start(f)
        async let one = f.account.finishAppReturn(token: started.token, code: "fixture-code", state: started.state)
        async let two = f.account.finishAppReturn(token: started.token, code: "fixture-code", state: started.state)
        let answers = [try await one, try await two]
        #expect(answers.filter { $0 }.count == 1)
        let writes = f.store.writes(), calls = await f.server.calls
        let after = await f.account.state()
        #expect(try await f.account.finishAppReturn(token: started.token, code: "fixture-code", state: started.state) == false)
        #expect(f.store.writes() == writes)
        #expect(await f.server.calls == calls)
        #expect(await f.account.state() == after)
    }

    // MARK: account trust

    @Test func automaticTrustAddsExactlyTheAccountsListedDevices() async throws {
        let f = try CloudAccountFixture.make()
        let a = key(), b = key(), c = key()
        await f.server.setOthers([device(Self.idA, "MacBook Air", a), device(Self.idB, "Studio", b), device(Self.idC, "Old Mac", c, status: .revoked)])
        try await signIn(f, mode: .account)
        let list = try await f.trust.list()
        let others = list.devices.filter { $0.how != "self" }
        #expect(Set(others.map(\.deviceId)) == [Self.idA, Self.idB])
        #expect(others.allSatisfy { $0.how == "account" && $0.trusted })
        #expect(others.first { $0.deviceId == Self.idA }?.signKey == a)
        #expect(Set(await f.outbox.released.flatMap { $0 }) == [Self.idA, Self.idB])
        let rows = await f.account.state().trust
        #expect(rows.first { $0.deviceId == Self.idA }?.standing == .trusted)
        #expect(rows.first { $0.deviceId == Self.idA }?.byAccount == true)
        #expect(rows.first { $0.deviceId == Self.idC }?.standing == .new)
        // Counted as confirmed for the lanes that wait for a first trusted device.
        #expect(await f.trust.hasDeviceTrustedByPress() == true)
        // A second read adds nothing and writes nothing.
        try await f.account.refresh()
        #expect(try await f.trust.list().devices == list.devices)
    }
    @Test func aChangedKeyIsHeldUntilThePersonTrustsItAgain() async throws {
        let f = try CloudAccountFixture.make()
        let first = key(), second = key()
        await f.server.setOthers([device(Self.idA, "MacBook Air", first)])
        try await signIn(f, mode: .account)
        await f.server.setOthers([device(Self.idA, "MacBook Air", second)])
        try await f.account.refresh()
        // Not re-trusted by itself: this Mac still holds the first key, so packs signed with the new one wait.
        #expect(await f.trust.trustedSigningKey(deviceId: Self.idA) == first)
        let row = try #require(await f.account.state().trust.first { $0.deviceId == Self.idA })
        #expect(row.keyChanged)
        let overview = try #require(BackendCloudOverviewBuilder.build(.init(snapshot: await f.account.state()).automatic()))
        #expect(overview.waiting.contains { $0.action == .trustAgain(deviceId: Self.idA) })
        // The one button: refused while the app's own remote input just posted, taken at the person's press.
        f.remoteInput.set(true)
        await #expect(throws: BackendCloudTrustRefusal.remoteInput) { try await f.account.trustChangedKey(row) }
        #expect(await f.trust.trustedSigningKey(deviceId: Self.idA) == first)
        f.remoteInput.set(false)
        try await f.account.trustChangedKey(row)
        #expect(await f.trust.trustedSigningKey(deviceId: Self.idA) == second)
        #expect(await f.outbox.trustedKeys[Self.idA] == second)
        #expect(await f.account.state().trust.first { $0.deviceId == Self.idA }?.keyChanged == false)
    }
    @Test func removeStopsADeviceAndAutomaticTrustNeverAddsItAgain() async throws {
        let f = try CloudAccountFixture.make()
        await f.server.setOthers([device(Self.idA, "MacBook Air", key())])
        try await signIn(f, mode: .account)
        let overview = try #require(BackendCloudOverviewBuilder.build(.init(snapshot: await f.account.state()).automatic(joined: [Self.idA])))
        #expect(overview.notices.map(\.text) == ["“MacBook Air” joined your account and is now trusted on this Mac."])
        #expect(overview.notices.first?.action == .removeDevice(deviceId: Self.idA))
        try await f.account.stopTrusting(deviceId: Self.idA)
        #expect(await f.trust.trustedSigningKey(deviceId: Self.idA) == nil)
        try await f.account.refresh()
        #expect(await f.trust.trustedSigningKey(deviceId: Self.idA) == nil)
        #expect(await f.account.state().trust.first { $0.deviceId == Self.idA }?.standing == .new)
    }
    @Test func askModeAddsNobodyByItself() async throws {
        let f = try CloudAccountFixture.make()
        await f.server.setOthers([device(Self.idA, "MacBook Air", key())])
        try await signIn(f, mode: .ask)
        #expect(try await f.trust.list().devices.allSatisfy { $0.how == "self" })
        #expect(await f.outbox.released.isEmpty)
        let row = try #require(await f.account.state().trust.first { $0.deviceId == Self.idA })
        #expect(row.standing == .new && row.canBeTrusted && !row.byAccount)
        // In ask mode the page offers Trust exactly as before.
        let overview = try #require(BackendCloudOverviewBuilder.build(.init(snapshot: await f.account.state())))
        #expect(overview.waiting.contains { $0.action == .trust(deviceId: Self.idA) })
        #expect(overview.notices.isEmpty)
    }
    @Test func theSettingReadsStrictWhenItIsNotUnderstood() {
        #expect(BackendCloudTrustMode.from(nil) == .account)
        #expect(BackendCloudTrustMode.from("account") == .account)
        #expect(BackendCloudTrustMode.from("ask") == .ask)
        #expect(BackendCloudTrustMode.from("garbage") == .ask)
    }
    @Test func noToolAnswerCarriesADeviceCode() async throws {
        let f = try CloudAccountFixture.make()
        await f.server.setOthers([device(Self.idA, "MacBook Air", key())])
        try await signIn(f, mode: .account)
        let state = await f.account.state()
        let wire = String(decoding: try state.wireValue.encodedJSON(pretty: false), as: UTF8.self)
        for row in state.trust { if let code = row.code { #expect(!wire.contains(code)) } }
        #expect(!wire.contains("\"code\""))
    }
}

private actor Lines {
    var values: [String] = []
    func add(_ line: String) { values.append(line) }
}

private extension BackendCloudOverviewInput {
    func automatic(joined: [String] = []) -> Self {
        var made = self
        made.automaticTrust = true
        made.joined = joined
        return made
    }
}
