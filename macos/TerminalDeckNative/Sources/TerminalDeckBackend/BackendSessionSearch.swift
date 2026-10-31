import Foundation
import TerminalDeckNativeCore

public enum BackendSessionSearchRole: String, Sendable { case user, assistant, thinking, tool, system }
public struct BackendSessionSearchRequest: Sendable {
    public let cwd: String, query: String
    public var allProjects = false, caseSensitive = false, regex = false
    public var roles: [BackendSessionSearchRole] = [.user, .assistant]
    public var maxHits = 200, maxSessions = 80, maxHitsPerSession = 6
    public var maxAgeMilliseconds = 365 * 86_400_000.0, budgetMilliseconds = 12_000.0
    public init(cwd: String, query: String) { self.cwd = cwd; self.query = query }
    public static func parse(_ value: NativeRPCValue) throws -> Self {
        var result = Self(cwd: try value["cwd"].requireString("project path", nonempty: true), query: try value["query"].requireString("query"))
        result.allProjects = value["scope"].string == "all"; result.caseSensitive = value["caseSensitive"].bool == true; result.regex = value["regex"].bool == true
        let roles = value["roles"].elements?.compactMap { $0.string.flatMap(BackendSessionSearchRole.init(rawValue:)) } ?? []; if !roles.isEmpty { result.roles = roles }
        result.maxHits = try BackendUsageIO.integer(value["maxHits"], fallback: 200, range: 1...1000); result.maxSessions = try BackendUsageIO.integer(value["maxSessions"], fallback: 80, range: 1...600)
        return result
    }
}
public actor BackendSessionSearchService {
    public static let channels: Set<String> = ["session-search:run", "session-search:cancel"]
    private let cost: BackendCostService, projects: BackendProjectService
    private var active: [String: BackendMCPCancellation] = [:]
    public init(cost: BackendCostService, projects: BackendProjectService) { self.cost = cost; self.projects = projects }
    private struct Term { let regex: NSRegularExpression; let phrase: Bool }
    private struct Query { let include: [Term], exclude: [Term] }
    private struct QueryFailure: Error { let code: String, message: String }
    private static func parse(_ request: BackendSessionSearchRequest) throws -> Query {
        let text = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf16.count >= 2 else { throw QueryFailure(code: "query-too-short", message: "Type at least 2 characters.") }
        guard text.utf16.count <= 4096 else { throw QueryFailure(code: "unsafe-regex", message: "The search query is too large.") }
        let options: NSRegularExpression.Options = request.caseSensitive ? [] : [.caseInsensitive]
        if request.regex {
            let compiled: NSRegularExpression
            do { compiled = try NSRegularExpression(pattern: text, options: options) } catch { throw QueryFailure(code: "invalid-regex", message: "The regular expression could not be compiled.") }
            // ICU, unlike the source JS engine, has no per-match deadline API.
            // Refuse repeated groups, backreferences/lookaround and adjacent
            // unbounded repeats rather than pretending cancellation can stop
            // a catastrophic match already executing on one block.
            let unsafe = ["\\)[*+{]", "\\\\[1-9]", "\\(\\?", "(?:[*+]\\??)[^|]{0,8}(?:[*+])"]
            guard !unsafe.contains(where: { !BackendUsageIO.matches($0, text).isEmpty }) else { throw QueryFailure(code: "unsafe-regex", message: "This pattern uses a repeated group, backreference, lookaround or overlapping repeat. Use a bounded pattern.") }
            return Query(include: [Term(regex: compiled, phrase: false)], exclude: [])
        }
        var included: [Term] = [], excluded: [Term] = [], index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }; if index == text.endIndex { break }
            var negative = false, phrase = false, body = ""
            if text[index] == "-" { let next = text.index(after: index); if next < text.endIndex, !text[next].isWhitespace { negative = true; index = next } }
            if text[index] == "\"" { phrase = true; index = text.index(after: index); while index < text.endIndex, text[index] != "\"" { body.append(text[index]); index = text.index(after: index) }; if index < text.endIndex { index = text.index(after: index) } }
            else { while index < text.endIndex, !text[index].isWhitespace { body.append(text[index]); index = text.index(after: index) } }
            if body.isEmpty || body == "-" { continue }
            let term = Term(regex: try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: body), options: options), phrase: phrase)
            if negative { excluded.append(term) } else { included.append(term) }
            guard included.count + excluded.count <= 32 else { throw QueryFailure(code: "query-too-short", message: "Use at most 32 search terms.") }
        }
        guard !included.isEmpty else { throw QueryFailure(code: "query-too-short", message: "Add something to search for, not only exclusions.") }
        return Query(include: included, exclude: excluded)
    }
    private struct Block { let role: BackendSessionSearchRole, text: String; let tool: String? }
    private static func blocks(_ raw: NativeRPCValue, roles: Set<String>) -> [Block] {
        guard raw["isMeta"].bool != true, let type = raw["type"].string else { return [] }
        func clip(_ text: String) -> String { String(decoding: text.utf16.prefix(120_000), as: UTF16.self) }
        if type == "system", roles.contains("system"), let text = raw["content"].string { return [Block(role: .system, text: clip(text), tool: nil)] }
        guard type == "user" || type == "assistant" else { return [] }
        let role: BackendSessionSearchRole = type == "user" ? .user : .assistant, content = raw["message"]["content"]
        if let text = content.string { return [Block(role: role, text: clip(text), tool: nil)] }
        var result: [Block] = []
        for block in content.elements ?? [] {
            switch block["type"].string {
            case "text": if let text = block["text"].string { result.append(Block(role: role, text: clip(text), tool: nil)) }
            case "thinking": if roles.contains("thinking"), let text = block["thinking"].string { result.append(Block(role: .thinking, text: clip(text), tool: nil)) }
            case "tool_use": if roles.contains("tool") { let name = block["name"].string ?? "tool"; result.append(Block(role: .tool, text: clip(name + " " + (block["input"].isNullish ? "" : block["input"].compact)), tool: name)) }
            case "tool_result": if roles.contains("tool") { let content = block["content"]; let text = content.string ?? content.elements?.compactMap { $0["type"].string == "text" ? $0["text"].string : nil }.joined(separator: "\n") ?? ""; if !text.isEmpty { result.append(Block(role: .tool, text: clip(text), tool: nil)) } }
            default: break
            }
        }
        return result.filter { roles.contains($0.role.rawValue) }
    }
    private static func snippet(_ text: String, ranges: [NSRange], anchor: NSRange) -> NativeRPCValue {
        let source = Array(text.utf16), from = max(0, anchor.location - 90), to = min(source.count, anchor.location + anchor.length + 220)
        var body: [UInt16] = [], mapping: [Int: Int] = [:], wasSpace = false
        for index in from..<to {
            let unit = source[index], space = CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(unit) ?? UnicodeScalar(0xFFFD)!)
            mapping[index] = body.count
            if space { if !wasSpace { body.append(32) }; wasSpace = true } else { body.append(unit); wasSpace = false }
        }
        mapping[to] = body.count
        let clipped = body.count > 260; body = Array(body.prefix(260))
        let kept = ranges.compactMap { range -> NativeRPCValue? in
            guard range.location >= from, range.location + range.length <= to, let start = mapping[range.location], let end = mapping[range.location + range.length], start < body.count else { return nil }
            return BackendUsageIO.object([("start", .number(Double(start))), ("length", .number(Double(min(end, body.count) - start)))])
        }
        return BackendUsageIO.object([("text", .string(String(decoding: body, as: UTF16.self))), ("ranges", .array(kept)), ("truncatedStart", .bool(from > 0)), ("truncatedEnd", .bool(clipped || to < source.count))])
    }
    public func search(_ request: BackendSessionSearchRequest, context: NativeRPCContext, cancellation: BackendMCPCancellation? = nil,
                       restrictedToProject: String? = nil) async throws -> NativeRPCValue {
        let query: Query
        do { query = try Self.parse(request) } catch let error as QueryFailure { return BackendUsageIO.object([("ok", .bool(false)), ("error", .string(error.code)), ("message", .string(error.message))]) }
        guard request.cwd.hasPrefix("/"), NativeTranscriptPaths.resolved(request.cwd) != "/" else { return BackendUsageIO.object([("ok", .bool(false)), ("error", .string("invalid-project")), ("message", .string("A real project folder is required."))]) }
        guard (1...1000).contains(request.maxHits), (1...600).contains(request.maxSessions), request.budgetMilliseconds > 0, request.budgetMilliseconds <= 120_000 else { throw NativeRPCError.invalidArguments("The search budget or response limit is invalid.") }
        _ = try await projects.requireKnown(request.cwd, restrictedTo: restrictedToProject)
        if request.allProjects, restrictedToProject != nil { throw NativeRPCError(code: "access-denied", message: "A project-bound caller cannot search other projects.") }
        let started = BackendUsageIO.now(), deadline = started + request.budgetMilliseconds, roles = Set(request.roles.map(\.rawValue))
        var all: [NativeTranscriptFile] = [], seen = Set<String>()
        let files = request.allProjects ? try await cost.allFiles(context: context, cancellation: cancellation, deadline: deadline) : try await cost.files(project: request.cwd, context: context)
        for file in files where request.maxAgeMilliseconds == 0 || file.modifiedAt >= started - request.maxAgeMilliseconds {
            if seen.insert(file.path).inserted { all.append(file) }
        }
        all.sort { $0.modifiedAt > $1.modifiedAt }
        var hits: [NativeRPCValue] = [], opened = 0, bytes = 0, totalHits = 0, truncated = all.count > request.maxSessions, cancelled = false
        do {
            for file in all.prefix(request.maxSessions) {
                if BackendUsageIO.now() >= deadline { truncated = true; break }
                var local: [NativeRPCValue] = [], cwd = "", lineCount = 0
                let scope = try await cost.scope(project: nil, context: context)
                let scan = try await BackendUsageIO.lines(path: file.path, roots: NativeTranscriptPaths.approvedRoots(scope), cancellation: cancellation, deadline: deadline) { line in
                    lineCount += 1
                    guard line.contains("\"message\"") || line.contains("\"content\""), let raw = try? NativeRPCValue.parseJSON(Data(line.utf8)) else { return }
                    if cwd.isEmpty { cwd = raw["cwd"].string ?? "" }
                    let stamp = BackendUsageIO.timestamp(raw["timestamp"]), at = stamp > 0 ? stamp : file.modifiedAt, sidechain = raw["isSidechain"].bool == true
                    for block in Self.blocks(raw, roles: roles) {
                        let range = NSRange(location: 0, length: block.text.utf16.count)
                        if query.exclude.contains(where: { $0.regex.firstMatch(in: block.text, range: range) != nil }) { continue }
                        var ranges: [NSRange] = [], occurrences = 0, phrase = false, anchor: NSRange?, rarest = Int.max, missing = false
                        for term in query.include {
                            var found = 0, first: NSRange?
                            term.regex.enumerateMatches(in: block.text, range: range) { match, _, stop in
                                guard let match else { return }; found += 1; if first == nil { first = match.range }
                                if ranges.count < 50 { ranges.append(match.range) }; if found >= 200 { stop.pointee = true }
                            }
                            if found == 0 { missing = true; break }; occurrences += found; phrase = phrase || term.phrase
                            if found < rarest { rarest = found; anchor = first }
                        }
                        guard !missing, let anchor else { continue }
                        let weights: [String: Double] = ["user": 4, "assistant": 3, "thinking": 1.5, "tool": 1, "system": 0.75]
                        let source = Array(block.text.utf16)
                        func word(_ index: Int) -> Bool { guard source.indices.contains(index) else { return false }; let value = source[index]; return value == 95 || (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) }
                        let boundary = ranges.contains { !word($0.location - 1) && !word($0.location + $0.length) }
                        var score = (weights[block.role.rawValue] ?? 0) + (phrase ? 1.5 : 0) + (boundary ? 0.75 : 0) + min(2, log2(1 + Double(occurrences)))
                        if at > 0 { score += 2 * pow(0.5, max(0, started - at) / (14 * 86_400_000)) }; if sidechain { score *= 0.8 }
                        local.append(BackendUsageIO.object([("sessionId", .string(file.sessionID)), ("transcriptPath", .string(file.path)), ("cwd", .string(cwd)), ("projectName", .string(URL(fileURLWithPath: cwd).lastPathComponent)), ("at", .number(at)), ("role", .string(block.role.rawValue)), ("tool", BackendUsageIO.string(block.tool)), ("isSidechain", .bool(sidechain)), ("score", .number(score)), ("matches", .number(Double(occurrences))), ("snippet", Self.snippet(block.text, ranges: ranges.sorted { $0.location < $1.location }, anchor: anchor))]))
                    }
                    if local.count > request.maxHitsPerSession * 4 { local.sort { ($0["score"].number ?? 0) > ($1["score"].number ?? 0) }; local = Array(local.prefix(request.maxHitsPerSession)) }
                }
                opened += 1; bytes += scan.bytes; truncated = truncated || scan.truncated
                local.sort { ($0["score"].number ?? 0) > ($1["score"].number ?? 0) }; local = Array(local.prefix(max(1, request.maxHitsPerSession)))
                if !cwd.isEmpty { local = local.map { $0.setting("cwd", .string(cwd)).setting("projectName", .string(URL(fileURLWithPath: cwd).lastPathComponent)) } }
                totalHits += local.count; hits += local
                if scan.truncated { break }
            }
        } catch is CancellationError { cancelled = true }
        catch let error as QueryFailure where error.code == "deadline" { truncated = true }
        hits.sort { let a = $0["score"].number ?? 0, b = $1["score"].number ?? 0; return a == b ? ($0["at"].number ?? 0) > ($1["at"].number ?? 0) : a > b }
        if hits.count > request.maxHits { truncated = true; hits = Array(hits.prefix(request.maxHits)) }
        return BackendUsageIO.object([("ok", .bool(true)), ("query", .string(request.query)), ("scope", .string(request.allProjects ? "all" : "project")), ("hits", .array(hits)), ("sessionsScanned", .number(Double(opened))), ("sessionsSkipped", .number(Double(max(0, all.count - opened)))), ("bytesScanned", .number(Double(bytes))), ("totalHits", .number(Double(totalHits))), ("truncated", .bool(truncated || BackendUsageIO.now() >= deadline)), ("cancelled", .bool(cancelled)), ("tookMs", .number(BackendUsageIO.now() - started))])
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], ownerID: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        if channel == "session-search:cancel" { cancel(ownerID: ownerID); return .null }
        guard channel == "session-search:run" else { throw BackendSessionFailure.unsupported("The native search channel is not registered.") }
        cancel(ownerID: ownerID); let cancellation = BackendMCPCancellation(); active[ownerID] = cancellation
        defer { if active[ownerID] === cancellation { active[ownerID] = nil } }
        do { return try await search(.parse(args.first ?? .missing), context: context, cancellation: cancellation) }
        catch is CancellationError { return BackendUsageIO.object([("ok", .bool(false)), ("error", .string("cancelled")), ("message", .string("The search was cancelled."))]) }
    }
    public func cancel(ownerID: String) { active.removeValue(forKey: ownerID)?.cancel() }
    public func stop() { active.values.forEach { $0.cancel() }; active.removeAll() }
}
