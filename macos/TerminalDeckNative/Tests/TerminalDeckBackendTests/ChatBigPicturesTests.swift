import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 28 Oct (Asad, CRM chat, chat.json 12 MB): pictures the AI read with its Read tool were kept as inline base64 twice
/// per picture, the helper's replies outgrew the app's 8 MB reply limit, and every send, seen-marker and phone read
/// failed with "JSON body is too large". A chat must never become unopenable because of its pictures.
@Suite("Chats with many pictures stay openable, small on disk and on the wire", .serialized)
struct ChatBigPicturesTests {
    static func picture(_ bytes: Int = 400_000) -> String { Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).base64EncodedString() }
    /// A tool result as Claude Code's stream gives it for a Read of an image: the content block and the tool's own copy.
    static func readResult(_ base64: String) -> NativeRPCValue {
        .object([.init("output", .array([.object([.init("type", .string("image")), .init("source", .object([
            .init("type", .string("base64")), .init("data", .string(base64)), .init("media_type", .string("image/jpeg"))]))])])),
            .init("details", .object([.init("type", .string("image")), .init("file", .object([.init("base64", .string(base64)),
                .init("type", .string("image/jpeg")), .init("originalSize", .number(300_000))]))]))])
    }
    static func longestString(_ value: NativeRPCValue) -> Int {
        switch value {
        case .string(let text): return text.utf8.count
        case .array(let items): return items.map(longestString).max() ?? 0
        case .object(let fields): return fields.map { longestString($0.value) }.max() ?? 0
        default: return 0
        }
    }

    @Test func onlyPictureBytesLeaveForAWindowOrAPhone() {
        let blob = Self.picture(30_000), prose = String(repeating: "A long tool answer with words. ", count: 1_000)
        let snapshot = NativeRPCValue.object([.init("events", .array([
            .object([.init("kind", .string("toolResult")), .init("value", Self.readResult(blob).setting("text", .string(prose)))]),
            .object([.init("kind", .string("message")), .init("value", .object([.init("text", .string(blob))]))])]))])
        let slim = BackendChatMedia.slim(snapshot), events = slim["events"].elements ?? []
        let result = events[0]["value"]
        #expect(result["output"].elements?.first?["source"]["data"].string == "")
        #expect(result["output"].elements?.first?["source"]["dataOmitted"].number == Double(blob.utf8.count / 4 * 3))
        #expect(result["output"].elements?.first?["source"]["media_type"].string == "image/jpeg", "what it was stays")
        #expect(result["details"]["file"]["base64"].string == "")
        #expect(result["text"].string == prose, "words are never cut")
        #expect(events[1]["value"]["text"].string == blob, "an answer's own text is never touched")
        let plain = NativeRPCValue.object([.init("events", .array([.object([.init("kind", .string("message")), .init("value", .object([.init("text", .string("hi"))]))])]))])
        #expect(BackendChatMedia.slim(plain) == plain)
    }

    @Test func aPictureIsKeptOnceAsAFileAndAnUnreadableOneStaysInline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-chat-media-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let blob = Self.picture(), media = root.appendingPathComponent("media")
        let kept = BackendChatMedia.keep(HootChatRecord(.toolResult, id: "toolu_1", value: Self.readResult(blob)), in: media)
        let source = kept.value["output"].elements?.first?["source"] ?? .null, file = kept.value["details"]["file"]
        let name = try #require(source["dataFile"].string)
        #expect(name.hasPrefix("media/") && name.hasSuffix(".jpg"))
        #expect(file["base64File"].string == name, "the two copies of one picture are one file")
        #expect(try Data(contentsOf: root.appendingPathComponent(name)) == Data(base64Encoded: blob))
        #expect(try FileManager.default.contentsOfDirectory(atPath: media.path).count == 1)
        #expect(Self.longestString(kept.value) < 1_000)
        #expect(kept.messageID == "toolu_1" && kept.kind == .toolResult)
        // Not decodable as a picture: kept exactly as it came (nothing is ever lost).
        let odd = String(blob.dropLast(3))
        let inline = BackendChatMedia.keep(HootChatRecord(.toolResult, value: Self.readResult(odd)), in: media)
        #expect(inline.value == Self.readResult(odd))
    }

    /// His chat, in miniature: a conversation saved inline by the build he runs (8 pictures, about 8.5 MB). It opens,
    /// takes a message that brings another picture, loses nothing, and is written back small.
    @Test func aBigChatSavedInlineOpensTakesMessagesAndLosesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-chat-big-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("chats/big-tab"), conversation = "big-conversation"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var events: [NativeRPCValue] = []
        func event(_ kind: String, _ value: NativeRPCValue, turn: String = "t1", id: String = "") {
            let sequence = events.count + 1
            events.append(.object([.init("version", .number(1)), .init("id", .string(conversation + ":\(sequence)")), .init("conversationId", .string(conversation)),
                .init("turnId", .string(turn)), .init("sequence", .number(Double(sequence))), .init("provider", .string("claude")),
                .init("kind", .string(kind)), .init("messageId", .string(id)), .init("value", value), .init("at", .number(1_793_215_363_608 + Double(sequence)))]))
        }
        event("user", .object([.init("text", .string("Look at all five versions")), .init("attachmentCount", .number(0))]))
        for index in 0..<8 {
            event("toolCall", .object([.init("name", .string("Read")), .init("input", .object([.init("file_path", .string("/tmp/v\(index).jpg"))]))]), id: "toolu_\(index)")
            event("toolResult", Self.readResult(Self.picture()), id: "toolu_\(index)")
        }
        event("message", .object([.init("text", .string("A is the best one."))]))
        event("completed", .object([]))
        let saved = NativeRPCValue.object([.init("version", .number(1)), .init("conversationId", .string(conversation)), .init("provider", .string("claude")),
            .init("sessionId", .string("big-session")), .init("contextKey", .null), .init("events", .array(events))])
        let chatFile = folder.appendingPathComponent("chat.json")
        try saved.encodedJSON().write(to: chatFile)
        let original = try Data(contentsOf: chatFile), before = original.count
        #expect(before > 8 * 1_048_576, "bigger than the reply limit that stopped his chat")

        let script = try Self.stubClaude(in: root)
        let manager = BackendPTYManager(inheritedEnvironment: ["PATH": "/usr/bin:/bin"]) { _ in }
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in },
            usageReport: { _ in .object([]) }, modelCatalogue: { .object([]) })
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        let meta = try await chats.launch(input, spawn: .init(provider: "claude", command: script.path, args: ["--resume", "big-session"],
            path: "/usr/bin:/bin", env: ["CLAUDE_CONFIG_DIR": root.path], tabKey: "big-tab"))
        // It opens: the whole history, pictures as stand-ins.
        let opened = try await chats.read(meta.id, cursor: nil, limit: 500)
        #expect((opened["events"].elements ?? []).count == events.count)
        #expect(Self.longestString(opened) < 16 * 1024)
        // It takes a message.
        _ = try await chats.say(meta.id, text: "why not all?")
        let end = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < end {
            if case .done = try await chats.turn(meta.id).state { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard case .done = try await chats.turn(meta.id).state else { Issue.record("the message was not answered"); return }
        // Nothing lost; the file is written back small; every picture is a file beside it.
        let after = try NativeRPCValue.parseJSON(Data(contentsOf: chatFile))
        let kept = after["events"].elements ?? []
        #expect(kept.count > events.count)
        for (index, old) in events.enumerated() {
            #expect(kept[index]["kind"] == old["kind"] && kept[index]["sequence"] == old["sequence"] && kept[index]["messageId"] == old["messageId"])
        }
        #expect(kept.contains { $0["kind"].string == "user" && $0["value"]["text"].string == "why not all?" })
        #expect(kept.contains { $0["kind"].string == "message" && $0["value"]["text"].string == "A is the best one." })
        let size = try Data(contentsOf: chatFile).count
        #expect(size < 1_048_576, "chat.json no longer grows with picture bytes (\(size) bytes)")
        #expect(Self.longestString(after) < 16 * 1024)
        let media = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("media").path)
        #expect(media.count == 9, "8 old pictures and the new one, each once")
        // Reviewer 28 Oct (MUST): the original is kept once, byte for byte, before the first save without its pictures.
        let backup = folder.appendingPathComponent("chat.json.pre-media")
        #expect(try Data(contentsOf: backup) == original, "the backup is the original, byte for byte")
        #expect((try NativeRPCValue.parseJSON(Data(contentsOf: backup))["events"].elements ?? []).count == events.count)
        #expect(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int == 0o600)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains { $0.hasSuffix(".tmp") }, "no half-written file left")
        // A later save never replaces the backup.
        try BackendChatMedia.keepOriginal(chatFile)
        #expect(try Data(contentsOf: backup) == original)
        await chats.close(meta.id)
    }

    @Test func aDurableWriteReplacesWholeAndLeavesNothingBehind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-chat-durable-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chat.json")
        try BackendChatMedia.durableWrite(Data("first".utf8), to: file)
        try BackendChatMedia.durableWrite(Data("second".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("second".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["chat.json"])
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        // No backup of a conversation that has no file yet; an existing backup stays as it is.
        try BackendChatMedia.keepOriginal(root.appendingPathComponent("missing.json"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing.json.pre-media").path))
        try BackendChatMedia.keepOriginal(file)
        try BackendChatMedia.durableWrite(Data("third".utf8), to: file)
        try BackendChatMedia.keepOriginal(file)
        #expect(try Data(contentsOf: root.appendingPathComponent("chat.json.pre-media")) == Data("second".utf8))
    }

    /// A fake Claude Code that, for each message, reads one more picture (its stream's own shape) and answers.
    static func stubClaude(in root: URL) throws -> URL {
        let script = root.appendingPathComponent("claude")
        try Data(#"""
        #!/bin/sh
        read init
        id=$(printf '%s' "$init" | /usr/bin/sed -E 's/.*"request_id":"([^"]*)".*/\1/')
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$id"
        pic=$(/bin/dd if=/dev/urandom bs=1000 count=300 2>/dev/null | /usr/bin/base64 | /usr/bin/tr -d '\n')
        while read line; do
          printf '{"type":"system","subtype":"init","session_id":"big-session"}\n'
          printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_new","name":"Read","input":{"file_path":"/tmp/v9.jpg"}}]}}\n'
          printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_new","content":[{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"%s"}}]}]},"tool_use_result":{"type":"image","file":{"base64":"%s","type":"image/jpeg"}}}\n' "$pic" "$pic"
          printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"All five, then."}]}}\n'
          printf '{"type":"result","subtype":"success","is_error":false,"session_id":"big-session","result":"All five, then."}\n'
        done
        """#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Opt-in, on a scratch COPY of a real conversation (TD_BIG_CHAT_COPY=<copied chat.json>; never the live file):
    /// it opens with every event, takes a message, loses nothing and is written back small.
    @Test func aRealBigChatCopyOpensAndTakesAMessage() async throws {
        guard let source = ProcessInfo.processInfo.environment["TD_BIG_CHAT_COPY"], FileManager.default.fileExists(atPath: source) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-chat-real-" + UUID().uuidString)
        let folder = root.appendingPathComponent("chats/real-tab")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chatFile = folder.appendingPathComponent("chat.json")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: chatFile)
        let original = try NativeRPCValue.parseJSON(Data(contentsOf: chatFile))
        let before = original["events"].elements ?? []
        let script = try Self.stubClaude(in: root)
        let manager = BackendPTYManager(inheritedEnvironment: ["PATH": "/usr/bin:/bin"]) { _ in }
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in },
            usageReport: { _ in .object([]) }, modelCatalogue: { .object([]) })
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        let meta = try await chats.launch(input, spawn: .init(provider: "claude", command: script.path, args: ["--resume", original["sessionId"].string ?? "real"],
            path: "/usr/bin:/bin", env: ["CLAUDE_CONFIG_DIR": root.path], tabKey: "real-tab"))
        let opened = try await chats.read(meta.id, cursor: nil, limit: 500)
        let wire = try opened.encodedJSON().count
        #expect(wire < 2 * 1_048_576, "the newest 500 events travel small (\(wire) bytes)")
        _ = try await chats.say(meta.id, text: "why not all?")
        let end = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < end {
            if case .done = try await chats.turn(meta.id).state { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .done = try await chats.turn(meta.id).state else { Issue.record("the message was not answered"); return }
        let after = try NativeRPCValue.parseJSON(Data(contentsOf: chatFile))["events"].elements ?? []
        #expect(after.count > before.count)
        for (index, old) in before.enumerated() {
            #expect(after[index]["sequence"] == old["sequence"] && after[index]["kind"] == old["kind"] && after[index]["messageId"] == old["messageId"])
            if !["toolResult", "toolCall"].contains(old["kind"].string ?? "") { #expect(after[index]["value"] == old["value"], "event \(index) is unchanged") }
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent("chat.json.pre-media")) == Data(contentsOf: URL(fileURLWithPath: source)), "his original, byte for byte")
        let size = try Data(contentsOf: chatFile).count
        print("real copy: \(before.count) events, \(try Data(contentsOf: URL(fileURLWithPath: source)).count) -> \(size) bytes, wire \(wire) bytes")
        #expect(size < 3 * 1_048_576)
        await chats.close(meta.id)
    }

    /// The helper's reply is read up to the frame limit it writes with, not the 8 MB request limit (the fault itself).
    @Test func aHelperReplyBiggerThanTheRequestLimitIsRead() async throws {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("cbp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blob = Self.picture(7_000_000)   // a 9.3 MB reply
        let reply = try NativeRPCValue.object([.init("events", .array([.object([.init("kind", .string("toolResult")),
            .init("value", Self.readResult(blob))])]))]).encodedJSON()
        #expect(reply.count > BackendHOSTProtocol.maximumRequestBytes)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let paths = try BackendHOSTPaths(dataDirectory: root)
        _ = try paths.secret(create: true)
        let server = try BackendHOSTServer(paths: paths, hostVersion: "big-reply", manager: manager, launch: { _ in throw BackendHOSTFailure.unavailable },
            snapshot: { _ in nil }, onIdle: {}, resource: { _, _ in reply })
        defer { server.stopListening() }
        let client = try BackendHOSTClient(paths: paths)
        defer { client.detach() }
        let raw = try await client.resource("chats.read", arguments: .object([.init("id", .string("big"))]))
        #expect(raw["events"].elements?.first?["value"]["details"]["file"]["base64"].string == blob)
        // The app's chat client hands the window and phones stand-ins only.
        let slim = try await BackendHOSTChatClient(client: client).call("read", id: "big")
        #expect(Self.longestString(slim) < 16 * 1024)
    }

    /// A phone pages through a chat with pictures: each page fits a phone frame and nothing is skipped.
    @Test func aPhonePagesThroughAChatWithPictures() async throws {
        var events: [NativeRPCValue] = []
        for sequence in 1...12 {
            let kind = sequence % 3 == 0 ? "toolResult" : "message"
            let value = kind == "toolResult" ? Self.readResult(Self.picture(200_000)) : .object([.init("text", .string("Line \(sequence)"))])
            events.append(HootChatEvent(conversationID: "c", turnID: "t\(sequence)", sequence: sequence, provider: .claude,
                record: HootChatRecord(kind == "toolResult" ? .toolResult : .message, value: value)).wireValue)
        }
        let snapshot = NativeRPCValue.object([.init("conversationId", .string("c")), .init("events", .array(events)), .init("busy", .bool(false))])
        let slim = BackendChatMedia.slim(snapshot)
        let bytes = try slim.encodedJSON().count
        #expect(bytes < (BackendRemoteProtocol.limits["MAX_MESSAGE_BYTES"] ?? 65_536), "the whole chat fits one phone frame (\(bytes) bytes)")
        #expect((slim["events"].elements ?? []).count == 12)
    }
}
