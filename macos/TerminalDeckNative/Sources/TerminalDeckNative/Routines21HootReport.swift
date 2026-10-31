import SwiftUI
import TerminalDeckNativeCore

struct Routines21HootReport: View {
    let report: NativeRPCValue
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: report["runStatus"].string == "ok" ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(report["runStatus"].string == "ok" ? ROUTINESKit.good : ROUTINESKit.bad)
                Text(report["routine"].string ?? "Routine").font(.callout.weight(.semibold))
                Spacer()
                Text(Date(timeIntervalSince1970: (report["at"].number ?? 0) / 1000).formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(report["report"]["text"].string ?? "").font(.callout).textSelection(.enabled)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
