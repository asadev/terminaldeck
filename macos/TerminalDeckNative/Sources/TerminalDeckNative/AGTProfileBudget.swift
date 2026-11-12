import Charts
import SwiftUI
import TerminalDeckNativeCore

/// Inputs belong to the profile's one save owner, not a separate budget store.
struct AGTProfileBudget: View {
    let value: NativeRPCValue
    let isAPI: Bool
    @Binding var monthlyLimit: Double?
    @Binding var warningPercent: Int
    @Binding var exhaustionAction: String
    @Binding var perTaskTokens: Int?
    var busy = false
    let changed: () -> Void

    var body: some View {
        if value["unit"].string == "unknown" {
            Text("This account's billing type is not confirmed. Token readings stay visible on Dashboard.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(20)
        } else if !["usd", "tokens"].contains(value["unit"].string ?? "") {
            Text(value["message"].string ?? "Monthly budget data is unavailable.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(20)
        } else {
        Form {
            Section("This month") {
                HStack(alignment: .firstTextBaseline) {
                    Text(isAPI ? "Recorded API cost" : "Tokens this month").foregroundStyle(.secondary)
                    Spacer()
                    Text(usedLabel).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                }
                if let limit = monthlyLimit, limit > 0, let used = value["used"].number {
                    ProgressView(value: min(1, max(0, used / limit))).tint(.blue)
                    Text("\(usedLabel) / \(limitLabel(limit))").font(.caption).foregroundStyle(.secondary)
                }
                let days = value["daily"].elements ?? []
                if !days.isEmpty {
                    Chart(days, id: \.compact) { day in
                        if let date = day["day"].string, let amount = day[isAPI ? "costUSD" : "tokens"].number {
                            BarMark(x: .value("Day", date), y: .value(isAPI ? "USD" : "Tokens", amount))
                                .foregroundStyle(Color.blue.opacity(0.75)).cornerRadius(2)
                        }
                    }.chartXAxis(.hidden).frame(height: 170).accessibilityLabel("Usage by day this month")
                } else if value["daily"].elements != nil {
                    Text("No daily usage has been recorded this month.").font(.callout).foregroundStyle(.secondary)
                        .frame(height: 170, alignment: .center)
                } else {
                    Text("Daily usage is unavailable.").font(.callout).foregroundStyle(.secondary).frame(height: 170)
                }
            }
            Section("Budget") {
                LabeledContent {
                    HStack(spacing: 6) {
                        if isAPI { Text("$").foregroundStyle(.secondary) }
                        NativeSessionNumberField("No budget", value: $monthlyLimit, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 170)
                            .accessibilityLabel(isAPI ? "Monthly budget in US dollars" : "Monthly token budget")
                        if !isAPI { Text("tokens").font(.caption).foregroundStyle(.secondary) }
                    }
                } label: { label("Monthly budget", detail: "Leave blank for no monthly limit.") }
                LabeledContent {
                    Picker("Warn me at", selection: $warningPercent) {
                        ForEach(Array(Set([50, 80, 90, warningPercent])).sorted(), id: \.self) { Text("\($0)%").tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().nativeUIGGreyControl().frame(maxWidth: 190)
                } label: { label("Warn me at", detail: "Send a warning before the budget is used up.") }
                LabeledContent {
                    Picker("When it runs out", selection: $exhaustionAction) {
                        Text("Pause the agent").tag("pause")
                        Text("Only warn me").tag("warn")
                    }.labelsHidden()
                } label: { label("When it runs out", detail: "Choose what happens when the budget is reached.") }
                LabeledContent {
                    HStack(spacing: 6) {
                        NativeSessionNumberField("App default", value: $perTaskTokens, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 170)
                            .accessibilityLabel("Per-task token budget")
                        Text("tokens").font(.caption).foregroundStyle(.secondary)
                    }
                } label: { label("Per task budget", detail: "A warning note on the task at the Warn me at share of these tokens. Nothing stops it.") }
            }
        }.formStyle(.grouped).disabled(busy)
        .onChange(of: monthlyLimit) { _, _ in changed() }
        .onChange(of: warningPercent) { _, _ in changed() }
        .onChange(of: exhaustionAction) { _, _ in changed() }
        .onChange(of: perTaskTokens) { _, _ in changed() }
        }
    }
    private func label(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private var usedLabel: String {
        guard let amount = value["used"].number else { return "—" }
        return isAPI ? amount.formatted(.currency(code: "USD")) : amount.formatted(.number.notation(.compactName))
    }
    private func limitLabel(_ amount: Double) -> String {
        isAPI ? amount.formatted(.currency(code: "USD")) : amount.formatted(.number.notation(.compactName)) + " tokens"
    }
}
