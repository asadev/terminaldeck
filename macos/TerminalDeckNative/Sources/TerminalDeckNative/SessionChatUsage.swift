import SwiftUI
import TerminalDeckNativeCore

private struct SessionChatUsageKey: EnvironmentKey {
    static let defaultValue: NativeUsageState? = nil
}
extension EnvironmentValues {
    var sessionChatUsage: NativeUsageState? {
        get { self[SessionChatUsageKey.self] }
        set { self[SessionChatUsageKey.self] = newValue }
    }
}

struct SessionChatUsagePanel: View {
    let report: UsageReport?
    let provider: String
    var now: Double = Date().timeIntervalSince1970 * 1000
    var body: some View {
        let rows = SessionChatUsageSummary.rows(report, now: now)
        VStack(alignment: .leading, spacing: 12) {
            Text("Account usage").font(.headline)
            HStack(spacing: 6) {
                Text(TerminalAgent.name(provider))
                if let account = report?.reportedAccount?.name { Text(account).foregroundStyle(.secondary) }
            }.font(.callout)
            if rows.isEmpty {
                Text(report == nil ? "Waiting for the account's usage reading." :
                    report?.reason ?? "This account has not reported usage limits yet.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(row.title)
                        Spacer()
                        Text(row.percent.map { UsageFormat.percent($0) + " used" } ?? "Not reported")
                            .monospacedDigit()
                    }.font(.callout)
                    if let percent = row.percent {
                        ProgressView(value: min(100, max(0, percent)), total: 100).tint(.accentColor)
                    }
                    Text(row.reset).font(.caption).foregroundStyle(.secondary)
                    if let note = row.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }.accessibilityElement(children: .combine)
            }
        }.padding(16).frame(width: 340, alignment: .leading)
    }
}
