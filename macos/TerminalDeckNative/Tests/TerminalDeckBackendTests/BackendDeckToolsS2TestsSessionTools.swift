import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// session-tools.test.ts cases that BackendDeckToolsSessionsPortLeaseTests left
/// as `_SeamNeeded` skips. The local lease's claim deadline is now injectable
/// (`BackendSessionToolLeases(endpoint:userData:clock:)`), so these run the real
/// BackendSessionToolLeases + BackendDeckToolsSessionsLeaseFacade against the
/// real deck-core security server, with a finite fake scheduler: no sleeps.
@MainActor final class BackendDeckToolsS2TestsSessionTools: XCTestCase {
    private typealias V = NativeRPCValue

    /// The shared session transport (real server/control/browser service) plus
    /// a real local lease facade over its endpoint, on its own fake scheduler.
    private func withLocal(_ operation: @MainActor (BackendDeckToolsSessionsPortTransport, BackendDeckToolsSessionsLeaseFacade, BackendDeckToolsSessionsPortScheduler) async throws -> Void) async throws {
        let transport = try await BackendDeckToolsSessionsPortTransport()
        let clock = BackendDeckToolsSessionsPortScheduler(0)
        let local: BackendSessionToolLeases
        do { local = try BackendSessionToolLeases(endpoint: transport.endpoint, userData: transport.root, clock: clock) } catch { await transport.close(); throw error }
        let facade = BackendDeckToolsSessionsLeaseFacade(local: local, endpoint: transport.endpoint, clock: clock)
        do { try await operation(transport, facade, clock); await facade.stop(); await transport.close() }
        catch { await facade.stop(); await transport.close(); throw error }
    }
    /// `configOf`: the path out of the `--mcp-config <path>` pair.
    private func configOf(_ prepared: BackendPreparedToolLease) throws -> String {
        let at = try XCTUnwrap(prepared.arguments.firstIndex(of: "--mcp-config"))
        XCTAssertGreaterThanOrEqual(at, 0)
        XCTAssertLessThan(at + 1, prepared.arguments.count)
        return prepared.arguments[at + 1]
    }
    /// The token a session would dial with, read back out of its own config file.
    private func token(file: String) throws -> String {
        let config = try V.parseJSON(Data(contentsOf: URL(fileURLWithPath: file)))
        let header = try XCTUnwrap(config["mcpServers"]["deck-control"]["headers"]["Authorization"].string)
        XCTAssertTrue(header.hasPrefix("Bearer "))
        return String(header.dropFirst(7))
    }
    /// The raw HTTP status of a tools/list dial. A revoked token is refused by the
    /// socket before a tool name is read, which is a transport error (non-200).
    private func dialStatus(_ h: BackendDeckToolsSessionsPortTransport, token: String) async throws -> Int {
        let body = try V.object([.init("jsonrpc", .string("2.0")), .init("id", .number(1)), .init("method", .string("tools/list")), .init("params", .object([]))]).encodedJSON()
        let response = await h.server.respond(.init(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:\(h.live?.port ?? 47821)", "authorization": "Bearer " + token,
            "content-type": "application/json", "accept": "application/json, text/event-stream"], body: body))
        return response.status
    }

    // L146 — adds the config without taking the person's own MCP servers away
    func testS2SessionToolsL146PrepareAddsConfigWithoutStrictMCPConfig() async throws {
        try await withLocal { h, tools, _ in
            let pending = try await tools.prepare()
            let prepared = try XCTUnwrap(pending)
            // `--strict-mcp-config` is the copilot's; an ordinary session keeps its own servers.
            XCTAssertFalse(prepared.arguments.contains("--strict-mcp-config"))
            XCTAssertEqual(prepared.arguments.first, "--mcp-config")
        }
    }

    // L155 — writes the token where only this account can read it
    func testS2SessionToolsL155ConfigHoldsEndpointAndBearerWithPrivateMode() async throws {
        try await withLocal { h, tools, _ in
            let pending = try await tools.prepare()
            let file = try self.configOf(try XCTUnwrap(pending))
            let written = try String(contentsOfFile: file, encoding: .utf8)
            let url = try XCTUnwrap(h.live?.url.absoluteString)
            XCTAssertTrue(written.contains(url))
            XCTAssertTrue(written.contains("Bearer "))
            let attributes = try FileManager.default.attributesOfItem(atPath: file)
            let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
            XCTAssertEqual(mode & 0o077, 0)
        }
    }

    // L409 — stops working the moment the session is gone
    func testS2SessionToolsL409ReleaseRevokesTokenAndRemovesConfig() async throws {
        try await withLocal { h, tools, _ in
            try h.attach(tab: "browser:1", session: "s1")
            let pending = try await tools.prepare()
            let prepared = try XCTUnwrap(pending)
            try await tools.local.bind(prepared.id, sessionID: "s1") // prepared.started('s1')
            let file = try self.configOf(prepared), secret = try self.token(file: file)
            let read = try await h.call(token: secret, name: "browser_read")
            XCTAssertNotEqual(read["isError"], .bool(true))

            await tools.release(sessionID: "s1")

            // Off the table: the dial is refused before any tool name is read.
            let status = try await self.dialStatus(h, token: secret)
            XCTAssertNotEqual(status, 200)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file))
            let size = await tools.size(); XCTAssertEqual(size, 0)
        }
    }

    // L614 — a token nobody claims is dropped rather than left live for the run
    func testS2SessionToolsL614UnclaimedTokenDroppedOnStop() async throws {
        try await withLocal { h, tools, clock in
            let pending = try await tools.prepare()
            let prepared = try XCTUnwrap(pending)
            let secret = try self.token(file: try self.configOf(prepared))
            let before = await tools.size(); XCTAssertEqual(before, 1)
            // The claim deadline is what covers a launch that throws before the pty exists.
            XCTAssertEqual(clock.deadlines(), [60_000])
            await tools.stop()
            let after = await tools.size(); XCTAssertEqual(after, 0)
            XCTAssertEqual(clock.pending(), 0)
            let status = try await self.dialStatus(h, token: secret)
            XCTAssertNotEqual(status, 200)
        }
    }

    // L260 — finds the phone tools in its index, taps one, and cannot shut a device down
    func testS2SessionToolsL260DeviceIndexTapAndShutdownUnknownOverSessionToken() async throws {
        let devices = BackendDeckCoreTestPortSessionsDeviceFixture()
        let f = try await BackendDeckCoreTestPortSessionsDoorFixture.make(network: true, devices: devices)
        do {
            let pending = try await f.leases.prepare()
            let prepared = try XCTUnwrap(pending)
            try await f.local.bind(prepared.id, sessionID: "s1") // prepared.started('s1')
            let token = try f.token(prepared)

            let listed = try await f.request("tools/list", token: token)["tools"].elements ?? []
            let meta = listed.first { $0["name"].string == "tools_describe" }?["description"].string ?? ""
            XCTAssertTrue(meta.contains("devices_tap —"))
            XCTAssertTrue(meta.contains("devices_tree —"))
            XCTAssertFalse(meta.contains("devices_shutdown"))
            let fetched = try await f.tool("tools_describe", args: .object([.init("tools", .array([.string("devices_tap")]))]), token: token)
            XCTAssertEqual(fetched["structuredContent"]["tools"].elements?.first?["name"].string, "devices_tap")

            let tapped = try await f.tool("devices_tap", args: .object([.init("deviceId", .string("ios:ABC-123")), .init("x", .number(0.5)), .init("y", .number(0.475))]), token: token)
            XCTAssertNotEqual(tapped["isError"], .bool(true))
            XCTAssertEqual(devices.calls.map(\.name), ["tap"])
            XCTAssertEqual(Array(devices.calls.first?.args.prefix(3) ?? []), [.string("ios:ABC-123"), .number(0.5), .number(0.475)])

            let stopped = try await f.tool("devices_shutdown", args: .object([.init("deviceId", .string("ios:ABC-123"))]), token: token)
            XCTAssertEqual(stopped["isError"], .bool(true))
            XCTAssertTrue(stopped["content"].compact.contains("no tool called"))
            XCTAssertFalse(devices.calls.map(\.name).contains("shutDown"))
            await f.close()
        } catch { await f.close(); throw error }
    }
}
