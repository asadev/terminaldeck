#if DEBUG
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// One offline dev-copy check; no real login, session or AI request is involved.
@MainActor
enum DevChatSendCheck {
    static func run() async throws -> Any {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-0606g-send-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("provider.py")
        try #"""
        import json, sys
        def emit(value):
            print(json.dumps(value), flush=True)
        emit({'type':'system','subtype':'init','session_id':'offline-chat-0606g'})
        emit({'type':'system','subtype':'task_started','task_id':'watcher','description':'Offline watcher'})
        emit({'type':'system','subtype':'session_state_changed','state':'idle'})
        for line in sys.stdin:
            row = json.loads(line)
            if row.get('type') == 'user':
                emit({'type':'system','subtype':'session_state_changed','state':'running'})
        """#.write(to: script, atomically: true, encoding: .utf8)
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"))
        do {
            try await store.attach(.init(command: "/usr/bin/python3", arguments: ["-u", script.path], cwd: root.path,
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path]))
            var snapshot = await store.snapshot()
            for _ in 0..<200 {
                if snapshot["busy"].bool == true, snapshot["foreground"].bool == false { break }
                try await Task.sleep(for: .milliseconds(25)); snapshot = await store.snapshot()
            }
            guard snapshot["busy"].bool == true, !BackendHootChatStore.foreground(in: snapshot) else {
                throw NativeRPCError.invalidArguments("The offline watcher did not become idle.")
            }
            var sends = 0
            let model = NativeHootChatModel(fixture: snapshot, chatInvoke: { channel, arguments in
                if channel.hasSuffix(":say") {
                    sends += 1
                    return try await store.say(arguments.first as? String ?? "").foundation ?? [:]
                }
                return await store.snapshot().foundation ?? [:]
            })
            var draft = model.composerDraft; draft.text = "Idle message"
            model.send(draft)
            for _ in 0..<200 {
                if sends == 1, !model.sending { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard sends == 1, model.queuedMessages.isEmpty, model.problem == nil else {
                throw NativeRPCError.invalidArguments("The idle message did not go straight through.")
            }
            snapshot = await store.snapshot()
            for _ in 0..<200 {
                if BackendHootChatStore.foreground(in: snapshot) { break }
                try await Task.sleep(for: .milliseconds(25)); snapshot = await store.snapshot()
            }
            guard BackendHootChatStore.foreground(in: snapshot) else {
                throw NativeRPCError.invalidArguments("The offline AI did not start its answer.")
            }
            model.acceptFixtureUpdate(snapshot)
            draft.text = "During answer"
            model.send(draft)
            let composerHeld = sends == 1 && model.queuedMessages.count == 1
            let receipt = try await store.say("Tool or phone message")
            let backendHeld = receipt["queued"].bool == true && (receipt["queuedMessages"].elements ?? []).count == 1
            guard composerHeld, backendHeld else {
                throw NativeRPCError.invalidArguments("A message bypassed the active answer.")
            }
            await store.stop()
            return ["idle_with_watcher_sent": true, "active_turn_composer_held": composerHeld,
                    "active_turn_shared_tool_phone_path_held": backendHeld, "checks_passed": 3, "checks_failed": 0,
                    "offline_provider": true]
        } catch { await store.stop(); throw error }
    }
}
#endif
