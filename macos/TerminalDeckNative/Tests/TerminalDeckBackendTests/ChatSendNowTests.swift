import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 29 Oct (Asad: "Send now" gave "The private session host connection failed (POSIX status 60)"). His chat's answer
/// had ended while a background task still ran, so the store sent no interrupt (it thought the turn was over), waited
/// 10 s for the chat to be idle, and the app had stopped waiting for the helper after 10 s. Send now works every time.
@Suite("Send now: the message goes in at once, never a timeout", .serialized)
struct ChatSendNowTests {
    /// A fake Claude Code. Message 1: starts a background task and ends its answer (the task keeps running); when
    /// `ignore-interrupt` exists it instead keeps answering and never honours an interrupt. Every input line is logged.
    static let stub = #"""
    #!/bin/sh
    printf 'launch %s\n' "$*" >> launches.txt
    read init
    id=$(printf '%s' "$init" | /usr/bin/sed -E 's/.*"request_id":"([^"]*)".*/\1/')
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$id"
    n=0
    while read line; do
      printf '%s\n' "$line" >> inputs.txt
      case "$line" in *'"subtype":"interrupt"'*) continue ;; esac
      n=$((n+1))
      printf '{"type":"system","subtype":"init","session_id":"send-now"}\n'
      if [ "$n" = 1 ] && [ -f ignore-interrupt ] && [ ! -f relaunched ]; then
        touch relaunched
        printf '{"type":"system","subtype":"session_state_changed","state":"running"}\n'
        printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working on it"}]}}\n'
        continue
      fi
      if [ "$n" = 1 ] && [ ! -f ignore-interrupt ]; then
        printf '{"type":"system","subtype":"task_started","task_id":"bg-1","description":"Running cd /tmp/ps && python3","task_type":"local_bash"}\n'
      fi
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"answer %s"}]}}\n' "$n"
      printf '{"type":"result","subtype":"success","is_error":false,"session_id":"send-now","result":"answer"}\n'
    done
    """#

    private struct Chat {
        let root: URL, chats: BackendSessionChats, id: String
        func inputs() -> String { (try? String(contentsOf: root.appendingPathComponent("inputs.txt"), encoding: .utf8)) ?? "" }
        func launches() -> Int { ((try? String(contentsOf: root.appendingPathComponent("launches.txt"), encoding: .utf8)) ?? "").split(separator: "\n").count }
    }
    private func chat(ignoreInterrupt: Bool) async throws -> Chat {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-send-now-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if ignoreInterrupt { try Data().write(to: root.appendingPathComponent("ignore-interrupt")) }
        let script = root.appendingPathComponent("claude")
        try Data(Self.stub.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let manager = BackendPTYManager(inheritedEnvironment: ["PATH": "/usr/bin:/bin"]) { _ in }
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in },
            usageReport: { _ in .object([]) }, modelCatalogue: { .object([]) })
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        let meta = try await chats.launch(input, spawn: .init(provider: "claude", command: script.path, args: ["--session-id", "send-now"],
            path: "/usr/bin:/bin", env: ["CLAUDE_CONFIG_DIR": root.path], tabKey: "send-now-tab"))
        return .init(root: root, chats: chats, id: meta.id)
    }
    private func until(_ seconds: Int = 8, _ check: () async throws -> Bool) async throws -> Bool {
        let end = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < end { if try await check() { return true }; try await Task.sleep(for: .milliseconds(30)) }
        return false
    }

    /// His case: the answer ended, a background task still runs. Send now delivers at once, sends no interrupt, and
    /// the task keeps running.
    @Test func besideABackgroundTaskSendNowGoesInAtOnce() async throws {
        let c = try await chat(ignoreInterrupt: false)
        defer { try? FileManager.default.removeItem(at: c.root) }
        _ = try await c.chats.say(c.id, text: "first", clientMessageID: "first-id")
        #expect(try await until { (try await c.chats.read(c.id, cursor: nil, limit: 500)["events"].elements ?? []).contains { $0["kind"].string == "completed" } })
        let busy = try await c.chats.read(c.id, cursor: nil, limit: 500)
        #expect(busy["busy"].bool == true && busy["foreground"].bool == false, "the answer ended; only the background task runs")
        let started = ContinuousClock.now
        let delivered = try await c.chats.steer(c.id, text: "second", clientMessageID: "second-id")
        #expect((delivered["events"].elements ?? []).contains { $0["value"]["clientMessageId"].string == "second-id" && $0["value"]["deliveryConfirmed"].bool == true })
        #expect(ContinuousClock.now - started < .seconds(3), "no 10 s wait")
        #expect(try await until { c.inputs().contains("second") })
        #expect(!c.inputs().contains("\"subtype\":\"interrupt\""), "nothing to interrupt: the task keeps running")
        #expect(c.launches() == 1)
        await c.chats.close(c.id)
    }

    /// When the AI keeps answering and ignores the interrupt, Send now stops its process (the conversation resumes)
    /// and the message goes in: it works every time.
    @Test func anIgnoredInterruptStillDeliversTheMessage() async throws {
        let c = try await chat(ignoreInterrupt: true)
        defer { try? FileManager.default.removeItem(at: c.root) }
        _ = try await c.chats.say(c.id, text: "first")
        #expect(try await until { (try await c.chats.read(c.id, cursor: nil, limit: 500)["foreground"].bool) == true })
        let delivered = try await c.chats.steer(c.id, text: "second", clientMessageID: "restart-id")
        #expect((delivered["events"].elements ?? []).contains { $0["value"]["clientMessageId"].string == "restart-id" })
        #expect(c.inputs().contains("\"subtype\":\"interrupt\""), "it was asked to stop first")
        #expect(try await until { c.inputs().contains("second") }, "then the message went in")
        #expect(c.launches() == 2, "its process was started again, in the same conversation")
        await c.chats.close(c.id)
    }

    @Test func deliveryIDCrossesThePrivateKeeperConnectionAndSurvivesReload() async throws {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("sn-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("claude")
        try Data(Self.stub.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let service = BackendHOSTChats(manager: manager, directory: root.appendingPathComponent("chats"))
        let paths = try BackendHOSTPaths(dataDirectory: root)
        _ = try paths.secret(create: true)
        let server = try BackendHOSTServer(paths: paths, hostVersion: "scratch-send-now", manager: manager,
            launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { manager.chatHostSnapshot($0) }, onIdle: {},
            resource: { method, payload in try await service.invoke(method, payload: payload) }, chatUpdates: { try await service.subscribe() })
        defer { server.stopListening() }
        let client = try BackendHOSTClient(paths: paths)
        defer { client.detach() }
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        let spawn = BackendSpawnSpec(provider: "claude", command: script.path, args: [], path: "/usr/bin:/bin", tabKey: "send-now")
        let session = try client.create(BackendHOSTProtocol.Launch(id: UUID().uuidString, input: input, spawn: spawn, inheritedEnvironment: [:]))
        let app = BackendSessionChats(manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
            directory: root.appendingPathComponent("unused-app"), publish: { _, _ in })
        try await app.useHost(client)
        // Current phone/tool callers omit the optional ID; the new app supplies one on the wire.
        let first = try await app.say(session.id, text: "first")
        #expect((first["events"].elements ?? []).contains { $0["value"]["deliveryConfirmed"].bool == true && $0["value"]["clientMessageId"].string?.isEmpty == false })
        #expect(try await until { try await app.read(session.id, cursor: nil, limit: 500)["foreground"].bool == false })
        let second = try await app.steer(session.id, text: "second", clientMessageID: "wire-steer")
        #expect((second["events"].elements ?? []).contains { $0["value"]["clientMessageId"].string == "wire-steer" })
        #expect(try await until { try await app.read(session.id, cursor: nil, limit: 500)["foreground"].bool == false })
        let third = try await app.steer(session.id, text: "third")
        let receiptIDs = (third["events"].elements ?? []).filter { $0["value"]["deliveryConfirmed"].bool == true }.compactMap { $0["value"]["clientMessageId"].string }
        #expect(receiptIDs.count == 3 && Set(receiptIDs).count == 3, "Default-ID say/steer and caller-supplied IDs remain distinct")
        let replay = NativeRPCValue.object([.init("id", .string(session.id)), .init("text", .string("second")), .init("attachments", .array([])),
            .init("context", .object([])), .init("clientMessageId", .string("wire-steer"))])
        _ = try await service.invoke("chats.steer", payload: replay.encodedJSON())
        let inputs = try String(contentsOf: root.appendingPathComponent("inputs.txt"), encoding: .utf8)
        #expect(inputs.split(separator: "\n").filter { $0.contains("second") }.count == 1, "Replaying a keeper request never writes the message twice")
        _ = try await service.invoke("chats.stopAll", payload: Data("{}".utf8))
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("chats"), includingPropertiesForKeys: nil)
        var found = false
        while let file = files?.nextObject() as? URL {
            if file.pathExtension == "json", let bytes = try? Data(contentsOf: file), String(data: bytes, encoding: .utf8)?.contains("wire-steer") == true {
                let reloaded = try BackendHootChatStore(file: file)
                found = (await reloaded.snapshot()["events"].elements ?? []).contains { $0["value"]["clientMessageId"].string == "wire-steer" }
                if found { break }
            }
        }
        #expect(found, "the delivery receipt remains in the saved conversation")
    }

    @Test func journalledMessageWithFailedPipeWriteHasNoDeliveryReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-send-now-broken-pipe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let store = try BackendHootChatStore(file: file)
        // Keep the child alive, but close stdin before say. The journal append still happens; the pipe write fails.
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", "exec 0<&-; touch closed; sleep 30"], cwd: root.path, environment: [:]))
        #expect(try await until { FileManager.default.fileExists(atPath: root.appendingPathComponent("closed").path) })
        do { _ = try await store.say("same words", clientMessageID: "failed-id"); Issue.record("Broken pipe accepted input") } catch {}
        let events = await store.snapshot()["events"].elements ?? []
        #expect(events.contains { $0["kind"].string == "user" && $0["value"]["text"].string == "same words" })
        // 4087fc85: the user row names its id before the write; only `deliveryConfirmed` is a delivery receipt.
        func receipt(_ event: NativeRPCValue) -> Bool { event["value"]["clientMessageId"].string == "failed-id" && event["value"]["deliveryConfirmed"].bool == true }
        #expect(!events.contains(where: receipt))
        await store.stop()
        let reloaded = try BackendHootChatStore(file: file)
        #expect(!(await reloaded.snapshot()["events"].elements ?? []).contains(where: receipt))
    }

    /// The app waits for the helper's answer to Send now (stop, confirm, maybe start again), never cutting it off at 10 s.
    @Test func theAppWaitsForTheHelpersSendNowAnswer() {
        func deadline(_ method: String?) -> Int {
            var request = BackendHOSTProtocol.Request(secret: "s", operation: .resource, id: "chat")
            request.resourceMethod = method
            return BackendHOSTClient.replyDeadlineMilliseconds(request)
        }
        #expect(deadline("chats.steer") == 60_000 && deadline("chats.say") == 60_000)
        #expect(deadline("chats.interrupt") == 30_000 && deadline("chats.stop") == 30_000)
        #expect(deadline("chats.read") == 10_000, "everything else as before")
    }
}
