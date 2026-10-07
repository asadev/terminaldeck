import Foundation
import WebKit
import TerminalDeckNativeCore

/// Browser data belongs to the app's existing WebKit stores. Creating a store
/// in a helper process, or using Foundation's shared cookie jar, would operate
/// on somebody else's login state.
@MainActor
final class NativeBrowserDataBridge {
    /// The native graph injects its required live authorization for every fetch.
    private let tabs: NativeBrowserTabs
    private let authorizeFetch: @MainActor (String, URL, String) async throws -> Void
    init(tabs: NativeBrowserTabs,
         authorizeFetch: @escaping @MainActor (String, URL, String) async throws -> Void) {
        self.tabs = tabs; self.authorizeFetch = authorizeFetch
    }

    private struct Refusal: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var isolatedTabs: [String: String] = [:]
    private struct Fetch { let partition: String; let session: URLSession; let task: Task<NativeRPCValue, Error> }
    private var fetches: [String: Fetch] = [:]
    private var operations: [UUID: (partition: String, task: Task<NativeRPCValue, Error>)] = [:]
    private var blockedPartitions: Set<String> = []
    private var closed = false
    private let maximumBodyBytes = 16 * 1024 * 1024

    func handle(_ operation: String, _ args: [String: Any]) async throws -> Any {
        guard !closed else { throw Refusal(message: "The app-owned browser data bridge has shut down.") }
        if operation == "browser-data:fetch-cancel" {
            if let id = args["fetchID"] as? String { fetches[id]?.task.cancel(); fetches[id]?.session.invalidateAndCancel() }
            return NSNull()
        }
        let partition = try text(args, "partition")
        guard !blockedPartitions.contains(partition) else { throw Refusal(message: "This browser profile is being retired.") }
        if operation == "browser-data:bind-isolated" {
            try bindIsolatedPartition(partition, to: text(args, "tabId"))
            return NSNull()
        }
        let store = try store(for: partition)
        let id = UUID()
        let task = Task { try NativeRPCValue.fromFoundation(try await self.perform(operation, args, store: store)) }
        operations[id] = (partition, task)
        defer { operations[id] = nil }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        return result.foundation ?? NSNull()
    }

    private func perform(_ operation: String, _ args: [String: Any], store: WKWebsiteDataStore) async throws -> Any {
        try Task.checkCancellation()
        switch operation {
        case "browser-data:cookies:get":
            let filter = args["filter"] as? [String: Any] ?? [:]
            let cookies = await allCookies(store)
            return cookies.filter { matches($0, filter: filter) }.map(cookieJSON)
        case "browser-data:cookies:set":
            guard let details = args["details"] as? [String: Any] else { throw Refusal(message: "Cookie details are missing.") }
            try await setCookie(details, store: store)
            return NSNull()
        case "browser-data:cookies:remove":
            let url = try webURL(text(args, "url")), name = try text(args, "name", allowEmpty: true)
            for cookie in await allCookies(store) where cookie.name == name && applies(cookie, to: url) {
                await deleteCookie(cookie, store: store)
            }
            return NSNull()
        case "browser-data:cookies:flush":
            throw Refusal(message: "Safari/WebKit has no public cookie disk-flush API. Cookie changes completed in the live store; forced disk persistence cannot be confirmed.")
        case "browser-data:clear-cache":
            await removeData(store, types: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])
            return NSNull()
        case "browser-data:clear-storage":
            try await clearStorage(store, options: args["options"] as? [String: Any] ?? [:])
            return NSNull()
        case "browser-data:cache-size", "browser-data:storage-path":
            // These are unknown, never a fabricated zero or the engine folder.
            return NSNull()
        case "browser-data:fetch": return try await fetch(args, store: store)
        default: throw Refusal(message: "The native browser does not support operation '\(operation)'.")
        }
    }

    func bindIsolatedPartition(_ partition: String, to tabID: String) throws {
        guard partition.hasPrefix("terminaldeck-tab-"), UUID(uuidString: String(partition.dropFirst("terminaldeck-tab-".count))) != nil,
              let tab = tabs.tab(tabID), tab.isolated,
              let view = tab.webView, !view.configuration.websiteDataStore.isPersistent else {
            throw Refusal(message: "An isolated partition must be bound to its exact live isolated Safari tab.")
        }
        if let current = isolatedTabs[partition], current != tabID {
            throw Refusal(message: "This isolated partition already belongs to another live tab.")
        }
        isolatedTabs[partition] = tabID
    }

    private func store(for partition: String) throws -> WKWebsiteDataStore {
        let prefix = "persist:terminaldeck-browser"
        if partition == prefix { return tabs.store(for: "") }
        if partition.hasPrefix(prefix + "-") {
            let profile = String(partition.dropFirst((prefix + "-").count))
            guard UUID(uuidString: profile) != nil else { throw Refusal(message: "That is not a Safari browser-profile partition.") }
            return tabs.store(for: profile.lowercased())
        }
        guard let tabID = isolatedTabs[partition], let tab = tabs.tab(tabID),
              tab.isolated, let view = tab.webView, !view.configuration.websiteDataStore.isPersistent else {
            throw Refusal(message: "This partition is not bound to an exact live isolated Safari tab. No separate cookie jar was created.")
        }
        return view.configuration.websiteDataStore
    }

    private func text(_ args: [String: Any], _ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = args[key] as? String, allowEmpty || !value.isEmpty else { throw Refusal(message: "Browser-data request is missing '\(key)'.") }
        return value
    }

    private func webURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw Refusal(message: "Browser data needs an HTTP or HTTPS URL without embedded credentials.")
        }
        return url
    }

    private func allCookies(_ store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func putCookie(_ cookie: HTTPCookie, store: WKWebsiteDataStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    private func deleteCookie(_ cookie: HTTPCookie, store: WKWebsiteDataStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.delete(cookie) { continuation.resume() }
        }
    }

    private func normalizedDomain(_ value: String) -> String {
        var value = value.lowercased()
        while value.hasPrefix(".") { value.removeFirst() }
        return value
    }

    private func applies(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host?.lowercased(), cookie.expiresDate.map({ $0 > Date() }) ?? true else { return false }
        let domain = normalizedDomain(cookie.domain)
        guard host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain)) else { return false }
        if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path == cookie.path || (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
    }

    private func matches(_ cookie: HTTPCookie, filter: [String: Any]) -> Bool {
        if let url = filter["url"] as? String {
            guard let parsed = try? webURL(url), applies(cookie, to: parsed) else { return false }
        }
        if let wanted = filter["domain"] as? String {
            let domain = normalizedDomain(cookie.domain), wanted = normalizedDomain(wanted)
            guard domain == wanted || domain.hasSuffix("." + wanted) else { return false }
        }
        if let name = filter["name"] as? String, cookie.name != name { return false }
        if let path = filter["path"] as? String, cookie.path != path { return false }
        if let secure = filter["secure"] as? Bool, cookie.isSecure != secure { return false }
        if let httpOnly = filter["httpOnly"] as? Bool, cookie.isHTTPOnly != httpOnly { return false }
        if let session = filter["session"] as? Bool, cookie.isSessionOnly != session { return false }
        return true
    }

    private func cookieJSON(_ cookie: HTTPCookie) -> [String: Any] {
        var result: [String: Any] = [
            "name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
            "secure": cookie.isSecure, "httpOnly": cookie.isHTTPOnly, "session": cookie.isSessionOnly,
            "hostOnly": !cookie.domain.hasPrefix("."),
        ]
        if let date = cookie.expiresDate { result["expirationDate"] = date.timeIntervalSince1970 }
        switch cookie.sameSitePolicy?.rawValue.lowercased() {
        case "lax": result["sameSite"] = "lax"
        case "strict": result["sameSite"] = "strict"
        case "none": result["sameSite"] = "no_restriction"
        default: result["sameSite"] = "unspecified"
        }
        return result
    }

    private func setCookie(_ details: [String: Any], store: WKWebsiteDataStore) async throws {
        let url = try webURL(text(details, "url"))
        let name = try text(details, "name", allowEmpty: true), value = try text(details, "value", allowEmpty: true)
        guard !name.contains(where: { $0.isNewline || $0 == ";" || $0 == "=" }),
              !value.contains(where: { $0.isNewline || $0 == ";" }) else { throw Refusal(message: "The cookie contains invalid characters.") }
        let path = details["path"] as? String ?? "/"
        guard path.hasPrefix("/") else { throw Refusal(message: "A cookie path must start with '/'.") }
        var properties: [HTTPCookiePropertyKey: Any] = [.originURL: url, .name: name, .value: value, .path: path]
        if let domain = details["domain"] as? String {
            let domainHost = normalizedDomain(domain), host = url.host!.lowercased()
            guard !domainHost.isEmpty, host == domainHost || host.hasSuffix("." + domainHost) else {
                throw Refusal(message: "The cookie domain does not match its URL.")
            }
            // Electron treats an explicit domain as a domain cookie.
            properties[.domain] = "." + domainHost
        }
        let secure = details["secure"] as? Bool ?? (url.scheme?.lowercased() == "https")
        if secure { properties[.secure] = "TRUE" }
        if details["httpOnly"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expiry = (details["expirationDate"] as? NSNumber)?.doubleValue {
            guard expiry.isFinite else { throw Refusal(message: "The cookie expiration date is invalid.") }
            properties[.expires] = Date(timeIntervalSince1970: expiry)
        } else { properties[.discard] = "TRUE" }
        if let sameSite = details["sameSite"] as? String {
            switch sameSite {
            case "lax", "strict": properties[.sameSitePolicy] = sameSite
            case "no_restriction":
                guard secure else { throw Refusal(message: "A SameSite=None cookie must be Secure.") }
                properties[.sameSitePolicy] = "none"
            case "unspecified": break
            default: throw Refusal(message: "The cookie SameSite policy is invalid.")
            }
        }
        guard let cookie = HTTPCookie(properties: properties) else { throw Refusal(message: "macOS rejected the cookie attributes.") }
        guard cookie.isHTTPOnly == (details["httpOnly"] as? Bool ?? false), cookie.isSecure == secure else {
            throw Refusal(message: "macOS cannot represent the requested cookie security attributes. The cookie was not written.")
        }
        let requestedSite = details["sameSite"] as? String
        if let requestedSite, requestedSite != "unspecified" {
            let actualSite = cookie.sameSitePolicy?.rawValue.lowercased()
            let expectedSite = requestedSite == "no_restriction" ? "none" : requestedSite
            guard actualSite == expectedSite else { throw Refusal(message: "macOS cannot represent the requested SameSite cookie policy. The cookie was not written.") }
        }
        try Task.checkCancellation()
        await putCookie(cookie, store: store)
        try Task.checkCancellation()
        if cookie.expiresDate.map({ $0 <= Date() }) == true { return }
        let saved = await allCookies(store)
        guard saved.contains(where: { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path && $0.value == cookie.value && $0.isHTTPOnly == cookie.isHTTPOnly && $0.isSecure == cookie.isSecure && (requestedSite == nil || requestedSite == "unspecified" || $0.sameSitePolicy?.rawValue.lowercased() == cookie.sameSitePolicy?.rawValue.lowercased()) }) else {
            throw Refusal(message: "Safari did not retain the cookie with the requested attributes.")
        }
    }

    private func removeData(_ store: WKWebsiteDataStore, types: Set<String>) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) { continuation.resume() }
        }
    }

    private func clearStorage(_ store: WKWebsiteDataStore, options: [String: Any]) async throws {
        if options["origin"] != nil && !(options["origin"] is NSNull) {
            // WKWebsiteDataRecord identifies a displayed site, not an exact
            // origin. Matching it would delete unrelated schemes or ports.
            throw Refusal(message: "Safari cannot clear an exact scheme/host/port using its public data-store API. Clear the whole selected profile, or use the site's own controls.")
        }
        if options["origins"] != nil || options["excludeOrigins"] != nil || options["quotas"] != nil {
            throw Refusal(message: "Safari cannot apply those Chromium storage filters. No browser data was cleared.")
        }
        guard let requested = options["storages"] as? [String] else {
            await removeData(store, types: WKWebsiteDataStore.allWebsiteDataTypes())
            return
        }
        let types: [String: Set<String>] = [
            "cookies": [WKWebsiteDataTypeCookies], "filesystem": [WKWebsiteDataTypeFileSystem],
            "indexdb": [WKWebsiteDataTypeIndexedDBDatabases],
            "localstorage": [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage],
            "websql": [WKWebsiteDataTypeWebSQLDatabases],
            "serviceworkers": [WKWebsiteDataTypeServiceWorkerRegistrations],
            "cachestorage": [WKWebsiteDataTypeFetchCache],
            // A Chromium shader cache has no counterpart in this WebKit store.
            "shadercache": [],
        ]
        var selected = Set<String>()
        for kind in requested {
            guard let mapped = types[kind] else { throw Refusal(message: "Safari does not recognize storage type '\(kind)'. No browser data was cleared.") }
            selected.formUnion(mapped)
        }
        if !selected.isEmpty { await removeData(store, types: selected) }
    }

    private func applyResponseCookies(_ response: HTTPURLResponse, store: WKWebsiteDataStore, partition: String) async throws {
        guard let url = response.url else { return }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields { fields[String(describing: key)] = String(describing: value) }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            let domain = normalizedDomain(cookie.domain), host = url.host?.lowercased() ?? ""
            guard host == domain || host.hasSuffix("." + domain) else { continue }
            try Task.checkCancellation()
            guard !closed, !blockedPartitions.contains(partition) else { throw CancellationError() }
            try await authorizeFetch(partition, url, "browser-data:fetch-cookie-response")
            await putCookie(cookie, store: store)
        }
    }

    private func fetch(_ args: [String: Any], store: WKWebsiteDataStore) async throws -> [String: Any] {
        let partition = try text(args, "partition")
        let id = try text(args, "fetchID")
        guard fetches[id] == nil else { throw Refusal(message: "This browser fetch is already running.") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 110
        let session = URLSession(configuration: config, delegate: BrowserFetchNoRedirect(), delegateQueue: nil)
        let task = Task { try NativeRPCValue.fromFoundation(try await self.fetchBody(args, store: store, partition: partition, session: session)) }
        fetches[id] = .init(partition: partition, session: session, task: task)
        defer { session.invalidateAndCancel(); fetches[id] = nil }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel(); session.invalidateAndCancel() }
        guard let result = value.foundation as? [String: Any] else { throw Refusal(message: "The browser fetch did not return an object.") }
        return result
    }

    /// Stops accepted requests and waits for cookie callbacks before a profile
    /// clear. The tombstone stays in place; recreating the graph is explicit.
    func cancel(partition: String) async {
        blockedPartitions.insert(partition)
        let accepted = operations.values.filter { $0.partition == partition }
        for operation in accepted { operation.task.cancel() }
        let pending = fetches.values.filter { $0.partition == partition }
        for fetch in pending { fetch.task.cancel(); fetch.session.invalidateAndCancel() }
        for fetch in pending { _ = try? await fetch.task.value }
        for operation in accepted { _ = try? await operation.task.value }
    }
    func shutdown() async {
        closed = true
        let accepted = Array(operations.values)
        for operation in accepted { operation.task.cancel() }
        let pending = Array(fetches.values)
        for fetch in pending { fetch.task.cancel(); fetch.session.invalidateAndCancel() }
        for fetch in pending { _ = try? await fetch.task.value }
        for operation in accepted { _ = try? await operation.task.value }
        fetches.removeAll(); isolatedTabs.removeAll()
    }

    private func fetchBody(_ args: [String: Any], store: WKWebsiteDataStore, partition: String, session: URLSession) async throws -> [String: Any] {
        var url = try webURL(text(args, "url"))
        let initialURL = url
        var method = (args["method"] as? String ?? "GET").uppercased()
        guard method.range(of: "^[A-Z]+$", options: .regularExpression) != nil else { throw Refusal(message: "The HTTP method is invalid.") }
        var body: Data?
        if let encoded = args["bodyBase64"] as? String {
            guard let decoded = Data(base64Encoded: encoded), decoded.count <= maximumBodyBytes else { throw Refusal(message: "The browser request body is invalid or exceeds 16 MiB.") }
            body = decoded
        }
        var headers = args["headers"] as? [String: String] ?? [:]
        headers = headers.filter { !["cookie", "host", "content-length"].contains($0.key.lowercased()) }
        let redirect = args["redirect"] as? String ?? "follow"
        let credentials = args["credentials"] as? String ?? "include"
        for hop in 0...10 {
            try Task.checkCancellation()
            guard !closed, !blockedPartitions.contains(partition) else { throw CancellationError() }
            try await authorizeFetch(partition, url, "browser-data:fetch-hop")
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.allHTTPHeaderFields = headers
            let useCookies = credentials != "omit" && (credentials != "same-origin" || origin(url) == origin(initialURL))
            if useCookies {
                let cookies = await allCookies(store).filter { applies($0, to: url) }.sorted { $0.path.count > $1.path.count }
                if !cookies.isEmpty { request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
            }
            let (bytes, rawResponse) = try await session.bytes(for: request)
            guard let response = rawResponse as? HTTPURLResponse else { throw Refusal(message: "The server did not return an HTTP response.") }
            if useCookies { try await applyResponseCookies(response, store: store, partition: partition) }
            if [301, 302, 303, 307, 308].contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"), redirect != "manual" {
                if redirect == "error" { throw Refusal(message: "This browser fetch refused a redirect.") }
                guard hop < 10, let next = URL(string: location, relativeTo: url)?.absoluteURL else { throw Refusal(message: "The browser fetch exceeded its redirect limit or received an invalid redirect.") }
                let checked = try webURL(next.absoluteString)
                if url.scheme?.lowercased() == "https", checked.scheme?.lowercased() != "https" { throw Refusal(message: "The browser fetch refused an HTTPS downgrade.") }
                if origin(checked) != origin(url) { headers = headers.filter { !["authorization", "proxy-authorization"].contains($0.key.lowercased()) } }
                if response.statusCode == 303 && method != "HEAD" || ([301, 302].contains(response.statusCode) && method == "POST") {
                    method = "GET"; body = nil
                    headers = headers.filter { !["content-type", "content-encoding"].contains($0.key.lowercased()) }
                }
                // Consume a bounded redirect body so this hop releases its connection.
                var discarded = 0
                for try await _ in bytes { discarded += 1; if discarded > maximumBodyBytes { throw Refusal(message: "The redirect response exceeds the native browser's 16 MiB limit.") } }
                url = checked
                continue
            }
            if method != "HEAD", response.expectedContentLength > maximumBodyBytes { throw Refusal(message: "This response exceeds the native browser's 16 MiB fetch limit. Use Safari's download action for larger files.") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBodyBytes else { throw Refusal(message: "This response exceeds the native browser's 16 MiB fetch limit. Use Safari's download action for larger files.") }
                data.append(byte)
            }
            var responseHeaders: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                let name = String(describing: key)
                if name.lowercased() != "set-cookie" { responseHeaders[name] = String(describing: value) }
            }
            // URLSession may decode a compressed response. Report the bytes
            // actually returned, rather than a stale compressed content length.
            if method != "HEAD" {
                for key in responseHeaders.keys where ["content-encoding", "content-length"].contains(key.lowercased()) { responseHeaders[key] = nil }
                responseHeaders["Content-Length"] = String(data.count)
            }
            return ["status": response.statusCode, "statusText": HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                    "headers": responseHeaders, "bodyBase64": data.base64EncodedString(),
                    "url": response.url?.absoluteString ?? url.absoluteString, "redirected": hop > 0]
        }
        throw Refusal(message: "The browser fetch exceeded its redirect limit.")
    }

    private func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }
}

private final class BrowserFetchNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The MainActor bridge reapplies the correct WebKit cookies per hop.
        completionHandler(nil)
    }
}
