import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendDeckCoreSecurityTestEvents: BackendDeckCoreSecurityEvents {
    func list() async throws -> NativeRPCValue { .object([.init("events", .array([.object([.init("name", .string("session.turn_finished"))])]))]) }
    func subscribe(keyID: String, via: String, parameters: NativeRPCValue) async throws -> NativeRPCValue { .object([.init("id", .string(keyID)), .init("via", .string(via))]) }
    func unsubscribe(keyID: String, parameters: NativeRPCValue) async throws -> NativeRPCValue { throw BackendDeckCoreSecurityProtocolError(code: -32004, message: "no such event") }
}
final class BackendDeckCoreSecurityDoorServerTests: XCTestCase {
    private let headers = ["content-type": "application/json", "accept": "application/json, text/event-stream", "host": "127.0.0.1:40404"]
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckCoreSecurityDoor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func made(_ keys: BackendDeckCoreSecurityAccessKeys, crm: Bool = false) async throws -> NativeRPCValue {
        try await keys.create(.object([.init("name", .string("ChatGPT")), .init("level", .string("full")), .init("crmOnly", .bool(crm))]))
    }
    private func control(broker: BackendDeckCoreSecurityConsentBroker? = nil) throws -> BackendDeckCoreSecurityControl {
        let tool = try BackendMCPTool(id: "projects.list", wireName: "projects_list", description: "projects", inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .read)
        let policy = BackendDeckCoreSecurityToolPolicy(tool: tool, summary: { _, _ in "List projects" }, run: { _, _ in .init(value: .object([.init("count", .number(1))]), summary: .object([.init("count", .number(1))])) })
        return try .init(log: .init(directory: temporary()), consent: broker ?? .init(ask: { _ in false }), policies: [policy])
    }
    private func envelope(_ method: String, id: NativeRPCValue = .number(1), params: NativeRPCValue = .object([]), modern: Bool = false) -> NativeRPCValue {
        let meta = NativeRPCValue.object([.init("io.modelcontextprotocol/protocolVersion", .string("2026-07-28")), .init("io.modelcontextprotocol/clientCapabilities", .object([])),
            .init("io.modelcontextprotocol/clientInfo", .object([.init("name", .string("openai-mcp")), .init("version", .string("2.0.0"))]))])
        return .object([.init("jsonrpc", .string("2.0")), .init("id", id), .init("method", .string(method)), .init("params", modern ? params.setting("_meta", meta) : params)])
    }
    func testCallerTableEmptyTokenRawBearerAndRevocation() async throws {
        let table = BackendDeckCoreSecurityCallerTable()
        let grant = BackendDeckCoreSecurityGrant(attended: false, caller: { .local })
        do { _ = try await table.set(token: "", grant: grant); XCTFail("Empty token refused") } catch {}
        let registration = try await table.set(token: String(repeating: "a", count: 64), grant: grant)
        let found = await table.match(authorization: "Bearer " + String(repeating: "a", count: 64)); XCTAssertEqual(found?.attended, false)
        let wrong = await table.match(authorization: "Bearer " + String(repeating: "b", count: 64)); XCTAssertNil(wrong)
        let revoked = await table.revoke(registration); XCTAssertTrue(revoked); XCTAssertTrue(grant.cancellation.isCancelled)
        XCTAssertEqual(BackendDeckCoreSecurityCallerTable.bearerOf(" bearer   ak_key "), "ak_key")
    }
    func testDoorCRMRefusalAndInternetSeparateFromLocal() async throws {
        let keys = BackendDeckCoreSecurityAccessKeys(directory: try temporary())
        let crm = try await made(keys, crm: true); let key = try await made(keys)
        let door = BackendDeckCoreSecurityAccessKeyDoor(keys: keys); await door.activate()
        let rejected = await door.grant(credential: crm["key"].string, via: "this-mac"); XCTAssertNil(rejected)
        let remoteOff = await door.grant(credential: key["key"].string, via: "internet"); XCTAssertNil(remoteOff)
        let local = await door.grant(credential: key["key"].string, via: "this-mac"); XCTAssertNotNil(local)
        _ = try await keys.setInternet(.bool(true))
        let remote = await door.grant(credential: key["key"].string, via: "internet"); XCTAssertNotNil(remote)
        _ = try await keys.setInternet(.bool(false)); XCTAssertTrue(remote?.cancellation.isCancelled == true); XCTAssertFalse(local?.cancellation.isCancelled == true)
        await local?.done(); await remote?.done(); await door.stop()
    }
    func testKeyLevelsTasksRenameAndRevokeResolveInsideOpenGrant() async throws {
        let keys = BackendDeckCoreSecurityAccessKeys(directory: try temporary()); let key = try await made(keys); let id = try XCTUnwrap(key["view"]["id"].string)
        let door = BackendDeckCoreSecurityAccessKeyDoor(keys: keys); await door.activate()
        let opened = await door.grant(credential: key["key"].string, via: "this-mac", userAgent: "claude-code/2.1.233 (cli)")
        let grant = try XCTUnwrap(opened)
        _ = try await keys.setLevel(id: id, level: .string("look")); let look = await grant.caller(); XCTAssertEqual(look.tiers, [.read]); XCTAssertFalse(look.tasks)
        _ = try await keys.setTasks(id: id, on: .bool(true)); _ = try await keys.rename(id: id, name: .string("Cursor"))
        let changed = await grant.caller(); XCTAssertTrue(changed.tasks); XCTAssertEqual(changed.keyName, "Cursor")
        await grant.noteClient("outside-app 9.9.9"); let view = await keys.get(id: id); XCTAssertEqual(view?["lastApp"], .string("outside-app 9.9.9"))
        _ = try await keys.revoke(id: id); XCTAssertTrue(grant.cancellation.isCancelled)
        let gone = await grant.caller(); XCTAssertTrue(gone.tiers.isEmpty); await grant.done(); XCTAssertEqual(door.inFlightCount(), 0); await door.stop()
    }
    func testHostLiteralRuleAllowsFarEndPortAndRefusesOriginPeer() {
        XCTAssertTrue(BackendDeckCoreSecurityServer.hostIsLocal("127.0.0.1:40404"))
        XCTAssertTrue(BackendDeckCoreSecurityServer.hostIsLocal("[::1]:9000"))
        XCTAssertTrue(BackendDeckCoreSecurityServer.hostIsLocal("LOCALHOST:1"))
        XCTAssertFalse(BackendDeckCoreSecurityServer.hostIsLocal("attacker.example:40404"))
        XCTAssertFalse(BackendDeckCoreSecurityServer.hostIsLocal(nil))
        XCTAssertFalse(BackendDeckCoreSecurityServer.isLoopback("192.168.1.2"))
        XCTAssertTrue(BackendDeckCoreSecurityServer.isLoopback("::ffff:127.0.0.1"))
    }
    func testLoopbackStatusGuardsTokenRouteAndBodyCap() async throws {
        let server = BackendDeckCoreSecurityServer(control: try control(), ownPorts: .init()); let endpoint = try await server.start()
        let body = try envelope("ping").encodedJSON()
        var h = headers; h["authorization"] = "Bearer " + endpoint.token
        let good = await server.respond(.init(method: "POST", path: "/mcp", headers: h, body: body)); XCTAssertEqual(good.status, 200)
        let missing = await server.respond(.init(method: "POST", path: "/mcp", headers: headers, body: body)); XCTAssertEqual(missing.status, 403)
        XCTAssertNil(missing.headers["www-authenticate"])
        let path = await server.respond(.init(method: "POST", path: "/other", headers: h, body: body)); XCTAssertEqual(path.status, 404)
        let get = await server.respond(.init(method: "GET", path: "/mcp", headers: h, body: Data())); XCTAssertEqual(get.status, 405)
        var origin = h; origin["origin"] = ""; let browser = await server.respond(.init(method: "POST", path: "/mcp", headers: origin, body: body)); XCTAssertEqual(browser.status, 403)
        let cap = await server.respond(.init(method: "POST", path: "/mcp", headers: h, body: Data(repeating: 120, count: 256 * 1024 + 1))); XCTAssertEqual(cap.status, 413)
        let pathToken = await server.respond(.init(method: "POST", path: "/mcp/" + endpoint.token, headers: headers, body: body)); XCTAssertEqual(pathToken.status, 403)
        await server.stop()
    }
    func testFreshRunTokensConcurrentStartAndOwnPortClaim() async throws {
        let ports = BackendDevOwnPorts(); let server = BackendDeckCoreSecurityServer(control: try control(), ownPorts: ports)
        async let first = server.start(); async let second = server.start(); let (one, two) = try await (first, second)
        XCTAssertEqual(one.port, two.port); XCTAssertNotEqual(one.token, one.unattendedToken)
        let claimed = await ports.ports(); XCTAssertTrue(claimed.contains(one.port)); await server.stop()
        let unclaimed = await ports.ports(); XCTAssertFalse(unclaimed.contains(one.port))
        let fresh = try await server.start(); XCTAssertNotEqual(fresh.token, one.token); await server.stop()
    }
    func testPreferredPortFallbackAndFixedPortFailure() async throws {
        let c = try control(); let one = BackendDeckCoreSecurityServer(control: c, ownPorts: .init()); let endpoint = try await one.start()
        let two = BackendDeckCoreSecurityServer(control: c, ownPorts: .init()); let moved = try await two.start(preferredPort: endpoint.port)
        XCTAssertNotEqual(moved.port, endpoint.port)
        let fixed = BackendDeckCoreSecurityServer(control: c, ownPorts: .init())
        do { _ = try await fixed.start(port: endpoint.port); XCTFail("A fixed occupied port must fail") } catch {}
        await one.stop(); await two.stop(); await fixed.stop()
    }
    func testLegacyBothContentShapesAndModernHeadersDiscoverEvents() async throws {
        let server = BackendDeckCoreSecurityServer(control: try control(), ownPorts: .init())
        let events = BackendDeckCoreSecurityTestEvents()
        let grant = BackendDeckCoreSecurityGrant(attended: true, caller: { .init(kind: .key, tiers: [.read], keyID: "k", keyName: "ChatGPT") }, events: events, keyID: "k", via: "internet")
        let legacy = await server.serve(parsed: envelope("tools/call", params: .object([.init("name", .string("projects_list")), .init("arguments", .object([]))])), headers: headers, grant: grant, cancellation: .init())
        let parsed = try NativeRPCValue.parseJSON(legacy.body); XCTAssertEqual(parsed["result"]["structuredContent"]["count"], .number(1)); XCTAssertNotNil(parsed["result"]["content"].elements?.first?["text"].string)
        let modern = envelope("server/discover", modern: true); var h = headers; h["mcp-protocol-version"] = "2026-07-28"; h = BackendDeckCoreSecurityServer.withStandardHeaders(h, parsed: modern)
        let response = await server.serve(parsed: modern, headers: h, grant: grant, cancellation: .init()); let discover = try NativeRPCValue.parseJSON(response.body)
        XCTAssertEqual(discover["result"]["capabilities"]["events"], .object([])); XCTAssertEqual(discover["result"]["resultType"], .string("complete"))
        XCTAssertTrue(discover["result"]["instructions"].string?.contains("notifications_wait") == true)
        let noHeaders = await server.serve(parsed: modern, headers: headers, grant: grant, cancellation: .init()); let error = try NativeRPCValue.parseJSON(noHeaders.body); XCTAssertEqual(error["error"]["code"], .number(-32020))
    }
    func testStandardHeaderSentinelAndNotificationsBatchesUntouched() {
        let body = envelope("tools/call", params: .object([.init("name", .string("résumé tool"))]))
        let h = BackendDeckCoreSecurityServer.withStandardHeaders([:], parsed: body); XCTAssertEqual(h["mcp-method"], "tools/call")
        XCTAssertEqual(h["mcp-name"], "=?base64?" + Data("résumé tool".utf8).base64EncodedString() + "?=")
        XCTAssertTrue(BackendDeckCoreSecurityServer.withStandardHeaders([:], parsed: envelope("notifications/initialized", id: .missing)).isEmpty)
        XCTAssertTrue(BackendDeckCoreSecurityServer.withStandardHeaders([:], parsed: .array([body])).isEmpty)
    }
    func testListenRefusedImmediatelyAndAcceptParity() async throws {
        let server = BackendDeckCoreSecurityServer(control: try control(), ownPorts: .init())
        let grant = BackendDeckCoreSecurityGrant(attended: true, caller: { .local })
        let refused = await server.serve(parsed: envelope("subscriptions/listen", modern: true), headers: ["mcp-protocol-version": "2026-07-28"], grant: grant, cancellation: .init())
        let no = try NativeRPCValue.parseJSON(refused.body); XCTAssertEqual(no["error"]["code"], .number(-32601))
        let unacceptable = await server.serve(parsed: envelope("ping"), headers: ["content-type": "application/json", "accept": "application/json"], grant: grant, cancellation: .init()); XCTAssertEqual(unacceptable.status, 406)
    }
    func testHiddenCallLeaksNoActionRow() async throws {
        let log = BackendDeckCoreSecurityActionLog(directory: try temporary())
        let control = try BackendDeckCoreSecurityControl(log: log, consent: .init(ask: { _ in false }))
        let server = BackendDeckCoreSecurityServer(control: control, ownPorts: .init())
        let grant = BackendDeckCoreSecurityGrant(attended: true, tools: ["browser_read"], caller: { .init(kind: .session, tiers: [.read], sessionID: "s") })
        let response = await server.serve(parsed: envelope("tools/call", params: .object([.init("name", .string("sessions_start"))])), headers: headers, grant: grant, cancellation: .init())
        let body = try NativeRPCValue.parseJSON(response.body); XCTAssertEqual(body["result"]["isError"], .bool(true))
        let rows = await log.tail(); XCTAssertTrue(rows.isEmpty)
    }
    func testCancellationNotificationWithdrawsConsentWithoutClosingRequest() async throws {
        let delivered = expectation(description: "consent shown")
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in delivered.fulfill(); return true })
        let tool = try BackendMCPTool(id: "settings.write", wireName: "settings_write", description: "settings", inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .alter)
        let policy = BackendDeckCoreSecurityToolPolicy(tool: tool, summary: { _, _ in "Change settings" }, run: { _, _ in XCTFail("Cancelled call must not run"); return .init(value: .null) })
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: temporary()), consent: broker, policies: [policy])
        let server = BackendDeckCoreSecurityServer(control: control, ownPorts: .init()); let grant = BackendDeckCoreSecurityGrant(identity: "caller", attended: true, caller: { .local })
        let callMessage = envelope("tools/call", params: .object([.init("name", .string("settings_write"))])); let h = headers
        let call = Task { await server.serve(parsed: callMessage, headers: h, grant: grant, cancellation: .init()) }
        await fulfillment(of: [delivered], timeout: 1)
        let cancel = envelope("notifications/cancelled", id: .missing, params: .object([.init("requestId", .number(1))]))
        let accepted = await server.serve(parsed: cancel, headers: headers, grant: grant, cancellation: .init()); XCTAssertEqual(accepted.status, 202)
        let response = await call.value; let body = try NativeRPCValue.parseJSON(response.body); XCTAssertEqual(body["result"]["isError"], .bool(true))
        let live = await broker.list(); XCTAssertTrue(live.isEmpty)
    }
    func testRelayOffUnknownMalformedAndPathKeySameDoor() async throws {
        let keys = BackendDeckCoreSecurityAccessKeys(directory: try temporary()); let key = try await made(keys)
        let door = BackendDeckCoreSecurityAccessKeyDoor(keys: keys); await door.activate()
        let server = BackendDeckCoreSecurityServer(control: try control(), keys: door, ownPorts: .init()); let body = try envelope("ping").encodedJSON()
        let off = await server.answerRelay(authorization: key["key"].string, pathKey: nil, userAgent: nil, protocolVersion: nil, body: body, cancellation: .init()); XCTAssertEqual(off.status, 404)
        _ = try await keys.setInternet(.bool(true))
        let good = await server.answerRelay(authorization: nil, pathKey: key["key"].string, userAgent: nil, protocolVersion: nil, body: body, cancellation: .init()); XCTAssertEqual(good.status, 200)
        let malformed = await server.answerRelay(authorization: nil, pathKey: key["key"].string, userAgent: nil, protocolVersion: nil, body: Data("no JSON".utf8), cancellation: .init()); XCTAssertEqual(malformed.status, 400)
        XCTAssertEqual(door.inFlightCount(), 0); await door.stop()
    }
    func testChunkedBodyAcrossFragmentsExtensionsAndTrailers() throws {
        var parser = BackendDeckCoreSecurityHTTPParser()
        XCTAssertNil(try parser.receive(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n4;tag=yes\r\n{\"a".utf8)))
        XCTAssertNil(try parser.receive(Data("\"\r\n3\r\n:1}".utf8)))
        let request = try XCTUnwrap(parser.receive(Data("\r\n0\r\nX-Trailer: harmless\r\n\r\n".utf8)))
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "{\"a\":1}")
    }
    func testHTTP10AndHeaderOnlyPostFraming() throws {
        var parser = BackendDeckCoreSecurityHTTPParser()
        let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
        let request = try XCTUnwrap(parser.receive(Data("POST /mcp HTTP/1.0\r\nHost: localhost\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)))
        XCTAssertEqual(request.method, "POST"); XCTAssertEqual(request.body, Data(body.utf8))
        var empty = BackendDeckCoreSecurityHTTPParser()
        let noBody = try XCTUnwrap(empty.receive(Data("POST /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)))
        XCTAssertTrue(noBody.body.isEmpty)
    }
    func testChunkedCapCountsBodyBytesAndRejectsLengthSmuggling() throws {
        var parser = BackendDeckCoreSecurityHTTPParser()
        let head = Data("POST /mcp HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n40000\r\n".utf8)
        XCTAssertNil(try parser.receive(head))
        XCTAssertNil(try parser.receive(Data(repeating: 120, count: 256 * 1024)))
        let request = try XCTUnwrap(parser.receive(Data("\r\n0\r\n\r\n".utf8))); XCTAssertEqual(request.body.count, 256 * 1024)
        var tooLarge = BackendDeckCoreSecurityHTTPParser()
        do { _ = try tooLarge.receive(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n40001\r\n".utf8)); XCTFail("Oversized decoded body refused") }
        catch let failure as BackendDeckCoreSecurityHTTPParseFailure { XCTAssertEqual(failure.status, 413) }
        var smuggling = BackendDeckCoreSecurityHTTPParser()
        do { _ = try smuggling.receive(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n".utf8)); XCTFail("Two body framings refused") }
        catch let failure as BackendDeckCoreSecurityHTTPParseFailure { XCTAssertEqual(failure.status, 400) }
    }
    func testClosedOrMalformedChunkedBodyCannotHang() throws {
        var parser = BackendDeckCoreSecurityHTTPParser()
        XCTAssertNil(try parser.receive(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n8\r\nx".utf8)))
        do { _ = try parser.receive(Data(), endOfStream: true); XCTFail("A torn body must refuse") }
        catch let failure as BackendDeckCoreSecurityHTTPParseFailure { XCTAssertEqual(failure.status, 400) }
        var malformed = BackendDeckCoreSecurityHTTPParser()
        do { _ = try malformed.receive(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nxyz\r\n".utf8)); XCTFail("Chunk size must be hexadecimal") }
        catch let failure as BackendDeckCoreSecurityHTTPParseFailure { XCTAssertEqual(failure.status, 400) }
    }
}
