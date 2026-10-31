import Foundation

/// Plain words for the same account windows shown by the session header. Missing and expired
/// figures remain unknown; they never become zero percent used.
public enum SessionChatUsageSummary {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let percent: Double?
        public let reset: String
        public let note: String?
        public var summary: String {
            "\(title): \(percent.map { UsageFormat.percent($0) + " used" } ?? "Usage not reported"). \(reset)"
        }
    }
    public static func rows(_ report: UsageReport?, now: Double = Date().timeIntervalSince1970 * 1000,
                            formatReset: (Double, Double) -> String = UsageReadout.resetInstant) -> [Row] {
        (report?.readings ?? []).map { reading in
            let readout = UsageReadout.of(reading, now: now, format: formatReset)
            let title: String
            switch reading.window {
            case .fiveHour: title = "5-hour window"
            case .weekly:
                if let suffix = reading.label.firstIndex(of: "("), !reading.label.lowercased().contains("all models") {
                    title = "Weekly window " + reading.label[suffix...]
                } else { title = "Weekly window" }
            case .monthly: title = "Monthly window"
            case .other: title = reading.label.isEmpty ? "Usage window" : reading.label
            }
            let reset = readout.state == .expired ? "This window has reset; waiting for a new reading." :
                readout.reset.map { "Resets \($0)." } ?? "Reset time not reported."
            return Row(id: reading.id, title: title, percent: readout.percent, reset: reset,
                       note: readout.state == .aged ? "Last reported reading; it may have changed." : nil)
        }
    }
    public static func wire(_ report: NativeRPCValue, now: Double = Date().timeIntervalSince1970 * 1000) -> NativeRPCValue {
        .array(rows(UsageReport.decode(report.foundation), now: now).map { row in
            .object([.init("id", .string(row.id)), .init("window", .string(row.title)),
                     .init("percentUsed", row.percent.map(NativeRPCValue.number) ?? .null),
                     .init("reset", .string(row.reset)), .init("summary", .string(row.summary)),
                     .init("note", row.note.map(NativeRPCValue.string) ?? .null)])
        })
    }
}
