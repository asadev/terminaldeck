import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("MacPayTests — subscription contract and complete paid-place matrix")
struct MacPayTests {
    @Test(arguments: [CloudSubscription.State.none, .lapsed, .paid, .gift])
    func offWalksEveryPaidPlaceWithoutChangingExistingCapabilities(_ state: CloudSubscription.State) {
        let status = CloudSubscriptionSnapshot(lastAnswer: .init(paywall: .off, state: state), available: true)
        for place in CloudPaidPlace.allCases {
            #expect(status.offers(place, existing: true), "\(place)")
            #expect(!status.offers(place, existing: false), "\(place)")
        }
        // 19 Nov: a gift shows its plan with the paywall off too; nothing else is new while it is off.
        #expect(status.showsSubscription == (state == .gift))
        #expect(!status.limitsRemoteToSessions)
    }
    @Test(arguments: [CloudSubscription.State.none, .lapsed, .paid, .gift])
    func onWalksEveryPaidPlaceAndDoesNotInventCapabilities(_ state: CloudSubscription.State) {
        let status = CloudSubscriptionSnapshot(lastAnswer: .init(paywall: .on, state: state), available: true)
        for place in CloudPaidPlace.allCases {
            // 19 Nov free plan: a free account keeps its devices and its other computers' sessions.
            #expect(status.offers(place) == (state == .paid || state == .gift || CloudPaidPlace.freeAccountPlaces.contains(place)), "\(place)")
            #expect(!status.offers(place, existing: false), "\(place)")
        }
        #expect(status.showsSubscription)
    }
    @Test func noAnswerAndOldServiceKeepTodaysBehaviourButRetainLastAnswer() {
        var status = CloudSubscriptionSnapshot()
        for place in CloudPaidPlace.allCases { #expect(status.offers(place)) }
        let lapsed = CloudSubscription(paywall: .on, state: .lapsed, plan: .yearly, paidUntil: 1,
                                       source: .apple, extraGb: 300, dataKeptUntil: 90)
        status.received(lapsed)
        #expect(!status.allowsCloudServices)
        status.received(nil)
        #expect(status.lastAnswer == lapsed)
        #expect(!status.available)
        #expect(!status.showsSubscription)
        for place in CloudPaidPlace.allCases { #expect(status.offers(place)) }
    }
    @Test func serviceDatesDoNotBecomeASecondEntitlementClock() throws {
        let body = Data(#"{"paywall":"on","state":"paid","plan":"yearly","paidUntil":1,"source":"google","includedGb":100,"extraGb":500,"offer":true,"dataKeptUntil":null}"#.utf8)
        let value = try CloudWire.decode(CloudSubscription.self, from: body)
        #expect(value.paidUntil == 1)
        #expect(value.extraGb == 500)
        #expect(CloudSubscriptionPage.rowValue(value).hasPrefix("Yearly · "))
        #expect(CloudSubscriptionSnapshot(lastAnswer: value, available: true).allowsCloudServices)
        #expect(value.wireValue["dataKeptUntil"] == .null)
        #expect(try CloudWire.decode(CloudSubscription.self, from: CloudWire.canonical(value)) == value)
    }
    @Test func previewOnlyAddsTheSubscriptionRowWithoutChangingAnyOldOffer() {
        let snapshot = CloudSubscriptionSnapshot(lastAnswer: .init(paywall: .off, state: .none, offer: true), available: true)
        #expect(snapshot.showsSubscription)
        for place in CloudPaidPlace.allCases { #expect(snapshot.offers(place)) }
        #expect(CloudSubscriptionPage.subscribe == "Subscribe in the Terminal Deck app on your phone")
        #expect(!snapshot.limitsRemoteToSessions)
    }

    // MARK: 19 Nov free plan (PAYMENTS-DESIGN.md "API for the app seats")

    @Test func tierAndStorageAreReadAndAnOlderServiceFallsBackToTheState() throws {
        let body = Data(#"{"paywall":"on","state":"gift","tier":"paid","plan":null,"paidUntil":null,"source":"gift","includedGb":100,"extraGb":200,"canBuyStorage":true,"offer":true,"dataKeptUntil":null}"#.utf8)
        let gift = try CloudWire.decode(CloudSubscription.self, from: body)
        #expect(gift.tier == .paid && gift.canBuyStorage == true && gift.accountTier == .paid)
        #expect(!gift.limitsRemoteToSessions)
        #expect(gift.wireValue["tier"] == .string("paid") && gift.wireValue["canBuyStorage"] == .bool(true))
        #expect(try CloudWire.decode(CloudSubscription.self, from: CloudWire.canonical(gift)) == gift)
        // An older service (no tier, no canBuyStorage): the tier comes from the state.
        let old = try CloudWire.decode(CloudSubscription.self, from: Data(#"{"paywall":"on","state":"lapsed","includedGb":100,"extraGb":0,"offer":false}"#.utf8))
        #expect(old.tier == nil && old.canBuyStorage == nil && old.accountTier == .free)
        #expect(old.limitsRemoteToSessions)
        #expect(old.wireValue["tier"] == .string("free") && old.wireValue["canBuyStorage"] == .bool(false))
    }
    @Test(arguments: [CloudSubscription.State.none, .lapsed, .paid, .gift])
    func onlyAFreeAccountWithThePaywallOnIsLimitedToSessions(_ state: CloudSubscription.State) {
        let free = state == .none || state == .lapsed
        for paywall in [CloudSubscription.Paywall.off, .on] {
            for tier in [nil, free ? CloudSubscription.Tier.free : .paid] {
                let answer = CloudSubscription(paywall: paywall, state: state, tier: tier)
                #expect(answer.limitsRemoteToSessions == (paywall == .on && free), "\(paywall) \(state) \(String(describing: tier))")
                #expect(CloudSubscriptionSnapshot(lastAnswer: answer, available: true).limitsRemoteToSessions == (paywall == .on && free))
                // Unknown (a failed or missing read): nothing is limited, as every payment rule here.
                #expect(!CloudSubscriptionSnapshot(lastAnswer: answer, available: false).limitsRemoteToSessions)
            }
        }
        // The service's tier decides over the state when both are sent.
        #expect(CloudSubscription(paywall: .on, state: .none, tier: .paid).limitsRemoteToSessions == false)
    }
    @Test func theProcessWideAnswerFollowsEveryUpdate() {
        let projection = CloudSubscriptionOffers()
        #expect(!projection.limitsRemoteToSessions, "no answer yet: nothing limited")
        projection.update(.init(lastAnswer: .init(paywall: .on, state: .none, tier: .free), available: true))
        #expect(projection.limitsRemoteToSessions)
        projection.update(.init(lastAnswer: .init(paywall: .on, state: .gift, tier: .paid), available: true))
        #expect(!projection.limitsRemoteToSessions)
        projection.update(.init(lastAnswer: .init(paywall: .off, state: .none, tier: .free), available: true))
        #expect(!projection.limitsRemoteToSessions)
        // A gift is the one row that is new with the paywall off.
        projection.update(.init(lastAnswer: .init(paywall: .off, state: .gift, tier: .paid), available: true))
        #expect(projection.showsTool("cloud.subscription"))
    }
    @Test func watchersHearOnlyAChangeOfTheLimit() {
        final class Heard: @unchecked Sendable {
            private let lock = NSLock(); private var values: [Bool] = []
            func add(_ value: Bool) { lock.withLock { values.append(value) } }
            var all: [Bool] { lock.withLock { values } }
        }
        let projection = CloudSubscriptionOffers(), heard = Heard()
        projection.watchRemoteLimit(owner: "fixture") { heard.add($0) }
        let free = CloudSubscriptionSnapshot(lastAnswer: .init(paywall: .on, state: .lapsed, tier: .free), available: true)
        let paid = CloudSubscriptionSnapshot(lastAnswer: .init(paywall: .on, state: .paid, tier: .paid), available: true)
        projection.update(paid)
        projection.update(free)          // the plan read that made it free
        projection.update(free)          // the same answer again: nothing
        projection.update(paid)          // paid again
        #expect(heard.all == [true, false])
        // One watcher per owner: a later one replaces it, nil removes it.
        let second = Heard()
        projection.watchRemoteLimit(owner: "fixture") { second.add($0) }
        projection.update(free)
        projection.watchRemoteLimit(owner: "fixture", nil)
        projection.update(paid)
        #expect(heard.all == [true, false] && second.all == [true])
    }
    @Test func toolAndCommandProjectionPreservesLocalWorkAndWhatsApp() {
        let projection = CloudSubscriptionOffers()
        let paidTools = ["cloud.status", "cloud.sync", "cloud.secrets", "cloud.session_move", "cloud.reach.status", "machines.ports", "machines.manage", "remote.status", "phone.alerts", "ai_apps.internet"]
        // 19 Nov free plan: other computers' sessions stay with a free account, so do their tools.
        let sessionTools = ["machines.look", "machines.session", "machines.copilot", "machines.upload"]
        let localTools = ["sessions.start", "files.read", "servers.details", "devices.list", "simulators.list", "whatsapp.agents", "cloud.subscription", "memory.read"]
        for tool in paidTools + localTools { #expect(projection.showsTool(tool) == (tool != "cloud.subscription")) }
        projection.update(.init(lastAnswer: .init(paywall: .on, state: .none), available: true))
        for tool in paidTools { #expect(!projection.showsTool(tool), "\(tool)") }
        for tool in localTools + sessionTools { #expect(projection.showsTool(tool), "\(tool)") }
        for id in ["app.join", "join-remote", "cloud-page", "settings:cloud"] { #expect(!projection.showsCommand(id)) }
        for id in ["devices", "settings:devices"] { #expect(projection.showsCommand(id), "\(id)") }
        for id in ["session.new", "view.files", "app.preferences"] { #expect(projection.showsCommand(id)) }
    }
    @Test func subscriptionSurvivesEveryAccountSnapshotProjection() {
        var snapshot = CloudAccountSnapshot(phase: .signedIn, gate: .closed, waitingRecords: 7)
        snapshot.subscription.received(.init(paywall: .on, state: .lapsed))
        #expect(snapshot.carried(phase: .paused, problem: nil).subscription == snapshot.subscription)
        #expect(snapshot.named("Person").subscription == snapshot.subscription)
        #expect(snapshot.withLocalProgress(coverage: [], waitingRecords: 7, blockedRecords: 0, baseline: nil, fetched: .zero).subscription == snapshot.subscription)
        #expect(snapshot.waitingRecords == 7)
    }
}
