import Foundation
import WebKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// One bounded HTTP operation. Redirects are stopped, returned to the caller
/// and followed only after a new exact-origin grant and a new cookie selection.
private final class NativeSafariCaptureBoundedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BackendBrowserAssetResponse, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var maximum = 0
    private var headersOnly = false
    private var prefixBytes: Int?
    private var cancelled = false
    private var completed = false
    func run(_ request: URLRequest, maximum: Int, headersOnly: Bool = false, prefixBytes: Int? = nil,
             timeoutSeconds: Double = 120) async throws -> BackendBrowserAssetResponse {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
                configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = min(30, timeoutSeconds); configuration.timeoutIntervalForResource = timeoutSeconds
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let shouldCancel = lock.withLock {
                    self.continuation = continuation; self.maximum = maximum; self.session = session; self.task = task
                    self.headersOnly = headersOnly; self.prefixBytes = prefixBytes
                    return cancelled
                }
                if shouldCancel { finish(.failure(CancellationError())) } else { task.resume() }
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        let operation = lock.withLock { cancelled = true; return task }
        operation?.cancel(); finish(.failure(CancellationError()))
    }
    private func finish(_ answer: Result<BackendBrowserAssetResponse, any Error>) {
        let result: (CheckedContinuation<BackendBrowserAssetResponse, any Error>?, URLSession?) = lock.withLock {
            guard !completed, continuation != nil else { return (nil, nil) }
            completed = true; let result = (continuation, session); continuation = nil; task = nil; session = nil; return result
        }
        result.1?.invalidateAndCancel(); result.0?.resume(with: answer)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // No cookies or redirects are allowed to escape the manual grant loop.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(NativeRPCError(code: "asset-response", message: "The asset response was not HTTP."))); return
        }
        let policy = lock.withLock {
            self.response = http
            return (headersOnly, response.expectedContentLength > Int64(maximum) && prefixBytes == nil && dataTask.originalRequest?.httpMethod != "HEAD")
        }
        if policy.0 {
            completionHandler(.cancel)
            finish(.success(Self.reply(http, body: Data(), complete: false))); return
        }
        let tooLarge = policy.1
        if tooLarge {
            completionHandler(.cancel); finish(.failure(NativeRPCError(code: "asset-too-large", message: "Asset Content-Length exceeds the explicit native fetch bound.")))
        } else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let policy: (Bool, HTTPURLResponse?, Data?) = lock.withLock {
            guard !completed else { return (false, nil, nil) }
            if let prefixBytes {
                body.append(data.prefix(max(0, prefixBytes - body.count)))
                return (false, body.count >= prefixBytes ? response : nil, body.count >= prefixBytes ? body : nil)
            }
            if body.count + data.count > maximum { return (true, nil, nil) }; body.append(data); return (false, nil, nil)
        }
        if policy.0 { dataTask.cancel(); finish(.failure(NativeRPCError(code: "asset-too-large", message: "Asset body exceeds the explicit native fetch bound; partial bytes are discarded."))) }
        else if let response = policy.1, let bytes = policy.2 { finish(.success(Self.reply(response, body: bytes, complete: false))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)); return }
        let reply = lock.withLock { (response, body, prefixBytes == nil && !headersOnly) }
        guard let response = reply.0, let url = response.url else { finish(.failure(NativeRPCError(code: "asset-response", message: "No HTTP response was received."))); return }
        if task.originalRequest?.httpMethod != "HEAD", reply.2,
           (response.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity",
           let stated = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), stated > reply.1.count {
            finish(.failure(NativeRPCError(code: "asset-truncated", message: "Only \(reply.1.count) bytes arrived of the \(stated) the server promised."))); return
        }
        _ = url
        finish(.success(Self.reply(response, body: reply.1, complete: reply.2)))
    }
    private static func reply(_ response: HTTPURLResponse, body: Data, complete: Bool) -> BackendBrowserAssetResponse {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields { if let key = name as? String { headers[key] = String(describing: value) } }
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        return .init(finalURL: response.url!, status: response.statusCode, headers: headers, body: body, complete: complete,
            image: NativeSafariCaptureAssetQuality.image(body, complete: complete, contentType: contentType))
    }
}

/// Native authenticated asset transport. Init is inert. The store resolver must
/// return the SAME app-owned WKWebsiteDataStore as the granted profile's tabs.
@MainActor
final class NativeSafariCaptureAssetFetch {
    private let store: @MainActor (String) throws -> WKWebsiteDataStore
    private let authorize: BackendBrowserScrapingAuthorize
    init(store: @escaping @MainActor (String) throws -> WKWebsiteDataStore, authorize: @escaping BackendBrowserScrapingAuthorize) {
        self.store = store; self.authorize = authorize
    }
    func fetch(caller: BackendBrowserScrapingCaller, profileID: String, url: URL, method: String, maximumBytes: Int) async throws -> BackendBrowserAssetResponse {
        try await request(caller: caller, profileID: profileID, url: url, method: method, maximumBytes: maximumBytes)
    }
    /// HEAD first, then an immediately cancelled one-byte range when HEAD is
    /// forbidden/unsupported/missing a length. Optional image measurement reads
    /// at most a 256 KiB prefix and never renders or rewrites the image bytes.
    func probe(caller: BackendBrowserScrapingCaller, profileID: String, url: URL, dimensions: Bool) async throws -> BackendBrowserRenditionProbe? {
        func once(method: String, range: String?, prefix: Int?) async throws -> BackendBrowserAssetResponse? {
            do {
                return try await request(caller: caller, profileID: profileID, url: url, method: method, maximumBytes: prefix ?? 1,
                    range: range, headersOnly: method == "GET" && prefix == nil, prefixBytes: prefix,
                    timeoutSeconds: 8, operation: "assets.probe.transport")
            } catch is CancellationError { throw CancellationError() }
            catch let error as NativeRPCError where error.code == "access-denied" { throw error }
            catch { try Task.checkCancellation(); return nil }
        }
        func length(_ response: BackendBrowserAssetResponse, ranged: Bool) -> Int? {
            if ranged, let range = response.header("content-range"), let tail = range.split(separator: "/").last,
               let value = Int(tail.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 { return value }
            if ranged, let range = response.header("content-range"), !range.isEmpty { return nil }
            guard let raw = response.header("content-length"), let value = Int(raw), value >= 0,
                  !ranged || value > 1 else { return nil }
            return value
        }
        func value(_ response: BackendBrowserAssetResponse, ranged: Bool, method: String) -> BackendBrowserRenditionProbe {
            .init(status: response.status == 206 ? 200 : response.status, bytes: length(response, ranged: ranged),
                contentType: (response.header("content-type") ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? "",
                image: response.image, method: method, finalURL: response.finalURL)
        }
        let head = try await once(method: "HEAD", range: nil, prefix: nil)
        let headValue = head.map { value($0, ranged: false, method: "HEAD") }
        let fallback = headValue == nil || [403, 405, 501].contains(headValue!.status) || (200..<300).contains(headValue!.status) && headValue!.bytes == nil
        if fallback || dimensions {
            let prefix = dimensions ? 262_144 : nil
            let response = try await once(method: "GET", range: dimensions ? "bytes=0-262143" : "bytes=0-0", prefix: prefix)
            if let response {
                let probe = value(response, ranged: true, method: dimensions ? "GET-range-prefix" : "GET-range-headers")
                if fallback { return probe }
                if (200..<300).contains(probe.status), let base = headValue {
                    return .init(status: base.status, bytes: base.bytes ?? probe.bytes, contentType: base.contentType.isEmpty ? probe.contentType : base.contentType,
                                 image: probe.image, method: "HEAD+GET-range-prefix", finalURL: probe.finalURL)
                }
            }
        }
        return headValue
    }
    private func request(caller: BackendBrowserScrapingCaller, profileID: String, url: URL, method: String, maximumBytes: Int,
                         range: String? = nil, headersOnly: Bool = false, prefixBytes: Int? = nil,
                         timeoutSeconds: Double = 120, operation: String = "assets.fetch.transport") async throws -> BackendBrowserAssetResponse {
        guard ["GET", "HEAD"].contains(method), ["https", "http"].contains(url.scheme ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              (1...64 * 1_024 * 1_024).contains(maximumBytes) else { throw NativeRPCError.invalidArguments("Use a bounded GET/HEAD against an exact HTTP(S) profile origin.") }
        try await authorize(caller, operation, profileID, url, .object([]))
        let website: WKWebsiteDataStore?
        if profileID == BackendBrowserAssetHooks.publicProfileID { website = nil }
        else { website = try store(profileID) }
        var current = url
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        for redirect in 0...8 {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw NativeRPCError(code: "asset-timeout", message: "The native request exhausted its \(Int(timeoutSeconds)) second deadline, including redirects.") }
            try await authorize(caller, operation, profileID, current, .object([]))
            let cookies: [HTTPCookie]
            if let website {
                cookies = await withCheckedContinuation { continuation in website.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
            } else { cookies = [] }
            var request = URLRequest(url: current); request.httpMethod = method; request.timeoutInterval = remaining
            request.httpShouldHandleCookies = false
            // Keep response lengths comparable to saved asset bytes whenever
            // the server supports identity coding. HTTP decoding is still the
            // platform's behavior; no image transform is ever applied.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            let applicable = cookies.filter { cookie in
                guard let host = current.host?.lowercased() else { return false }
                let domain = cookie.domain.lowercased(), base = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
                let domainMatches = host == base || domain.hasPrefix(".") && host.hasSuffix("." + base)
                let path = current.path.isEmpty ? "/" : current.path
                let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
                let pathMatches = path == cookiePath || path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).first == "/")
                return domainMatches && pathMatches && (!cookie.isSecure || current.scheme == "https") && (cookie.expiresDate.map { $0 > Date() } ?? true)
            }.sorted { $0.path.count > $1.path.count }
            for (key, value) in HTTPCookie.requestHeaderFields(with: applicable) { request.setValue(value, forHTTPHeaderField: key) }
            // Check again after the asynchronous cookie read, before the bytes
            // (which may include HttpOnly cookies) ever leave the process.
            try await authorize(caller, operation, profileID, current, .object([]))
            let socketRemaining = deadline - ProcessInfo.processInfo.systemUptime
            guard socketRemaining > 0 else { throw NativeRPCError(code: "asset-timeout", message: "The native request deadline expired before the socket opened.") }
            let response = try await NativeSafariCaptureBoundedRequest().run(request, maximum: maximumBytes, headersOnly: headersOnly,
                                                                           prefixBytes: prefixBytes, timeoutSeconds: socketRemaining)
            try await authorize(caller, operation, profileID, current, .object([]))
            let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: response.headers, for: current)
            for cookie in responseCookies where website != nil {
                // A sibling-domain grant is not implied by a Domain attribute.
                let base = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                guard current.host?.lowercased() == base.lowercased() || current.host?.lowercased().hasSuffix("." + base.lowercased()) == true else { continue }
                try await authorize(caller, "assets.fetch.cookie-response", profileID, current, .object([]))
                if let website {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        website.httpCookieStore.setCookie(cookie) { continuation.resume() }
                    }
                }
            }
            if [301, 302, 303, 307, 308].contains(response.status), let location = response.header("location") {
                guard redirect < 8, let next = URL(string: location, relativeTo: current)?.absoluteURL,
                      ["http", "https"].contains(next.scheme ?? ""), next.host != nil, next.user == nil, next.password == nil else {
                    throw NativeRPCError(code: "asset-redirect", message: "Asset redirect is invalid or exceeds eight hops.")
                }
                guard current.scheme != "https" || next.scheme == "https" else {
                    throw NativeRPCError(code: "asset-redirect", message: "Authenticated asset redirects may not downgrade HTTPS to HTTP.")
                }
                try await authorize(caller, operation, profileID, next, .object([])); current = next; continue
            }
            return response
        }
        throw NativeRPCError(code: "asset-redirect", message: "Asset redirects exceeded the native bound.")
    }
}
