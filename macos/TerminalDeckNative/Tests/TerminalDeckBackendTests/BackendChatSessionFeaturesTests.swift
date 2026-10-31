import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// F29 file checkpoints, F35 background tasks, F38 fork, F57 location. Provider answers are stubbed; nothing is launched.
final class BackendChatSessionFeaturesTests: XCTestCase, @unchecked Sendable {
    private actor Provider {
        var calls: [(String, NativeRPCValue)] = []
        let replies: [String: [NativeRPCValue]]
        init(_ replies: [String: [NativeRPCValue]] = [:]) { self.replies = replies }
        /// Replies to a method in order; the last one repeats.
        func request(_ method: String, _ params: NativeRPCValue) throws -> NativeRPCValue {
            let seen = calls.filter { $0.0 == method }.count
            calls.append((method, params))
            guard let list = replies[method], let last = list.last else { throw NativeRPCError.malformed("Unexpected provider call: " + method) }
            return seen < list.count ? list[seen] : last
        }
        func methods() -> [String] { calls.map(\.0) }
    }
    private func json(_ value: String) throws -> NativeRPCValue { try .parseJSON(Data(value.utf8)) }

    // MARK: Background tasks (F35)

    private func tasks() throws -> [NativeRPCValue] {
        [try json(#"{"id":"bash-1","title":"npm run watch","kind":"local_bash","status":"running","toolUseId":"tool-1","appTaskId":"task-9"}"#),
         try json(#"{"id":"bash-2","title":"build","kind":"local_bash","status":"completed","toolUseId":"tool-2"}"#)]
    }
    private func background(_ op: String, _ args: String = "{}", provider: HootChatProvider = .claude, stub: Provider) async throws -> NativeRPCValue {
        try await BackendChatBackground.invoke(operation: op, args: try json(args), provider: provider, ownedTasks: try tasks(), request: { m, p in try await stub.request(m, p) })
    }
    func testBackgroundListShowsRecordedTasksWithTaskLinkAndNoProviderCall() async throws {
        let stub = Provider()
        let list = try await background("background/list", stub: stub)
        XCTAssertEqual(list["items"].elements?.count, 2)
        XCTAssertEqual(list["items"].elements?.first?["running"].bool, true)
        XCTAssertEqual(list["items"].elements?.first?["appTaskId"].string, "task-9")
        XCTAssertEqual(list["lifecycleAvailable"].bool, true)
        let calls = await stub.methods()
        XCTAssertTrue(calls.isEmpty)
    }
    func testBackgroundOutputReadsOnlyTheTailOfATaskThisChatEmitted() async throws {
        let big = String(repeating: "x", count: 20_000)
        let stub = Provider(["get_task_output": [try json(#"{"output":"\#(big)"}"#)]])
        let out = try await background("background/output", #"{"taskId":"bash-1"}"#, stub: stub)
        XCTAssertEqual(out["output"].string?.utf8.count, BackendChatBackground.maximumOutput)
        XCTAssertEqual(out["clipped"].bool, true)
        let calls = await stub.calls
        XCTAssertEqual(calls.first?.1["task_id"].string, "bash-1")
        do { _ = try await background("background/output", #"{"taskId":"foreign"}"#, stub: stub); XCTFail("A task this chat never emitted") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
        do { _ = try await background("background/output", #"{"taskId":"bash-1","path":"/etc/passwd"}"#, stub: stub); XCTFail("Extra argument") } catch {}
    }
    func testBackgroundStopNeedsRunningTaskAndDetachNeedsAnExplicitScope() async throws {
        let stub = Provider(["stop_task": [try json("{}")], "background_tasks": [try json("{}")]])
        _ = try await background("background/stop", #"{"taskId":"bash-1"}"#, stub: stub)
        do { _ = try await background("background/stop", #"{"taskId":"bash-2"}"#, stub: stub); XCTFail("Already finished") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "not-running") }
        do { _ = try await background("background/detach", "{}", stub: stub); XCTFail("Omission must not mean every task") } catch {}
        _ = try await background("background/detach", #"{"toolUseId":"tool-1"}"#, stub: stub)
        _ = try await background("background/detach", #"{"all":true}"#, stub: stub)
        do { _ = try await background("background/detach", #"{"toolUseId":"tool-2"}"#, stub: stub); XCTFail("Finished tool call") } catch {}
        let calls = await stub.methods()
        XCTAssertEqual(calls, ["stop_task", "background_tasks", "background_tasks"])
    }
    func testCodexBackgroundOffersTheRecordedListOnlyAndSaysWhy() async throws {
        let stub = Provider()
        let list = try await background("background/list", provider: .codex, stub: stub)
        XCTAssertEqual(list["outputAvailable"].bool, false)
        XCTAssertNotNil(list["note"].string)
        do { _ = try await background("background/output", #"{"taskId":"bash-1"}"#, provider: .codex, stub: stub); XCTFail("No Codex protocol") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "unavailable") }
        let calls = await stub.methods()
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: File checkpoints (F29)

    private let rows: [NativeRPCValue] = [
        .object([.init("turnId", .string("11111111-1111-4111-8111-111111111111")), .init("messageUuid", .string("11111111-1111-4111-8111-111111111111")), .init("text", .string("first"))]),
    ]
    private let turn = "11111111-1111-4111-8111-111111111111"
    private func checkpoint(_ op: String, _ args: String, provider: HootChatProvider = .claude, quiet: Bool = true, stub: Provider) async throws -> NativeRPCValue {
        try await BackendChatFileCheckpoints.invoke(operation: op, args: try json(args), provider: provider, checkpoints: rows, quiet: quiet, request: { m, p in try await stub.request(m, p) })
    }
    func testCheckpointPreviewIsADryRunAndDoesNotRewindConversation() async throws {
        let stub = Provider(["rewind_files": [try json(#"{"canRewind":true,"filesChanged":["/p/a.swift","/p/b.swift"],"insertions":4,"deletions":9}"#)]])
        let preview = try await checkpoint("checkpoints/preview", #"{"turnId":"\#(turn)"}"#, stub: stub)
        XCTAssertEqual(preview["canRewind"].bool, true)
        XCTAssertEqual(preview["fileCount"].number, 2)
        XCTAssertEqual(preview["conversationRewound"].bool, false)
        XCTAssertNotNil(preview["digest"].string)
        let calls = await stub.calls
        XCTAssertEqual(calls.first?.1["dry_run"].bool, true)
        XCTAssertEqual(calls.first?.1["user_message_id"].string, turn)
    }
    func testCheckpointRestoreNeedsTheApprovedPreviewAndAQuietChat() async throws {
        let dry = try json(#"{"canRewind":true,"filesChanged":["/p/a.swift"],"insertions":1,"deletions":2}"#)
        let stub = Provider(["rewind_files": [dry]])
        let digest = try await checkpoint("checkpoints/preview", #"{"turnId":"\#(turn)"}"#, stub: stub)["digest"].string ?? ""
        do { _ = try await checkpoint("checkpoints/restore", #"{"turnId":"\#(turn)","approvedDigest":"stale"}"#, stub: stub); XCTFail("A changed preview needs new approval") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "preview-changed") }
        do { _ = try await checkpoint("checkpoints/restore", #"{"turnId":"\#(turn)","approvedDigest":"\#(digest)"}"#, quiet: false, stub: stub); XCTFail("Busy chat") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "busy") }
        let before = await stub.calls.filter { $0.1["dry_run"].bool == false }.count
        XCTAssertEqual(before, 0, "Nothing was restored by the refused attempts")
    }
    /// Review chat-backend #5: quiet is re-checked right before the real restore, after the preview round trip.
    func testCheckpointRestoreIsRefusedIfTheChatBecameBusyDuringThePreview() async throws {
        let stub = Provider(["rewind_files": [try json(#"{"canRewind":true,"filesChanged":["/p/a.swift"],"insertions":1,"deletions":2}"#)]])
        let digest = try await checkpoint("checkpoints/preview", #"{"turnId":"\#(turn)"}"#, stub: stub)["digest"].string ?? ""
        do {
            _ = try await BackendChatFileCheckpoints.invoke(operation: "checkpoints/restore", args: try json(#"{"turnId":"\#(turn)","approvedDigest":"\#(digest)"}"#),
                provider: .claude, checkpoints: rows, quiet: true, quietNow: { false }, request: { m, p in try await stub.request(m, p) })
            XCTFail("A turn started during the preview")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "busy") }
        let real = await stub.calls.filter { $0.1["dry_run"].bool == false }
        XCTAssertEqual(real.count, 0, "Nothing was restored while the AI was working")
    }
    func testCheckpointRestoreRunsTheRealRewindOnlyAfterAMatchingPreview() async throws {
        let stub = Provider(["rewind_files": [try json(#"{"canRewind":true,"filesChanged":["/p/a.swift"],"insertions":1,"deletions":2}"#)]])
        let digest = try await checkpoint("checkpoints/preview", #"{"turnId":"\#(turn)"}"#, stub: stub)["digest"].string ?? ""
        let done = try await checkpoint("checkpoints/restore", #"{"turnId":"\#(turn)","approvedDigest":"\#(digest)"}"#, stub: stub)
        XCTAssertEqual(done["restored"].bool, true)
        XCTAssertEqual(done["conversationRewound"].bool, false)
        let real = await stub.calls.filter { $0.1["dry_run"].bool == false }
        XCTAssertEqual(real.count, 1)
        XCTAssertEqual(real.first?.1["user_message_id"].string, turn)
    }
    func testCheckpointRefusesUnknownTurnsPathsAndCodex() async throws {
        let stub = Provider()
        do { _ = try await checkpoint("checkpoints/preview", #"{"turnId":"22222222-2222-4222-8222-222222222222"}"#, stub: stub); XCTFail("Unrecorded message") } catch {}
        do { _ = try await checkpoint("checkpoints/preview", #"{"turnId":"\#(turn)","messageId":"x"}"#, stub: stub); XCTFail("Provider IDs are not accepted") } catch {}
        let codex = try await checkpoint("checkpoints/list", "{}", provider: .codex, stub: stub)
        XCTAssertEqual(codex["available"].bool, false)
        do { _ = try await checkpoint("checkpoints/restore", #"{"turnId":"\#(turn)"}"#, provider: .codex, stub: stub); XCTFail("No Codex file restore") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "unavailable") }
        let calls = await stub.methods()
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: Fork (F38) and location (F57)

    private func fork(_ args: String = "{}", provider: HootChatProvider = .codex, conversation: String? = "parent", quiet: Bool = true,
                      turns: [String: String] = ["turn-a": "codex-turn-a", "turn-open": ""], isolated: Provider? = nil, stub: Provider) async throws -> NativeRPCValue {
        let forker = isolated ?? stub
        return try await BackendChatFork.invoke(operation: "fork/create", args: try json(args), provider: provider, conversation: conversation, cwd: "/p",
            knownTurns: turns, quiet: quiet, request: { m, p in try await stub.request(m, p) },
            isolatedFork: { p in try await forker.request("thread/fork", p) })
    }
    func testCodexForkCreatesANewProviderConversationAndReleasesIt() async throws {
        let stub = Provider(["thread/fork": [try json(#"{"thread":{"id":"child","forkedFromId":"parent"},"cwd":"/p"}"#)]])
        let result = try await fork(#"{"throughTurn":"turn-a"}"#, stub: stub)
        XCTAssertEqual(result["mode"].string, "forked")
        XCTAssertEqual(result["conversationId"].string, "child")
        XCTAssertEqual(result["parentConversationId"].string, "parent")
        let calls = await stub.calls
        XCTAssertEqual(calls.map(\.0), ["thread/fork"])
        XCTAssertEqual(calls[0].1["lastTurnId"].string, "codex-turn-a", "Codex must get the Codex turn ID, not the app's")
        XCTAssertEqual(calls[0].1["ephemeral"].bool, false)
        XCTAssertEqual(calls[0].1["threadId"].string, "parent")
    }
    // FIXFORK (16 Oct, live): the new Chat failed with "thread already has an active writer": the parent's own Codex
    // process made the fork and kept its writer lock. The fork is made in a separate short-lived process, never the parent's.
    func testCodexForkIsNeverMadeInTheParentChatsOwnProcess() async throws {
        let parent = Provider(), separate = Provider(["thread/fork": [try json(#"{"thread":{"id":"child","forkedFromId":"parent"},"cwd":"/p"}"#)]])
        let result = try await fork(isolated: separate, stub: parent)
        XCTAssertEqual(result["conversationId"].string, "child")
        let parentCalls = await parent.methods(), separateCalls = await separate.methods()
        XCTAssertEqual(parentCalls, [], "the parent's process must not load the fork")
        XCTAssertEqual(separateCalls, ["thread/fork"])
        do {
            _ = try await BackendChatFork.invoke(operation: "fork/create", args: try json("{}"), provider: .codex, conversation: "parent", cwd: "/p",
                knownTurns: [:], quiet: true, request: { m, p in try await parent.request(m, p) })
            XCTFail("Forked without a separate process")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "unavailable") }
        let after = await parent.methods()
        XCTAssertEqual(after, [])
    }
    func testTheForkProcessAnswersTheForkAndIsStoppedAfterwards() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fixfork-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("fake-app-server.py"), marker = folder.appendingPathComponent("exited")
        try """
        import json, signal, sys
        def done(*_):
            open(sys.argv[1], 'w').write('done'); sys.exit(0)
        signal.signal(signal.SIGTERM, done)
        for line in sys.stdin:
            m = json.loads(line)
            if 'id' not in m: continue
            r = {'thread': {'id': 'child', 'forkedFromId': m['params'].get('threadId')}} if m['method'] == 'thread/fork' else {}
            print(json.dumps({'jsonrpc': '2.0', 'id': m['id'], 'result': r}), flush=True)
        done()
        """.write(to: script, atomically: true, encoding: .utf8)
        let launch = BackendHootChatLaunch(command: "/usr/bin/python3", arguments: ["-I", script.path, marker.path], cwd: folder.path, environment: [:])
        let result = try await BackendChatForkProcess.fork(launch: launch, params: try json(#"{"threadId":"parent"}"#), timeout: .seconds(20))
        XCTAssertEqual(result["thread"]["id"].string, "child")
        XCTAssertEqual(result["thread"]["forkedFromId"].string, "parent")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the fork process must have ended before the fork is handed over")
    }
    func testForkNeverReportsAForkItCouldNotConfirm() async throws {
        for reply in [#"{"thread":{"id":"parent"}}"#, #"{"thread":{"id":"other","forkedFromId":"somebody-else"}}"#, #"{}"#] {
            let stub = Provider(["thread/fork": [try json(reply)]])
            do { _ = try await fork(stub: stub); XCTFail("Unconfirmed fork") }
            catch { XCTAssertEqual((error as? NativeRPCError)?.code, "fork-unconfirmed") }
        }
    }
    func testForkRefusesBusyChatsForeignTurnsAndExtraSettings() async throws {
        let stub = Provider()
        do { _ = try await fork(quiet: false, stub: stub); XCTFail("Busy") } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "busy") }
        do { _ = try await fork(#"{"throughTurn":"not-mine"}"#, stub: stub); XCTFail("Foreign turn") } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
        do { _ = try await fork(#"{"throughTurn":"turn-open"}"#, stub: stub); XCTFail("No provider turn ID recorded") } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "unavailable") }
        do { _ = try await fork(#"{"cwd":"/elsewhere"}"#, stub: stub); XCTFail("Folder is not selectable") } catch {}
        do { _ = try await fork(conversation: nil, stub: stub); XCTFail("No conversation yet") } catch {}
        let calls = await stub.methods()
        XCTAssertTrue(calls.isEmpty)
    }
    func testClaudeForkIsALaunchInstructionNotAProviderCall() async throws {
        let stub = Provider()
        let result = try await fork(provider: .claude, stub: stub)
        XCTAssertEqual(result["mode"].string, "launch-fork")
        XCTAssertEqual(result["requiresForkLaunch"].bool, true)
        XCTAssertEqual(result["conversationId"].string, "parent")
        do { _ = try await fork(#"{"throughTurn":"turn-a"}"#, provider: .claude, stub: stub); XCTFail("Claude forks whole") } catch {}
        do { _ = try await fork(provider: .gemini, stub: stub); XCTFail("Gemini has no fork") } catch {}
        let calls = await stub.methods()
        XCTAssertTrue(calls.isEmpty)
    }
    func testLocationNamesThisMacAndDoesNotInventARemoteRoute() async throws {
        let stub = Provider()
        let place = try await BackendChatFork.invoke(operation: "location/read", args: .object([]), provider: .codex, conversation: "c", cwd: "/p",
            knownTurns: [:], quiet: true, request: { m, p in try await stub.request(m, p) })
        XCTAssertEqual(place["executionLocation"].string, "this-mac")
        XCTAssertEqual(place["folder"].string, "/p")
        XCTAssertEqual(place["continuation"]["otherMachines"].bool, false)
        XCTAssertEqual(place["continuation"]["cloud"].bool, false)
        XCTAssertTrue((place["remoteRoutes"].elements ?? []).allSatisfy { $0["runsAiThere"].bool == false })
    }

    // MARK: Policy and launch plumbing

    func testNewOperationsAreOnTheFeatureDoorWithTheRightPermissions() throws {
        for operation in BackendChatProviderFeaturePolicy.sessionFeatureOperations {
            XCTAssertNoThrow(try BackendChatProviderFeaturePolicy.validate(operation, arguments: .object([])))
        }
        for read in ["checkpoints/list", "checkpoints/preview", "background/list", "background/output", "location/read"] {
            XCTAssertFalse(BackendChatProviderFeaturePolicy.changes(read), read)
        }
        for change in ["checkpoints/restore", "background/stop", "background/detach", "fork/create"] {
            XCTAssertTrue(BackendChatProviderFeaturePolicy.changes(change), change)
        }
        for caller in [BackendDeckCoreSecurityCaller.Kind.session, .remote, .key] {
            XCTAssertThrowsError(try BackendChatProviderFeaturePolicy.authorize("checkpoints/restore", caller: caller))
            XCTAssertThrowsError(try BackendChatProviderFeaturePolicy.authorize("fork/create", caller: caller))
            XCTAssertNoThrow(try BackendChatProviderFeaturePolicy.authorize("checkpoints/preview", caller: caller))
        }
        XCTAssertNoThrow(try BackendChatProviderFeaturePolicy.authorize("checkpoints/restore", caller: .local))
    }
    func testClaudeMessagesCarryTheirOwnIDAndTheCLIGetsCheckpointing() throws {
        let id = UUID().uuidString.lowercased()
        XCTAssertEqual(BackendHootChatCLI.user("hi", uuid: id)["uuid"].string, id)
        XCTAssertTrue(BackendHootChatCLI.user("hi", uuid: "task:" + id)["uuid"].isNullish, "A prefixed background turn ID is not a message ID")
        XCTAssertTrue(BackendHootChatCLI.user("hi")["uuid"].isNullish)
        XCTAssertEqual(BackendHootChatCLI.planningEnvironment([:])["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"], "1")
        XCTAssertNil(BackendHootChatCLI.planningEnvironment(["CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING": "1"])["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"])
        XCTAssertEqual(BackendHootChatCLI.planningEnvironment(["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "0"])["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"], "0")
    }
    func testClaudeForkLaunchResumesTheLiveParentWithoutClaimingItsIdentity() throws {
        let parent = "8b1a1a48-14a6-41de-a773-022597c6b96c"
        var input = BackendCreateSessionInput(cwd: "/w/app", provider: "claude"); input.resume = true; input.resumeConversationId = parent; input.forkSession = true
        let provider = BackendProviderSpec(id: "claude", command: "claude", args: [], resumeArgs: ["--continue"])
        let live = BackendSessionMeta(id: "p", input: BackendCreateSessionInput(cwd: "/w/app", provider: "claude"),
            spawn: .init(provider: "claude", command: "/fixture/claude", args: [], path: "/fixture", agentSessionId: parent), now: Date(timeIntervalSince1970: 1))
        let chosen = try BackendConversationLaunch.arguments(input, provider: provider, live: [live])
        XCTAssertEqual(chosen.arguments, ["--resume", parent, "--fork-session"])
        XCTAssertFalse(chosen.heldNamed)
        XCTAssertNil(chosen.conversationID, "The fork learns its own ID from the CLI")
        XCTAssertEqual(BackendSessionChats.withoutConversation(chosen.arguments), [], "A restart resumes the fork itself, never forks again")
    }
    func testInstructionSourcesAndForkFieldsRoundTripThroughTheLaunchInput() throws {
        var input = BackendCreateSessionInput(cwd: "/w", provider: "claude"); input.forkSession = true
        let again = try JSONDecoder().decode(BackendCreateSessionInput.self, from: JSONEncoder().encode(input))
        XCTAssertEqual(again.forkSession, true)
    }
}
