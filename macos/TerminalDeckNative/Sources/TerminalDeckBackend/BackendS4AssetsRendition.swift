import Foundation
import TerminalDeckNativeCore

/// Port of src/main/browser-asset-rendition.ts (the rewrite rules, the
/// acceptance judgement and choosing the best rendition) and of
/// browser-asset-probe.ts (HEAD, then a one-byte ranged GET). Rule rewriting
/// runs through the existing BackendBrowserScrapingRegex (system JavaScriptCore),
/// which is exact ECMAScript replace. The tool layer already validated and
/// normalised the rules (BackendDeckToolsAssets.readRules), so rules arrive as
/// {id, match, replace, flags?}.

public struct BackendS4AssetsProbe: Sendable, Equatable {
    public let status: Int, bytes: Int?, contentType: String
    public init(status: Int, bytes: Int?, contentType: String) { self.status = status; self.bytes = bytes; self.contentType = contentType }
}
typealias BackendS4AssetsProbeFunction = @Sendable (String) async -> BackendS4AssetsProbe?

struct BackendS4AssetsRule: Sendable, Equatable {
    let id: String, match: String, replace: String, flags: String
    static func read(_ raw: NativeRPCValue) -> [BackendS4AssetsRule] {
        (raw.elements ?? []).compactMap { entry in
            guard let id = entry["id"].string, let match = entry["match"].string else { return nil }
            return BackendS4AssetsRule(id: id, match: match, replace: entry["replace"].string ?? "", flags: entry["flags"].string ?? "")
        }
    }
}

struct BackendS4AssetsCandidate: Sendable, Equatable { let url: String, ruleId: String }

struct BackendS4AssetsRenditionAttempt: Sendable {
    let url: String, ruleId: String, ok: Bool, reason: String, status: Int?, bytes: Int?
    var value: NativeRPCValue {
        BackendS4AssetsObject.make([("url", .string(url)), ("ruleId", .string(ruleId)), ("ok", .bool(ok)), ("reason", .string(reason)),
                                    ("status", status.map(BackendS4AssetsObject.number) ?? .null), ("bytes", bytes.map(BackendS4AssetsObject.number) ?? .null)])
    }
}

struct BackendS4AssetsRenditionChoice: Sendable {
    let url: String, ruleId: String, upgraded: Bool, fellBack: Bool, reachable: Bool, comparedBytes: Bool
    let originalUrl: String, attempts: [BackendS4AssetsRenditionAttempt], line: String
    var value: NativeRPCValue {
        BackendS4AssetsObject.make([("url", .string(url)), ("ruleId", .string(ruleId)), ("upgraded", .bool(upgraded)), ("fellBack", .bool(fellBack)),
                                    ("reachable", .bool(reachable)), ("comparedBytes", .bool(comparedBytes)), ("originalUrl", .string(originalUrl)),
                                    ("attempts", .array(attempts.map(\.value))), ("line", .string(line))])
    }
}

struct BackendS4AssetsRenditionOptions: Sendable {
    var minBytes: Double = 0
    var requireLarger = true
    /// minBytes is truncated and clamped at zero by the tool; requireLarger is
    /// true unless the call said otherwise (the source default).
    init(_ arguments: NativeRPCValue) {
        if let bytes = arguments["minBytes"].number { minBytes = max(0, bytes.rounded(.towardZero)) }
        if let larger = arguments["requireLarger"].bool { requireLarger = larger }
    }
    init(minBytes: Double, requireLarger: Bool) { self.minBytes = minBytes; self.requireLarger = requireLarger }
}

enum BackendS4AssetsRendition {
    static let probeTimeoutMilliseconds = 8_000

    static func apply(_ url: String, rule: BackendS4AssetsRule) -> String {
        (try? BackendBrowserScrapingRegex.replace(url, pattern: rule.match, replacement: rule.replace, flags: rule.flags)) ?? url
    }

    static func candidates(_ url: String, rules: [BackendS4AssetsRule]) -> [BackendS4AssetsCandidate] {
        var out: [BackendS4AssetsCandidate] = [], seen: Set<String> = []
        func add(_ candidate: BackendS4AssetsCandidate) { if seen.insert(candidate.url).inserted { out.append(candidate) } }
        if rules.count > 1 {
            var combined = url, used: [String] = []
            for rule in rules {
                let next = apply(combined, rule: rule)
                if next != combined { used.append(rule.id) }
                combined = next
            }
            if used.count > 1 { add(.init(url: combined, ruleId: used.joined(separator: "+"))) }
        }
        for rule in rules {
            let next = apply(url, rule: rule)
            if next != url { add(.init(url: next, ruleId: rule.id)) }
        }
        add(.init(url: url, ruleId: ""))
        return out
    }

    /// acceptsRendition(): the five refusals, in the source's order.
    static func accepts(candidateUrl: String, probe: BackendS4AssetsProbe?, originalProbe: BackendS4AssetsProbe?,
                        minBytes: Double, requireLarger: Bool) -> (ok: Bool, reason: String, comparedBytes: Bool) {
        guard let probe else { return (false, "the request failed", false) }
        if probe.status < 200 || probe.status >= 300 { return (false, "HTTP \(probe.status)", false) }
        if candidateUrl.range(of: #"\.(?:jpe?g|png|gif|webp|avif|bmp|tiff?|svg|pdf|mp4|webm|mov|zip|dwg|dxf)(?:$|[?#])"#, options: [.regularExpression, .caseInsensitive]) != nil,
           probe.contentType.hasPrefix("text/") {
            return (false, "the server answered with \(probe.contentType), which is a page rather than the file", false)
        }
        if let bytes = probe.bytes, bytes == 0 { return (false, "the server answered with nothing", false) }
        if minBytes > 0, let bytes = probe.bytes, Double(bytes) < minBytes {
            return (false, "\(bytes) bytes is below the \(Int(minBytes)) this run will accept", false)
        }
        if requireLarger {
            guard let original = originalProbe, let originalBytes = original.bytes, let bytes = probe.bytes else { return (true, "", false) }
            if bytes <= originalBytes { return (false, "it is \(bytes) bytes against the original's \(originalBytes), so it is not a bigger copy", true) }
            return (true, "", true)
        }
        return (true, "", false)
    }

    private static func describeFailures(_ attempts: [BackendS4AssetsRenditionAttempt]) -> String {
        attempts.filter { !$0.ok }.map { "\($0.ruleId.isEmpty ? "original" : $0.ruleId) — \($0.reason)" }.joined(separator: "; ")
    }

    /// chooseRendition(): probe the original once (only when an upgrade exists
    /// and a larger copy is required), try each candidate, first acceptable wins,
    /// and when nothing answers hand the original back anyway.
    static func choose(url: String, rules: [BackendS4AssetsRule], probe: BackendS4AssetsProbeFunction,
                       options: BackendS4AssetsRenditionOptions) async -> BackendS4AssetsRenditionChoice {
        let list = candidates(url, rules: rules)
        var attempts: [BackendS4AssetsRenditionAttempt] = []
        var originalProbe: BackendS4AssetsProbe?, originalProbed = false
        if options.requireLarger && list.contains(where: { !$0.ruleId.isEmpty }) {
            originalProbe = await probe(url); originalProbed = true
        }
        for candidate in list {
            let isOriginal = candidate.ruleId.isEmpty
            let measured = isOriginal && originalProbed ? originalProbe : await probe(candidate.url)
            let verdict = accepts(candidateUrl: candidate.url, probe: measured, originalProbe: originalProbe, minBytes: options.minBytes,
                                  requireLarger: isOriginal ? false : options.requireLarger)
            attempts.append(.init(url: candidate.url, ruleId: candidate.ruleId, ok: verdict.ok, reason: verdict.reason, status: measured?.status, bytes: measured?.bytes))
            if !verdict.ok { continue }
            let fellBack = isOriginal && attempts.count > 1
            let line = isOriginal
                ? (fellBack ? "No upgrade held, so the original URL was used: \(describeFailures(attempts))" : "No rule changed this URL, so the original was used.")
                : "Upgraded by \(candidate.ruleId)\(verdict.comparedBytes ? " and it is a bigger file than the original" : "")."
            return .init(url: candidate.url, ruleId: candidate.ruleId, upgraded: !isOriginal, fellBack: fellBack, reachable: true,
                         comparedBytes: verdict.comparedBytes, originalUrl: url, attempts: attempts, line: line)
        }
        return .init(url: url, ruleId: "", upgraded: false, fellBack: attempts.count > 1, reachable: false, comparedBytes: false, originalUrl: url,
                     attempts: attempts, line: "Nothing answered for this asset, so the original URL is being handed back to be fetched anyway: \(describeFailures(attempts))")
    }
}

// MARK: - transport seam and the probe

public struct BackendS4AssetsResponse: Sendable {
    public let status: Int
    /// Header names lower-cased.
    public let headers: [String: String]
    /// nil = the server sent no body at all. A normal finish is a complete body;
    /// a thrown error is a body that stopped part-way.
    public let body: AsyncThrowingStream<Data, Error>?
    public let cancel: @Sendable () -> Void
    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>?, cancel: @escaping @Sendable () -> Void = {}) {
        self.status = status; self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body; self.cancel = cancel
    }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// The network. Real implementations use the profile's own cookie jar (the
/// existing Safari fetch hooks, see BackendS4AssetsHooksTransport); tests use
/// fakes. `profile` is nil for a public, cookie-less request.
public protocol BackendS4AssetsTransport: Sendable {
    func open(url: String, method: String, headers: [String: String], profile: String?, timeoutMilliseconds: Int) async throws -> BackendS4AssetsResponse
    func probe(url: String, profile: String?, timeoutMilliseconds: Int) async -> BackendS4AssetsProbe?
}

enum BackendS4AssetsTimed {
    struct Timeout: Error, LocalizedError { var errorDescription: String? { "the request timed out" } }
    static func run<T: Sendable>(_ milliseconds: Int, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(max(1, milliseconds)) * 1_000_000); throw Timeout() }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Timeout() }
            return first
        }
    }
}

public extension BackendS4AssetsTransport {
    /// probeAsset(): HEAD first; if the server will not answer HEAD (405, 501, 403)
    /// or gave no length for a good answer, a one-byte ranged GET.
    func probe(url: String, profile: String?, timeoutMilliseconds: Int) async -> BackendS4AssetsProbe? {
        guard url.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        @Sendable func length(_ response: BackendS4AssetsResponse, ranged: Bool) -> Int? {
            func whole(_ text: String?) -> Int? { text.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
            if ranged {
                let range = response.header("content-range") ?? ""
                if let slash = range.range(of: #"/(\d+)\s*$"#, options: .regularExpression) {
                    return Int(range[slash].dropFirst().trimmingCharacters(in: .whitespaces))
                }
                if range.isEmpty {
                    guard let value = whole(response.header("content-length")), value > 1 else { return nil }
                    return value
                }
                return nil
            }
            guard let value = whole(response.header("content-length")), value >= 0 else { return nil }
            return value
        }
        let transport = self
        func once(_ ranged: Bool) async -> BackendS4AssetsProbe? {
            do {
                return try await BackendS4AssetsTimed.run(timeoutMilliseconds) { () async throws -> BackendS4AssetsProbe in
                    let response = try await transport.open(url: url, method: ranged ? "GET" : "HEAD", headers: ranged ? ["Range": "bytes=0-0"] : [:],
                                                            profile: profile, timeoutMilliseconds: timeoutMilliseconds)
                    if ranged { response.cancel() }
                    let type = (response.header("content-type") ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                    return BackendS4AssetsProbe(status: response.status == 206 ? 200 : response.status, bytes: length(response, ranged: ranged), contentType: type)
                }
            } catch { return nil }
        }
        let head = await once(false)
        if let head, head.status != 405, head.status != 501, head.status != 403 {
            if (200..<300).contains(head.status), head.bytes == nil, let ranged = await once(true) { return ranged }
            return head
        }
        let ranged = await once(true)
        return ranged ?? head
    }
}
