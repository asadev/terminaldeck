import Foundation

/// The real `WhatsAppTransport`: URLSession against WhatsApp's Agent Platform (`https://api.whatsapp.com/agent/v1`),
/// following the manual's own rules (version 1, 25 Aug 2026). Foundation only, so Windows ports it file for file.
///
/// What it guarantees, per key:
/// - never two polls at once; sends and status calls strictly one after another (one lane each);
/// - at most 12 sends, 12 status calls, 15 polls and 12 media requests in any 60 seconds (rolling window);
/// - a 2xx send is never retried; a 4xx is not retried except 429; a 503 with code 131016 is retried after backing off;
///   a 500, a 503 with another code, or a lost connection after the request left is reported as "unknown whether sent"
///   and NOT retried, so a message is never sent twice;
/// - the key is only ever placed in the `Authorization` header. No log line, error text, outcome or description holds it.
public actor WhatsAppHTTPTransport: WhatsAppTransport {
    public static let defaultBase = URL(string: "https://api.whatsapp.com/agent/v1")!
    /// The `.failed` text when WhatsApp's answer was lost after the request left (500, a timeout, a dropped connection).
    /// The engine can compare against it; the message is not sent again.
    public static let unknownWhetherSent = "WhatsApp did not say whether the message arrived, so it was not sent again."
    /// Where a media `url` may point; the key is sent with the download, so nowhere else.
    public static let defaultMediaHosts = ["whatsapp.com", "whatsapp.net", "fbsbx.com", "facebook.com", "fbcdn.net"]

    /// The numbers the manual gives, and the client's own timing. Tests may shrink them.
    public struct Limits: Sendable {
        public var sendsPerMinute = 12
        public var statusesPerMinute = 12
        public var pollsPerMinute = 15
        public var mediaPerMinute = 12
        /// First back-off wait; it doubles on every failure in a row, capped at `longestBackOff`.
        public var firstBackOff: Double = 2
        public var longestBackOff: Double = 60
        /// Tries for one send that keeps meeting 429 / 503 131016 / no connection before `.backOff` is returned.
        public var sendAttempts = 3
        /// Tries for one status call (marking read is harmless to repeat).
        public var statusAttempts = 2
        /// The client's own read timeout for a send or status call: well above the time a send needs (manual: "Retrying a send").
        public var callTimeout: Double = 60
        /// Added to the long-poll's own timeout for the client's read timeout (25 s poll -> 60 s).
        public var pollGrace: Double = 35
        /// The largest media item the manual allows (video, audio, document): 16 MB.
        public var largestMedia = 16 * 1024 * 1024
        public init() {}
    }

    private enum Lane: Hashable { case poll, out, media }
    private enum Window: Hashable { case poll, send, status, media }
    private struct LaneID: Hashable { let key: String; let lane: Lane }
    private struct WindowID: Hashable { let key: String; let window: Window }

    private let session: URLSession
    private let base: URL
    private let clock: WhatsAppClock
    private let limits: Limits
    private let mediaHosts: [String]

    private var busy: Set<LaneID> = []
    private var waiting: [LaneID: [CheckedContinuation<Void, Never>]] = [:]
    private var calls: [WindowID: [Date]] = [:]
    private var backOff: [WindowID: Double] = [:]

    public init(session: URLSession? = nil, base: URL = WhatsAppHTTPTransport.defaultBase, clock: WhatsAppClock = .system,
                limits: Limits = Limits(), mediaHosts: [String] = WhatsAppHTTPTransport.defaultMediaHosts) {
        self.session = session ?? WhatsAppHTTPTransport.makeSession()
        self.base = base
        self.clock = clock
        self.limits = limits
        self.mediaHosts = mediaHosts
    }

    /// No cache, no cookies, no waiting for a network: an answer or a clear failure.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 300
        // Security review hardening (15 Nov): a redirect never carries the key anywhere but WhatsApp's and Meta's own
        // https hosts; any other redirect is refused (the 3xx comes back as the answer).
        return URLSession(configuration: configuration, delegate: WhatsAppRedirectGuard(hosts: defaultMediaHosts), delegateQueue: nil)
    }

    // MARK: - The protocol

    public func check(key: String) async -> WhatsAppKeyCheck {
        let lane = LaneID(key: key, lane: .poll)
        await acquire(lane)
        defer { release(lane) }
        await waitForRoom(key, .poll)
        let request = makeRequest("GET", path: "updates", query: [URLQueryItem(name: "limit", value: "1"),
                                                                  URLQueryItem(name: "timeout", value: "0")],
                                  key: key, timeout: limits.callTimeout)
        switch await perform(request) {
        case .http(let status, let data):
            switch status {
            case 200, 204, 409: return .accepted
            case 401: return .refused
            case 400: return Self.errorCode(data) == 100 ? .refused : .unreachable
            default: return .unreachable
            }
        case .notSent, .unknown:
            return .unreachable
        }
    }

    public func poll(key: String, offset: Int64?, timeout: Int) async -> WhatsAppPoll {
        let lane = LaneID(key: key, lane: .poll)
        await acquire(lane)
        defer { release(lane) }
        await waitForRoom(key, .poll)
        let wait = min(max(timeout, 0), 25)
        var query: [URLQueryItem] = []
        if let offset { query.append(URLQueryItem(name: "offset", value: String(max(offset, 0)))) }
        query.append(URLQueryItem(name: "limit", value: "50"))
        query.append(URLQueryItem(name: "timeout", value: String(wait)))
        let request = makeRequest("GET", path: "updates", query: query, key: key, timeout: Double(wait) + limits.pollGrace)
        let id = WindowID(key: key, window: .poll)
        switch await perform(request) {
        case .http(200, let data):
            guard let parsed = Self.parseUpdates(data) else { return .backOff(seconds: grow(id)) }
            backOff[id] = nil
            return .messages(parsed.messages, next: parsed.next)
        case .http(204, _):
            backOff[id] = nil
            return .nothing
        case .http(409, _):
            backOff[id] = nil
            return .replaced
        case .http(401, _):
            return .keyRefused
        case .http(400, let data) where Self.errorCode(data) == 100:
            return .keyRefused
        case .http, .notSent, .unknown:
            // 429, 5xx, a malformed query or no connection: reuse the same offset after waiting.
            return .backOff(seconds: grow(id))
        }
    }

    public func markRead(key: String, messageID: String, typing: Bool) async -> WhatsAppSent {
        let lane = LaneID(key: key, lane: .out)
        await acquire(lane)
        defer { release(lane) }
        var body: [String: Any] = ["messaging_product": "whatsapp", "status": "read", "message_id": messageID]
        if typing { body["typing_indicator"] = ["type": "text"] }
        let id = WindowID(key: key, window: .status)
        var attempt = 0
        while true {
            attempt += 1
            // A read mark or a typing refresh that would wait for room is skipped, not queued behind the answer.
            if let wait = takeRoom(key, .status) { return .backOff(seconds: wait) }
            let request = makeRequest("POST", path: "statuses", body: body, key: key, timeout: limits.callTimeout)
            switch await perform(request) {
            case .http(let status, _) where (200..<300).contains(status):
                backOff[id] = nil
                return .sent
            case .http(401, _):
                return .keyRefused
            case .http(403, _):
                return .notCreator
            case .http(400, let data):
                let code = Self.errorCode(data)
                if code == 100 { return .keyRefused }
                return .failed("WhatsApp could not mark the message read" + Self.codeWords(400, code) + ".")
            case .http(let status, _) where status == 429 || status >= 500:
                break   // not marked (or unknown): marking read again is harmless, so retry after backing off
            case .http(let status, let data):
                return .failed("WhatsApp could not mark the message read" + Self.codeWords(status, Self.errorCode(data)) + ".")
            case .notSent, .unknown:
                break
            }
            let wait = grow(id)
            if attempt >= limits.statusAttempts { return .backOff(seconds: wait) }
            await clock.sleep(wait)
        }
    }

    public func send(key: String, to: String, text: String) async -> WhatsAppSent {
        // Only the creator ("user:<id>", copied from an inbound `from`) can be addressed; anything else never leaves.
        guard to.hasPrefix("user:"), to.count > "user:".count else { return .notCreator }
        guard !text.isEmpty else { return .failed("There was nothing to send.") }
        guard text.utf16.count <= WhatsAppText.limit else {
            return .failed("The message is longer than WhatsApp allows (\(WhatsAppText.limit) characters).")
        }
        let lane = LaneID(key: key, lane: .out)
        await acquire(lane)
        defer { release(lane) }
        let body: [String: Any] = ["messaging_product": "whatsapp", "to": to, "type": "text", "text": ["body": text]]
        let id = WindowID(key: key, window: .send)
        var attempt = 0
        while true {
            attempt += 1
            await waitForRoom(key, .send)
            let request = makeRequest("POST", path: "messages", body: body, key: key, timeout: limits.callTimeout)
            switch await perform(request) {
            case .http(let status, _) where (200..<300).contains(status):
                // Sent. Never retried.
                backOff[id] = nil
                return .sent
            case .http(429, _):
                break   // not sent: may be retried after backing off
            case .http(503, let data) where Self.errorCode(data) == 131016:
                break   // "not accepted for delivery": not sent, send again after backing off
            case .http(let status, _) where status >= 500:
                // 500 (or a 5xx the manual does not name): it may or may not have been sent.
                return .failed(Self.unknownWhetherSent)
            case .http(401, _):
                return .keyRefused
            case .http(403, _):
                return .notCreator
            case .http(400, let data):
                let code = Self.errorCode(data)
                if code == 100 {
                    // Code 100 is also a length cap; then the message names the field instead of a sentence.
                    return Self.isLengthCap(data)
                        ? .failed("WhatsApp said the message is too long.")
                        : .keyRefused
                }
                return .failed("WhatsApp refused the message" + Self.codeWords(400, code) + ".")
            case .http(let status, let data):
                return .failed("WhatsApp refused the message" + Self.codeWords(status, Self.errorCode(data)) + ".")
            case .unknown:
                return .failed(Self.unknownWhetherSent)
            case .notSent:
                break   // the request never left this computer: safe to try again
            }
            let wait = grow(id)
            if attempt >= limits.sendAttempts { return .backOff(seconds: wait) }
            await clock.sleep(wait)
        }
    }

    public func media(key: String, id mediaID: String, limit: Int) async -> WhatsAppMedia? {
        let most = min(limit, limits.largestMedia)
        guard most > 0, !mediaID.isEmpty else { return nil }
        let lane = LaneID(key: key, lane: .media)
        await acquire(lane)
        defer { release(lane) }
        // Media ids are opaque handles of letters, digits and dashes; anything else is not WhatsApp's and is not asked for.
        guard mediaID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) }),
              !mediaID.hasPrefix(".") else { return nil }
        await waitForRoom(key, .media)
        let metaRequest = makeRequest("GET", path: "media/" + mediaID, key: key, timeout: limits.callTimeout)
        guard case .http(200, let metaData) = await perform(metaRequest),
              let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any],
              let link = meta["url"] as? String, let url = URL(string: link), isAllowedMediaURL(url) else { return nil }
        if let size = Self.int64(meta["file_size"]), size > Int64(most) { return nil }
        await waitForRoom(key, .media)
        var download = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        download.httpMethod = "GET"
        download.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        guard case .http(200, let bytes) = await perform(download), !bytes.isEmpty, bytes.count <= most else { return nil }
        let mime = (meta["mime_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "application/octet-stream"
        return WhatsAppMedia(data: bytes, mimeType: mime, fileName: nil)
    }

    // MARK: - Lanes (one call at a time per key and lane, first come first served)

    private func acquire(_ lane: LaneID) async {
        if busy.contains(lane) {
            await withCheckedContinuation { waiting[lane, default: []].append($0) }
        } else {
            busy.insert(lane)
        }
    }

    /// Hands the lane straight to the next waiter (it stays busy) or frees it.
    private func release(_ lane: LaneID) {
        if var queue = waiting[lane], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[lane] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            busy.remove(lane)
        }
    }

    // MARK: - Rate windows (rolling 60 s per key and method) and back-off

    private func most(_ window: Window) -> Int {
        switch window {
        case .poll: return limits.pollsPerMinute
        case .send: return limits.sendsPerMinute
        case .status: return limits.statusesPerMinute
        case .media: return limits.mediaPerMinute
        }
    }

    /// Records a call if there is room now; otherwise the seconds until there is.
    private func takeRoom(_ key: String, _ window: Window) -> Double? {
        let id = WindowID(key: key, window: window)
        let now = clock.now()
        var recent = (calls[id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        if recent.count < most(window) {
            recent.append(now)
            calls[id] = recent
            return nil
        }
        calls[id] = recent
        return max(60 - now.timeIntervalSince(recent[0]), 0.001)
    }

    private func waitForRoom(_ key: String, _ window: Window) async {
        while let wait = takeRoom(key, window) { await clock.sleep(wait) }
    }

    /// The next back-off wait for this key and method: first, then doubled each time, capped.
    private func grow(_ id: WindowID) -> Double {
        let next = backOff[id].map { min($0 * 2, limits.longestBackOff) } ?? min(limits.firstBackOff, limits.longestBackOff)
        backOff[id] = next
        return next
    }

    // MARK: - HTTP

    private enum Outcome {
        case http(Int, Data)
        /// The request never left this computer (no network, no such host, could not connect, TLS refused).
        case notSent
        /// It may have reached WhatsApp (timeout, dropped connection, anything else).
        case unknown
    }

    private static let neverLeft: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
        .dataNotAllowed, .callIsActive, .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected, .appTransportSecurityRequiresSecureConnection,
    ]

    private func perform(_ request: URLRequest) async -> Outcome {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            return .http(http.statusCode, data)
        } catch let error as URLError {
            return Self.neverLeft.contains(error.code) ? .notSent : .unknown
        } catch {
            return .unknown
        }
    }

    private func makeRequest(_ method: String, path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                             key: String, timeout: Double) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    private func isAllowedMediaURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil else { return false }
        return mediaHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: - Parsing (static so tests can call it directly)

    /// `error.code` of an error body, when there is one.
    static func errorCode(_ data: Data) -> Int? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return Self.int64(error["code"]).map { Int($0) }
    }

    /// A length cap answers code 100 with the field name as the message ("text.body"), not a sentence.
    static func isLengthCap(_ data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = root["error"] as? [String: Any], let message = error["message"] as? String else { return false }
        let words = message.lowercased()
        return words.contains("body") || words.contains("caption") || !message.contains(" ")
    }

    static func codeWords(_ status: Int, _ code: Int?) -> String {
        code.map { " (HTTP \(status), code \($0))" } ?? " (HTTP \(status))"
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    /// A 200 from `GET /updates`: the messages in order and `next_offset`. Statuses (receipts) are skipped; a poll of
    /// only receipts gives no messages and still the next offset. nil = not WhatsApp's shape (treated as a failed poll).
    static func parseUpdates(_ data: Data) -> (messages: [WhatsAppInbound], next: Int64)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let next = nextOffset(data) ?? int64(root["next_offset"]) else { return nil }
        var messages: [WhatsAppInbound] = []
        for entry in root["entry"] as? [[String: Any]] ?? [] {
            for change in entry["changes"] as? [[String: Any]] ?? [] {
                let value = change["value"] as? [String: Any] ?? [:]
                for item in value["messages"] as? [[String: Any]] ?? [] {
                    if let message = inbound(item) { messages.append(message) }
                }
            }
        }
        return (messages, next)
    }

    /// `next_offset` read from the raw text, so a 64-bit value never passes through a Double.
    private static func nextOffset(_ data: Data) -> Int64? {
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #""next_offset"\s*:\s*-?[0-9]+"#, options: .regularExpression) else { return nil }
        let digits = text[range].drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
        return Int64(digits)
    }

    static func inbound(_ item: [String: Any]) -> WhatsAppInbound? {
        guard let id = item["id"] as? String, !id.isEmpty, let from = item["from"] as? String, !from.isEmpty else { return nil }
        let seconds: Double = (item["timestamp"] as? String).flatMap(Double.init) ?? (item["timestamp"] as? NSNumber)?.doubleValue ?? 0
        let type = item["type"] as? String ?? ""
        let kind = WhatsAppInbound.Kind(rawValue: type) ?? .other
        let payload = item[type] as? [String: Any] ?? [:]
        let carriesMedia: Set<WhatsAppInbound.Kind> = [.image, .audio, .video, .document, .sticker]
        return WhatsAppInbound(
            id: id, from: from, timestamp: Date(timeIntervalSince1970: seconds), kind: kind,
            text: kind == .text ? payload["body"] as? String : nil,
            caption: payload["caption"] as? String,
            mediaID: carriesMedia.contains(kind) ? payload["id"] as? String : nil,
            mimeType: carriesMedia.contains(kind) ? payload["mime_type"] as? String : nil,
            fileName: kind == .document ? payload["filename"] as? String : nil)
    }
}

/// Time for the transport: real by default, virtual in tests (so they never sleep).
public struct WhatsAppClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Double) async -> Void
    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Double) async -> Void) {
        self.now = now
        self.sleep = sleep
    }
    public static let system = WhatsAppClock(
        now: { Date() },
        sleep: { seconds in
            guard seconds > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        })
}

/// Follows a redirect only to https on WhatsApp's and Meta's own hosts (the media hosts); refuses every other one, so the
/// `Authorization` header is never sent anywhere else.
final class WhatsAppRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let hosts: [String]
    init(hosts: [String]) { self.hosts = hosts.map { $0.lowercased() } }
    static func allowed(_ url: URL?, hosts: [String]) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.allowed(request.url, hosts: hosts) ? request : nil)
    }
}
