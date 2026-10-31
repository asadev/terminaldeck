import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatProviderTerminalsTests: XCTestCase, @unchecked Sendable {
    private actor Wire {
        var calls: [(String, NativeRPCValue)] = []
        let replies: [NativeRPCValue]
        init(_ replies: [NativeRPCValue] = []) { self.replies = replies }
        func request(_ method: String, _ params: NativeRPCValue) -> NativeRPCValue {
            let index = calls.count; calls.append((method, params))
            return replies.isEmpty ? .object([]) : replies[min(index, replies.count - 1)]
        }
        func recorded() -> [(String, NativeRPCValue)] { calls }
    }
    private func json(_ value: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(value.utf8)) }
    private func pair(_ process: String = "process-1", _ item: String = "item-1") -> NativeRPCValue {
        .object([.init("processId", .string(process)), .init("itemId", .string(item))])
    }
    private func invoke(_ operation: String, _ arguments: NativeRPCValue = .object([]), provider: HootChatProvider = .codex, wire: Wire) async throws -> NativeRPCValue {
        try await BackendChatProviderTerminals.invoke(operation: operation, arguments: arguments, provider: provider,
            conversation: "own-thread", cwd: "/scratch", request: { method, params in await wire.request(method, params) })
    }
    func testInventoryUsesExactOwningThreadAndDoesNotExposeAnOSPIDDoor() async throws {
        let wire = Wire([try json(#"{"data":[{"processId":"process-1","itemId":"item-1","command":"sleep 10","cwd":"/scratch","osPid":1234}],"nextCursor":"next"}"#)])
        let result = try await invoke("terminals/list", try json(#"{"limit":10,"cursor":"page"}"#), wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["thread/backgroundTerminals/list"])
        XCTAssertEqual(calls[0].1["threadId"].string, "own-thread")
        XCTAssertEqual(calls[0].1["cursor"].string, "page")
        let row = try XCTUnwrap(result["terminals"].elements?.first)
        XCTAssertEqual(row["processId"].string, "process-1")
        XCTAssertEqual(row["itemId"].string, "item-1")
        XCTAssertTrue(row["osPid"].isNullish)
        XCTAssertEqual(row["canWrite"].bool, false)
        XCTAssertEqual(result["nextCursor"].string, "next")
    }
    func testReadUsesRecordedThreadItemOutputAndIncludesVersionReceipt() async throws {
        let wire = Wire([try json(#"{"data":[{"turnId":"turn-1","item":{"id":"item-1","type":"commandExecution","processId":"process-1","command":"echo hello","cwd":"/scratch","status":"completed","aggregatedOutput":"hello\n","exitCode":0}}]}"#)])
        let result = try await invoke("terminals/read", pair(), wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["thread/items/list"])
        XCTAssertEqual(calls[0].1["threadId"].string, "own-thread")
        XCTAssertEqual(result["output"].string, "hello\n")
        XCTAssertEqual(result["outputAvailable"].bool, true)
        XCTAssertEqual(result["outputBytes"].number, 6)
        XCTAssertEqual(result["outputSHA256"].string, "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
        XCTAssertEqual(result["exitCode"].number, 0)
        XCTAssertEqual(result["source"].string, "thread/items/list")
    }
    func testMissingProviderOutputRemainsUnavailableRatherThanEmptyProof() async throws {
        let wire = Wire([try json(#"{"data":[{"turnId":"turn-1","item":{"id":"item-1","type":"commandExecution","processId":"process-1","status":"inProgress","aggregatedOutput":null}}]}"#)])
        let result = try await invoke("terminals/read", pair(), wire: wire)
        XCTAssertEqual(result["outputAvailable"].bool, false)
        XCTAssertTrue(result["output"].isNullish)
        XCTAssertTrue(result["outputSHA256"].isNullish)
    }
    func testReadRejectsAnItemForAnotherProcess() async throws {
        let wire = Wire([try json(#"{"data":[{"turnId":"turn-1","item":{"id":"item-1","type":"commandExecution","processId":"foreign","aggregatedOutput":"private"}}]}"#)])
        do { _ = try await invoke("terminals/read", pair(), wire: wire); XCTFail("Foreign process output accepted") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
    }
    func testStopRechecksCompleteFreshInventoryThenTargetsOnlyItsThreadProcess() async throws {
        let wire = Wire([try json(#"{"data":[],"nextCursor":"page-2"}"#),
                         try json(#"{"data":[{"processId":"process-1","itemId":"item-1","command":"sleep 10","cwd":"/scratch"}],"nextCursor":null}"#), .object([])])
        let result = try await invoke("terminals/stop", pair(), wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["thread/backgroundTerminals/list", "thread/backgroundTerminals/list", "thread/backgroundTerminals/terminate"])
        XCTAssertTrue(calls.allSatisfy { $0.1["threadId"].string == "own-thread" })
        XCTAssertEqual(calls[2].1["processId"].string, "process-1")
        XCTAssertTrue(calls[2].1["osPid"].isNullish)
        XCTAssertEqual(result["terminationRequested"].bool, true)
        XCTAssertEqual(result["stoppedConfirmed"].bool, false)
    }
    func testStopRejectsUnknownReusedAndAmbiguousProcessIdentity() async throws {
        for response in [
            #"{"data":[]}"#,
            #"{"data":[{"processId":"process-1","itemId":"new-item"}]}"#,
            #"{"data":[{"processId":"process-1","itemId":"item-1"},{"processId":"process-1","itemId":"other"}]}"#,
        ] {
            let wire = Wire([try json(response)])
            do { _ = try await invoke("terminals/stop", pair(), wire: wire); XCTFail("Unowned terminal stop accepted") }
            catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
            let calls = await wire.recorded(); XCTAssertEqual(calls.map(\.0), ["thread/backgroundTerminals/list"])
        }
    }
    func testCleanupUsesOnlyDedicatedThreadEndpoint() async throws {
        let wire = Wire()
        let result = try await invoke("terminals/clean", wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["thread/backgroundTerminals/clean"])
        XCTAssertEqual(calls[0].1["threadId"].string, "own-thread")
        XCTAssertEqual(result["requested"].bool, true)
        XCTAssertEqual(result["requiresRefresh"].bool, true)
    }
    func testUnavailableInteractiveOperationsNeverUseUnsandboxedOrConnectionScopedFallback() async throws {
        let wire = Wire()
        for operation in ["terminals/create", "terminals/write", "terminals/resize", "terminals/foreground"] {
            let result = try await invoke(operation, .object([]), wire: wire)
            XCTAssertEqual(result["availability"].string, "unavailable")
            XCTAssertEqual(result["performed"].bool, false)
        }
        let claude = try await invoke("terminals/list", provider: .claude, wire: wire)
        let gemini = try await invoke("terminals/list", provider: .gemini, wire: wire)
        XCTAssertEqual(claude["availability"].string, "unavailable")
        XCTAssertEqual(gemini["availability"].string, "unavailable")
        let calls = await wire.recorded(); XCTAssertTrue(calls.isEmpty)
    }
    func testCallerCannotInjectThreadPIDCommandOrApprovalOverride() async throws {
        let wire = Wire()
        for key in ["threadId", "osPid", "command", "approvalPolicy", "sandboxPolicy"] {
            do {
                _ = try await invoke("terminals/stop", pair().setting(key, .string("foreign")), wire: wire)
                XCTFail("Injected terminal authority accepted: " + key)
            } catch {}
        }
        let calls = await wire.recorded(); XCTAssertTrue(calls.isEmpty)
    }
    func testLoopingProviderPagesCannotAuthorizeTermination() async throws {
        let wire = Wire([try json(#"{"data":[],"nextCursor":"loop"}"#)])
        do { _ = try await invoke("terminals/stop", pair(), wire: wire); XCTFail("Looping inventory accepted") } catch {}
        let calls = await wire.recorded(); XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.0 == "thread/backgroundTerminals/list" })
    }
    func testOutputClipKeepsValidUTF8AndReportsFullByteCount() async throws {
        let output = String(repeating: "🦉", count: 40_000)
        let item = NativeRPCValue.object([.init("id", .string("item-1")), .init("type", .string("commandExecution")),
            .init("processId", .string("process-1")), .init("aggregatedOutput", .string(output))])
        let wire = Wire([.object([.init("data", .array([.object([.init("item", item), .init("turnId", .string("turn-1"))])]))])])
        let result = try await invoke("terminals/read", pair(), wire: wire)
        XCTAssertEqual(result["truncated"].bool, true)
        XCTAssertEqual(result["outputBytes"].number, 160_000)
        XCTAssertLessThanOrEqual(result["output"].string?.utf8.count ?? .max, 131_072)
        XCTAssertFalse(result["output"].string?.contains("�") == true)
    }
}
