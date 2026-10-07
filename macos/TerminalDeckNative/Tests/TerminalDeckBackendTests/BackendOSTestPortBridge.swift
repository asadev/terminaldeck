import Foundation
import Network
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// No TCP listener or clock is started. The production byte parser, auth,
/// routing, file serving, invoke/send and SSE owner run over these fakes.
final class BackendOSTestPortBridgeNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var accept: (@Sendable (BackendOSNativeBridge.Connection) -> Void)?
    private(set) var attempts: [Int] = []
    let available: Int, busy: Int?
    init(available: Int = 18933, busy: Int? = nil) { self.available = available; self.busy = busy }
    var bindings: BackendOSNativeBridge.NetworkBindings { .init { [self] wanted, accept in
        try lock.withLock {
            attempts.append(wanted); if wanted == busy { throw NWError.posix(.EADDRINUSE) }
            self.accept = accept; return .init(port: wanted == 0 ? available : wanted, close: {})
        }
    } }
    func request(_ bytes: Data) -> BackendOSTestPortBridgeSocket {
        let socket = BackendOSTestPortBridgeSocket(bytes); let callback = lock.withLock { accept }; callback?(socket.connection); return socket
    }
}
final class BackendOSTestPortBridgeLogs: @unchecked Sendable {
    private let lock = NSLock(); private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func text() -> String { lock.withLock { lines.joined(separator: "\n") } }
}
final class BackendOSTestPortBridgeSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: Data?, output = Data(), closed = false
    private var eof: BackendOSNativeBridge.Connection.Read?, close: (@Sendable () -> Void)?
    private var completed: [CheckedContinuation<Data, Never>] = []
    private var waiters: [(String, CheckedContinuation<Data, Never>)] = []
    init(_ bytes: Data) { incoming = bytes }
    var connection: BackendOSNativeBridge.Connection { .init(read: { [self] _, _, callback in
        let data = lock.withLock { let data = incoming; incoming = nil; if data == nil { eof = callback }; return data }
        if let data { callback(data, false, nil) }
    }, write: { [self] data, callback in
        let waiting = lock.withLock { () -> [(String, CheckedContinuation<Data, Never>)] in
            if let data { output.append(data) }; let text = String(decoding: output, as: UTF8.self)
            let ready = waiters.filter { text.contains($0.0) }; waiters.removeAll { text.contains($0.0) }; return ready
        }
        let bytes = lock.withLock { output }; for waiter in waiting { waiter.1.resume(returning: bytes) }; callback(nil)
    }, cancel: { [self] in
        let state = lock.withLock { () -> (Data, [CheckedContinuation<Data, Never>], BackendOSNativeBridge.Connection.Read?, (@Sendable () -> Void)?) in
            if closed { return (output, [], nil, nil) }; closed = true
            let continuations = completed + waiters.map(\.1); completed = []; waiters = []; let oldEOF = eof; eof = nil
            return (output, continuations, oldEOF, close)
        }
        for continuation in state.1 { continuation.resume(returning: state.0) }; state.2?(nil, true, nil); state.3?()
    }, observeClose: { [self] callback in lock.withLock { close = callback } }) }
    func response() async -> Data { await withCheckedContinuation { continuation in lock.withLock { if closed { continuation.resume(returning: output) } else { completed.append(continuation) } } } }
    func contains(_ needle: String) async -> Data { await withCheckedContinuation { continuation in lock.withLock { if String(decoding: output, as: UTF8.self).contains(needle) || closed { continuation.resume(returning: output) } else { waiters.append((needle, continuation)) } } } }
}

final class BackendOSTestPortBridge: BackendOSTestPortFixture {
    let token = "test-token-0123456789abcdef0123456789abcdef"
    struct Reply { let status: Int, headers: [String: String], body: String }
    struct Rig { let root: URL, network: BackendOSTestPortBridgeNetwork, clock: BackendOSTestPortManualClock, logs: BackendOSTestPortBridgeLogs, registry: NativeChannelRegistry, bridge: BackendOSNativeBridge, endpoint: BackendOSNativeBridge.Endpoint }
    func rig(network: BackendOSTestPortBridgeNetwork = .init(), portFile: URL? = nil, fixedToken: String? = "test-token-0123456789abcdef0123456789abcdef", maxBody: Int = 64 * 1024 * 1024, onClient: @escaping @Sendable () async throws -> Void = {}) async throws -> Rig {
        let root = try scratch("bridge"), renderer = root.appendingPathComponent("out/renderer"), shim = root.appendingPathComponent("out/native-web/shim.js")
        try put(renderer.appendingPathComponent("index.html"), "<!doctype html>\n<html lang=\"en\">\n  <head>\n    <meta charset=\"UTF-8\" />\n    <script type=\"module\" crossorigin src=\"./assets/app.js\"></script>\n  </head>\n  <body><div id=\"root\"></div></body>\n</html>\n")
        try put(renderer.appendingPathComponent("assets/app.js"), "console.log(\"app\")\n"); try put(root.appendingPathComponent("out/secret.txt"), "outside the renderer\n")
        try FileManager.default.createSymbolicLink(at: renderer.appendingPathComponent("assets/link.txt"), withDestinationURL: root.appendingPathComponent("out/secret.txt"))
        let clock = BackendOSTestPortManualClock(), logs = BackendOSTestPortBridgeLogs(), registry = NativeChannelRegistry()
        let bridge = try BackendOSNativeBridge(options: .init(rendererDirectory: renderer, shimFile: shim, portFile: portFile, maximumBodyBytes: maxBody,
            network: network.bindings, token: fixedToken, scheduleKeepAlive: clock.schedule, onClient: onClient, log: logs.append), dispatcher: .init(registry: registry), ownPorts: BackendDevOwnPorts(), ownerID: "7")
        let endpoint = try await bridge.start(); return Rig(root: root, network: network, clock: clock, logs: logs, registry: registry, bridge: bridge, endpoint: endpoint)
    }
    func raw(_ rig: Rig, method: String = "GET", path: String = "/", headers: [String: String] = [:], body: String = "") -> Data {
        var headers = headers; if headers["host"] == nil { headers["host"] = "127.0.0.1:\(rig.endpoint.port)" }; if !body.isEmpty { headers["content-length"] = String(body.utf8.count) }
        return Data(("\(method) \(path) HTTP/1.1\r\n" + headers.keys.sorted().map { "\($0): \(headers[$0]!)\r\n" }.joined() + "\r\n" + body).utf8)
    }
    func reply(_ rig: Rig, method: String = "GET", path: String = "/", headers: [String: String] = [:], body: String = "") async -> Reply {
        let data = await rig.network.request(raw(rig, method: method, path: path, headers: headers, body: body)).response(), text = String(decoding: data, as: UTF8.self), split = text.components(separatedBy: "\r\n\r\n"), head = split[0].components(separatedBy: "\r\n")
        var parsed: [String: String] = [:]
        for line in head.dropFirst() { if let colon = line.firstIndex(of: ":") { parsed[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) } }
        return Reply(status: Int(head[0].split(separator: " ").dropFirst().first ?? "0") ?? 0, headers: parsed, body: split.dropFirst().joined(separator: "\r\n\r\n"))
    }
    func cookie() -> [String: String] { ["cookie": "td_native=" + token] }
    func post(_ rig: Rig, _ path: String, _ body: String, headers: [String: String] = [:]) async -> Reply { await reply(rig, method: "POST", path: path, headers: cookie().merging(["content-type": "application/json"]) { _, new in new }.merging(headers) { _, new in new }, body: body) }
    func testBridge107ReadyLoopbackPortAndFresh32ByteToken() async throws {
        let r = try await rig(fixedToken: nil); let line = r.endpoint.readyLine
        XCTAssertNotNil(line.range(of: #"^TD_NATIVE_READY http://127\.0\.0\.1:\d+/\?t=[A-Za-z0-9_-]{43,}$"#, options: .regularExpression)); XCTAssertEqual(r.endpoint.url, "http://127.0.0.1:\(r.endpoint.port)/?t=\(r.endpoint.token)"); await r.bridge.close()
    }
    func testBridge117FailureStaysOneLine() { XCTAssertEqual(BackendOSNativeBridge.failedLine("the port\nwas taken\r\n"), "TD_NATIVE_FAILED the port was taken"); XCTAssertEqual(BackendOSNativeBridge.failedLine(""), "TD_NATIVE_FAILED unknown reason") }
    func testBridge124RememberedPortFreshToken() async throws {
        let file = try scratch().appendingPathComponent("native-shell-port"), network = BackendOSTestPortBridgeNetwork()
        let first = try await rig(network: network, portFile: file, fixedToken: nil); XCTAssertEqual(try text(file).trimmingCharacters(in: .whitespacesAndNewlines), String(first.endpoint.port)); await first.bridge.close()
        let second = try await rig(network: network, portFile: file, fixedToken: nil); XCTAssertEqual(second.endpoint.port, first.endpoint.port); XCTAssertNotEqual(second.endpoint.token, first.endpoint.token); await second.bridge.close()
    }
    func testBridge139BusyPreferredPortFallsBackAndRemembers() async throws {
        let file = try scratch().appendingPathComponent("native-shell-port"); try put(file, "13000\n"); let network = BackendOSTestPortBridgeNetwork(available: 13001, busy: 13000), r = try await rig(network: network, portFile: file)
        XCTAssertNotEqual(r.endpoint.port, 13000); XCTAssertEqual(try text(file).trimmingCharacters(in: .whitespacesAndNewlines), String(r.endpoint.port)); XCTAssertEqual(network.attempts, [13000, 0]); XCTAssertTrue(r.logs.text().contains("port 13000 is taken")); await r.bridge.close()
    }
    func testBridge164RememberedPortJunkIgnored() throws { let file = try scratch().appendingPathComponent("port"); for junk in ["80", "banana", "70000", ""] { try put(file, junk); XCTAssertNil(BackendOSNativeBridge.rememberedPort(file)) }; XCTAssertNil(BackendOSNativeBridge.rememberedPort(file.deletingLastPathComponent().appendingPathComponent("absent"))) }
    func testBridge175BootstrapCookieCSPAndFirstShim() async throws {
        let r = try await rig(), result = await reply(r, path: "/?t=" + token)
        XCTAssertEqual(result.status, 200); XCTAssertEqual(result.headers["set-cookie"], "td_native=\(token); HttpOnly; SameSite=Strict; Path=/"); XCTAssertEqual(result.headers["content-type"], "text/html; charset=utf-8"); XCTAssertTrue(result.headers["content-security-policy"]?.contains("script-src 'self'") == true)
        let head = result.body.components(separatedBy: "<head>").last?.components(separatedBy: "</head>").first ?? "", first = head.range(of: "<script")
        XCTAssertNotNil(first); if let first { XCTAssertTrue(head[first.lowerBound...].hasPrefix("<script src=\"/__td/shim.js\"></script>")); let asset = try XCTUnwrap(head.range(of: "./assets/app.js")); XCTAssertGreaterThan(head.distance(from: head.startIndex, to: asset.lowerBound), head.distance(from: head.startIndex, to: first.lowerBound)) }; await r.bridge.close()
    }
    func testBridge188MissingCookieAndTokenForbidden() async throws { let r = try await rig(); for path in ["/assets/app.js", "/", "/__td/events"] { let result = await reply(r, path: path); XCTAssertEqual(result.status, 403); XCTAssertEqual(result.body, "Forbidden.") }; await r.bridge.close() }
    func testBridge195WrongBootstrapTokenForbidden() async throws { let r = try await rig(), result = await reply(r, path: "/?t=nope"); XCTAssertEqual(result.status, 403); await r.bridge.close() }
    func testBridge200CorrectCookieWrongHostForbidden() async throws { let r = try await rig(); for host in ["localhost", "localhost:\(r.endpoint.port)", "evil.example:\(r.endpoint.port)", "127.0.0.1"] { let result = await reply(r, path: "/assets/app.js", headers: cookie().merging(["host": host]) { _, new in new }); XCTAssertEqual(result.status, 403) }; let bootstrap = await reply(r, path: "/?t=" + token, headers: ["host": "rebound.example:\(r.endpoint.port)"]); XCTAssertEqual(bootstrap.status, 403); await r.bridge.close() }
    func testBridge209OriginAndFetchSiteEvenWithCookie() async throws {
        let r = try await rig(); try await r.registry.register("brand:get", ownerID: "test") { _, _ in .null }
        for headers in [["origin": "http://evil.example"], ["origin": "null"], ["origin": "http://127.0.0.1:\(r.endpoint.port + 1)"], ["sec-fetch-site": "cross-site"]] { let result = await post(r, "/__td/invoke", #"{"channel":"brand:get","args":[]}"#, headers: headers); XCTAssertEqual(result.status, 403) }
        let allowed = await post(r, "/__td/invoke", #"{"channel":"brand:get","args":[]}"#, headers: ["origin": "http://127.0.0.1:\(r.endpoint.port)", "sec-fetch-site": "same-origin"]); XCTAssertEqual(allowed.status, 200); await r.bridge.close()
    }
    func testBridge225HeaderTokenAccepted() async throws { let r = try await rig(), result = await reply(r, path: "/assets/app.js", headers: ["x-td-token": token]); XCTAssertEqual(result.status, 200); await r.bridge.close() }
    func testBridge232StaticAssetContentTypeAndBytes() async throws { let r = try await rig(), result = await reply(r, path: "/assets/app.js", headers: cookie()); XCTAssertEqual(result.status, 200); XCTAssertEqual(result.headers["content-type"], "text/javascript; charset=utf-8"); XCTAssertEqual(result.body, "console.log(\"app\")\n"); await r.bridge.close() }
    func testBridge240EveryTraversalAndSymlinkRefusal() async throws { let r = try await rig(); for path in ["/../secret.txt", "/assets/../../secret.txt", "/assets/%2e%2e/%2e%2e/secret.txt", "/assets/..%2f..%2fsecret.txt", "/assets/%2E%2E%5C..%5Csecret.txt", "/assets/link.txt", "/%00/etc/passwd", "/%E0%A4%A"] { let result = await reply(r, path: path, headers: cookie()); XCTAssertTrue([403, 404].contains(result.status), path); XCTAssertFalse(result.body.contains("outside the renderer")) }; await r.bridge.close() }
    func testBridge259PurePathGate() { let root = URL(fileURLWithPath: "/r"); XCTAssertEqual(BackendOSNativeBridge.staticPath(root: root, pathname: "/assets/a.js")?.path, "/r/assets/a.js"); for path in ["/assets/../a.js", "/a%2F..%2F..%2Fb", "/a\\b"] { XCTAssertNil(BackendOSNativeBridge.staticPath(root: root, pathname: path)) } }
    func testBridge266MissingThenBuiltShim() async throws { let r = try await rig(), missing = await reply(r, path: "/__td/shim.js", headers: cookie()); XCTAssertEqual(missing.status, 404); XCTAssertTrue(missing.body.contains("out/native-web/shim.js is missing")); try put(r.root.appendingPathComponent("out/native-web/shim.js"), "window.__shim = true\n"); let built = await reply(r, path: "/__td/shim.js", headers: cookie()); XCTAssertEqual(built.status, 200); XCTAssertEqual(built.headers["content-type"], "text/javascript; charset=utf-8"); XCTAssertEqual(built.body, "window.__shim = true\n"); await r.bridge.close() }
    func testBridge279NoHeadNoInjection() { XCTAssertNil(BackendOSNativeBridge.injectShim("<html><body></body></html>")); XCTAssertEqual(BackendOSNativeBridge.injectShim("<html><HEAD lang=\"x\"><title>t</title></HEAD></html>"), "<html><HEAD lang=\"x\">\n    <script src=\"/__td/shim.js\"></script><title>t</title></HEAD></html>") }
    func testBridge312InvokeValueBytesAndUndefinedOmission() async throws {
        let r = try await rig(); try await r.registry.register("echo:it", ownerID: "test") { context, args in XCTAssertEqual(context.ownerID, "7"); return .object([.init("args", .array(args)), .init("bytes", .bytes(Data("hi".utf8))), .init("when", .missing)]) }
        let response = await post(r, "/__td/invoke", #"{"channel":"echo:it","args":[1,"two",{"$bytes":"aW4="}]}"#), value = try NativeRPCValue.parseJSON(Data(response.body.utf8))
        XCTAssertEqual(response.status, 200); XCTAssertEqual(value, .object([.init("ok", .bool(true)), .init("value", .object([.init("args", .array([.number(1), .string("two"), .object([.init("$bytes", .string("aW4="))])])), .init("bytes", .object([.init("$bytes", .string("aGk="))]))]))])); await r.bridge.close()
    }
    func testBridge329HandlerAndMissingHandlerErrors() async throws {
        let r = try await rig(); try await r.registry.register("fails:always", ownerID: "test") { _, _ in throw NativeRPCError(code: "test", message: "it broke") }
        let failed = await post(r, "/__td/invoke", #"{"channel":"fails:always"}"#), absent = await post(r, "/__td/invoke", #"{"channel":"nobody:home","args":[]}"#)
        XCTAssertEqual(try NativeRPCValue.parseJSON(Data(failed.body.utf8)), .object([.init("ok", .bool(false)), .init("error", .string("it broke"))])); XCTAssertEqual(try NativeRPCValue.parseJSON(Data(absent.body.utf8)), .object([.init("ok", .bool(false)), .init("error", .string("No handler registered for 'nobody:home'"))])); await r.bridge.close()
    }
    func testBridge342BodyFormatChannelAndLimitRefusals() async throws {
        let r = try await rig(maxBody: 64), wrongType = await post(r, "/__td/invoke", #"{"channel":"a"}"#, headers: ["content-type": "text/plain"]); XCTAssertEqual(wrongType.status, 415)
        for body in ["not json", "[1,2]", #"{"channel":"error"}"#, #"{"channel":"a:b","args":"x"}"#] { let response = await post(r, "/__td/invoke", body); XCTAssertEqual(response.status, 400) }
        let large = await post(r, "/__td/invoke", NativeRPCValue.object([.init("channel", .string("a:b")), .init("args", .array([.string(String(repeating: "x", count: 200))]))]).compact); XCTAssertEqual(large.status, 413); await r.bridge.close()
    }
    func testBridge353SendEveryArgumentAnd204() async throws {
        let r = try await rig(), heard = BackendOSTestPortRegistryPushTrace.Heard(); let subscription = try await r.registry.onSend("session:write", ownerID: "test") { context, args in await heard.append(.array([.number(Double(Int(context.ownerID) ?? -1))] + args)) }
        let reply = await post(r, "/__td/send", #"{"channel":"session:write","args":["s1","ls\r"]}"#), values = await heard.all(); XCTAssertEqual(reply.status, 204); XCTAssertEqual(values, [.array([.number(7), .string("s1"), .string("ls\r")])]); await subscription.cancelAndWait(); await r.bridge.close()
    }
    func testBridge365SendSyncRefuses501() async throws { let r = try await rig(), result = await post(r, "/__td/send-sync", #"{"channel":"a:b"}"#); XCTAssertEqual(result.status, 501); XCTAssertTrue(try NativeRPCValue.parseJSON(Data(result.body.utf8))["error"].string?.contains("sendSync") == true); await r.bridge.close() }
    func testBridge374EventFrameAndClientCount() async throws {
        actor Clients {
            var count = 0; var waiting: CheckedContinuation<Int, Never>?
            func arrived() { count += 1; waiting?.resume(returning: count); waiting = nil }
            func first() async -> Int { if count > 0 { return count }; return await withCheckedContinuation { waiting = $0 } }
        }
        let clients = Clients(), r = try await rig(onClient: { await clients.arrived() }), absent = await r.bridge.emit(channel: "nobody:listening", arguments: []); XCTAssertFalse(absent)
        let socket = r.network.request(raw(r, path: "/__td/events", headers: cookie())); _ = await socket.contains(": connected")
        let arrived = await clients.first(); XCTAssertEqual(arrived, 1)
        let header = await socket.contains(": connected"); XCTAssertTrue(String(decoding: header, as: UTF8.self).contains("Content-Type: text/event-stream; charset=utf-8"))
        let count = await r.bridge.clientCount(), sent = await r.bridge.emit(channel: "session:status", arguments: [.string("s1"), .object([.init("state", .string("busy"))]), .bytes(Data([1, 2, 3]))]); XCTAssertEqual(count, 1); XCTAssertTrue(sent)
        let bytes = await socket.contains("data: "), line = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n").first { $0.hasPrefix("data: ") } ?? ""
        XCTAssertEqual(try NativeRPCValue.parseJSON(Data(line.dropFirst(6).utf8)), .object([.init("channel", .string("session:status")), .init("args", .array([.string("s1"), .object([.init("state", .string("busy"))]), .object([.init("$bytes", .string("AQID"))])]))])); await r.bridge.close()
    }
    // TS bridge-server.test.ts:415-433 waits for ": keep-alive" in the response BODY (node's `res.on('data')`); this
    // fake socket also carries the head, whose `Connection: keep-alive` matched at once and raced the frame.
    // Waiting for the comment frame itself is the same condition on raw bytes (S1g, misport fix).
    func testBridge415KeepaliveWithManualClock() async throws { let r = try await rig(), socket = r.network.request(raw(r, path: "/__td/events", headers: cookie())); _ = await socket.contains(": connected"); r.clock.fire(); let bytes = await socket.contains(": keep-alive\n\n"); XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(": keep-alive\n\n"), String(decoding: bytes, as: UTF8.self) + " | log: " + r.logs.text()); await r.bridge.close() }
}
