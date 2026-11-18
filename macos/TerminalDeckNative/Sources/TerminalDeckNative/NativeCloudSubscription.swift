import SwiftUI
import TerminalDeckNativeCore

/// Behaviour seam for the Settings/shell design lanes. It reads observable state; never edits layout or saved choices.
@MainActor enum NativeCloudOffers {
    static func shows(_ place: CloudPaidPlace, existing: Bool = true) -> Bool {
        NativeCloudAccount.shared.snapshot.subscription.offers(place, existing: existing)
    }
    static func showsSession(_ target: SessionTarget?) -> Bool {
        target?.machineId == nil || shows(.otherComputerSessions)
    }
    static func showsArtifact(cloudOnly: Bool) -> Bool {
        !cloudOnly || shows(.artifactCloudActions)
    }
    static var showsSubscription: Bool { NativeCloudAccount.shared.snapshot.subscription.showsSubscription }
}

/// Plain placeholders only. Fable owns their final drawing; the contract is the model, id, title and fields below.
struct NativeCloudSubscriptionRow: View {
    var model: NativeCloudAccount = .shared
    @Environment(\.deckSettingsOpen) private var open
    var body: some View {
        if model.snapshot.subscription.showsSubscription {
            DeckSettingsLinkRow(title: CloudSubscriptionPage.title, symbol: "cloud", value: model.snapshot.subscription.lastAnswer.map(CloudSubscriptionPage.rowValue)) {
                open(CloudSubscriptionPage.id)
            }
        }
    }
}

struct NativeCloudSubscriptionPage: View {
    var model: NativeCloudAccount = .shared
    var body: some View {
        if model.snapshot.subscription.showsSubscription, let answer = model.snapshot.subscription.lastAnswer {
            DeckSettingsScaffold(title: CloudSubscriptionPage.title) {
                DeckSettingsGroup {
                    Text(CloudSubscriptionPage.benefit)
                    Text(CloudSubscriptionPage.price)
                    DeckSettingsRow("State", subtitle: answer.state.rawValue) { EmptyView() }
                    DeckSettingsRow("Plan", subtitle: answer.plan?.rawValue ?? "None") { EmptyView() }
                    DeckSettingsRow("Paid until", subtitle: answer.paidUntil.map(Self.date) ?? "—") { EmptyView() }
                    DeckSettingsRow("Source", subtitle: answer.source?.rawValue.capitalized ?? "—") { EmptyView() }
                    DeckSettingsRow("Included storage", subtitle: "\(answer.includedGb) GB") { EmptyView() }
                    DeckSettingsRow("Extra storage", subtitle: "\(answer.extraGb) GB") { EmptyView() }
                    Text(CloudSubscriptionPage.subscribe)
                }
            }
        }
    }
    private static func date(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000).formatted(date: .abbreviated, time: .omitted)
    }
}
