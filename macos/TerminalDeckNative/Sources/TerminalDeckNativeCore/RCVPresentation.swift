import Foundation

/// The Receiver page's words and projections: pure, so the screen stays thin and
/// every sentence a person reads is tested (RCVPresentationTests). Nothing here
/// calls the engine; the screen hands in what `receiver:overview` returned.
///
/// Everything is nested under `RCVPresentation` so these names can never collide
/// with the Receiver's backend types.
public enum RCVPresentation {

    // MARK: - Wire

    /// Read a channel answer (Foundation `Any`) as one of the Receiver's Codable types.
    public static func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        guard JSONSerialization.isValidJSONObject([value]) else {
            throw NativeRPCError.malformed("The Receiver’s answer could not be read.")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NativeRPCError.malformed("The Receiver’s answer could not be read.")
        }
    }

    /// A Codable value as a Foundation object, to send as a channel argument.
    public static func foundation<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }

    /// Any failure as one plain sentence for the page.
    public static func sentence(_ error: Error) -> String {
        if let wire = error as? EngineWireError { return wire.description }
        if let rpc = error as? NativeRPCError { return rpc.message.isEmpty ? "Something went wrong." : rpc.message }
        if error is DecodingError { return "The Receiver’s answer could not be read." }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Something went wrong." : text
    }

    /// `sourceCreate` answers this.
    public struct Created: Decodable, Sendable {
        public var source: RCVSourceView
        public var reveal: RCVSecretReveal?
    }

    /// `test` answers this.
    public struct TestAnswer: Decodable, Sendable {
        public var decision: RCVDecision
        public var event: RCVEvent
    }

    /// `askHoot` answers this.
    public struct TaskAnswer: Decodable, Sendable {
        public var taskId: String?
    }

    // MARK: - The rail

    public enum Place: String, CaseIterable, Identifiable, Sendable {
        case flow, unrouted, sources, rules
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .flow: "Flow"
            case .unrouted: "Unrouted"
            case .sources: "Sources"
            case .rules: "Rules"
            }
        }
        public var symbol: String {
            switch self {
            case .flow: "tray.and.arrow.down"
            case .unrouted: "tray"
            case .sources: "antenna.radiowaves.left.and.right"
            case .rules: "arrow.triangle.branch"
            }
        }
    }

    public static func count(_ place: Place, in overview: RCVOverview) -> Int {
        switch place {
        case .flow: overview.events.count
        case .unrouted: overview.unrouted
        case .sources: overview.sources.count
        case .rules: overview.rules.count
        }
    }

    public static func relayLine(connected: Bool) -> String {
        connected ? "Connected to the relay." : "Not connected to the relay. Deliveries wait there and arrive when it is back."
    }

    // MARK: - Status words

    /// How a status reads: calm grey, good, waiting, needs a look, or bad.
    public enum Tone: String, Sendable { case calm, good, waiting, attention, bad }

    /// The status filter's order.
    public static let statuses: [RCVStatus] = [.delivered, .held, .unrouted, .failed, .duplicate, .ignored, .rejected]

    public static func word(_ status: RCVStatus) -> String {
        switch status {
        case .delivered: "Delivered"
        case .held: "Waiting"
        case .unrouted: "Unrouted"
        case .failed: "Failed"
        case .duplicate: "Repeat"
        case .ignored: "Ignored"
        case .rejected: "Rejected"
        }
    }

    public static func symbol(_ status: RCVStatus) -> String {
        switch status {
        case .delivered: "checkmark.circle"
        case .held: "clock"
        case .unrouted: "tray"
        case .failed: "exclamationmark.circle"
        case .duplicate: "square.on.square"
        case .ignored: "eye.slash"
        case .rejected: "xmark.shield"
        }
    }

    public static func tone(_ status: RCVStatus) -> Tone {
        switch status {
        case .delivered: .good
        case .held: .waiting
        case .unrouted: .attention
        case .failed, .rejected: .bad
        case .duplicate, .ignored: .calm
        }
    }

    /// One sentence on what a status means, for the filter and the detail.
    public static func meaning(_ status: RCVStatus) -> String {
        switch status {
        case .delivered: "Handed to where its rule sends it."
        case .held: "Waiting for quiet hours or a rate limit to pass."
        case .unrouted: "No rule matched it yet."
        case .failed: "It could not be handed over. You can retry it."
        case .duplicate: "Already received once, so it was not sent again."
        case .ignored: "The source’s ignore list matched, so it was not sent anywhere."
        case .rejected: "It failed its signature or secret check. Nothing it sent was kept."
        }
    }

    // MARK: - Time

    static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func format(_ date: Date, _ template: String, timeZone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// A time of day, "14:05" (or "2:05 PM" where the locale says so).
    public static func clock(_ ms: Double, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        format(Date(timeIntervalSince1970: ms / 1000), "jmm", timeZone: timeZone, locale: locale)
    }

    /// A time of day with seconds, for the trail.
    public static func clockSeconds(_ ms: Double, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        format(Date(timeIntervalSince1970: ms / 1000), "jmmss", timeZone: timeZone, locale: locale)
    }

    /// An hour of the day for the quiet-hours pickers, "22:00".
    public static func hour(_ hour: Int, locale: Locale = .current) -> String {
        format(Date(timeIntervalSince1970: Double(max(0, min(23, hour))) * 3_600), "jmm", timeZone: TimeZone(identifier: "UTC")!, locale: locale)
    }

    /// Plain relative words: "just now", "4 min ago", "2 hours ago", "yesterday 14:05", "Mon 09:12", "8 Oct".
    public static func relative(_ ms: Double, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        if seconds < 3_600 { return "\(max(1, Int(seconds / 60))) min ago" }
        let calendar = gregorian(timeZone)
        if seconds < 6 * 3_600 || calendar.isDate(date, inSameDayAs: now) {
            let hours = max(1, Int(seconds / 3_600))
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday " + clock(ms, timeZone: timeZone, locale: locale)
        }
        if seconds < 6 * 86_400 {
            return format(date, "EEE", timeZone: timeZone, locale: locale) + " " + clock(ms, timeZone: timeZone, locale: locale)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return format(date, sameYear ? "dMMM" : "dMMMy", timeZone: timeZone, locale: locale)
    }

    /// When a held event goes out: "until 08:00", or "until Mon 08:00" past today.
    static func until(_ ms: Double, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let calendar = gregorian(timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return "until " + clock(ms, timeZone: timeZone, locale: locale) }
        return "until " + format(date, "EEE", timeZone: timeZone, locale: locale) + " " + clock(ms, timeZone: timeZone, locale: locale)
    }

    // MARK: - Names

    public static func source(_ id: String, in sources: [RCVSourceView]) -> RCVSourceView? { sources.first { $0.id == id } }

    public static func sourceName(_ id: String, in sources: [RCVSourceView]) -> String {
        if let view = source(id, in: sources) { return view.source.name }
        if let builtIn = RCVPresets.internalSources.first(where: { $0.id == id }) { return builtIn.name }
        return "A removed source"
    }

    /// The source's preset symbol (monoline SF Symbol).
    public static func sourceSymbol(_ source: RCVSource?, presets: [RCVPreset]) -> String {
        if let source, let preset = presets.first(where: { $0.id == source.preset }) ?? RCVPresets.named(source.preset) { return preset.symbol }
        if let source, RCVPresets.isInternal(source.id) { return RCVPresets.terminalDeck.symbol }
        return RCVPresets.generic.symbol
    }

    public static func sourceSymbol(id: String, sources: [RCVSourceView], presets: [RCVPreset]) -> String {
        if let view = source(id, in: sources) { return sourceSymbol(view.source, presets: presets) }
        return RCVPresets.isInternal(id) ? RCVPresets.terminalDeck.symbol : RCVPresets.generic.symbol
    }

    /// Who a target is, by name only: "Hoot", "Ada", "Not chosen yet".
    public static func targetName(_ target: RCVTarget, agents: [RCVChoice], sessions: [RCVChoice]) -> String {
        switch target.kind {
        case .hoot: return "Hoot"
        case .agent, .newTask:
            if target.id.isEmpty { return "Not chosen yet" }
            return agents.first { $0.id == target.id }?.name ?? target.id
        case .session:
            if target.id.isEmpty { return "Not chosen yet" }
            return sessions.first { $0.id == target.id }?.name ?? target.id
        }
    }

    /// Who a target is and how: "Ada (one ongoing task)", "New task for Ada", "Ada (running session)", "Hoot".
    public static func targetWords(_ target: RCVTarget, agents: [RCVChoice], sessions: [RCVChoice]) -> String {
        let name = targetName(target, agents: agents, sessions: sessions)
        switch target.kind {
        case .hoot: return "Hoot"
        case .agent: return "\(name) (one ongoing task)"
        case .newTask: return "New task for \(name)"
        case .session: return "\(name) (running session)"
        }
    }

    public static func ruleName(_ id: String?, in rules: [RCVRule]) -> String? {
        guard let id else { return nil }
        return rules.first { $0.id == id }?.name ?? "A deleted rule"
    }

    // MARK: - Flow

    public struct Row: Equatable, Identifiable, Sendable {
        public var id: String
        public var at: Double
        public var sourceID: String
        public var sourceName: String
        public var sourceSymbol: String
        public var kind: String
        public var title: String
        /// "→ rule → target", or nil while nothing took it.
        public var route: String?
        public var status: RCVStatus
        public var statusWord: String
        public var statusSymbol: String
        public var tone: Tone
        public var severity: RCVSeverity
    }

    /// The words after an event's source: "→ rule → target", "→ By hand → Hoot", or nil.
    public static func route(_ event: RCVEvent, rules: [RCVRule], agents: [RCVChoice], sessions: [RCVChoice]) -> String? {
        let rule = ruleName(event.ruleId, in: rules)
        let target = event.target.map { targetName($0, agents: agents, sessions: sessions) }
        switch (rule, target) {
        case (let rule?, let target?): return "→ \(rule) → \(target)"
        case (let rule?, nil): return "→ \(rule)"
        case (nil, let target?): return "→ By hand → \(target)"
        default: return nil
        }
    }

    public static func row(_ event: RCVEvent, overview: RCVOverview) -> Row {
        Row(id: event.id, at: event.receivedAt, sourceID: event.sourceId,
            sourceName: sourceName(event.sourceId, in: overview.sources),
            sourceSymbol: sourceSymbol(id: event.sourceId, sources: overview.sources, presets: overview.presets),
            kind: event.kind, title: title(event),
            route: route(event, rules: overview.rules, agents: overview.agents, sessions: overview.sessions),
            status: event.status, statusWord: word(event.status), statusSymbol: symbol(event.status), tone: tone(event.status),
            severity: event.severity)
    }

    public static func rows(_ events: [RCVEvent], overview: RCVOverview) -> [Row] { events.map { row($0, overview: overview) } }

    /// An event's headline; never blank.
    public static func title(_ event: RCVEvent) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return String(title.prefix(200)) }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return String(text.prefix(120)) }
        return event.status == .rejected ? "Refused delivery" : event.kind
    }

    /// The events a search and the two filters leave, newest first. The search reads
    /// the title, text, type, source name and field values, ignoring case.
    public static func filter(_ events: [RCVEvent], query: String, sourceID: String?, status: RCVStatus?, sources: [RCVSourceView]) -> [RCVEvent] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return events.filter { event in
            if let sourceID, event.sourceId != sourceID { return false }
            if let status, event.status != status { return false }
            guard !words.isEmpty else { return true }
            let haystack = ([event.title, event.text, event.kind, sourceName(event.sourceId, in: sources), event.upstreamId ?? ""]
                            + event.fields.values).joined(separator: "\n").lowercased()
            return words.allSatisfy(haystack.contains)
        }
        .sorted { $0.receivedAt > $1.receivedAt }
    }

    // MARK: - One event

    public struct Step: Equatable, Identifiable, Sendable {
        public enum Kind: String, Sendable { case cameFrom, rule, wentTo, result }
        public var kind: Kind
        public var id: String { kind.rawValue }
        /// "Came from", "Rule", "Went to", "Result".
        public var label: String
        public var value: String
        public var detail: String?
        public var symbol: String
        /// Whether the event got this far.
        public var reached: Bool
        public var tone: Tone
    }

    /// The four steps: Came from → Rule → Went to → Result.
    public static func chain(_ event: RCVEvent, overview: RCVOverview, now: Date = Date(), timeZone: TimeZone = .current,
                             locale: Locale = .current) -> [Step] {
        let source = sourceName(event.sourceId, in: overview.sources)
        let cameFrom = Step(kind: .cameFrom, label: "Came from", value: source,
                            detail: "\(event.kind) · \(event.severity.rawValue)",
                            symbol: sourceSymbol(id: event.sourceId, sources: overview.sources, presets: overview.presets),
                            reached: true, tone: .calm)

        let rule: Step
        switch event.status {
        case .rejected:
            rule = Step(kind: .rule, label: "Rule", value: "Not checked", detail: "It failed its signature or secret check.",
                        symbol: "arrow.triangle.branch", reached: false, tone: .bad)
        case .ignored:
            rule = Step(kind: .rule, label: "Rule", value: "Ignore list", detail: "The source ignores messages like this.",
                        symbol: "arrow.triangle.branch", reached: true, tone: .calm)
        default:
            if let name = ruleName(event.ruleId, in: overview.rules) {
                rule = Step(kind: .rule, label: "Rule", value: name, detail: nil, symbol: "arrow.triangle.branch", reached: true, tone: .calm)
            } else if event.target != nil {
                rule = Step(kind: .rule, label: "Rule", value: "By hand", detail: "Sent on from this page.",
                            symbol: "hand.point.up.left", reached: true, tone: .calm)
            } else if event.status == .duplicate {
                rule = Step(kind: .rule, label: "Rule", value: "Repeat", detail: "The sender already delivered this one.",
                            symbol: "arrow.triangle.branch", reached: true, tone: .calm)
            } else {
                rule = Step(kind: .rule, label: "Rule", value: "No rule matched", detail: "Add a rule, or send it on by hand.",
                            symbol: "arrow.triangle.branch", reached: false, tone: .attention)
            }
        }

        let wentTo: Step
        if let target = event.target {
            wentTo = Step(kind: .wentTo, label: "Went to", value: targetName(target, agents: overview.agents, sessions: overview.sessions),
                          detail: targetKindWords(target.kind), symbol: targetSymbol(target.kind),
                          reached: event.status == .delivered || event.status == .failed || event.status == .held, tone: .calm)
        } else {
            let value: String
            switch event.status {
            case .unrouted: value = "Nowhere yet"
            default: value = "Not sent"
            }
            wentTo = Step(kind: .wentTo, label: "Went to", value: value, detail: nil, symbol: "arrow.right.circle", reached: false, tone: .calm)
        }

        var value = word(event.status)
        if event.status == .held, let resume = event.resumeAt { value += " " + until(resume, now: now, timeZone: timeZone, locale: locale) }
        let result = Step(kind: .result, label: "Result", value: value, detail: resultDetail(event),
                          symbol: symbol(event.status), reached: true, tone: tone(event.status))
        return [cameFrom, rule, wentTo, result]
    }

    static func targetKindWords(_ kind: RCVTargetKind) -> String {
        switch kind {
        case .agent: "One ongoing task"
        case .newTask: "A new task"
        case .session: "Typed into a running session"
        case .hoot: "A task for Hoot"
        }
    }

    public static func targetSymbol(_ kind: RCVTargetKind) -> String {
        switch kind {
        case .agent: "person.crop.circle"
        case .newTask: "checklist"
        case .session: "terminal"
        case .hoot: "bird"
        }
    }

    /// What came of it: the outcome, the task, and how many replies went back.
    public static func resultDetail(_ event: RCVEvent) -> String? {
        var parts: [String] = []
        if let outcome = event.outcome?.trimmingCharacters(in: .whitespacesAndNewlines), !outcome.isEmpty { parts.append(outcome) }
        if let task = event.taskId, !task.isEmpty { parts.append("Task \(task)") }
        if let session = event.sessionId, !session.isEmpty, event.taskId == nil { parts.append("Session \(session)") }
        if !event.replies.isEmpty { parts.append(event.replies.count == 1 ? "1 reply" : "\(event.replies.count) replies") }
        if parts.isEmpty { return meaning(event.status) }
        return parts.joined(separator: " · ")
    }

    public struct ReplyLine: Equatable, Identifiable, Sendable {
        public var id: String
        public var headline: String
        public var text: String
        public var detail: String?
        public var symbol: String
        public var tone: Tone
    }

    public static func replyLines(_ event: RCVEvent, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> [ReplyLine] {
        event.replies.sorted { $0.at < $1.at }.map { reply in
            let state: String, symbol: String, tone: Tone
            switch reply.state {
            case .sent: state = "Sent"; symbol = "arrowshape.turn.up.left"; tone = .good
            case .failed: state = "Did not send"; symbol = "exclamationmark.circle"; tone = .bad
            case .refused: state = "Refused"; symbol = "hand.raised"; tone = .attention
            }
            var headline = "\(state) · \(relative(reply.at, now: now, timeZone: timeZone, locale: locale))"
            if !reply.by.isEmpty { headline += " · by \(reply.by)" }
            if reply.autoApproved { headline += " · without asking" }
            return ReplyLine(id: reply.id, headline: headline, text: reply.text, detail: reply.detail, symbol: symbol, tone: tone)
        }
    }

    public struct TrailLine: Equatable, Identifiable, Sendable {
        public var id: Int
        public var time: String
        public var words: String
    }

    public static func trail(_ event: RCVEvent, timeZone: TimeZone = .current, locale: Locale = .current) -> [TrailLine] {
        event.trail.enumerated().map { index, step in
            TrailLine(id: index, time: clockSeconds(step.at, timeZone: timeZone, locale: locale), words: step.words)
        }
    }

    public struct Pair: Equatable, Identifiable, Sendable {
        public var name: String
        public var value: String
        public var id: String { name }
        public init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }

    public static func fields(_ event: RCVEvent) -> [Pair] {
        event.fields.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { Pair($0.key, $0.value) }
    }

    public static func headers(_ event: RCVEvent) -> [Pair] {
        event.headers.sorted { $0.key < $1.key }.map { Pair($0.key, $0.value) }
    }

    /// The raw payload, pretty and stable, for the collapsed monospace view.
    public static func prettyRaw(_ raw: Data, limit: Int = 40_000) -> String {
        var text: String
        if let object = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = String(decoding: raw, as: UTF8.self)
        }
        if text.count > limit { text = String(text.prefix(limit)) + "\n…" }
        return text
    }

    /// Which buttons an event offers.
    public struct Actions: Equatable, Sendable {
        public var retry: Bool
        public var replay: Bool
        public var route: Bool
        public var reply: Bool
        public var suggest: Bool
        public var askHoot: Bool
        public init(retry: Bool, replay: Bool, route: Bool, reply: Bool, suggest: Bool, askHoot: Bool) {
            self.retry = retry; self.replay = replay; self.route = route; self.reply = reply; self.suggest = suggest; self.askHoot = askHoot
        }
    }

    public static func actions(_ event: RCVEvent, source: RCVSource?) -> Actions {
        let kept = event.status != .rejected
        return Actions(retry: event.status == .failed || event.status == .held,
                       replay: kept,
                       route: kept,
                       reply: kept && source?.reply != nil,
                       suggest: event.status == .unrouted,
                       askHoot: event.status == .unrouted)
    }

    // MARK: - Sources

    public struct State: Equatable, Sendable {
        public var word: String
        public var symbol: String
        public var tone: Tone
    }

    /// Active / Waiting for relay / Paused.
    public static func state(_ view: RCVSourceView) -> State {
        if !view.source.enabled { return State(word: "Paused", symbol: "pause.circle", tone: .calm) }
        if view.source.origin == .terminalDeck || view.active { return State(word: "Active", symbol: "checkmark.circle", tone: .good) }
        return State(word: "Waiting for relay", symbol: "clock", tone: .waiting)
    }

    /// "No events yet", or "12 events · last 4 min ago · 1 rejected".
    public static func summary(_ view: RCVSourceView, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var parts: [String] = []
        if view.eventCount == 0 { parts.append("No events yet") }
        else { parts.append(view.eventCount == 1 ? "1 event" : "\(view.eventCount) events") }
        if let last = view.lastEventAt, view.eventCount > 0 { parts.append("last " + relative(last, now: now, timeZone: timeZone, locale: locale)) }
        if view.rejectedCount > 0 { parts.append("\(view.rejectedCount) rejected") }
        return parts.joined(separator: " · ")
    }

    /// The owner's own sources first (by name), Terminal Deck's built-in ones last.
    public static func sorted(_ sources: [RCVSourceView]) -> [RCVSourceView] {
        sources.sorted { a, b in
            let ai = RCVPresets.isInternal(a.id), bi = RCVPresets.isInternal(b.id)
            if ai != bi { return !ai }
            return a.source.name.localizedStandardCompare(b.source.name) == .orderedAscending
        }
    }

    public static func hasOwnSources(_ sources: [RCVSourceView]) -> Bool { sources.contains { !RCVPresets.isInternal($0.id) } }

    public static func canDelete(_ source: RCVSource) -> Bool { !RCVPresets.isInternal(source.id) && source.origin != .terminalDeck }

    public static func deleteQuestion(_ source: RCVSource) -> String { "Delete the source “\(source.name)”?" }

    public static func deleteWarning(_ source: RCVSource) -> String {
        "Its address stops working at once and anything sent to it is refused. Rules that only listen to it stop matching. This cannot be undone."
    }

    public static let rotateQuestion = "Replace the secret?"
    public static let rotateWarning = "The old secret stops working at once. Paste the new one into the sender, or its deliveries are rejected."

    /// The presets a person can make a source from (Terminal Deck's own are built in).
    public static func creatable(_ presets: [RCVPreset]) -> [RCVPreset] { presets.filter { $0.origin == .relay } }

    /// A preset lets its owner pick how senders prove themselves, unless the vendor fixes a signature.
    public static func authChoosable(_ preset: RCVPreset) -> Bool { preset.origin == .relay && preset.auth.scheme != .hmac }

    /// The auth a scheme starts with, keeping the allow-list and the preset's own details.
    public static func auth(_ scheme: RCVAuthScheme, from current: RCVAuth, preset: RCVPreset?) -> RCVAuth {
        var next = RCVAuth(scheme: scheme, ipAllow: current.ipAllow)
        switch scheme {
        case .hmac: next.hmac = current.hmac ?? preset?.auth.hmac ?? RCVHMAC(header: "x-signature-256", prefix: "sha256=")
        case .token: next.tokenHeader = current.tokenHeader ?? preset?.auth.tokenHeader
        case .basic: next.basicUser = current.basicUser ?? preset?.auth.basicUser ?? "receiver"
        case .none: break
        }
        return next
    }

    /// How a scheme is explained under the picker.
    public static func authHelp(_ scheme: RCVAuthScheme) -> String {
        switch scheme {
        case .hmac: "The sender signs each delivery with the secret. Best when the service supports it."
        case .token: "The sender sends the secret with each delivery, or uses the address with the secret built in."
        case .basic: "The sender signs in with a user name and the secret as the password."
        case .none: "Anyone who knows the address can send. Use only with an allow-list."
        }
    }

    /// Allowed addresses typed one per line or separated by commas.
    public static func addresses(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    public static func addressesText(_ list: [String]) -> String { list.joined(separator: "\n") }

    /// What the source page says about the address.
    public static func addressLine(_ view: RCVSourceView) -> String {
        if view.source.origin == .terminalDeck { return "Built in. Terminal Deck sends its own events here, so there is no address." }
        if view.address == nil { return "The address appears once the relay confirms it." }
        return "Paste this address into the service that sends to it."
    }

    /// The reveal sheet's help: the preset's own sentence on where to paste it.
    public static func revealHelp(_ view: RCVSourceView?, presets: [RCVPreset]) -> String {
        guard let view, let preset = presets.first(where: { $0.id == view.source.preset }) ?? RCVPresets.named(view.source.preset) else {
            return "Paste the address and the secret into the service that sends to this source."
        }
        return preset.help
    }

    /// Senders that give you their secret (Sentry's Client Secret) instead of taking ours.
    public static func offersOwnSecret(_ source: RCVSource) -> Bool {
        source.origin == .relay && !RCVPresets.isInternal(source.id) && source.auth.scheme != .none
    }

    /// Right after adding it, ask for the sender's secret instead of showing ours.
    public static func ownSecretFirst(_ source: RCVSource) -> Bool { offersOwnSecret(source) && source.preset == RCVPresets.sentry.id }

    public static let ownSecretTitle = "Use the sender’s own secret"
    public static let ownSecretHelp = "For senders like Sentry that give you their secret. Paste it here instead of copying ours."
    public static let ownSecretSaved = "Saved. Deliveries are now checked with the sender’s secret."

    public static let revealWarning = "This is the only time the secret is shown here. Copy it now. You can replace it later if it is lost."

    /// The mapping run over a recent event, for the live preview. A source that
    /// splits one delivery into many keeps each item as its event's payload, so the
    /// item is put back under the split path first.
    public static func preview(_ source: RCVSource, sample event: RCVEvent) -> [RCVEvent] {
        var body = event.raw
        if let split = source.mapping.split?.trimmingCharacters(in: .whitespaces), !split.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
            let path = split.hasPrefix("$.") ? String(split.dropFirst(2)) : split
            if !(RCVEngine.walk(object, path) is [Any]) {
                let keys = path.split(separator: ".").map(String.init)
                if !keys.isEmpty, keys.allSatisfy({ !$0.contains("[") && !$0.isEmpty }) {
                    var wrapped: Any = [object]
                    for key in keys.reversed() { wrapped = [key: wrapped] }
                    if let data = try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys]) { body = data }
                }
            }
        }
        var headers = event.headers
        if headers["content-type"] == nil { headers["content-type"] = "application/json" }
        return RCVEngine.normalize(body: body, headers: headers, meta: ["source": source.id, "receivedAt": String(Int64(event.receivedAt))],
                                   source: source, receivedAt: event.receivedAt)
    }

    // MARK: - Rules

    public static func conditionWords(_ condition: RCVCondition) -> String {
        switch condition.operation {
        case .exists, .missing: "\(condition.path) \(condition.operation.title)"
        default: "\(condition.path) \(condition.operation.title) \(condition.value)"
        }
    }

    /// Whether an operation takes a value.
    public static func needsValue(_ operation: RCVCondition.Operation) -> Bool { operation != .exists && operation != .missing }

    /// "Any source · when kind is issues and fields.action is opened → New task for Ada".
    public static func summary(_ rule: RCVRule, overview: RCVOverview) -> String {
        let from: String
        if rule.sourceIds.isEmpty { from = "Any source" }
        else { from = "From " + rule.sourceIds.map { sourceName($0, in: overview.sources) }.joined(separator: ", ") }
        let when = rule.conditions.isEmpty ? "everything" : "when " + rule.conditions.map(conditionWords).joined(separator: " and ")
        return "\(from) · \(when) → \(targetWords(rule.target, agents: overview.agents, sessions: overview.sessions))"
    }

    /// The extra lines under a rule: its limits, in plain words.
    public static func limits(_ rule: RCVRule, locale: Locale = .current) -> String? {
        var parts: [String] = []
        if let quiet = rule.quietHours { parts.append("Quiet \(hour(quiet.startHour, locale: locale))–\(hour(quiet.endHour, locale: locale))") }
        if rule.dedupeMinutes > 0 { parts.append("Repeats within \(rule.dedupeMinutes) min skipped") }
        if rule.perMinute != 10 { parts.append("At most \(rule.perMinute) a minute") }
        if rule.autoApproveReplies { parts.append("Replies go out without asking") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A blank rule for "New rule".
    public static func newRule(sourceIDs: [String] = []) -> RCVRule {
        RCVRule(name: "", sourceIds: sourceIDs, target: .init(kind: .hoot, id: "hoot"))
    }

    /// The index a rule moves to, or nil at the end of the list.
    public static func moveIndex(_ id: String, up: Bool, in rules: [RCVRule]) -> Int? {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return nil }
        let next = up ? index - 1 : index + 1
        return rules.indices.contains(next) ? next : nil
    }

    /// What a condition's path can be: the envelope, the sources' fields, and what
    /// recent events actually carried (fields, headers, payload keys).
    public static func paths(sources: [RCVSource], events: [RCVEvent], limit: Int = 80) -> [String] {
        var out = ["kind", "severity", "title", "text", "source"]
        for source in sources { out += source.mapping.fields.map { "fields." + $0.name } }
        for event in events.prefix(20) {
            out += event.fields.keys.sorted().map { "fields." + $0 }
            if let object = try? JSONSerialization.jsonObject(with: event.raw, options: [.fragmentsAllowed]) as? [String: Any] {
                out += rawPaths(object, prefix: "raw", depth: 0)
            }
            out += event.headers.keys.sorted().map { "header." + $0 }
        }
        var seen = Set<String>()
        return Array(out.filter { seen.insert($0).inserted }.prefix(limit))
    }

    static func rawPaths(_ object: [String: Any], prefix: String, depth: Int) -> [String] {
        var out: [String] = []
        for key in object.keys.sorted() where key.range(of: #"^[A-Za-z0-9_\-]{1,64}$"#, options: .regularExpression) != nil {
            let path = prefix + "." + key
            if let nested = object[key] as? [String: Any] {
                if depth < 1 { out += rawPaths(nested, prefix: path, depth: depth + 1) }
            } else if !(object[key] is [Any]) {
                out.append(path)
            }
        }
        return out
    }

    /// The placeholders an instruction can use, as typed: "{{title}}".
    public static func placeholders(sources: [RCVSource], events: [RCVEvent]) -> [String] {
        (["id"] + paths(sources: sources, events: events, limit: 60)).map { "{{\($0)}}" }
    }

    public struct StartingPoint: Identifiable, Sendable {
        public var id: String
        public var title: String
        public var detail: String
        public var rule: RCVRule
    }

    /// The presets' example rules as one-click starting points: for the owner's sources
    /// when there are some of that preset, else for any source.
    public static func startingPoints(sources: [RCVSourceView], presets: [RCVPreset]) -> [StartingPoint] {
        var out: [StartingPoint] = []
        let all = presets.isEmpty ? RCVPresets.all : presets
        for preset in all {
            let mine = sorted(sources).filter { $0.source.preset == preset.id }
            for example in preset.examples {
                var rule = example
                rule.sourceIds = mine.map(\.id)
                let detail = mine.isEmpty ? "For any \(preset.name) source" : "For " + mine.map(\.source.name).joined(separator: ", ")
                out.append(StartingPoint(id: preset.id + "/" + example.id, title: example.name, detail: detail, rule: rule))
            }
        }
        // The owner's own presets first; then the ones whose sources exist.
        return out.sorted { !$0.rule.sourceIds.isEmpty && $1.rule.sourceIds.isEmpty }
    }

    /// A starting point or suggestion turned into a fresh rule to edit.
    public static func fresh(_ rule: RCVRule) -> RCVRule {
        var copy = rule
        copy.id = UUID().uuidString.lowercased()
        copy.autoApproveReplies = false
        return copy
    }

    public static let autoApproveWarning = "Replies to events this rule sends on go out at once, without asking you first. Turn this on only for senders you trust."

    public static func validation(_ rule: RCVRule) -> String? {
        do { try RCVEngine.validate(rule); return nil } catch { return sentence(error) }
    }

    public struct DecisionWords: Equatable, Sendable {
        public var headline: String
        public var reason: String
        public var tone: Tone
        public var instruction: String?
    }

    /// The tester's answer: "Would go to Ada", and the reason in the router's words.
    public static func decisionWords(_ decision: RCVDecision, overview: RCVOverview, now: Date = Date(), timeZone: TimeZone = .current,
                                     locale: Locale = .current) -> DecisionWords {
        let target = decision.target.map { targetWords($0, agents: overview.agents, sessions: overview.sessions) }
        let headline: String
        switch decision.status {
        case .delivered: headline = "Would go to " + (target ?? "its target")
        case .held:
            let when = decision.resumeAt.map { " " + until($0, now: now, timeZone: timeZone, locale: locale) } ?? ""
            headline = "Would wait\(when), then go to " + (target ?? "its target")
        case .unrouted: headline = "Would wait in Unrouted"
        case .duplicate: headline = "Would be skipped as a repeat"
        case .failed: headline = "Would fail"
        case .ignored: headline = "Would be ignored"
        case .rejected: headline = "Would be rejected"
        }
        return DecisionWords(headline: headline, reason: decision.reason, tone: tone(decision.status), instruction: decision.instruction)
    }

    // MARK: - Empty states

    public struct Empty: Equatable, Sendable {
        public var symbol: String
        public var title: String
        public var message: String
        /// The one button, if any: "Add a source", "Show everything".
        public var action: String?
    }

    public static func emptyFlow(hasOwnSources: Bool, narrowed: Bool) -> Empty {
        if narrowed {
            return Empty(symbol: "magnifyingglass", title: "Nothing matches", message: "Try other words, or show everything.", action: "Show everything")
        }
        if !hasOwnSources {
            return Empty(symbol: "tray.and.arrow.down", title: "Nothing received yet",
                         message: "Add a source to start receiving. Each source gets its own address to paste into the service that sends to it.",
                         action: "Add a source")
        }
        return Empty(symbol: "tray.and.arrow.down", title: "Nothing received yet",
                     message: "When a source sends something, it shows up here: where it came from, which rule took it, and where it went.",
                     action: nil)
    }

    public static let emptyUnrouted = Empty(symbol: "tray", title: "Nothing unrouted",
                                            message: "Everything that arrived matched a rule. Anything no rule takes waits here.", action: nil)

    public static let emptySources = Empty(symbol: "antenna.radiowaves.left.and.right", title: "No sources yet",
                                           message: "Add a source to start receiving: a server, Sentry, WhatsApp, a CRM, GitHub, or any service that can send a webhook.",
                                           action: "Add a source")

    public static let emptyRules = Empty(symbol: "arrow.triangle.branch", title: "No rules yet",
                                         message: "Rules decide where incoming things go. Start from one of these, or make your own.",
                                         action: "New rule")

    public static let noSelection = Empty(symbol: "arrow.left", title: "Choose an event",
                                          message: "See where it came from, which rule took it, where it went and what came back.", action: nil)

    public static let rulesExplainer = "Rules are checked from the top. The first one that matches decides where an event goes."
}
