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
    var checking = false
    var refresh: () -> Void = {}
    var body: some View {
        let readouts = (report?.numberedReadings ?? []).map { UsageReadout.of($0, now: now) }
        DeckMenuSurface {
            NativeUsagePlanPanel(provider: provider, agent: TerminalAgent.name(provider),
                account: report?.accountLabel.map(DeckAccountWords.shown), readouts: readouts, now: now,
                checking: checking, note: report?.reason, missing: report?.missingNumbersNote, refresh: refresh)
        }
        .frame(width: 280, alignment: .leading)
    }
}
