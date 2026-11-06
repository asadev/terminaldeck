import Foundation
import TerminalDeckNativeCore

/// catalogue.ts's fourteen tools, including their argument-dependent policy.
public enum BackendDeckCoreCatalogueBuiltins {
    public typealias Context = BackendDeckCoreSecurityCallContext
    public typealias Output = BackendDeckCoreSecurityToolOutput
    private typealias Rules = BackendDeckCoreCatalogueRules
    public static let providers = ["claude", "codex", "gemini", "shell"]
    public static let maxCopilotSessions = 5
    public static let defaultTranscriptLimit = 40, maxTranscriptLimit = 200
    public static let defaultWindowBytes = 262_144, maxWindowBytes = 4_194_304
    public static let maxMessageChars = 4_000, maxTranscriptChars = 65_536, maxScreenChars = 8_000

    public static func tools(surface: any BackendDeckCoreCatalogueSurface,
                             typingClock: BackendDeckCoreBriefClock = .real) throws -> BackendDeckCoreCatalogueBundle {
        let metadata = try BackendDeckCoreCatalogueLiterals.builtins()
        let policies = metadata.map { entry -> BackendDeckCoreSecurityToolPolicy in
            let id = entry.tool.id
            let needsPrecheck = ["sessions.start", "sessions.send", "git.diff", "git.status", "alerts.list", "settings.write", "log.note"].contains(id)
            let precheck: (@Sendable (NativeRPCValue, Context) throws -> Void)? = needsPrecheck ? { @Sendable (args: NativeRPCValue, context: Context) throws -> Void in
                if id == "settings.write", surface is any BackendCompositionSettingsWriting {
                    let request = try Self.checkSettingsPatch(args, caller: context.caller)
                    let checked = BackendDeckCoreCatalogueSettings.check(scope: request.scope, patch: request.patch)
                    guard checked.problems.isEmpty else { throw NativeRPCError.invalidArguments("that patch would not be accepted, so it was not put to the person: \(checked.problemSentence)") }
                    return
                }
                try Self.precheck(id: id, arguments: args, context: context, surface: surface)
            } : nil
            let asyncPrecheck: (@Sendable (NativeRPCValue, Context) async throws -> Void)? = id == "settings.write" && surface is any BackendCompositionSettingsWriting ? { @Sendable (args: NativeRPCValue, context: Context) async throws -> Void in
                _ = try await Self.prepareSettingsWriteAsync(args, surface: surface, caller: context.caller)
            } : nil
            let escalates = ["sessions.send", "sessions.stop"].contains(id)
            let escalate: (@Sendable (NativeRPCValue, Context) throws -> BackendMCPTier?)? = escalates ? { @Sendable (args: NativeRPCValue, context: Context) throws -> BackendMCPTier? in
                let session = try Rules.optionalString(args, "sessionId")
                return session.map { context.startedByCopilot($0) } == true ? .act : .alter
            } : nil
            return .init(tool: entry.tool, aliases: entry.aliases,
                summary: { args, _ in try Self.summary(id: id, arguments: args) }, precheck: precheck, precheckAsync: asyncPrecheck, escalate: escalate,
                run: { args, context in try await Self.run(id: id, arguments: args, context: context, surface: surface, typingClock: typingClock) })
        }
        return try .init(metadata: metadata, policies: policies)
    }

    public static func viewOf(surface: any BackendDeckCoreCatalogueSurface, context: Context, metadata meta: NativeRPCValue) -> NativeRPCValue {
        let id = meta["id"].string ?? ""
        let live = surface.sessionStatus(id)
        let exitCode = meta["exitCode"].number.flatMap { Int(exactly: $0) }
        let status = BackendDeckCoreAttention.status(exitCode: exitCode, live: live["status"].string, chat: meta["chat"].bool == true)
        let statusSince = live["at"].number ?? meta["createdAt"].number ?? 0
        let attentionSince = exitCode != nil && live.isNullish ? nil : statusSince
        return Rules.object([
            ("id", meta["id"]), ("cwd", meta["cwd"]), ("title", meta["title"]), ("provider", meta["provider"]),
            ("view", meta["view"]), ("kind", meta["kind"]), ("chat", meta["chat"]),
            ("seat", meta["seat"]), ("agent", meta["agent"]), ("tabKey", meta["tabKey"]), ("agentSessionId", meta["agentSessionId"]),
            ("status", .string(status)), ("statusSince", .number(statusSince))
        ]).merging(BackendDeckCoreAttention.view(status: status, statusSince: attentionSince, exitCode: exitCode, now: context.now()))
            .merging(Rules.object([
                ("createdAt", meta["createdAt"]), ("chat", meta["chat"]), ("exitCode", meta["exitCode"]), ("resumed", .bool(meta["resumed"] == .bool(true))),
                ("profileName", meta["profileName"].isNullish ? .null : meta["profileName"]),
                ("startedByCopilot", .bool(meta["origin"] != .string("app") && context.startedByCopilot(id))),
                ("startedByApp", meta["origin"] == .string("app") ? (meta["originApp"].isNullish ? .string("An AI app") : meta["originApp"]) : .null),
                ("windows", .array(surface.windows(sessionID: id).map { $0["slot"] }))
            ]))
    }
    public static func knownFolders(_ surface: any BackendDeckCoreCatalogueSurface) -> Set<String> {
        Set(surface.listProjects().compactMap { $0["path"].string } + surface.listSessions().compactMap { $0["cwd"].string } + surface.taskWorkspaceFolders())
    }
    /// `caller`: Hoot (this Mac's own caller) may open any absolute folder (Asad, 12 Oct: "Folder it can open should
    /// always be able to open all the folders"); everyone else gets the folders this app has open.
    public static func requireKnownFolder(_ surface: any BackendDeckCoreCatalogueSurface, path: String, caller: BackendDeckCoreSecurityCaller? = nil) throws -> String {
        try requireKnownFolder(path, known: knownFolders(surface), local: caller?.kind == .local)
    }
    static func requireKnownFolder(_ path: String, known: Set<String>, local: Bool) throws -> String {
        if local, path.hasPrefix("/") {
            if !known.contains(path) { try requireExistingFolder(path) }
            return path
        }
        guard known.contains(path) else { throw BackendDeckCoreSecurityRefusal(.notPermitted, "\(path) is not a folder this app has open. Use projects.list to see the folders you can ask about.") }
        return path
    }
    public static func requireExistingFolder(_ path: String) throws {
        var directory: ObjCBool = false
        guard !path.contains("\0"), FileManager.default.fileExists(atPath: path, isDirectory: &directory) else {
            throw NativeRPCError.invalidArguments("that folder doesn't exist: \(path)")
        }
        guard directory.boolValue else { throw NativeRPCError.invalidArguments("that path is not a folder: \(path)") }
    }
    public static func requireSession(surface: any BackendDeckCoreCatalogueSurface, context: Context, id: String, message: Bool = false) throws -> NativeRPCValue {
        let rows = surface.listSessions()
        guard let meta = try BackendSessionDirectory.resolve(id, rows: rows) else {
            throw NativeRPCError.invalidArguments("this app is not holding a session with id \(id). Either that is not one of its ids — check sessions.list — or the session was stopped, which drops it and everything this app knew about it. A session that exited on its own is still here, with its exit code; a stopped one is not. Ask before stopping something you will want to report on.")
        }
        guard BackendSessionDirectory.permits(meta, rows: rows, caller: context.caller, message: message) else {
            throw NativeRPCError(code: "access-denied", message: BackendSessionDirectory.accessRefusal)
        }
        return viewOf(surface: surface, context: context, metadata: meta)
    }
    public static func requireStartableFolder(surface: any BackendDeckCoreCatalogueSurface, caller: BackendDeckCoreSecurityCaller, path: String) throws -> String {
        let known = try requireKnownFolder(surface, path: path, caller: caller)
        if caller.kind == .remote {
            guard let folders = surface.deviceFolders(caller.deviceID ?? "") else {
                throw BackendDeckCoreSecurityRefusal(.notPermitted, "starting a session on behalf of a device is not available on this machine, so this was refused. Tell the person what you would have started and let them start it.")
            }
            let offered = (caller.deviceID ?? "").isEmpty ? [] : folders
            if let matching = offered.first(where: { normalizeFolder($0) == normalizeFolder(known) }) { return matching }
            throw BackendDeckCoreSecurityRefusal(.notPermitted, offered.isEmpty ?
                "this device has no folders chosen for it, so it cannot start a session anywhere. Nothing was started. Say so, and do not retry — the folders are chosen on the desktop, in Settings." :
                "this device may only start a session in: \(offered.joined(separator: ", ")). Nothing was started. Use one of those, or say what you would have needed.")
        }
        if caller.kind == .key, let folders = caller.folders, !folders.isEmpty {
            let allowed = folders.contains { folder in
                normalizeFolder(folder) == normalizeFolder(known) || known.hasPrefix(folder.hasSuffix("/") || folder.hasSuffix("\\") ? folder : folder + "/")
            }
            guard allowed else {
                throw BackendDeckCoreSecurityRefusal(.notPermitted, "the access key this app is using may only start sessions in: \(folders.joined(separator: ", ")). Nothing was started. Use one of those, or say what you would have needed — the owner chooses the folders in Settings.")
            }
        }
        return known
    }
    private static func normalizeFolder(_ raw: String) -> String { BackendRemoteServeSessionPolicy.normalizeFolder(raw) }
    public static func checkStart(surface: any BackendDeckCoreCatalogueSurface, context: Context, arguments args: NativeRPCValue) throws {
        let cwd = try requireStartableFolder(surface: surface, caller: context.caller, path: Rules.string(args, "cwd"))
        let root = surface.appStateRoot(), prefix = surface.appStateRoot().hasSuffix("/") ? root : root + "/"
        if (cwd == root || cwd.hasPrefix(prefix)) && !surface.taskWorkspaceFolders().contains(cwd) {
            throw BackendDeckCoreSecurityRefusal(.notPermitted, "\(cwd) is inside this app's own storage (\(root)). A session started there would be editing the app's state from underneath it. Start it in one of the project folders instead.")
        }
        try requireStartRoom(cwd: cwd, sessions: surface.listSessions(), startedByCaller: context.startedByCopilot)
        _ = try checkBrief(args)
        if surface.hasAsyncAccountChoices { _ = try Rules.optionalString(args, "account") }
        else { _ = try chooseAccount(surface: surface, arguments: args) }
    }
    /// All AI start tools keep the same overlapping-work and live-session limits.
    public static func requireStartRoom(cwd: String, sessions: [NativeRPCValue], startedByCaller: (String) -> Bool) throws {
        if let clash = sessions.first(where: { row in
            guard let folder = row["cwd"].string else { return false }
            return BackendAgentProjectAccess.within(cwd, folder) && BackendAgentProjectAccess.within(folder, cwd)
                && row["exitCode"] == .null && startedByCaller(row["id"].string ?? "")
        }) {
            throw BackendDeckCoreSecurityRefusal(.notPermitted, "You already have a session running in \(cwd) (\(clash["id"].string ?? "")). This guard prevents two of your agents editing the same working folder. projectId independent changes where the session is listed; it does not give it a separate folder. Use the existing session, wait for it to finish, or start the other job in a separate git worktree added through projects_add. Stop the existing session only if you mean to end its work.")
        }
        let live = sessions.filter { $0["exitCode"] == .null && startedByCaller($0["id"].string ?? "") }
        guard live.count < maxCopilotSessions else {
            throw BackendDeckCoreSecurityRefusal(.notPermitted, "You already have \(live.count) sessions running, which is the limit. Past about five, the work comes back faster than anybody can review it. Wait for one to finish, or stop one.")
        }
    }
    public static func checkBrief(_ args: NativeRPCValue) throws -> String? {
        guard let brief = try Rules.optionalString(args, "brief") else { return nil }
        let trimmed = Rules.trim(brief), count = trimmed.utf16.count
        guard count >= 40 else {
            throw NativeRPCError.invalidArguments("a brief needs at least 40 characters — say the repo, what to change, what counts as done and what not to touch. If there is genuinely nothing to scope, leave it out.")
        }
        guard count <= 8_000 else { throw NativeRPCError.invalidArguments("a brief may be at most 8000 characters; this one is \(count). Scope the work, do not describe it.") }
        guard try Rules.optionalString(args, "title") != nil else { throw NativeRPCError.invalidArguments("a brief needs a `title` of a few words — it becomes the filename.") }
        return trimmed
    }
    public static func chooseAccount(surface: any BackendDeckCoreCatalogueSurface, arguments args: NativeRPCValue) throws -> NativeRPCValue? {
        try chooseAccount(arguments: args, choices: surface.accounts())
    }
    static func chooseAccountForStart(arguments args: NativeRPCValue,
        read: @Sendable () async throws -> [NativeRPCValue]?) async throws -> NativeRPCValue? {
        guard try Rules.optionalString(args, "account") != nil else { return nil }
        return try chooseAccount(arguments: args, choices: await read())
    }
    private static func chooseAccount(arguments args: NativeRPCValue, choices: [NativeRPCValue]?) throws -> NativeRPCValue? {
        guard let wanted = try Rules.optionalString(args, "account") else { return nil }
        guard let accounts = choices else { throw NativeRPCError.invalidArguments("this app cannot choose an account for a session here; leave `account` out") }
        let exact = accounts.filter { $0["id"].string == wanted }
        let folded = Rules.trim(wanted).lowercased()
        let byName = accounts.filter { Rules.trim($0["name"].string ?? "").lowercased() == folded }
        let found = exact.count == 1 ? exact : byName
        let names = accounts.map { "\($0["name"].string ?? "") (\($0["provider"].string ?? ""))" }.joined(separator: ", ")
        guard !found.isEmpty else { throw NativeRPCError.invalidArguments("there is no account called \"\(wanted)\". The accounts are: \(names.isEmpty ? "none" : names).") }
        guard found.count == 1 else { throw NativeRPCError.invalidArguments("more than one account is called \"\(wanted)\"; name it by id instead. The accounts are: \(names).") }
        let account = found[0]
        if let provider = try Rules.optionalString(args, "provider"), provider != account["provider"].string {
            throw NativeRPCError.invalidArguments("\(account["name"].string ?? "") is a \(account["provider"].string ?? "") login, so it cannot run a \(provider) session")
        }
        return account
    }
    public static func limitsFrom(_ limits: NativeRPCValue) throws -> NativeRPCValue {
        if !limits["deniedTools"].isNullish && limits["deniedTools"].elements == nil {
            throw NativeRPCError.invalidArguments("deniedTools must be a list of tool names that can be blocked")
        }
        let raw = limits["deniedTools"].elements ?? []
        var denied: [String] = []
        for value in raw {
            guard let name = value.string, name.range(of: #"^(?:[A-Z][A-Za-z0-9]{0,63}|mcp__[A-Za-z0-9_-]{1,64}(?:__[A-Za-z0-9_-]{1,64})?)$"#, options: .regularExpression) != nil else {
                throw NativeRPCError.invalidArguments("\(Rules.jsString(value)) is not a tool name that can be blocked")
            }
            if !denied.contains(name) { denied.append(name) }
        }
        let agent = limits["agentInstructions"]
        if agent != .missing, agent.string?.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) == nil {
            throw NativeRPCError.invalidArguments("\(Rules.jsString(agent)) is not a task agent id")
        }
        var result = NativeRPCValue.object([])
        if !denied.isEmpty { result = result.setting("deniedTools", Rules.strings(denied)) }
        if limits["noSkills"] == .bool(true) { result = result.setting("noSkills", .bool(true)) }
        if agent != .missing { result = result.setting("agentInstructions", agent) }
        return result
    }
    public static func checkSettingsPatch(_ args: NativeRPCValue, caller: BackendDeckCoreSecurityCaller? = nil) throws -> (scope: String, patch: NativeRPCValue, keys: [String]) {
        let scope = try Rules.string(args, "scope")
        guard ["settings", "preferences"].contains(scope) else { throw NativeRPCError.invalidArguments("scope must be \"settings\" or \"preferences\"") }
        let patch = try Rules.record(args, "patch"), keys = patch.fields!.map(\.key)
        guard !keys.isEmpty else { throw NativeRPCError.invalidArguments("patch must name at least one key") }
        if scope == "settings" {
            let blocked = keys.filter { Rules.isProtectedSetting($0, for: caller) }
            guard blocked.isEmpty else { throw BackendDeckCoreSecurityRefusal(.notPermitted, (Rules.isHoot(caller) ? "these are Hoot's own settings, which only the person changes: " : "these settings cannot be changed through Hoot: ") + "\(blocked.joined(separator: ", ")). Ask the person to change them in Settings if they want them changed.") }
        } else {
            let unknown = keys.filter { !Rules.writablePreferences.contains($0) }
            guard unknown.isEmpty else { throw BackendDeckCoreSecurityRefusal(.notPermitted, "preferences has no writable key called \(unknown.joined(separator: ", ")). Writable preferences are: \(Rules.writablePreferences.joined(separator: ", ")).") }
        }
        return (scope, patch, keys)
    }
    public static func prepareSettingsWrite(_ args: NativeRPCValue, surface: any BackendDeckCoreCatalogueSurface, caller: BackendDeckCoreSecurityCaller? = nil) throws -> (scope: String, patch: NativeRPCValue, keys: [String], snapshot: String) {
        let checked = try checkSettingsPatch(args, caller: caller)
        let values = BackendDeckCoreCatalogueSettings.check(scope: checked.scope, patch: checked.patch)
        guard values.problems.isEmpty else { throw NativeRPCError.invalidArguments("that patch would not be accepted, so it was not put to the person: \(values.problemSentence)") }
        let snapshot: NativeRPCValue
        do { snapshot = try surface.snapshotSettings() }
        catch { throw NativeRPCError(code: "internal", message: "could not save a copy of the current settings first, so nothing was changed: \(error.localizedDescription)") }
        guard let path = snapshot["path"].string else { throw NativeRPCError(code: "internal", message: "could not save a copy of the current settings first, so nothing was changed: the snapshot writer returned no path") }
        return (checked.scope, checked.patch, checked.keys, path)
    }
    public static func precheck(id: String, arguments args: NativeRPCValue, context: Context, surface: any BackendDeckCoreCatalogueSurface) throws {
        switch id {
        case "sessions.start": try checkStart(surface: surface, context: context, arguments: args)
        case "sessions.send": _ = try Rules.sanitizeSendText(Rules.string(args, "text"))
        case "git.diff", "git.status": _ = try requireKnownFolder(surface, path: Rules.string(args, "cwd"), caller: context.caller)
        case "alerts.list": _ = try requireKnownFolder(surface, path: Rules.string(args, "projectPath"), caller: context.caller)
        case "settings.write": _ = try prepareSettingsWrite(args, surface: surface, caller: context.caller)
        case "log.note": _ = try Rules.sanitizeNote(Rules.string(args, "note"))
        default: break
        }
    }
    public static func prepareSettingsWriteAsync(_ args: NativeRPCValue, surface: any BackendDeckCoreCatalogueSurface, caller: BackendDeckCoreSecurityCaller? = nil) async throws -> (scope: String, patch: NativeRPCValue, keys: [String], snapshot: String) {
        guard let writer = surface as? any BackendCompositionSettingsWriting else { return try prepareSettingsWrite(args, surface: surface, caller: caller) }
        let checked = try checkSettingsPatch(args, caller: caller)
        let values = BackendDeckCoreCatalogueSettings.check(scope: checked.scope, patch: checked.patch)
        guard values.problems.isEmpty else { throw NativeRPCError.invalidArguments("that patch would not be accepted, so it was not put to the person: \(values.problemSentence)") }
        let snapshot: NativeRPCValue
        do { snapshot = try await writer.snapshotSettingsAsync() }
        catch { throw NativeRPCError(code: "internal", message: "could not save a copy of the current settings first, so nothing was changed: \(error.localizedDescription)") }
        guard let path = snapshot["path"].string else { throw NativeRPCError(code: "internal", message: "could not save a copy of the current settings first, so nothing was changed: the snapshot writer returned no path") }
        return (checked.scope, checked.patch, checked.keys, path)
    }
    public static func summary(id: String, arguments args: NativeRPCValue) throws -> String {
        switch id {
        case "sessions.list": return "List the running sessions"
        case "sessions.get": return "Read session \(try Rules.optionalString(args, "sessionId") ?? "?")"
        case "sessions.transcript": return "Read the transcript of session \(try Rules.optionalString(args, "sessionId") ?? "?")"
        case "sessions.start":
            let whereAt = try Rules.optionalString(args, "cwd") ?? "?", what = try Rules.optionalString(args, "title"), account = try Rules.optionalString(args, "account")
            let kind = "\(try Rules.optionalString(args, "provider") ?? "default") session" + (account.map { " as " + $0 } ?? "")
            return "Start a \(kind) in \(whereAt)" + (what.map { " to " + $0 } ?? "")
        case "sessions.send":
            let text = try Rules.optionalString(args, "text") ?? "", shown = text.utf16.count > 120 ? Rules.prefix(text, 120) + "…" : text
            return "Type into session \(try Rules.optionalString(args, "sessionId") ?? "?"): “\(shown)”"
        case "sessions.stop": return "Stop session \(try Rules.optionalString(args, "sessionId") ?? "?")"
        case "projects.list": return "List the open projects"
        case "sessions.result": return try Rules.optionalString(args, "sessionId").map { "Report on session " + $0 } ?? "Report on every session"
        case "git.diff":
            let path = try Rules.optionalString(args, "path"), cwd = try Rules.optionalString(args, "cwd") ?? "?"
            return path.map { "Read the diff of \($0) in \(cwd)" } ?? "Read the diff in \(cwd)"
        case "git.status": return "Read git status for \(try Rules.optionalString(args, "cwd") ?? "?")"
        case "alerts.list": return "Read alerts for \(try Rules.optionalString(args, "projectPath") ?? "?")"
        case "settings.read": return "Read the app settings"
        case "settings.write":
            let scope = try Rules.optionalString(args, "scope") ?? "?", patch = args["patch"], keys = (patch.fields ?? []).map(\.key)
            if keys.isEmpty { return "Change \(scope): (nothing)" }
            if !["settings", "preferences"].contains(scope) { return "Change \(scope): \(keys.joined(separator: ", "))" }
            let checked = BackendDeckCoreCatalogueSettings.check(scope: scope, patch: patch)
            if !checked.problems.isEmpty { return "Change \(scope): \(keys.joined(separator: ", "))" }
            let parts = keys.map { key -> String in
                if !checked.effective.has(key) { return "\(key) back to its default" }
                let written = checked.effective[key].compact
                return checked.adjusted.contains(key) ? "\(key) to \(written) (asked for \(patch[key].compact))" : "\(key) to \(written)"
            }
            return "Change \(scope): \(parts.joined(separator: ", "))"
        case "log.note": return "Noted: \"\(try Rules.sanitizeNote(Rules.string(args, "note")))\""
        default: throw NativeRPCError.invalidArguments("no tool called \(id)")
        }
    }

    public static func run(id: String, arguments args: NativeRPCValue, context: Context, surface: any BackendDeckCoreCatalogueSurface,
                           typingClock: BackendDeckCoreBriefClock = .real) async throws -> Output {
        switch id {
        case "sessions.list":
            let cwd = try Rules.optionalString(args, "cwd")
            let rows = surface.listSessions()
            let sessions = rows.filter { (cwd == nil || $0["cwd"].string == cwd) && BackendSessionDirectory.permits($0, rows: rows, caller: context.caller, directory: true) }.map { viewOf(surface: surface, context: context, metadata: $0) }.sorted(by: BackendDeckCoreAttention.precedes)
            let blocked = sessions.filter { $0["attention"] == .string("blocked") }.count
            let summary = Rules.object([("count", .number(Double(sessions.count))), ("blocked", .number(Double(blocked)))])
            return .init(value: NativeRPCValue.object([.init("sessions", .array(sessions))]).merging(summary), summary: summary)
        case "sessions.get":
            let session = try requireSession(surface: surface, context: context, id: Rules.string(args, "sessionId"))
            let record = await surface.agentRecord(session: session, windowBytes: 0)
            let match: NativeRPCValue
            if let record { match = record.match } else { match = try await surface.transcriptFor(session: session) }
            let bytes: Double
            if let record { bytes = record.bytes }
            else if let path = match["path"].string, !path.isEmpty { bytes = try await surface.transcriptBytes(path: path) } else { bytes = 0 }
            var value = Rules.object([
                ("session", session), ("windows", .array(surface.windows(sessionID: session["id"].string ?? "").map { $0["description"] })),
                ("transcriptPath", match["path"]), ("transcriptBytes", .number(bytes)), ("transcriptBasis", match["basis"]),
                ("transcriptAmbiguous", match["ambiguous"]), ("otherSessionsInFolder", match["otherSessions"])
            ])
            if match["note"] != .null { value = value.setting("transcriptNote", match["note"]) }
            return .init(value: value, summary: Rules.object([("sessionId", session["id"]), ("status", session["status"]), ("basis", match["basis"])]))
        case "sessions.transcript": return try await transcript(args: args, context: context, surface: surface)
        case "sessions.start":
            return try await surface.withSessionStartContext(context) {
                try await start(args: args, context: context, surface: surface)
            }
        case "sessions.send":
            let session = try requireSession(surface: surface, context: context, id: Rules.string(args, "sessionId"), message: true)
            let text = try Rules.sanitizeSendText(Rules.string(args, "text")), submit = try Rules.optionalBool(args, "submit", fallback: true)
            guard session["exitCode"] == .null else { throw NativeRPCError.invalidArguments("session \(session["id"].string ?? "") has already exited; there is nothing to type into") }
            let sentAt = context.now(), sessionID = session["id"].string ?? ""
            if session["chat"].bool == true {
                guard submit else { throw NativeRPCError.invalidArguments("Chat messages must be submitted together. Use sessions_chat with do: draft to edit a draft.") }
                try await surface.sendChat(sessionID, text: text)
            } else {
                try await BackendDeckCoreTyping.typeLine(write: { data in try await surface.writeToSession(sessionID, data: data) }, text: text, submit: submit, clock: typingClock)
            }
            noteTyped(sessionID: sessionID, text: text, caller: context.caller)
            return .init(value: Rules.object([("sessionId", session["id"]), ("sent", .number(Double(text.utf16.count))), ("submitted", .bool(submit)), ("sentAt", .number(sentAt))]),
                summary: Rules.object([("sessionId", session["id"]), ("chars", .number(Double(text.utf16.count))), ("submitted", .bool(submit)), ("text", .string(text))]))
        case "sessions.stop":
            let session = try requireSession(surface: surface, context: context, id: Rules.string(args, "sessionId"))
            try await surface.killSession(session["id"].string ?? "")
            return .init(value: Rules.object([("sessionId", session["id"]), ("stopped", .bool(true))]), summary: Rules.object([("sessionId", session["id"]), ("cwd", session["cwd"])]))
        case "projects.list":
            let projects = surface.listProjects(), count = NativeRPCValue.number(Double(projects.count))
            return .init(value: Rules.object([("projects", .array(projects)), ("count", count)]), summary: .object([.init("count", count)]))
        case "sessions.result":
            if let id = try Rules.optionalString(args, "sessionId") {
                let session = try requireSession(surface: surface, context: context, id: id)
                let report = try await surface.reportOnSession(session: session)
                return .init(value: report, summary: Rules.object([("sessionId", report["sessionId"]), ("attention", report["attention"]), ("progress", report["progress"]["verdict"])]))
            }
            let minutes = try Rules.optionalInt(args, "sinceMinutes", fallback: 0, min: 0, max: 43_200)
            let rows = surface.listSessions()
            let sessions = rows.filter { BackendSessionDirectory.permits($0, rows: rows, caller: context.caller) }.map { viewOf(surface: surface, context: context, metadata: $0) }.sorted(by: BackendDeckCoreAttention.precedes)
            let fleet = try await surface.reportOnFleet(sessions: sessions, since: minutes == 0 ? nil : context.now() - Double(minutes) * 60_000,
                limit: Rules.optionalInt(args, "limit", fallback: 8, min: 1, max: 25), now: context.now())
            return .init(value: fleet, summary: Rules.object([("sessions", fleet["totals"]["sessions"]), ("blocked", fleet["totals"]["blocked"]), ("looping", fleet["totals"]["looping"]), ("failed", fleet["totals"]["failed"])]))
        case "git.diff":
            let cwd = try requireKnownFolder(surface, path: Rules.string(args, "cwd"), caller: context.caller)
            let rows = surface.listSessions()
            let sessions = rows.filter { BackendSessionDirectory.permits($0, rows: rows, caller: context.caller) }.map { viewOf(surface: surface, context: context, metadata: $0) }
            let diff = try await surface.collectFolderDiff(sessions: sessions, cwd: cwd, path: Rules.optionalString(args, "path"), maxFiles: Rules.optionalInt(args, "maxFiles", fallback: 25, min: 1, max: 100))
            return .init(value: diff, summary: Rules.object([("cwd", .string(cwd)), ("files", diff["changedFiles"]), ("withDiff", diff["withDiff"]), ("bound", diff["bound"])]))
        case "git.status":
            let cwd = try requireKnownFolder(surface, path: Rules.string(args, "cwd"), caller: context.caller), status = try await surface.gitStatus(cwd: cwd)
            return .init(value: status, summary: Rules.object([("cwd", .string(cwd)), ("repo", .bool(status.fields != nil && status["repo"] == .bool(true)))]))
        case "alerts.list":
            let path = try requireKnownFolder(surface, path: Rules.string(args, "projectPath"), caller: context.caller), report = try await surface.alerts(projectPath: path)
            return .init(value: report, summary: Rules.object([("projectPath", .string(path)), ("alerts", .number(Double(report["alerts"].elements?.count ?? 0)))]))
        case "settings.read":
            let stores = surface.readSettings(), settings = stores["settings"], preferences = stores["preferences"]
            return .init(value: Rules.object([("settings", settings), ("preferences", preferences),
                ("writablePreferences", Rules.strings(Rules.writablePreferences)),
                ("protectedSettingKeys", Rules.strings(Rules.isHoot(context.caller) ? [] : Rules.protectedKeys)),
                ("protectedSettingPrefixes", Rules.strings(Rules.isHoot(context.caller) ? Rules.hootOwnPrefixes : Rules.protectedPrefixes))]), summary: .object([.init("keys", .number(Double(settings.fields?.count ?? 0)))]))
        case "settings.write":
            let request = try await prepareSettingsWriteAsync(args, surface: surface, caller: context.caller)
            let values: NativeRPCValue
            if let writer = surface as? any BackendCompositionSettingsWriting {
                values = request.scope == "settings" ? try await writer.writeSettingsAsync(request.patch) : try await writer.writePreferencesAsync(request.patch)
            } else if request.scope == "settings" { values = try surface.writeSettings(request.patch) }
            else { values = try surface.writePreferences(request.patch) }
            let applied = surface.applyToWindow(scope: request.scope, values: values)
            let said = applied ? "in-the-open-window: the value is saved, and the window that is already open was handed the new value and redrew with it. It is on screen now." : "not-yet-in-the-open-window: the value is saved and every launch from now on reads it, but no open window took it — there is none to tell. It appears when the app is next started."
            return .init(value: Rules.object([("scope", .string(request.scope)), (request.scope, values), ("snapshot", .string(request.snapshot)), ("appliedToWindow", .string(said))]),
                summary: Rules.object([("scope", .string(request.scope)), ("keys", Rules.strings(request.keys)), ("snapshot", .string(request.snapshot)), ("appliedToWindow", .bool(applied))]))
        case "log.note":
            let note = try Rules.sanitizeNote(Rules.string(args, "note"))
            // The central gate's row is the write. A second append would forge a duplicate event.
            return .init(value: Rules.object([("recorded", .bool(true)), ("note", .string(note)), ("where", .string("the action log; this app wrote the row, attributed to you"))]), summary: .object([.init("chars", .number(Double(note.utf16.count)))]))
        default: throw NativeRPCError.invalidArguments("no tool called \(id)")
        }
    }
    public static func fitTail(_ messages: [NativeRPCValue], limit: Int) -> (kept: [NativeRPCValue], dropped: Int) {
        var kept: [NativeRPCValue] = [], chars = 0
        for message in messages.reversed() {
            guard kept.count < limit else { break }
            let raw = message["text"].string ?? "", capped = raw.utf16.count > maxMessageChars
            let text = capped ? Rules.prefix(raw, maxMessageChars) + "…" : raw
            if chars + text.utf16.count > maxTranscriptChars && !kept.isEmpty { break }
            chars += text.utf16.count
            kept.append(message.setting("text", .string(text)).setting("truncated", .bool(capped)))
        }
        return (Array(kept.reversed()), messages.count - kept.count)
    }
    private static func transcript(args: NativeRPCValue, context: Context, surface: any BackendDeckCoreCatalogueSurface) async throws -> Output {
        let session = try requireSession(surface: surface, context: context, id: Rules.string(args, "sessionId"))
        let limit = try Rules.optionalInt(args, "limit", fallback: defaultTranscriptLimit, min: 1, max: maxTranscriptLimit)
        let windowBytes = try Rules.optionalInt(args, "windowBytes", fallback: defaultWindowBytes, min: 4096, max: maxWindowBytes)
        let record = await surface.agentRecord(session: session, windowBytes: windowBytes)
        let match: NativeRPCValue
        if let record { match = record.match } else { match = try await surface.transcriptFor(session: session) }
        guard let path = match["path"].string else {
            let screen = try await surface.sessionScreen(session["id"].string ?? "") ?? ""
            let text = screen.utf16.count > maxScreenChars ? Rules.suffix(screen, maxScreenChars) : screen
            let source = screen.isEmpty ? "none" : "terminal"
            return .init(value: Rules.object([("sessionId", session["id"]), ("cwd", session["cwd"]), ("source", .string(source)), ("transcriptPath", .null),
                ("partial", .bool(screen.utf16.count > text.utf16.count)), ("messages", .array([])), ("screen", .string(text))]),
                summary: Rules.object([("source", .string(source)), ("chars", .number(Double(text.utf16.count)))]))
        }
        let bytes: Double, fromByte: Double, parsed: [NativeRPCValue]
        if let record { bytes = record.bytes; fromByte = record.fromByte; parsed = record.messages }
        else {
            bytes = try await surface.transcriptBytes(path: path); fromByte = Swift.max(0, bytes - Double(windowBytes))
            parsed = try await surface.readTranscriptFrom(path: path, fromByte: fromByte)
        }
        let tail = fitTail(parsed, limit: limit)
        return .init(value: Rules.object([("sessionId", session["id"]), ("cwd", session["cwd"]), ("source", .string("chat")), ("transcriptPath", .string(path)),
            ("fileBytes", .number(bytes)), ("fromByte", .number(fromByte)), ("partial", .bool(fromByte > 0 || tail.dropped > 0)),
            ("inWindow", .number(Double(parsed.count))), ("returned", .number(Double(tail.kept.count))), ("messages", .array(tail.kept))]),
            summary: Rules.object([("source", .string("chat")), ("fileBytes", .number(bytes)), ("fromByte", .number(fromByte)), ("returned", .number(Double(tail.kept.count))), ("inWindow", .number(Double(parsed.count)))]))
    }
    public static let startBriefBudgetSeconds: Double = 60
    /// Deck Memory: words this app's assistant (or a lead's or agent's session) typed into a session are
    /// theirs in the diary, never the person's. An outside AI app is left to the capture's own rule.
    private static func noteTyped(sessionID: String, text: String, caller: BackendDeckCoreSecurityCaller) {
        guard caller.kind != .key, !sessionID.isEmpty else { return }
        var author = DeckMemoryAuthor.orchestrator
        if caller.kind == .session, let id = caller.sessionID, let holder = DeckMemorySessionCenter.shared?.owner(sessionID: id) {
            author = holder.kind == .lead ? .lead : .agent
        }
        DeckMemoryFlowInbox.typed(sessionID: sessionID, text: text, by: author)
    }
    private static func start(args: NativeRPCValue, context: Context, surface: any BackendDeckCoreCatalogueSurface) async throws -> Output {
        // Repeat the refusal rules when reached without a precheck.
        try checkStart(surface: surface, context: context, arguments: args)
        let cwd = try requireStartableFolder(surface: surface, caller: context.caller, path: Rules.string(args, "cwd"))
        let brief = try checkBrief(args), account = try await chooseAccountForStart(arguments: args, read: { try await surface.accountsForSessionStart() })
        let asked = try Rules.optionalString(args, "provider")
        if let asked, !providers.contains(asked) { throw NativeRPCError.invalidArguments("provider must be one of \(providers.joined(separator: ", "))") }
        var provider = asked ?? account?["provider"].string
        // Deck Memory: the playbook fills in what this app's own assistant left out (AI, model, effort,
        // permission, standing instructions). It can differ, with a reason. An outside AI app is left alone.
        var playbook: BackendPlaybookChoice?
        // One small argument for the rare start that differs from the playbook, so the always-listed tool stays cheap.
        let differ = args["differ"]
        if !differ.isNullish {
            guard differ.fields != nil, Set(differ.fields?.map(\.key) ?? []).isSubset(of: ["model", "effort", "permission", "instructions", "reason"]) else {
                throw NativeRPCError.invalidArguments("differ takes model, effort, permission, instructions and reason")
            }
        }
        let wanted = BackendPlaybookFill.Asked(provider: provider, model: try Rules.optionalString(differ, "model"),
            effort: try Rules.optionalString(differ, "effort"), permission: try Rules.optionalString(differ, "permission"),
            instructions: try Rules.optionalString(differ, "instructions"), reason: try Rules.optionalString(differ, "reason"))
        let choosing = wanted.model != nil || wanted.effort != nil || wanted.permission != nil || wanted.instructions != nil
        if context.caller.kind == .key || provider == "shell" {
            guard !choosing else {
                throw NativeRPCError.invalidArguments("differ belongs to this app's own playbook and cannot be used for this start; leave it out")
            }
        } else {
            let job = try Rules.optionalString(args, "job") ?? Rules.optionalString(args, "title") ?? ""
            // Hoot's playbook; a lead's own when a lead's session is the caller (it falls back to Hoot's row).
            var seat = DeckMemoryOwner.hoot
            if context.caller.kind == .session, let id = context.caller.sessionID,
               let holder = DeckMemorySessionCenter.shared?.owner(sessionID: id), holder.kind == .lead,
               let lead = BackendAGTMemoryOwners.memoryOwner(holder) { seat = lead }
            let row = await BackendPlaybookFill.row(owner: seat, job: job)
            if row != nil || choosing {
                let choice = try BackendPlaybookFill.resolve(row: row, asked: wanted,
                    fallbackProvider: surface.readSettings()["preferences"]["defaultProvider"].string ?? "claude")
                if !choice.isEmpty { playbook = choice }
                provider = choice.provider
            }
        }
        let conversation = try Rules.optionalString(args, "conversation")
        if let conversation, conversation.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) == nil {
            throw NativeRPCError.invalidArguments("conversation must be a conversation id")
        }
        var input = Rules.object([("cwd", .string(cwd)), ("cols", .number(120)), ("rows", .number(30)),
            ("resume", .bool(try Rules.optionalBool(args, "resume", fallback: false) || conversation != nil))])
        if let conversation { input = input.setting("resumeConversationId", .string(conversation)) }
        if let provider { input = input.setting("provider", .string(provider)) }
        // Chat or terminal (Asad, 13 Oct). Left out: the app's default, a chat (BackendSessionLifecycleCoordinator.startsAsChat).
        if let mode = try Rules.optionalString(args, "mode") {
            guard ["chat", "terminal"].contains(mode) else { throw NativeRPCError.invalidArguments("mode must be chat or terminal") }
            input = input.setting("chat", .bool(mode == "chat"))
        }
        if let projectId = try Rules.optionalString(args, "projectId") { input = input.setting("projectId", .string(projectId)) }
        if let account { input = input.setting("profileId", account["id"]) }
        if let playbook {
            if let model = playbook.model { input = input.setting("model", .string(model)) }
            if let effort = playbook.effort { input = input.setting("effort", .string(effort)) }
            if let mode = playbook.permissionMode { input = input.setting("permissionMode", .string(mode)) }
        }
        input = input.merging(try limitsFrom(context.sessionLimits)).merging(context.caller.sessionOrigin).setting("originRunId", .string(context.callID))
        if let title = try Rules.optionalString(args, "title") { input = input.setting("title", .string(title)) }
        var spec: NativeRPCValue?
        if let brief {
            spec = try surface.writeSpec(directory: BackendDeckCoreBrief.specsDirectory(copilotRoot: URL(fileURLWithPath: surface.copilotRoot())).path, input: Rules.object([
                ("title", .string(try Rules.optionalString(args, "title") ?? "brief")),
                ("brief", .string(context.caller.kind != .key && DeckMemory.isReady ? BackendPlaybookFill.brief(brief, choice: playbook ?? .init()) : brief)), ("cwd", .string(cwd)),
                ("provider", provider.map(NativeRPCValue.string) ?? .null), ("callId", .string(context.callID)), ("at", .number(context.now()))
            ]))
            guard spec?["path"].string != nil else { throw NativeRPCError(code: "internal", message: "The brief writer returned no path, so no session was started.") }
        }
        let meta = try await surface.startSession(input: input, forDevice: context.caller.kind == .remote ? (context.caller.deviceID ?? "") : nil)
        let sessionID = try meta["id"].requireString("started session id", nonempty: true)
        context.noteStarted(sessionID)
        let session = viewOf(surface: surface, context: context, metadata: meta)
        var summary = Rules.object([("sessionId", meta["id"]), ("cwd", meta["cwd"]), ("provider", meta["provider"])])
        // What the playbook supplied (and where this start differs from it) goes back with the handle and into the log.
        let used: NativeRPCValue = playbook?.wireValue ?? .null
        if let playbook {
            summary = summary.setting("playbook", .string(playbook.jobKind.isEmpty ? "none" : playbook.jobKind))
            if let model = playbook.model { summary = summary.setting("model", .string(model)) }
            if let reason = playbook.reason { summary = summary.setting("reason", .string(reason)) }
        }
        func answer(_ spec: NativeRPCValue) -> NativeRPCValue {
            let value = Rules.object([("session", session), ("spec", spec)])
            return playbook == nil ? value : value.setting("playbook", used)
        }
        guard let spec, let path = spec["path"].string else { return .init(value: answer(.null), summary: summary) }
        let line = BackendDeckCoreBrief.deliveryLine(path)
        // L8 (10 Oct): a CLI that is slow to show its prompt must not hold this call past the AI app's
        // ~120 s give-up. After `startBriefBudgetSeconds` the session handle comes back now and the brief
        // keeps being delivered in the background (same rules, same 120 s limit).
        let typist = context.caller
        let attempt = Task {
            let delivery = try await surface.deliverBrief(sessionID, line: line)
            // Typed and sent is typed, seen on screen or not (11 Oct: "sent" until seen, "delivered" only when seen).
            if delivery["delivered"] == .bool(true) || delivery["sent"] == .bool(true) { noteTyped(sessionID: sessionID, text: line, caller: typist) }
            return delivery
        }
        guard let settled = await BackendMCPCallBudget.within(startBriefBudgetSeconds, { await attempt.result }) else {
            summary = summary.setting("spec", .string(path)).setting("delivered", .string("pending"))
            return .init(value: answer(Rules.object([("path", .string(path)), ("delivered", .bool(false)), ("pending", .bool(true)),
                ("nextStep", .string("The session started and its brief is still being typed in once its prompt is ready (this goes on in the background). Check with sessions_get or sessions_wait; if it never arrives, send it \"\(line)\" with sessions.send."))])), summary: summary)
        }
        // #110: the session is already running. A delivery error must not hide its handle, or the caller
        // starts a second (paid) session and the first sits idle with no one knowing its id.
        let delivery: NativeRPCValue
        switch settled {
        case .success(let value): delivery = value
        case .failure(let error):
            delivery = Rules.object([("delivered", .bool(false)), ("sent", .bool(false)),
                ("reason", .string("Typing its brief failed: " + ((error as? NativeRPCError)?.message ?? error.localizedDescription)))])
        }
        let delivered = delivery["delivered"] == .bool(true), sent = delivered || delivery["sent"] == .bool(true)
        let nextStep: NativeRPCValue = delivered ? .null : sent ? .string("The brief was sent, but it was not seen on the session's screen, so it is not confirmed delivered. Check with sessions_get or sessions_wait whether the session is working on it. Send it \"\(line)\" with sessions.send only if the session sits idle at an empty prompt; do not send it twice blindly.") : .string("The session is running but has not been told anything. \(delivery["reason"].isNullish ? "null" : Rules.jsString(delivery["reason"])) Send it \"\(line)\" with sessions.send once its prompt is up, or tell the person.")
        summary = summary.setting("spec", .string(path)).setting("delivered", .bool(delivered)).setting("sent", .bool(sent))
        return .init(value: answer(Rules.object([("path", .string(path)), ("delivered", .bool(delivered)), ("sent", .bool(sent)),
            ("waitedMs", delivery["waitedMs"]), ("nextStep", nextStep)])), summary: summary)
    }
}
