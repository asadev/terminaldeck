import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("MacPayTests — existing sign-in, HTTP fallback, calm refresh and retained data", .serialized)
struct MacPayTests {
    @Test func signedOutHasNoSubscriptionRequest() async throws {
        let f = try CloudAccountFixture.make()
        await f.account.refreshSubscriptionIfDue()
        #expect(await f.server.subscriptionCalls == 0)
        #expect(await f.account.state().subscription.allowsCloudServices)
    }
    @Test func oldService404KeepsExactCloudBehaviourAndNoNewTools() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let status = await f.account.state()
        #expect(status.visible(at: 0))
        #expect(!status.subscription.available)
        #expect(await f.server.subscriptionCalls == 1)
        #expect(status.waitingRecords == 2)
        let entries = try await BackendCloudAccountTools.registrations(service: f.account, now: 0, signin: { _ in })
        #expect(entries.map { $0.0.id } == BackendCloudAccountTools.ids)
        #expect(!(await f.outbox.paused))
    }
    @Test(arguments: [CloudSubscription.State.none, .lapsed, .paid, .gift])
    func realAccountReadsServiceAndGatesAllOffers(_ state: CloudSubscription.State) async throws {
        let f = try CloudAccountFixture.make()
        try await f.server.setSubscription(.init(paywall: .on, state: state, plan: .monthly, paidUntil: 1, source: state == .gift ? .gift : .google))
        _ = try await f.signin()
        let status = await f.account.state()
        #expect(status.phase == .signedIn)
        #expect(status.subscription.available)
        for place in CloudPaidPlace.allCases {
            #expect(status.subscription.offers(place) == (state == .paid || state == .gift || CloudPaidPlace.freeAccountPlaces.contains(place)))
        }
        #expect(try await f.identity.existing() != nil)
        let entries = try await BackendCloudAccountTools.registrations(service: f.account, now: 0, signin: { _ in })
        #expect(entries.contains { $0.0.id == "cloud.subscription" })
        #expect(entries.contains { $0.0.id == "cloud.sync" } == (state == .paid || state == .gift))
        if state == .none || state == .lapsed { #expect(await f.transport.stateCalls == 0) }
        // 19 Nov free plan: every account's sign-in registers this Mac, so its other devices can reach it.
        #expect(await f.transport.registrations == 1)
    }
    @Test func aFreeAccountRegistersThisMacForItsDevicesAndStartsNoCloudSync() async throws {
        let f = try CloudAccountFixture.make()
        try await f.server.setSubscription(.init(paywall: .on, state: .none, tier: .free, canBuyStorage: false))
        _ = try await f.signin()
        let status = await f.account.state()
        #expect(status.phase == .signedIn)
        #expect(status.subscription.limitsRemoteToSessions)
        #expect(!status.subscription.allowsCloudServices)
        #expect(await f.transport.registrations == 1, "the device record its phones and computers reach it by")
        #expect(await f.server.registered != nil)
        #expect(await f.transport.stateCalls == 0, "no Cloud status read")
        #expect(await f.outbox.flushes == 0, "no sync engine asked for anything")
        #expect(!(await f.outbox.paused))
        #expect(try await f.identity.existing() != nil)
        // Decker, 20 Nov: the Devices page lists his devices for a free account, read through the device door only.
        #expect(status.devices.count == 1)
        #expect(status.subscription.offers(.devices) && status.subscription.offers(.otherComputerSessions))
        #expect(!status.subscription.offers(.remoteMachineChoices) && !status.subscription.offers(.phoneAndWebReach))
        // A later status read is the device list again, never the Cloud status, and not more often than the recheck.
        let calls = await f.transport.deviceCalls
        try await f.account.refresh()
        #expect(await f.transport.deviceCalls == calls + 1)
        #expect(await f.transport.stateCalls == 0)
        _ = await f.account.state()
        _ = await f.account.state()
        #expect(await f.transport.deviceCalls == calls + 1, "no read loop between rechecks")
    }
    @Test func paywallOffChangesNothingForAFreeTier() async throws {
        let f = try CloudAccountFixture.make()
        try await f.server.setSubscription(.init(paywall: .off, state: .none, tier: .free, canBuyStorage: false))
        _ = try await f.signin()
        let status = await f.account.state()
        #expect(!status.subscription.limitsRemoteToSessions)
        #expect(status.subscription.allowsCloudServices)
        #expect(await f.transport.stateCalls >= 1, "Cloud as today")
    }
    @Test func lapseChangesOnlyOffersAndLeavesSyncSignInTrustAndPendingDataAlone() async throws {
        let f = try CloudAccountFixture.make()
        try await f.server.setSubscription(.init(paywall: .on, state: .paid, plan: .yearly, source: .apple))
        _ = try await f.signin()
        let before = await f.account.state()
        let identity = f.store.value(), writes = f.store.writes(), trust = f.trustSlot.bytes()
        #expect(!(await f.outbox.paused))
        #expect(!(await f.transport.stopped))
        try await f.server.setSubscription(.init(paywall: .on, state: .lapsed, plan: .yearly, source: .apple, dataKeptUntil: f.clock.now() + 90 * 86_400_000))
        f.clock.advance(300_001)
        await f.account.refreshSubscriptionIfDue()
        let after = await f.account.state()
        #expect(!after.subscription.allowsCloudServices)
        #expect(after.phase == before.phase && after.gate == before.gate)
        #expect(after.coverage == before.coverage && after.waitingRecords == before.waitingRecords)
        #expect(after.trust == before.trust && f.trustSlot.bytes() == trust)
        #expect(f.store.value() == identity && f.store.writes() == writes)
        #expect(!(await f.outbox.paused))
        #expect(!(await f.transport.stopped))
        #expect(await f.server.removals == 0)
        #expect(await f.server.logouts == 0)
    }
    @Test func refreshUsesFiveMinuteGapAndAnOutageKeepsTheAnswerButDisablesEnforcement() async throws {
        let f = try CloudAccountFixture.make()
        let value = CloudSubscription(paywall: .on, state: .none)
        try await f.server.setSubscription(value)
        _ = try await f.signin()
        for _ in 0..<10 { await f.account.refreshSubscriptionIfDue() }
        #expect(await f.server.subscriptionCalls == 1)
        await f.server.subscriptionOffline()
        f.clock.advance(300_001)
        await f.account.refreshSubscriptionIfDue()
        let status = await f.account.state().subscription
        #expect(await f.server.subscriptionCalls == 2)
        #expect(status.lastAnswer == value)
        #expect(!status.available && status.allowsCloudServices && !status.showsSubscription)
        #expect(try await f.identity.existing() != nil)
    }
    @Test(arguments: [200, 404, 500])
    func oldMalformedAndFailedAnswersAreOff(_ code: Int) async throws {
        let f = try CloudAccountFixture.make()
        try await f.server.setSubscription(nil, status: code)
        _ = try await f.signin()
        #expect(await f.account.state().subscription.allowsCloudServices)
        #expect(!(await f.account.state().subscription.showsSubscription))
    }
}
