import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor RelayResourceOwner {
    var owner: BackendHOSTMCPPersistence?
    var callID: UUID?
    func bind(_ owner: BackendHOSTMCPPersistence) { self.owner = owner }
    func note(_ id: UUID) { callID = id }
    func lastID() -> UUID? { callID }
    func invoke(_ args: NativeRPCValue) async throws -> NativeRPCValue {
        guard let owner else { throw BackendHOSTFailure.unavailable }
        return try await owner.sessionCallerResource(args)
    }
}
final class HOSTRelayCallerResourceTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let paths: BackendHOSTPaths, server: BackendHOSTServer, owner: BackendHOSTMCPPersistence
        let endpoint: BackendMCPEndpointDescription, client: BackendHOSTClient, calls: RelayResourceOwner, token: String
    }
    private func fixture(legacy: Bool = false) async throws -> Fixture {
        // A private Unix socket path is limited to 104 bytes, so the usual per-user temp folder is too long.
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("td-relay-caller-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let calls = RelayResourceOwner(), manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "relay-caller-scratch", manager: manager,
            launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { _ in nil }, onIdle: {}, resource: { method, payload in
                guard method == "mcp.caller.current", !legacy else { throw BackendHOSTFailure.invalid("Unknown persistent resource operation.") }
                return try await calls.invoke(NativeRPCValue.parseJSON(payload)).encodedJSON()
            })
        addTeardownBlock { server.stopListening() }
        let relay = try BackendHOSTAppRelayServer(paths: paths, host: server.hello)
        let owner = try BackendHOSTMCPPersistence(server: BackendNativeMCPServer(), relay: relay, userData: root, sessionsDrained: { true })
        await calls.bind(owner)
        addTeardownBlock { try await owner.stopAfterSessionsDrained() }
        let tool = try BackendMCPTool(id: "fixture.read", wireName: "fixture_read", description: "Scratch retained-call read",
            inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .read)
        try await owner.installTools([tool]); let endpoint = try await owner.start()
        let prepared = try await owner.sessionTools.prepare(serverName: "deck-control", allowed: ["fixture.read"], projectRoot: root.path, taskProject: nil)
        try await owner.sessionTools.bind(prepared.id, sessionID: "scratch-session", machineID: "")
        let lease = try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(prepared.arguments.last))))
        let token = String(try XCTUnwrap(lease["mcpServers"]["deck-control"]["headers"]["Authorization"].string).dropFirst(7))
        return .init(paths: paths, server: server, owner: owner, endpoint: endpoint, client: try BackendHOSTClient(paths: paths), calls: calls, token: token)
    }
    private func attach(_ f: Fixture) throws -> BackendHOSTAppRelayClient {
        let app = try BackendHOSTAppRelayClient(paths: f.paths, host: f.server.hello, handler: { call in
            await f.calls.note(call.id)
            let args = NativeRPCValue.object([.init("callID", .string(call.id.uuidString))])
            let receipt = try await f.client.resource("mcp.caller.current", arguments: args)
            do {
                _ = try await f.client.resource("mcp.caller.current", arguments: args.setting("sessionID", .string("forged-session")))
                return .failure("Caller-provided session metadata was accepted")
            } catch {}
            return .value(receipt)
        })
        addTeardownBlock { app.detach() }
        return app
    }
    private func request(_ f: Fixture) async throws -> NativeRPCValue {
        var request = URLRequest(url: f.endpoint.url); request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("Bearer " + f.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", .string(UUID().uuidString)),
            .init("method", .string("tools/call")), .init("params", .object([.init("name", .string("fixture_read")), .init("arguments", .object([]))]))]).encodedJSON()
        let (data, _) = try await URLSession.shared.data(for: request)
        return try NativeRPCValue.parseJSON(data)
    }
    func testAuthenticatedResourceChecksRealPendingRelayThenRefusesReplayAndForgery() async throws {
        let f = try await fixture(), app = try attach(f)
        let result = try await request(f)
        XCTAssertEqual(result["result"]["isError"].bool, false, "\(result)")
        let receipt = result["result"]["structuredContent"]
        XCTAssertEqual(receipt["sessionID"].string, "scratch-session")
        XCTAssertEqual(receipt["toolID"].string, "fixture.read")
        let tools = Set(receipt["tools"].elements?.compactMap(\.string) ?? [])
        XCTAssertTrue(tools.contains("fixture.read"))
        XCTAssertTrue(tools.isSubset(of: ["fixture.read", "fixture_read"]), "Only the leased tool, never a wider list: \(tools)")
        XCTAssertTrue((receipt["tiers"].elements ?? []).contains(.string("read")))
        XCTAssertEqual(receipt["argumentsDigest"].string, try BackendHOSTSessionToolRelay.argumentsDigest(.object([])))
        XCTAssertTrue(receipt["token"].isNullish)
        let lastID = await f.calls.lastID()
        let id = try XCTUnwrap(lastID)
        do { _ = try await f.client.resource("mcp.caller.current", arguments: .object([.init("callID", .string(id.uuidString))])); XCTFail("Finished call ID was replayed") } catch {}
        do { _ = try await f.client.resource("mcp.caller.current", arguments: .object([.init("callID", .string(UUID().uuidString))])); XCTFail("Forged call ID was accepted") } catch {}
        app.detach()
    }
    func testReconnectUsesFreshAttachmentCallWithoutWideningRetainedGrant() async throws {
        let f = try await fixture(), first = try attach(f)
        let initial = try await request(f)
        XCTAssertEqual(initial["result"]["isError"].bool, false, "\(initial)")
        let firstID = await f.calls.lastID(); first.detach()
        let second = try attach(f)
        let next = try await request(f)
        XCTAssertEqual(next["result"]["isError"].bool, false)
        let nextID = await f.calls.lastID()
        XCTAssertNotEqual(firstID, nextID)
        XCTAssertTrue(Set(next["result"]["structuredContent"]["tools"].elements?.compactMap(\.string) ?? []).isSubset(of: ["fixture.read", "fixture_read"]))
        if let firstID {
            do { _ = try await f.client.resource("mcp.caller.current", arguments: .object([.init("callID", .string(firstID.uuidString))])); XCTFail("Old attachment call survived reconnect") } catch {}
        }
        let projection = await f.owner.projection()
        XCTAssertEqual(projection.callerCount, 1)
        second.detach()
    }
    func testOldHelperWithoutResourceFailsClosedAndKeepsItsGrant() async throws {
        let f = try await fixture(legacy: true), app = try attach(f)
        let result = try await request(f)
        XCTAssertEqual(result["result"]["isError"].bool, true)
        let projection = await f.owner.projection()
        XCTAssertEqual(projection.callerCount, 1)
        app.detach()
    }
}
