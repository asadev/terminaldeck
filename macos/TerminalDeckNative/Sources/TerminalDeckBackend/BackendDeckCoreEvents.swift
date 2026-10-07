import Foundation
import TerminalDeckNativeCore

public struct BackendDeckCoreEventsError: Error, LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public let data: NativeRPCValue
    public init(code: Int, message: String, data: NativeRPCValue = .missing) { self.code = code; self.message = message; self.data = data }
    public var errorDescription: String? { message }
    public var wire: NativeRPCValue { BackendDeckCoreEventsSupport.object([("code", .number(Double(code))),("message", .string(message)),("data", data)]) }
}

/// MCP Events subscriptions and the source-compatible mcp-events.json outbox.
public actor BackendDeckCoreEvents {
    public static let fileName = "mcp-events.json"
    public static let subscriptionHeader = "X-MCP-Subscription-Id"
    public static let maximumSubscriptionsPerKey = 10
    public static let minimumTTL: Double = 60_000
    public static let maximumTTL: Double = 86_400_000
    public static let rotationGrace: Double = 300_000
    public static let maximumBodyBytes = 262_144
    public static let eventNames = ["finished": "session.turn_finished", "needs-input": "session.needs_input", "exited": "session.exited"]
    public typealias AccessMode = @Sendable (String) async -> String?
    private struct Secret: Sendable {
        let value: String
        let until: Double?
        var wire: NativeRPCValue { BackendDeckCoreEventsSupport.object([("value",.string(value)),("until",BackendDeckCoreEventsSupport.number(until))]) }
    }
    private struct Subscription: Sendable {
        let id: String, keyID: String, name: String, sessionID: String?, url: String
        var via: String
        var secrets: [Secret]
        let createdAt: Double
        var refreshBefore: Double
        var lastDelivery: NativeRPCValue = .null
        var seen: [String] = []
        var wire: NativeRPCValue { BackendDeckCoreEventsSupport.object([("id",.string(id)),("keyId",.string(keyID)),("via",.string(via)),("name",.string(name)),("sessionId",BackendDeckCoreEventsSupport.nullable(sessionID)),("url",.string(url)),("secrets",.array(secrets.map(\.wire))),("createdAt",.number(createdAt)),("refreshBefore",.number(refreshBefore)),("lastDelivery",lastDelivery),("seen",.array(seen.map(NativeRPCValue.string)))]) }
        var view: NativeRPCValue {
            let address = URL(string: url)
            let host = address.map { ($0.host ?? "") + ($0.port.map { ":\($0)" } ?? "") } ?? url
            return BackendDeckCoreEventsSupport.object([("id",.string(id)),("keyId",.string(keyID)),("event",.string(name)),("host",.string(host)),("sessionId",BackendDeckCoreEventsSupport.nullable(sessionID)),("refreshBefore",.number(refreshBefore)),("lastDelivery",lastDelivery)])
        }
    }
    private struct Outgoing: Sendable {
        let token: UUID
        let subscriptionID: String, eventID: String, body: String
        var attempts: Int
        var nextAt: Double?
        var wire: NativeRPCValue { BackendDeckCoreEventsSupport.object([("subscriptionId",.string(subscriptionID)),("eventId",.string(eventID)),("body",.string(body)),("attempts",.number(Double(attempts))),("nextAt",BackendDeckCoreEventsSupport.number(nextAt))]) }
    }
    private let directory: URL?
    private let mode: AccessMode
    private let internet: @Sendable () async -> Bool
    private let clock: any BackendDeckCoreEventsClock
    private let post: BackendDeckCoreEventsCallbackPost
    private let onDelivered: @Sendable (String, String) async -> Void
    private let owesEvent: @Sendable (String, String) async -> Bool
    private let onChange: @Sendable () -> Void
    private let report: @Sendable (String) -> Void
    private var subscriptionsByID: [String: Subscription] = [:]
    private var subscriptionOrder: [String] = []
    private var outbox: [Outgoing] = []
    private var posting: Set<UUID> = []
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var verifying: [String: Task<Void, Error>] = [:]
    private var timer: UUID?
    private var timerAt: Double?
    private var saveQueued = false
    private var stopped = false
    /// Timer hops onto this actor, recorded as they start, for awaitIdle().
    private let fires = BackendDeckCoreEventsWork()

    public init(directory: URL? = nil, mode: @escaping AccessMode, internet: @escaping @Sendable () async -> Bool,
                clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock(),
                post: @escaping BackendDeckCoreEventsCallbackPost = BackendDeckCoreEventsCallback.post,
                onDelivered: @escaping @Sendable (String, String) async -> Void = { _, _ in },
                owed: @escaping @Sendable (String, String) async -> Bool = { _, _ in true },
                onChange: @escaping @Sendable () -> Void = {}, report: @escaping @Sendable (String) -> Void = { _ in }) {
        self.directory = directory; self.mode = mode; self.internet = internet; self.clock = clock; self.post = post
        self.onDelivered = onDelivered; self.owesEvent = owed; self.onChange = onChange; self.report = report
    }
    public func load() {
        guard let raw = try? BackendDeckCoreEventsSupport.read(file), raw["v"].number == 1, let values = raw["subscriptions"].elements else { return }
        subscriptionsByID = [:]; subscriptionOrder = []
        for raw in values {
            guard let id = raw["id"].string, let key = raw["keyId"].string, let via = raw["via"].string, ["this-mac","internet"].contains(via),
                  let name = raw["name"].string, Self.eventNames.values.contains(name), raw["sessionId"] == .null || raw["sessionId"].string != nil,
                  let url = raw["url"].string, let secrets = raw["secrets"].elements, secrets.allSatisfy({ $0["value"].string != nil }),
                  let created = raw["createdAt"].number, let before = raw["refreshBefore"].number, let seen = raw["seen"].elements else { continue }
            let sub = Subscription(id: id, keyID: key, name: name, sessionID: raw["sessionId"].string, url: url, via: via,
                secrets: secrets.map { Secret(value: $0["value"].string!, until: $0["until"].number) }, createdAt: created, refreshBefore: before,
                lastDelivery: raw["lastDelivery"].isNullish ? .null : raw["lastDelivery"], seen: seen.compactMap(\.string))
            if subscriptionsByID[id] == nil { subscriptionOrder.append(id) }; subscriptionsByID[id] = sub
        }
        outbox = (raw["outbox"].elements ?? []).compactMap { raw in
            guard let sub = raw["subscriptionId"].string, subscriptionsByID[sub] != nil, let event = raw["eventId"].string,
                  let body = raw["body"].string, let attempts = raw["attempts"].number, attempts >= 0, attempts < Double(Int.max),
                  raw["nextAt"] == .null || raw["nextAt"].number != nil else { return nil }
            return Outgoing(token: UUID(), subscriptionID: sub, eventID: event, body: body, attempts: Int(attempts), nextAt: raw["nextAt"].number ?? clock.now())
        }
        expire(); arm()
    }
    public func list() -> NativeRPCValue { BackendDeckCoreEventsSupport.object([("events",.array(Self.catalogue()))]) }
    public static func secretProblem(_ value: NativeRPCValue) -> String? {
        guard let secret = value.string, secret.hasPrefix(BackendDeckCoreEventsWebhook.secretPrefix) else { return "The signing secret has to start with whsec_." }
        let encoded = String(secret.dropFirst(6))
        guard encoded.range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil, encoded.utf8.count % 4 == 0 else { return "The signing secret is not base64." }
        let count = Data(base64Encoded: encoded)?.count ?? 0
        return (24...64).contains(count) ? nil : "The signing secret has to be 24 to 64 bytes."
    }
    public static func subscriptionId(keyId: String, url: String, name: String, sessionId: String?) -> String {
        let canonical = NativeRPCValue.array([.string(keyId),.string(url),.string(name),sessionId.map { BackendDeckCoreEventsSupport.object([("sessionId",.string($0))]) } ?? .object([])]).compact
        return "sub_" + BackendDeckCoreEventsSupport.digest(canonical, length: 32)
    }
    public func subscribe(keyId: String, via: String, params: NativeRPCValue) async throws -> NativeRPCValue {
        guard !stopped else { throw error(-32012, "The app is shutting down.") }
        guard params.fields != nil else { throw error(-32602, "params has to be an object.") }
        let (name, sessionID) = try eventAndArguments(params)
        let delivery = params["delivery"]
        guard delivery.fields != nil else { throw error(-32602, "delivery is required.") }
        guard delivery["mode"].string == "webhook" else { throw error(-32014, "Only webhook delivery is offered.", BackendDeckCoreEventsSupport.object([("feature",.string("delivery")),("value",delivery["mode"].string.map { .string(BackendDeckCoreEventsSupport.utf16Slice($0, length: 40)) } ?? .null)])) }
        guard let url = delivery["url"].string else { throw error(-32602, "delivery.url is required.") }
        if let problem = BackendDeckCoreEventsCallback.urlProblem(url) { throw error(-32602, problem) }
        if let problem = Self.secretProblem(delivery["secret"]) { throw error(-32602, problem) }
        let secret = delivery["secret"].string!
        guard let mode = await mode(keyId) else { throw error(-32012, "This access key no longer exists.") }
        guard mode != "off" else { throw error(-32012, "The owner switched notifications off for this app. They can turn them back on in Settings, under Connect an AI app.") }
        let lease = params["ttlMs"].number.map { min(max($0, Self.minimumTTL), Self.maximumTTL) } ?? Self.maximumTTL
        let id = Self.subscriptionId(keyId: keyId, url: url, name: name, sessionId: sessionID), now = clock.now()
        if var sub = subscriptionsByID[id] {
            sub.refreshBefore = now + lease
            if sub.secrets.first?.value != secret { sub.secrets = [Secret(value: secret, until: nil)] + sub.secrets.prefix(1).map { Secret(value: $0.value, until: now + Self.rotationGrace) } }
            sub.via = via; subscriptionsByID[id] = sub; changed(); return answer(sub)
        }
        guard subscriptionsByID.values.filter({ $0.keyID == keyId }).count < Self.maximumSubscriptionsPerKey else { throw error(-32013, "This app already has 10 subscriptions. Unsubscribe from one first.", BackendDeckCoreEventsSupport.object([("limit",.string("subscriptions")),("max",.number(10))])) }
        let task: Task<Void, Error>
        if let existing = verifying[id] { task = existing }
        else { task = Task { try await self.verify(id: id, url: url, secret: secret) }; verifying[id] = task }
        do { try await task.value } catch { verifying[id] = nil; throw error }
        verifying[id] = nil
        guard !stopped else { throw error(-32012, "The app is shutting down.") }
        if let existing = subscriptionsByID[id] { return answer(existing) }
        let sub = Subscription(id: id, keyID: keyId, name: name, sessionID: sessionID, url: url, via: via, secrets: [Secret(value: secret, until: nil)], createdAt: now, refreshBefore: now + lease)
        subscriptionsByID[id] = sub; subscriptionOrder.append(id); changed(); return answer(sub)
    }
    public func unsubscribe(keyId: String, params: NativeRPCValue) throws -> NativeRPCValue {
        guard params.fields != nil else { throw error(-32602, "params has to be an object.") }
        let (name, sessionID) = try eventAndArguments(params)
        guard params["delivery"].fields != nil, let url = params["delivery"]["url"].string else { throw error(-32602, "delivery.url is required.") }
        remove(Self.subscriptionId(keyId: keyId, url: url, name: name, sessionId: sessionID)); return .object([])
    }
    public func dispatch(method: String, keyId: String, via: String, params: NativeRPCValue) async throws -> NativeRPCValue? {
        switch method {
        case "events/list": return list()
        case "events/subscribe": return try await subscribe(keyId: keyId, via: via, params: params)
        case "events/unsubscribe": return try unsubscribe(keyId: keyId, params: params)
        default: return nil
        }
    }
    public func offer(keyId: String, event: NativeRPCValue) async -> Int {
        guard !stopped, let name = Self.eventNames[event["type"].string ?? ""] else { return 0 }
        expire()
        var wanting: [Subscription] = []
        for id in subscriptionOrder {
            guard let sub = subscriptionsByID[id], sub.keyID == keyId, sub.name == name, sub.sessionID == nil || sub.sessionID == event["sessionId"].string else { continue }
            if await allowed(sub) { wanting.append(sub) }
        }
        let claimed = wanting.filter { $0.sessionID != nil }, selected = claimed.isEmpty ? wanting : claimed
        let eventID = event["id"].string ?? ""
        let body = BackendDeckCoreEventsSupport.object([("eventId",.string(eventID)),("name",.string(name)),("timestamp",.string(BackendDeckCoreEventsSupport.iso(event["at"].number ?? clock.now()))),("data",event),("cursor",.null)]).compact
        guard body.utf8.count <= Self.maximumBodyBytes else { return 0 }
        var offered = 0
        for sub in selected where subscriptionsByID[sub.id] != nil {
            guard subscriptionsByID[sub.id]?.seen.contains(eventID) != true, !outbox.contains(where: { $0.subscriptionID == sub.id && $0.eventID == eventID }) else { continue }
            outbox.append(Outgoing(token: UUID(), subscriptionID: sub.id, eventID: eventID, body: body, attempts: 0, nextAt: clock.now())); offered += 1
        }
        if offered > 0 { await attempt(); save() }; return offered
    }
    public func subscriptions(keyId: String? = nil) -> [NativeRPCValue] {
        expire(); return subscriptionOrder.compactMap { subscriptionsByID[$0] }.filter { keyId == nil || $0.keyID == keyId }.map(\.view)
    }
    public func stopSubscription(keyId: String, id: String) -> Bool {
        guard subscriptionsByID[id]?.keyID == keyId else { return false }; remove(id); return true
    }
    public func reconcile() async {
        for sub in subscriptionsByID.values {
            let live = await mode(sub.keyID)
            if live == nil || live == "off" { drop(sub.id); changed() }
        }
    }
    public func stop() { stopped = true; if let timer { clock.cancel(timer) }; timer = nil; timerAt = nil; if saveQueued { flush() } }
    public func armed() -> Bool { timer != nil }
    public func owed() -> Int { outbox.count }
    public func owes(keyId: String, eventId: String) -> Bool { outbox.contains { $0.eventID == eventId && subscriptionsByID[$0.subscriptionID]?.keyID == keyId } }
    private func error(_ code: Int, _ message: String, _ data: NativeRPCValue = .missing) -> BackendDeckCoreEventsError { .init(code: code, message: message, data: data) }
    private func eventAndArguments(_ params: NativeRPCValue) throws -> (String, String?) {
        guard let name = params["name"].string, !name.isEmpty else { throw error(-32602, "name is required.") }
        guard Self.eventNames.values.contains(name) else { throw error(-32011, "There is no event called \(BackendDeckCoreEventsSupport.utf16Slice(name, length: 80)).", BackendDeckCoreEventsSupport.object([("kind",.string("event"))])) }
        let args = params["arguments"].isNullish ? NativeRPCValue.object([]) : params["arguments"]
        guard let fields = args.fields else { throw error(-32602, "arguments has to be an object.") }
        for field in fields where field.key != "sessionId" { throw error(-32602, "Unknown argument \(BackendDeckCoreEventsSupport.utf16Slice(field.key, length: 40)). The only one is sessionId.") }
        if args["sessionId"] == .missing { return (name,nil) }
        guard let id = args["sessionId"].string, !id.isEmpty, id.utf16.count <= 200 else { throw error(-32602, "sessionId has to be a session id.") }
        return (name,id)
    }
    private func verify(id: String, url: String, secret: String) async throws {
        let challenge = BackendDeckCoreEventsSupport.base64URL(try BackendDeckCoreEventsSupport.random(24))
        let body = BackendDeckCoreEventsSupport.object([("type",.string("verification")),("challenge",.string(challenge))]).compact
        let message = "msg_verification_" + BackendDeckCoreEventsSupport.base64URL(try BackendDeckCoreEventsSupport.random(12))
        let headers = signed([Secret(value: secret, until: nil)], messageID: message, body: body, subscription: id)
        let result: BackendDeckCoreEventsCallbackAnswer
        do { result = try await post(url,headers,body) }
        catch {
            let refused = error as? BackendDeckCoreEventsCallbackRefused
            if refused?.reason == "not_public" { throw self.error(-32602, refused!.message) }
            throw self.error(-32015, "The callback could not be reached to verify it.", BackendDeckCoreEventsSupport.object([("reason",.string(refused?.reason ?? "connection_refused"))]))
        }
        guard (200..<300).contains(result.status) else { throw error(-32015, "The callback answered \(result.status) to verification.", BackendDeckCoreEventsSupport.object([("reason",.string(result.status >= 500 ? "http_5xx" : "http_4xx"))])) }
        let echoed = try? NativeRPCValue.parseJSON(Data(result.body.utf8))
        let echo = echoed?["challenge"].string ?? ""
        guard BackendDeckCoreEventsSupport.equal(echo,challenge) else { throw error(-32015, "The callback did not echo the verification challenge.", BackendDeckCoreEventsSupport.object([("reason",.string("challenge_failed"))])) }
    }
    private func allowed(_ sub: Subscription) async -> Bool {
        guard let mode = await mode(sub.keyID), mode != "off" else { return false }
        if sub.via != "internet" { return true }
        return await internet()
    }
    private func attempt() async {
        guard !stopped else { return }
        var ready: [(UUID,Subscription)] = []
        for item in outbox {
            guard let next = item.nextAt, next <= clock.now(), !posting.contains(item.token) else { continue }
            guard let sub = subscriptionsByID[item.subscriptionID], sub.refreshBefore > clock.now(), await allowed(sub) else { discard(item.token); continue }
            guard await owesEvent(sub.keyID,item.eventID) else { discard(item.token); continue }
            guard !stopped, outbox.contains(where: { $0.token == item.token }), !posting.contains(item.token) else { continue }
            // Reserve the due set before launching callbacks. Swift actor awaits
            // must not let one immediate callback suppress another chat that was
            // owed this same source pass (the JS loop launches all before settling).
            posting.insert(item.token); ready.append((item.token,sub))
        }
        for (token,sub) in ready {
            if stopped || !outbox.contains(where:{ $0.token == token }) { posting.remove(token); continue }
            postOne(token,sub:sub)
        }
        arm()
    }
    private func postOne(_ token: UUID, sub: Subscription) {
        guard let index = outbox.firstIndex(where: { $0.token == token }) else { return }
        posting.insert(token); outbox[index].attempts += 1; let item = outbox[index]
        let headers = signed(sub.secrets, messageID: item.eventID, body: item.body, subscription: sub.id)
        inFlight[item.token] = Task {
            do { let result = try await post(sub.url,headers,item.body); await complete(item: item, sub: sub, status: result.status, problem: nil) }
            catch { await complete(item: item, sub: sub, status: nil, problem: error.localizedDescription) }
            await finished(item.token)
        }
    }
    private func finished(_ token: UUID) { inFlight[token] = nil }
    /// Deterministic completion seam for tests: awaits every timer that has fired
    /// (its retry pass) and every callback attempt in flight (including its
    /// delivered notice), and what each of them starts, never polls.
    public func awaitIdle() async {
        while true {
            await fires.awaitIdle()
            if inFlight.isEmpty { return }
            let tasks = Array(inFlight.values)
            for task in tasks { await task.value }
        }
    }
    private func complete(item: Outgoing, sub: Subscription, status: Int?, problem: String?) async {
        guard !stopped, let index = outbox.firstIndex(where: { $0.token == item.token }) else { posting.remove(item.token); return }
        if let status, (200..<300).contains(status) {
            if var live = subscriptionsByID[sub.id] { live.lastDelivery = delivery(ok:true,error:nil); live.seen = Array((live.seen + [item.eventID]).suffix(200)); subscriptionsByID[sub.id] = live }
            // The queue is told first, and the entry stays "posting" meanwhile, so neither the
            // queue's retry nor this outbox's own can hand the same notice out a second time.
            await onDelivered(sub.keyID,item.eventID)
            posting.remove(item.token)
            discard(item.token)
            changed(); arm(); return
        }
        posting.remove(item.token)
        if status == 410 { drop(sub.id) }
        else if status == 413 { discard(item.token); subscriptionsByID[sub.id]?.lastDelivery = delivery(ok:false,error:"the callback refused the size (413)") }
        else {
            let why = status.map { "the callback answered \($0)" } ?? problem ?? "connection_refused"
            let retry = item.attempts - 1
            if BackendDeckCoreEventsSupport.retryDelays.indices.contains(retry) {
                outbox[index].nextAt = clock.now() + BackendDeckCoreEventsSupport.retryDelays[retry]
                subscriptionsByID[sub.id]?.lastDelivery = delivery(ok:false,error:why)
            } else { discard(item.token); subscriptionsByID[sub.id]?.lastDelivery = delivery(ok:false,error:"\(why); gave up after \(item.attempts) tries") }
        }
        changed(); arm()
    }
    private func delivery(ok: Bool, error: String?) -> NativeRPCValue { BackendDeckCoreEventsSupport.object([("at",.number(clock.now())),("ok",.bool(ok)),("error",BackendDeckCoreEventsSupport.nullable(error))]) }
    private func signed(_ secrets: [Secret], messageID: String, body: String, subscription: String) -> [String: String] {
        let now = clock.now(), timestamp = floor(now / 1_000)
        let signatures = secrets.filter { $0.until == nil || $0.until! > now }.map { BackendDeckCoreEventsWebhook.sign(secret:$0.value,id:messageID,timestamp:timestamp,body:body) }.joined(separator:" ")
        return ["webhook-id":messageID,"webhook-timestamp":String(format:"%.0f",timestamp),"webhook-signature":signatures,Self.subscriptionHeader:subscription]
    }
    private func answer(_ sub: Subscription) -> NativeRPCValue { BackendDeckCoreEventsSupport.object([("id",.string(sub.id)),("refreshBefore",.string(BackendDeckCoreEventsSupport.iso(sub.refreshBefore))),("cursor",.null),("truncated",.bool(false))]) }
    private func discard(_ token: UUID) { outbox.removeAll { $0.token == token }; save() }
    private func drop(_ id: String) { subscriptionsByID[id] = nil; subscriptionOrder.removeAll { $0 == id }; outbox.removeAll { $0.subscriptionID == id }; save() }
    private func remove(_ id: String) { guard subscriptionsByID[id] != nil else { return }; drop(id); changed() }
    private func expire() {
        let now = clock.now()
        for sub in subscriptionsByID.values {
            if sub.refreshBefore <= now { drop(sub.id); changed(); continue }
            let kept = sub.secrets.filter { $0.until == nil || $0.until! > now }
            if kept.count != sub.secrets.count { subscriptionsByID[sub.id]?.secrets = kept; save() }
        }
    }
    private func arm() {
        guard !stopped else { return }
        let next = outbox.filter { !posting.contains($0.token) }.compactMap(\.nextAt).min()
        if next == timerAt { return }; if let timer { clock.cancel(timer) }; timer = nil; timerAt = next
        if let next { timer = clock.schedule(after:max(next-clock.now(),0)) { [fires] in fires.start { await self.fire() } } }
    }
    private func fire() async { timer = nil; timerAt = nil; await attempt() }
    private func changed() { save(); onChange() }
    private var file: URL? { directory?.appendingPathComponent(Self.fileName) }
    private func save() { guard file != nil, !saveQueued else { return }; saveQueued = true; Task { self.flush() } }
    public func flush() {
        saveQueued = false
        let value = BackendDeckCoreEventsSupport.object([("v",.number(1)),("subscriptions",.array(subscriptionOrder.compactMap { subscriptionsByID[$0]?.wire })),("outbox",.array(outbox.map(\.wire)))])
        do { try BackendDeckCoreEventsSupport.write(value,file:file) } catch { report("[mcp-events] could not save the subscriptions: \(error.localizedDescription)") }
    }
    public static func catalogue() -> [NativeRPCValue] {
        let string = BackendDeckCoreEventsSupport.object([("type",.string("string"))]), number = BackendDeckCoreEventsSupport.object([("type",.string("number"))]), boolean = BackendDeckCoreEventsSupport.object([("type",.string("boolean"))])
        let excerpt = BackendDeckCoreEventsSupport.object([("type",.string("object")),("properties",BackendDeckCoreEventsSupport.object([("text",string),("truncated",boolean)]))])
        let input = BackendDeckCoreEventsSupport.object([("type",.string("object")),("properties",BackendDeckCoreEventsSupport.object([("sessionId",string.setting("description",.string("Only this session: pass the one this chat started, so other chats on the same connection are not woken for it. Leave it out for every session this app started or sent a message to.")))])),("additionalProperties",.bool(false))])
        let payload = BackendDeckCoreEventsSupport.object([("type",.string("object")),("description",.string("One notification about one session, the same object notifications_list returns.")),("properties",BackendDeckCoreEventsSupport.object([("id",string.setting("description",.string("Stable id; also the delivery’s webhook-id."))),("type",string.setting("enum",.array([.string("finished"),.string("needs-input"),.string("exited")]))),("sessionId",string.setting("description",.string("Pass to sessions_send, sessions_keys, sessions_screen or sessions_result."))),("sessionName",string),("at",number.setting("description",.string("Epoch milliseconds."))),("answer",excerpt.setting("description",.string("finished: the newest thing the agent said, capped at 2,000 characters."))),("screen",excerpt.setting("description",.string("needs-input (or finished with no transcript): the last lines of the screen."))),("exitCode",number),("crashed",boolean),("suggestedTool",string.setting("description",.string("The tool most likely wanted next."))),("note",string.setting("description",.string("One sentence of fact about what happened.")))])),("required",.array(["id","type","sessionId","sessionName","at","suggestedTool","note"].map(NativeRPCValue.string)))])
        let descriptions = ["A coding session this app started, or sent the last message to, finished its turn. Carries the agent’s answer.","A coding session this app started, or sent the last message to, stopped to ask something: a permission prompt, a menu or a question. Answer it with sessions_keys or sessions_send.","A coding session this app started exited, or crashed."]
        return ["session.turn_finished","session.needs_input","session.exited"].enumerated().map { BackendDeckCoreEventsSupport.object([("name",.string($0.element)),("description",.string(descriptions[$0.offset])),("delivery",.array([.string("webhook")])),("inputSchema",input),("payloadSchema",payload)]) }
    }
}

extension BackendDeckCoreEvents: BackendDeckCoreSecurityEvents {
    public func subscribe(keyID: String, via: String, parameters: NativeRPCValue) async throws -> NativeRPCValue {
        do { return try await subscribe(keyId:keyID,via:via,params:parameters) }
        catch let error as BackendDeckCoreEventsError { throw BackendDeckCoreSecurityProtocolError(code:error.code,message:error.message,data:error.data) }
    }
    public func unsubscribe(keyID: String, parameters: NativeRPCValue) async throws -> NativeRPCValue {
        do { return try unsubscribe(keyId:keyID,params:parameters) }
        catch let error as BackendDeckCoreEventsError { throw BackendDeckCoreSecurityProtocolError(code:error.code,message:error.message,data:error.data) }
    }
}
