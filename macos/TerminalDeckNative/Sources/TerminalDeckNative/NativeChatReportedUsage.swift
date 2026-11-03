import SwiftUI
import TerminalDeckNativeCore

struct NativeChatReportedUsagePanel: View {
    let reading: NativeRPCValue
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI usage report").font(.headline)
            Text(TerminalAgent.name(reading["provider"].string ?? "") + " · " + (reading["scope"].string ?? "Latest report"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach([("Input tokens", "inputTokens"), ("Output tokens", "outputTokens"), ("Total tokens", "totalTokens"),
                     ("Cached input tokens", "cachedInputTokens"), ("Cache write tokens", "cacheWriteTokens")], id: \.1) { title, key in
                if let number = reading[key].number { HStack { Text(title); Spacer(); Text(number.formatted(.number.precision(.fractionLength(0)))).monospacedDigit() } }
            }
            HStack {
                Text("Reported cost")
                Spacer()
                Text(reading["costUSD"].number.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(2...6))) } ?? "Not reported").monospacedDigit()
            }
            if let at = reading["reportedAt"].number { Text(Date(timeIntervalSince1970: at / 1000).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            Text("The latest provider report, including any cumulative figures it supplies. This is separate from account limits and your bill.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(width: 340)
    }
}
