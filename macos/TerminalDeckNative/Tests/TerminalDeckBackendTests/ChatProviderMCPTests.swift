import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatProviderMCPTests: XCTestCase, @unchecked Sendable {
    private actor Wire {
        var calls: [(String, NativeRPCValue)] = []
        let replies: [NativeRPCValue]
        init(_ replies: [NativeRPCValue]) { self.replies = replies }
        func request(_ method: String, _ params: NativeRPCValue) -> NativeRPCValue {
            let index = calls.count; calls.append((method, params))
            return replies.isEmpty ? .object([]) : replies[min(index, replies.count - 1)]
        }
        func recorded() -> [(String, NativeRPCValue)] { calls }
    }
    private func json(_ value: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(value.utf8)) }
    private func invoke(_ operation: String, _ args: NativeRPCValue = .object([]), provider: HootChatProvider = .codex,
                        conversation: String? = "own-thread", wire: Wire) async throws -> NativeRPCValue {
        try await BackendChatProviderMCP.invoke(operation: operation, arguments: args, provider: provider,
            conversation: conversation, cwd: "/scratch", request: { method, params in await wire.request(method, params) })
    }
    func testCodexStatusUsesThisThreadAndPreservesDiscoveryFailure() async throws {
        let wire = Wire([try json(#"{"data":[{"name":"scratch","runtimeStatus":"failed","authStatus":"notLoggedIn","toolsError":"Discovery failed","httpOrigin":"https://example.test/private?token=hidden","tools":{},"resources":[],"resourceTemplates":[]}],"nextCursor":"page-2"}"#)])
        let result = try await invoke("mcp/status", try json(#"{"cursor":"page-1"}"#), wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "mcpServerStatus/list")
        XCTAssertEqual(calls[0].1["threadId"].string, "own-thread")
        XCTAssertEqual(calls[0].1["detail"].string, "full")
        XCTAssertEqual(calls[0].1["cursor"].string, "page-1")
        let row = try XCTUnwrap(result["servers"].elements?.first)
        XCTAssertEqual(result["scope"].string, "provider-session")
        XCTAssertEqual(result["nextCursor"].string, "page-2")
        XCTAssertEqual(row["status"].string, "failed")
        XCTAssertEqual(row["error"].string, "Discovery failed")
        XCTAssertEqual(row["origin"].string, "https://example.test")
        XCTAssertEqual(row["canAuth"].bool, true)
        XCTAssertEqual(row["canReconnect"].bool, false)
    }
    func testCatalogPresenceDoesNotPretendAnUnknownRuntimeIsConnected() async throws {
        let wire = Wire([try json(#"{"data":[{"name":"scratch","runtimeStatus":null,"authStatus":"unknown","tools":{"read":{"name":"read","description":"Read a file"}}}]}"#)])
        let result = try await invoke("mcp/status", wire: wire)
        let row = try XCTUnwrap(result["servers"].elements?.first)
        XCTAssertEqual(row["status"].string, "not-reported")
        XCTAssertEqual(row["toolCount"].number, 1)
        XCTAssertTrue(row["providerStatus"].isNullish)
    }
    func testClaudeDetailsKeepSourceAndRemovePrivateConfigurationAndSecrets() async throws {
        let wire = Wire([try json(#"{"mcpServers":[{"name":"scratch","status":"failed","source":"project","scope":"project","error":"Authorization: Bearer super-secret endpoint https://user:pass@example.test/path?key=hidden","error_code":"APPROVAL_REQUIRED","config":{"type":"http","url":"https://user:pass@example.test/private?token=hidden","headers":{"Authorization":"another-secret"},"env":{"KEY":"hidden"}},"tools":[{"name":"read","description":"Read a file","inputSchema":{"secret":"hidden"}}],"serverInfo":{"name":"Scratch","version":"1.0"}}]}"#)])
        let result = try await invoke("mcp/details", try json(#"{"name":"scratch"}"#), provider: .claude, wire: wire)
        let row = try XCTUnwrap(result["servers"].elements?.first)
        XCTAssertEqual(row["source"].string, "project")
        XCTAssertEqual(row["configScope"].string, "project")
        XCTAssertEqual(row["errorCode"].string, "APPROVAL_REQUIRED")
        XCTAssertEqual(row["origin"].string, "https://example.test")
        XCTAssertTrue(row["config"].isNullish)
        let encoded = String(decoding: try result.encodedJSON(), as: UTF8.self)
        for secret in ["super-secret", "another-secret", "hidden", "user:pass", "/private", "/path"] { XCTAssertFalse(encoded.contains(secret), secret) }
    }
    func testCodexAuthValidatesServerAndUsesThreadScopedOAuth() async throws {
        let wire = Wire([try json(#"{"data":[{"name":"scratch","runtimeStatus":"authenticationRequired","authStatus":"notLoggedIn","tools":{}}]}"#),
                         try json(#"{"authorizationUrl":"https://auth.example.test/authorize?state=expected","accessToken":"do-not-show"}"#)])
        let result = try await invoke("mcp/auth", try json(#"{"name":"scratch","scopes":["arbitrary"],"threadId":"foreign"}"#), wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["mcpServerStatus/list", "mcpServer/oauth/login"])
        XCTAssertEqual(calls[0].1["serverName"].string, "scratch")
        XCTAssertEqual(calls[1].1["name"].string, "scratch")
        XCTAssertEqual(calls[1].1["threadId"].string, "own-thread")
        XCTAssertTrue(calls[1].1["scopes"].isNullish)
        XCTAssertEqual(result["authorizationUrl"].string, "https://auth.example.test/authorize?state=expected")
        XCTAssertEqual(result["authenticated"].bool, false)
        XCTAssertTrue(result["accessToken"].isNullish)
    }
    func testClaudeAuthUsesInstalledControlAndNormalizesURL() async throws {
        let wire = Wire([try json(#"{"mcpServers":[{"name":"scratch","status":"needs-auth","config":{"type":"http"}}]}"#),
                         try json(#"{"authUrl":"https://auth.example.test/authorize?state=expected","requiresUserAction":true,"callbackExpected":true,"state":"private-state"}"#)])
        let result = try await invoke("mcp/auth", try json(#"{"id":"scratch"}"#), provider: .claude, wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["mcp_status", "mcp_authenticate"])
        XCTAssertEqual(calls[1].1["serverName"].string, "scratch")
        XCTAssertEqual(result["authorizationUrl"].string, "https://auth.example.test/authorize?state=expected")
        XCTAssertEqual(result["callbackExpected"].bool, true)
        XCTAssertTrue(result["state"].isNullish)
    }
    func testClaudeReconnectReadsResultInsteadOfAssumingSuccess() async throws {
        let failed = try json(#"{"mcpServers":[{"name":"scratch","status":"failed","config":{"type":"http"}}]}"#)
        let connected = try json(#"{"mcpServers":[{"name":"scratch","status":"connected","config":{"type":"http"}}]}"#)
        let wire = Wire([failed, .object([]), connected])
        let result = try await invoke("mcp/reconnect", try json(#"{"name":"scratch"}"#), provider: .claude, wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["mcp_status", "mcp_reconnect", "mcp_status"])
        XCTAssertEqual(calls[1].1["serverName"].string, "scratch")
        XCTAssertEqual(result["reconnected"].bool, true)
        XCTAssertEqual(result["servers"].elements?.first?["status"].string, "connected")
    }
    func testCodexReloadRequiresExplicitModeAndNeverClaimsReconnect() async throws {
        let inventory = try json(#"{"data":[{"name":"scratch","runtimeStatus":"failed","authStatus":"unknown","tools":{}}]}"#)
        let deniedWire = Wire([inventory])
        let denied = try await invoke("mcp/reconnect", try json(#"{"name":"scratch"}"#), wire: deniedWire)
        XCTAssertEqual(denied["availability"].string, "unavailable")
        XCTAssertEqual(denied["requiredMode"].string, "reloadConfiguration")
        let deniedCalls = await deniedWire.recorded(); XCTAssertEqual(deniedCalls.count, 1)
        let wire = Wire([inventory, .object([])])
        let result = try await invoke("mcp/reconnect", try json(#"{"name":"scratch","mode":"reloadConfiguration"}"#), wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["mcpServerStatus/list", "config/mcpServer/reload"])
        XCTAssertEqual(calls[1].1, .null)
        XCTAssertEqual(result["action"].string, "reloadConfiguration")
        XCTAssertEqual(result["reconnected"].bool, false)
        XCTAssertEqual(result["statusIsBeforeAction"].bool, true)
    }
    func testUnknownOrDisabledServerCannotBeMutated() async throws {
        let wire = Wire([try json(#"{"mcpServers":[{"name":"scratch","status":"disabled"}]}"#)])
        let disabled = try await invoke("mcp/reconnect", try json(#"{"name":"scratch"}"#), provider: .claude, wire: wire)
        XCTAssertEqual(disabled["availability"].string, "unavailable")
        do {
            _ = try await invoke("mcp/auth", try json(#"{"name":"foreign"}"#), provider: .claude, wire: wire)
            XCTFail("Accepted an unknown server")
        } catch {}
        let calls = await wire.recorded(); XCTAssertTrue(calls.allSatisfy { $0.0 == "mcp_status" })
    }
    func testProviderErrorsAreRedactedBeforeLeavingTheAdapter() async throws {
        do {
            _ = try await BackendChatProviderMCP.invoke(operation: "mcp/status", arguments: .object([]), provider: .codex,
                conversation: "own-thread", cwd: "/scratch", request: { _, _ in
                    throw NativeRPCError(code: "provider-error", message: "Authorization: Bearer secret-value at https://user:pass@example.test/path?token=hidden")
                })
            XCTFail("Provider failure was swallowed")
        } catch {
            XCTAssertEqual((error as? NativeRPCError)?.code, "provider-error")
            for secret in ["secret-value", "hidden", "user:pass", "/path"] { XCTAssertFalse(error.localizedDescription.contains(secret)) }
        }
    }
    func testMalformedInventoryCannotClaimAnEmptySuccessfulConnectionList() async throws {
        let wire = Wire([.object([])])
        do { _ = try await invoke("mcp/status", wire: wire); XCTFail("Malformed status accepted") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "provider-mcp-unavailable") }
    }
    func testUnsupportedOrUnreadyProviderDoesNotFallBackToGlobalStatus() async throws {
        let wire = Wire([])
        let gemini = try await invoke("mcp/status", provider: .gemini, wire: wire)
        let codex = try await invoke("mcp/status", conversation: nil, wire: wire)
        XCTAssertEqual(gemini["availability"].string, "unavailable")
        XCTAssertEqual(codex["availability"].string, "unavailable")
        let calls = await wire.recorded(); XCTAssertTrue(calls.isEmpty)
    }
}
