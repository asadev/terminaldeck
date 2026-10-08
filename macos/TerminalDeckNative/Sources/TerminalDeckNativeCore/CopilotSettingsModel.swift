import Foundation

/// Settings → Hoot, as data: a port of `settings/sections/copilot-bridge.ts` and the
/// pure parts of `CopilotSection.tsx`. Same narrowing, same words.

public enum CopilotWords {
    public static let assistant = "Hoot"
    public static let blurb = "The one agent that can see every session — and every file it reads, remembers and writes."
    public static let neverStarted = "It has never been started. Its folder, its instructions and its memory are all written the first time it runs — nothing below exists on disk yet."

    /// `STATUS_LABEL`.
    public static func statusLabel(_ status: CopilotStatus) -> String {
        switch status {
        case .stopped: return "Not running"
        case .starting: return "Starting…"
        case .running: return "Running"
        }
    }

    /// `logTrustLine`.
    public static func logTrustLine(_ report: CopilotActionLog) -> String {
        report.outsideCopilotFolder
            ? "Checked just now: this file is outside every path \(assistant) can write to."
            : "This file is inside \(assistant)’s own folder, which it can write to. That is a defect — the log is not trustworthy until it moves."
    }

    /// `baseName`.
    public static func baseName(_ path: String) -> String {
        guard let cut = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return path }
        return String(path[path.index(after: cut)...])
    }

    /// `when`: the time today, or "Mon d, hh:mm"; "never" for none.
    public static func when(_ at: Double?, now: Date = Date()) -> String {
        guard let at else { return "never" }
        let date = Date(timeIntervalSince1970: at / 1000)
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("hhmm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMdhhmm")
        }
        return formatter.string(from: date)
    }

    /// `whenIso`: an ISO time as `when` says it, or the text itself.
    public static func whenIso(_ at: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: at) ?? ISO8601DateFormatter().date(from: at) {
            return when(date.timeIntervalSince1970 * 1000)
        }
        return at
    }
}

// MARK: - The session

public enum CopilotStatus: String, Sendable { case stopped, starting, running }
public enum CopilotInstructionsState: String, Sendable { case missing, current, superseded, edited }

public struct CopilotStartupFile: Equatable, Sendable, Identifiable {
    public enum Owner: String, Sendable { case app, yours, folder }
    public let path: String
    public let purpose: String
    public let exists: Bool
    public let size: Double?
    public let modifiedAt: Double?
    public let owner: Owner
    public var id: String { path }

    static func from(_ raw: CodingAIJSON) -> CopilotStartupFile? {
        guard raw.isObject, let path = raw["path"].string else { return nil }
        return CopilotStartupFile(path: path, purpose: raw["purpose"].string ?? "", exists: raw["exists"].isTrue,
                                  size: raw["size"].number, modifiedAt: raw["modifiedAt"].number,
                                  owner: Owner(rawValue: raw["owner"].string ?? "") ?? .folder)
    }
}

public struct CopilotFolder: Equatable, Sendable {
    public let home: String
    public let chosen: String?
    public let isDefault: Bool
    public let problem: String?
    public let runningIn: String?
    public let restartNeeded: Bool

    /// `toCopilotFolder`.
    public static func from(_ raw: CodingAIJSON) -> CopilotFolder? {
        guard raw.isObject, let home = raw["home"].string else { return nil }
        return CopilotFolder(home: home, chosen: raw["chosen"].text, isDefault: raw["isDefault"].bool != false,
                             problem: raw["problem"].text, runningIn: raw["runningIn"].text, restartNeeded: raw["restartNeeded"].isTrue)
    }
}

public struct CopilotFolderChange: Equatable, Sendable {
    public let folder: CopilotFolder?
    public let problem: String?
    public let cancelled: Bool

    /// `toFolderChange`.
    public static func from(_ raw: CodingAIJSON) -> CopilotFolderChange {
        guard raw.isObject else { return CopilotFolderChange(folder: nil, problem: "That did not work.", cancelled: false) }
        return CopilotFolderChange(folder: CopilotFolder.from(raw["report"]), problem: raw["problem"].text, cancelled: raw["cancelled"].isTrue)
    }
}

public struct CopilotLayerRead: Equatable, Sendable {
    public let text: String?
    public let path: String
    public let error: String?

    /// `toLayerRead`.
    public static func from(_ raw: CodingAIJSON) -> CopilotLayerRead {
        guard raw.isObject else { return CopilotLayerRead(text: nil, path: "", error: "This build could not read that file.") }
        return CopilotLayerRead(text: raw["text"].string, path: raw["path"].string ?? "", error: raw["error"].text)
    }
}

public struct CopilotState: Equatable, Sendable {
    public struct Paths: Equatable, Sendable {
        public let root: String
        public let ownFolder: Bool
        public let instructions: String
        public let memory: String
        public let log: String
        public let actions: String
        public let layerDir: String
        public let layerYours: String
        public let layerContract: String
        public let layerComposed: String
    }
    public struct Records: Equatable, Sendable {
        public let kind: String
        public let enforced: Bool
        public let reason: String?
        public let paths: [String]
    }

    public let status: CopilotStatus
    public let sessionId: String?
    public let paths: Paths
    public let folder: CopilotFolder?
    public let home: String
    public let startedAt: Double?
    public let problem: String?
    public let records: Records
    public let profile: (id: String, name: String)?
    public let instructionsAreDefault: Bool
    public let instructions: CopilotInstructionsState
    public let startupFiles: [CopilotStartupFile]
    public let layerFiles: [CopilotStartupFile]

    public static func == (a: CopilotState, b: CopilotState) -> Bool {
        a.status == b.status && a.sessionId == b.sessionId && a.paths == b.paths && a.folder == b.folder && a.home == b.home
            && a.startedAt == b.startedAt && a.problem == b.problem && a.records == b.records
            && a.profile?.id == b.profile?.id && a.profile?.name == b.profile?.name
            && a.instructionsAreDefault == b.instructionsAreDefault && a.instructions == b.instructions
            && a.startupFiles == b.startupFiles && a.layerFiles == b.layerFiles
    }

    /// `toCopilotState`: nil without an object holding `paths.root`.
    public static func from(_ raw: CodingAIJSON) -> CopilotState? {
        guard raw.isObject, raw["paths"].isObject, let root = raw["paths"]["root"].string else { return nil }
        let paths = raw["paths"]
        let layer = paths["layer"]
        let records = raw["records"]
        let profile = raw["profile"]
        let status = raw["status"].string
        return CopilotState(
            status: status == "running" ? .running : status == "starting" ? .starting : .stopped,
            sessionId: raw["sessionId"].text,
            paths: Paths(root: root, ownFolder: paths["ownFolder"].bool != false, instructions: paths["instructions"].string ?? "",
                         memory: paths["memory"].string ?? "", log: paths["log"].string ?? "", actions: paths["actions"].string ?? "",
                         layerDir: layer["dir"].string ?? "", layerYours: layer["yours"].string ?? "",
                         layerContract: layer["contract"].string ?? "", layerComposed: layer["composed"].string ?? ""),
            folder: CopilotFolder.from(raw["folder"]),
            home: raw["home"].string ?? "",
            startedAt: raw["startedAt"].number,
            problem: raw["problem"].text,
            records: Records(kind: records["kind"].string ?? "none", enforced: records["enforced"].isTrue,
                             reason: records["reason"].text, paths: (records["paths"].array ?? []).compactMap(\.string)),
            profile: profile.isObject ? profile["id"].string.map { ($0, profile["name"].string ?? $0) } : nil,
            instructionsAreDefault: raw["instructionsAreDefault"].isTrue,
            instructions: CopilotInstructionsState(rawValue: raw["instructions"].string ?? "") ?? .missing,
            startupFiles: (raw["startupFiles"].array ?? []).compactMap(CopilotStartupFile.from),
            layerFiles: (raw["layerFiles"].array ?? []).compactMap(CopilotStartupFile.from)
        )
    }

    /// `hasNeverStarted`: no instructions on disk and no memory folder.
    public static func neverStarted(_ state: CopilotState?, _ memory: CopilotMemoryReport?) -> Bool {
        guard let state else { return false }
        return state.instructions == .missing && memory?.exists != true
    }
}

public struct CopilotSignIn: Equatable, Sendable {
    public enum State: String, Sendable { case signedIn = "signed-in", signedOut = "signed-out", unknown }
    public let state: State
    public let account: String?
    public let plan: String?
    public let profileId: String
    public let profileName: String
    public let checkedAt: Double

    /// `toCopilotSignIn`.
    public static func from(_ raw: CodingAIJSON) -> CopilotSignIn? {
        guard raw.isObject else { return nil }
        return CopilotSignIn(state: State(rawValue: raw["state"].string ?? "") ?? .unknown, account: raw["account"].text,
                             plan: raw["plan"].text, profileId: raw["profileId"].string ?? "",
                             profileName: raw["profileName"].string ?? "", checkedAt: raw["checkedAt"].number ?? 0)
    }
}

// MARK: - Files

/// `toResetResult`, `toInstructionsWrite`, `toFolderInstructionsWrite`: one shape.
public struct CopilotWriteResult: Equatable, Sendable {
    public let done: Bool
    public let backup: String?
    public let created: Bool
    public let error: String?
    public let state: CopilotState?

    public static func reset(_ raw: CodingAIJSON) -> CopilotWriteResult {
        CopilotWriteResult(done: raw["reset"].isTrue, backup: raw["backup"].text, created: false, error: raw["error"].text,
                           state: CopilotState.from(raw["state"]))
    }
    public static func write(_ raw: CodingAIJSON) -> CopilotWriteResult {
        CopilotWriteResult(done: raw["saved"].isTrue, backup: raw["backup"].text, created: raw["created"].isTrue,
                           error: raw["error"].text, state: CopilotState.from(raw["state"]))
    }
}

/// `toInstructionsRead`: the text and its state, or why not.
public enum CopilotInstructionsRead: Equatable, Sendable {
    case text(String, CopilotInstructionsState)
    case failed(String)

    public static func from(_ raw: CodingAIJSON) -> CopilotInstructionsRead {
        if raw["ok"].isTrue, let text = raw["text"].string {
            return .text(text, CopilotInstructionsState(rawValue: raw["state"].string ?? "") ?? .missing)
        }
        return .failed(raw["error"].string ?? "Its instructions could not be read.")
    }
}

public struct CopilotFolderInstructionsRead: Equatable, Sendable {
    public let text: String
    public let exists: Bool
    public let error: String?

    /// `toFolderInstructionsRead`.
    public static func from(_ raw: CodingAIJSON) -> CopilotFolderInstructionsRead {
        guard let text = raw["text"].string else {
            return CopilotFolderInstructionsRead(text: "", exists: false,
                                                 error: raw["error"].string ?? "That folder’s own instructions could not be read.")
        }
        return CopilotFolderInstructionsRead(text: text, exists: raw["exists"].isTrue, error: raw["error"].text)
    }
}

public struct CopilotScaffoldResult: Equatable, Sendable {
    public let created: [String]
    public let removed: [String]
    public let error: String?

    public static func from(_ raw: CodingAIJSON) -> CopilotScaffoldResult {
        CopilotScaffoldResult(created: (raw["created"].array ?? []).compactMap(\.string),
                              removed: (raw["removed"].array ?? []).compactMap(\.string), error: raw["error"].text)
    }
}

public enum CopilotReveal {
    /// `toRevealMessage`.
    public static func message(_ raw: CodingAIJSON) -> String { raw["message"].string ?? "Nothing happened." }
}

// MARK: - The showing

public enum CopilotShowing {
    public static let setting = RNMHootSettingsMigration.interactiveKey
    /// `toInteractiveDriving`: on unless the setting says false.
    public static func interactive(_ raw: CodingAIJSON) -> Bool {
        let values = raw["values"].isObject ? raw["values"] : raw
        // An explicitly stored current key wins, including false or null.
        // Older peers/settings snapshots still use the protected legacy key.
        return (values.object?[setting] ?? values["copilot.interactive"]).bool != false
    }
}

// MARK: - Memory

public struct CopilotMemoryFact: Equatable, Sendable, Identifiable {
    public let name: String
    public let path: String
    public let bytes: Double
    public let modifiedAt: Double
    public let description: String?
    public let type: String?
    public let scope: String?
    public let verified: String?
    public let index: Bool
    public var id: String { name }
}

public struct CopilotMemoryReport: Equatable, Sendable {
    public let dir: String
    public let exists: Bool
    public let facts: [CopilotMemoryFact]
    public let error: String?

    /// `toMemoryReport`.
    public static func from(_ raw: CodingAIJSON) -> CopilotMemoryReport? {
        guard raw.isObject, let dir = raw["dir"].string else { return nil }
        let facts: [CopilotMemoryFact] = (raw["facts"].array ?? []).compactMap { fact in
            guard fact.isObject, let name = fact["name"].string else { return nil }
            return CopilotMemoryFact(name: name, path: fact["path"].string ?? "", bytes: fact["bytes"].number ?? 0,
                                     modifiedAt: fact["modifiedAt"].number ?? 0, description: fact["description"].text,
                                     type: fact["type"].text, scope: fact["scope"].text, verified: fact["verified"].text,
                                     index: fact["index"].isTrue)
        }
        return CopilotMemoryReport(dir: dir, exists: raw["exists"].isTrue, facts: facts, error: raw["error"].text)
    }
}

/// `toMemoryRead`.
public enum CopilotMemoryRead: Equatable, Sendable {
    case text(name: String, text: String, truncated: Bool)
    case failed(String)

    public static func from(_ raw: CodingAIJSON) -> CopilotMemoryRead {
        if raw["ok"].isTrue, let text = raw["text"].string {
            return .text(name: raw["name"].string ?? "", text: text, truncated: raw["truncated"].isTrue)
        }
        return .failed(raw["error"].string ?? "That file could not be read.")
    }
}

/// `toMemoryDelete` / `toMemoryWrite`.
public struct CopilotMemoryChange: Equatable, Sendable {
    public let ok: Bool
    public let error: String?
    public let memory: CopilotMemoryReport?

    public static func from(_ raw: CodingAIJSON) -> CopilotMemoryChange {
        CopilotMemoryChange(ok: raw["ok"].isTrue, error: raw["error"].text, memory: CopilotMemoryReport.from(raw["memory"]))
    }
}

// MARK: - The action log

public struct CopilotLoggedAction: Equatable, Sendable, Identifiable {
    public enum Outcome: String, Sendable { case ok, refused, error }
    public let at: String
    public let action: String
    public let detail: String
    public let tool: String?
    public let tier: String?
    public let outcome: Outcome?
    public let confirmationRequired: Bool?
    public let confirmed: Bool?
    public let confirmedBy: String?
    public let refusedReason: String?
    public let caller: String?
    public let ms: Double?
    public let error: String?
    public let sessionId: String?
    public var id: String { "\(at)|\(action)|\(detail)" }
}

public struct CopilotActionLog: Equatable, Sendable {
    public let dir: String
    public let file: String
    public let exists: Bool
    public let bytes: Double
    public let outsideCopilotFolder: Bool
    public let rows: [CopilotLoggedAction]
    public let more: Bool
    public let error: String?

    /// `toActionLog`.
    public static func from(_ raw: CodingAIJSON) -> CopilotActionLog? {
        guard raw.isObject, let file = raw["file"].string else { return nil }
        let rows: [CopilotLoggedAction] = (raw["rows"].array ?? []).compactMap { row in
            guard row.isObject, let at = row["at"].string, let action = row["action"].string else { return nil }
            let caller = row["caller"].string
            return CopilotLoggedAction(
                at: at, action: action, detail: row["detail"].string ?? "", tool: row["tool"].text, tier: row["tier"].text,
                outcome: CopilotLoggedAction.Outcome(rawValue: row["outcome"].string ?? ""),
                confirmationRequired: row["confirmationRequired"].bool, confirmed: row["confirmed"].bool,
                confirmedBy: row["confirmedBy"].text, refusedReason: row["refusedReason"].text,
                caller: caller == "local" || caller == "remote" ? caller : nil, ms: row["ms"].number,
                error: row["error"].text, sessionId: row["sessionId"].text)
        }
        return CopilotActionLog(dir: raw["dir"].string ?? "", file: file, exists: raw["exists"].isTrue,
                                bytes: raw["bytes"].number ?? 0, outsideCopilotFolder: raw["outsideCopilotFolder"].isTrue,
                                rows: rows, more: raw["more"].isTrue, error: raw["error"].text)
    }
}

// MARK: - Routines

public struct CopilotRoutine: Equatable, Sendable, Identifiable {
    public enum State: String, Sendable { case armed, running, disabled, broken, unarmed, paused, stale }
    public struct Refusal: Equatable, Sendable { public let at: Double; public let tool: String; public let reason: String }
    public let id: String
    public let name: String
    public let file: String
    public let folder: String?
    public let triggers: [String]
    public let prompt: String
    public let enabled: Bool
    public let state: State
    public let reason: String?
    public let problems: [String]
    public let warnings: [String]
    public let lastRunAt: Double?
    public let lastFinishedAt: Double?
    public let lastOutcome: String?
    public let lastError: String?
    public let consecutiveFailures: Int
    public let running: Bool
    public let runsLastHour: Int
    public let runsLastDay: Int
    public let pausedUntil: Double?
    public let nextDueAt: Double?
    public let missedWhileClosed: Int
    public let refusedCalls: [Refusal]

    /// `toRoutineRows`.
    public static func list(_ raw: CodingAIJSON) -> [CopilotRoutine] {
        (raw.array ?? []).compactMap { view in
            guard view.isObject, let id = view["id"].string else { return nil }
            let outcome = view["lastOutcome"].string
            return CopilotRoutine(
                id: id, name: view["name"].string ?? id, file: view["file"].string ?? "", folder: view["folder"].text,
                triggers: (view["triggers"].array ?? []).compactMap(\.string), prompt: view["prompt"].string ?? "",
                enabled: view["enabled"].bool ?? true, state: State(rawValue: view["state"].string ?? "") ?? .unarmed,
                reason: view["reason"].text, problems: (view["problems"].array ?? []).compactMap(\.string),
                warnings: (view["warnings"].array ?? []).compactMap(\.string), lastRunAt: view["lastRunAt"].number,
                lastFinishedAt: view["lastFinishedAt"].number,
                lastOutcome: outcome == "ok" || outcome == "failed" ? outcome : nil, lastError: view["lastError"].text,
                consecutiveFailures: Int(view["consecutiveFailures"].number ?? 0), running: view["running"].isTrue,
                runsLastHour: Int(view["runsLastHour"].number ?? 0), runsLastDay: Int(view["runsLastDay"].number ?? 0),
                pausedUntil: view["pausedUntil"].number, nextDueAt: view["nextDueAt"].number,
                missedWhileClosed: Int(view["missedWhileClosed"].number ?? 0),
                refusedCalls: (view["refusedCalls"].array ?? []).compactMap { entry in
                    guard entry.isObject, let tool = entry["tool"].string else { return nil }
                    return Refusal(at: entry["at"].number ?? 0, tool: tool, reason: entry["reason"].string ?? "")
                })
        }
    }
}

/// `toRoutineText` / `toRoutineWrite`.
public enum CopilotRoutineText: Equatable, Sendable {
    case text(String, file: String)
    case problems([String])

    public static func from(_ raw: CodingAIJSON) -> CopilotRoutineText {
        if raw["ok"].isTrue, let text = raw["text"].string { return .text(text, file: raw["file"].string ?? "") }
        let problems = (raw["problems"].array ?? []).compactMap(\.string)
        return .problems(problems.isEmpty ? ["That routine could not be read."] : problems)
    }
}

public enum CopilotRoutineWrite: Equatable, Sendable {
    case saved(id: String)
    case problems([String])

    public static func from(_ raw: CodingAIJSON) -> CopilotRoutineWrite {
        if raw["ok"].isTrue { return .saved(id: raw["id"].string ?? "") }
        let problems = (raw["problems"].array ?? []).compactMap(\.string)
        return .problems(problems.isEmpty ? ["That routine could not be saved."] : problems)
    }
}

// MARK: - Its name (shared/copilot-identity.ts)

/// `readCopilotIdentity`: the "## Who you are" block of its instructions.
public struct CopilotIdentity: Equatable, Sendable {
    public var name: String?
    public var callThem: String?
    public var addressNote: String?
    public init(name: String? = nil, callThem: String? = nil, addressNote: String? = nil) {
        self.name = name; self.callThem = callThem; self.addressNote = addressNote
    }

    public static let heading = "## Who you are"
    public static let end = "---"

    /// Whether the block is there at all (the setup has run), and what it says.
    public static func read(_ instructions: String?) -> (ran: Bool, identity: CopilotIdentity) {
        guard let instructions else { return (false, CopilotIdentity()) }
        let lines = instructions.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) else {
            return (false, CopilotIdentity())
        }
        var stop = lines.count
        var at = start + 1
        while at < lines.count {
            if lines[at].trimmingCharacters(in: .whitespaces) == end { stop = at + 1; break }
            if lines[at].range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil { stop = at; break }
            at += 1
        }
        let block = Array(lines[(start + 1)..<max(start + 1, stop)])
        func bolded(_ stem: String, _ max: Int) -> String? {
            for line in block where line.hasPrefix(stem) {
                let rest = String(line.dropFirst(stem.count))
                if let match = rest.range(of: #"^\*\*([^*]+)\*\*"#, options: .regularExpression) {
                    return clean(String(rest[match].dropFirst(2).dropLast(2)), max)
                }
            }
            return nil
        }
        func trailing(_ stem: String, _ max: Int) -> String? {
            for line in block where line.hasPrefix(stem) { return clean(String(line.dropFirst(stem.count)), max) }
            return nil
        }
        return (true, CopilotIdentity(name: bolded("Your name is ", 32), callThem: bolded("Call them ", 32),
                                      addressNote: trailing("Address them like this: ", 160)))
    }

    /// `cleanIdentityValue`.
    public static func clean(_ raw: String, _ max: Int) -> String? {
        let flattened = raw
            .replacingOccurrences(of: #"[\u0000-\u001f\u007f]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if flattened.isEmpty { return nil }
        let cut = String(flattened.prefix(max)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? nil : cut
    }

    /// The name row's line: what it is called, and what it calls you.
    public var line: String {
        (name == nil ? "It goes by \(CopilotWords.assistant), the name this app gives it." : "It is called \(name!).")
            + (callThem == nil ? " It has not been told what to call you." : " It calls you \(callThem!).")
    }
}

public enum CopilotFolderWords {
    public static let choosing = "\(CopilotWords.assistant) works in this folder as you would: it reads the folder’s own instructions and memory, and anything else in it — including any credentials kept there. That is the same access any session you start in that folder already has. Nothing of this app’s is ever written into it."
    public static let needsRestart = "A session’s folder is fixed when it starts, so this takes effect the next time \(CopilotWords.assistant) starts. The one running now keeps working where it began."
}

// MARK: - Its files (the FilesGroup words)

public enum CopilotFilesWords {
    /// `INSTRUCTIONS`: the instruction file's badge, whether it is quiet, and its sentence.
    public static func instructions(_ state: CopilotInstructionsState) -> (badge: String, quiet: Bool, says: String) {
        switch state {
        case .missing: return ("not written yet", true, "The file does not exist. Creating its files writes the version this build ships.")
        case .current: return ("as shipped", true, "Byte for byte what this build ships. You can edit it — the app will never write over your version.")
        case .superseded: return ("out of date", false, "A default an older build wrote, untouched since — nothing in it is yours. It describes powers this build has changed, so \(CopilotWords.assistant) is being told something untrue about itself.")
        case .edited: return ("your words", true, "These are your words, and they are the truth for \(CopilotWords.assistant) rather than this build’s wording. Nothing in the app will replace them.")
        }
    }

    /// `FileRow` never draws the same word twice, whatever it is handed.
    public static func distinct(_ badges: [(text: String, quiet: Bool)]) -> [(text: String, quiet: Bool)] {
        var shown: [(text: String, quiet: Bool)] = []
        for badge in badges where !shown.contains(where: { $0.text.lowercased() == badge.text.lowercased() }) { shown.append(badge) }
        return shown
    }

    /// Why Restore cannot act, or nil.
    public static func resetBecause(_ state: CopilotInstructionsState) -> String? {
        switch state {
        case .current: return "It already matches this build."
        case .missing: return "There is no file yet. Create its files instead."
        default: return nil
        }
    }

    /// The memory row's badge.
    public static func memoryBadge(_ memory: CopilotMemoryReport?) -> String {
        guard let memory else { return "not read" }
        guard memory.exists else { return "none yet" }
        let count = memory.facts.count
        return "\(count) file\(count == 1 ? "" : "s")"
    }

    /// What "Create its files" said.
    public static func scaffoldLine(_ result: CopilotScaffoldResult) -> String {
        if let error = result.error { return error }
        let count = result.created.count
        return count == 0 ? "Everything was already there." : "Created \(count) file\(count == 1 ? "" : "s"). Nothing was started."
    }

    /// "Saved. …" after a save of its instructions (or the folder's).
    public static func savedLine(backup: String?, running: Bool, created: Bool = false) -> String {
        let where_ = backup.map { " What was there is at \($0)." } ?? ""
        if created { return "Written. That folder now has its own instructions, and every session you start there reads them.\(where_)" }
        return running
            ? "Saved.\(where_) \(CopilotWords.assistant) is still running with the old text — restart it to apply this."
            : "Saved.\(where_) It applies the next time \(CopilotWords.assistant) starts."
    }
}

// MARK: - The action log and its reach (words)

public enum CopilotLogWords {
    /// Who confirmed, spelled out, and how long it took.
    public static func confirmLine(_ row: CopilotLoggedAction) -> String {
        let who: String
        if row.confirmed == nil {
            who = "Terminal Deck wrote this row itself"
        } else if row.confirmationRequired == false {
            who = "no confirmation needed at this tier"
        } else if row.confirmed == true {
            who = "you confirmed it\(row.confirmedBy.map { " (\($0))" } ?? "")"
        } else {
            who = "not confirmed\(row.refusedReason.map { " — \($0)" } ?? "")"
        }
        return who + (row.ms.map { " · \(OrderedJSON.jsNumber($0)) ms" } ?? "")
    }

    /// "What it has done"'s badge.
    public static func badge(_ log: CopilotActionLog?, loading: Bool) -> String {
        if loading && log == nil { return "reading" }
        let count = log?.rows.count ?? 0
        return count == 0 ? "nothing yet" : "\(count) record\(count == 1 ? "" : "s")"
    }

    /// Newest first; twelve until "Show the other N".
    public static func shown(_ log: CopilotActionLog?, all: Bool) -> [CopilotLoggedAction] {
        let rows = Array((log?.rows ?? []).reversed())
        return all ? rows : Array(rows.prefix(12))
    }

    /// The refused-records row: its badge, and the line under it.
    public static func recordsBadge(_ records: CopilotState.Records?) -> String {
        if records?.enforced == true { return "held" }
        return (records?.kind ?? "none") != "none" ? "not proven" : "not enforced here"
    }

    public static func recordsLine(_ state: CopilotState) -> String {
        if state.records.enforced { return "The running process was started inside that refusal, measured against this machine rather than assumed." }
        if let reason = state.records.reason { return reason }
        return state.status == .running
            ? "The running process is NOT inside that refusal."
            : "Nothing is running, so nothing is being held right now."
    }

    public static func refusedMore(_ records: CopilotState.Records?) -> String {
        "An agent that can write its own next trigger is an automation loop with no human in it; a record its subject can compose is worth nothing; and a permission an agent can grant itself is not a permission."
            + ((records?.paths.isEmpty ?? true) ? "" : " On this machine: \(records!.paths.joined(separator: ", ")).")
    }
}

// MARK: - Routines (words)

public enum CopilotRoutineWords {
    /// `ROUTINE_STATE_TEXT`.
    public static func state(_ state: CopilotRoutine.State) -> String {
        switch state {
        case .armed: return "armed"
        case .running: return "running now"
        case .disabled: return "off in its own file"
        case .broken: return "broken"
        case .unarmed: return "nothing is listening"
        case .paused: return "paused"
        case .stale: return "stale"
        }
    }

    /// Paused by its own failures.
    public static func brokenOff(_ routine: CopilotRoutine) -> Bool { routine.state == .paused && routine.consecutiveFailures > 0 }
    /// The switch: on unless off in its file or paused.
    public static func armed(_ routine: CopilotRoutine) -> Bool { routine.state != .disabled && routine.state != .paused }

    public static func brokenLine(_ routine: CopilotRoutine, when: (Double) -> String) -> String {
        (routine.reason ?? "Stopped after \(routine.consecutiveFailures) failures in a row.") + " "
            + (routine.pausedUntil.map { "It comes back on its own at \(when($0))." } ?? "It will not run again until you resume it.")
    }

    /// Why the switch cannot act (off in its own file), or nil.
    public static func switchBecause(_ routine: CopilotRoutine) -> String? {
        guard routine.state == .disabled else { return nil }
        return "\(routine.reason ?? "It is off in its own file.") Press Edit and change its `enabled:` line — the switch never writes to the file."
    }

    /// Why Run now cannot act, or nil.
    public static func runBecause(_ routine: CopilotRoutine) -> String? {
        if routine.running { return "It is running now." }
        if routine.state == .broken { return routine.problems.first ?? routine.reason ?? "This routine could not be read." }
        return nil
    }

    public static func triggers(_ routine: CopilotRoutine) -> String {
        (routine.triggers.isEmpty ? "no trigger" : routine.triggers.joined(separator: " · ")) + (routine.folder.map { " — in \($0)" } ?? "")
    }

    public static func lastRun(_ routine: CopilotRoutine, when: (Double) -> String) -> String {
        var line: String
        if let finished = routine.lastFinishedAt {
            let outcome = routine.lastOutcome == "ok" ? "finished"
                : routine.lastOutcome == "failed" ? "failed\(routine.lastError.map { ": \($0)" } ?? "")" : "outcome unknown"
            line = "Last run \(when(finished)) — \(outcome)."
        } else {
            line = "It has never run."
        }
        if let next = routine.nextDueAt { line += " Next due \(when(next))." }
        if routine.missedWhileClosed > 0 { line += " \(routine.missedWhileClosed) due while the app was closed." }
        return line
    }

    public static func refused(_ routine: CopilotRoutine) -> String? {
        let count = routine.refusedCalls.count
        guard count > 0 else { return nil }
        return "\(count) call\(count == 1 ? " was" : "s were") refused during its runs — a decision is waiting for you rather than the routine being broken."
    }

    /// What `routines:run` answered.
    public static func runLine(_ raw: CodingAIJSON, name: String) -> String {
        if raw["started"].isTrue { return "\(name) is running." }
        return raw["reason"].string ?? "It did not start, and said nothing about why."
    }
}
