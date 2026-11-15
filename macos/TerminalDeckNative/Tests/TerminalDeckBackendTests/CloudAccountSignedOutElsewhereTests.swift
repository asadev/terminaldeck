import Foundation
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lost-device design B4, with the 15 Nov review rule: this Mac removes its Cloud keys ONLY on Cloud's explicit answer
/// that THIS device was revoked by the account (`device_revoked` from the Cloud service, seen again on a second call of
/// the Cloud transport). Then the hook removes only the key items, the sign-in ends, the outbox is paused (never
/// emptied) and Profile says who and when. Every other answer (a bare 401, another 403, a 5xx, a timeout, an empty
/// answer, no network, the Store's own refusal) removes nothing. Fixtures only; the key items' removal itself is proven
/// in CloudSecretsLostMacTests.aRemoteSignOutRemovesOnlyThisDevicesCloudKeys.
@Suite("Cloud account — this Mac signed out from another device: explicit answers only")
struct CloudAccountSignedOutElsewhereTests {
    actor Heard {
        var values: [BackendCloudSignedOutElsewhere] = []
        func add(_ value: BackendCloudSignedOutElsewhere) { values.append(value) }
    }
    private func signedIn() async throws -> (CloudAccountFixture, Heard) {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let heard = Heard()
        await f.account.setSignedOutElsewhereHook { await heard.add($0) }
        return (f, heard)
    }

    @Test func theExplicitAnswerRemovesOnlyTheKeysPausesTheQueueAndSaysWhoDidIt() async throws {
        let (f, heard) = try await signedIn()
        let mine = try await f.identity.deviceRegistration().deviceId
        await f.transport.failState(detail: .init(code: "device_revoked", message: "fixture", retryable: false, requestId: "fixture",
                                                  removedByName: "Studio Mac mini", removedAt: 1_800_000_000_000))
        // The second, confirming call of the Cloud transport: again the "removed by" form.
        await f.transport.failDevices(detail: .init(code: "device_revoked", message: "fixture", retryable: false, requestId: "fixture",
                                                    removedByName: "Studio Mac mini", removedAt: 1_800_000_000_000))
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        let told = await heard.values
        #expect(told.count == 1)
        #expect(told.first?.deviceId == mine)
        #expect(told.first?.byName == "Studio Mac mini")
        #expect(await f.account.state().problem?.hasPrefix("Signed out from Studio Mac mini on ") == true)
        #expect(await f.account.state().problem?.contains("Everything on this Mac is kept") == true)
        #expect(try await f.identity.existing() == nil, "the sign-in ended")
        #expect(await f.outbox.paused, "the waiting changes are paused, never emptied")
        // Signing in again: the queue goes again (everything follows) and the line is gone.
        _ = try await f.signin()
        #expect(!(await f.outbox.paused))
        #expect(await f.account.state().phase == .signedIn)
        #expect(await f.account.state().problem == nil)
    }

    /// Cloud said device_revoked once, but its own second call does not say it again: not explicit, keys stay.
    @Test func aDeviceRevokedThatIsNotSeenAgainRemovesNothing() async throws {
        let (f, heard) = try await signedIn()
        await f.transport.failState(["device_revoked"])
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        #expect(await heard.values.isEmpty)
    }

    /// Review finding 4: the PLAIN device_revoked (no "removed by": the sign-in session itself ended, or does not match)
    /// twice in a row is not "another device signed you out": nothing is removed.
    @Test func aPlainDeviceRevokedTwiceRemovesNothing() async throws {
        let (f, heard) = try await signedIn()
        await f.transport.failState(["device_revoked"])
        await f.transport.failDevices(["device_revoked"])
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        #expect(await heard.values.isEmpty)
        #expect(await f.account.state().problem?.hasPrefix("Signed out from") != true)
    }

    /// Review finding 4: the "removed by" form once, then a plain one: not confirmed, nothing is removed.
    @Test func theRemovedByFormMustComeOnTheSecondCallToo() async throws {
        let (f, heard) = try await signedIn()
        await f.transport.failState(detail: .init(code: "device_revoked", message: "fixture", retryable: false, requestId: "fixture",
                                                  removedByName: "Studio Mac mini", removedAt: 1_800_000_000_000))
        await f.transport.failDevices(["device_revoked"])
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        #expect(await heard.values.isEmpty)
    }

    /// Review finding 4: the registration answer "revoked" (after a bad device proof) ends the sign-in as before but
    /// never removes the Cloud keys.
    @Test func theRegistrationAnswerRevokedRemovesNothing() async throws {
        let (f, heard) = try await signedIn()
        await f.server.setAnswerRevoked(true)
        await f.transport.failState(["bad_device_proof"])
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        #expect(await heard.values.isEmpty)
        #expect(await f.account.state().problem?.hasPrefix("Signed out from") != true)
    }

    /// The Store refused the token (the session ended): the sign-in ends as before, but this is not Cloud saying
    /// "this device was removed", so the Cloud keys are never touched and no "signed out from" line shows.
    @Test func theStoresRefusalNeverRemovesTheKeys() async throws {
        let (f, heard) = try await signedIn()
        await f.transport.failState(["sign_in_required"])
        await f.server.setRefusalCode("refresh_token_not_found")
        await f.server.set("refuseRefresh", true)
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        #expect(await heard.values.isEmpty)
        #expect(await f.account.state().problem?.hasPrefix("Signed out from") != true)
    }

    /// A bare 401 (a deploy in progress), a 403 of another kind, a 5xx, a busy service: nothing changes, the sign-in
    /// and the queue stay, nothing alarming is said; Cloud tries again with the normal back-off.
    @Test(arguments: ["sign_in_required", "forbidden", "internal_error", "temporarily_unavailable", "budget_paused"])
    func aRefusalThatIsNotExplicitRemovesNothing(_ code: String) async throws {
        let (f, heard) = try await signedIn()
        await f.transport.failState([code, code])
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        #expect(await heard.values.isEmpty, "\(code)")
        #expect(try await f.identity.existing() != nil, "\(code): the sign-in stays")
        #expect(!(await f.outbox.paused), "\(code): the queue stays")
        #expect(await f.account.state().problem?.hasPrefix("Signed out from") != true)
    }

    /// A timeout, no network, an empty or undecodable answer: nothing changes.
    @Test func noAnswerOfAnyKindRemovesNothing() async throws {
        for failure: any Error in [URLError(.timedOut), URLError(.notConnectedToInternet), CloudFailure.invalidRequest, CloudFailure.unavailable] {
            let (f, heard) = try await signedIn()
            await f.transport.failState(error: failure)
            await #expect(throws: (any Error).self) { try await f.account.refresh() }
            #expect(await heard.values.isEmpty)
            #expect(try await f.identity.existing() != nil)
            #expect(!(await f.outbox.paused))
        }
    }

    /// His own "Sign out" on this Mac is not "signed out from another device": no hook, the key slot is never touched.
    @Test func hisOwnSignOutNeverCallsTheHook() async throws {
        let (f, heard) = try await signedIn()
        try await f.account.signOut()
        #expect(await heard.values.isEmpty)
    }

    @Test func theLineNamesTheDeviceAndTheDateNeverAnId() {
        let line = BackendCloudSignedOutElsewhere(sub: "s", deviceId: "3f2a-id", byName: "iPhone", at: 1_800_000_000_000).line
        #expect(line.hasPrefix("Signed out from iPhone on "))
        #expect(!line.contains("3f2a-id"))
        #expect(BackendCloudSignedOutElsewhere(sub: "s", deviceId: "d", byName: nil, at: 0).line.hasPrefix("Signed out from another of your devices on "))
    }
}
