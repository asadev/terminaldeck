import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatProviderControlsTests: XCTestCase, @unchecked Sendable {
    private actor Wire {
        var calls: [(String, NativeRPCValue)] = []
        let response: NativeRPCValue
        init(_ response: NativeRPCValue = .object([])) { self.response = response }
        func request(_ method: String, _ params: NativeRPCValue) -> NativeRPCValue {
            calls.append((method, params)); return response
        }
        func recorded() -> [(String, NativeRPCValue)] { calls }
    }
    private func json(_ text: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(text.utf8)) }
    private func invoke(_ operation: String, _ args: NativeRPCValue = .object([]), provider: HootChatProvider = .codex, wire: Wire) async throws -> NativeRPCValue {
        try await BackendChatProviderControls.invoke(operation: operation, arguments: args, provider: provider,
            conversation: "own-thread", cwd: "/scratch", request: { method, params in await wire.request(method, params) })
    }
    func testGoalsUseRealStatusesAndReturnProviderProgress() async throws {
        let wire = Wire(try json(#"{"goal":{"objective":"Finish","status":"paused","tokenBudget":2000,"tokensUsed":10,"timeUsedSeconds":2}}"#))
        let read = try await invoke("goals/read", wire: wire)
        XCTAssertEqual(read["goal"]["tokensUsed"].number, 10)
        _ = try await invoke("goals/pause", wire: wire)
        _ = try await invoke("goals/resume", wire: wire)
        _ = try await invoke("goals/edit", try json(#"{"tokenBudget":null}"#), wire: wire)
        _ = try await invoke("goals/clear", wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["thread/goal/get", "thread/goal/set", "thread/goal/set", "thread/goal/set", "thread/goal/clear"])
        XCTAssertEqual(calls[1].1["status"].string, "paused")
        XCTAssertEqual(calls[2].1["status"].string, "active")
        XCTAssertEqual(calls[3].1["tokenBudget"], .null)
        XCTAssertTrue(calls.allSatisfy { $0.1["threadId"].string == "own-thread" })
    }
    func testUnavailableProvidersDoNotAttemptRPCOrPretendSuccess() async throws {
        let wire = Wire()
        for provider in [HootChatProvider.claude, .gemini] {
            let result = try await invoke("voice/start", provider: provider, wire: wire)
            XCTAssertEqual(result["availability"].string, "unavailable")
            XCTAssertEqual(result["transportSupported"].bool, false)
        }
        let calls = await wire.recorded(); XCTAssertTrue(calls.isEmpty)
    }
    func testPluginEnableVerifiesInventoryAndCannotWriteAnArbitraryConfigKey() async throws {
        let wire = Wire(try json(#"{"marketplaces":[{"plugins":[{"id":"a.b@market","installed":true}]}],"config":{"api_key":"secret"}}"#))
        let result = try await invoke("connections/enablePlugin", try json(#"{"id":"a.b@market","enabled":true,"keyPath":"approval_policy"}"#), wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["plugin/installed", "config/value/write"])
        XCTAssertEqual(calls[1].1["keyPath"].string, #"plugins."a.b@market".enabled"#)
        XCTAssertEqual(calls[1].1["value"].bool, true)
        XCTAssertEqual(result["effectiveOnNextConversation"].bool, true)
        XCTAssertTrue(result["providerResult"]["config"].isNullish)
        do {
            _ = try await invoke("connections/enablePlugin", try json(#"{"id":"unknown","enabled":false}"#), wire: wire)
            XCTFail("Unknown plugin accepted")
        } catch {}
        let after = await wire.recorded(); XCTAssertEqual(after.count, 3)
    }
    func testProviderConnectionsUseNativeInventoryAndOAuth() async throws {
        let wire = Wire()
        _ = try await invoke("connections/plugins", wire: wire)
        _ = try await invoke("connections/apps", try json(#"{"cursor":"page-2"}"#), wire: wire)
        _ = try await invoke("connections/auth", try json(#"{"name":"scratch-mcp"}"#), wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["plugin/list", "app/list", "mcpServer/oauth/login"])
        XCTAssertEqual(calls[0].1["cwds"], .array([.string("/scratch")]))
        XCTAssertEqual(calls[1].1["cursor"].string, "page-2")
        XCTAssertEqual(calls[2].1["name"].string, "scratch-mcp")
    }
    func testRealtimeUsesAppServerWebsocketTransportAndValidatedAudio() async throws {
        let wire = Wire()
        _ = try await invoke("voice/start", try json(#"{"voice":"marin"}"#), wire: wire)
        _ = try await invoke("voice/audio", try json(#"{"audio":{"data":"AAAAAA==","sampleRate":24000,"numChannels":1}}"#), wire: wire)
        _ = try await invoke("voice/text", try json(#"{"text":"Hello","role":"developer"}"#), wire: wire)
        _ = try await invoke("voice/stop", wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["thread/realtime/start", "thread/realtime/appendAudio", "thread/realtime/appendText", "thread/realtime/stop"])
        XCTAssertEqual(calls[0].1["transport"]["type"].string, "websocket")
        XCTAssertEqual(calls[0].1["outputModality"].string, "audio")
        XCTAssertEqual(calls[1].1["audio"]["samplesPerChannel"].number, 2)
        XCTAssertEqual(calls[2].1["role"].string, "user")
        do {
            _ = try await invoke("voice/audio", try json(#"{"audio":{"data":"invalid!","sampleRate":24000,"numChannels":1}}"#), wire: wire)
            XCTFail("Malformed audio accepted")
        } catch {}
        let after = await wire.recorded(); XCTAssertEqual(after.count, 4)
    }
    func testRealtimeEventsAreOwnedBoundedAndAudioIsExplicitlyEphemeral() throws {
        let value = try json(#"{"method":"thread/realtime/outputAudio/delta","params":{"threadId":"own-thread","audio":{"data":"AAAAAA==","sampleRate":24000,"numChannels":1,"credentials":"secret"}}}"#)
        XCTAssertNil(BackendChatProviderControls.notification(value, conversation: "foreign-thread"))
        let event = try XCTUnwrap(BackendChatProviderControls.notification(value, conversation: "own-thread"))
        XCTAssertEqual(event["ephemeralAudio"].bool, true)
        XCTAssertTrue(event["params"]["audio"]["credentials"].isNullish)
        let goal = try json(#"{"method":"thread/goal/updated","params":{"threadId":"own-thread","goal":{"objective":"Finish","tokensUsed":42,"apiKey":"secret"}}}"#)
        let progress = try XCTUnwrap(BackendChatProviderControls.notification(goal, conversation: "own-thread"))
        XCTAssertEqual(progress["params"]["goal"]["tokensUsed"].number, 42)
        XCTAssertTrue(progress["params"]["goal"]["apiKey"].isNullish)
    }
    func testSecretFieldsAreRemovedRecursively() throws {
        let result = BackendChatProviderControls.sanitized(try json(#"{"apps":[{"id":"safe","env":{"TOKEN":"secret"},"headers":{"Authorization":"secret"},"accessToken":"secret"}],"goal":{"tokenBudget":100}}"#))
        let app = try XCTUnwrap(result["apps"].elements?.first)
        XCTAssertTrue(app["env"].isNullish)
        XCTAssertTrue(app["headers"].isNullish)
        XCTAssertTrue(app["accessToken"].isNullish)
        XCTAssertEqual(result["goal"]["tokenBudget"].number, 100)
    }
}
