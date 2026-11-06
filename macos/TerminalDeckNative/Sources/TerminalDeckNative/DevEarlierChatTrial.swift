#if DEBUG
import Foundation
import CryptoKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// A single real-provider trial in the dev copy's private scratch folder. It owns every process and file it creates.
enum DevEarlierChatTrial {
    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NativeRPCError(code: "dev-trial", message: message) }
    }
    private static func messages(_ snapshot: NativeRPCValue) -> [NativeRPCValue] {
        (snapshot["events"].elements ?? []).filter { ["user", "message"].contains($0["kind"].string ?? "") }
    }
    private static func progress(_ phase: String, counts: [String: Int] = [:]) throws {
        guard let out = DevReload.outFolder else { return }
        var value: [String: Any] = counts
        value["phase"] = phase
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: out.appendingPathComponent("r3-trial-progress.json"), options: .atomic)
    }
    private static func journalObservation(_ file: URL, baseline: Data, phase: String) throws -> [String: Any] {
        let bytes = try Data(contentsOf: file)
        let before = try JSONSerialization.jsonObject(with: baseline) as? [String: Any] ?? [:]
        let after = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
        func canonical(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let beforeEvents = try canonical(before["events"] ?? []), afterEvents = try canonical(after["events"] ?? [])
        let changed = try Set(before.keys).union(after.keys).sorted().filter {
            try canonical(before[$0] ?? NSNull()) != canonical(after[$0] ?? NSNull())
        }
        let originals = before["events"] as? [[String: Any]] ?? []
        let rows = after["events"] as? [[String: Any]] ?? []
        let prefixBytes = try canonical(Array(rows.prefix(originals.count)))
        let prefixUnchanged = prefixBytes == beforeEvents
        let appended = Array(rows.dropFirst(originals.count))
        let policyKeys: Set<String> = ["provider", "providerConversationId", "source", "reason", "authority", "sandbox", "approval", "workspaceTrust", "network"]
        let allowedReceipts = appended.filter { row in
            let value = row["value"] as? [String: Any] ?? [:], policy = value["effectivePolicy"] as? [String: Any] ?? [:]
            return row["kind"] as? String == "session" && row["turnId"] as? String == ""
                && row["conversationId"] as? String == before["conversationId"] as? String
                && row["provider"] as? String == before["provider"] as? String
                && row["messageId"] as? String == ""
                && (row["sequence"] as? NSNumber)?.intValue == ((originals.last?["sequence"] as? NSNumber)?.intValue ?? 0) + 1
                && Set(value.keys) == ["effectivePolicy"] && Set(policy.keys) == policyKeys
                && policy["source"] as? String == "provider-policy-not-current"
                && policy["reason"] as? String == "The provider process stopped. No current boundary is confirmed."
                && policy["provider"] as? String == before["provider"] as? String
                && policy["providerConversationId"] as? String == before["sessionId"] as? String
                && policy["authority"] as? String == "not-current"
                && ["sandbox", "approval", "workspaceTrust", "network"].allSatisfy { policy[$0] is NSNull }
        }.count
        // Releasing the old provider deliberately saves one invalidated permission receipt; keep it intact.
        let historyRetained = prefixUnchanged && appended.count <= 1 && allowedReceipts == appended.count
        let observation: [String: Any] = ["bytesUnchanged": bytes == baseline, "eventsUnchanged": beforeEvents == afterEvents,
            "beforeBytesSHA256": digest(baseline), "afterBytesSHA256": digest(bytes),
            "beforeEventsSHA256": digest(beforeEvents), "afterEventsSHA256": digest(afterEvents),
            "retainedPrefixSHA256": digest(prefixBytes), "originalEventCount": originals.count,
            "originalEventPrefixUnchanged": prefixUnchanged, "historyRetained": historyRetained, "allowedStoppedPolicyReceipts": allowedReceipts,
            "eventCount": rows.count, "messageCount": rows.filter { ["user", "message"].contains($0["kind"] as? String ?? "") }.count,
            "changedTopLevelKeys": changed]
        if let out = DevReload.outFolder {
            let target = out.appendingPathComponent("r3-trial-journal-observations.json")
            var saved = (try? JSONSerialization.jsonObject(with: Data(contentsOf: target))) as? [String: Any] ?? [:]
            saved[phase] = observation
            try JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys]).write(to: target, options: .atomic)
        }
        return observation
    }
    private actor LateFailureReceipt {
        private var injected = false
        private var closed = false
        private var restores = 0
        func closeOnce(confirmed: Bool) -> Bool {
            guard !injected else { return false }
            injected = true; closed = confirmed
            return true
        }
        func restored() { if injected { restores += 1 } }
        func counts() -> (Bool, Bool, Int) { (injected, closed, restores) }
    }

    /// One conversation proves recovery after its earlier provider writer has closed.
    /// args: [] or ["codex"] runs the real Codex. ["claude-standin"] runs a scripted Claude Code stand-in in the scratch
    /// folder (6 Nov: Codex was out of usage and the only Claude sign-in belongs to the installed app's data).
    static func run(_ args: [String] = []) async throws -> Any {
        guard let out = DevReload.outFolder,
              out.deletingLastPathComponent().lastPathComponent == "Terminal Deck Dev-0213" else {
            throw NativeRPCError(code: "dev-trial", message: "This trial is restricted to Dev-0213 data.")
        }
        let choice = args.first ?? "codex"
        try require(["codex", "claude-standin"].contains(choice), "The trial runs Codex or the Claude Code stand-in.")
        let claudeTrial = choice == "claude-standin", providerName = claudeTrial ? "claude" : "codex"
        let root = out.appendingPathComponent("r10-" + String(UUID().uuidString.prefix(6)).lowercased())
        let work = root.appendingPathComponent("work"), journal = root.appendingPathComponent("chats")
        try require(!FileManager.default.fileExists(atPath: root.path), "The scratch trial folder already exists.")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let claudeConversation = UUID().uuidString.lowercased()
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex"), home = URL(fileURLWithPath: NSHomeDirectory())
        let binary = claudeTrial ? "/usr/bin/python3" : home.appendingPathComponent(".local/bin/codex").path
        try require(FileManager.default.isExecutableFile(atPath: binary), "The scratch trial needs the existing \(claudeTrial ? "python3" : "Codex") command.")
        let wrapper = root.appendingPathComponent("provider")
        let standIn = root.appendingPathComponent("claude-standin.py"), launches = root.appendingPathComponent("claude-standin-launches.jsonl")
        let claudeConfig = root.appendingPathComponent("claude-config")
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if claudeTrial {
            // Claude Code's stream-json protocol as the chat engine speaks it: control replies, its init receipt (session
            // and permission mode), one answer and one result per message. Every launch records its arguments.
            try FileManager.default.createDirectory(at: claudeConfig, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.claudeStandIn.write(to: standIn, atomically: true, encoding: .utf8)
            try ("#!/bin/sh\nexec /usr/bin/python3 -u " + quoted(standIn.path) + " " + quoted(launches.path) + " \"$@\"\n").write(to: wrapper, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            do { try FileManager.default.copyItem(at: home.appendingPathComponent(".codex/auth.json"), to: codex.appendingPathComponent("auth.json")) }
            catch { throw NativeRPCError(code: "dev-trial", message: "The scratch trial could not copy the existing Codex sign-in.") }
            try ("#!/bin/sh\nexport CODEX_HOME=" + quoted(codex.path) + "\nexec " + quoted(binary) + " \"$@\"\n").write(to: wrapper, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let original = journal.appendingPathComponent("r10-source")
        let file = original.appendingPathComponent(claudeTrial ? "chat.json" : "chat-codex.json")
        let media = original.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!
        let imageFile = media.appendingPathComponent("retained.png")
        try image.write(to: imageFile)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let service = BackendHOSTChats(manager: manager, directory: journal, modelCatalogue: { .object([]) })
        let receipt = LateFailureReceipt(), paths = try BackendHOSTPaths(dataDirectory: root)
        _ = try paths.secret(create: true)
        let server = try BackendHOSTServer(paths: paths, hostVersion: "r10-private-earlier-owner", manager: manager,
            launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { manager.chatHostSnapshot($0) }, onIdle: {}, resource: { method, payload in
                let reply = try await service.invoke(method, payload: payload)
                if method == "chats.close" {
                    let absent = (try? await service.invoke("chats.read", payload: payload)) == nil
                    if await receipt.closeOnce(confirmed: absent) {
                        throw NativeRPCError(code: "dev-injected-after-close", message: "Private trial failure after the earlier AI closed.")
                    }
                }
                if method == "chats.launch" { await receipt.restored() }
                guard method == "chats.read" else { return reply }
                return try NativeRPCValue.parseJSON(reply).setting("messageActions", .null).encodedJSON()
            }, chatUpdates: { try await service.subscribe() })
        let client = try BackendHOSTClient(paths: paths)
        let app = BackendSessionChats(manager: manager, directory: journal, publish: { _, _ in }, modelCatalogue: { .object([]) })
        let cleanup: @Sendable () async -> Void = {
            await app.endAllForQuit()
            _ = try? await service.invoke("chats.stopAll", payload: Data("{}".utf8))
            server.stopListening(); client.detach(); manager.killAll()
        }
        do {
            let account = BackendAccountIdentity(id: "r10-private-account", name: "Scratch")
            var input = BackendCreateSessionInput(cwd: work.path, provider: providerName); input.chat = true
            var environment = ProcessInfo.processInfo.environment.filter { key, _ in
                !["ANTHROPIC", "OPENAI", "CLAUDE", "CODEX", "TD_DEV_INVOKE_TOKEN"].contains(where: key.contains)
            }
            if claudeTrial { environment["CLAUDE_CONFIG_DIR"] = claudeConfig.path } else { environment["CODEX_HOME"] = codex.path }
            let claudeArgs = ["--model", "haiku"]
            let spawn = BackendSpawnSpec(provider: providerName, command: wrapper.path,
                args: claudeTrial ? claudeArgs + ["--session-id", claudeConversation] : ["--model", "gpt-6.1-sol", "--sandbox", "read-only", "--ask-for-approval", "never"],
                path: environment["PATH"] ?? "/usr/bin:/bin", env: environment, profile: account,
                agentSessionId: claudeTrial ? claudeConversation : nil, tabKey: "r10-source")
            let launch = try BackendHOSTProtocol.Launch(id: UUID().uuidString.lowercased(), input: input, spawn: spawn, inheritedEnvironment: [:])
            let meta = try client.create(launch)
            for (index, text) in ["Reply exactly R10_KEEP", "Reply exactly R10_KEEP_TOO"].enumerated() {
                let attachments: [NativeRPCValue] = index == 0 ? [.object([.init("type", .string("image")),
                    .init("source", .object([.init("type", .string("base64")), .init("media_type", .string("image/png")), .init("data", .string(image.base64EncodedString()))]))])] : []
                let request = NativeRPCValue.object([.init("id", .string(meta.id)), .init("text", .string(text)),
                    .init("attachments", .array(attachments)), .init("clientMessageId", .string(UUID().uuidString))])
                _ = try await service.invoke("chats.say", payload: request.encodedJSON())
                let deadline = ContinuousClock.now + .seconds(120)
                var finished = false
                while ContinuousClock.now < deadline {
                    let snapshot = try NativeRPCValue.parseJSON(await service.invoke("chats.read", payload: request.encodedJSON()))
                    if snapshot["busy"].bool != true, messages(snapshot).count >= (index + 1) * 2 { finished = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try require(finished, "The private \(providerName) did not finish its expected reply in time.")
            }
            try await app.useHost(client)
            try await app.setDraft(meta.id, text: "First draft")
            try await app.setDraft(meta.id, text: "Second draft")
            try await app.setDraft(meta.id, text: "Keep my unsent draft")
            _ = try await app.setOptions(meta.id, claudeTrial ? .object([.init("model", .string("claude:haiku"))])
                : .object([.init("model", .string("codex:gpt-6.1-sol")), .init("effort", .string("high"))]))
            let before = try await app.read(meta.id, cursor: 0, limit: 500), choices = try await app.options(meta.id)
            let originalEvents = before["events"].elements ?? []
            let baseline = try Data(contentsOf: file)
            let sourceInput = input
            let conversation = try before["providerConversationId"].requireString("private AI conversation", nonempty: true)
            try require(!claudeTrial || conversation == claudeConversation, "Claude Code did not keep the chat's own conversation.")
            let beforePolicy = before["effectivePolicy"]
            let resumed = BackendSpawnSpec(provider: spawn.provider, command: spawn.command,
                args: claudeTrial ? claudeArgs + ["--resume", conversation] : spawn.args, path: spawn.path,
                env: spawn.env, profile: account, agentSessionId: conversation, resumed: true, tabKey: spawn.tabKey)
            await app.setEarlierEngineMove { id in
                var resume = sourceInput; resume.resume = true; resume.resumeConversationId = conversation; resume.replaces = id
                _ = try await app.moveEarlierChat(id, input: resume, spawn: resumed)
            }
            guard let secondUser = messages(before).last(where: { $0["kind"].string == "user" })?["sequence"].number else {
                throw NativeRPCError(code: "dev-trial", message: "The private source has no second message boundary.")
            }
            var failedLate = false
            do { _ = try await app.rewind(meta.id, sequence: Int(secondUser)) }
            catch { failedLate = error.localizedDescription.contains("Private trial failure after the earlier AI closed") }
            let (injected, closed, restoreCount) = await receipt.counts()
            try require(failedLate && injected && closed, "The trial did not reach its failure after the earlier AI closed.")
            try require(restoreCount == 1, "The earlier chat was not restored exactly once (post-close launches: \(restoreCount)).")
            try await app.ensure(meta.id)
            let restored = try await app.read(meta.id, cursor: 0, limit: 500), restoredChoices = try await app.options(meta.id)
            try require(messages(restored) == messages(before) && messages(restored).count >= 4, "Recovery changed the saved messages.")
            try require(Array((restored["events"].elements ?? []).prefix(originalEvents.count)) == originalEvents, "Recovery changed original events or media references.")
            try require(try Data(contentsOf: imageFile) == image, "Recovery changed the saved image.")
            try require(restored["draft"] == before["draft"] && (restored["draftRevision"].number ?? -1) >= (before["draftRevision"].number ?? 0), "Recovery lost the draft or its revision.")
            for key in ["model", "effort", "permissionMode", "fastMode"] {
                try require(restoredChoices[key] == choices[key], "Recovery changed the \(key) option.")
            }
            try await app.setDraft(meta.id, text: "A later edit must still arrive")
            let edited = try await app.read(meta.id, cursor: 0, limit: 1)
            try require(edited["draft"].string == "A later edit must still arrive"
                && (edited["draftRevision"].number ?? 0) > (before["draftRevision"].number ?? 0),
                "Recovery left later draft edits behind an older revision.")
            try await app.setDraft(meta.id, text: "Keep my unsent draft")
            let recoveredMeta = try requireMeta(manager.list(), id: meta.id)
            try require(recoveredMeta.profileId == meta.profileId && recoveredMeta.cwd == meta.cwd && recoveredMeta.tabKey == meta.tabKey,
                "Recovery changed the chat account, folder or owner identity.")
            try require(restored["providerConversationId"].string == conversation, "Recovery did not reconnect the original AI conversation.")
            try require(!FileManager.default.fileExists(atPath: original.appendingPathComponent("new-engine").path), "Recovery left a partial moved owner behind.")
            let journalCheck = try journalObservation(file, baseline: baseline, phase: "lateFailureRecovery")
            var afterTurnMessages = messages(restored).count, standInLaunches = 0
            if claudeTrial {
                // Claude Code reports its policy when a turn starts. One more message proves the restored earlier AI
                // continues the same provider conversation, and returns its receipt for it.
                let launchesBeforeTurn = (try? String(contentsOf: launches, encoding: .utf8))?.split(separator: "\n").count ?? 0
                let request = NativeRPCValue.object([.init("id", .string(meta.id)), .init("text", .string("Reply exactly R10_AFTER")),
                    .init("attachments", .array([])), .init("clientMessageId", .string(UUID().uuidString))])
                _ = try await service.invoke("chats.say", payload: request.encodedJSON())
                let deadline = ContinuousClock.now + .seconds(120)
                var answered: NativeRPCValue?
                while ContinuousClock.now < deadline {
                    let snapshot = try NativeRPCValue.parseJSON(await service.invoke("chats.read", payload: request.encodedJSON()))
                    if snapshot["busy"].bool != true, messages(snapshot).count >= messages(restored).count + 2 { answered = snapshot; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard let answered else { throw NativeRPCError(code: "dev-trial", message: "The restored Claude Code did not answer in time.") }
                let reply = messages(answered).last(where: { $0["kind"].string == "message" })?["value"]["text"].string ?? ""
                afterTurnMessages = messages(answered).count
                try require(reply.contains("R10_AFTER"), "The restored Claude Code did not answer the next message.")
                try require(answered["providerConversationId"].string == conversation, "The restored Claude Code changed its conversation.")
                let policy = answered["effectivePolicy"]
                try require(["system/init", "system/status", "set_permission_mode"].contains(policy["source"].string ?? "")
                    && policy["providerConversationId"].string == conversation
                    && policy["approval"].string != nil && policy["approval"] == beforePolicy["approval"],
                    "Claude Code did not return its real receipt for the original conversation.")
                // The restore (and any relaunch after it) resumed the saved conversation; none started a new one.
                let rows = try String(contentsOf: launches, encoding: .utf8).split(separator: "\n").map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
                let resumedRows = rows.dropFirst().filter { row in
                    let argv = (row["args"].elements ?? []).compactMap(\.string)
                    return zip(argv, argv.dropFirst()).contains { pair in pair.0 == "--resume" && pair.1 == conversation } && !argv.contains("--session-id")
                }
                try require(rows.count >= 2 && launchesBeforeTurn >= 2 && resumedRows.count == rows.count - 1,
                    "A launch after the first did not resume the saved Claude conversation.")
                standInLaunches = rows.count
            } else {
                let policy = restored["effectivePolicy"]
                try require(policy["source"].string == "thread/resume" && policy["providerConversationId"].string == conversation
                    && policy["sandbox"]["type"].string == "readOnly" && policy["approval"].string == "never",
                    "Codex did not return its real resume receipt for the original conversation.")
            }
            let evidence: [String: Any] = ["operationsPassed": 1, "operationsFailed": 0, "failureAfterSourceClose": true,
                "restores": restoreCount, "beforeMessages": messages(before).count, "afterMessages": messages(restored).count,
                "originalEventsRetained": originalEvents.count, "mediaFilesRetained": 1, "draftAndRevisionRetained": true,
                "optionsRetained": 4, "originalOwnerRestored": true, "laterDraftEditsVisible": true, "sameConversationReconnects": 1, "providerResumeReceipt": true,
                "partialMoveRemoved": true, "provider": claudeTrial ? "scripted-claude-stand-in" : "real-codex", "model": claudeTrial ? "haiku" : "gpt-6.1-sol",
                "promptTurns": claudeTrial ? 3 : 2, "afterTurnMessages": afterTurnMessages, "providerLaunches": standInLaunches,
                "journalPrefixUnchanged": journalCheck["originalEventPrefixUnchanged"] as? Bool ?? false,
                "originalSandbox": claudeTrial ? "stand-in, no tools" : "read-only", "originalApproval": claudeTrial ? (beforePolicy["approval"].string ?? "") : "never", "scratchRemoved": true]
            await cleanup()
            try FileManager.default.removeItem(at: root)
            try require(!FileManager.default.fileExists(atPath: root.path), "The scratch trial folder could not be removed.")
            try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]).write(to: out.appendingPathComponent("r10-late-failure-counts.json"), options: .atomic)
            return evidence
        } catch { await cleanup(); throw error }
    }
    /// Claude Code's chat protocol (stream-json in and out), scripted. argv[1] is the launch record file.
    private static let claudeStandIn = #"""
    import json, os, re, sys, uuid
    record, args = sys.argv[1], sys.argv[2:]
    def value(flag, default=None):
        return next((args[i + 1] for i, arg in enumerate(args[:-1]) if arg == flag), default)
    conversation = value('--session-id') or value('--resume') or 'r10-stand-in'
    mode, model = value('--permission-mode', 'default'), value('--model', 'haiku')
    with open(record, 'a') as f: f.write(json.dumps({'args': args}) + '\n')
    def out(row): print(json.dumps(row), flush=True)
    for line in sys.stdin:
        try: row = json.loads(line)
        except ValueError: continue
        if row.get('type') == 'control_request':
            request, reply = row.get('request') or {}, {}
            if request.get('subtype') == 'set_permission_mode':
                mode = request.get('mode', mode); reply = {'mode': mode}
            out({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': row.get('request_id'), 'response': reply}})
            continue
        if row.get('type') != 'user': continue
        content = (row.get('message') or {}).get('content')
        text = content if isinstance(content, str) else ' '.join(part.get('text', '') for part in content or [] if isinstance(part, dict))
        found = re.search(r'Reply exactly (\S+)', text)
        answer = found.group(1) if found else 'OK'
        out({'type': 'system', 'subtype': 'init', 'session_id': conversation, 'permissionMode': mode, 'model': model, 'tools': [], 'cwd': os.getcwd()})
        out({'type': 'assistant', 'session_id': conversation, 'parent_tool_use_id': None, 'uuid': str(uuid.uuid4()),
             'message': {'id': 'msg_' + uuid.uuid4().hex[:20], 'type': 'message', 'role': 'assistant', 'model': model,
                         'content': [{'type': 'text', 'text': answer}], 'stop_reason': 'end_turn', 'usage': {'input_tokens': 1, 'output_tokens': 1}}})
        out({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': conversation, 'result': answer,
             'num_turns': 1, 'duration_ms': 5, 'usage': {'input_tokens': 1, 'output_tokens': 1}})
    """#
    private static func requireMeta(_ sessions: [BackendSessionMeta], id: String) throws -> BackendSessionMeta {
        guard let meta = sessions.first(where: { $0.id == id }) else {
            throw NativeRPCError(code: "dev-trial", message: "Recovery did not return the chat to its original owner.")
        }
        return meta
    }

    static func runRealProviderHistoryTrial() async throws -> Any {
        guard let out = DevReload.outFolder,
              out.deletingLastPathComponent().lastPathComponent == "Terminal Deck Dev-0213" else {
            throw NativeRPCError(code: "dev-trial", message: "This trial is restricted to Dev-0213 data.")
        }
        // Keep the private socket below macOS's pathname limit, including the Dev-0213 data path.
        let root = out.appendingPathComponent("r3-" + String(UUID().uuidString.prefix(6)).lowercased())
        try require(!FileManager.default.fileExists(atPath: root.path), "The scratch trial folder already exists.")
        let work = root.appendingPathComponent("work"), codex = root.appendingPathComponent("codex")
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let binary = home.appendingPathComponent(".local/bin/codex").path
        try require(FileManager.default.isExecutableFile(atPath: binary), "The scratch trial needs the existing Codex command.")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do { try FileManager.default.copyItem(at: home.appendingPathComponent(".codex/auth.json"), to: codex.appendingPathComponent("auth.json")) }
        catch { try? FileManager.default.removeItem(at: root); throw NativeRPCError(code: "dev-trial", message: "The scratch trial could not read the existing Codex sign-in.") }
        defer { try? FileManager.default.removeItem(at: root) }
        // Session environments deliberately strip CODEX_*; apply the private home after that boundary.
        let wrapper = root.appendingPathComponent("provider")
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\nexport CODEX_HOME=" + quoted(codex.path) + "\nexec " + quoted(binary) + " \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
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
        }
        do {
            var environment = ProcessInfo.processInfo.environment.filter { key, _ in
                !["ANTHROPIC", "OPENAI", "CLAUDE", "CODEX", "TD_DEV_INVOKE_TOKEN"].contains(where: key.contains)
            }
            environment["CODEX_HOME"] = codex.path
            let account = BackendAccountIdentity(id: "r3-scratch-login", name: "Scratch")
            var input = BackendCreateSessionInput(cwd: work.path, provider: "codex"); input.chat = true
            let spawn = BackendSpawnSpec(provider: "codex", command: wrapper.path,
                args: ["--model", "gpt-6.1-sol", "--sandbox", "read-only", "--ask-for-approval", "never"], path: environment["PATH"] ?? "/usr/bin:/bin", env: environment, profile: account, tabKey: "r3-source")
            let launch = try BackendHOSTProtocol.Launch(id: UUID().uuidString.lowercased(), input: input, spawn: spawn, inheritedEnvironment: [:])
            try progress("starting_scratch_ai")
            let meta = try client.create(launch)
            for (index, text) in ["Reply exactly R3_KEEP", "Reply exactly R3_DROP"].enumerated() {
                let request = NativeRPCValue.object([.init("id", .string(meta.id)), .init("text", .string(text)), .init("clientMessageId", .string(UUID().uuidString))])
                _ = try await service.invoke("chats.say", payload: request.encodedJSON())
                let deadline = ContinuousClock.now + .seconds(120)
                var finished = false
                while ContinuousClock.now < deadline {
                    let snapshot = try NativeRPCValue.parseJSON(await service.invoke("chats.read", payload: request.encodedJSON()))
                    if snapshot["busy"].bool != true, messages(snapshot).count == (index + 1) * 2 { finished = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try require(finished, "The scratch AI did not finish its expected reply in time.")
            }
            try await app.useHost(client)
            let sourceInput = input
            let movedCountFile = root.appendingPathComponent("move-count.txt")
            let before = try await app.read(meta.id, cursor: 0, limit: 500)
            let original = messages(before)
            try require(original.count == 4, "The scratch source did not retain both exchanges.")
            try progress("source_ready", counts: ["beforeMessages": original.count])
            let originalFile = journal.appendingPathComponent("r3-source/chat-codex.json")
            let originalBytes = try Data(contentsOf: originalFile)
            _ = try journalObservation(originalFile, baseline: originalBytes, phase: "beforeMove")
            await app.setEarlierEngineMove { id in
                let snapshot = try NativeRPCValue.parseJSON(await service.invoke("chats.read", payload: NativeRPCValue.object([.init("id", .string(id))]).encodedJSON()))
                let conversation = try snapshot["providerConversationId"].requireString("scratch AI conversation", nonempty: true)
                let resumed = BackendSpawnSpec(provider: spawn.provider, command: spawn.command, args: spawn.args, path: spawn.path, env: spawn.env, profile: account, agentSessionId: conversation, resumed: true, tabKey: spawn.tabKey)
                var resume = sourceInput; resume.resume = true; resume.resumeConversationId = conversation; resume.replaces = id
                _ = try await app.moveEarlierChat(id, input: resume, spawn: resumed)
                let moved = try await app.read(id, cursor: 0, limit: 500)
                try Data(String(messages(moved).count).utf8).write(to: movedCountFile)
                let preserved = try journalObservation(originalFile, baseline: originalBytes, phase: "afterMove")
                try require(preserved["historyRetained"] as? Bool == true, "The move changed the earlier owner's saved events.")
            }
            guard let secondUser = original.last(where: { $0["kind"].string == "user" })?["sequence"].number else {
                throw NativeRPCError(code: "dev-trial", message: "The second scratch message was not recorded.")
            }
            // An occupied destination refuses the move before the earlier owner releases the conversation.
            let staging = originalFile.deletingLastPathComponent().appendingPathComponent("new-engine")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var refused = false
            do { _ = try await app.rewind(meta.id, sequence: Int(secondUser)) }
            catch { refused = error.localizedDescription.contains("previous conversation move") }
            try require(refused, "The occupied move destination was not safely refused.")
            let failed = try await app.read(meta.id, cursor: 0, limit: 500)
            let failureMessages = messages(failed)
            try require(failureMessages == original, "The refused move changed the scratch messages.")
            let failureJournal = try journalObservation(originalFile, baseline: originalBytes, phase: "failedMove")
            try require(failureJournal["eventsUnchanged"] as? Bool == true, "The refused move changed the scratch journal events.")
            try require(failureJournal["bytesUnchanged"] as? Bool == true, "The refused move changed the scratch journal bytes.")
            try progress("failed_move_kept_source", counts: ["failureBeforeMessages": original.count, "failureAfterMessages": failureMessages.count])
            try FileManager.default.removeItem(at: staging)
            _ = try await app.rewind(meta.id, sequence: Int(secondUser))
            let movedCount = Int(try String(contentsOf: movedCountFile, encoding: .utf8)) ?? -1
            try require(movedCount == 4, "The successful move lost scratch messages.")
            let rewound = try await app.read(meta.id, cursor: 0, limit: 500)
            let kept = messages(rewound)
            try require(kept.count == 2, "Rewind did not retain exactly the first exchange.")
            try progress("move_and_rewind_passed", counts: ["beforeMessages": original.count, "afterMoveMessages": movedCount, "afterRewindMessages": kept.count])
            let rewindJournal = try journalObservation(originalFile, baseline: originalBytes, phase: "afterRewind")
            try require(rewindJournal["historyRetained"] as? Bool == true, "Rewind changed the earlier owner's saved events.")
            guard let answer = kept.last(where: { $0["kind"].string == "message" })?["sequence"].number else {
                throw NativeRPCError(code: "dev-trial", message: "The retained scratch answer has no saved boundary.")
            }
            let fork = try await app.providerFeature(meta.id, operation: "fork/create", arguments: .object([.init("throughSequence", .number(answer))]))
            let forkID = try fork["conversationId"].requireString("forked AI conversation", nonempty: true)
            var childInput = input; childInput.resume = true; childInput.resumeConversationId = forkID
            let childSpawn = BackendSpawnSpec(provider: spawn.provider, command: spawn.command, args: spawn.args, path: spawn.path, env: spawn.env, profile: account, agentSessionId: forkID, resumed: true, tabKey: "r3-fork")
            let forkInput = childInput
            let child = try await BackendChatForkLaunchScope.$sourceID.withValue(meta.id) {
                try require(await app.prefersLocalEngine(tabKey: "r3-fork"), "The moved source's fork was routed to a different owner.")
                return try await app.launch(forkInput, spawn: childSpawn)
            }
            try await app.seedFork(child.id, from: meta.id, through: Int(answer))
            let copied = try await app.read(child.id, cursor: 0, limit: 500)
            let forkMessages = messages(copied)
            let afterFork = messages(try await app.read(meta.id, cursor: 0, limit: 500))
            try require(forkMessages.count == 2, "Fork did not retain the first exchange.")
            try require(forkMessages.map { $0["value"]["text"].string } == kept.map { $0["value"]["text"].string }, "Fork changed the copied words.")
            try require(afterFork == kept, "Fork changed the scratch source.")
            try require(forkID != rewound["providerConversationId"].string, "Fork reused the source AI identity.")
            let forkJournal = try journalObservation(originalFile, baseline: originalBytes, phase: "afterFork")
            try require(forkJournal["historyRetained"] as? Bool == true, "Fork changed the earlier owner's saved events.")
            let evidence: [String: Any] = ["beforeMessages": original.count, "afterMoveMessages": movedCount,
                "failureBeforeMessages": original.count, "failureAfterMessages": failureMessages.count,
                "failureJournalUnchanged": true, "failureJournalBytesUnchanged": failureJournal["bytesUnchanged"] ?? false, "afterRewindMessages": kept.count, "forkMessages": forkMessages.count,
                "sourceAfterForkMessages": afterFork.count, "originalHistoryRetained": true, "originalJournalEventsUnchanged": forkJournal["eventsUnchanged"] ?? false, "allowedStoppedPolicyReceipts": forkJournal["allowedStoppedPolicyReceipts"] ?? 0, "originalJournalBytesUnchanged": forkJournal["bytesUnchanged"] ?? false, "forkIdentitySeparate": true,
                "realProvider": "codex", "forkOwner": "same_app_as_moved_source", "operationsPassed": 4, "operationsFailed": 0, "scratchRemoved": true]
            await cleanup()
            try FileManager.default.removeItem(at: root)
            try require(!FileManager.default.fileExists(atPath: root.path), "The scratch trial folder could not be removed.")
            try progress("passed", counts: ["beforeMessages": original.count, "afterMoveMessages": movedCount, "afterRewindMessages": kept.count, "forkMessages": forkMessages.count])
            return evidence
        } catch { await cleanup(); throw error }
    }
}
#endif
