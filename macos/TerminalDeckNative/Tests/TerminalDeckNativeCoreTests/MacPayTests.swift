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
        #expect(!status.showsSubscription)
    }
    @Test(arguments: [CloudSubscription.State.none, .lapsed, .paid, .gift])
    func onWalksEveryPaidPlaceAndDoesNotInventCapabilities(_ state: CloudSubscription.State) {
        let status = CloudSubscriptionSnapshot(lastAnswer: .init(paywall: .on, state: state), available: true)
        for place in CloudPaidPlace.allCases {
            #expect(status.offers(place) == (state == .paid || state == .gift), "\(place)")
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
        #expect(CloudSubscriptionPage.subscribe == "Subscribe in the Terminal Deck app on your iPhone or Android phone")
    }
    @Test func toolAndCommandProjectionPreservesLocalWorkAndWhatsApp() {
        let projection = CloudSubscriptionOffers()
        let paidTools = ["cloud.status", "cloud.sync", "cloud.secrets", "cloud.session_move", "cloud.reach.status", "machines.look", "remote.status", "phone.alerts", "ai_apps.internet"]
        let localTools = ["sessions.start", "files.read", "servers.details", "devices.list", "simulators.list", "whatsapp.agents", "cloud.subscription", "memory.read"]
        for tool in paidTools + localTools { #expect(projection.showsTool(tool) == (tool != "cloud.subscription")) }
        projection.update(.init(lastAnswer: .init(paywall: .on, state: .none), available: true))
        for tool in paidTools { #expect(!projection.showsTool(tool), "\(tool)") }
        for tool in localTools { #expect(projection.showsTool(tool), "\(tool)") }
        for id in ["app.join", "join-remote", "cloud-page", "settings:cloud", "devices"] { #expect(!projection.showsCommand(id)) }
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
