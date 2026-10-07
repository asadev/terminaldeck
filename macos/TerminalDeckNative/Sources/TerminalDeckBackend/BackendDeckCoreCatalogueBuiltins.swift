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
                    let request = try Self.checkSettingsPatch(args)
                    let checked = BackendDeckCoreCatalogueSettings.check(scope: request.scope, patch: request.patch)
                    guard checked.problems.isEmpty else { throw NativeRPCError.invalidArguments("that patch would not be accepted, so it was not put to the person: \(checked.problemSentence)") }
                    return
                }
                try Self.precheck(id: id, arguments: args, context: context, surface: surface)
            } : nil
            let asyncPrecheck: (@Sendable (NativeRPCValue, Context) async throws -> Void)? = id == "settings.write" && surface is any BackendCompositionSettingsWriting ? { @Sendable (args: NativeRPCValue, _: Context) async throws -> Void in
                _ = try await Self.prepareSettingsWriteAsync(args, surface: surface)
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
        let status = BackendDeckCoreAttention.status(exitCode: exitCode, live: live["status"].string)
        let statusSince = live["at"].number ?? meta["createdAt"].number ?? 0
        let attentionSince = exitCode != nil && live.isNullish ? nil : statusSince
        return Rules.object([
            ("id", meta["id"]), ("cwd", meta["cwd"]), ("title", meta["title"]), ("provider", meta["provider"]),
            ("status", .string(status)), ("statusSince", .number(statusSince))
        ]).merging(BackendDeckCoreAttention.view(status: status, statusSince: attentionSince, exitCode: exitCode, now: context.now()))
            .merging(Rules.object([
                ("createdAt", meta["createdAt"]), ("exitCode", meta["exitCode"]), ("resumed", .bool(meta["resumed"] == .bool(true))),
                ("profileName", meta["profileName"].isNullish ? .null : meta["profileName"]),
                ("startedByCopilot", .bool(meta["origin"] != .string("app") && context.startedByCopilot(id))),
                ("startedByApp", meta["origin"] == .string("app") ? (meta["originApp"].isNullish ? .string("An AI app") : meta["originApp"]) : .null),
                ("windows", .array(surface.windows(sessionID: id).map { $0["slot"] }))
            ]))
    }
    public static func knownFolders(_ surface: any BackendDeckCoreCatalogueSurface) -> Set<String> {
        Set(surface.listProjects().compactMap { $0["path"].string } + surface.listSessions().compactMap { $0["cwd"].string } + surface.taskWorkspaceFolders())
    }
    public static func requireKnownFolder(_ surface: any BackendDeckCoreCatalogueSurface, path: String) throws -> String {
        guard knownFolders(surface).contains(path) else {
            throw BackendDeckCoreSecurityRefusal(.notPermitted, "\(path) is not a folder this app has open. Use projects.list to see the folders you can ask about.")
        }
        return path
    }
    public static func requireSession(surface: any BackendDeckCoreCatalogueSurface, context: Context, id: String) throws -> NativeRPCValue {
        guard let meta = surface.listSessions().first(where: { $0["id"].string == id }) else {
            throw NativeRPCError.invalidArguments("this app is not holding a session with id \(id). Either that is not one of its ids — check sessions.list — or the session was stopped, which drops it and everything this app knew about it. A session that exited on its own is still here, with its exit code; a stopped one is not. Ask before stopping something you will want to report on.")
        }
        return viewOf(surface: surface, context: context, metadata: meta)
    }
    public static func requireStartableFolder(surface: any BackendDeckCoreCatalogueSurface, caller: BackendDeckCoreSecurityCaller, path: String) throws -> String {
        let known = try requireKnownFolder(surface, path: path)
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
    private static func normalizeFolder(_ raw: String) -> String {
        let absolute = raw.hasPrefix("/")
        var parts: [String] = []
        for part in raw.split(separator: "/").map(String.init) {
            if part == "." { continue }
            if part == ".." {
                if let last = parts.last, last != ".." { parts.removeLast() }
                else if !absolute { parts.append(part) }
            } else { parts.append(part) }
        }
        let value = (absolute ? "/" : "") + parts.joined(separator: "/")
        return value.isEmpty ? "." : value
    }
    public static func checkStart(surface: any BackendDeckCoreCatalogueSurface, context: Context, arguments args: NativeRPCValue) throws {
        let cwd = try requireStartableFolder(surface: surface, caller: context.caller, path: Rules.string(args, "cwd"))
        let root = surface.appStateRoot(), prefix = surface.appStateRoot().hasSuffix("/") ? root : root + "/"
        if (cwd == root || cwd.hasPrefix(prefix)) && !surface.taskWorkspaceFolders().contains(cwd) {
            throw BackendDeckCoreSecurityRefusal(.notPermitted, "\(cwd) is inside this app's own storage (\(root)). A session started there would be editing the app's state from underneath it. Start it in one of the project folders instead.")
        }
        let sessions = surface.listSessions()
        if let clash = sessions.first(where: { $0["cwd"].string == cwd && $0["exitCode"] == .null && context.startedByCopilot($0["id"].string ?? "") }) {
            throw BackendDeckCoreSecurityRefusal(.notPermitted, "You already have a session running in \(cwd) (\(clash["id"].string ?? "")). Two agents in one working tree overwrite each other's edits and nothing can tell afterwards which one made which change. Use that session, or stop it first.")
        }
        let live = sessions.filter { $0["exitCode"] == .null && context.startedByCopilot($0["id"].string ?? "") }
        guard live.count < maxCopilotSessions else {
            throw BackendDeckCoreSecurityRefusal(.notPermitted, "You already have \(live.count) sessions running, which is the limit. Past about five, the work comes back faster than anybody can review it. Wait for one to finish, or stop one.")
        }
        _ = try checkBrief(args)
        _ = try chooseAccount(surface: surface, arguments: args)
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
        guard let wanted = try Rules.optionalString(args, "account") else { return nil }
        guard let accounts = surface.accounts() else { throw NativeRPCError.invalidArguments("this app cannot choose an account for a session here; leave `account` out") }
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
    public static func checkSettingsPatch(_ args: NativeRPCValue) throws -> (scope: String, patch: NativeRPCValue, keys: [String]) {
        let scope = try Rules.string(args, "scope")
        guard ["settings", "preferences"].contains(scope) else { throw NativeRPCError.invalidArguments("scope must be \"settings\" or \"preferences\"") }
        let patch = try Rules.record(args, "patch"), keys = patch.fields!.map(\.key)
        guard !keys.isEmpty else { throw NativeRPCError.invalidArguments("patch must name at least one key") }
        if scope == "settings" {
            let blocked = keys.filter(Rules.isProtectedSetting)
            guard blocked.isEmpty else { throw BackendDeckCoreSecurityRefusal(.notPermitted, "these settings cannot be changed through Hoot: \(blocked.joined(separator: ", ")). Ask the person to change them in Settings if they want them changed.") }
        } else {
            let unknown = keys.filter { !Rules.writablePreferences.contains($0) }
            guard unknown.isEmpty else { throw BackendDeckCoreSecurityRefusal(.notPermitted, "preferences has no writable key called \(unknown.joined(separator: ", ")). Writable preferences are: \(Rules.writablePreferences.joined(separator: ", ")).") }
        }
        return (scope, patch, keys)
    }
    public static func prepareSettingsWrite(_ args: NativeRPCValue, surface: any BackendDeckCoreCatalogueSurface) throws -> (scope: String, patch: NativeRPCValue, keys: [String], snapshot: String) {
        let checked = try checkSettingsPatch(args)
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
        case "git.diff", "git.status": _ = try requireKnownFolder(surface, path: Rules.string(args, "cwd"))
        case "alerts.list": _ = try requireKnownFolder(surface, path: Rules.string(args, "projectPath"))
        case "settings.write": _ = try prepareSettingsWrite(args, surface: surface)
        case "log.note": _ = try Rules.sanitizeNote(Rules.string(args, "note"))
        default: break
        }
    }
    public static func prepareSettingsWriteAsync(_ args: NativeRPCValue, surface: any BackendDeckCoreCatalogueSurface) async throws -> (scope: String, patch: NativeRPCValue, keys: [String], snapshot: String) {
        guard let writer = surface as? any BackendCompositionSettingsWriting else { return try prepareSettingsWrite(args, surface: surface) }
        let checked = try checkSettingsPatch(args)
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
            let sessions = surface.listSessions().filter { cwd == nil || $0["cwd"].string == cwd }.map { viewOf(surface: surface, context: context, metadata: $0) }.sorted(by: BackendDeckCoreAttention.precedes)
            let blocked = sessions.filter { $0["attention"] == .string("blocked") }.count
            let summary = Rules.object([("count", .number(Double(sessions.count))), ("blocked", .number(Double(blocked)))])
            return .init(value: NativeRPCValue.object([.init("sessions", .array(sessions))]).merging(summary), summary: summary)
        case "sessions.get":
            let session = try requireSession(surface: surface, context: context, id: Rules.string(args, "sessionId"))
            let match = try await surface.transcriptFor(session: session)
            let bytes: Double
            if let path = match["path"].string, !path.isEmpty { bytes = try await surface.transcriptBytes(path: path) } else { bytes = 0 }
            var value = Rules.object([
                ("session", session), ("windows", .array(surface.windows(sessionID: session["id"].string ?? "").map { $0["description"] })),
                ("transcriptPath", match["path"]), ("transcriptBytes", .number(bytes)), ("transcriptBasis", match["basis"]),
                ("transcriptAmbiguous", match["ambiguous"]), ("otherSessionsInFolder", match["otherSessions"])
            ])
            if match["note"] != .null { value = value.setting("transcriptNote", match["note"]) }
            return .init(value: value, summary: Rules.object([("sessionId", session["id"]), ("status", session["status"]), ("basis", match["basis"])]))
        case "sessions.transcript": return try await transcript(args: args, context: context, surface: surface)
        case "sessions.start": return try await start(args: args, context: context, surface: surface)
        case "sessions.send":
            let session = try requireSession(surface: surface, context: context, id: Rules.string(args, "sessionId"))
            let text = try Rules.sanitizeSendText(Rules.string(args, "text")), submit = try Rules.optionalBool(args, "submit", fallback: true)
            guard session["exitCode"] == .null else { throw NativeRPCError.invalidArguments("session \(session["id"].string ?? "") has already exited; there is nothing to type into") }
            let sentAt = context.now(), sessionID = session["id"].string ?? ""
            try await BackendDeckCoreTyping.typeLine(write: { data in try await surface.writeToSession(sessionID, data: data) }, text: text, submit: submit, clock: typingClock)
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
            let sessions = surface.listSessions().map { viewOf(surface: surface, context: context, metadata: $0) }.sorted(by: BackendDeckCoreAttention.precedes)
            let fleet = try await surface.reportOnFleet(sessions: sessions, since: minutes == 0 ? nil : context.now() - Double(minutes) * 60_000,
                limit: Rules.optionalInt(args, "limit", fallback: 8, min: 1, max: 25), now: context.now())
            return .init(value: fleet, summary: Rules.object([("sessions", fleet["totals"]["sessions"]), ("blocked", fleet["totals"]["blocked"]), ("looping", fleet["totals"]["looping"]), ("failed", fleet["totals"]["failed"])]))
        case "git.diff":
            let cwd = try requireKnownFolder(surface, path: Rules.string(args, "cwd"))
            let sessions = surface.listSessions().map { viewOf(surface: surface, context: context, metadata: $0) }
            let diff = try await surface.collectFolderDiff(sessions: sessions, cwd: cwd, path: Rules.optionalString(args, "path"), maxFiles: Rules.optionalInt(args, "maxFiles", fallback: 25, min: 1, max: 100))
            return .init(value: diff, summary: Rules.object([("cwd", .string(cwd)), ("files", diff["changedFiles"]), ("withDiff", diff["withDiff"]), ("bound", diff["bound"])]))
        case "git.status":
            let cwd = try requireKnownFolder(surface, path: Rules.string(args, "cwd")), status = try await surface.gitStatus(cwd: cwd)
            return .init(value: status, summary: Rules.object([("cwd", .string(cwd)), ("repo", .bool(status.fields != nil && status["repo"] == .bool(true)))]))
        case "alerts.list":
            let path = try requireKnownFolder(surface, path: Rules.string(args, "projectPath")), report = try await surface.alerts(projectPath: path)
            return .init(value: report, summary: Rules.object([("projectPath", .string(path)), ("alerts", .number(Double(report["alerts"].elements?.count ?? 0)))]))
        case "settings.read":
            let stores = surface.readSettings(), settings = stores["settings"], preferences = stores["preferences"]
            return .init(value: Rules.object([("settings", settings), ("preferences", preferences),
                ("writablePreferences", Rules.strings(Rules.writablePreferences)), ("protectedSettingKeys", Rules.strings(Rules.protectedKeys)),
                ("protectedSettingPrefixes", Rules.strings(Rules.protectedPrefixes))]), summary: .object([.init("keys", .number(Double(settings.fields?.count ?? 0)))]))
        case "settings.write":
            let request = try await prepareSettingsWriteAsync(args, surface: surface)
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
        let match = try await surface.transcriptFor(session: session)
        guard let path = match["path"].string else {
            let screen = try await surface.sessionScreen(session["id"].string ?? "") ?? ""
            let text = screen.utf16.count > maxScreenChars ? Rules.suffix(screen, maxScreenChars) : screen
            let source = screen.isEmpty ? "none" : "terminal"
            return .init(value: Rules.object([("sessionId", session["id"]), ("cwd", session["cwd"]), ("source", .string(source)), ("transcriptPath", .null),
                ("partial", .bool(screen.utf16.count > text.utf16.count)), ("messages", .array([])), ("screen", .string(text))]),
                summary: Rules.object([("source", .string(source)), ("chars", .number(Double(text.utf16.count)))]))
        }
        let bytes = try await surface.transcriptBytes(path: path), fromByte = Swift.max(0, bytes - Double(windowBytes))
        let parsed = try await surface.readTranscriptFrom(path: path, fromByte: fromByte), tail = fitTail(parsed, limit: limit)
        return .init(value: Rules.object([("sessionId", session["id"]), ("cwd", session["cwd"]), ("source", .string("chat")), ("transcriptPath", .string(path)),
            ("fileBytes", .number(bytes)), ("fromByte", .number(fromByte)), ("partial", .bool(fromByte > 0 || tail.dropped > 0)),
            ("inWindow", .number(Double(parsed.count))), ("returned", .number(Double(tail.kept.count))), ("messages", .array(tail.kept))]),
            summary: Rules.object([("source", .string("chat")), ("fileBytes", .number(bytes)), ("fromByte", .number(fromByte)), ("returned", .number(Double(tail.kept.count))), ("inWindow", .number(Double(parsed.count)))]))
    }
    private static func start(args: NativeRPCValue, context: Context, surface: any BackendDeckCoreCatalogueSurface) async throws -> Output {
        // Repeat the refusal rules when reached without a precheck.
        try checkStart(surface: surface, context: context, arguments: args)
        let cwd = try requireStartableFolder(surface: surface, caller: context.caller, path: Rules.string(args, "cwd"))
        let brief = try checkBrief(args), account = try chooseAccount(surface: surface, arguments: args)
        let asked = try Rules.optionalString(args, "provider")
        if let asked, !providers.contains(asked) { throw NativeRPCError.invalidArguments("provider must be one of \(providers.joined(separator: ", "))") }
        let provider = asked ?? account?["provider"].string
        let conversation = try Rules.optionalString(args, "conversation")
        if let conversation, conversation.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) == nil {
            throw NativeRPCError.invalidArguments("conversation must be a conversation id")
        }
        var input = Rules.object([("cwd", .string(cwd)), ("cols", .number(120)), ("rows", .number(30)),
            ("resume", .bool(try Rules.optionalBool(args, "resume", fallback: false) || conversation != nil))])
        if let conversation { input = input.setting("resumeConversationId", .string(conversation)) }
        if let provider { input = input.setting("provider", .string(provider)) }
        if let account { input = input.setting("profileId", account["id"]) }
        input = input.merging(try limitsFrom(context.sessionLimits)).merging(context.caller.sessionOrigin).setting("originRunId", .string(context.callID))
        var spec: NativeRPCValue?
        if let brief {
            spec = try surface.writeSpec(directory: BackendDeckCoreBrief.specsDirectory(copilotRoot: URL(fileURLWithPath: surface.copilotRoot())).path, input: Rules.object([
                ("title", .string(try Rules.optionalString(args, "title") ?? "brief")), ("brief", .string(brief)), ("cwd", .string(cwd)),
                ("provider", provider.map(NativeRPCValue.string) ?? .null), ("callId", .string(context.callID)), ("at", .number(context.now()))
            ]))
            guard spec?["path"].string != nil else { throw NativeRPCError(code: "internal", message: "The brief writer returned no path, so no session was started.") }
        }
        let meta = try await surface.startSession(input: input, forDevice: context.caller.kind == .remote ? (context.caller.deviceID ?? "") : nil)
        let sessionID = try meta["id"].requireString("started session id", nonempty: true)
        context.noteStarted(sessionID)
        let session = viewOf(surface: surface, context: context, metadata: meta)
        var summary = Rules.object([("sessionId", meta["id"]), ("cwd", meta["cwd"]), ("provider", meta["provider"])])
        guard let spec, let path = spec["path"].string else { return .init(value: Rules.object([("session", session), ("spec", .null)]), summary: summary) }
        let line = BackendDeckCoreBrief.deliveryLine(path), delivery = try await surface.deliverBrief(sessionID, line: line)
        let delivered = delivery["delivered"] == .bool(true)
        let nextStep: NativeRPCValue = delivered ? .null : .string("The session is running but has not been told anything. \(delivery["reason"].isNullish ? "null" : Rules.jsString(delivery["reason"])) Send it \"\(line)\" with sessions.send once its prompt is up, or tell the person.")
        summary = summary.setting("spec", .string(path)).setting("delivered", .bool(delivered))
        return .init(value: Rules.object([("session", session), ("spec", Rules.object([("path", .string(path)), ("delivered", .bool(delivered)),
            ("waitedMs", delivery["waitedMs"]), ("nextStep", nextStep)]))]), summary: summary)
    }
}
