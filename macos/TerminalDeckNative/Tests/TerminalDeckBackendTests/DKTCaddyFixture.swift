import Foundation

/// Caddy's JSON administration surface, confined to the shared temporary Unix
/// HTTP server. No Caddy binary, TCP listener, certificate service, or real DNS.
/// Semantics: https://caddyserver.com/docs/api . Module validation covers only
/// the HTTP structures Apps uses; this fixture is not a Caddy provisioning test.
final class DKTFakeCaddy: @unchecked Sendable {
    static let protectedDemoRouteID = "178-105-239-176.sslip.io"

    /// Synthetic sentinel only. Its address is never contacted by this fixture.
    static func protectedDemo(strictAdminHost: Bool = false) throws -> DKTFakeCaddy {
        let config = DKTCaddyJSON.object([
            "admin": .object(["listen": .string("127.0.0.1:2019")]),
            "apps": .object(["http": .object(["servers": .object([
                "terminaldeck": .object([
                    "listen": .array([.string(":443")]),
                    "routes": .array([.object([
                        "@id": .string(protectedDemoRouteID),
                        "match": .array([.object(["host": .array([.string(protectedDemoRouteID)])])]),
                        "handle": .array([.object([
                            "handler": .string("reverse_proxy"),
                            "upstreams": .array([.object(["dial": .string("protected-demo:8080")])])
                        ])])
                    ])])
                ])
            ])])])
        ])
        return try DKTFakeCaddy(initialConfig: config.encoded(), strictAdminHost: strictAdminHost)
    }

    private let state: DKTCaddyState
    let server: DKTUnixHTTPServer

    init(initialConfig: Data = Data("{}".utf8), socketPath: String? = nil, strictAdminHost: Bool = false) throws {
        let config = try DKTCaddyJSON(data: initialConfig)
        try config.validateConfig()
        let state = DKTCaddyState(config: config, strictAdminHost: strictAdminHost)
        self.state = state
        server = DKTUnixHTTPServer(socketPath: socketPath) { request in state.respond(to: request) }
    }

    var socketPath: String { server.socketPath }
    var requests: [DKTHTTPRequest] { state.lock.withLock { state.requests } }
    var configuration: DKTCaddyJSON { state.lock.withLock { state.config } }
    var persistedConfiguration: DKTCaddyJSON { state.lock.withLock { state.persistedConfig } }
    var successfulWriteCount: Int { state.lock.withLock { state.successfulWriteCount } }
    var activeConnectionCount: Int { server.activeConnectionCount }
    func start() throws { try server.start() }
    func stop() { server.stop() }
    func configSnapshot() throws -> Data { try configuration.encoded() }
    func persistedSnapshot() throws -> Data { try persistedConfiguration.encoded() }
    func suppressNextAutosave(count: Int = 1) { state.lock.withLock { state.skippedAutosaves = max(0, count) } }

    /// A production HTTP callback may use this to inject the same handler
    /// without opening any socket. Such a test covers the HTTP/API boundary,
    /// not the Unix transport; use socketPath when exercising transport itself.
    func respond(to request: DKTHTTPRequest) -> DKTHTTPResponse { state.respond(to: request) }

    /// Matched responses happen before parsing or changing active config.
    /// A nil method or path matches any; rules are consumed in insertion order.
    func failNext(method: String? = nil, path: String? = nil, statusCode: Int = 503,
                  message: String = "Injected Caddy failure", count: Int = 1, afterMatchingRequests: Int = 0) {
        guard count > 0 else { return }
        state.lock.withLock {
            state.failures.append(.init(method: method?.uppercased(), path: path,
                                        remaining: count, skip: max(0, afterMatchingRequests),
                                        statusCode: statusCode, message: message))
        }
    }
}

private final class DKTCaddyState: @unchecked Sendable {
    let lock = NSLock()
    var config: DKTCaddyJSON
    var persistedConfig: DKTCaddyJSON
    var skippedAutosaves = 0
    let strictAdminHost: Bool
    var requests: [DKTHTTPRequest] = []
    var successfulWriteCount = 0
    var failures: [DKTCaddyFailure] = []

    init(config: DKTCaddyJSON, strictAdminHost: Bool) {
        self.config = config; persistedConfig = config; self.strictAdminHost = strictAdminHost
    }

    func respond(to request: DKTHTTPRequest) -> DKTHTTPResponse {
        lock.withLock {
            requests.append(request)
            // A Unix listener itself does not require Caddy Host enforcement.
            // This optional mode emulates the real localhost:2019 TCP admin
            // behind the production SSH tunnel, while still using no TCP here.
            if strictAdminHost {
                let host = request.headers.first { $0.key.lowercased() == "host" }?.value.lowercased()
                guard ["localhost:2019", "127.0.0.1:2019", "[::1]:2019"].contains(host ?? "") else {
                    return error(403, "Caddy admin Host is not trusted")
                }
            }
            let method = request.method.uppercased()
            let rawPath = String(request.target.split(separator: "?", maxSplits: 1,
                                                       omittingEmptySubsequences: false)[0])
            if let index = failures.firstIndex(where: {
                ($0.method == nil || $0.method == method) && ($0.path == nil || $0.path == rawPath)
            }) {
                let failure = failures[index]
                if failure.skip > 0 { failures[index].skip -= 1 }
                else {
                    failures[index].remaining -= 1
                    if failures[index].remaining == 0 { failures.remove(at: index) }
                    return error(failure.statusCode, failure.message)
                }
            }
            do {
                if rawPath == "/load" {
                    guard method == "POST" else { throw DKTCaddyConfigError(405, "method is not allowed") }
                    let candidate = try payload(request)
                    try candidate.validateConfig()
                    config = candidate
                    publishAutosave(candidate)
                    successfulWriteCount += 1
                    return DKTHTTPResponse()
                }

                let components = try route(rawPath)
                let resolvedPath = "/config/" + components.joined(separator: "/")
                if method == "GET" {
                    let value = try config.value(at: components)
                    return DKTHTTPResponse(headers: ["Content-Type": "application/json",
                                                      "Etag": try etag(path: resolvedPath, value: value)],
                                           body: try value.encoded())
                }
                guard ["POST", "PUT", "PATCH", "DELETE"].contains(method) else {
                    throw DKTCaddyConfigError(405, "method is not allowed")
                }
                if let precondition = header("if-match", in: request) {
                    try validatePrecondition(precondition)
                }
                let body = method == "DELETE" ? DKTCaddyJSON.null : try payload(request)
                let candidate = try config.changing(method: method, path: components, payload: body)
                try candidate.validateConfig()
                // Build a new tree, validate it, then publish once. No partial
                // changes escape if parsing, traversal, or validation fails.
                config = candidate
                publishAutosave(candidate)
                successfulWriteCount += 1
                return DKTHTTPResponse()
            } catch let failure as DKTCaddyConfigError {
                return error(failure.statusCode, failure.message)
            } catch {
                return self.error(400, "Caddy config is not valid JSON")
            }
        }
    }

    private func publishAutosave(_ candidate: DKTCaddyJSON) {
        if skippedAutosaves > 0 { skippedAutosaves -= 1 }
        else { persistedConfig = candidate }
    }

    private func payload(_ request: DKTHTTPRequest) throws -> DKTCaddyJSON {
        guard let contentType = header("content-type", in: request),
              contentType.lowercased().contains("/json") else {
            throw DKTCaddyConfigError(400, "application/json content type is required")
        }
        return try DKTCaddyJSON(data: request.body)
    }

    private func route(_ rawPath: String) throws -> [String] {
        guard rawPath.hasPrefix("/") else { throw DKTCaddyConfigError(400, "invalid request path") }
        var components = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        components.removeFirst()
        if components.last == "" { components.removeLast() }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DKTCaddyConfigError(400, "invalid request path")
        }
        components = try components.map {
            guard let decoded = $0.removingPercentEncoding, !decoded.contains("\0"),
                  decoded != ".", decoded != ".." else {
                throw DKTCaddyConfigError(400, "invalid escaped request path")
            }
            return decoded
        }
        switch components.removeFirst() {
        case "config": return components
        case "id":
            guard let id = components.first else { throw DKTCaddyConfigError(400, "object ID is required") }
            guard let path = config.path(forID: id) else { throw DKTCaddyConfigError(404, "object ID was not found") }
            return path + Array(components.dropFirst())
        default: throw DKTCaddyConfigError(404, "Caddy endpoint is not implemented by this fixture")
        }
    }

    private func header(_ name: String, in request: DKTHTTPRequest) -> String? {
        request.headers.first(where: { $0.key.lowercased() == name })?.value
    }

    private func validatePrecondition(_ value: String) throws {
        guard value.first == "\"", value.last == "\"" else {
            throw DKTCaddyConfigError(412, "config precondition failed")
        }
        let fields = value.dropFirst().dropLast().split(separator: " ", maxSplits: 1).map(String.init)
        guard fields.count == 2, fields[0].hasPrefix("/config/") else {
            throw DKTCaddyConfigError(412, "config precondition failed")
        }
        do {
            let components = try route(fields[0])
            let current = try config.value(at: components)
            guard try etag(path: fields[0], value: current) == value else {
                throw DKTCaddyConfigError(412, "config precondition failed")
            }
        } catch {
            throw DKTCaddyConfigError(412, "config precondition failed")
        }
    }

    private func etag(path: String, value: DKTCaddyJSON) throws -> String {
        // A deterministic test-only content hash. Production Caddy uses xxhash;
        // tests treat tags as opaque and never infer security from this hash.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in try value.encoded() { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return "\"\(path) \(String(hash, radix: 16))\""
    }

    private func error(_ status: Int, _ message: String) -> DKTHTTPResponse {
        let body = (try? DKTCaddyJSON.object(["error": .string(message)]).encoded()) ?? Data()
        return DKTHTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: body)
    }
}

private struct DKTCaddyFailure {
    let method: String?
    let path: String?
    var remaining: Int
    var skip: Int
    let statusCode: Int
    let message: String
}
