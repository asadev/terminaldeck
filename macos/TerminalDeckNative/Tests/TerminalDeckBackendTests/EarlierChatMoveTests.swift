import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class EarlierChatMoveTests: XCTestCase, @unchecked Sendable {
    private func event(_ sequence: Int, _ kind: HootChatKind) -> HootChatEvent {
        .init(conversationID: "original", turnID: "turn", sequence: sequence, provider: .codex,
              record: .text(kind, id: "message-\(sequence)", "same words"))
    }
    func testTransferRefusesBusyPendingQueuedAndChangedConversation() throws {
        let idle = NativeRPCValue.object([.init("sequence", .number(4)), .init("conversationId", .string("chat")), .init("providerConversationId", .string("ai"))])
        XCTAssertNoThrow(try BackendEarlierChatMove.requireIdle(idle))
        for changed in [idle.setting("busy", .bool(true)), idle.setting("foreground", .bool(true)),
                        idle.setting("pending", .array([.object([])])), idle.setting("queuedMessages", .array([.object([])])), idle.setting("queuedCount", .number(1))] {
            XCTAssertThrowsError(try BackendEarlierChatMove.requireIdle(changed))
        }
        XCTAssertThrowsError(try BackendEarlierChatMove.requireUnchanged(idle, idle.setting("sequence", .number(5))))
        XCTAssertThrowsError(try BackendEarlierChatMove.requireUnchanged(idle, idle.setting("providerConversationId", .string("other"))))
    }
    func testEarlierButtonsWaitForIdleWithoutAddingNotice() throws {
        let row = event(1, .user).wireValue
        let idle = NativeRPCValue.object([.init("provider", .string("codex")), .init("providerConversationId", .string("ai")), .init("events", .array([row]))])
        XCTAssertEqual(BackendEarlierChatMove.offeringActions(idle)["messageActions"].elements?.count, 1)
        let busy = BackendEarlierChatMove.offeringActions(idle.setting("busy", .bool(true)))
        XCTAssertEqual(busy["messageActions"].elements?.first?["rewind"].bool, false)
        XCTAssertEqual(busy["messageActions"].elements?.first?["fork"].bool, true)
        XCTAssertNil(busy["notice"].string)
        let runningJob = idle.setting("job", .object([.init("job", .object([]))]))
        XCTAssertEqual(BackendEarlierChatMove.offeringActions(runningJob)["messageActions"].elements?.first?["rewind"].bool, false)
        XCTAssertEqual(BackendEarlierChatMove.offeringActions(runningJob)["messageActions"].elements?.first?["fork"].bool, true)
        let finished = runningJob.setting("job", .object([.init("finishedAt", .number(1))]))
        XCTAssertEqual(BackendEarlierChatMove.offeringActions(finished)["messageActions"].elements?.count, 1)
        XCTAssertEqual(BackendEarlierChatMove.offeringActions(idle.setting("queuedCount", .number(1)))["messageActions"].elements?.first?["rewind"].bool, false)
        XCTAssertEqual(BackendEarlierChatMove.offeringActions(idle)["messageActions"].elements?.count, 1)
    }
    func testCodexBoundariesUseSavedItemIDsAndRejectOtherConversation() throws {
        let message = event(1, .message)
        let item = NativeRPCValue.object([.init("id", .string("message-1"))])
        let turn = NativeRPCValue.object([.init("id", .string("provider-turn")), .init("items", .array([item]))])
        let thread = NativeRPCValue.object([.init("id", .string("ai")), .init("cwd", .string("/scratch")), .init("turns", .array([turn]))])
        XCTAssertEqual(try BackendEarlierChatMove.codexTurns([message], thread: thread, conversation: "ai", cwd: "/scratch"), ["turn": "provider-turn"])
        XCTAssertEqual(try BackendEarlierChatMove.codexTurns([event(2, .message)], thread: thread, conversation: "ai", cwd: "/scratch"), [:])
        XCTAssertThrowsError(try BackendEarlierChatMove.codexTurns([message], thread: thread, conversation: "other", cwd: "/scratch"))
    }
    func testHootForkKeepsChosenMessageAndLeavesSourceBytesUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r3-hoot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try BackendHootChatStore(file: root.appendingPathComponent("source.json"), provider: .codex, retainAllHistory: true)
        try await source.seedForkHistory([event(1, .user), event(2, .message), event(3, .user), event(4, .message)])
        let original = try Data(contentsOf: await source.historyFileURL)
        let prefix = try await source.hootForkPrefix(through: 2)
        let target = try BackendHootChatStore(file: root.appendingPathComponent("fork.json"), provider: .codex, retainAllHistory: true)
        try await target.seedHootForkHistory(prefix)
        let snapshot = await target.snapshot()
        XCTAssertEqual(snapshot["events"].elements?.count, 2)
        let sourceFile = await source.historyFileURL
        XCTAssertEqual(try Data(contentsOf: sourceFile), original)
        XCTAssertNotEqual(snapshot["conversationId"].string, "original")
        XCTAssertNil(snapshot["providerConversationId"].string)
        do { _ = try await source.hootForkPrefix(through: 99); XCTFail("Unknown message") } catch {}
    }

    func testMovedSourceForkChoosesSameOwnerAndKeepsSeedOwnershipGuards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r3-fork-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("provider.py")
        try #"""
        import json, sys
        args = sys.argv[1:]
        conversation = next((args[i+1] for i, arg in enumerate(args[:-1]) if arg in ['--resume', '--session-id']), 'offline-owner')
        for line in sys.stdin:
            request = json.loads(line)
            if request.get('type') == 'control_request':
                print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':request['request_id'],'response':{}}}), flush=True)
                print(json.dumps({'type':'system','subtype':'init','session_id':conversation}), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let wrapper = root.appendingPathComponent("claude")
        try "#!/bin/sh\nexec /usr/bin/python3 -u \"$(dirname \"$0\")/provider.py\" \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let directory = root.appendingPathComponent("chats"), moved = directory.appendingPathComponent("source/new-engine")
        let sourceStore = try BackendHootChatStore(file: moved.appendingPathComponent("chat.json"), provider: .claude, retainAllHistory: true)
        let conversation = "11111111-1111-4111-8111-111111111111", answer = "22222222-2222-4222-8222-222222222222"
        let history: [HootChatEvent] = [
            .init(conversationID: "moved", turnID: "turn", sequence: 1, provider: .claude, record: .text(.user, id: "turn", "keep this")),
            .init(conversationID: "moved", turnID: "turn", sequence: 2, provider: .claude,
                record: .init(.message, id: answer, value: .object([.init("text", .string("kept answer")), .init("providerMessageId", .string(answer))]))),
            .init(conversationID: "moved", turnID: "turn", sequence: 3, provider: .claude, record: .init(.completed))]
        try await sourceStore.seedEarlierEngineHistory(history, conversation: conversation, chatID: "moved")
        try Data("1".utf8).write(to: moved.appendingPathComponent("active"))
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let chats = BackendSessionChats(manager: manager, directory: directory, publish: { _, _ in })
        let account = BackendAccountIdentity(id: "same-login", name: "Fixture")
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        let sourceSpawn = BackendSpawnSpec(provider: "claude", command: wrapper.path, args: ["--resume", conversation], path: "/usr/bin:/bin",
            profile: account, agentSessionId: conversation, resumed: true, tabKey: "source")
        do {
            let source = try await chats.launch(input, spawn: sourceSpawn)
            let ordinary = await chats.prefersLocalEngine(tabKey: "child")
            XCTAssertFalse(ordinary, "Without its source scope, a new child would follow the hosted New Chat route")
            let unowned = await BackendChatForkLaunchScope.$sourceID.withValue("not-owned") { await chats.prefersLocalEngine(tabKey: "child") }
            XCTAssertFalse(unowned)
            let child = try await BackendChatForkLaunchScope.$sourceID.withValue(source.id) {
                let sameOwner = await chats.prefersLocalEngine(tabKey: "child")
                XCTAssertTrue(sameOwner, "An app-owned moved source keeps its fork in the same owner")
                let childSpawn = BackendSpawnSpec(provider: "claude", command: wrapper.path, args: ["--session-id", answer], path: "/usr/bin:/bin",
                    profile: account, agentSessionId: answer, tabKey: "child")
                return try await chats.launch(input, spawn: childSpawn)
            }
            try await chats.seedFork(child.id, from: source.id, through: 2)
            let copied = try await chats.read(child.id, cursor: 0, limit: 500)
            XCTAssertEqual((copied["events"].elements ?? []).filter { ["user", "message"].contains($0["kind"].string ?? "") }.count, 2)
            do { try await chats.seedFork(child.id, from: "not-owned", through: 2); XCTFail("Unowned sources must still be refused") }
            catch { XCTAssertTrue(error.localizedDescription.contains("same session owner") || error.localizedDescription.contains("this session owner")) }
            await chats.endAllForQuit(); manager.killAll()
        } catch { await chats.endAllForQuit(); manager.killAll(); throw error }
    }

    /// The one opt-in real-AI safety trial. Its older-owner wire omits messageActions, as the earlier engine did.
    func testDevEarlierEngineRewindForkSafetyTrial() async throws {
        let settings = ProcessInfo.processInfo.environment
        guard let location = settings["TD_R3_TRIAL_ROOT"], let binary = settings["TD_R3_CODEX_BIN"] else { throw XCTSkip("One opt-in Dev-0213 safety trial") }
        let root = URL(fileURLWithPath: location), work = root.appendingPathComponent("work"), codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json"), to: codex.appendingPathComponent("auth.json"))
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let journal = root.appendingPathComponent("session-chats")
        let service = BackendHOSTChats(manager: manager, directory: journal)
        let paths = try BackendHOSTPaths(dataDirectory: root)
        _ = try paths.secret(create: true)
        let server = try BackendHOSTServer(paths: paths, hostVersion: "r3-scratch-earlier-owner", manager: manager,
            launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { manager.chatHostSnapshot($0) }, onIdle: {}, resource: { method, payload in
                let bytes = try await service.invoke(method, payload: payload)
                guard method == "chats.read" else { return bytes }
                return try NativeRPCValue.parseJSON(bytes).setting("messageActions", .null).encodedJSON()
            }, chatUpdates: { try await service.subscribe() })
        let client = try BackendHOSTClient(paths: paths)
        let app = BackendSessionChats(manager: manager, directory: journal, publish: { _, _ in })
        let cleanup: @Sendable () async -> Void = {
            await app.endAllForQuit()
            _ = try? await service.invoke("chats.stopAll", payload: Data("{}".utf8))
            server.stopListening(); client.detach(); manager.killAll()
            try? FileManager.default.removeItem(at: root)
        }
        do {
            var environment = settings.filter { key, _ in !["ANTHROPIC", "OPENAI", "CLAUDE", "CODEX"].contains(where: key.contains) }
            environment["CODEX_HOME"] = codex.path
            let account = BackendAccountIdentity(id: "r3-scratch-login", name: "Scratch")
            var input = BackendCreateSessionInput(cwd: work.path, provider: "codex"); input.chat = true
            let spawn = BackendSpawnSpec(provider: "codex", command: binary,
                args: ["--model", "gpt-6.1-sol", "--sandbox", "read-only", "--ask-for-approval", "never"], path: environment["PATH"] ?? "/usr/bin:/bin", env: environment, profile: account, tabKey: "r3-source")
            let launch = try BackendHOSTProtocol.Launch(id: UUID().uuidString.lowercased(), input: input, spawn: spawn, inheritedEnvironment: [:])
            let meta = try client.create(launch)
            for text in ["Reply exactly R3_KEEP", "Reply exactly R3_DROP"] {
                let request = NativeRPCValue.object([.init("id", .string(meta.id)), .init("text", .string(text)), .init("clientMessageId", .string(UUID().uuidString))])
                _ = try await service.invoke("chats.say", payload: request.encodedJSON())
                let deadline = ContinuousClock.now + .seconds(120)
                while ContinuousClock.now < deadline {
                    let snapshot = try NativeRPCValue.parseJSON(await service.invoke("chats.read", payload: request.encodedJSON()))
                    if snapshot["busy"].bool != true { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            try await app.useHost(client)
            let sourceInput = input
            await app.setEarlierEngineMove { id in
                let snapshot = try NativeRPCValue.parseJSON(await service.invoke("chats.read", payload: NativeRPCValue.object([.init("id", .string(id))]).encodedJSON()))
                let conversation = try snapshot["providerConversationId"].requireString("scratch AI conversation", nonempty: true)
                let resumed = BackendSpawnSpec(provider: spawn.provider, command: spawn.command, args: spawn.args, path: spawn.path, env: spawn.env, profile: account, agentSessionId: conversation, resumed: true, tabKey: spawn.tabKey)
                var resume = sourceInput; resume.resume = true; resume.resumeConversationId = conversation; resume.replaces = id
                _ = try await app.moveEarlierChat(id, input: resume, spawn: resumed)
                let moved = try await app.read(id, cursor: 0, limit: 500)
                let count = (moved["events"].elements ?? []).filter { ["user", "message"].contains($0["kind"].string ?? "") }.count
                try Data(String(count).utf8).write(to: root.deletingLastPathComponent().appendingPathComponent("r3-move-count.txt"))
            }
            let before = try await app.read(meta.id, cursor: 0, limit: 500)
            let messages = try XCTUnwrap(before["events"].elements).filter { ["user", "message"].contains($0["kind"].string ?? "") }
            XCTAssertEqual(messages.count, 4)
            let originalFile = journal.appendingPathComponent("r3-source/chat-codex.json")
            let originalBytes = try Data(contentsOf: originalFile)
            let secondUser = try XCTUnwrap(messages.last { $0["kind"].string == "user" }?["sequence"].number)
            // Force the real move to refuse an occupied staging folder, before releasing its earlier owner.
            let staging = originalFile.deletingLastPathComponent().appendingPathComponent("new-engine")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            do { _ = try await app.rewind(meta.id, sequence: Int(secondUser)); XCTFail("Occupied move destination must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("previous conversation move")) }
            let failed = try await app.read(meta.id, cursor: 0, limit: 500)
            let failureMessages = (failed["events"].elements ?? []).filter { ["user", "message"].contains($0["kind"].string ?? "") }
            XCTAssertEqual(failureMessages, messages)
            XCTAssertEqual(try Data(contentsOf: originalFile), originalBytes)
            try FileManager.default.removeItem(at: staging)
            _ = try await app.rewind(meta.id, sequence: Int(secondUser))
            let movedCount = Int(try String(contentsOf: root.deletingLastPathComponent().appendingPathComponent("r3-move-count.txt"), encoding: .utf8))
            XCTAssertEqual(movedCount, 4)
            let rewound = try await app.read(meta.id, cursor: 0, limit: 500)
            let kept = try XCTUnwrap(rewound["events"].elements).filter { ["user", "message"].contains($0["kind"].string ?? "") }
            XCTAssertEqual(kept.count, 2)
            XCTAssertEqual(try Data(contentsOf: originalFile), originalBytes)
            let answer = try XCTUnwrap(kept.last { $0["kind"].string == "message" }?["sequence"].number)
            let fork = try await app.providerFeature(meta.id, operation: "fork/create", arguments: .object([.init("throughSequence", .number(answer))]))
            let forkID = try fork["conversationId"].requireString("forked AI conversation", nonempty: true)
            var childInput = input; childInput.resume = true; childInput.resumeConversationId = forkID
            let childSpawn = BackendSpawnSpec(provider: spawn.provider, command: spawn.command, args: spawn.args, path: spawn.path, env: spawn.env, profile: account, agentSessionId: forkID, resumed: true, tabKey: "r3-fork")
            // The production launcher sends fresh Chats to the earlier owner. Exercise that same ownership split.
            let childLaunch = try BackendHOSTProtocol.Launch(id: UUID().uuidString.lowercased(), input: childInput, spawn: childSpawn, inheritedEnvironment: [:])
            let child = try client.create(childLaunch)
            try await app.adoptHostedSession(child)
            try await app.seedFork(child.id, from: meta.id, through: Int(answer))
            let copied = try await app.read(child.id, cursor: 0, limit: 500)
            let forkMessages = (copied["events"].elements ?? []).filter { ["user", "message"].contains($0["kind"].string ?? "") }
            XCTAssertEqual(forkMessages.count, 2)
            XCTAssertEqual(forkMessages.map { $0["value"]["text"].string }, kept.map { $0["value"]["text"].string })
            XCTAssertNotEqual(forkID, rewound["providerConversationId"].string)
            let evidence = NativeRPCValue.object([.init("beforeMessages", .number(Double(messages.count))), .init("afterMoveMessages", .number(Double(movedCount ?? -1))), .init("failureBeforeMessages", .number(Double(messages.count))), .init("failureAfterMessages", .number(Double(failureMessages.count))), .init("failureJournalUnchanged", .bool(true)), .init("afterRewindMessages", .number(Double(kept.count))), .init("forkMessages", .number(Double(forkMessages.count))), .init("originalJournalUnchanged", .bool(true)), .init("realProvider", .string("codex"))])
            try evidence.encodedJSON().write(to: root.deletingLastPathComponent().appendingPathComponent("r3-trial-counts.json"), options: .atomic)
            await cleanup()
        } catch { await cleanup(); throw error }
    }
}
