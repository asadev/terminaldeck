import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// R5 with the security review's M3 and S17: signing out of the last Mac that can open the saved passwords warns
/// first and requires confirmed recovery words. It is decided from what THIS MAC holds; the service's device list
/// can only prove, read fresh at the press, that another approved Mac exists.
@Suite("Cloud sign-out — the last Mac that can open saved passwords")
struct CloudSignOutGuardTests {
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0, answer = false, confirmed = false, held = false
        func set(held: Bool, confirmed: Bool, answer: Bool) { lock.withLock { self.held = held; self.confirmed = confirmed; self.answer = answer } }
        func warn() -> Bool { lock.withLock { count += 1; return answer } }
        func words() -> Bool { lock.withLock { confirmed } }
        func keyHeld() -> Bool { lock.withLock { held } }
        func warnings() -> Int { lock.withLock { count } }
    }
    private func other(_ id: String, approved: Bool, status: CloudDeviceStatus = .active) -> CloudDevice {
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "fixture-x", y: "fixture-y")
        return .init(deviceId: id, label: "Other Mac", platform: .macos, appVersion: "fixture", status: status, secretsApproved: approved,
                     lastSeenAt: 0, signPublicJwk: key, wrapPublicJwk: key)
    }
    /// A signed-in fixture account with saved passwords wired (all three hooks set).
    private func made() async throws -> (f: CloudAccountFixture, asked: Asked) {
        let f = try CloudAccountFixture.make(), asked = Asked()
        await f.account.setLastSignOutWarning { asked.warn() }
        await f.account.setRecoveryWordsConfirmed { asked.words() }
        await f.account.setSavedPasswordsKeyHeld { asked.keyHeld() }
        _ = try await f.signin()
        return (f, asked)
    }
    static let otherId = "10000000-0000-4000-8000-000000000002"

    @Test func anotherApprovedMacIsOnlyAnActiveOtherDevice() {
        let mine = "10000000-0000-4000-8000-000000000001"
        #expect(BackendCloudSignOutGuard.anotherApprovedDevice(in: [other(mine, approved: true), other(Self.otherId, approved: true)], thisDeviceId: mine))
        #expect(!BackendCloudSignOutGuard.anotherApprovedDevice(in: [other(mine, approved: true), other(Self.otherId, approved: false)], thisDeviceId: mine))
        // A device that was cut off is not another way in, and this Mac's own row never counts.
        #expect(!BackendCloudSignOutGuard.anotherApprovedDevice(in: [other(mine, approved: true), other(Self.otherId, approved: true, status: .revoked)], thisDeviceId: mine))
        #expect(!BackendCloudSignOutGuard.anotherApprovedDevice(in: [other(mine, approved: true)], thisDeviceId: mine))
    }
    @Test func theLastMacIsRefusedUntilTheRecoveryWordsAreConfirmed() async throws {
        let (f, asked) = try await made()
        asked.set(held: true, confirmed: false, answer: true)
        await #expect(throws: BackendCloudSignOutRefusal.recoveryWordsNotConfirmed) { try await f.account.signOut() }
        #expect(await f.account.state().phase == .signedIn)
        #expect(try await f.identity.existing() != nil)
        #expect(asked.warnings() == 0) // refused before any warning: there is nothing to agree to yet
        #expect(await f.server.logouts == 0)
        // The refusal names a place the page has.
        #expect(BackendCloudSignOutRefusal.recoveryWordsNotConfirmed.words.contains("Saved passwords in Settings → Cloud"))
    }
    @Test func whenSavedPasswordsCannotAnswerTheRefusalSaysSoAndThisMacStaysSignedIn() async throws {
        let (f, asked) = try await made()
        asked.set(held: true, confirmed: true, answer: true)
        // Saved passwords cannot be asked just now (Cloud does not answer): not the same as "not confirmed".
        await f.account.setRecoveryWordsConfirmed { throw CloudFailure.unavailable }
        await #expect(throws: BackendCloudSignOutRefusal.recoveryWordsNotChecked) { try await f.account.signOut() }
        #expect(await f.account.state().phase == .signedIn)
        #expect(asked.warnings() == 0)
        let unchecked = BackendCloudSignOutRefusal.recoveryWordsNotChecked.words
        let unconfirmed = BackendCloudSignOutRefusal.recoveryWordsNotConfirmed.words
        #expect(unchecked.contains("Try again when this Mac is online"))
        #expect(unchecked != unconfirmed)
        // Once saved passwords answer, sign-out goes on to the warning and the person's press.
        await f.account.setRecoveryWordsConfirmed { asked.words() }
        try await f.account.signOut()
        #expect(asked.warnings() == 1)
        #expect(await f.account.state().phase == .signedOut)
    }
    @Test func theLastMacIsWarnedAndOnlyThePersonsPressSignsOut() async throws {
        let (f, asked) = try await made()
        asked.set(held: true, confirmed: true, answer: false)
        await #expect(throws: CancellationError.self) { try await f.account.signOut() }
        #expect(asked.warnings() == 1)
        #expect(await f.account.state().phase == .signedIn)
        asked.set(held: true, confirmed: true, answer: true)
        try await f.account.signOut()
        #expect(asked.warnings() == 2)
        #expect(await f.account.state().phase == .signedOut)
        #expect(try await f.identity.existing() == nil)
    }
    @Test func itIsDecidedFromTheKeyThisMacHoldsNotFromTheServicesList() async throws {
        // The service calls this Mac approved and alone, but this Mac holds no key: nothing can be lost, no guard.
        let (plain, askedPlain) = try await made()
        await plain.server.setOwnApproved(true)
        askedPlain.set(held: false, confirmed: false, answer: false)
        try await plain.account.signOut()
        #expect(askedPlain.warnings() == 0)
        #expect(await plain.account.state().phase == .signedOut)
        // The service does NOT call this Mac approved, but this Mac holds the key: guarded all the same.
        let (holder, askedHolder) = try await made()
        askedHolder.set(held: true, confirmed: false, answer: true)
        await #expect(throws: BackendCloudSignOutRefusal.recoveryWordsNotConfirmed) { try await holder.account.signOut() }
        #expect(await holder.account.state().phase == .signedIn)
    }
    @Test func onlyAFreshListCanProveAnotherApprovedMac() async throws {
        // Another active approved device in a list read at the press: the key is held elsewhere too, plain sign-out.
        let (two, askedTwo) = try await made()
        await two.server.setOthers([other(Self.otherId, approved: true)])
        askedTwo.set(held: true, confirmed: false, answer: false)
        try await two.account.signOut()
        #expect(askedTwo.warnings() == 0)
        #expect(await two.account.state().phase == .signedOut)
        // The same other device was in the LAST list this Mac read, but the read at the press fails: an old list
        // proves nothing, so this Mac is treated as the last one (security review S17).
        let (stale, askedStale) = try await made()
        await stale.server.setOthers([other(Self.otherId, approved: true)])
        try await stale.account.refresh()
        let known = await stale.account.state().devices
        #expect(known.contains(where: { $0.deviceId == Self.otherId && $0.secretsApproved }))
        await stale.transport.setDeviceListOffline(true)
        askedStale.set(held: true, confirmed: false, answer: true)
        await #expect(throws: BackendCloudSignOutRefusal.recoveryWordsNotConfirmed) { try await stale.account.signOut() }
        #expect(await stale.account.state().phase != .signedOut)
        // A device that was cut off is not another way in.
        let (cut, askedCut) = try await made()
        await cut.server.setOthers([other(Self.otherId, approved: true, status: .revoked)])
        askedCut.set(held: true, confirmed: true, answer: false)
        await #expect(throws: CancellationError.self) { try await cut.account.signOut() }
        #expect(askedCut.warnings() == 1)
    }
    @Test func aSessionTheServerEndedIsStillClearedWithoutAsking() async throws {
        let (f, asked) = try await made()
        asked.set(held: true, confirmed: false, answer: false)
        await f.transport.failState(["session_not_found"])
        _ = try? await f.account.refresh()
        #expect(await f.account.state().phase == .signedOut)
        #expect(asked.warnings() == 0)
    }
    @Test func withoutSavedPasswordsWiredSignOutSimplyWorks() async throws {
        // Security review M3: where saved passwords are not wired no Mac can hold a key, so nothing may stand in the
        // way of signing out, whatever the service's list says. (Before: a refusal with nothing to press.)
        let f = try CloudAccountFixture.make()
        await f.account.setLastSignOutWarning { false }
        _ = try await f.signin()
        await f.server.setOwnApproved(true)
        try await f.account.signOut()
        #expect(await f.account.state().phase == .signedOut)
        #expect(try await f.identity.existing() == nil)
    }
}
