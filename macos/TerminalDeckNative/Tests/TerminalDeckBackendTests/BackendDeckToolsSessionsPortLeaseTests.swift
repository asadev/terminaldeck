import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendDeckToolsSessionsPortLeaseTests: XCTestCase {
    private typealias V = BackendDeckToolsSessionsPortValues
    private let six = ["browser_close", "browser_handover", "browser_open", "browser_read", "browser_screenshot", "browser_step"]
    private func using(network: Bool = false, _ operation: @MainActor (BackendDeckToolsSessionsPortTransport) async throws -> Void) async throws {
        let transport = try await BackendDeckToolsSessionsPortTransport(includeNetwork: network)
        do { try await operation(transport); await transport.close() } catch { await transport.close(); throw error }
    }
    private func prepare(_ lease: BackendDeckToolsSessionsElsewhereLeases, allowed: @escaping @Sendable () async -> Bool = { true }) async throws -> BackendDeckToolsSessionsPreparedElsewhere {
        let pending = try await lease.prepare(allowed: allowed); return try XCTUnwrap(pending)
    }
    func testSessionToolsL166NoEndpointMintsNoLocalLease() async throws {
        try await using { h in
            let missing = BackendDeckToolsSessionsPortEndpoint(specs: h.specs); await missing.setAvailable(false)
            let local = try BackendSessionToolLeases(endpoint: missing, userData: h.root)
            let facade = BackendDeckToolsSessionsLeaseFacade(local: local, endpoint: missing, clock: h.clock)
            let prepared = try await facade.prepare(); XCTAssertNil(prepared)
            let registered = await missing.snapshot(); XCTAssertEqual(registered.count, 0)
        }
    }
    func testSessionToolsL175OrdinaryGrantListsExactlySixBrowserVerbs() async throws {
        try await using { h in
            let (token, _) = try await h.registerOrdinary()
            let listing = try await h.exchange(token: token, method: "tools/list").value
            XCTAssertEqual(listing["result"]["tools"].elements?.compactMap { $0["name"].string }.sorted(), self.six)
        }
    }
    func testSessionToolsL193DescribeIndexOnlyIncludesGrantedHeldTools() async throws {
        try await using(network: true) { h in
            let (token, _) = try await h.registerOrdinary()
            let listing = try await h.exchange(token: token, method: "tools/list").value["result"]["tools"].elements ?? []
            XCTAssertEqual(listing.compactMap { $0["name"].string }.sorted(), self.six + ["tools_describe"])
            let description = listing.first { $0["name"].string == "tools_describe" }?["description"].string ?? ""
            XCTAssertTrue(description.contains("browser_network —")); XCTAssertFalse(description.contains("sessions_"))
            let fetched = try await h.call(token: token, name: "tools_describe", args: V.object([("tools", .array([.string("browser_network")]))]))
            XCTAssertEqual(fetched["structuredContent"]["tools"].elements?.first?["name"], .string("browser_network"))
            let hidden = try await h.call(token: token, name: "tools_describe", args: V.object([("tools", .array([.string("sessions_send"), .string("sessions_teleport")]))]))
            XCTAssertEqual(hidden["structuredContent"], V.object([("tools", .array([])), ("unknown", .array([.string("no tool called sessions_send"), .string("no tool called sessions_teleport")]))]))
        }
    }
    func testSessionToolsL314InitializeDescribesOnlyReachableBrowserSurface() async throws {
        try await using { h in
            let (token, _) = try await h.registerOrdinary()
            let initialized = try await h.exchange(token: token, method: "initialize", params: V.object([("protocolVersion", .string("2025-06-18")), ("clientInfo", V.object([("name", .string("test-session")), ("version", .string("0.0.0"))]))])).value
            let text = initialized["result"]["instructions"].string ?? ""
            XCTAssertTrue(text.contains("browser_open")); XCTAssertFalse(text.contains("the sessions running in it"))
        }
    }
    func testSessionToolsL329HiddenSessionDrivingCannotBeFoundOrCalled() async throws {
        try await using { h in
            let (token, _) = try await h.registerOrdinary()
            let names = try await h.exchange(token: token, method: "tools/list").value["result"]["tools"].elements?.compactMap { $0["name"].string } ?? []
            for hidden in ["sessions_list", "sessions_start", "sessions_send", "report", "brief"] { XCTAssertFalse(names.contains(hidden)) }
            let guessed = try await h.call(token: token, name: "sessions_send", args: V.object([("sessionId", .string("x")), ("text", .string("hi"))]))
            XCTAssertEqual(guessed["isError"], .bool(true)); XCTAssertTrue(guessed.compact.contains("no tool called sessions_send"))
        }
    }
    func testSessionToolsL347ReadUsesWindowAttachedToAuthenticatedSession() async throws {
        try await using { h in
            try h.attach(); let (token, _) = try await h.registerOrdinary()
            let read = try await h.call(token: token, name: "browser_read")
            XCTAssertNotEqual(read["isError"], .bool(true)); XCTAssertEqual(read["structuredContent"]["text"], .string("hello"))
            XCTAssertEqual(h.browserRuntime.observed, ["browser:1"])
        }
    }
    func testSessionToolsL359PersonAttachedWindowAcceptsAllRelevantVerbs() async throws {
        try await using { h in
            try h.attach(tab: "browser:9"); let (token, _) = try await h.registerOrdinary()
            for (name, args) in [
                ("browser_read", V.object([("window", .string("B1"))])),
                ("browser_step", V.object([("window", .string("B1")), ("verb", .string("click")), ("selector", .string("#go"))])),
                ("browser_screenshot", V.object([("window", .string("B1"))])),
                ("browser_open", V.object([("window", .string("B1")), ("url", .string("http://localhost:3000/next"))]))
            ] { let result = try await h.call(token: token, name: name, args: args); XCTAssertNotEqual(result["isError"], .bool(true), name) }
        }
    }
    func testSessionToolsL386UnknownWindowRefusalDoesNotNameForbiddenSessionTool() async throws {
        try await using { h in
            try h.attach(); let (token, _) = try await h.registerOrdinary()
            let refused = try await h.call(token: token, name: "browser_read", args: V.object([("window", .string("B7"))])), text = refused.compact
            XCTAssertFalse(text.contains("sessions.list")); XCTAssertFalse(text.contains("sessions_list")); XCTAssertTrue(text.contains("browser.open")); XCTAssertTrue(text.contains("menu"))
        }
    }
    func testSessionToolsL442ElsewhereConfigUsesFarLoopbackAddress() async throws {
        try await using { h in
            let lease = BackendDeckToolsSessionsElsewhereLeases(endpoint: h.endpoint, clock: h.clock), prepared = try await self.prepare(lease)
            let text = try prepared.configFor("http://127.0.0.1:40404/mcp")
            XCTAssertTrue(text.contains("http://127.0.0.1:40404/mcp")); XCTAssertFalse(text.contains(h.live?.url.absoluteString ?? "unset")); XCTAssertTrue(text.contains("Bearer "))
            await lease.stop()
        }
    }
    private func token(_ prepared: BackendDeckToolsSessionsPreparedElsewhere) throws -> String {
        let config = try NativeRPCValue.parseJSON(Data(prepared.configFor("http://127.0.0.1:40404/mcp").utf8))
        return String((config["mcpServers"]["deck-control"]["headers"]["Authorization"].string ?? "").dropFirst(7))
    }
    func testSessionToolsL452ElsewhereBindingUsesServerMachineKey() async throws {
        try await using { h in
            try h.attach(session: "srv-1 shell-9", machine: "srv-1")
            let leases = BackendDeckToolsSessionsElsewhereLeases(endpoint: h.endpoint, clock: h.clock), prepared = try await self.prepare(leases)
            try await prepared.started("srv-1 shell-9", "srv-1")
            let result = try await h.call(token: self.token(prepared), name: "browser_read")
            XCTAssertNotEqual(result["isError"], .bool(true)); XCTAssertEqual(h.browserRuntime.observed, ["browser:1"]); await leases.stop()
        }
    }
    func testSessionToolsL473ElsewhereHasOnlySixBrowserVerbs() async throws {
        try await using { h in
            let leases = BackendDeckToolsSessionsElsewhereLeases(endpoint: h.endpoint, clock: h.clock), prepared = try await self.prepare(leases)
            try await prepared.started("srv-1 shell-9", "srv-1")
            let names = try await h.exchange(token: self.token(prepared), method: "tools/list").value["result"]["tools"].elements?.compactMap { $0["name"].string }.sorted()
            XCTAssertEqual(names, self.six); XCTAssertFalse(names?.contains("sessions_send") == true); await leases.stop()
        }
    }
    func testSessionToolsL495FilesOnThisMacAreUnknownToElsewhereSession() async throws {
        try await using(network: true) { h in
            let leases = BackendDeckToolsSessionsElsewhereLeases(endpoint: h.endpoint, clock: h.clock), prepared = try await self.prepare(leases)
            try await prepared.started("srv-1 shell-9", "srv-1")
            let refused = try await h.call(token: self.token(prepared), name: "browser_network", args: V.object([("window", .string("B1"))]))
            XCTAssertEqual(refused["isError"], .bool(true)); XCTAssertTrue(refused.compact.contains("no tool called")); await leases.stop()
        }
    }
    func testSessionToolsL515ElsewhereSubtractsExactlyLocalFileAndDeviceKnowledgeFamilies() {
        let ordinary = BackendDeckToolsSessionsGrants.ordinary, elsewhere = BackendDeckToolsSessionsGrants.elsewhere
        for name in ["browser_network", "assets_fetch", "assets_ledger", "assets_coverage"] { XCTAssertTrue(ordinary.contains(name)); XCTAssertFalse(elsewhere.contains(name)) }
        for name in ["browser_open", "browser_read", "browser_step", "browser_workers", "browser_extract", "tools_describe"] { XCTAssertTrue(elsewhere.contains(name)) }
        XCTAssertTrue(elsewhere.isSubset(of: ordinary))
    }
    func testSessionToolsL530RemoteScreenshotRefusalProvidesUsableReadAlternative() async throws {
        try await using { h in
            try h.attach(session: "srv-1 shell-9", machine: "srv-1")
            let leases = BackendDeckToolsSessionsElsewhereLeases(endpoint: h.endpoint, clock: h.clock), prepared = try await self.prepare(leases)
            try await prepared.started("srv-1 shell-9", "srv-1")
            let refused = try await h.call(token: self.token(prepared), name: "browser_screenshot")
            XCTAssertEqual(refused["isError"], .bool(true)); XCTAssertTrue(refused.compact.contains("browser.read")); await leases.stop()
        }
    }
    func testSessionToolsL558RevokedPermissionRefusesVeryNextCallWithoutReconnect() async throws {
        try await using { h in
            try h.attach(session: "srv-1 shell-9", machine: "srv-1")
            let permission = BackendDeckCoreSecurityTestBox(true)
            let leases = BackendDeckToolsSessionsElsewhereLeases(endpoint: h.endpoint, clock: h.clock), prepared = try await self.prepare(leases, allowed: { permission.get() })
            try await prepared.started("srv-1 shell-9", "srv-1")
            let first = try await h.call(token: self.token(prepared), name: "browser_read"); XCTAssertNotEqual(first["isError"], .bool(true))
            permission.set(false)
            let refused = try await h.call(token: self.token(prepared), name: "browser_read")
            XCTAssertEqual(refused["isError"], .bool(true)); await leases.stop()
        }
    }
    func testSessionToolsL580DroppedElsewhereTokenNoLongerAuthenticates() async throws {
        try await using { h in
            let leases = BackendDeckToolsSessionsElsewhereLeases(endpoint: h.endpoint, clock: h.clock), prepared = try await self.prepare(leases)
            try await prepared.started("srv-1 shell-9", "srv-1"); let secret = try self.token(prepared)
            await prepared.drop(); let denied = try await h.exchange(token: secret, method: "tools/list")
            XCTAssertNotEqual(denied.status, 200); await leases.stop()
        }
    }
    func testSessionToolsL594NoEndpointMintsNoElsewhereLease() async throws {
        try await using { h in
            let endpoint = BackendDeckToolsSessionsPortEndpoint(specs: h.specs); await endpoint.setAvailable(false)
            let leases = BackendDeckToolsSessionsElsewhereLeases(endpoint: endpoint, clock: h.clock), prepared = try await leases.prepare(allowed: { true })
            XCTAssertNil(prepared); let count = await leases.count; XCTAssertEqual(count, 0)
        }
    }
    func testSessionToolsL601SessionReleaseRevokesSameElsewhereID() async throws {
        try await using { h in
            let leases = BackendDeckToolsSessionsElsewhereLeases(endpoint: h.endpoint, clock: h.clock), prepared = try await self.prepare(leases)
            try await prepared.started("srv-1 shell-9", "srv-1"); let secret = try self.token(prepared)
            await leases.release(sessionID: "srv-1 shell-9"); let denied = try await h.exchange(token: secret, method: "tools/list")
            XCTAssertNotEqual(denied.status, 200); let count = await leases.count; XCTAssertEqual(count, 0)
        }
    }
    func testSessionToolsL626EveryBrowserGrantHasBothSpellingsAndNoSessionDriving() {
        for id in ["browser.open", "browser.read", "browser.step", "browser.screenshot", "browser.handover", "browser.close"] {
            XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains(id)); XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains(id.replacingOccurrences(of: ".", with: "_")))
        }
        for id in ["sessions.start", "sessions_start", "sessions.send", "sessions_send", "report", "brief"] { XCTAssertFalse(BackendDeckToolsSessionsGrants.ordinary.contains(id)) }
    }
    func testSessionToolsL651NeitherGrantReadsFillsOrEnumeratesCredentials() {
        for name in BackendDeckToolsSessionsGrants.ordinary.union(BackendDeckToolsSessionsGrants.elsewhere) {
            XCTAssertNil(name.range(of: "password|passwd|login|credential|secret|keychain|autofill", options: [.regularExpression, .caseInsensitive]), name)
        }
        for name in ["browser.logins", "browser.password", "browser.fill", "browser.autofill", "browser.lift"] {
            for spelling in [name, name.replacingOccurrences(of: ".", with: "_")] { XCTAssertFalse(BackendDeckToolsSessionsGrants.ordinary.contains(spelling)); XCTAssertFalse(BackendDeckToolsSessionsGrants.elsewhere.contains(spelling)) }
        }
    }
    func testSessionToolsL683OrdinaryMayDriveEveryTestDeviceVerbButCannotShutDown() {
        for verb in ["list", "open", "screenshot", "tree", "find", "tap", "swipe", "type", "button", "annotations"] {
            XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains("devices." + verb)); XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains("devices_" + verb))
        }
        XCTAssertFalse(BackendDeckToolsSessionsGrants.ordinary.contains("devices.shutdown")); XCTAssertFalse(BackendDeckToolsSessionsGrants.ordinary.contains("devices_shutdown"))
    }
    func testSessionToolsL692ElsewhereHasNoDeviceCapability() {
        for name in BackendDeckToolsSessionsGrants.ordinary where name.hasPrefix("devices") { XCTAssertFalse(BackendDeckToolsSessionsGrants.elsewhere.contains(name), name) }
    }
    func testElsewherePendingClaimExpiresExactlyAtSixtySecondsWithFakeClock() async throws {
        try await using { h in
            let endpoint = BackendDeckToolsSessionsPortEndpoint(specs: h.specs), clock = BackendDeckToolsSessionsPortScheduler(0)
            let leases = BackendDeckToolsSessionsElsewhereLeases(endpoint: endpoint, clock: clock)
            _ = try await leases.prepare(allowed: { true }); let pending = await leases.count; XCTAssertEqual(pending, 1)
            XCTAssertEqual(clock.deadlines(), [60_000]); clock.advance(59_999); let stillPending = await leases.count; XCTAssertEqual(stillPending, 1)
            clock.advance(1); await endpoint.revoked.wait(1); let ended = await leases.count; XCTAssertEqual(ended, 0)
        }
    }
}
