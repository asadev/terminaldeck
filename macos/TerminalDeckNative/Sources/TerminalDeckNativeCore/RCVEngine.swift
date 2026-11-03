import Foundation

/// The Receiver's generic core: paths into any payload, templates, conditions,
/// normalization into the one envelope, and "learn from a sample". Nothing here
/// knows a vendor; presets are data (RCVPresets.swift).
public enum RCVEngine {
    public static let maxTitle = 300, maxText = 4_000, maxKind = 120, maxField = 2_000, maxFields = 40
    public static let maxSplit = 50, maxInstruction = 20_000, maxRawBytes = 80 * 1024

    // MARK: Context

    /// What a path can reach. In mapping, bare names read the payload; once an
    /// event exists (rules, instructions, replies), bare names read the envelope.
    public struct Context {
        public var payload: Any
        public var item: Any?
        public var headers: [String: String]
        public var meta: [String: String]
        public var event: RCVEvent?
        public var extra: [String: String]
        public init(payload: Any, item: Any? = nil, headers: [String: String] = [:], meta: [String: String] = [:],
                    event: RCVEvent? = nil, extra: [String: String] = [:]) {
            self.payload = payload; self.item = item; self.headers = headers; self.meta = meta; self.event = event; self.extra = extra
        }
        public static func of(_ event: RCVEvent, extra: [String: String] = [:]) -> Context {
            let raw = (try? JSONSerialization.jsonObject(with: event.raw, options: [.fragmentsAllowed])) ?? [String: Any]()
            return Context(payload: raw, headers: event.headers, meta: ["receivedAt": String(Int64(event.receivedAt)), "source": event.sourceId],
                           event: event, extra: extra)
        }
    }

    // MARK: Paths

    enum Segment: Equatable { case key(String), index(Int) }

    static func segments(_ path: String) -> [Segment]? {
        var out: [Segment] = []
        var current = ""
        var chars = Array(path)
        var i = 0
        if chars.first == "." { chars.removeFirst() }
        while i < chars.count {
            let c = chars[i]
            if c == "." {
                guard !current.isEmpty || out.last.map({ if case .index = $0 { true } else { false } }) == true else { return nil }
                if !current.isEmpty { out.append(.key(current)); current = "" }
            } else if c == "[" {
                if !current.isEmpty { out.append(.key(current)); current = "" }
                guard let close = chars[i...].firstIndex(of: "]"), let n = Int(String(chars[(i + 1)..<close])), n >= 0, n < 10_000 else { return nil }
                out.append(.index(n)); i = close
            } else { current.append(c) }
            i += 1
        }
        if !current.isEmpty { out.append(.key(current)) }
        return out.count <= 16 ? out : nil
    }

    static func walk(_ root: Any?, _ path: String) -> Any? {
        guard var node = root else { return nil }
        if path.isEmpty { return node }
        guard let parts = segments(path) else { return nil }
        for part in parts {
            switch part {
            case .key(let key):
                guard let object = node as? [String: Any], let next = object[key] else { return nil }
                node = next
            case .index(let n):
                guard let array = node as? [Any], n < array.count else { return nil }
                node = array[n]
            }
        }
        if node is NSNull { return nil }
        return node
    }

    /// A value as text: numbers without a trailing ".0", booleans as true/false, objects as compact JSON.
    public static func text(_ value: Any?) -> String? {
        switch value {
        case nil: return nil
        case let string as String: return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            if double.rounded() == double, abs(double) < 1e15 { return String(Int64(double)) }
            return String(double)
        case let other?:
            guard JSONSerialization.isValidJSONObject(other), let data = try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys]) else { return nil }
            return String(decoding: data.prefix(maxField), as: UTF8.self)
        }
    }

    /// Resolve one path (no alternatives, no quotes) to text.
    public static func resolve(_ rawPath: String, in context: Context) -> String? {
        let path = rawPath.trimmingCharacters(in: .whitespaces)
        func after(_ prefix: String) -> String? { path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil }
        if let name = after("header.") { return context.headers[name.lowercased()] }
        if let name = after("meta.") { return context.meta[name] }
        if let name = after("secret.") { return context.extra["secret." + name] }
        if path == "item" { return text(context.item) }
        if let rest = after("item.") ?? after("item[").map({ "[" + $0 }) { return text(walk(context.item, rest)) }
        if path == "$" || path == "raw" { return text(context.payload) }
        if let rest = after("$.") ?? after("raw.") ?? after("$[").map({ "[" + $0 }) ?? after("raw[").map({ "[" + $0 }) {
            return text(walk(context.payload, rest))
        }
        if let event = context.event {
            if let name = after("fields.") { return event.fields[name] }
            switch path {
            case "kind": return event.kind
            case "severity": return event.severity.rawValue
            case "title": return event.title
            case "text": return event.text
            case "source": return event.sourceId
            case "id", "eventId": return event.id
            case "upstreamId": return event.upstreamId
            case "time": return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: event.time / 1000))
            default: break
            }
        }
        if let value = context.extra[path] { return value }
        return text(walk(context.payload, path))
    }

    // MARK: Templates

    public struct TemplateError: Error, Equatable { public let message: String }

    /// Placeholders in a template, in order. Throws when braces do not pair.
    public static func placeholders(_ template: String) throws -> [String] {
        var out: [String] = []
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            guard let close = rest[open.upperBound...].range(of: "}}") else { throw TemplateError(message: "A {{ has no matching }}.") }
            let inner = String(rest[open.upperBound..<close.lowerBound])
            guard !inner.contains("{{"), !inner.trimmingCharacters(in: .whitespaces).isEmpty, inner.count <= 400 else {
                throw TemplateError(message: "A {{…}} placeholder is empty, nested or too long.")
            }
            out.append(inner); rest = rest[close.upperBound...]
        }
        guard out.count <= 64 else { throw TemplateError(message: "A template may have at most 64 placeholders.") }
        return out
    }

    /// `a|b|"literal"`: the first alternative that is present and not empty.
    static func alternatives(_ expression: String, in context: Context) -> String? {
        var parts: [String] = []
        var current = "", quoted = false
        for c in expression {
            if c == "\"" { quoted.toggle(); current.append(c) }
            else if c == "|" && !quoted { parts.append(current); current = "" }
            else { current.append(c) }
        }
        parts.append(current)
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") { return String(trimmed.dropFirst().dropLast()) }
            if let value = resolve(trimmed, in: context), !value.isEmpty { return value }
        }
        return nil
    }

    /// Fill a template in one pass. Values are inserted as they are and never
    /// read again, so a `{{…}}` inside an incoming message stays literal text.
    public static func render(_ template: String, in context: Context, limit: Int = maxInstruction,
                              escape: (String) -> String = { $0 }) throws -> String {
        _ = try placeholders(template)
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            out += rest[..<open.lowerBound]
            out += escape(alternatives(String(rest[open.upperBound..<close.lowerBound]), in: context) ?? "")
            rest = rest[close.upperBound...]
            guard out.count <= limit else { throw TemplateError(message: "The filled text is longer than \(limit) characters.") }
        }
        out += rest
        guard out.count <= limit else { throw TemplateError(message: "The filled text is longer than \(limit) characters.") }
        return out
    }

    public static func jsonEscape(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return String(text.dropFirst(2).dropLast(2))
    }

    // MARK: Conditions

    public static func matches(_ condition: RCVCondition, in context: Context) -> Bool {
        let actual = resolve(condition.path, in: context)
        let expected = condition.value
        switch condition.operation {
        case .exists: return actual.map { !$0.isEmpty } ?? false
        case .missing: return actual.map { $0.isEmpty } ?? true
        case .equals: return actual == expected
        case .notEquals: return actual != expected
        case .contains: return actual?.localizedCaseInsensitiveContains(expected) == true
        case .notContains: return actual?.localizedCaseInsensitiveContains(expected) != true
        case .startsWith: return actual?.lowercased().hasPrefix(expected.lowercased()) == true
        case .oneOf:
            let options = expected.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return actual.map(options.contains) ?? false
        case .above, .below:
            guard let a = actual.flatMap(Double.init), let b = Double(expected) else { return false }
            return condition.operation == .above ? a > b : a < b
        case .atLeast:
            guard let actual else { return false }
            return RCVSeverity.reading(actual) >= RCVSeverity.reading(expected)
        case .matches:
            guard let actual, let regex = try? NSRegularExpression(pattern: expected, options: [.caseInsensitive]) else { return false }
            let bounded = String(actual.prefix(10_000))
            return regex.firstMatch(in: bounded, range: NSRange(bounded.startIndex..., in: bounded)) != nil
        }
    }

    // MARK: Normalization

    /// Read a body as JSON; a form body as an object; anything else as `{"text": …}`.
    public static func payload(_ body: Data, contentType: String?) -> Any {
        if let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]), json is [String: Any] || json is [Any] {
            return json
        }
        let text = String(decoding: body.prefix(maxRawBytes), as: UTF8.self)
        if contentType?.lowercased().hasPrefix("application/x-www-form-urlencoded") == true {
            var object: [String: Any] = [:]
            for pair in text.split(separator: "&").prefix(200) {
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
                if let key = parts.first, !key.isEmpty { object[key] = parts.count > 1 ? parts[1] : "" }
            }
            return object
        }
        return ["text": text]
    }

    /// Header names that prove identity are never kept with an event.
    public static func keptHeaders(_ headers: [String: String], auth: RCVAuth) -> [String: String] {
        let secretWords = ["authorization", "signature", "secret", "token", "password", "cookie", "api-key", "apikey", "x-api", "auth"]
        var out: [String: String] = [:]
        for (name, value) in headers {
            let lower = name.lowercased()
            if secretWords.contains(where: lower.contains) { continue }
            if lower == auth.tokenHeader?.lowercased() || lower == auth.hmac?.header.lowercased() || lower == auth.hmac?.timestampHeader?.lowercased() { continue }
            out[lower] = String(value.prefix(512))
            if out.count >= 32 { break }
        }
        return out
    }

    /// Time from text: Unix seconds or milliseconds, or ISO 8601.
    public static func time(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let number = Double(text) { return number > 1e12 ? number : number * 1000 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 * 1000 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text).map { $0.timeIntervalSince1970 * 1000 }
    }

    /// One delivery → one or more envelopes. `ignored` events carry status `.ignored`.
    public static func normalize(body: Data, headers: [String: String], meta: [String: String], source: RCVSource,
                                 receivedAt: Double) -> [RCVEvent] {
        let contentType = headers["content-type"]
        let root = payload(body, contentType: contentType)
        let mapping = source.mapping
        var items: [Any?] = [nil]
        if let split = mapping.split, !split.isEmpty, let array = walk(root, split.hasPrefix("$.") ? String(split.dropFirst(2)) : split) as? [Any], !array.isEmpty {
            items = Array(array.prefix(maxSplit))
        }
        let kept = keptHeaders(headers, auth: source.auth)
        return items.map { item in
            let context = Context(payload: root, item: item, headers: headers, meta: meta)
            func fill(_ template: String?, _ limit: Int) -> String {
                guard let template else { return "" }
                return String(((try? render(template, in: context, limit: limit * 4)) ?? "").prefix(limit))
            }
            var fields: [String: String] = [:]
            for map in mapping.fields.prefix(maxFields) {
                let value = fill(map.value, maxField)
                if !value.isEmpty { fields[map.name] = value }
            }
            let rawObject = item ?? root
            var raw = (try? JSONSerialization.data(withJSONObject: rawObject, options: [.sortedKeys])) ?? Data("{}".utf8)
            if raw.count > maxRawBytes { raw = Data("{\"text\":\"The original was too large to keep.\"}".utf8) }
            let kind = fill(mapping.kind, maxKind).trimmingCharacters(in: .whitespacesAndNewlines)
            let upstream = fill(mapping.upstreamId, 200)
            var event = RCVEvent(sourceId: source.id, receivedAt: receivedAt, time: time(fill(mapping.time, 64)), kind: kind.isEmpty ? "event" : kind,
                                 severity: .reading(fill(mapping.severity, 40)), title: fill(mapping.title, maxTitle),
                                 text: fill(mapping.text, maxText), fields: fields, raw: raw, headers: kept,
                                 upstreamId: upstream.isEmpty ? nil : upstream)
            if event.title.isEmpty { event.title = event.text.isEmpty ? "\(source.name): \(event.kind)" : String(event.text.prefix(120)) }
            if mapping.ignore.contains(where: { matches($0, in: context) }) { event.status = .ignored }
            return event
        }
    }

    // MARK: Learn from a sample

    /// Propose a mapping from one real payload: the likely type, title, text,
    /// level, time and id, and a few more fields. A suggestion the owner edits.
    public static func learn(body: Data, headers: [String: String]) -> RCVMapping {
        let root = payload(body, contentType: headers["content-type"])
        var split: String?
        var base: Any = root
        var prefix = ""
        if let object = root as? [String: Any] {
            for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                if let array = value as? [Any], let first = array.first as? [String: Any], !first.isEmpty, object.count <= 6 {
                    split = key; base = first; prefix = "item."; break
                }
            }
        } else if let array = root as? [Any], let first = array.first {
            base = first; prefix = "[0]."
        }
        var scalars: [(path: String, key: String, depth: Int)] = []
        func collect(_ node: Any, _ path: String, _ depth: Int) {
            guard depth <= 4, scalars.count < 400 else { return }
            if let object = node as? [String: Any] {
                for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                    guard key.range(of: #"^[A-Za-z0-9_\-]{1,64}$"#, options: .regularExpression) != nil else { continue }
                    let next = path.isEmpty ? key : path + "." + key
                    if value is [String: Any] { collect(value, next, depth + 1) }
                    else if !(value is [Any]), text(value) != nil { scalars.append((next, key.lowercased(), depth)) }
                }
            }
        }
        collect(base, "", 0)
        func pick(_ names: [String], exclude: Set<String> = []) -> String? {
            for name in names {
                if let hit = scalars.filter({ $0.key == name && !exclude.contains($0.path) }).min(by: { $0.depth < $1.depth }) { return prefix + hit.path }
            }
            return nil
        }
        let headerNames = headers.keys.map { $0.lowercased() }.sorted()
        let kindHeader = headerNames.first { $0.range(of: #"^x-.*-event(-type)?$|-hook-resource$|^x-event-type$"#, options: .regularExpression) != nil }
        let idHeader = headerNames.first { $0.range(of: #"delivery|request-id|idempotency-key|message-id"#, options: .regularExpression) != nil }
        let kind = kindHeader.map { "header." + $0 } ?? pick(["event", "event_type", "eventtype", "type", "action", "topic", "kind"])
        let title = pick(["title", "subject", "summary", "headline", "alertname", "alert_name", "check_name", "name"])
        let body = pick(["message", "text", "body", "description", "details", "content", "msg", "culprit"], exclude: Set([title].compactMap { $0 }.map { String($0.dropFirst(prefix.count)) }))
        let severity = pick(["severity", "level", "priority", "status", "state"])
        let time = pick(["timestamp", "time", "created_at", "createdat", "occurred_at", "date", "ts"])
        let upstream = idHeader.map { "header." + $0 } ?? pick(["id", "event_id", "eventid", "uuid", "message_id", "delivery_id"])
        let used = Set([kind, title, body, severity, time, upstream].compactMap { $0 })
        var fields: [RCVFieldMap] = []
        for scalar in scalars.sorted(by: { ($0.depth, $0.path) < ($1.depth, $1.path) }) where fields.count < 8 {
            let full = prefix + scalar.path
            guard !used.contains(full), !scalar.key.contains("secret"), !scalar.key.contains("token"), !scalar.key.contains("password") else { continue }
            let name = String(scalar.path.replacingOccurrences(of: ".", with: "_").suffix(40))
            fields.append(.init(name, "{{\(full)}}"))
        }
        func template(_ path: String?, _ fallback: String) -> String { path.map { "{{\($0)|\"\(fallback)\"}}" } ?? "{{\"\(fallback)\"}}" }
        return RCVMapping(split: split, kind: template(kind, "event"), severity: template(severity, "info"),
                          title: title.map { "{{\($0)}}" } ?? "", text: body.map { "{{\($0)}}" } ?? "",
                          time: time.map { "{{\($0)}}" }, upstreamId: upstream.map { "{{\($0)}}" }, fields: fields)
    }

    // MARK: Validation

    public static func check(_ template: String, _ label: String, max: Int = 8_000) throws {
        guard template.count <= max else { throw NativeRPCError.invalidArguments("\(label) is too long.") }
        do { _ = try placeholders(template) } catch let error as TemplateError { throw NativeRPCError.invalidArguments("\(label): \(error.message)") }
    }

    static let headerName = #"^[a-z0-9][a-z0-9-]{0,63}$"#

    public static func validIP(_ entry: String) -> Bool {
        let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let address = parts.first else { return false }
        var v4 = in_addr(), v6 = in6_addr()
        let isV4 = inet_pton(AF_INET, String(address), &v4) == 1
        let isV6 = !isV4 && inet_pton(AF_INET6, String(address), &v6) == 1
        guard isV4 || isV6 else { return false }
        if parts.count == 2 { guard let bits = Int(parts[1]), bits >= 0, bits <= (isV4 ? 32 : 128) else { return false } }
        return true
    }

    public static func validate(_ source: RCVSource) throws {
        func bad(_ m: String) -> NativeRPCError { .invalidArguments(m) }
        guard !source.name.trimmingCharacters(in: .whitespaces).isEmpty, source.name.count <= 80 else { throw bad("Give the source a name of up to 80 characters.") }
        let auth = source.auth
        if auth.scheme == .hmac {
            guard let hmac = auth.hmac, hmac.header.range(of: headerName, options: .regularExpression) != nil else { throw bad("A signed source needs the lowercase header its signature arrives in.") }
            guard hmac.prefix.count <= 32, hmac.signedPayload.contains("{body}"), hmac.signedPayload.count <= 64, (0...86_400).contains(hmac.toleranceSeconds) else { throw bad("The signature settings are not valid.") }
            if hmac.signedPayload.contains("{timestamp}") {
                guard let ts = hmac.timestampHeader, ts.range(of: headerName, options: .regularExpression) != nil else { throw bad("Name the header the signed timestamp arrives in.") }
            }
        }
        if let header = auth.tokenHeader { guard header.range(of: headerName, options: .regularExpression) != nil else { throw bad("The token header name is not valid.") } }
        if auth.scheme == .basic { guard let user = auth.basicUser, !user.isEmpty, user.count <= 64, !user.contains(":") else { throw bad("Basic sign-in needs a user name without a colon.") } }
        guard auth.ipAllow.count <= 32, auth.ipAllow.allSatisfy(validIP) else { throw bad("Each allowed address must be an IP address or range, at most 32.") }
        let m = source.mapping
        for (template, label) in [(m.kind, "The type"), (m.severity, "The level"), (m.title, "The title"), (m.text, "The text"),
                                  (m.time ?? "", "The time"), (m.upstreamId ?? "", "The sender's id")] { try check(template, label, max: 400) }
        guard m.fields.count <= maxFields, m.ignore.count <= 20 else { throw bad("Use at most \(maxFields) fields and 20 ignore conditions.") }
        for field in m.fields {
            guard field.name.range(of: #"^[A-Za-z0-9_\-]{1,40}$"#, options: .regularExpression) != nil else { throw bad("Field names use letters, digits, - and _.") }
            try check(field.value, "Field \(field.name)", max: 400)
        }
        try m.ignore.forEach(validate)
        if let reply = source.reply {
            switch reply.via {
            case .http:
                guard ["POST", "PUT", "PATCH"].contains(reply.method), reply.url.hasPrefix("https://"), reply.url.count <= 500 else { throw bad("A reply address must be https and use POST, PUT or PATCH.") }
                try check(reply.url, "The reply address", max: 500)
                // The host is fixed by the owner: event values may fill the path, never the host.
                let host = reply.url.dropFirst("https://".count).prefix { $0 != "/" }
                guard !host.contains("{{"), !host.isEmpty else { throw bad("The reply address's host must be written out, not filled from the message.") }
                try check(reply.body, "The reply body", max: 4_000)
                guard reply.headers.count <= 16 else { throw bad("Use at most 16 reply headers.") }
                for header in reply.headers {
                    guard header.name.lowercased().range(of: headerName, options: .regularExpression) != nil else { throw bad("A reply header name is not valid.") }
                    try check(header.value, "Reply header \(header.name)", max: 500)
                }
            case .github:
                try check(reply.repository ?? "", "The repository", max: 200); try check(reply.number ?? "", "The number", max: 200)
            }
        }
    }

    public static func validate(_ condition: RCVCondition) throws {
        guard !condition.path.isEmpty, condition.path.count <= 200, condition.value.count <= 2_000 else { throw NativeRPCError.invalidArguments("Each condition needs a path and a short value.") }
        if condition.operation == .matches {
            guard condition.value.count <= 200, (try? NSRegularExpression(pattern: condition.value)) != nil else { throw NativeRPCError.invalidArguments("That pattern is not a valid regular expression.") }
        }
    }

    public static func validate(_ rule: RCVRule) throws {
        func bad(_ m: String) -> NativeRPCError { .invalidArguments(m) }
        guard !rule.name.trimmingCharacters(in: .whitespaces).isEmpty, rule.name.count <= 120 else { throw bad("Give the rule a name of up to 120 characters.") }
        guard rule.sourceIds.count <= 64, rule.conditions.count <= 20 else { throw bad("Use at most 20 conditions.") }
        try rule.conditions.forEach(validate)
        guard !rule.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw bad("Write what the target should do.") }
        try check(rule.instruction, "The instruction")
        guard (1...120).contains(rule.perMinute), (0...1_440).contains(rule.dedupeMinutes) else { throw bad("Use 1 to 120 per minute and up to 1,440 minutes for repeats.") }
        switch rule.target.kind {
        case .hoot: break
        case .agent, .newTask, .session:
            guard !rule.target.id.isEmpty, rule.target.id.count <= 200 else { throw bad("Choose who the rule hands events to.") }
        }
        if let key = rule.target.threadKey { try check(key, "The conversation key", max: 200) }
        guard rule.project.isEmpty || (rule.project.hasPrefix("/") && !rule.project.contains("\0") && rule.project.count <= 1_024) else { throw bad("The project folder must be a full folder path.") }
        if let quiet = rule.quietHours {
            guard (0...23).contains(quiet.startHour), (0...23).contains(quiet.endHour), quiet.startHour != quiet.endHour, TimeZone(identifier: quiet.timeZone) != nil else { throw bad("Quiet hours need two different hours and a real time zone.") }
        }
    }
}
