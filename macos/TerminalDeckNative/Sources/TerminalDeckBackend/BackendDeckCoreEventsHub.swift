import Foundation
import TerminalDeckNativeCore

/// The source-shaped durable queue. Event text remains untrusted evidence.
public actor BackendDeckCoreEventsHub {
    public static let fileName = "notifications.json"
    public static let maximumPerKey = 200
    public static let maximumAge: Double = 7 * 24 * 60 * 60 * 1_000
    public static let maximumPerWait = 20
    public static let maximumTurns = 1_000
    public typealias Settings = @Sendable (String) async -> NativeRPCValue?
    public typealias Pushing = @Sendable (String, String) async -> Bool
    private struct Item: Sendable {
        let token: UUID
        var event: NativeRPCValue
        let keyID: String
        var state: String
        var attempts: Int
        var nextAt: Double?
        var via: String?
        var deliveredAt: Double?
        var lastError: String?
        var id: String { event["id"].string ?? "" }
        var wire: NativeRPCValue { BackendDeckCoreEventsSupport.object([("event", event),("keyId", .string(keyID)),("state", .string(state)),("attempts", .number(Double(attempts))),("nextAt", BackendDeckCoreEventsSupport.number(nextAt)),("via", BackendDeckCoreEventsSupport.nullable(via)),("deliveredAt", BackendDeckCoreEventsSupport.number(deliveredAt)),("lastError", BackendDeckCoreEventsSupport.nullable(lastError))]) }
    }
    private struct Waiter {
        let keyID: String
        let max: Int
        let continuation: CheckedContinuation<[NativeRPCValue], Never>
        let cancellation: BackendMCPCancellation?
        var observer: UUID?
        var timer: UUID?
    }
    private var items: [Item] = []
    private var last: [String: NativeRPCValue] = [:]
    private var turns: [(String, Double)] = []
    private var waiters: [UUID: Waiter] = [:]
    private var waiterOrder: [UUID] = []
    private let directory: URL?
    private let settings: Settings
    private let clock: any BackendDeckCoreEventsClock
    private let post: BackendDeckCoreEventsWebhookPost
    private let changed: @Sendable () -> Void
    private let report: @Sendable (String) -> Void
    private var pushing: Pushing
    private var timer: UUID?
    private var timerAt: Double?
    private var posting: Set<UUID> = []
    private var stopped = false
    private var saveQueued = false
    /// Timer hops and webhook posts, recorded as they start, for awaitIdle().
    private let work = BackendDeckCoreEventsWork()

    public init(directory: URL? = nil, settings: @escaping Settings,
                clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock(),
                post: @escaping BackendDeckCoreEventsWebhookPost = BackendDeckCoreEventsCallback.webhookPost,
                pushing: @escaping Pushing = { _, _ in false },
                onChange: @escaping @Sendable () -> Void = {}, report: @escaping @Sendable (String) -> Void = { _ in }) {
        self.directory = directory; self.settings = settings; self.clock = clock; self.post = post
        self.pushing = pushing; self.changed = onChange; self.report = report
    }
    /// Invoke once after construction, before registration. No live directory is touched by construction.
    public func load() {
        guard let raw = try? BackendDeckCoreEventsSupport.read(file), raw["v"].number == 1, let rows = raw["items"].elements else { return }
        items = rows.compactMap { raw in
            let event = raw["event"]
            guard let key = raw["keyId"].string, let state = raw["state"].string, ["pending","delivered","undelivered"].contains(state),
                  let attempts = raw["attempts"].number, attempts >= 0, attempts <= Double(Int.max),
                  event["id"].string != nil, event["sessionId"].string != nil, event["at"].number != nil,
                  ["finished","needs-input","exited"].contains(event["type"].string ?? "") else { return nil }
            let next = raw["nextAt"].number ?? (state == "pending" ? clock.now() : nil)
            return Item(token: UUID(), event: event, keyID: key, state: state, attempts: Int(attempts), nextAt: next,
                        via: raw["via"].string, deliveredAt: raw["deliveredAt"].number, lastError: raw["lastError"].string)
        }
        last = [:]
        for field in raw["last"].fields ?? [] where field.value["at"].number != nil && field.value["state"].string != nil { last[field.key] = field.value }
        turns = (raw["turns"].elements ?? []).compactMap {
            guard let pair = $0.elements, pair.count >= 2, let name = pair[0].string, let at = pair[1].number else { return nil }; return (name, at)
        }
        prune(); arm()
    }
    public func setPushing(_ pushing: @escaping Pushing) { self.pushing = pushing }
    public func enqueue(keyId: String, event: NativeRPCValue, turn: String? = nil) async -> Bool {
        guard !stopped, let settings = await settings(keyId), settings["mode"].string != "off", !stopped else { return false }
        if let turn { guard !turns.contains(where: { $0.0 == turn }) else { return false }; turns.append((turn, clock.now())) }
        items.append(Item(token: UUID(), event: event, keyID: keyId, state: "pending", attempts: 0, nextAt: clock.now(), via: nil, deliveredAt: nil, lastError: nil))
        prune(); note(keyId, state: "pending", via: nil, error: nil)
        await attempt(); save(); return true
    }
    public func wait(keyId: String, timeoutMs: Double, cancellation: BackendMCPCancellation? = nil, max: Int = BackendDeckCoreEventsHub.maximumPerWait) async -> [NativeRPCValue] {
        let ready = await take(keyId, max: max, via: "wait")
        if !ready.isEmpty || stopped || cancellation?.isCancelled == true { return ready }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = Waiter(keyID: keyId, max: max, continuation: continuation, cancellation: cancellation)
                waiterOrder.append(id)
                let timer = clock.schedule(after: Swift.max(timeoutMs, 0)) { [work] in work.start { await self.settle(id, events: []) } }
                waiters[id]?.timer = timer
                let observer = cancellation?.observe { Task { await self.settle(id, events: []) } }
                waiters[id]?.observer = observer
                if Task.isCancelled || cancellation?.isCancelled == true { settle(id, events: []) }
            }
        } onCancel: { Task { await self.settle(id, events: []) } }
    }
    public func list(keyId: String) -> [NativeRPCValue] {
        prune()
        return items.filter { $0.keyID == keyId }.map { $0.event.setting("delivery", .string($0.state)).setting("via", BackendDeckCoreEventsSupport.nullable($0.via)) }
    }
    public func ack(keyId: String, ids: [String]) -> NativeRPCValue {
        var wanted: [String] = []; for id in ids where !wanted.contains(id) { wanted.append(id) }
        let acked = items.filter { $0.keyID == keyId && wanted.contains($0.id) }.map(\.id)
        items.removeAll { $0.keyID == keyId && wanted.contains($0.id) }
        if !acked.isEmpty { arm(); save(); changed() }
        return BackendDeckCoreEventsSupport.object([("acked", .array(acked.map(NativeRPCValue.string))), ("alreadyGone", .array(wanted.filter { !acked.contains($0) }.map(NativeRPCValue.string)))])
    }
    public func testWebhook(keyId: String) async -> NativeRPCValue {
        guard let settings = await settings(keyId), let url = settings["url"].string, let secret = settings["secret"].string else { return result(false, "Set a webhook address first.") }
        let id = "test-" + UUID().uuidString.lowercased()
        let event = BackendDeckCoreEventsSupport.object([("id",.string(id)),("type",.string("finished")),("sessionId",.string("test")),("sessionName",.string("Test notification")),("at",.number(clock.now())),("answer",BackendDeckCoreEventsSupport.object([("text",.string("This is a test from Settings. Nothing happened in any session.")),("truncated",.bool(false))])),("suggestedTool",.string("notifications_list")),("note",.string("A test notification, sent from Settings. It is not kept and needs no acknowledgement."))])
        let body = event.compact
        do {
            let status = try await post(url, BackendDeckCoreEventsWebhook.headers(secret: secret, id: id, timestamp: floor(clock.now()/1_000), body: body), body)
            return (200..<300).contains(status) ? result(true, "Delivered: the address answered \(status).") : result(false, "The address answered \(status), so a real notification would be retried.")
        } catch { return result(false, "Could not reach the address: \(error.localizedDescription)") }
    }
    @discardableResult public func deliveredBy(keyId: String, id: String, via: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.keyID == keyId && $0.id == id && $0.state != "delivered" }) else { return false }
        delivered(index, via: via); arm(); return true
    }
    public func owes(keyId: String, id: String) -> Bool { items.contains { $0.keyID == keyId && $0.id == id && $0.state != "delivered" } }
    public func lastDelivery(keyId: String) -> NativeRPCValue? { last[keyId]?.setting("outstanding", .number(Double(size(keyId: keyId)))) }
    public func size(keyId: String? = nil) -> Int { keyId.map { key in items.filter { $0.keyID == key }.count } ?? items.count }
    public func armed() -> Bool { timer != nil }
    public func reconcile() async {
        let keys = Set(items.map(\.keyID) + Array(last.keys) + waiters.values.map(\.keyID))
        var gone: Set<String> = []
        for key in keys { if await settings(key) == nil { gone.insert(key) } }
        let before = items.count; items.removeAll { gone.contains($0.keyID) }; last = last.filter { !gone.contains($0.key) }
        for id in waiterOrder where gone.contains(waiters[id]?.keyID ?? "") { settle(id, events: []) }
        if before != items.count { arm(); save() }; await attempt()
    }
    public func stop() {
        stopped = true; for id in waiterOrder { settle(id, events: []) }
        if let timer { clock.cancel(timer) }; timer = nil; timerAt = nil; flush()
    }
    private func result(_ ok: Bool, _ message: String) -> NativeRPCValue { BackendDeckCoreEventsSupport.object([("ok", .bool(ok)),("message", .string(message))]) }
    private func settle(_ id: UUID, events: [NativeRPCValue]) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }; if let timer = waiter.timer { clock.cancel(timer) }
        if let observer = waiter.observer { waiter.cancellation?.removeObserver(observer) }
        waiter.continuation.resume(returning: events)
    }
    private func attempt() async {
        guard !stopped else { return }
        let tokens = items.filter { $0.state == "pending" && ($0.nextAt ?? .infinity) <= clock.now() && !posting.contains($0.token) }.map(\.token)
        for token in tokens {
            guard let item = items.first(where: { $0.token == token }), let config = await settings(item.keyID), config["mode"].string != "off", !stopped else { continue }
            if await pushing(item.keyID, item.id) { if let index = pendingIndex(token) { missed(index, "its push to the app is still being tried") }; continue }
            var offered = false
            for id in waiterOrder where waiters[id]?.keyID == item.keyID {
                guard let waiter = waiters[id] else { continue }
                let events = await take(item.keyID, max: waiter.max, via: "wait")
                if !events.isEmpty { settle(id, events: events); offered = true; break }
            }
            if offered { continue }
            guard let index = pendingIndex(token) else { continue }
            if config["mode"].string == "webhook", let url = config["url"].string, let secret = config["secret"].string { postOne(index, url: url, secret: secret) }
            else { missed(index, "nobody was waiting for it") }
        }
        arm()
    }
    private func pendingIndex(_ token: UUID) -> Int? { items.firstIndex { $0.token == token && $0.state == "pending" && !posting.contains(token) } }
    private func postOne(_ index: Int, url: String, secret: String) {
        items[index].attempts += 1; let item = items[index]; posting.insert(item.token)
        let body = item.event.compact, headers = BackendDeckCoreEventsWebhook.headers(secret: secret, id: item.id, timestamp: floor(clock.now()/1_000), body: body)
        work.start { [post] in
            let problem: String?
            do { let status = try await post(url, headers, body); problem = (200..<300).contains(status) ? nil : "the webhook answered \(status)" }
            catch { problem = "the webhook could not be reached: \(error.localizedDescription)" }
            await self.completePost(item.token, problem: problem)
        }
    }
    private func completePost(_ token: UUID, problem: String?) {
        posting.remove(token)
        guard let index = pendingIndex(token) else { return }
        if let problem { failed(index, problem) } else { delivered(index, via: "webhook") }
        arm(); save()
    }
    private func missed(_ index: Int, _ why: String) { items[index].attempts += 1; failed(index, why) }
    private func failed(_ index: Int, _ why: String) {
        items[index].lastError = why; let retry = items[index].attempts - 1
        if BackendDeckCoreEventsSupport.retryDelays.indices.contains(retry) {
            items[index].nextAt = clock.now() + BackendDeckCoreEventsSupport.retryDelays[retry]
            note(items[index].keyID, state: "failed", via: nil, error: why)
        } else { items[index].state = "undelivered"; items[index].nextAt = nil; note(items[index].keyID, state: "undelivered", via: nil, error: why) }
        save()
    }
    private func delivered(_ index: Int, via: String) {
        items[index].state = "delivered"; items[index].via = via; items[index].nextAt = nil; items[index].deliveredAt = clock.now(); items[index].lastError = nil
        note(items[index].keyID, state: "delivered", via: via, error: nil); save()
    }
    private func take(_ keyID: String, max: Int, via: String) async -> [NativeRPCValue] {
        var out: [NativeRPCValue] = []
        for item in items.filter({ $0.keyID == keyID && $0.state != "delivered" }) {
            if out.count >= max { break }
            if await pushing(keyID, item.id) { continue }
            guard let index = items.firstIndex(where: { $0.token == item.token && $0.state != "delivered" }) else { continue }
            delivered(index, via: via); out.append(item.event)
        }
        if !out.isEmpty { arm() }; return out
    }
    private func note(_ keyID: String, state: String, via: String?, error: String?) {
        last[keyID] = BackendDeckCoreEventsSupport.object([("state",.string(state)),("at",.number(clock.now())),("via",BackendDeckCoreEventsSupport.nullable(via)),("error",BackendDeckCoreEventsSupport.nullable(error))]); changed()
    }
    private func prune() {
        let cutoff = clock.now() - Self.maximumAge
        items.removeAll { ($0.event["at"].number ?? 0) < cutoff }
        var count: [String: Int] = [:], keep: Set<UUID> = []
        for item in items.reversed() { count[item.keyID, default: 0] += 1; if count[item.keyID]! <= Self.maximumPerKey { keep.insert(item.token) } }
        items.removeAll { !keep.contains($0.token) }
        while let turn = turns.first, turn.1 < cutoff || turns.count > Self.maximumTurns { turns.removeFirst() }
    }
    private func arm() {
        guard !stopped else { return }
        let next = items.filter { $0.state == "pending" && !posting.contains($0.token) }.compactMap(\.nextAt).min()
        if next == timerAt { return }; if let timer { clock.cancel(timer) }; timer = nil; timerAt = next
        guard let next else { return }
        timer = clock.schedule(after: max(next - clock.now(), 0)) { [work] in work.start { await self.fire() } }
    }
    private func fire() async { timer = nil; timerAt = nil; await attempt() }
    /// Deterministic completion seam (as BackendDeckCoreEvents.awaitIdle): awaits
    /// every timer that has fired and every webhook post in flight, with what
    /// each one starts, until nothing is running. Never polls.
    public nonisolated func awaitIdle() async { await work.awaitIdle() }
    private var file: URL? { directory?.appendingPathComponent(Self.fileName) }
    private func save() {
        guard file != nil, !saveQueued else { return }; saveQueued = true
        Task { self.flush() }
    }
    public func flush() {
        saveQueued = false
        let value = BackendDeckCoreEventsSupport.object([("v",.number(1)),("items",.array(items.map(\.wire))),("last",.object(last.keys.sorted().map { .init($0,last[$0]!) })),("turns",.array(turns.map { .array([.string($0.0),.number($0.1)]) }))])
        do { try BackendDeckCoreEventsSupport.write(value, file: file) } catch { report("[notify] could not save the notification queue: \(error.localizedDescription)") }
    }
}
