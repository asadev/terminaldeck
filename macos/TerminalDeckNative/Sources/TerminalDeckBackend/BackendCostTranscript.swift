import Foundation
import TerminalDeckNativeCore

public struct BackendCostTokens: Sendable, Equatable {
    public var input = 0.0, output = 0.0, cacheWrite5m = 0.0, cacheWrite1h = 0.0, cacheRead = 0.0
    public init() {}
    public var prompt: Double { input + cacheWrite5m + cacheWrite1h + cacheRead }
    public var total: Double { prompt + output }
    public var cacheHitRate: Double { prompt > 0 ? cacheRead / prompt : 0 }
    public var wireValue: NativeRPCValue { BackendUsageIO.object([("input", .number(input)), ("output", .number(output)), ("cacheWrite5m", .number(cacheWrite5m)), ("cacheWrite1h", .number(cacheWrite1h)), ("cacheRead", .number(cacheRead))]) }
    /// transcript.ts:652-669 parseUsage: a non-object is absent (`null` there, nil here); missing fields count as zero.
    public static func parse(_ raw: NativeRPCValue, sanitize: Bool = true) -> Self? {
        guard raw.fields != nil else { return nil }
        func count(_ value: NativeRPCValue) -> Double { let number = value.number ?? 0; return sanitize ? min(1e12, max(0, floor(number))) : number }
        var result = Self(); result.input = count(raw["input_tokens"]); result.output = count(raw["output_tokens"]); result.cacheRead = count(raw["cache_read_input_tokens"])
        result.cacheWrite5m = count(raw["cache_creation"]["ephemeral_5m_input_tokens"]); result.cacheWrite1h = count(raw["cache_creation"]["ephemeral_1h_input_tokens"])
        result.cacheWrite5m += max(0, count(raw["cache_creation_input_tokens"]) - result.cacheWrite5m - result.cacheWrite1h)
        return result
    }
    public mutating func add(_ other: Self) { input += other.input; output += other.output; cacheWrite5m += other.cacheWrite5m; cacheWrite1h += other.cacheWrite1h; cacheRead += other.cacheRead }
}

/// Legacy cost channels carry tokens and context only. Subscription spend is
/// not inferred from API prices or token counts.
public enum BackendCostMath {
    public static func normalizeModel(_ model: String) -> String {
        var result = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for pattern in ["^(us|eu|apac|global)\\.", "^anthropic\\.", "\\[1m\\]", "@\\d{8}$", "-v\\d+:\\d+$", "-\\d{8}$"] { result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
        return result
    }
    public static func contextWindow(_ model: String) -> Double {
        let normalized = normalizeModel(model).replacingOccurrences(of: "-fast$", with: "", options: .regularExpression)
        let large = ["claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-5", "claude-sonnet-4-6"]
        return large.contains(where: normalized.hasPrefix) ? 1_000_000 : 200_000
    }
    public static func effectiveWindow(model: String, observed: Double) -> Double {
        let base = contextWindow(model); if observed <= base { return base }
        return [200_000.0, 1_000_000.0].first(where: { $0 >= observed && $0 >= base }) ?? observed
    }
    public static func context(tokens: Double, window: Double) -> NativeRPCValue {
        let percent = window > 0 ? tokens / window * 100 : 0
        return BackendUsageIO.object([("tokens", .number(tokens)), ("window", .number(window)), ("percent", .number(percent)), ("remaining", .number(max(0, window - tokens))), ("level", .string(percent >= 90 ? "critical" : percent >= 70 ? "warning" : "ok"))])
    }
    public static func warnings(tokens: Double?, prefix: Double, window: Double) -> [NativeRPCValue] {
        var result: [NativeRPCValue] = []
        if let tokens, window > 0, tokens / window >= 0.7 {
            let percent = tokens / window * 100
            result.append(BackendUsageIO.object([("kind", .string("context-window")), ("level", .string(percent >= 90 ? "critical" : "warning")), ("percent", .number(percent)), ("message", .string("The current context is \(Int(percent.rounded()))% of its window."))]))
        }
        if window > 0, prefix / window >= 0.15 {
            let percent = prefix / window * 100
            result.append(BackendUsageIO.object([("kind", .string("pre-context")), ("level", .string(percent >= 30 ? "critical" : "warning")), ("percent", .number(percent)), ("message", .string("The first request already occupied \(Int(percent.rounded()))% of the context window."))]))
        }
        return result
    }
    public static func format(_ tokens: Double) -> String {
        if tokens >= 999_950 { return String(format: "%.2f", tokens / 1_000_000).replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression) + "M" }
        if tokens >= 1000 { return String(format: "%.1f", tokens / 1000).replacingOccurrences(of: "\\.0$", with: "", options: .regularExpression) + "k" }
        return String(Int(tokens.rounded()))
    }
}

struct BackendCostRequest: Sendable {
    let key: String?
    var at: Double, endedAt: Double
    let model: String, speed: String, usage: BackendCostTokens, sidechain: Bool
    var stopReason: String?, tools: [String] = []
}
struct BackendCostTool: Sendable {
    var calls = 0, failures = 0, timed = 0
    var totalMs = 0.0, maxMs = 0.0
}
struct BackendCostToolCall: Sendable { let id: String, name: String; let at: Double; var failed: Bool? }
public struct BackendCostTranscript: Sendable {
    public let path: String
    public var sessionID: String
    public var cwd: String
    var requests: [BackendCostRequest] = []
    var compactions: [NativeRPCValue] = []
    var tools: [String: BackendCostTool] = [:]
    var startedAt = 0.0, lastActivityAt = 0.0, maxMainPrompt = 0.0
    var lastMainModel = "", lastAnyModel = ""
    var dedupe: [String: Int] = [:], seenUses = Set<String>(), seenResults = Set<String>()
    var pendingTools: [String: (name: String, at: Double)] = [:]
    var toolTrail: [BackendCostToolCall] = []
    public var readBytes = 0, truncated = false
    public var requestCount: Int { requests.count }
    public var usage: BackendCostTokens { var result = BackendCostTokens(); requests.forEach { result.add($0.usage) }; return result }
    public var window: Double { BackendCostMath.effectiveWindow(model: lastMainModel.isEmpty ? lastAnyModel : lastMainModel, observed: maxMainPrompt) }
    public var mainPrompt: Double? { requests.last(where: { !$0.sidechain && $0.usage.prompt > 0 })?.usage.prompt }
    public var prefix: Double { requests.first(where: { !$0.sidechain && $0.usage.prompt > 0 })?.usage.prompt ?? 0 }
    public var context: NativeRPCValue { mainPrompt.map { BackendCostMath.context(tokens: $0, window: window) } ?? .null }
    public var warnings: [NativeRPCValue] { BackendCostMath.warnings(tokens: mainPrompt, prefix: prefix, window: window) }
    var modelUsage: [String: (usage: BackendCostTokens, count: Int)] {
        var result: [String: (usage: BackendCostTokens, count: Int)] = [:]
        for request in requests {
            // A synthetic message can count as a request but never a real model.
            guard request.model != "<synthetic>" else { continue }
            var bucket = result[request.model] ?? (BackendCostTokens(), 0); bucket.usage.add(request.usage); bucket.count += 1; result[request.model] = bucket
        }
        return result
    }
    public var summary: NativeRPCValue {
        let byModel = modelUsage
        let models = byModel.keys.sorted { let a = byModel[$0]!.usage.total, b = byModel[$1]!.usage.total; return a == b ? $0 < $1 : a > b }
        return BackendUsageIO.object([("sessionId", .string(sessionID)), ("transcriptPath", .string(path)), ("cwd", .string(cwd)), ("models", .array(models.map(NativeRPCValue.string))),
            ("requests", .number(Double(requests.count))), ("usage", usage.wireValue), ("usageByModel", .object(models.map { .init($0, byModel[$0]!.usage.wireValue) })),
            ("context", context), ("warnings", .array(warnings)), ("preContextTokens", .number(prefix)), ("compactions", .number(Double(compactions.count))),
            ("sidechainRequests", .number(Double(requests.filter(\.sidechain).count))), ("startedAt", .number(startedAt)), ("lastActivityAt", .number(lastActivityAt)),
            ("truncated", .bool(truncated)), ("bytesRead", .number(Double(readBytes)))])
    }
    mutating func consume(_ line: String) throws {
        guard line.contains("\"usage\"") || line.contains("tool_use") || line.contains("tool_result") || line.contains("compact_boundary"),
              let raw = try? NativeRPCValue.parseJSON(Data(line.utf8), maximumBytes: BackendUsageIO.maximumLineBytes) else { return }
        let at = BackendUsageIO.timestamp(raw["timestamp"])
        if let id = raw["sessionId"].string, !id.isEmpty, id.utf8.count <= 256 { sessionID = id }; if let directory = raw["cwd"].string, directory.utf8.count <= 4096 { cwd = directory }
        if at > 0 { startedAt = startedAt > 0 ? min(startedAt, at) : at; lastActivityAt = max(lastActivityAt, at) }
        let sidechain = raw["isSidechain"].bool == true
        if raw["type"].string == "system", raw["subtype"].string == "compact_boundary" {
            guard compactions.count < 20_000 else { throw NativeRPCError.malformed("This transcript exceeded the compaction-metadata read budget.") }
            let meta = raw["compactMetadata"], pre = min(1e12, max(0, floor(meta["preTokens"].number ?? 0))), post = min(1e12, max(0, floor(meta["postTokens"].number ?? 0)))
            if !sidechain { maxMainPrompt = max(maxMainPrompt, pre) }
            compactions.append(BackendUsageIO.object([("at", .number(at)), ("afterRequest", .number(Double(requests.count))), ("preTokens", .number(pre)), ("postTokens", .number(post)), ("reclaimedTokens", .number(max(0, pre - post))), ("trigger", .string(meta["trigger"].string ?? "auto")), ("durationMs", .number(max(0, meta["durationMs"].number ?? 0)))]))
            return
        }
        var owner: Int?
        let message = raw["message"]
        if raw["type"].string == "assistant", message["usage"].fields != nil {
            let rawKey = message["id"].string ?? raw["requestId"].string ?? raw["uuid"].string
            guard rawKey == nil || rawKey!.utf8.count <= 1024 else { throw NativeRPCError.malformed("A transcript request identifier exceeds its metadata budget.") }
            let key = rawKey
            if let key, let previous = dedupe[key] {
                owner = previous; if at > 0 { requests[previous].at = requests[previous].at > 0 ? min(at, requests[previous].at) : at; requests[previous].endedAt = max(requests[previous].endedAt, at) }
                if let stopReason = message["stop_reason"].string { requests[previous].stopReason = stopReason }
            } else {
                guard requests.count < 100_000 else { throw NativeRPCError.malformed("This transcript exceeded the request-count read budget.") }
                let tokens = BackendCostTokens.parse(message["usage"]) ?? BackendCostTokens()
                // transcript.ts:719: fast mode is read from `message.usage.speed` only (where Claude Code writes it).
                let speed = message["usage"]["speed"].string == "fast" ? "fast" : "standard"
                var model = BackendCostMath.normalizeModel(String((message["model"].string ?? "unknown").prefix(512))); if speed == "fast", !model.hasSuffix("-fast") { model += "-fast" }
                owner = requests.count; requests.append(BackendCostRequest(key: key, at: at, endedAt: at, model: model, speed: speed, usage: tokens, sidechain: sidechain, stopReason: message["stop_reason"].string))
                if let key { dedupe[key] = owner }
                lastAnyModel = model; if !sidechain { lastMainModel = model; maxMainPrompt = max(maxMainPrompt, tokens.prompt) }
            }
        }
        for block in message["content"].elements ?? [] {
            if block["type"].string == "tool_use", let id = block["id"].string, id.utf8.count <= 1024, let rawName = block["name"].string, seenUses.insert(id).inserted {
                let name = String(rawName.prefix(1024))
                guard seenUses.count <= 200_000 else { throw NativeRPCError.malformed("This transcript exceeded the tool-call read budget.") }
                tools[name, default: BackendCostTool()].calls += 1; pendingTools[id] = (name, at)
                toolTrail.append(BackendCostToolCall(id: id, name: name, at: at, failed: nil)); if toolTrail.count > 1000 { toolTrail.removeFirst(toolTrail.count - 1000) }
                if let target = owner ?? requests.indices.last { requests[target].tools.append(name) }
            } else if block["type"].string == "tool_result", let id = block["tool_use_id"].string, id.utf8.count <= 1024 {
                guard seenResults.insert(id).inserted else { continue }
                guard seenResults.count <= 200_000 else { throw NativeRPCError.malformed("This transcript exceeded the tool-result metadata read budget.") }
                guard let pending = pendingTools.removeValue(forKey: id) else { continue }
                var stat = tools[pending.name] ?? BackendCostTool()
                if block["is_error"].bool == true { stat.failures += 1 }
                if let index = toolTrail.firstIndex(where: { $0.id == id }) { toolTrail[index].failed = block["is_error"].bool == true }
                if pending.at > 0, at >= pending.at { let elapsed = at - pending.at; stat.timed += 1; stat.totalMs += elapsed; stat.maxMs = max(stat.maxMs, elapsed) }
                tools[pending.name] = stat
            }
        }
    }
    public func insights(maxTimeline: Int = 750, maxContextPoints: Int = 400, now: Double = Date().timeIntervalSince1970 * 1000) -> NativeRPCValue {
        var previousEnd = 0.0, timeline: [NativeRPCValue] = [], points: [NativeRPCValue] = [], generating = 0.0
        for (offset, request) in requests.enumerated() {
            let span = max(0, request.endedAt - request.at), percent = request.sidechain ? nil : request.usage.prompt / window * 100
            generating += span
            timeline.append(BackendUsageIO.object([("index", .number(Double(offset + 1))), ("key", .string(request.key ?? "anonymous:\(offset + 1)")), ("at", .number(request.at)), ("endedAt", .number(request.endedAt)), ("streamMs", .number(span)), ("sinceLastMs", .number(previousEnd > 0 ? max(0, request.at - previousEnd) : 0)), ("model", .string(request.model)), ("speed", .string(request.speed)), ("usage", request.usage.wireValue), ("promptTokens", .number(request.usage.prompt)), ("outputTokens", .number(request.usage.output)), ("totalTokens", .number(request.usage.total)), ("contextPercent", BackendUsageIO.number(percent)), ("isSidechain", .bool(request.sidechain)), ("stopReason", BackendUsageIO.string(request.stopReason)), ("tools", .array(request.tools.map(NativeRPCValue.string)))]))
            if let percent, request.usage.prompt > 0 { points.append(BackendUsageIO.object([("index", .number(Double(offset + 1))), ("at", .number(request.at)), ("tokens", .number(request.usage.prompt)), ("percent", .number(percent))])) }
            previousEnd = max(previousEnd, request.endedAt)
        }
        let heaviest = timeline.filter { ($0["totalTokens"].number ?? 0) > 0 }.sorted { let a = $0["totalTokens"].number ?? 0, b = $1["totalTokens"].number ?? 0; return a == b ? ($0["index"].number ?? 0) < ($1["index"].number ?? 0) : a > b }.prefix(5)
        if maxContextPoints <= 0 { points = [] } else if points.count > maxContextPoints {
            let size = Double(points.count) / Double(maxContextPoints), old = points
            points = (0..<maxContextPoints).compactMap { bucket in let from = Int(floor(Double(bucket) * size)), to = min(old.count, Int(floor(Double(bucket + 1) * size))); return old[from..<to].max { ($0["percent"].number ?? 0) < ($1["percent"].number ?? 0) } }
        }
        let calls = tools.values.reduce(0) { $0 + $1.calls }, tokens = usage
        let toolRows = tools.keys.sorted { let a = tools[$0]!.calls, b = tools[$1]!.calls; return a == b ? $0 < $1 : a > b }.map { name -> NativeRPCValue in
            let stat = tools[name]!, server: String? = BackendUsageIO.matches("^mcp__(.+?)__(.+)$", name).first.flatMap { BackendUsageIO.group($0, 1, name) }
            return BackendUsageIO.object([("name", .string(name)), ("server", BackendUsageIO.string(server)), ("calls", .number(Double(stat.calls))), ("failures", .number(Double(stat.failures))), ("timedCalls", .number(Double(stat.timed))), ("totalMs", .number(stat.totalMs)), ("maxMs", .number(stat.maxMs)), ("avgMs", .number(stat.timed > 0 ? stat.totalMs / Double(stat.timed) : 0)), ("share", .number(calls > 0 ? Double(stat.calls) / Double(calls) : 0))])
        }
        let models = modelUsage.sorted { $0.value.usage.total == $1.value.usage.total ? $0.key < $1.key : $0.value.usage.total > $1.value.usage.total }.map { model, bucket in
            BackendUsageIO.object([("model", .string(model)), ("requests", .number(Double(bucket.count))), ("usage", bucket.usage.wireValue), ("promptTokens", .number(bucket.usage.prompt)), ("outputTokens", .number(bucket.usage.output)), ("share", .number(tokens.total > 0 ? bucket.usage.total / tokens.total : 0))])
        }
        let cap = max(0, maxTimeline)
        return summary.merging(BackendUsageIO.object([("models", .array(models)), ("durationMs", .number(max(0, lastActivityAt - startedAt))), ("generatingMs", .number(generating)), ("toolMs", .number(tools.values.reduce(0) { $0 + $1.totalMs })), ("timeline", .array(Array(timeline.suffix(cap)))), ("omittedRequests", .number(Double(max(0, timeline.count - cap)))), ("heaviest", .array(Array(heaviest))), ("tools", .array(toolRows)), ("toolCalls", .number(Double(calls))), ("toolFailures", .number(Double(tools.values.reduce(0) { $0 + $1.failures }))), ("cacheHitRate", .number(tokens.cacheHitRate)), ("contextSeries", .array(points)), ("compactions", .array(compactions)), ("generatedAt", .number(now))]))
    }
    public static func read(path: String, scope: NativeTranscriptScope, cancellation: BackendMCPCancellation? = nil, deadline: Double? = nil) async throws -> Self {
        let approved = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
        var result = Self(path: approved, sessionID: URL(fileURLWithPath: approved).deletingPathExtension().lastPathComponent, cwd: "")
        let scan = try await BackendUsageIO.lines(path: approved, roots: NativeTranscriptPaths.approvedRoots(scope), cancellation: cancellation, deadline: deadline) { try result.consume($0) }
        result.readBytes = scan.bytes; result.truncated = scan.truncated; return result
    }
}
