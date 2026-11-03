import Foundation
import Testing
import TerminalDeckNativeCore

@Suite("Foundation: chat-transcript.ts exact conversation rules")
struct BackendFoundationTestsTranscriptsChat {
    typealias F = BackendFoundationTestsSessionsFixtures
    private func texts(_ lines: [String]) async throws -> [String] {
        try await F.messages(lines).map { $0.role.rawValue + ": " + $0.text }
    }
    // TS chat-transcript.test.ts:107
    @Test func typedPromptAndReply() async throws {
        #expect(try await texts([F.prompt("Add a chat toggle"), F.reply("Done — the toggle sits in the header.")]) == ["you: Add a chat toggle", "agent: Done — the toggle sits in the header."])
    }
    // TS chat-transcript.test.ts:114
    @Test func arrayToolOutputNeverShown() async throws {
        let result = try await texts([F.prompt("list the files"), F.reply("Reading the directory now."), F.toolResult("toolu_01Qc23ik", "total 6296\ndrwxr-xr-x@ 32 apple staff 1024 Jun 10 23:22 ."), F.reply("Twelve files, nothing unexpected.")])
        #expect(result == ["you: list the files", "agent: Reading the directory now.\n\nTwelve files, nothing unexpected."])
        #expect(!result.joined(separator: "\n").contains("drwxr-xr-x"))
    }
    // TS chat-transcript.test.ts:130
    @Test func interruptionArrayDropped() async throws {
        let interruption = try F.line(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]], "uuid": "u-int-1", "timestamp": "2026-08-12T09:00:07.000Z"])
        #expect(try await texts([F.prompt("go"), interruption]) == ["you: go"])
    }
    // TS chat-transcript.test.ts:142
    @Test func pastedImageHumanPromptKept() async throws {
        let pasted = try F.line(["type": "user", "message": ["role": "user", "content": [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBORw0…"]], ["type": "text", "text": "this is how it looks on home"]]], "uuid": "u-img-1", "timestamp": "2026-08-12T09:01:00.000Z", "origin": ["kind": "human"]])
        #expect(try await texts([pasted]) == ["you: this is how it looks on home"])
    }
    // TS chat-transcript.test.ts:159
    @Test func privateThinkingAndToolsDropped() async throws {
        let thinking = try F.reply("", overrides: ["uuid": "u-think"], messageOverrides: ["content": [["type": "thinking", "thinking": "The user wants a toggle…", "signature": "Es4B"]]])
        let tool = try F.reply("", overrides: ["uuid": "u-tool"], messageOverrides: ["content": [["type": "tool_use", "id": "toolu_1", "name": "Read", "input": ["file_path": "/x"]]]])
        #expect(try await texts([F.prompt("go"), thinking, tool, F.reply("Read it.", overrides: ["uuid": "u-say"])]) == ["you: go", "agent: Read it."])
    }
    // TS chat-transcript.test.ts:172
    @Test func metaSidechainSummaryAndErrorsDropped() async throws {
        let lines = try [F.prompt("Approach this as the design lead at a small studio…", overrides: ["uuid": "u-meta", "isMeta": true, "origin": NSNull()]), F.reply("Sub-agent reporting in.", overrides: ["uuid": "u-side", "isSidechain": true]), F.prompt("This session is being continued from a previous conversation…", overrides: ["uuid": "u-summary", "isCompactSummary": true]), F.reply("API Error: Connection closed mid-response.", overrides: ["uuid": "u-err", "isApiErrorMessage": true], messageOverrides: ["model": "<synthetic>"]), F.prompt("carry on"), F.reply("Carrying on.")]
        #expect(try await texts(lines) == ["you: carry on", "agent: Carrying on."])
    }
    // TS chat-transcript.test.ts:193
    @Test func syntheticReplyDroppedWithoutErrorFlag() async throws {
        let synthetic = try F.reply("No response requested.", overrides: ["uuid": "u-syn", "isApiErrorMessage": false], messageOverrides: ["model": "<synthetic>", "stop_reason": "stop_sequence"])
        #expect(try await texts([F.prompt("ping"), synthetic, F.reply("Real answer.", overrides: ["uuid": "u-real"], messageOverrides: ["id": "msg_R"])]) == ["you: ping", "agent: Real answer."])
    }
    // TS chat-transcript.test.ts:209
    @Test func arrayCommandTagDropped() async throws {
        let command = try F.line(["type": "user", "uuid": "u-arr-cmd", "timestamp": "2026-08-12T09:02:03.000Z", "origin": ["kind": "human"], "message": ["role": "user", "content": [["type": "text", "text": "<command-name>/compact</command-name>\n<command-args></command-args>"]]]])
        #expect(try await texts([command, F.prompt("and now the real one")]) == ["you: and now the real one"])
    }
    // TS chat-transcript.test.ts:226
    @Test func slashCommandPlumbingDropped() async throws {
        let slash = try F.line(["type": "user", "uuid": "u-cmd", "message": ["role": "user", "content": "<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>claude-fable-5</command-args>"]])
        let stdout = try F.line(["type": "user", "uuid": "u-out", "message": ["role": "user", "content": "<local-command-stdout>Set model to claude-fable-5</local-command-stdout>"]])
        let notification = try F.line(["type": "user", "uuid": "u-note", "origin": ["kind": "task-notification"], "message": ["role": "user", "content": "<task-notification>\n<task-id>wdtmjatgv</task-id>\n</task-notification>"]])
        #expect(try await texts([slash, stdout, notification, F.prompt("ok now build it")]) == ["you: ok now build it"])
    }
    // TS chat-transcript.test.ts:253
    @Test func stapledSystemReminderRemoved() async throws {
        #expect(try await texts([F.prompt("ship it\n<system-reminder>Remember to run the tests.</system-reminder>")]) == ["you: ship it"])
    }
    // TS chat-transcript.test.ts:258
    @Test func tagMentionInsidePromptKept() async throws {
        #expect(try await texts([F.prompt("what does <command-name> mean in the transcript?")]) == ["you: what does <command-name> mean in the transcript?"])
    }
    // TS chat-transcript.test.ts:269
    @Test func threeReplyBlocksCollapse() async throws {
        let replies = try zip(["First.", "Second.", "Third."], ["u-1", "u-2", "u-3"]).map { try F.reply($0.0, overrides: ["uuid": $0.1, "timestamp": "2026-08-12T09:03:00.000Z"], messageOverrides: ["id": "msg_split", "usage": ["input_tokens": 4, "output_tokens": 300, "cache_read_input_tokens": 51000]]) }
        let result = try await F.messages([F.prompt("explain the reader")] + replies)
        #expect(result.count == 2); #expect(result[1].role == .agent); #expect(result[1].text == "First.\n\nSecond.\n\nThird.")
    }
    // TS chat-transcript.test.ts:287
    @Test func replayedReplyDeduplicates() async throws {
        let once = try F.reply("Only once.", overrides: ["uuid": "u-dup"], messageOverrides: ["id": "msg_dup"])
        #expect(try await F.messages([F.prompt("hi"), once, once, once]).map(\.text) == ["hi", "Only once."])
    }
    // TS chat-transcript.test.ts:300
    @Test func identicalPromptsRemainTwoTurns() async throws {
        #expect(try await texts([F.prompt("continue", overrides: ["uuid": "u-a"]), F.reply("ok", overrides: ["uuid": "r-a"], messageOverrides: ["id": "m-a"]), F.prompt("continue", overrides: ["uuid": "u-b"])]) == ["you: continue", "agent: ok", "you: continue"])
    }
    // TS chat-transcript.test.ts:306
    @Test func userStartsNewAgentMessage() async throws {
        #expect(try await texts([F.prompt("one", overrides: ["uuid": "u-1"]), F.reply("first answer", overrides: ["uuid": "r-1"], messageOverrides: ["id": "m-1"]), F.prompt("two", overrides: ["uuid": "u-2"]), F.reply("second answer", overrides: ["uuid": "r-2"], messageOverrides: ["id": "m-2"])]) == ["you: one", "agent: first answer", "you: two", "agent: second answer"])
    }
    // TS chat-transcript.test.ts:334
    @Test func incrementalReadOnlyChanges() async throws {
        let scratch = try BackendFoundationTestsSessionsScratch(), file = try scratch.write(F.conversation + ".jsonl", [F.prompt("start"), F.reply("Working on it.")].joined(separator: "\n") + "\n")
        let reader = NativeChatTranscriptReader(path: file.path)
        #expect(try await reader.readAll().messages.map(\.text) == ["start", "Working on it."])
        #expect(try await reader.readAll().messages.isEmpty)
        try scratch.append(file, F.reply("Finished.", overrides: ["uuid": "r-2"], messageOverrides: ["id": "msg_B"]) + "\n")
        let second = try await reader.readAll(), conversation = await reader.conversation
        #expect(second.messages.count == 1); #expect(second.messages[0].id == conversation[1].id)
        #expect(second.messages[0].text == "Working on it.\n\nFinished."); #expect(conversation.count == 2)
    }
    // TS chat-transcript.test.ts:354
    @Test func returnedMessageIsSnapshot() async throws {
        let scratch = try BackendFoundationTestsSessionsScratch(), file = try scratch.write("chat.jsonl", [F.prompt("start"), F.reply("One.")].joined(separator: "\n") + "\n")
        let reader = NativeChatTranscriptReader(path: file.path), first = try await reader.readAll()
        try scratch.append(file, F.reply("Two.", overrides: ["uuid": "r-2"], messageOverrides: ["id": "msg_B"]) + "\n")
        _ = try await reader.readAll(); #expect(first.messages[1].text == "One.")
    }
    // TS chat-transcript.test.ts:364
    @Test func shrinkingFileResetsReader() async throws {
        let scratch = try BackendFoundationTestsSessionsScratch(), file = try scratch.write("chat.jsonl", [F.prompt("first session"), F.reply("Hello.")].joined(separator: "\n") + "\n")
        let reader = NativeChatTranscriptReader(path: file.path); _ = try await reader.readAll()
        try Data((F.prompt("reused id", overrides: ["uuid": "u-new"]) + "\n").utf8).write(to: file)
        let after = try await reader.readAll(); #expect(after.reset)
        #expect(await reader.conversation.map(\.text) == ["reused id"])
    }
    // TS chat-transcript.test.ts:375
    @Test func halfWrittenLineHeldUntilAppend() async throws {
        let whole = try F.reply("Rest of it.", overrides: ["uuid": "r-3"], messageOverrides: ["id": "msg_C"]), cut = whole.index(whole.startIndex, offsetBy: whole.count / 2)
        let scratch = try BackendFoundationTestsSessionsScratch(), file = try scratch.write("chat.jsonl", [F.prompt("start"), F.reply("Partial")].joined(separator: "\n") + "\n" + String(whole[..<cut]))
        let reader = NativeChatTranscriptReader(path: file.path)
        #expect(try await reader.readAll().messages.map(\.text) == ["start", "Partial"])
        try scratch.append(file, String(whole[cut...]) + "\n")
        #expect(try await reader.readAll().reset == false)
        #expect(await reader.conversation.map(\.text) == ["start", "Partial\n\nRest of it."])
    }
    // TS chat-transcript.test.ts:392
    @Test func tornLineAndMissingFileSurvived() async throws {
        let scratch = try BackendFoundationTestsSessionsScratch(), file = try scratch.write("chat.jsonl", "{\"type\":\"user\",\"message\":\n" + F.prompt("after the mess") + "\n")
        #expect(try await NativeChatTranscriptReader(path: file.path).readAll().messages.map(\.text) == ["after the mess"])
        #expect(try await NativeChatTranscriptReader(path: file.appendingPathComponent("nope.jsonl").path).readAll().messages.isEmpty)
    }
    // TS chat-transcript.test.ts:402
    @Test func gateSkipsLargeToolResults() throws {
        #expect(try !NativeChatTranscriptParsing.mayCarryChat(F.toolResult("toolu_1", String(repeating: "x", count: 100))))
    }
    // TS chat-transcript.test.ts:406
    @Test func gateAllowsPromptsAndReplies() throws {
        #expect(try NativeChatTranscriptParsing.mayCarryChat(F.prompt("hello")))
        #expect(try NativeChatTranscriptParsing.mayCarryChat(F.reply("hi")))
    }
    // TS chat-transcript.test.ts:411
    @Test func gateSkipsBookkeeping() throws {
        for line in [try F.json(["type": "attachment", "attachment": ["type": "file"]]), try F.json(["type": "queue-operation", "operation": "add"]), try F.json(["type": "ai-title", "aiTitle": "Chat view"])] { #expect(!NativeChatTranscriptParsing.mayCarryChat(line)) }
    }
    // TS chat-transcript.test.ts:447
    @Test func confinedTranscriptDiscoveredAndApproved() throws {
        let scratch = try BackendFoundationTestsSessionsScratch(), cwd = "/Users/apple/Projects/terminaldeck"
        let path = try scratch.write("homes/dev-a/.claude/projects/" + NativeTranscriptPaths.encodeProjectPath(cwd) + "/sess-phone.jsonl", [F.prompt("what is failing?"), F.reply("the build.")].joined(separator: "\n") + "\n")
        let config = scratch.root.appendingPathComponent("config").path
        try FileManager.default.createDirectory(atPath: config + "/projects/" + NativeTranscriptPaths.encodeProjectPath(cwd), withIntermediateDirectories: true)
        let scope = NativeTranscriptScope(configDirectory: config, deviceHomesRoot: scratch.root.appendingPathComponent("homes").path)
        #expect(try NativeTranscriptPaths.newest(cwd, scope: scope)?.path == path.path)
        #expect(try NativeTranscriptPaths.assertTranscript(path.path, scope: scope) == NativeTranscriptPaths.canonical(path.path))
    }
    // TS chat-transcript.test.ts:469
    @Test func newestStoreWinsByTime() throws {
        let scratch = try BackendFoundationTestsSessionsScratch(), base = "homes/dev-a/.claude/projects/" + NativeTranscriptPaths.encodeProjectPath("/Users/apple/Projects/terminaldeck")
        let old = try scratch.write(base + "/sess-old.jsonl", F.prompt("yesterday") + "\n")
        try scratch.modified(old, milliseconds: 1700000000000)
        let new = try scratch.write(base + "/sess-new.jsonl", F.prompt("today") + "\n")
        let scope = NativeTranscriptScope(configDirectory: scratch.root.appendingPathComponent("config").path, deviceHomesRoot: scratch.root.appendingPathComponent("homes").path)
        #expect(try NativeTranscriptPaths.newest("/Users/apple/Projects/terminaldeck", scope: scope)?.path == new.path)
    }
    // TS chat-transcript.test.ts:489
    @Test func noStoreAnswersNothing() throws {
        let scratch = try BackendFoundationTestsSessionsScratch()
        #expect(try NativeTranscriptPaths.newest("/nowhere/at/all", scope: .init(configDirectory: scratch.root.appendingPathComponent("missing").path)) == nil)
    }
}
