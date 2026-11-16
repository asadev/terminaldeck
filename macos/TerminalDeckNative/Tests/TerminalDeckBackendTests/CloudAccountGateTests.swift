import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Review round 1 (1, 3, 5, 24) and round 2 (N2, N3, N4): only an explicit server answer closes Cloud; a closed answer
/// makes the account dormant and keeps the sign-in; links only start a confirmed sign-in.
@Suite("Cloud account — explicit decisions, dormant accounts, confirmed sign-in")
struct CloudAccountGateTests {
    actor Hooks {
        var values: [BackendCloudAccountSessionChange] = []
        func add(_ value: BackendCloudAccountSessionChange) { values.append(value) }
    }
    @Test func aClosedEntitlementMakesTheAccountDormantAndKeepsTheSignIn_N3() async throws {
        let f = try CloudAccountFixture.make(), hooks = Hooks()
        await f.account.setSessionHook { await hooks.add($0) }
        _ = try await f.signin()
        await f.server.set("gate", false)
        try await f.account.refresh()
        #expect(await f.account.state().phase == .dormant)
        #expect(!(await f.account.state().visible(at: f.clock.now())))
        #expect(try await f.identity.existing() != nil)
        #expect(await f.server.logouts == 0)
        #expect(await hooks.values == [.signedIn, .dormant])
        #expect(await f.outbox.paused)
        #expect(try await BackendCloudAccountTools.registrations(service: f.account, now: f.clock.now(), signin: { _ in }).isEmpty)
        // Turned on again: the next explicit answer reopens it with the same saved sign-in.
        await f.server.set("gate", true)
        try await f.account.refresh()
        #expect(await f.account.state().visible(at: f.clock.now()))
        #expect(await hooks.values.last == .signedIn)
    }
    @Test func aWrongClockOrAStaleServerTimeNeverClosesOrSignsOut_N3() async throws {
        let f = try CloudAccountFixture.make()
        await f.server.set("staleExpiry", true)
        _ = try await f.signin()
        #expect(await f.account.state().visible(at: f.clock.now()))
        f.clock.advance(86_400_000)
        #expect(await f.account.state().visible(at: f.clock.now()))
        #expect(try await f.identity.existing() != nil)
    }
    @Test func onlyARefusedSessionClearsTheSignIn_N3() async throws {
        let f = try CloudAccountFixture.make(), hooks = Hooks()
        await f.account.setSessionHook { await hooks.add($0) }
        _ = try await f.signin()
        f.clock.advance(3_590_000) // the access token needs refreshing
        await f.server.set("refuseRefresh", true)
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        #expect(try await f.identity.existing() == nil)
        #expect(await hooks.values.last == .signedOut)
    }
    @Test(arguments: [("session_not_found", true), ("refresh_token_not_found", true), ("refresh_token_already_used", false)])
    func theStoresRealRefusalShapesAreRecognised_G1(code: String, refused: Bool) async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        f.clock.advance(3_590_000) // the access token needs refreshing at the Store
        await f.server.setRefusalCode(code)
        await f.server.set("refuseRefresh", true)
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        #expect((try await f.identity.existing() == nil) == refused)
        #expect(await f.account.state().visible(at: f.clock.now()) == !refused)
    }
    /// MAC-NEXT-12 (13 Nov): was "a repeat signs out". The Store has just issued a fresh token, so a second
    /// sign_in_required is Cloud unable to check (its database busy during an export), not a revocation: KEPT.
    @Test func cloudsSignInRequiredGetsOneFreshTokenThenARepeatKeepsTheSignIn_macNext12() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let refreshes = await f.server.refreshes
        await f.transport.failState(["sign_in_required"])
        try await f.account.refresh()                       // one fresh token, then the answer
        #expect(await f.server.refreshes == refreshes + 1)
        #expect(await f.account.state().visible(at: f.clock.now()))
        #expect(try await f.identity.existing() != nil)
        await f.transport.failState(["sign_in_required", "sign_in_required"])
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        #expect(try await f.identity.existing() != nil)     // the Store issued the token: the sign-in is kept
        #expect(await f.account.state().phase != .signedOut)
        #expect(await f.account.state().problem?.contains("tries again") == true)
        // The timed retry asks for a fresh token again and, once Cloud answers, is signed in as before.
        try await f.account.refresh()
        #expect(await f.account.state().visible(at: f.clock.now()))
        #expect(await f.server.refreshes == refreshes + 2)
    }
    /// Round 5: a repeated bad_device_proof (old expectation: signed out, deviceRevoked) is now "no answer" with a
    /// date-and-time message and the sign-in KEPT, because a wrong clock can cause it; a removed device is told by
    /// 403 device_revoked, which still signs out.
    @Test func aBadDeviceProofReRegistersOnceThenARepeatKeepsTheSignIn_round5() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let registrations = await f.transport.registrations
        await f.transport.failState(["bad_device_proof"])
        try await f.account.refresh()
        #expect(await f.transport.registrations == registrations + 1)
        #expect(await f.account.state().visible(at: f.clock.now()))
        await f.transport.failState(["bad_device_proof", "bad_device_proof"])
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        #expect(try await f.identity.existing() != nil)
        #expect(await f.account.state().visible(at: f.clock.now()))
        #expect(await f.account.state().problem?.contains("date and time") == true)
    }
    @Test func aClockSkewAnswerRetriesOnceAndARepeatNeverSignsOut_round5() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let calls = await f.transport.stateCalls
        await f.transport.failState(["clock_skew"])
        try await f.account.refresh()                        // corrected and asked again
        #expect(await f.transport.stateCalls == calls + 2)
        #expect(await f.account.state().problem == nil)
        await f.transport.failState(["clock_skew", "clock_skew"])
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        #expect(try await f.identity.existing() != nil)
        #expect(await f.account.state().visible(at: f.clock.now()))
        #expect(await f.account.state().problem?.contains("date and time") == true)
    }
    /// MAC-NEXT-12b: the service retires a superseded registration by deleting its session, so the device then hears
    /// 401 sign_in_required (not device_revoked). The quiet device watch must not swallow it: the status read runs at
    /// once; the Store refuses the deleted session -> "sign in again"; a live session -> carries on by itself.
    @Test func aRetiredRegistrationIsToldAtTheNextDeviceWatch_macNext12b() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        // Live session (the service was busy): the watch's status read renews the token and the Mac carries on.
        await f.transport.failDevices(["sign_in_required"])
        await f.transport.failState(["sign_in_required"])
        #expect(try await f.account.refreshDevicesIfChanged())
        #expect(try await f.identity.existing() != nil)
        #expect(await f.account.state().visible(at: f.clock.now()))
        // Retired registration: its session is gone at the Store too -> signed out, said as "sign in".
        await f.transport.failDevices(["sign_in_required"])
        await f.transport.failState(["sign_in_required"])
        await f.server.setRefusalCode("refresh_token_not_found")
        await f.server.set("refuseRefresh", true)
        await #expect(throws: (any Error).self) { try await f.account.refreshDevicesIfChanged() }
        #expect(try await f.identity.existing() == nil)
        #expect(!(await f.account.state().visible(at: f.clock.now())))
    }
    @Test func aRemovedDeviceIsStillSignedOut_round5() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        await f.transport.failState(["device_revoked"])
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        #expect(try await f.identity.existing() == nil)
    }
    @Test func cloudWithoutAnEntitlementValueIsNoAnswerNotAClosedGate_G4() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        await f.server.set("noEntitlementValue", true)
        f.clock.advance(300_000)
        await #expect(throws: CloudFailure.unavailable) { try await f.account.refresh() }
        #expect(await f.account.state().phase == .signedIn)
        #expect(await f.account.state().visible(at: f.clock.now()))
        #expect(try await f.identity.existing() != nil)
    }
    @Test func aSignedInAwakeMacRechecksQuietlyInTheBackground() async throws {
        let f = try CloudAccountFixture.make()
        await f.account.setBackgroundCheckInterval(.milliseconds(30))
        _ = try await f.signin()
        let calls = await f.transport.stateCalls
        var spins = 0
        while await f.transport.stateCalls == calls, spins < 200 { spins += 1; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await f.transport.stateCalls > calls)
        try await f.account.signOut()
        let after = await f.transport.stateCalls
        try await Task.sleep(for: .milliseconds(120))
        #expect(await f.transport.stateCalls == after)
    }
    @Test func noNetworkNeverHidesCloudOrPausesSendingAndRetriesWhenTheNetworkReturns_N2() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        #expect(!(await f.outbox.paused))
        await f.transport.setOffline(true)
        f.clock.advance(3_000_000)
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        let state = await f.account.state()
        #expect(state.visible(at: f.clock.now()))
        #expect(state.problem != nil)
        #expect(!(await f.outbox.paused))
        await f.transport.setOffline(false)
        let before = await f.transport.stateCalls
        await f.account.networkReturned()
        var spins = 0
        while await f.transport.stateCalls == before, spins < 400 { spins += 1; await Task.yield() }
        #expect(await f.transport.stateCalls == before + 1)
        spins = 0
        while await f.account.state().problem != nil, spins < 400 { spins += 1; await Task.yield() }
        #expect(await f.account.state().problem == nil)
    }
    @Test func theDecisionIsRecheckedLazilyByMonotonicTimeWithoutClosingFirst_N2() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let calls = await f.transport.stateCalls
        f.clock.advance(60_000)
        #expect(await f.account.state().visible(at: f.clock.now()))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await f.transport.stateCalls == calls)
        f.clock.advance(200_000)
        #expect(await f.account.state().visible(at: f.clock.now()))
        var spins = 0
        while await f.transport.stateCalls == calls, spins < 400 { spins += 1; await Task.yield() }
        #expect(await f.transport.stateCalls == calls + 1)
    }
    @Test func resumeWithoutASavedSessionReturnsToTheNoAccountState_finding1() async throws {
        let f = try CloudAccountFixture.make(), hooks = Hooks()
        await f.account.setSessionHook { await hooks.add($0) }
        try await f.account.resume()
        #expect(await hooks.values == [.signedOut])
        #expect(await f.server.calls == 0)
        #expect(await f.transport.stateCalls == 0)
    }
    @Test func aLinkCannotStartASecondSignInOrCloseAnOpenGate_finding3() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let before = await f.account.state()
        #expect(before.visible(at: f.clock.now()))
        let callback = CloudHandoffCallback(port: 49556, pathToken: String(repeating: "b", count: 32))
        await #expect(throws: CloudFailure.idReused) { _ = try await f.account.beginSignIn(callback: callback) }
        #expect(await f.account.state() == before)
    }
    // Owner, 13 Nov: the "Sign in to Cloud as …?" sheet is gone (the website names the account). What it guarded,
    // a sign-in this app did not start, is refused by `finishAppReturn` instead: CloudAccountAppReturnTests.
    @Test func anAbandonedLinkAttemptLeavesNothingBehind_finding3() async throws {
        let f = try CloudAccountFixture.make(), hooks = Hooks()
        await f.account.setSessionHook { await hooks.add($0) }
        let callback = CloudHandoffCallback(port: 49555, pathToken: String(repeating: "a", count: 32))
        _ = try await f.account.beginSignIn(callback: callback)
        #expect(await f.account.pendingSignInState() != nil)
        await f.account.abandonSignIn()
        #expect(await hooks.values == [.signedOut])
        #expect(await f.account.state() == .signedOut)
        #expect(f.store.writes() == 0)
    }
    @Test func aFailedRegistrationKeepsNoNewSession_finding24() async throws {
        let f = try CloudAccountFixture.make(), hooks = Hooks()
        await f.account.setSessionHook { await hooks.add($0) }
        await f.server.set("registration", true)
        await #expect(throws: CloudFailure.deviceRevoked) { _ = try await f.signin() }
        #expect(try await f.identity.existing() == nil)
        // clear() writes the signed-out tombstone and then removes the item; with removal working nothing is left at all.
        // (The tombstone that survives a FAILED removal is covered by signoutKeepsWorkAndHasDurableTombstoneIfDeletionFails.)
        #expect(f.store.value() == nil)
        #expect(f.store.writes() == 2) // the session, then the tombstone; never the session again
        #expect(await hooks.values == [.signedOut])
    }
    @Test func aSignInRefusedByTheGateIsKeptDormantAndSaysSo_N7() async throws {
        let f = try CloudAccountFixture.make()
        await f.server.set("gate", false)
        await #expect(throws: CloudFailure.gateClosed) { _ = try await f.signin() }
        #expect(await f.account.state().phase == .dormant)
        #expect(await f.account.state().problem != nil)
        #expect(try await f.identity.existing() != nil)
    }
    @Test func aFreshTokenThatCouldNotBeAskedForIsTriedAgainBeforeAnySignOut_round5() async throws {
        // Round 5 (A1, small): Cloud says sign_in_required, the forced token refresh fails for a NETWORK reason. That is
        // no answer. When Cloud says sign_in_required again, a fresh token must be tried again: the Mac is not signed out.
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let before = await f.server.refreshes
        await f.server.set("tokenOffline", true)
        await f.transport.failState(["sign_in_required"])
        _ = try? await f.account.refresh()
        #expect(await f.account.state().phase != .signedOut)
        #expect(try await f.identity.existing() != nil)
        #expect(await f.server.refreshes == before)
        // The network is back; Cloud refuses once more, then accepts the fresh token.
        await f.server.set("tokenOffline", false)
        await f.transport.failState(["sign_in_required"])
        try await f.account.refresh()
        #expect(await f.server.refreshes == before + 1)
        #expect(await f.account.state().phase == .signedIn)
        #expect(try await f.identity.existing() != nil)
        #expect(await f.server.logouts == 0)
    }
}

extension CloudAccountGateTests.Hooks {
    actor Identity {
        var value: CloudUserIdentity?
        func set(_ value: CloudUserIdentity) { self.value = value }
    }
}
