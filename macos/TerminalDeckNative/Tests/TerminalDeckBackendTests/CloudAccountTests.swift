import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud account — isolated sign-in and registered-device flow")
struct CloudAccountTests {
    @Test func startsClosedWithoutTouchingProtectedStorage() async throws {
        let f = try CloudAccountFixture.make()
        #expect(await f.account.state() == .signedOut)
        #expect(f.store.writes() == 0)
        #expect(await f.server.calls == 0)
    }
    @Test func websiteHandoffUsesPKCEAndNeverPutsTokensInTheURL() async throws {
        let f = try CloudAccountFixture.make()
        let url = try await f.signin()
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name))
        #expect(names == ["challenge", "state", "port", "callback", "provider"])
        #expect(!url.absoluteString.contains("verifier"))
        #expect(!url.absoluteString.contains("accessToken"))
        let status = await f.account.state()
        #expect(status.phase == .signedIn)
        #expect(status.devices.count == 1)
        #expect(status.coverage.first?.items == 3)
        #expect(status.waitingRecords == 2)
        #expect(!status.wireValue.compact.contains("fixture-refresh"))
        #expect(!status.wireValue.compact.contains("accessToken"))
    }
    @Test func signInCodeAndStateHaveTheServicesExactLengths() async throws {
        // Proven on TEST (13 Nov): the service takes a callback code of exactly 22 base64url characters (16 bytes,
        // cloud/worker/src/auth.ts) and the website a state of exactly 43 (32 bytes, api/store/cloud/_flow.js).
        // Anything else is "400 invalid_request" at sign-in.
        func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        #expect(BackendCloudAccount.callbackCodeBytes == 16 && BackendCloudAccount.stateBytes == 32)
        let code = BackendCloudAccount.random(bytes: BackendCloudAccount.callbackCodeBytes)
        #expect(matches(code, "^[A-Za-z0-9_-]{22}$"), "\(code)")
        let f = try CloudAccountFixture.make()
        let callback = CloudHandoffCallback(port: 49555, pathToken: code)
        let url = try await f.account.beginSignIn(callback: callback)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let state = try #require(items.first { $0.name == "state" }?.value)
        #expect(matches(state, "^[A-Za-z0-9_-]{43}$"), "\(state)")
        #expect(items.first { $0.name == "callback" }?.value == code)
        // Owner, 13 Nov: the loopback listener is gone; the app callback (through the website) makes its code with
        // the same length.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let account = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckBackend/BackendCloudAccount.swift"), encoding: .utf8)
        #expect(account.contains("CloudHandoffCallback.app(platform: platform, pathToken: Self.random(bytes: Self.callbackCodeBytes))"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/TerminalDeckBackend/BackendCloudAccountLoopback.swift").path))
    }
    @Test func callbackStateAndOneUseFlowAreEnforcedBeforeExchange() async throws {
        let f = try CloudAccountFixture.make()
        let callback = CloudHandoffCallback(port: 49555, pathToken: String(repeating: "a", count: 32))
        await f.confirmAll()
        let url = try await f.account.beginSignIn(callback: callback)
        try await f.server.authorize(url)
        await #expect(throws: CloudFailure.invalidRequest) { try await f.account.finishSignIn(code: "fixture-code", state: "wrong", callback: callback) }
        #expect(await f.server.calls == 0)
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        try await f.account.finishSignIn(code: "fixture-code", state: state, callback: callback)
        await #expect(throws: CloudFailure.invalidRequest) { try await f.account.finishSignIn(code: "fixture-code", state: state, callback: callback) }
        #expect(await f.server.calls == 1)
    }
    @Test func expiredHandoffDoesNotWriteCredentials() async throws {
        let f = try CloudAccountFixture.make()
        let callback = CloudHandoffCallback(port: 49555, pathToken: String(repeating: "a", count: 32))
        let url = try await f.account.beginSignIn(callback: callback)
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        f.clock.advance(300_001)
        await #expect(throws: CloudFailure.invalidRequest) { try await f.account.finishSignIn(code: "fixture-code", state: state, callback: callback) }
        #expect(f.store.writes() == 0)
    }
    @Test func wrongIssuerIsNotPersistedOrRegistered() async throws {
        let f = try CloudAccountFixture.make()
        await f.server.set("wrongIssuer", true)
        await #expect(throws: CloudFailure.invalidRequest) { _ = try await f.signin() }
        #expect(f.store.writes() == 0)
        #expect(await f.server.registered == nil)
        #expect(!(await f.account.state().visible(at: f.clock.now())))
    }
    @Test func protectedStoreFailureCannotOpenTheCloudGate() async throws {
        let f = try CloudAccountFixture.make()
        f.store.failWrites = true
        await #expect(throws: CloudFailure.unavailable) { _ = try await f.signin() }
        #expect(await f.server.registered == nil)
        #expect(!(await f.account.state().visible(at: f.clock.now())))
    }
    @Test func serverMustAcceptDeviceProofBeforeAnySurfaceAppears() async throws {
        let f = try CloudAccountFixture.make()
        await f.server.set("registration", true)
        await #expect(throws: CloudFailure.deviceRevoked) { _ = try await f.signin() }
        #expect(!(await f.account.state().visible(at: f.clock.now())))
    }
    @Test func registeredKeysAreStableAndSharedECDHHasNoSecondStore() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let first = try await f.identity.deviceRegistration()
        let second = try await f.identity.deviceRegistration()
        #expect(first == second)
        let peer = P256.KeyAgreement.PrivateKey()
        let point = peer.publicKey.x963Representation
        let publicKey = CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])), y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
        let shared = try await f.identity.deviceSharedSecret(peer: publicKey)
        let ourPoint = Data([4]) + BackendCloudAccountIdentity.unbase64(first.wrapPublicJwk.x)! + BackendCloudAccountIdentity.unbase64(first.wrapPublicJwk.y!)!
        let expected = try peer.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: ourPoint)).withUnsafeBytes { Data($0) }
        #expect(shared == expected)
        #expect(f.store.writes() == 1)
    }
    @Test func refreshIsSharedAndCommittedBeforeAllCallersReturn() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        f.clock.advance(3_550_000)
        async let one = f.identity.credentials()
        async let two = f.identity.credentials()
        async let three = f.identity.credentials()
        let sessions = try await [one, two, three]
        #expect(Set(sessions.map { $0.refreshToken }).count == 1)
        #expect(await f.server.refreshes == 1)
        #expect(f.store.writes() == 2)
        #expect(f.store.value()?.contains(sessions[0].refreshToken) == true)
    }
    @Test func aFailedRefreshWriteCannotLeakAnUncommittedPair() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let before = f.store.value()
        f.clock.advance(3_550_000); f.store.failWrites = true
        await #expect(throws: CloudFailure.unavailable) { _ = try await f.identity.credentials() }
        #expect(f.store.value() == before)
    }
    @Test func signoutKeepsWorkAndHasDurableTombstoneIfDeletionFails() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        f.store.failRemoval = true
        try await f.account.signOut()
        #expect(await f.account.state() == .signedOut)
        #expect(await f.outbox.paused)
        #expect(await f.transport.stopped)
        #expect(await f.server.logouts == 1)
        #expect(f.store.value() == #"{"signedOut":true}"#)
        let restored = BackendCloudAccountIdentity(configuration: f.identity.configuration, store: f.store.port(), http: f.server, clock: { f.clock.now() })
        #expect(try await restored.existing() == nil)
    }
    @Test func signoutDuringRefreshCannotResurrectAuthentication() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        f.clock.advance(3_550_000)
        let refreshing = Task { try await f.identity.credentials() }
        try await Task.sleep(for: .milliseconds(5))
        try await f.account.signOut()
        _ = try? await refreshing.value
        #expect(try await f.identity.existing() == nil)
        #expect(await f.account.state() == .signedOut)
    }
    @Test func pauseResumeAndRetryGoThroughTheInjectedOutbox() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        try await f.account.sync(action: "pause")
        #expect(await f.outbox.paused)
        #expect(await f.account.state().phase == .paused)
        try await f.account.sync(action: "resume")
        #expect(await f.outbox.paused == false)
        try await f.account.sync(action: "retry")
        #expect(await f.outbox.flushes == 1)
    }
    @Test func subjectBindingCreatesOnlyOneSetOfRealPorts() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let count = CloudAccountFixtureClock()
        let initial = count.now()
        let binding = BackendCloudAccountBinding(identity: f.identity) { session, device in
            #expect(session.user.id == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
            #expect(device.deviceId == (try await f.identity.deviceRegistration()).deviceId)
            count.advance(1)
            try await Task.sleep(for: .milliseconds(10))
            return .init(transport: f.transport, outbox: f.outbox)
        }
        async let a = binding.resolve()
        async let b = binding.resolve()
        async let c = binding.resolve()
        _ = try await (a, b, c)
        #expect(count.now() == initial + 1)
    }
    @Test func capabilityRevocationRemovesEveryCloudTool() async throws {
        let f = try CloudAccountFixture.make()
        #expect(try await BackendCloudAccountTools.registrations(service: f.account, now: f.clock.now(), signin: { _ in }).isEmpty)
        _ = try await f.signin()
        #expect(try await BackendCloudAccountTools.registrations(service: f.account, now: f.clock.now(), signin: { _ in }).count == BackendCloudAccountTools.ids.count)
        await f.server.set("gate", false)
        try await f.account.refresh()
        #expect(try await BackendCloudAccountTools.registrations(service: f.account, now: f.clock.now(), signin: { _ in }).isEmpty)
        #expect(await f.outbox.paused)
    }
}
