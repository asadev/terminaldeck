import Foundation

/// The last CLI report is not an invoice or an account balance. Never sum cumulative reports.
public enum ChatReportedUsage {
    public static func metrics(_ raw: NativeRPCValue, cost: NativeRPCValue = .missing) -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = []
        for (name, keys) in [("inputTokens", ["inputTokens", "input_tokens"]),
            ("outputTokens", ["outputTokens", "output_tokens"]), ("totalTokens", ["totalTokens", "total_tokens"]),
            ("cachedInputTokens", ["cachedInputTokens", "cache_read_input_tokens"]),
            ("cacheWriteTokens", ["cacheWriteTokens", "cache_creation_input_tokens"])] {
            if let number = keys.compactMap({ raw[$0].number }).first, number >= 0, number.rounded(.down) == number {
                fields.append(.init(name, .number(number)))
            }
        }
        if let number = cost.number, number >= 0 { fields.append(.init("costUSD", .number(number))) }
        return .object(fields)
    }
    public static func latest(_ events: [HootChatEvent]) -> NativeRPCValue {
        for event in events.reversed() {
            let value = event.record.value
            let figures: NativeRPCValue
            var scope = "Latest provider report"
            if value["cliUsage"].fields != nil {
                figures = metrics(value["cliUsage"], cost: value["cliUsage"]["costUSD"])
                scope = value["cliUsage"]["scope"].string ?? scope
            } else if event.record.kind == .completed {
                figures = metrics(value["usage"].isNullish ? value : value["usage"], cost: value["costUSD"])
            } else { continue }
            guard !(figures.fields ?? []).isEmpty else { continue }
            return figures.setting("provider", .string(event.provider.rawValue)).setting("turnId", .string(event.turnID))
                .setting("reportedAt", .number(event.at)).setting("scope", .string(scope))
                .setting("source", .string("CLI-reported values; not an account balance or verified bill"))
        }
        return .null
    }
}
