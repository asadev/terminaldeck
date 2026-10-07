import Foundation
import TerminalDeckNativeCore

public struct BackendDeckToolsSessionsOutput: Sendable {
    public let value: NativeRPCValue, summary: NativeRPCValue
    public init(_ value: NativeRPCValue, summary: NativeRPCValue) { self.value = value; self.summary = summary }
}

public enum BackendDeckToolsSessionsArea {
    typealias Args = BackendDeckToolsArgs
    typealias Rules = BackendDeckToolsSessionsRules
    static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    static func string(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
    static func bad(_ message: String) -> NativeRPCError { Args.bad(message) }
    static func refused(_ message: String, code: String = "not-permitted") -> NativeRPCError { .init(code: code, message: message) }
    static func session(_ id: String, runtime: any BackendDeckToolsSessionsRuntime, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        guard let value = try await runtime.sessions(context).first(where: { $0["id"].string == id }) else {
            throw bad("this app is not holding a session with id \(id). Either that is not one of its ids — check sessions.list — or the session was stopped, which drops it and everything this app knew about it. A session that exited on its own is still here, with its exit code; a stopped one is not. Ask before stopping something you will want to report on.")
        }
        return value
    }
    static func knownFolder(_ path: String, runtime: any BackendDeckToolsSessionsRuntime, context: BackendMCPCallContext) async throws -> String {
        guard try await runtime.knownFolders(context).contains(path) else { throw refused("\(path) is not a folder this app has open. Use projects.list to see the folders you can ask about.") }
        return path
    }
    static func definitions(module: String, runtime: any BackendDeckToolsSessionsRuntime,
                            run: @escaping @Sendable (BackendDeckToolsSessionsCatalogue.Entry, BackendMCPCallContext, NativeRPCValue) async throws -> BackendDeckToolsSessionsOutput) throws -> [BackendDeckToolsDefinition] {
        try BackendDeckToolsSessionsCatalogue.entries.filter { $0.sourceModule == module }.map { entry in
            let spec = try entry.spec()
            return BackendDeckToolsDefinition(spec: spec, title: entry.title, index: entry.index) { context, args in
                do {
                    guard args.fields != nil else { throw bad("arguments must be an object") }
                    if context.cancellation.isCancelled { throw CancellationError() }
                    let output = try await run(entry, context, args)
                    try await runtime.recordResult(toolID: entry.id, summary: output.summary, context: context)
                    return .value(output.value)
                } catch let error as NativeRPCError {
                    return BackendMCPToolReply(content: [.object([.init("type", .string("text")), .init("text", .string(error.message))])],
                        structuredContent: object([("ok", .bool(false)), ("error", .string(error.message)), ("refusal", .string(error.code))]), isError: true)
                } catch is CancellationError { return .failure("The caller went away.") }
                catch { return .failure(error.localizedDescription) }
            }
        }
    }
    static func authorize(_ entry: BackendDeckToolsSessionsCatalogue.Entry, tier: BackendMCPTier? = nil, summary: String,
                          args: NativeRPCValue, runtime: any BackendDeckToolsSessionsRuntime, context: BackendMCPCallContext) async throws {
        try await runtime.authorize(tool: entry.spec(), tier: tier ?? entry.tier, summary: summary, arguments: args, context: context)
    }
    public static func area(id: String = "sessions", definitions: [BackendDeckToolsDefinition]) throws -> BackendDeckCoreToolArea {
        try BackendDeckToolsSupport.area(id: id, definitions: definitions)
    }
    public static func sessionDefinitions(runtime: any BackendDeckToolsSessionsRuntime, surface: any BackendDeckToolsSessionsSurface,
                                          clock: BackendDeckToolsSessionsClock = .init()) throws -> [BackendDeckToolsDefinition] {
        try definitions(module: "session-more-tools.ts", runtime: runtime) { entry, context, args in
            let sid = try Args.optStr(args, "sessionId") ?? "?"
            switch entry.id {
            case "sessions.wait":
                try await authorize(entry, summary: "Wait for session \(sid)", args: args, runtime: runtime, context: context)
                let first = try await session(Args.str(args, "sessionId"), runtime: runtime, context: context)
                let id = first["id"].string ?? "", timeout = try Args.optInt(args, "timeoutSeconds", 40, 1, 240) * 1_000, started = clock.now()
                if !args["after"].isNullish, args["after"].number == nil { throw bad("after must be a number — the `sentAt` sessions.send returned") }
                let after = args["after"].number ?? started
                var sawWorking = false, calmSince: Double?, lastTranscriptLook = -Double.infinity, outcome = "timed-out"
                while true {
                    if context.cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
                    let now = clock.now()
                    guard let meta = try await runtime.sessions(context).first(where: { $0["id"].string == id }) else { outcome = "stopped"; break }
                    if !meta["exitCode"].isNullish { outcome = "exited"; break }
                    let live = try await surface.status(sessionID: id, context: context)
                    let status = live?["status"].string ?? "idle"
                    if status == "input" { outcome = "blocked"; break }
                    if status == "working" { sawWorking = true; calmSince = nil }
                    else if sawWorking {
                        if calmSince == nil { calmSince = now }
                        if now - (calmSince ?? now) >= 1_000 { outcome = "finished"; break }
                    } else if status == "completed", let stamp = live?["at"].number, stamp > after { outcome = "finished"; break }
                    else if now - lastTranscriptLook >= 2_000 {
                        lastTranscriptLook = now
                        if let answer = try await latestAnswer(meta, runtime: runtime, surface: surface, context: context), (answer["at"].number ?? 0) > after { outcome = "finished"; break }
                    }
                    if now - started >= Double(timeout) { break }
                    try await clock.sleep(250)
                }
                let waited = clock.now() - started
                let summary = object([("sessionId", .string(id)), ("outcome", .string(outcome)), ("waitedMs", .number(waited))])
                guard let meta = try await runtime.sessions(context).first(where: { $0["id"].string == id }) else {
                    return .init(summary.setting("note", .string(outcomeNote(outcome))), summary: summary)
                }
                let answer = try await latestAnswer(meta, runtime: runtime, surface: surface, context: context)
                let screen = outcome == "blocked" || answer == nil ? try await surface.screen(sessionID: id, context: context) : nil
                let capped = Rules.capScreen(screen ?? "")
                var value = object([("sessionId", .string(id)), ("outcome", .string(outcome)), ("attention", meta["attention"]), ("attentionReason", meta["attentionReason"]),
                    ("status", meta["status"]), ("waitedMs", .number(waited)), ("answer", answer?.setting("afterSend", .bool((answer?["at"].number ?? 0) > after)) ?? .null),
                    ("screen", outcome == "blocked" || answer == nil ? .string(capped.text) : .null), ("note", .string(outcomeNote(outcome)))])
                if capped.partial { value = value.setting("screenPartial", .bool(true)) }
                return .init(value, summary: summary.setting("status", meta["status"]))
            case "sessions.keys":
                let keys = try BackendDeckToolsSessionsTyping.resolveKeys(args["keys"])
                let own = try await runtime.startedByCaller(sessionID: sid, context: context)
                try await authorize(entry, tier: own ? .act : .alter, summary: "Press \(keys.map(\.label).joined(separator: ", ")) in session \(sid)", args: args, runtime: runtime, context: context)
                let held = try await session(Args.str(args, "sessionId"), runtime: runtime, context: context), id = held["id"].string ?? ""
                if !held["exitCode"].isNullish { throw bad("session \(id) has already exited; there is nothing to press keys in") }
                let sentAt = clock.now()
                try await BackendDeckToolsSessionsTyping.pressKeys(write: { data in try await surface.write(sessionID: id, data: data, context: context) }, keys: keys, sleep: clock.sleep)
                return .init(object([("sessionId", .string(id)), ("pressed", .array(keys.map { .string($0.label) })), ("sentAt", .number(sentAt))]), summary: object([("sessionId", .string(id)), ("keys", .array(keys.map { .string($0.name) }))]))
            case "sessions.screen":
                try await authorize(entry, summary: "Read the screen of session \(sid)", args: args, runtime: runtime, context: context)
                let held = try await session(Args.str(args, "sessionId"), runtime: runtime, context: context), id = held["id"].string ?? ""
                let raw = try await surface.screen(sessionID: id, context: context), capped = Rules.capScreen(raw ?? "")
                var value = object([("sessionId", .string(id)), ("attention", held["attention"]), ("status", held["status"]), ("screen", .string(capped.text)), ("partial", .bool(capped.partial))])
                if raw == nil { value = value.setting("note", .string("This session’s screen is no longer being read; it has ended.")) }
                return .init(value, summary: object([("sessionId", .string(id)), ("chars", .number(Double(capped.text.utf16.count)))]))
            case "sessions.rename":
                let title = try Rules.title(args)
                try await authorize(entry, summary: title.isEmpty ? "Put session \(sid) back to its folder name" : "Rename session \(sid) to “\(title)”", args: args, runtime: runtime, context: context)
                let held = try await session(Args.str(args, "sessionId"), runtime: runtime, context: context), id = held["id"].string ?? ""
                guard let resolved = try await surface.rename(sessionID: id, title: title, context: context) else { throw bad("session \(id) is no longer held by this app") }
                let value = object([("sessionId", .string(id)), ("title", .string(resolved))]); return .init(value, summary: value)
            case "sessions.held":
                let action = try Args.str(args, "action")
                guard ["list", "retry", "forget"].contains(action) else { throw bad("action must be \"list\", \"retry\" or \"forget\"") }
                let key = action == "list" ? "?" : try Args.str(args, "key")
                try await authorize(entry, tier: action == "forget" ? .alter : action == "retry" ? .act : .read,
                    summary: action == "retry" ? "Try starting held session \(key) again" : action == "forget" ? "Stop holding session \(key)" : "List the sessions that did not start", args: args, runtime: runtime, context: context)
                let rows = try await surface.held(context: context)
                if action == "list" { return .init(object([("held", .array(rows)), ("count", .number(Double(rows.count)))]), summary: object([("action", .string(action)), ("count", .number(Double(rows.count)))])) }
                guard rows.contains(where: { $0["key"].string == key }) else { throw bad("nothing is being held under \(key); use action \"list\" for the keys") }
                if action == "forget" { return .init(object([("forgotten", .string(key)), ("held", .array(try await surface.forgetHeld(key: key, context: context)))]), summary: object([("action", .string(action)), ("key", .string(key))])) }
                let before = Set(try await runtime.sessions(context).compactMap { $0["id"].string })
                let after = try await surface.retryHeld(key: key, context: context), back = !after.contains { $0["key"].string == key }
                let started = try await runtime.sessions(context).filter { !before.contains($0["id"].string ?? "") }
                var value = object([("key", .string(key)), ("cameBack", .bool(back)), ("started", .array(started)), ("held", .array(after))])
                if !back { value = value.setting("reason", after.first { $0["key"].string == key }?["reason"] ?? .null) }
                return .init(value, summary: object([("action", .string(action)), ("key", .string(key)), ("cameBack", .bool(back))]))
            case "sessions.account":
                let action = try Args.str(args, "action")
                guard ["show", "plan", "switch", "later", "cancel", "armed"].contains(action) else { throw bad("action must be one of show, plan, switch, later, cancel, armed") }
                if action != "armed" { _ = try Args.str(args, "sessionId") }
                let wanted = ["plan", "switch", "later"].contains(action) ? try Args.str(args, "account") : "?"
                let summaries = ["switch":"Switch session \(sid) to \(wanted)", "later":"Switch session \(sid) to \(wanted) at its next message", "cancel":"Cancel the switch armed on session \(sid)", "plan":"Check what switching session \(sid) to \(wanted) would do", "armed":"List the account switches waiting for a message", "show":"Read which account session \(sid) runs as"]
                try await authorize(entry, tier: ["switch", "later"].contains(action) ? .alter : action == "cancel" ? .act : .read, summary: summaries[action] ?? "", args: args, runtime: runtime, context: context)
                if action == "armed" { let armed = try await surface.armedSwitches(context: context); return .init(object([("armed", .array(armed))]), summary: object([("action", .string(action)), ("count", .number(Double(armed.count)))])) }
                let held = try await session(Args.str(args, "sessionId"), runtime: runtime, context: context), id = held["id"].string ?? ""
                if action == "show" { return .init(object([("sessionId", .string(id)), ("account", try await surface.account(sessionID: id, context: context)), ("limits", try await surface.limits(sessionID: id, context: context))]), summary: object([("action", .string(action)), ("sessionId", .string(id))])) }
                if action == "cancel" { let cancelled = try await surface.cancelSwitch(sessionID: id, context: context); return .init(object([("sessionId", .string(id)), ("cancelled", .bool(cancelled))]), summary: object([("action", .string(action)), ("cancelled", .bool(cancelled))])) }
                let account = try Rules.chooseAccount(try await surface.accounts(context: context), wanted: wanted, provider: held["provider"].string), profileID = account["id"].string ?? ""
                if action == "plan" { let plan = try await surface.accountPlan(sessionID: id, profileID: profileID, context: context); return .init(object([("plan", plan)]), summary: object([("action", .string(action)), ("refused", .bool(!plan["refusal"].isNullish))])) }
                if action == "later" { return .init(try await surface.switchLater(sessionID: id, profileID: profileID, context: context), summary: object([("action", .string(action)), ("sessionId", .string(id))])) }
                let replacement = try await surface.switchAccount(sessionID: id, profileID: profileID, context: context), newID = replacement["id"].string ?? ""
                if newID == id { return .init(object([("switchedInPlace", .bool(true)), ("session", replacement)]), summary: object([("action", .string(action)), ("sessionId", .string(newID)), ("inPlace", .bool(true))])) }
                if try await runtime.startedByCaller(sessionID: id, context: context) { try await runtime.noteStarted(sessionID: newID, context: context) }
                return .init(object([("replaced", .string(id)), ("session", replacement)]), summary: object([("action", .string(action)), ("replaced", .string(id)), ("sessionId", .string(newID))]))
            case "sessions.search":
                let cwd = try await knownFolder(Args.str(args, "cwd"), runtime: runtime, context: context), query = try Args.str(args, "query")
                try await authorize(entry, summary: "Search past conversations for “\(query)”", args: args, runtime: runtime, context: context)
                var request = object([("cwd", .string(cwd)), ("query", .string(query)), ("scope", .string(try Args.optStr(args, "scope") == "all" ? "all" : "project")),
                    ("caseSensitive", .bool(try Args.optBool(args, "caseSensitive", false))), ("regex", .bool(try Args.optBool(args, "regex", false))), ("maxHits", .number(Double(try Args.optInt(args, "maxHits", 20, 1, 100))))])
                let roles = args["roles"].elements?.compactMap(\.string).filter { ["user", "assistant", "tool"].contains($0) } ?? []
                if !roles.isEmpty { request = request.setting("roles", .array(roles.map(NativeRPCValue.string))) }
                let result = try await surface.search(request: request, context: context)
                return .init(result, summary: object([("cwd", .string(cwd)), ("hits", .number(Double(result["hits"].elements?.count ?? 0)))]))
            case "chats.list", "chats.read", "chats.insights":
                let cwd = try await knownFolder(Args.str(args, "cwd"), runtime: runtime, context: context)
                let summary = entry.id == "chats.list" ? "List past conversations in \(cwd)" : entry.id == "chats.read" ? "Read a past conversation in \(cwd)" : "Read the numbers for a conversation in \(cwd)"
                try await authorize(entry, summary: summary, args: args, runtime: runtime, context: context)
                let all = try await surface.transcripts(cwd: cwd, context: context).enumerated().sorted { a, b in
                    let aTime = a.element["modifiedAt"].number ?? 0, bTime = b.element["modifiedAt"].number ?? 0
                    return aTime == bTime ? a.offset < b.offset : aTime > bTime
                }.map(\.element)
                if entry.id == "chats.list" {
                    let limit = try Args.optInt(args, "limit", 20, 1, 100)
                    let chats = all.prefix(limit).map { file in object([("transcriptPath", file["path"]), ("conversationId", file["sessionId"]), ("createdAt", file["createdAt"]), ("modifiedAt", file["modifiedAt"]), ("bytes", file["bytes"])]) }
                    return .init(object([("cwd", .string(cwd)), ("chats", .array(chats)), ("count", .number(Double(all.count))), ("more", .bool(all.count > chats.count))]), summary: object([("cwd", .string(cwd)), ("count", .number(Double(all.count)))]))
                }
                guard !all.isEmpty else { throw bad("there are no conversations recorded for \(cwd)") }
                let asked = try Args.optStr(args, "transcriptPath"), path = asked ?? all[0]["path"].string ?? ""
                guard all.contains(where: { $0["path"].string == path }) else { throw bad("\(path) is not one of the conversations in \(cwd); use chats.list for them") }
                if entry.id == "chats.insights" { return .init(object([("cwd", .string(cwd)), ("transcriptPath", .string(path)), ("insights", Rules.trimInsights(try await surface.insights(transcriptPath: path, context: context)))]), summary: object([("cwd", .string(cwd))])) }
                let limit = try Args.optInt(args, "limit", 40, 1, 200), bytes = try await surface.transcriptBytes(path: path, context: context), from = max(0, bytes - 256 * 1_024)
                let messages = try await surface.transcriptMessages(path: path, fromByte: from, context: context)
                let kept = messages.suffix(limit).map { message in
                    let text = message["text"].string ?? "", cut = text.utf16.count > 4_000
                    return message.setting("text", .string(cut ? BackendDeckToolsSupport.slice(text, 0, 4_000) + "…" : text)).setting("truncated", .bool(cut))
                }
                return .init(object([("cwd", .string(cwd)), ("transcriptPath", .string(path)), ("fileBytes", .number(Double(bytes))), ("fromByte", .number(Double(from))),
                    ("partial", .bool(from > 0 || messages.count > kept.count)), ("messages", .array(kept))]), summary: object([("cwd", .string(cwd)), ("returned", .number(Double(kept.count))), ("fileBytes", .number(Double(bytes)))]))
            default: throw BackendDeckToolsSupport.unavailable(entry.id)
            }
        }
    }
    static func latestAnswer(_ session: NativeRPCValue, runtime: any BackendDeckToolsSessionsRuntime, surface: any BackendDeckToolsSessionsSurface, context: BackendMCPCallContext) async throws -> NativeRPCValue? {
        let cwd = session["cwd"].string ?? "", files = try await surface.transcripts(cwd: cwd, context: context)
        let inFolder = try await runtime.sessions(context).filter { $0["cwd"].string == cwd }
        let match = BackendDeckToolsSessionsTranscriptMatch.match(session: session, files: files, sessionsInFolder: inFolder)
        guard let path = match["path"].string else { return nil }
        let bytes = try await surface.transcriptBytes(path: path, context: context)
        let messages = try await surface.transcriptMessages(path: path, fromByte: max(0, bytes - 256 * 1_024), context: context)
        guard let answer = messages.reversed().first(where: { $0["role"].string == "agent" && !($0["text"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        let text = (answer["text"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), cut = text.utf16.count > 4_000
        return object([("at", answer["at"]), ("text", .string(cut ? BackendDeckToolsSupport.slice(text, 0, 4_000) + "…" : text)), ("truncated", .bool(cut))])
    }
    static func outcomeNote(_ outcome: String) -> String {
        switch outcome {
        case "finished": "The session finished its turn and is back at its prompt. `answer` is the last thing it said."
        case "blocked": "The session is stopped on a question — a permission prompt, a menu or a yes/no — and will do nothing until it is answered. A menu like that is drawn on the terminal and is not in the transcript, so `screen` is what it is asking. sessions.keys presses the key it wants; sessions.send types a reply."
        case "exited": "The session’s process has ended. `answer` is the last thing it said before it did."
        case "stopped": "This app no longer holds that session — it was stopped, which drops it. Nothing more can be read from it here."
        default: "Nothing finished inside the time allowed; the session is in the state below. Waiting again is cheap and picks up from now."
        }
    }
}
