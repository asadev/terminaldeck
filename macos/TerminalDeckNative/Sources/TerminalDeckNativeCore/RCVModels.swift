import Foundation

// The Receiver: one generic inbound hub. Every incoming thing (a webhook through
// the relay, or one of Terminal Deck's own events) becomes the same envelope, and
// rules match on envelope fields and on any path into the untouched payload.
// Vendors (WhatsApp/Whapi, CRM, GitHub, Sentry, server alerts) are only presets:
// an auth scheme + a field mapping + example rules, all editable (RCVPresets.swift).

// MARK: - Sources

/// How a sender proves itself. The relay checks what it can; the Mac checks again end to end.
public enum RCVAuthScheme: String, Codable, CaseIterable, Sendable {
    case hmac, token, basic, none
    public var title: String {
        switch self {
        case .hmac: "Signed (HMAC)"
        case .token: "Secret token"
        case .basic: "Username and password"
        case .none: "Private address only"
        }
    }
}

public struct RCVHMAC: Codable, Equatable, Sendable {
    public enum Algorithm: String, Codable, CaseIterable, Sendable { case sha1, sha256, sha512 }
    public enum Encoding: String, Codable, CaseIterable, Sendable { case hex, base64 }
    /// Lowercase header name the sender puts its signature in.
    public var header: String
    public var algorithm: Algorithm
    public var encoding: Encoding
    /// Text before the signature in the header, e.g. "sha256=". Empty for none.
    public var prefix: String
    /// What is signed: "{body}", or e.g. "{timestamp}.{body}" / "v0:{timestamp}:{body}".
    public var signedPayload: String
    /// Header carrying the timestamp when `signedPayload` uses one.
    public var timestampHeader: String?
    /// How old a signed timestamp may be, in seconds (replay protection).
    public var toleranceSeconds: Int
    public init(header: String, algorithm: Algorithm = .sha256, encoding: Encoding = .hex, prefix: String = "",
                signedPayload: String = "{body}", timestampHeader: String? = nil, toleranceSeconds: Int = 300) {
        self.header = header; self.algorithm = algorithm; self.encoding = encoding; self.prefix = prefix
        self.signedPayload = signedPayload; self.timestampHeader = timestampHeader; self.toleranceSeconds = toleranceSeconds
    }
}

public struct RCVAuth: Codable, Equatable, Sendable {
    public var scheme: RCVAuthScheme
    public var hmac: RCVHMAC?
    /// Extra header a token may arrive in (besides the address path and `Authorization: Bearer`).
    public var tokenHeader: String?
    /// Basic auth user name (not secret). The password is the source secret.
    public var basicUser: String?
    /// Addresses or ranges (`203.0.113.0/24`) allowed to send. Empty: anyone with the address.
    public var ipAllow: [String]
    public init(scheme: RCVAuthScheme, hmac: RCVHMAC? = nil, tokenHeader: String? = nil, basicUser: String? = nil, ipAllow: [String] = []) {
        self.scheme = scheme; self.hmac = hmac; self.tokenHeader = tokenHeader; self.basicUser = basicUser; self.ipAllow = ipAllow
    }
}

/// Turns a raw payload into the envelope. Every value is a template (RCVEngine):
/// `{{path|path|"literal"}}` takes the first non-empty alternative.
public struct RCVMapping: Codable, Equatable, Sendable {
    /// Path to an array; each element becomes its own event, reachable as `item.…`.
    public var split: String?
    public var kind: String
    public var severity: String
    public var title: String
    public var text: String
    public var time: String?
    /// The sender's own id for this event, used to drop repeats.
    public var upstreamId: String?
    public var fields: [RCVFieldMap]
    /// Events matching ANY of these are kept as "ignored" and never routed (e.g. echoes of our own replies).
    public var ignore: [RCVCondition]
    public init(split: String? = nil, kind: String = "{{type|event|\"event\"}}", severity: String = "{{severity|level|\"info\"}}",
                title: String = "{{title|subject|summary|name}}", text: String = "{{message|text|body|description}}",
                time: String? = nil, upstreamId: String? = nil, fields: [RCVFieldMap] = [], ignore: [RCVCondition] = []) {
        self.split = split; self.kind = kind; self.severity = severity; self.title = title; self.text = text
        self.time = time; self.upstreamId = upstreamId; self.fields = fields; self.ignore = ignore
    }
}

public struct RCVFieldMap: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

/// How an agent answers through the same connection. Recipients come only from
/// the event (templates over its fields); the agent supplies only the text.
public struct RCVReplyChannel: Codable, Equatable, Sendable {
    public enum Via: String, Codable, CaseIterable, Sendable { case http, github }
    public var via: Via
    public var method: String
    /// Template; may use event values such as `{{fields.chat}}`. Must be https.
    public var url: String
    /// Header templates. `{{secret.reply}}` is the reply credential kept in the secure store.
    public var headers: [RCVFieldMap]
    /// Body template. `{{reply}}` is the agent's text, JSON-escaped when the body is JSON.
    public var body: String
    /// For `.github`: templates for the repository ("owner/name") and issue or pull request number.
    public var repository: String?
    public var number: String?
    public init(via: Via = .http, method: String = "POST", url: String = "", headers: [RCVFieldMap] = [], body: String = "{\"text\":\"{{reply}}\"}",
                repository: String? = nil, number: String? = nil) {
        self.via = via; self.method = method; self.url = url; self.headers = headers; self.body = body
        self.repository = repository; self.number = number
    }
}

public enum RCVOrigin: String, Codable, Sendable { case relay, terminalDeck }

public struct RCVSource: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The preset it started from (informational; nothing branches on it).
    public var preset: String
    public var origin: RCVOrigin
    public var auth: RCVAuth
    public var mapping: RCVMapping
    public var reply: RCVReplyChannel?
    public var enabled: Bool
    public var createdAt: Double
    public init(id: String, name: String, preset: String, origin: RCVOrigin = .relay, auth: RCVAuth, mapping: RCVMapping,
                reply: RCVReplyChannel? = nil, enabled: Bool = true, createdAt: Double = Date().timeIntervalSince1970 * 1000) {
        self.id = id; self.name = name; self.preset = preset; self.origin = origin; self.auth = auth; self.mapping = mapping
        self.reply = reply; self.enabled = enabled; self.createdAt = createdAt
    }
}

// MARK: - Conditions and rules

public struct RCVCondition: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, CaseIterable, Sendable {
        case equals, notEquals, contains, notContains, startsWith, matches, exists, missing, oneOf, above, below, atLeast
        public var title: String {
            switch self {
            case .equals: "is"; case .notEquals: "is not"; case .contains: "contains"; case .notContains: "does not contain"
            case .startsWith: "starts with"; case .matches: "matches pattern"; case .exists: "is present"; case .missing: "is missing"
            case .oneOf: "is one of"; case .above: "is above"; case .below: "is below"; case .atLeast: "is at least"
            }
        }
    }
    /// `kind`, `severity`, `title`, `text`, `source`, `fields.<name>`, `raw.<path>` (or `$.<path>`), `header.<name>`.
    public var path: String
    public var operation: Operation
    /// For `oneOf`: values separated by commas. For `atLeast`: a severity word.
    public var value: String
    public init(_ path: String, _ operation: Operation = .equals, _ value: String = "") {
        self.path = path; self.operation = operation; self.value = value
    }
}

public struct RCVQuietHours: Codable, Equatable, Sendable {
    public var startHour: Int, endHour: Int, timeZone: String
    public init(startHour: Int = 22, endHour: Int = 8, timeZone: String = TimeZone.current.identifier) {
        self.startHour = startHour; self.endHour = endHour; self.timeZone = timeZone
    }
    /// When quiet hours started before `date` end, or nil when `date` is not in them.
    public func ends(after date: Date) -> Date? {
        guard let zone = TimeZone(identifier: timeZone), startHour != endHour else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let hour = calendar.component(.hour, from: date)
        let quiet = startHour < endHour ? (hour >= startHour && hour < endHour) : (hour >= startHour || hour < endHour)
        guard quiet else { return nil }
        return calendar.nextDate(after: date, matching: DateComponents(hour: endHour, minute: 0, second: 0), matchingPolicy: .nextTime)
    }
}

public enum RCVTargetKind: String, Codable, CaseIterable, Sendable {
    /// One ongoing task per conversation for a task agent; later messages join it.
    case agent
    /// A new task for a task agent, every time.
    case newTask
    /// Typed into a running AI session.
    case session
    /// A task for Hoot.
    case hoot
    public var title: String {
        switch self {
        case .agent: "Task agent (ongoing conversation)"
        case .newTask: "New task for an agent"
        case .session: "Running session"
        case .hoot: "Hoot"
        }
    }
}

public struct RCVTarget: Codable, Equatable, Sendable {
    public var kind: RCVTargetKind
    /// Agent id, session id, or "hoot".
    public var id: String
    /// For `.agent`: which events share one ongoing task, e.g. `{{fields.chat}}`. Default: the source.
    public var threadKey: String?
    public init(kind: RCVTargetKind = .hoot, id: String = "hoot", threadKey: String? = nil) {
        self.kind = kind; self.id = id; self.threadKey = threadKey
    }
}

public struct RCVRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// Empty: any source.
    public var sourceIds: [String]
    /// All must match.
    public var conditions: [RCVCondition]
    public var target: RCVTarget
    /// Owner-written; `{{title}}`, `{{text}}`, `{{fields.x}}`, `{{raw.path}}` … are filled once, never re-expanded.
    public var instruction: String
    /// Folder an agent's task works in. Empty: the agent's default project.
    public var project: String
    public var perMinute: Int
    /// The same filled instruction within this many minutes is a repeat. 0: off.
    public var dedupeMinutes: Int
    public var quietHours: RCVQuietHours?
    /// Replies to events this rule routed are sent without asking. Only the owner, on the Receiver page, can turn it on.
    public var autoApproveReplies: Bool
    public init(id: String = UUID().uuidString.lowercased(), name: String, enabled: Bool = true, sourceIds: [String] = [],
                conditions: [RCVCondition] = [], target: RCVTarget = .init(), instruction: String = "{{title}}\n{{text}}",
                project: String = "", perMinute: Int = 10, dedupeMinutes: Int = 0, quietHours: RCVQuietHours? = nil,
                autoApproveReplies: Bool = false) {
        self.id = id; self.name = name; self.enabled = enabled; self.sourceIds = sourceIds; self.conditions = conditions
        self.target = target; self.instruction = instruction; self.project = project; self.perMinute = perMinute
        self.dedupeMinutes = dedupeMinutes; self.quietHours = quietHours; self.autoApproveReplies = autoApproveReplies
    }
}

// MARK: - Events

public enum RCVSeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case debug, info, warning, error, critical
    var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    /// Sender words onto the five levels: "fatal" is critical, "warn" is warning, numbers 0-50 Sentry/syslog-style.
    public static func reading(_ text: String) -> RCVSeverity {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "debug", "trace", "verbose", "10": .debug
        case "warning", "warn", "notice", "degraded", "30": .warning
        case "error", "err", "failed", "failure", "down", "high", "40": .error
        case "critical", "crit", "fatal", "emergency", "emerg", "alert", "panic", "50": .critical
        default: .info
        }
    }
}

public enum RCVStatus: String, Codable, CaseIterable, Sendable {
    /// Matched no rule; waits in the Unrouted inbox.
    case unrouted
    /// Waiting for quiet hours or a rate limit to pass.
    case held
    /// Handed to its target.
    case delivered
    /// The target could not take it; retry is possible.
    case failed
    /// Already seen (same sender id, or same instruction inside the rule's window).
    case duplicate
    /// Dropped by the source's ignore list (e.g. our own reply coming back).
    case ignored
    /// Failed its signature or credential check on this Mac. No payload is kept.
    case rejected
}

public struct RCVStep: Codable, Equatable, Sendable {
    public var at: Double
    public var words: String
    public init(at: Double, _ words: String) { self.at = at; self.words = words }
}

public struct RCVReply: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case sent, failed, refused }
    public var id: String
    public var at: Double
    public var text: String
    public var state: State
    public var by: String
    public var autoApproved: Bool
    public var detail: String?
    public init(id: String = UUID().uuidString.lowercased(), at: Double, text: String, state: State, by: String, autoApproved: Bool, detail: String? = nil) {
        self.id = id; self.at = at; self.text = text; self.state = state; self.by = by; self.autoApproved = autoApproved; self.detail = detail
    }
}

/// The one envelope every incoming thing becomes, plus where it went.
public struct RCVEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sourceId: String
    public var receivedAt: Double
    public var time: Double
    public var kind: String
    public var severity: RCVSeverity
    public var title: String
    public var text: String
    public var fields: [String: String]
    /// The untouched payload as JSON (non-JSON bodies become `{"text": …}`). Never credentials.
    public var raw: Data
    /// Sender headers minus anything that proves identity (auth, signatures, tokens, cookies).
    public var headers: [String: String]
    public var upstreamId: String?
    public var status: RCVStatus
    public var trail: [RCVStep]
    public var ruleId: String?
    public var target: RCVTarget?
    public var instruction: String?
    public var taskId: String?
    public var sessionId: String?
    public var outcome: String?
    public var replies: [RCVReply]
    public var attempt: Int
    public var resumeAt: Double?
    public var replayOf: String?
    public init(id: String = UUID().uuidString.lowercased(), sourceId: String, receivedAt: Double, time: Double? = nil, kind: String,
                severity: RCVSeverity = .info, title: String = "", text: String = "", fields: [String: String] = [:],
                raw: Data = Data("{}".utf8), headers: [String: String] = [:], upstreamId: String? = nil) {
        self.id = id; self.sourceId = sourceId; self.receivedAt = receivedAt; self.time = time ?? receivedAt; self.kind = kind
        self.severity = severity; self.title = title; self.text = text; self.fields = fields; self.raw = raw; self.headers = headers
        self.upstreamId = upstreamId; status = .unrouted; trail = []; replies = []; attempt = 0
    }
}

/// What routing decided (also the dry-run answer).
public struct RCVDecision: Codable, Equatable, Sendable {
    public var status: RCVStatus
    public var reason: String
    public var ruleId: String?
    public var ruleName: String?
    public var target: RCVTarget?
    public var instruction: String?
    public var resumeAt: Double?
    public init(status: RCVStatus, reason: String, ruleId: String? = nil, ruleName: String? = nil, target: RCVTarget? = nil,
                instruction: String? = nil, resumeAt: Double? = nil) {
        self.status = status; self.reason = reason; self.ruleId = ruleId; self.ruleName = ruleName; self.target = target
        self.instruction = instruction; self.resumeAt = resumeAt
    }
}

// MARK: - What the screen and tools see

/// A source as shown to the page and to tools: never its secret.
public struct RCVSourceView: Codable, Equatable, Identifiable, Sendable {
    public var source: RCVSource
    /// The address to paste into the sender (relay sources), or nil for Terminal Deck's own sources.
    public var address: String?
    /// Whether the relay has confirmed this address is active.
    public var active: Bool
    public var hasReplyCredential: Bool
    public var lastEventAt: Double?
    public var eventCount: Int
    public var rejectedCount: Int
    public var id: String { source.id }
    public init(source: RCVSource, address: String?, active: Bool, hasReplyCredential: Bool, lastEventAt: Double?, eventCount: Int, rejectedCount: Int) {
        self.source = source; self.address = address; self.active = active; self.hasReplyCredential = hasReplyCredential
        self.lastEventAt = lastEventAt; self.eventCount = eventCount; self.rejectedCount = rejectedCount
    }
}

/// Shown once to the owner when a source is made or its secret is replaced.
public struct RCVSecretReveal: Codable, Equatable, Sendable {
    public var sourceId: String
    public var secret: String
    /// The address with the token built in, for senders that only take a URL (token sources only).
    public var addressWithSecret: String?
    public init(sourceId: String, secret: String, addressWithSecret: String?) {
        self.sourceId = sourceId; self.secret = secret; self.addressWithSecret = addressWithSecret
    }
}

/// Something a rule can hand events to, for the pickers.
public struct RCVChoice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct RCVOverview: Codable, Equatable, Sendable {
    public var sources: [RCVSourceView]
    public var rules: [RCVRule]
    public var events: [RCVEvent]
    public var unrouted: Int
    public var held: Int
    public var relayConnected: Bool
    public var relayBase: String?
    public var presets: [RCVPreset]
    /// Task agents and running AI sessions a rule can target.
    public var agents: [RCVChoice]
    public var sessions: [RCVChoice]
    public init(sources: [RCVSourceView], rules: [RCVRule], events: [RCVEvent], unrouted: Int, held: Int, relayConnected: Bool, relayBase: String?,
                presets: [RCVPreset], agents: [RCVChoice] = [], sessions: [RCVChoice] = []) {
        self.sources = sources; self.rules = rules; self.events = events; self.unrouted = unrouted; self.held = held
        self.relayConnected = relayConnected; self.relayBase = relayBase; self.presets = presets; self.agents = agents; self.sessions = sessions
    }
}

public enum RCVWire {
    public static func value<T: Encodable>(_ value: T) throws -> NativeRPCValue { try .parseJSON(JSONEncoder().encode(value)) }
    public static func decode<T: Decodable>(_ type: T.Type, _ value: NativeRPCValue) throws -> T {
        do { return try JSONDecoder().decode(type, from: value.encodedJSON()) }
        catch { throw NativeRPCError.invalidArguments("That Receiver value is not in the expected shape.") }
    }
}
