import Foundation
import TerminalDeckNativeCore

/// Pure projections over the existing TaskStore envelope. No second owner,
/// price table, provider probe, persistence file or scheduler.
public enum BackendAGOPTRunHistory {
    public static func start(id: String, agentID: String, taskID: String?, session: BackendSessionMeta,
                             accountID: String?, at: Double, requestedModel: String?, requestedEffort: String?) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("agent_id", .string(agentID)),
            .init("task_id", taskID.map(NativeRPCValue.string) ?? .null), .init("session_id", .string(session.id)),
            .init("conversation_id", session.agentSessionId.map(NativeRPCValue.string) ?? .null),
            .init("session_name", .string(session.title)), .init("provider", .string(session.provider)),
            .init("account_id", accountID.map(NativeRPCValue.string) ?? .null), .init("cwd", .string(session.cwd)),
            .init("project_id", session.projectId.map(NativeRPCValue.string) ?? .null),
            .init("started_at", .number(at)), .init("ended_at", .null), .init("outcome", .string("working")),
            .init("tokens", .null), .init("cost_usd", .null), .init("billing_kind", .string("unknown")),
            .init("cost_source", .null), .init("needed_help", .bool(false)), .init("verified", .null), .init("summary", .null),
            .init("requested_model", requestedModel.map(NativeRPCValue.string) ?? .null),
            .init("requested_effort", requestedEffort.map(NativeRPCValue.string) ?? .null), .init("usage_days", .object([]))])
    }
    /// Already verified metadata/cost sources call this; no MCP argument or
    /// agent prose is a billing source. All amounts are measured deltas.
    public static func addUsage(_ run: NativeRPCValue, tokens: Double?, reportedAPIUSD: Double?,
                                billingKind: String, source: String?, at: Double, calendar: Calendar) throws -> NativeRPCValue {
        guard ["api", "subscription", "unknown"].contains(billingKind),
              tokens.map({ $0.isFinite && $0 >= 0 && $0 <= 1e15 }) ?? true,
              reportedAPIUSD.map({ $0.isFinite && $0 >= 0 && $0 <= 1e12 }) ?? true else {
            throw NativeRPCError.invalidArguments("The reported usage is invalid.")
        }
        guard reportedAPIUSD == nil || billingKind == "api" && source?.isEmpty == false else {
            throw NativeRPCError(code: "usage-unavailable", message: "Money needs an actual API billing and reported cost source.")
        }
        let key = day(at, calendar: calendar)
        var days = run["usage_days"].fields == nil ? NativeRPCValue.object([]) : run["usage_days"]
        var value = days[key].fields == nil ? NativeRPCValue.object([.init("day", .string(key))]) : days[key]
        var result = run.setting("billing_kind", .string(billingKind))
        if let tokens {
            result = result.setting("tokens", .number((run["tokens"].number ?? 0) + tokens))
            value = value.setting("tokens", .number((value["tokens"].number ?? 0) + tokens))
        }
        if let reportedAPIUSD {
            result = result.setting("cost_usd", .number((run["cost_usd"].number ?? 0) + reportedAPIUSD))
                .setting("cost_source", source.map(NativeRPCValue.string) ?? .null)
            value = value.setting("cost_usd", .number((value["cost_usd"].number ?? 0) + reportedAPIUSD))
        }
        value = value.setting("billing_kind", .string(billingKind))
        days = days.setting(key, value)
        return result.setting("usage_days", days)
    }
    public static func finish(_ run: NativeRPCValue, outcome: String, at: Double, summary: String?, verified: Bool?) throws -> NativeRPCValue {
        guard ["completed", "failed", "stopped", "paused", "reassigned", "lost"].contains(outcome) else {
            throw NativeRPCError.invalidArguments("The run outcome is invalid.")
        }
        guard run["ended_at"].isNullish else { return run }
        return run.setting("outcome", .string(outcome)).setting("ended_at", .number(at))
            .setting("summary", summary.map { .string(String($0.prefix(2_000))) } ?? .null)
            .setting("verified", verified.map(NativeRPCValue.bool) ?? .null)
    }
    /// Compact a removed CLOSED run once into existing TaskStore day rows.
    /// Run count and usage days differ: work crossing midnight charges actual
    /// observed delta dates, while the run count follows its actual start.
    public static func compact(_ run: NativeRPCValue, into rows: NativeRPCValue, calendar: Calendar) throws -> NativeRPCValue {
        guard run["ended_at"].number != nil, let agent = run["agent_id"].string,
              let started = run["started_at"].number else { throw NativeRPCError.invalidArguments("Only an actual finished run can be compacted.") }
        var result = rows.fields == nil ? NativeRPCValue.object([]) : rows
        let startDay = day(started, calendar: calendar), startKey = agent + ":" + startDay
        var counted = bucket(result[startKey], agent: agent, day: startDay)
        counted = add(counted, "runs", 1)
        let outcome = run["outcome"].string ?? "unknown"
        if outcome == "completed" { counted = add(counted, "completed", 1) }
        if ["completed", "failed", "stopped", "reassigned", "lost"].contains(outcome) {
            counted = add(counted, "finished", 1)
            if outcome == "completed", run["needed_help"].bool != true { counted = add(counted, "finished_without_help", 1) }
        }
        if let task = run["task_id"].string, run["verified"].bool == true {
            counted = counted.setting("verified_tasks", .array(Array(Set((counted["verified_tasks"].elements ?? []).compactMap(\.string) + [task])).sorted().map(NativeRPCValue.string)))
        }
        result = result.setting(startKey, counted)
        for field in run["usage_days"].fields ?? [] {
            let key = agent + ":" + field.key
            var usage = bucket(result[key], agent: agent, day: field.key)
            if let tokens = field.value["tokens"].number { usage = add(usage, "tokens", tokens); usage = add(usage, "token_reports", 1) }
            if let cost = field.value["cost_usd"].number, field.value["billing_kind"].string == "api" { usage = add(usage, "cost_usd", cost); usage = add(usage, "cost_reports", 1) }
            result = result.setting(key, usage)
        }
        // Preserve absence of a report without synthesizing a zero-cost run.
        if run["tokens"].isNullish { counted = add(result[startKey], "unknown_token_runs", 1); result = result.setting(startKey, counted) }
        if run["billing_kind"].string == "api", run["cost_usd"].isNullish { counted = add(result[startKey], "unknown_cost_runs", 1); result = result.setting(startKey, counted) }
        return result
    }
    public static func month(profileID: String, runs: [NativeRPCValue], compacted: NativeRPCValue,
                             calendar: Calendar, now: Double, trackedSince: Double?) throws -> NativeRPCValue {
        let date = Date(timeIntervalSince1970: now / 1_000)
        guard let interval = calendar.dateInterval(of: .month, for: date) else { throw NativeRPCError(code: "usage-unavailable", message: "This month could not be determined.") }
        let prefix = monthKey(now, calendar: calendar)
        var buckets = compacted
        for run in runs where run["agent_id"].string == profileID {
            // Use a projected closed copy solely for the view. No persistent
            // mutation and no claim that an active run has actually ended.
            let projected = run["ended_at"].isNullish ? run.setting("ended_at", .number(now)).setting("outcome", .string("working")) : run
            buckets = try compact(projected, into: buckets, calendar: calendar)
        }
        let days = (buckets.fields ?? []).map(\.value).filter { $0["agent_id"].string == profileID && $0["day"].string?.hasPrefix(prefix + "-") == true }.sorted { ($0["day"].string ?? "") < ($1["day"].string ?? "") }
        let tokens = days.reduce(0.0) { $0 + ($1["tokens"].number ?? 0) }, money = days.reduce(0.0) { $0 + ($1["cost_usd"].number ?? 0) }
        let tokenReports = days.reduce(0.0) { $0 + ($1["token_reports"].number ?? 0) }, costReports = days.reduce(0.0) { $0 + ($1["cost_reports"].number ?? 0) }
        let unknownTokens = days.reduce(0.0) { $0 + ($1["unknown_token_runs"].number ?? 0) }, unknownCost = days.reduce(0.0) { $0 + ($1["unknown_cost_runs"].number ?? 0) }
        let covered = trackedSince.map { $0 <= interval.start.timeIntervalSince1970 * 1_000 } ?? false
        return .object([.init("month_key", .string(prefix)), .init("time_zone", .string(calendar.timeZone.identifier)),
            .init("tokens", tokenReports > 0 || covered && unknownTokens == 0 ? .number(tokens) : .null),
            .init("cost_usd", costReports > 0 ? .number(money) : .null),
            .init("token_coverage", .string(covered && unknownTokens == 0 ? "complete" : "partial")),
            .init("cost_coverage", .string(covered && unknownCost == 0 && costReports > 0 ? "reported" : "unavailable-or-partial")),
            .init("days", .array(days))])
    }
    public static func day(_ at: Double, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: at / 1_000))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    public static func window(profileID: String, runs: [NativeRPCValue], compacted: NativeRPCValue,
                              calendar: Calendar, now: Double, days: Int, trackedSince: Double?) throws -> NativeRPCValue {
        guard (1...366).contains(days), let start = calendar.date(byAdding: .day, value: 1 - days,
            to: calendar.startOfDay(for: Date(timeIntervalSince1970: now / 1_000))) else {
            throw NativeRPCError.invalidArguments("The history window is invalid.")
        }
        let firstDay = day(start.timeIntervalSince1970 * 1_000, calendar: calendar), lastDay = day(now, calendar: calendar)
        var buckets = compacted
        for run in runs where run["agent_id"].string == profileID {
            let projected = run["ended_at"].isNullish ? run.setting("ended_at", .number(now)).setting("outcome", .string("working")) : run
            buckets = try compact(projected, into: buckets, calendar: calendar)
        }
        let rows = (buckets.fields ?? []).map(\.value).filter {
            $0["agent_id"].string == profileID && ($0["day"].string ?? "") >= firstDay && ($0["day"].string ?? "") <= lastDay
        }.sorted { ($0["day"].string ?? "") < ($1["day"].string ?? "") }
        let finished = rows.reduce(0.0) { $0 + ($1["finished"].number ?? 0) }
        let helped = rows.reduce(0.0) { $0 + ($1["finished_without_help"].number ?? 0) }
        let verified = Set(rows.flatMap { ($0["verified_tasks"].elements ?? []).compactMap(\.string) })
        return .object([.init("days", .array(rows)), .init("runs", .number(rows.reduce(0) { $0 + ($1["runs"].number ?? 0) })),
            .init("tasks_done", .number(Double(verified.count))), .init("finished", .number(finished)),
            .init("finished_without_help_percent", finished > 0 ? .number(helped / finished * 100) : .null),
            .init("coverage", .string(trackedSince.map { $0 <= start.timeIntervalSince1970 * 1_000 } == true ? "complete" : "partial"))])
    }
    public static func monthKey(_ at: Double, calendar: Calendar) -> String { String(day(at, calendar: calendar).prefix(7)) }
    private static func add(_ row: NativeRPCValue, _ key: String, _ amount: Double) -> NativeRPCValue { row.setting(key, .number((row[key].number ?? 0) + amount)) }
    private static func bucket(_ existing: NativeRPCValue, agent: String, day: String) -> NativeRPCValue {
        existing.fields == nil ? .object([.init("agent_id", .string(agent)), .init("day", .string(day))]) : existing
    }
}
