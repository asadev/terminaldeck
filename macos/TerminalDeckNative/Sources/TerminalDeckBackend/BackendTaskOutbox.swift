import Foundation
import CryptoKit
import TerminalDeckNativeCore

public struct BackendTaskWebhookTarget: Sendable {
    public let url: URL
    fileprivate let secret: Data
    public init(url: URL, signingSecret: String) throws {
        guard (url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? ""))), url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else {
            throw NativeRPCError.invalidArguments("The task events address must be an HTTP or HTTPS URL without credentials or a fragment")
        }
        let raw = signingSecret.hasPrefix("whsec_") ? String(signingSecret.dropFirst(6)) : signingSecret
        guard let bytes = Data(base64Encoded: raw), bytes.count == 32 else { throw NativeRPCError.malformed("The connection's existing signing secret is invalid; rotate it in Settings") }
        self.url = url; secret = bytes
    }
}
public struct BackendTaskWebhookAnswer: Sendable {
    public let status: Int
    public let body: String
    public init(status: Int, body: String) { self.status = status; self.body = body }
}
public struct BackendTaskWebhookTransport: Sendable {
    public init() {}
    /// Called only by an explicitly started outbox; no redirects, cookies or
    /// URL credential storage. Cancellation stops this request's session.
    public func post(target: BackendTaskWebhookTarget, event: NativeRPCValue) async throws -> BackendTaskWebhookAnswer {
        let request = try Self.signedRequest(target: target, event: event)
        let configuration = URLSessionConfiguration.ephemeral; configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw NativeRPCError(code: "webhook", message: "The CRM did not return an HTTP response") }
        var body = Data()
        for try await byte in stream { try Task.checkCancellation(); if body.count >= 8_192 { break }; body.append(byte) }
        return BackendTaskWebhookAnswer(status: response.statusCode, body: String(decoding: body, as: UTF8.self))
    }
    /// task-outbox.ts' Standard Webhooks delivery: webhook-id, a timestamp in seconds, and a v1 HMAC-SHA256 over
    /// `id.timestamp.body`. Built without any network use, so the exact bytes can be inspected.
    public static func signedRequest(target: BackendTaskWebhookTarget, event: NativeRPCValue) throws -> URLRequest {
        let bytes = try event.encodedJSON(), eventID = try event["eventId"].requireString("eventId", nonempty: true), stamp = String(Int(BackendTaskValues.time() / 1_000))
        var signed = Data((eventID + "." + stamp + ".").utf8); signed.append(bytes)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: target.secret))).base64EncodedString()
        var request = URLRequest(url: target.url, timeoutInterval: 10); request.httpMethod = "POST"; request.httpBody = bytes
        request.setValue("application/json", forHTTPHeaderField: "content-type"); request.setValue(eventID, forHTTPHeaderField: "webhook-id")
        request.setValue(stamp, forHTTPHeaderField: "webhook-timestamp"); request.setValue("v1," + signature, forHTTPHeaderField: "webhook-signature")
        return request
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}

/// Original task-outbox.json v1 and Standard Webhooks deliveries. The real
/// grant/connection resolver is checked again for every retry, including restore.
public actor BackendTaskOutbox {
    public typealias Target = @Sendable (String) async throws -> BackendTaskWebhookTarget?
    public typealias Post = @Sendable (BackendTaskWebhookTarget, NativeRPCValue) async throws -> BackendTaskWebhookAnswer
    private let persistence: BackendTaskPersistence, target: Target, post: Post
    private let onCommentID: @Sendable (String, String) async throws -> Void
    private let changed: @Sendable () async -> Void, problem: @Sendable (String) async -> Void
    private var items: [NativeRPCValue] = [], loaded = false, stopped = true
    private var posting: [String: Task<Void, Never>] = [:], timer: BackendTaskTimer?
    public init(persistence: BackendTaskPersistence, target: @escaping Target,
                post: @escaping Post = { try await BackendTaskWebhookTransport().post(target: $0, event: $1) },
                onCommentID: @escaping @Sendable (String, String) async throws -> Void,
                changed: @escaping @Sendable () async -> Void = {}, problem: @escaping @Sendable (String) async -> Void) {
        self.persistence = persistence; self.target = target; self.post = post; self.onCommentID = onCommentID; self.changed = changed; self.problem = problem
    }
    public func start() async throws {
        guard stopped else { return }; try persistence.writable()
        if !loaded {
            if let raw = try persistence.read("task-outbox.json") {
                guard raw["v"].number == 1 else { throw NativeRPCError.malformed("Unsupported task-outbox.json version") }
                items = (raw["items"].elements ?? []).filter { $0["keyId"].string != nil && $0["event"]["eventId"].string != nil }.map { row in
                    row["state"].string == "pending" && row["nextAt"].isNullish ? row.setting("nextAt", .number(BackendTaskValues.time())) : row
                }
            }; loaded = true
        }; prune(); stopped = false; await attempt()
    }
    public func send(keyID: String, body: NativeRPCValue, sequence: Int) async throws -> NativeRPCValue {
        guard loaded, !stopped else { throw NativeRPCError(code: "not-started", message: "The task event outbox is not running") }; try persistence.writable()
        guard ["task.status", "task.comment", "task.delegate_requested"].contains(body["type"].string ?? ""), body["externalTaskId"].string != nil,
              body["originExternalTaskId"].string != nil, body["actor"].string != nil, sequence >= 0 else { throw NativeRPCError.invalidArguments("Incomplete outgoing task event") }
        let now = BackendTaskValues.time(), event = body.setting("eventId", .string("tde_" + UUID().uuidString.lowercased())).setting("seq", .number(Double(sequence))).setting("at", .string(Self.iso(now)))
        let before = items
        items.append(BackendTaskValues.object([("keyId", .string(keyID)), ("event", event), ("state", .string("pending")), ("attempts", .number(0)), ("nextAt", .number(now)), ("queuedAt", .number(now)), ("error", .null)])); prune()
        do { try flush() } catch { items = before; throw error }; await changed(); await attempt(); return event
    }
    public func list(keyID: String? = nil) -> [NativeRPCValue] {
        items.filter { keyID == nil || $0["keyId"].string == keyID }.map { BackendTaskValues.object([("eventId", $0["event"]["eventId"]), ("type", $0["event"]["type"]), ("externalTaskId", $0["event"]["externalTaskId"]), ("state", $0["state"]), ("attempts", $0["attempts"]), ("error", $0["error"])]) }
    }
    public func stop() async throws {
        stopped = true; timer?.cancel(); timer = nil; let running = Array(posting.values); running.forEach { $0.cancel() }; posting.removeAll()
        for job in running { await job.value }; if loaded { try flush() }
    }
    public func wake() async { guard !stopped else { return }; await attempt() }
    public static func outgoing(store: BackendTaskStore, outbox: BackendTaskOutbox) -> @Sendable (BackendTaskRecord, NativeRPCValue) async throws -> Void {
        { record, body in
            let current = try await store.byID(record.id) ?? record, sequence = try await store.nextSequence(record.id)
            // Consume the sequence durably before queueing. A failed queue may
            // leave a gap, never a reused number after a process crash.
            let complete = body.setting("externalTaskId", current.value["externalTaskId"]).setting("originExternalTaskId", current.value["originExternalTaskId"])
                .setting("externalThreadId", current.value["externalThreadId"].isNullish ? .null : current.value["externalThreadId"])
                .setting("actor", body["actor"].isNullish ? current.value["assignee"]["identity"] : body["actor"])
            let event = try await outbox.send(keyID: current.value["keyId"].string!, body: complete, sequence: sequence)
            try await store.markOurs(keyID: current.value["keyId"].string!, eventID: event["eventId"].string!)
        }
    }
    private func attempt() async {
        guard !stopped else { return }; timer?.cancel(); timer = nil
        for item in items where item["state"].string == "pending" && (item["nextAt"].number ?? .infinity) <= BackendTaskValues.time() {
            guard let id = item["event"]["eventId"].string, posting[id] == nil, let key = item["keyId"].string else { continue }
            posting[id] = Task { [weak self, target, post] in
                do {
                    guard let target = try await target(key) else { await self?.finished(id, answer: nil, error: "the connection has no events address", retry: false); return }
                    try Task.checkCancellation(); guard let event = await self?.beginAttempt(id) else { await self?.cancelled(id); return }
                    let answer = try await post(target, event); await self?.finished(id, answer: answer, error: nil, retry: true)
                } catch is CancellationError { await self?.cancelled(id) }
                catch { await self?.finished(id, answer: nil, error: "the CRM could not be reached", retry: true) }
            }
        }; arm()
    }
    private func beginAttempt(_ id: String) -> NativeRPCValue? {
        guard !stopped, let index = items.firstIndex(where: { $0["event"]["eventId"].string == id }) else { return nil }
        items[index] = items[index].setting("attempts", .number((items[index]["attempts"].number ?? 0) + 1))
        do { try flush() } catch { Task { await problem(error.localizedDescription) }; return nil }; return items[index]["event"]
    }
    private func cancelled(_ id: String) { posting[id] = nil }
    private func finished(_ id: String, answer: BackendTaskWebhookAnswer?, error: String?, retry: Bool) async {
        posting[id] = nil
        guard !stopped, let index = items.firstIndex(where: { $0["event"]["eventId"].string == id }), items[index]["state"].string == "pending" else { return }
        if let answer, (200..<300).contains(answer.status) {
            items[index] = items[index].setting("state", .string("delivered")).setting("nextAt", .null).setting("error", .null)
            if items[index]["event"]["type"].string == "task.comment", let parsed = try? NativeRPCValue.parseJSON(Data(answer.body.utf8), maximumBytes: 8_192), let comment = parsed["externalCommentId"].string, !comment.isEmpty, comment.utf16.count <= 200 {
                do { try await onCommentID(items[index]["keyId"].string!, comment) } catch { await problem("The CRM comment was delivered but its id could not be kept: " + error.localizedDescription) }
            }
        } else {
            let attempts = Int(items[index]["attempts"].number ?? 0), delays = [5_000, 30_000, 120_000]
            let canRetry = answer.map { $0.status == 408 || $0.status == 429 || $0.status >= 500 } ?? retry
            let delay = canRetry && attempts >= 1 && attempts <= delays.count ? delays[attempts - 1] : nil
            items[index] = items[index].setting("error", .string(error ?? "the CRM answered \(answer?.status ?? 0)"))
                .setting("state", .string(delay == nil ? "undelivered" : "pending")).setting("nextAt", delay.map { .number(BackendTaskValues.time() + Double($0)) } ?? .null)
        }
        do { try flush() } catch { await problem(error.localizedDescription) }; await changed(); arm()
    }
    private func arm() {
        timer?.cancel(); timer = nil; guard !stopped else { return }
        let due = items.filter { $0["state"].string == "pending" && posting[$0["event"]["eventId"].string ?? ""] == nil }.compactMap { $0["nextAt"].number }.min()
        if let due { timer = BackendTaskTimers.schedule(milliseconds: min(max(0, due - BackendTaskValues.time()), 3_600_000)) { [weak self] in await self?.attempt() } }
    }
    private func prune() {
        let cutoff = BackendTaskValues.time() - 7 * 86_400_000
        items.removeAll { $0["state"].string != "pending" && ($0["queuedAt"].number ?? 0) < cutoff }
        var excess = items.count - 2_000
        items.removeAll { row in if excess > 0 && row["state"].string != "pending" { excess -= 1; return true }; return false }
    }
    private func flush() throws { try persistence.write("task-outbox.json", value: BackendTaskValues.object([("v", .number(1)), ("items", .array(items))])) }
    static func iso(_ milliseconds: Double) -> String { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1_000)) }
}
