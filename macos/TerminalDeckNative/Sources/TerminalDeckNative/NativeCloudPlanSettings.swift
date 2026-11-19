import SwiftUI

// "Terminal Deck Cloud" in Settings (notes/overnight-20261118/PAYMENTS-DESIGN.md, section "Apps", the Mac, and its
// "19 Nov changes", which win):
//   free (paywall on, tier free): ONE row "Terminal Deck Cloud" on Profile, beside Sign-in, that opens a small page: one
//     line of what it gives, the price, and "Subscribe in the Terminal Deck app on your phone" (this Mac sells nothing);
//   paid: the same row shows the plan and its date, and the page shows the plan;
//   gift (paid at no charge): "Terminal Deck Cloud · Gift · no charge", the paywall on or off;
//   paywall off: nothing else (until Asad says "start charging").
// These are plain views over `NativeCloudPlanFacts`. Where the facts come from is ONE seam, `NativeCloudPlanSeam.current`
// (the state is written on lane/mac-pay). Design: notes/review-20261118/DESIGN-settings.md section 8.

/// What the Mac knows about the account's plan: the fields of the service's `GET /v1/subscription`, as the views take them.
struct NativeCloudPlanFacts: Equatable, Sendable {
    enum State: String, Sendable { case paid, gift, none, lapsed }
    enum Plan: String, Sendable { case monthly, yearly }
    enum Source: String, Sendable { case apple, google, gift }
    /// The row is drawn for this account (the service's `paywall == "on"`, `offer` for a preview account, or a gift).
    /// While false nothing of this file is drawn anywhere.
    var shows: Bool
    var state: State = .none
    var plan: Plan? = nil
    var paidUntil: Date? = nil
    var source: Source? = nil
    var includedGb = 100
    var extraGb = 0
    /// After the plan ended: the day until which the Cloud data is kept.
    var dataKeptUntil: Date? = nil
    /// The price as words. The store's own price text can replace these once the phones report it.
    var monthlyPrice = "$8.00"
    var yearlyPrice = "$67.00"

    /// Cloud can be used: paid, or given to the account.
    var entitled: Bool { state == .paid || state == .gift }
}

/// SEAM (notes/review-20261118/LOGIC-HANDOFF.md, "Terminal Deck Cloud row"): the account's plan as this Mac knows it.
/// The observable subscription answers nil while charging is off or the state is not known.
@MainActor
enum NativeCloudPlanSeam {
    static var current: @MainActor () -> NativeCloudPlanFacts? = { liveFacts() }

    static func liveFacts() -> NativeCloudPlanFacts? {
        let subscription = NativeCloudAccount.shared.snapshot.subscription
        guard subscription.showsSubscription, let answer = subscription.lastAnswer else { return nil }
        return NativeCloudPlanFacts(shows: true,
            state: .init(rawValue: answer.state.rawValue) ?? .none,
            plan: answer.plan.flatMap { .init(rawValue: $0.rawValue) },
            paidUntil: answer.paidUntil.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            source: answer.source.flatMap { .init(rawValue: $0.rawValue) },
            includedGb: answer.includedGb, extraGb: answer.extraGb,
            dataKeptUntil: answer.dataKeptUntil.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }
    /// The facts to draw, or nil = draw nothing (paywall off, signed out, not known).
    static func shown() -> NativeCloudPlanFacts? {
        guard let facts = current(), facts.shows else { return nil }
        return facts
    }
}

/// The words of the row and the page. Plain: names and dates, no ids, nothing about what comes later.
enum NativeCloudPlanWords {
    static let title = "Terminal Deck Cloud"
    static let symbol = "cloud.fill"
    /// One line of what it adds: a free account's sessions on its computers, from every device, are free already
    /// (19 Nov; the phones' three lines in one).
    static func gives(_ facts: NativeCloudPlanFacts) -> String {
        "Browser, simulators and screen sharing, Cloud sync and tasks on every device, and \(facts.includedGb) GB of Cloud storage."
    }
    static func price(_ facts: NativeCloudPlanFacts) -> String { "\(facts.monthlyPrice) a month, or \(facts.yearlyPrice) a year" }
    static let subscribe = "Subscribe in the Terminal Deck app on your phone"
    /// A plan given to the account: the paid plan at no charge (Asad, 19 Nov: "it should show which value subscription
    /// it is but it is not paid, it is a gift").
    static let gift = "Gift · no charge"

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).day().month(.abbreviated).year())
    }
    static func plan(_ plan: NativeCloudPlanFacts.Plan?) -> String {
        switch plan {
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        case nil: "Terminal Deck Cloud"
        }
    }
    static func source(_ source: NativeCloudPlanFacts.Source?) -> String? {
        switch source {
        case .apple: "Apple"
        case .google: "Google Play"
        case .gift, nil: nil
        }
    }
    /// The row's short state at its right: the plan and its date when entitled, when it ended after that, else nothing.
    static func rowValue(_ facts: NativeCloudPlanFacts, calendar: Calendar = .current) -> String? {
        switch facts.state {
        case .paid:
            guard let until = facts.paidUntil else { return plan(facts.plan) }
            return plan(facts.plan) + " · paid until " + day(until, calendar: calendar)
        case .gift: return gift
        case .lapsed: return facts.paidUntil.map { "Ended " + day($0, calendar: calendar) } ?? "Ended"
        case .none: return nil
        }
    }
    /// After the plan ended: when, and until when the data is kept (each only when the account says it).
    static func ended(_ facts: NativeCloudPlanFacts, calendar: Calendar = .current) -> String? {
        guard facts.state == .lapsed else { return nil }
        let when = facts.paidUntil.map { "Your plan ended on " + day($0, calendar: calendar) + "." } ?? "Your plan has ended."
        let kept = facts.dataKeptUntil.map { " Your Cloud data is kept until " + day($0, calendar: calendar) + "." } ?? ""
        return when + kept
    }
    static func storage(_ facts: NativeCloudPlanFacts) -> String { "\(facts.includedGb + max(0, facts.extraGb)) GB" }
    static func storageInfo(_ facts: NativeCloudPlanFacts) -> String? {
        facts.extraGb > 0 ? "\(facts.includedGb) GB with the plan and \(facts.extraGb) GB of extra storage." : nil
    }
    /// Where the plan is changed: in the phone app it was bought in (a plan given to the account has nothing to change).
    static func manage(_ facts: NativeCloudPlanFacts) -> String? {
        switch facts.source {
        case .apple: "Change or cancel it in the Terminal Deck app on your iPhone."
        case .google: "Change or cancel it in the Terminal Deck app on your Android phone."
        case .gift, nil: nil
        }
    }
}

/// The ONE row on Profile: "Terminal Deck Cloud", its state at the right, a chevron.
struct NativeCloudPlanRow: View {
    let facts: NativeCloudPlanFacts
    let action: () -> Void
    var body: some View {
        DeckSettingsLinkRow(title: NativeCloudPlanWords.title, symbol: NativeCloudPlanWords.symbol, tint: .indigo,
                            value: NativeCloudPlanWords.rowValue(facts), action: action)
    }
}

/// The small page behind the row. Not entitled: what it gives in one line, the price, and where to subscribe (this Mac
/// sells nothing, so the page has no button). Entitled: the plan, its date, where it was paid, the storage.
struct NativeCloudPlanPage: View {
    let facts: NativeCloudPlanFacts
    static let tile: CGFloat = 56

    var body: some View {
        DeckSettingsScaffold(title: NativeCloudPlanWords.title) {
            VStack(spacing: DeckTokens.Spacing.s8) {
                DeckSettingsIconTile(symbol: NativeCloudPlanWords.symbol, tint: .indigo, size: Self.tile, radius: 13, glyph: 26)
                    .padding(.bottom, DeckTokens.Spacing.s4)
                Text(NativeCloudPlanWords.title).font(.system(size: 17, weight: .semibold))
                if facts.entitled {
                    if facts.state == .gift {
                        Text(NativeCloudPlanWords.gift).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
                    }
                } else {
                    if let ended = NativeCloudPlanWords.ended(facts) {
                        Text(ended).font(DeckSettingsLook.rowTitle).foregroundStyle(.primary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 400)
                    }
                    Text(NativeCloudPlanWords.gives(facts)).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 400)
                    Text(NativeCloudPlanWords.price(facts)).font(.system(size: 15, weight: .semibold))
                        .padding(.top, DeckTokens.Spacing.s8)
                    Text(NativeCloudPlanWords.subscribe).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 400)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, DeckTokens.Spacing.s24)
            .accessibilityElement(children: .contain)
            if facts.entitled {
                DeckSettingsGroup {
                    if facts.state == .paid {
                        DeckSettingsRow("Plan", state: NativeCloudPlanWords.plan(facts.plan))
                        if let until = facts.paidUntil { DeckSettingsRow("Paid until", state: NativeCloudPlanWords.day(until)) }
                        if let source = NativeCloudPlanWords.source(facts.source) { DeckSettingsRow("Paid through", state: source) }
                    }
                    DeckSettingsRow("Storage", info: NativeCloudPlanWords.storageInfo(facts), state: NativeCloudPlanWords.storage(facts))
                }
                if let manage = NativeCloudPlanWords.manage(facts) {
                    Text(manage).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                }
                // A gift can still be upgraded to the paid plan (Asad, 19 Nov: "so that user can at least upgrade").
                if facts.state == .gift {
                    Text(NativeCloudPlanWords.subscribe).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                }
            }
        }
    }
}
