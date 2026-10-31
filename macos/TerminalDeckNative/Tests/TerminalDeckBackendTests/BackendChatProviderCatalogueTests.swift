import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendChatProviderCatalogueTests: XCTestCase, @unchecked Sendable {
    private actor Provider {
        var calls: [(String, NativeRPCValue)] = []
        let replies: [String: NativeRPCValue]
        init(_ replies: [String: NativeRPCValue]) { self.replies = replies }
        func request(_ method: String, _ params: NativeRPCValue) throws -> NativeRPCValue {
            calls.append((method, params))
            guard let reply = replies[method] else { throw NativeRPCError.malformed("Unexpected provider call: " + method) }
            return reply
        }
    }
    private func json(_ value: String) throws -> NativeRPCValue { try .parseJSON(Data(value.utf8)) }
    private func call(_ op: String, _ args: NativeRPCValue = .object([]), provider: HootChatProvider = .codex,
                      stub: Provider) async throws -> NativeRPCValue {
        try await BackendChatProviderCatalogue.invoke(operation: op, arguments: args, provider: provider,
            conversation: "current", cwd: "/scratch/project", request: { method, params in try await stub.request(method, params) })
    }

    func testCodexCatalogueRetainsIdentityPaginationAndExactProjectScope() async throws {
        let stub = Provider(["thread/list": try json(#"{"data":[{"id":"chosen","cwd":"/scratch/project","modelProvider":"custom","name":"Own thread","preview":"hello","updatedAt":12},{"id":"foreign","cwd":"/scratch/other"},{"id":"chosen","cwd":"/scratch/project"}],"nextCursor":"opaque-provider-page"}"#)])
        let response = try await call("catalogue/list", try json(#"{"cursor":"old-page","query":"Own","limit":5,"archived":true}"#), stub: stub)
        XCTAssertEqual(response["items"].elements?.count, 1)
        XCTAssertEqual(response["items"].elements?.first?["conversationId"].string, "chosen")
        XCTAssertEqual(response["items"].elements?.first?["provider"].string, "codex")
        XCTAssertEqual(response["items"].elements?.first?["modelProvider"].string, "custom")
        XCTAssertEqual(response["items"].elements?.first?["updatedAt"].number, 12_000)
        XCTAssertEqual(response["nextCursor"].string, "opaque-provider-page")
        let calls = await stub.calls
        XCTAssertEqual(calls.map(\.0), ["thread/list"])
        XCTAssertEqual(calls[0].1["cwd"].string, "/scratch/project")
        XCTAssertEqual(calls[0].1["searchTerm"].string, "Own")
        XCTAssertEqual(calls[0].1["cursor"].string, "old-page")
        XCTAssertEqual(calls[0].1["useStateDbOnly"].bool, true)
        XCTAssertEqual(calls[0].1["archived"].bool, true)
    }

    func testCodexPreviewReadsPagedTextWithoutResumeOrToolPayloads() async throws {
        let stub = Provider([
            "thread/read": try json(#"{"thread":{"id":"chosen","cwd":"/scratch/project","preview":"hello"}}"#),
            "thread/turns/list": try json(#"{"data":[{"id":"turn-one","items":[{"type":"userMessage","id":"u","content":[{"type":"text","text":"question"},{"type":"image","url":"not-a-text-preview"}]},{"type":"agentMessage","id":"a","text":"answer"},{"type":"commandExecution","command":"private tool payload"}]}],"nextCursor":"more-turns"}"#)])
        let response = try await call("catalogue/read", try json(#"{"conversationId":"chosen","cursor":"turn-page"}"#), stub: stub)
        XCTAssertEqual(response["conversationId"].string, "chosen")
        XCTAssertEqual(response["items"].elements?.compactMap { $0["text"].string }, ["question", "answer"])
        XCTAssertEqual(response["readOnly"].bool, true)
        XCTAssertEqual(response["nextCursor"].string, "more-turns")
        let calls = await stub.calls
        XCTAssertEqual(calls.map(\.0), ["thread/read", "thread/turns/list"])
        XCTAssertEqual(calls[0].1["includeTurns"].bool, false)
        XCTAssertEqual(calls[1].1["threadId"].string, "chosen")
        XCTAssertEqual(calls[1].1["itemsView"].string, "full")
        XCTAssertEqual(calls[1].1["cursor"].string, "turn-page")
    }

    func testPreviewRejectsDifferentCwdOrConversationBeforeReadingTurns() async throws {
        for metadata in [#"{"id":"chosen","cwd":"/scratch/other"}"#, #"{"id":"different","cwd":"/scratch/project"}"#] {
            let stub = Provider(["thread/read": try json("{\"thread\":" + metadata + "}")])
            do { _ = try await call("catalogue/read", try json(#"{"conversationId":"chosen"}"#), stub: stub); XCTFail("Foreign transcript admitted") }
            catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
            let calls = await stub.calls
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testSkillsUseProviderEnabledStatePathAndSupportedCommand() async throws {
        let stub = Provider(["skills/list": try json(#"{"data":[{"cwd":"/scratch/project","errors":[],"skills":[{"name":"ship","description":"Ship it","enabled":true,"path":"/skills/ship/SKILL.md","scope":"repo"},{"name":"off","enabled":false,"path":"/skills/off/SKILL.md"},{"name":"review","enabled":true,"path":"/skills/review/SKILL.md"}]},{"cwd":"/scratch/other","skills":[{"name":"foreign","enabled":true,"path":"/elsewhere"}]}]}"#)])
        let response = try await call("skills/list", stub: stub)
        let rows = try XCTUnwrap(response["items"].elements)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0]["path"].string, "/skills/ship/SKILL.md")
        XCTAssertEqual(rows[0]["command"].string, "/ship")
        XCTAssertEqual(rows[0]["invocable"].bool, true)
        XCTAssertEqual(rows[1]["enabled"].bool, false)
        XCTAssertEqual(rows[1]["invocable"].bool, false)
        XCTAssertEqual(rows[2]["invocable"].bool, false, "A built-in command cannot silently invoke a same-named skill")
    }

    func testInstructionManifestKeepsEffectiveOriginsAndDoesNotExposeUnrelatedConfig() async throws {
        let stub = Provider(["config/read": try json(#"{"config":{"developer_instructions":"Follow the project","mcp_servers":{"secret":{"headers":{"Authorization":"DO-NOT-FORWARD"}}},"api_key":"DO-NOT-FORWARD"},"origins":{"developer_instructions":{"name":{"type":"user","file":"/account/config.toml"},"version":"revision"}},"layers":[{"name":{"type":"project","dotCodexFolder":"/scratch/project/.codex"},"version":"r2","config":{"developer_instructions":"Project source","api_key":"DO-NOT-FORWARD"}}]}"#)])
        let response = try await call("instructions/read", stub: stub)
        XCTAssertEqual(response["items"].elements?.first?["value"].string, "Follow the project")
        XCTAssertEqual(response["items"].elements?.first?["origin"]["file"].string, "/account/config.toml")
        XCTAssertEqual(response["layers"].elements?.first?["source"]["projectDirectory"].string, "/scratch/project/.codex")
        XCTAssertEqual(response["complete"].bool, false)
        XCTAssertFalse(String(decoding: try response.encodedJSON(), as: UTF8.self).contains("DO-NOT-FORWARD"))
    }

    /// F62: the provider's own `instructionSources` reply is the applied manifest; nothing else is inferred.
    func testAppliedInstructionFilesComeOnlyFromACurrentProviderReceipt() async throws {
        let config = try json(#"{"config":{"developer_instructions":"Follow the project"},"origins":{"developer_instructions":{"name":{"type":"user","file":"/account/config.toml"},"version":"v1"}},"layers":[]}"#)
        let thread = try json(#"{"thread":{"id":"current"},"instructionSources":["/scratch/project/AGENTS.md","/account/AGENTS.md"]}"#)
        let receipt = try XCTUnwrap(BackendChatProviderPolicy.instructionReceipt(thread, conversation: "current", source: "thread/resume"))
        let stub = Provider(["config/read": config])
        let withReceipt = try await BackendChatProviderCatalogue.invoke(operation: "instructions/read", arguments: .object([]), provider: .codex,
            conversation: "current", cwd: "/scratch/project", appliedInstructions: receipt, request: { m, p in try await stub.request(m, p) })
        XCTAssertEqual(withReceipt["complete"].bool, true)
        XCTAssertEqual(withReceipt["appliedInstructionFiles"].elements?.compactMap(\.string), ["/scratch/project/AGENTS.md", "/account/AGENTS.md"])
        XCTAssertEqual(withReceipt["items"].elements?.first?["basis"].string, "provider-loaded-instruction-file")
        XCTAssertEqual(withReceipt["items"].elements?.last?["value"].string, "Follow the project")
        // A receipt for another conversation, or none at all, never claims a complete manifest.
        let other = try await BackendChatProviderCatalogue.invoke(operation: "instructions/read", arguments: .object([]), provider: .codex,
            conversation: "different", cwd: "/scratch/project", appliedInstructions: receipt, request: { m, p in try await stub.request(m, p) })
        XCTAssertEqual(other["complete"].bool, false)
        XCTAssertTrue(other["appliedInstructionFiles"].isNullish)
        let none = try await call("instructions/read", stub: stub)
        XCTAssertEqual(none["complete"].bool, false)
    }

    func testInstructionReceiptRejectsRelativeMissingAndForeignReplies() throws {
        let good = try json(#"{"thread":{"id":"c"},"instructionSources":["/a/AGENTS.md"]}"#)
        XCTAssertNotNil(BackendChatProviderPolicy.instructionReceipt(good, conversation: "c", source: "thread/start"))
        XCTAssertNil(BackendChatProviderPolicy.instructionReceipt(good, conversation: "other", source: "thread/start"))
        XCTAssertNil(BackendChatProviderPolicy.instructionReceipt(good, conversation: "c", source: "thread/list"))
        XCTAssertNil(BackendChatProviderPolicy.instructionReceipt(try json(#"{"thread":{"id":"c"},"instructionSources":["relative/AGENTS.md"]}"#), conversation: "c", source: "thread/start"))
        XCTAssertNil(BackendChatProviderPolicy.instructionReceipt(try json(#"{"thread":{"id":"c"}}"#), conversation: "c", source: "thread/start"), "Older CLIs report no manifest")
    }

    func testUnverifiedProviderDoesNotMakeInventedRPCsAndInvalidLimitsDoNotReachProvider() async throws {
        let stub = Provider([:])
        let response = try await call("skills/list", provider: .gemini, stub: stub)
        XCTAssertEqual(response["available"].bool, false)
        for value in [#"{"limit":0}"#, #"{"limit":1000}"#, #"{"limit":1.5}"#] {
            do { _ = try await call("catalogue/list", try json(value), stub: stub); XCTFail("Invalid page size admitted") } catch {}
        }
        let calls = await stub.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testClaudeCatalogueProvesMetadataAndAccountScopeDespiteEncodedDirectoryCollision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sess-catalogue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/scratch/a-b", collision = "/scratch/a/b"
        XCTAssertEqual(NativeTranscriptPaths.encodeProjectPath(cwd), NativeTranscriptPaths.encodeProjectPath(collision))
        let directory = root.appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(cwd))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func write(_ id: String, _ project: String, metadataID: String? = nil) throws {
            let row: [String: Any] = ["type": "user", "uuid": id, "sessionId": metadataID ?? id, "cwd": project, "message": ["content": "message " + id]]
            var bytes = try JSONSerialization.data(withJSONObject: row); bytes.append(10)
            try bytes.write(to: directory.appendingPathComponent(id + ".jsonl"))
        }
        try write("own", cwd); try write("foreign", collision); try write("false-id", cwd, metadataID: "actual-id")
        let scope = NativeTranscriptScope(configDirectory: root.path, projectFolders: [cwd])
        let response = try await BackendChatProviderCatalogue.claude(operation: "catalogue/list", arguments: .object([]), cwd: cwd, scope: scope)
        XCTAssertEqual(response["items"].elements?.count, 1)
        let own = try XCTUnwrap(response["items"].elements?.first)
        XCTAssertEqual(own["conversationId"].string, "own")
        let preview = try await BackendChatProviderCatalogue.claude(operation: "catalogue/read", arguments: own, cwd: cwd, scope: scope)
        XCTAssertEqual(preview["items"].elements?.first?["text"].string, "message own")
        let forged = own.setting("path", .string(directory.appendingPathComponent("foreign.jsonl").path)).setting("conversationId", .string("foreign"))
        do { _ = try await BackendChatProviderCatalogue.claude(operation: "catalogue/read", arguments: forged, cwd: cwd, scope: scope); XCTFail("Colliding foreign project admitted") } catch {}
        do { _ = try await BackendChatProviderCatalogue.claude(operation: "catalogue/list", arguments: .object([]), cwd: collision, scope: scope); XCTFail("Authority scope widened") } catch {}
    }

    func testClaudeAccountScopeUsesOnlyTheActualResolvedLaunchEnvironment() throws {
        let privateScope = try BackendChatProviderCatalogue.claudeScope(environment: ["CLAUDE_CONFIG_DIR": "/private/account", "HOME": "/system/home"], cwd: "/scratch/project")
        XCTAssertEqual(try NativeTranscriptPaths.configDirectories(privateScope), ["/private/account"])
        XCTAssertEqual(privateScope.projectFolders, ["/scratch/project"])
        let systemScope = try BackendChatProviderCatalogue.claudeScope(environment: ["HOME": "/resolved/account-home"], cwd: "/scratch/project")
        XCTAssertEqual(systemScope.configDirectory, "/resolved/account-home/.claude")
        for env in [[String: String](), ["CLAUDE_CONFIG_DIR": "relative-private", "HOME": "/system/home"], ["CLAUDE_CONFIG_DIR": "", "HOME": "/system/home"]] {
            XCTAssertThrowsError(try BackendChatProviderCatalogue.claudeScope(environment: env, cwd: "/scratch/project"))
        }
    }
}
