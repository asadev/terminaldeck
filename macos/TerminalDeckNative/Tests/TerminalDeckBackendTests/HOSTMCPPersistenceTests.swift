import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HOSTMCPPersistenceTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
    }
    private struct Fixture: Sendable {
        var root: URL
        var paths: BackendHOSTPaths
        var hello: BackendHOSTProtocol.Hello
        var relay: BackendHOSTAppRelayServer
        var owner: BackendHOSTMCPPersistence
        var endpoint: BackendMCPEndpointDescription
        var guardState: HOSTMCPGuard
        var read: BackendMCPTool
        var alter: BackendMCPTool
    }
    private func fixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let hello = BackendHOSTProtocol.Hello(protocolVersion: BackendHOSTProtocol.version, hostVersion: "mcp-fixture", hostPID: getpid(), instance: UUID())
        let relay = try BackendHOSTAppRelayServer(paths: paths, host: hello), state = HOSTMCPGuard()
        let owner = try BackendHOSTMCPPersistence(server: BackendNativeMCPServer(), relay: relay, userData: root, sessionsDrained: { state.drained })
        addTeardownBlock { state.setDrained(true); try await owner.stopAfterSessionsDrained() }
        let schema: NativeRPCValue = .object([.init("type", .string("object")), .init("properties", .object([]))])
        let read = try BackendMCPTool(id: "fixture.read", wireName: "fixture_read", description: "Owned scratch read.", inputSchema: schema, tier: .read)
        let alter = try BackendMCPTool(id: "fixture.alter", wireName: "fixture_alter", description: "Owned scratch alter.", inputSchema: schema, tier: .alter)
        try await owner.installTools([read, alter]); let endpoint = try await owner.start()
        return .init(root: root, paths: paths, hello: hello, relay: relay, owner: owner, endpoint: endpoint, guardState: state, read: read, alter: alter)
    }
    private func http(_ fixture: Fixture, token: String, tool: String, arguments: NativeRPCValue = .object([]), id: String? = nil) async throws -> (Int, NativeRPCValue) {
        var request = URLRequest(url: fixture.endpoint.url); request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let value: NativeRPCValue = .object([.init("jsonrpc", .string("2.0")), .init("id", .string(id ?? UUID().uuidString)),
            .init("method", .string("tools/call")), .init("params", .object([.init("name", .string(tool)), .init("arguments", arguments)]))])
        request.httpBody = try value.encodedJSON()
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, data.isEmpty ? .null : try NativeRPCValue.parseJSON(data))
    }
    private func leaseToken(_ prepared: BackendPreparedToolLease) throws -> (String, URL) {
        let config = try XCTUnwrap(prepared.arguments.last)
        let value = try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: config)))
        let authorization = try XCTUnwrap(value["mcpServers"]["deck-control"]["headers"]["Authorization"].string)
        XCTAssertTrue(authorization.hasPrefix("Bearer "))
        return (String(authorization.dropFirst(7)), URL(fileURLWithPath: config))
    }
    func testActualCallerTableAndPrivateLeaseSurviveAppDetachAndNewAttachment() async throws {
        let fixture = try await fixture(), session = UUID().uuidString
        let prepared = try await fixture.owner.sessionTools.prepare(serverName: "deck-control", allowed: ["fixture.read"], projectRoot: fixture.root.path, taskProject: fixture.root.path + "/task")
        try await fixture.owner.sessionTools.bind(prepared.id, sessionID: session, machineID: "scratch-mac")
        let (token, config) = try leaseToken(prepared), originalConfig = try Data(contentsOf: config)
        let receipt = HOSTMCPReceipts()
        let first = try BackendHOSTAppRelayClient(paths: fixture.paths, host: fixture.hello, handler: { call in
            receipt.append(call); return .value(.object([.init("value", .string("first"))]))
        })
        addTeardownBlock { first.detach() }
        let before = try await http(fixture, token: token, tool: "fixture_read")
        XCTAssertEqual(before.0, 200); XCTAssertEqual(before.1["result"]["structuredContent"]["value"].string, "first")
        XCTAssertEqual(receipt.last?.context.sessionID, session); XCTAssertEqual(receipt.last?.context.machineID, "scratch-mac")
        XCTAssertEqual(receipt.last?.context.projectRoot, fixture.root.path); XCTAssertEqual(receipt.last?.taskProject, fixture.root.path + "/task")
        first.detach()
        // A nil app handler also has a deterministic detached-tool result,
        // regardless of the kernel's socket-disconnect notification timing.
        let during = try await http(fixture, token: token, tool: "fixture_read")
        XCTAssertEqual(during.0, 200); XCTAssertEqual(during.1["result"]["isError"].bool, true)
        XCTAssertEqual(try Data(contentsOf: config), originalConfig)
        let detached = await fixture.owner.projection(); XCTAssertEqual(detached.url, fixture.endpoint.url.absoluteString)
        XCTAssertEqual(detached.callerCount, 1); XCTAssertEqual(detached.leaseCount, 1)
        let second = try BackendHOSTAppRelayClient(paths: fixture.paths, host: fixture.hello, handler: { call in
            receipt.append(call); return .value(.object([.init("value", .string("second"))]))
        })
        addTeardownBlock { second.detach() }
        let after = try await http(fixture, token: token, tool: "fixture_read")
        XCTAssertEqual(after.1["result"]["structuredContent"]["value"].string, "second")
        XCTAssertEqual(try leaseToken(prepared).0, token); XCTAssertEqual(try Data(contentsOf: config), originalConfig)
        XCTAssertEqual(receipt.count, 2)
    }
    func testRealNativeServerRefusesWrongTokenDisallowedTierAndRevokedDynamicPermission() async throws {
        let fixture = try await fixture(), receipt = HOSTMCPReceipts(), token = try BackendAccountFiles.randomHex(bytes: 32)
        let registration = try await fixture.owner.endpoint.register(token: token, grant: .init(attended: false,
            allowedTools: ["fixture.read", "fixture_read", "fixture.alter", "fixture_alter"], allowedTiers: [.read], projectRoot: fixture.root.path,
            taskProject: fixture.root.path + "/task", permitted: { fixture.guardState.permitted }))
        try await fixture.owner.endpoint.bind(registration, sessionID: UUID().uuidString, machineID: "grant-mac")
        let app = try BackendHOSTAppRelayClient(paths: fixture.paths, host: fixture.hello, handler: { call in receipt.append(call); return .value(.object([])) })
        addTeardownBlock { app.detach() }
        let wrong = try await http(fixture, token: try BackendAccountFiles.randomHex(bytes: 32), tool: "fixture_read")
        XCTAssertEqual(wrong.0, 401)
        let tier = try await http(fixture, token: token, tool: "fixture_alter")
        XCTAssertEqual(tier.1["result"]["isError"].bool, true); XCTAssertEqual(receipt.count, 0)
        let accepted = try await http(fixture, token: token, tool: "fixture_read")
        XCTAssertEqual(accepted.1["result"]["isError"].bool, false)
        XCTAssertEqual(receipt.last?.context.allowedTiers, [.read]); XCTAssertEqual(receipt.last?.context.attended, false)
        fixture.guardState.setPermitted(false)
        let revoked = try await http(fixture, token: token, tool: "fixture_read")
        XCTAssertEqual(revoked.1["result"]["isError"].bool, true); XCTAssertEqual(receipt.count, 1)
    }
    func testCurrentAppHandlerMayRefuseAfterReattachWithoutChangingOriginalGrant() async throws {
        let fixture = try await fixture(), token = try BackendAccountFiles.randomHex(bytes: 32)
        let registration = try await fixture.owner.endpoint.register(token: token, grant: .init(attended: true, allowedTools: ["fixture.read", "fixture_read"], allowedTiers: [.read]))
        try await fixture.owner.endpoint.bind(registration, sessionID: UUID().uuidString, machineID: "")
        let app = try BackendHOSTAppRelayClient(paths: fixture.paths, host: fixture.hello, handler: { _ in .value(.object([])) })
        addTeardownBlock { app.detach() }
        let before = try await http(fixture, token: token, tool: "fixture_read")
        XCTAssertEqual(before.1["result"]["isError"].bool, false)
        app.setHandler { _ in throw BackendHOSTFailure.authentication }
        let refused = try await http(fixture, token: token, tool: "fixture_read"), projection = await fixture.owner.projection()
        XCTAssertEqual(refused.1["result"]["isError"].bool, true)
        XCTAssertEqual(projection.callerCount, 1)
    }
    func testSafeProjectionContainsNoCallerTokenAndStopRequiresActualDrain() async throws {
        let fixture = try await fixture(), token = try BackendAccountFiles.randomHex(bytes: 32)
        let registration = try await fixture.owner.endpoint.register(token: token, grant: .init(attended: true, allowedTools: ["fixture.read", "fixture_read"], allowedTiers: [.read]))
        try await fixture.owner.endpoint.bind(registration, sessionID: UUID().uuidString, machineID: "")
        let value = await fixture.owner.projection(), data = try JSONEncoder().encode(value)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(token))
        do { try await fixture.owner.stopAfterSessionsDrained(); XCTFail("Live resources must keep their MCP owner.") }
        catch {}
        let retained = await fixture.owner.projection(); XCTAssertEqual(retained.callerCount, 1)
        fixture.guardState.setDrained(true); try await fixture.owner.stopAfterSessionsDrained()
        let stopped = await fixture.owner.projection(); XCTAssertNil(stopped.url); XCTAssertEqual(stopped.callerCount, 0)
    }
    func testCancellationReachesAttachedHandlerWithoutRevokingPersistentCaller() async throws {
        let fixture = try await fixture(), received = expectation(description: "handler received call"), cancelled = expectation(description: "handler cancelled")
        let token = try BackendAccountFiles.randomHex(bytes: 32), id = UUID().uuidString
        let registration = try await fixture.owner.endpoint.register(token: token,
            grant: .init(attended: false, allowedTools: ["fixture.read", "fixture_read"], allowedTiers: [.read]))
        try await fixture.owner.endpoint.bind(registration, sessionID: UUID().uuidString, machineID: "cancel-mac")
        let app = try BackendHOSTAppRelayClient(paths: fixture.paths, host: fixture.hello, handler: { call in
            let token = call.context.cancellation.observe { cancelled.fulfill() }
            defer { call.context.cancellation.removeObserver(token) }
            received.fulfill()
            do { try await Task.sleep(for: .seconds(60)) } catch {}
            return .value(.object([]))
        })
        addTeardownBlock { app.detach() }
        let request = Task { try await self.http(fixture, token: token, tool: "fixture_read", id: id) }
        await fulfillment(of: [received], timeout: 5)
        var notification = URLRequest(url: fixture.endpoint.url); notification.httpMethod = "POST"
        notification.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        notification.httpBody = try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("method", .string("notifications/cancelled")),
            .init("params", .object([.init("requestId", .string(id))]))]).encodedJSON()
        _ = try await URLSession.shared.data(for: notification)
        await fulfillment(of: [cancelled], timeout: 5)
        let answer = try await request.value; XCTAssertEqual(answer.1["result"]["isError"].bool, true)
        XCTAssertEqual(fixture.relay.projection().pendingCalls, 0)
        let retained = await fixture.owner.projection(); XCTAssertEqual(retained.callerCount, 1)
        app.setHandler { _ in .value(.object([])) }
        let following = try await http(fixture, token: token, tool: "fixture_read")
        XCTAssertEqual(following.1["result"]["isError"].bool, false)
    }
    func testHostInstanceMismatchCannotReplaceCurrentAppBinding() async throws {
        let fixture = try await fixture()
        let app = try BackendHOSTAppRelayClient(paths: fixture.paths, host: fixture.hello, handler: { _ in .value(.object([])) })
        addTeardownBlock { app.detach() }
        var wrong = fixture.hello; wrong.instance = UUID()
        XCTAssertThrowsError(try BackendHOSTAppRelayClient(paths: fixture.paths, host: wrong, handler: { _ in .value(.object([])) }))
        XCTAssertTrue(fixture.relay.projection().attached)
    }
    func testForgedClaimedAppPidCannotReplaceCurrentKernelPeerBinding() async throws {
        let fixture = try await fixture()
        let app = try BackendHOSTAppRelayClient(paths: fixture.paths, host: fixture.hello, handler: { _ in .value(.object([])) })
        addTeardownBlock { app.detach() }
        let fd = try BackendHOSTSocket.connect(fixture.paths.directory.appendingPathComponent("app-relay.sock").path)
        defer { Darwin.close(fd) }
        var frame = BackendHOSTAppRelayProtocol.Frame(.attach, instance: fixture.hello.instance)
        frame.secret = try fixture.paths.secret(create: false); frame.pid = getpid() + 1
        try BackendHOSTSocket.write(frame, to: fd, maximum: BackendHOSTAppRelayProtocol.maximumHandshake)
        XCTAssertThrowsError(try BackendHOSTSocket.read(BackendHOSTAppRelayProtocol.Frame.self, from: fd))
        XCTAssertEqual(fixture.relay.projection().appPID, getpid())
    }
}

private final class HOSTMCPGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var permission = true, drain = false
    var permitted: Bool { lock.withLock { permission } }
    var drained: Bool { lock.withLock { drain } }
    func setPermitted(_ value: Bool) { lock.withLock { permission = value } }
    func setDrained(_ value: Bool) { lock.withLock { drain = value } }
}
private final class HOSTMCPReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [BackendHOSTAppRelayCall] = []
    var count: Int { lock.withLock { calls.count } }
    var last: BackendHOSTAppRelayCall? { lock.withLock { calls.last } }
    func append(_ call: BackendHOSTAppRelayCall) { lock.withLock { calls.append(call) } }
}
