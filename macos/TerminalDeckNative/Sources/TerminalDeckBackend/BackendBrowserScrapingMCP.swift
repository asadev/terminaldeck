import Foundation
import TerminalDeckNativeCore

/// Source identities and schemas. Installation registers actual service
/// handlers; it never starts the endpoint or constructs hidden browser stores.
public enum BackendBrowserScrapingMCP {
    /// The session engine must consult its current consent, budget, action log,
    /// machine/profile/origin grants AND the dynamically selected action tier.
    /// The server's base tool tier alone is insufficient for scraping.set or
    /// ledger.record; this mandatory gate preserves the source's tier escalation.
    public typealias AuthorizeCall = @Sendable
        (BackendMCPCallContext, String, BackendMCPTier, NativeRPCValue) async throws -> BackendBrowserScrapingCaller
    private struct Definition: Sendable { let id: String; let tier: BackendMCPTier; let description: String; let schema: NativeRPCValue }
    private static func type(_ name: String) -> NativeRPCValue { .object([.init("type", .string(name))]) }
    private static func choice(_ values: [String]) -> NativeRPCValue {
        .object([.init("type", .string("string")), .init("enum", .array(values.map(NativeRPCValue.string)))])
    }
    private static func schema(_ properties: [(String, NativeRPCValue)], required: [String] = []) -> NativeRPCValue {
        .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
            .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
    }
    private static var stringArray: NativeRPCValue { .object([.init("type", .string("array")), .init("items", type("string"))]) }
    private static var renditionRules: NativeRPCValue {
        .object([.init("type", .string("array")), .init("maxItems", .number(32)), .init("items", schema([
            ("id", type("string")), ("match", type("string")), ("replace", type("string")), ("flags", type("string"))], required: ["id", "match", "replace"]))])
    }
    private static var definitions: [Definition] {
        let assetCommon: [(String, NativeRPCValue)] = [("profileId", type("string")), ("rules", renditionRules),
            ("minBytes", type("number")), ("requireLarger", type("boolean")), ("minWidth", type("number")),
            ("minHeight", type("number")), ("minByteRatio", type("number")), ("requireLargerDimensions", type("boolean"))]
        return [
            .init(id: "browser.workers", tier: .read, description: "List granted worker profiles and their live paced lease status. Profiles are isolated WebKit cookie jars; no crawl/job engine is started.", schema: schema([])),
            .init(id: "browser.worker", tier: .act, description: "Take, release or renew one granted worker. Take actually awaits the per-profile delay and jitter. Holder identity comes from the authenticated session and machine; leases expire and are never persisted.", schema: schema([
                ("action", choice(["take", "release", "renew"])), ("worker", type("string")), ("holdMs", type("number"))], required: ["action"])),
            .init(id: "browser.lift_request", tier: .act, description: "File a request for the person to copy a signed-in profile into workers. Local attended callers only. The agent cannot approve it. The WebKit transfer adapter is currently pending; filing an ask never copies login data.", schema: schema([
                ("from", type("string")), ("into", stringArray), ("reason", type("string"))], required: ["from"])),
            .init(id: "browser.scraping", tier: .read, description: "Read or update granted profile scraping settings, measured status, workers and pacing; reveal/clear capture records or ledgers. Action-specific read/act/alter consent is checked. Stored request rules do not imply WebKit interception support.", schema: schema([
                ("action", choice(["config", "set", "status", "clearcapture", "showcapture", "clearledgers", "blockshots", "workers", "addworker", "removeworker", "pace", "forgetlift"])),
                ("profile", type("string")), ("patch", type("object")), ("on", type("boolean")), ("count", type("integer")),
                ("concurrency", type("integer")), ("delayMs", type("integer")), ("jitterMs", type("integer")), ("lift", type("string"))])),
            .init(id: "browser.network", tier: .act, description: "Start/status/stop partial WebKit resource timing metadata capture on a granted bound browser window. Response bodies, all traffic, service-worker events and pause/fulfill interception are not available through public WebKit APIs. Unsupported block/fulfill rules are refused, never silently armed.", schema: schema([
                ("action", choice(["start", "status", "stop"])), ("rules", type("object")), ("capture", type("boolean")),
                ("limits", type("object")), ("sessionId", type("string")), ("window", type("string")), ("runId", type("string"))], required: ["action"])),
            .init(id: "assets.rendition", tier: .act, description: "Probe combined/individual rendition URL rewrites, then the original, from the granted WebKit profile. HEAD falls back to bounded ranged GET. Status/type/minBytes are checked; known lengths are compared by default and unknown comparisons are reported. Optional minWidth/minHeight/minByteRatio/requireLargerDimensions require native measured metadata. Source g/i/m/s/u/y and standard JS replacement tokens use isolated system JavaScriptCore, with no Node or page access.", schema: schema([("url", type("string"))] + assetCommon, required: ["url"])),
            .init(id: "assets.ledger", tier: .read, description: "Decide, record, verify or summarize a profile-owned run ledger. Resume skips only a real granted file with the matching byte length and SHA-256; record hashes the file itself. Refetch ignores resume decisions. Paired-device callers are refused.", schema: schema([
                ("runId", type("string")), ("op", choice(["decide", "record", "verify", "summary"])), ("mode", choice(["resume", "refetch"])),
                ("url", type("string")), ("path", type("string")), ("fetchedUrl", type("string")), ("ruleId", type("string")),
                ("expectDigest", type("string")), ("profileId", type("string"))], required: ["runId", "op"])),
            .init(id: "assets.coverage", tier: .act, description: "Compare captured count with the page's own unambiguous total; record complete/short/over/unknown and summarize earlier checks. Missing, malformed or disagreeing totals are unknown, never complete. Source JavaScript i/m/s/u/y matching and structural thousands separators are preserved via isolated system JavaScriptCore. Local files only.", schema: schema([
                ("runId", type("string")), ("op", choice(["check", "summary"])), ("captured", type("number")), ("text", type("string")),
                ("pattern", type("string")), ("flags", type("string")), ("stated", type("number")), ("tolerance", type("number")),
                ("what", type("string")), ("pageUrl", type("string")), ("profileId", type("string"))], required: ["runId"])),
            .init(id: "assets.fetch", tier: .act, description: "Fetch a bounded batch of asset URLs to an explicitly granted local directory using the exact WebKit profile's cookies. Authorize every redirect, preserve original bytes, try rewrites then fall back, verify resume files and append real measured digests. Limit 64 MiB per asset and 1000 URLs per batch. Paired devices are refused.", schema: schema([
                ("runId", type("string")), ("dir", type("string")), ("urls", stringArray), ("mode", choice(["resume", "refetch"]))] + assetCommon, required: ["runId", "dir", "urls"])),
            .init(id: "assets.blocks", tier: .read, description: "Aggregate privacy-safe block evidence across caller-granted profiles and exact page origins, newest first; optional profileId narrows it. Report filtered total, missing screenshots, opt-out profiles and honest empty reasons. Capture follows the source default-on toggle. Unowned legacy-root evidence and paired-device access are excluded.", schema: schema([
                ("limit", type("number")), ("since", type("number")), ("profileId", type("string"))]))
        ]
    }
    public static func tier(id: String, arguments: NativeRPCValue) -> BackendMCPTier {
        if id == "assets.ledger", arguments["op"].string == "record" { return .act }
        if id == "browser.scraping" {
            let action = arguments["action"].string ?? "config"
            if action == "showcapture" { return .act }
            if ["set", "clearcapture", "clearledgers", "workers", "addworker", "removeworker", "pace", "forgetlift"].contains(action) || action == "blockshots" && arguments["on"].bool != nil { return .alter }
            return .read
        }
        return definitions.first { $0.id == id }?.tier ?? .alter
    }
    public static func tools() throws -> [BackendMCPTool] {
        try definitions.map { try BackendMCPTool(id: $0.id, wireName: $0.id.replacingOccurrences(of: ".", with: "_"),
            description: $0.description, inputSchema: $0.schema, tier: $0.tier) }
    }
    public static func install(on server: BackendNativeMCPServer, rpc: BackendBrowserScrapingRPC,
                               authorizeCall: @escaping AuthorizeCall) async throws {
        for spec in try tools() {
            try await server.registerTool(spec) { context, arguments in
                let base = try await BackendBrowserFactories.toolReply {
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    let caller = try await authorizeCall(context, spec.id, tier(id: spec.id, arguments: arguments), arguments)
                    try Task.checkCancellation()
                    let answer = try await rpc.tool(spec.id, args: arguments, caller: caller)
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    return answer
                }
                guard !base.isError, let answer = base.structuredContent else { return base }
                // A batch failure or explicit unavailable transfer is a tool
                // error with structured evidence, never an empty-success reply.
                let failed = answer["ok"].bool == false || answer["complete"].bool == false && (answer["tally"]["failed"].number ?? 0) > 0
                return BackendMCPToolReply(content: base.content, structuredContent: base.structuredContent, isError: failed)
            }
        }
    }
}
