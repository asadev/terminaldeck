import Foundation
import TerminalDeckNativeCore

/// One question for the helper AI.
public struct DeckMemoryFlowHelperRequest: Sendable, Equatable {
    /// claude | codex | gemini
    public var ai: String
    /// "" = the small default (Claude: sonnet; Codex and Gemini: that app's own default).
    public var model: String
    public var system: String
    public var prompt: String
    public var timeoutMilliseconds: Double
    public init(ai: String, model: String, system: String, prompt: String, timeoutMilliseconds: Double = 180_000) {
        self.ai = ai; self.model = model; self.system = system; self.prompt = prompt; self.timeoutMilliseconds = timeoutMilliseconds
    }
}

/// What the AI answered, and what the run used when the AI app reports it (Claude Code does).
public struct DeckMemoryFlowHelperReply: Sendable, Equatable {
    public var text: String
    /// Everything read (the question plus what the AI app adds around it), in tokens.
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(text: String, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.text = text; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

/// Runs one helper question and returns the AI's answer. Throws with a plain reason.
public protocol DeckMemoryFlowHelperRunning: Sendable {
    func run(_ request: DeckMemoryFlowHelperRequest) async throws -> DeckMemoryFlowHelperReply
}

/// What the helper may hand back for one conversation part. The app decides what is written and where.
public struct DeckMemoryFlowHelperAnswer: Sendable, Equatable {
    public struct Note: Sendable, Equatable {
        public var type: DeckMemoryNoteType
        public var title: String
        public var text: String
        /// The number of the stored note (as shown to the helper) this one explicitly replaces.
        public var replaces: Int?
        /// 3 to 6 words naming it, for lists (nil = the app uses the first words).
        public var short: String? = nil
    }
    public struct Topic: Sendable, Equatable { public var title: String; public var text: String }
    public var result = ""
    public var state: DeckMemoryResultState?
    public var proof = ""
    /// nil = the helper said nothing about it; "" = nothing waits any more.
    public var waiting: String?
    public var notes: [Note] = []
    public var topics: [Topic] = []
    public var isEmpty: Bool { result.isEmpty && notes.isEmpty && topics.isEmpty && (waiting ?? "").isEmpty }
}

/// Builds the helper's fixed input pack (MEMORY-LESSONS.md change 6) and reads its answer.
public enum DeckMemoryFlowHelperPrompt {
    /// Room for the new rows in one question (about 24,000 tokens). More than this is read by a second job.
    public static let budgetCharacters = 90_000
    /// A tool row keeps its start and its end.
    public static let toolCapCharacters = 2_500
    /// The person's and the AI's words go in whole; this only stops one enormous paste from filling the pack.
    public static let messageCapCharacters = 30_000
    public static let referenceRows = 6, referenceCapCharacters = 300
    static let maximumNotes = 12, maximumTopics = 6

    public struct Slice: Sendable, Equatable {
        public var text: String
        public var lastID: Int64
        public var rows: Int
        /// Rows were left for the next job.
        public var more: Bool
    }

    static func stamp() -> DateFormatter {
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd HH:mm"; format.locale = Locale(identifier: "en_US_POSIX"); return format
    }
    static func label(_ entry: DeckMemoryDiaryEntry) -> String {
        switch DeckMemoryFlowRules.author(entry) {
        case "person": return "PERSON"
        case "orchestrator": return "HOOT (the orchestrator)"
        case "lead": return "LEAD"
        case "tool": return "TOOL"
        case "app": return "APP"
        case "agent": return "AI"
        // The app did not record who typed it: never taken for the person's own words.
        default: return "USER SIDE (not confirmed to be the person)"
        }
    }
    /// Keeps the start and the end, with a visible marker where text was taken out.
    static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = limit * 2 / 3, tail = limit - head
        return String(text.prefix(head)) + "\n[… \(text.count - limit) characters left out …]\n" + String(text.suffix(tail))
    }
    static func line(_ entry: DeckMemoryDiaryEntry, cap: Int, format: DateFormatter) -> String {
        // Recognised secrets never leave the Mac in a helper question; the diary itself stays word for word.
        let text = DeckMemoryRedaction.forSharing(cut(entry.text, to: cap))
        return "[" + format.string(from: entry.at) + "] " + label(entry) + ": " + text
    }

    /// The new rows of one session's diary as the helper reads them, oldest first, within the budget.
    /// When they do not all fit, the cut falls at the start of a turn (before something the person or the orchestrator said).
    public static func slice(_ entries: [DeckMemoryDiaryEntry], budget: Int = budgetCharacters) -> Slice {
        let format = stamp()
        var lines: [String] = [], used = 0
        for entry in entries {
            let text = line(entry, cap: entry.role == .tool ? toolCapCharacters : messageCapCharacters, format: format)
            if !lines.isEmpty, used + text.count > budget {
                var keep = lines.count
                if let turn = (1..<keep).last(where: { entries[$0].role == .user }) { keep = turn }
                return Slice(text: lines.prefix(keep).joined(separator: "\n\n"), lastID: entries[keep - 1].id, rows: keep, more: true)
            }
            lines.append(text); used += text.count
        }
        return Slice(text: lines.joined(separator: "\n\n"), lastID: entries.last?.id ?? 0, rows: lines.count, more: false)
    }

    /// The rows just before the new ones, cut short: context only.
    public static func reference(_ entries: [DeckMemoryDiaryEntry]) -> String {
        let format = stamp()
        return entries.suffix(referenceRows).map { line($0, cap: referenceCapCharacters, format: format) }.joined(separator: "\n")
    }
    /// The notes already stored, numbered 1, 2, 3… in the order given. Imported or hand-edited notes were never
    /// cleaned on the way in, so secrets and private parts come out here as they do for diary rows.
    public static func stored(_ notes: [DeckMemoryNote]) -> String {
        let format = stamp()
        if notes.isEmpty { return "None." }
        return notes.enumerated().map { index, note in
            "\(index + 1). [\(note.type.rawValue) · \(format.string(from: note.labels.date))] \(DeckMemoryRedaction.forSharing(note.title)): "
                + String(DeckMemoryRedaction.forSharing(note.body).prefix(400)).replacingOccurrences(of: "\n", with: " ")
        }.joined(separator: "\n")
    }

    /// The whole question for one conversation part. `who` is a plain description the app wrote.
    public static func turn(who: String, part: String, before: String, stored: [DeckMemoryNote], topics: [DeckMemoryTopic], checklist: String,
                            correcting: Bool, prompts: DeckMemoryFlowPrompts = .standard) -> String {
        let open = topics.isEmpty ? "None yet." : topics.prefix(8).map {
            "### " + DeckMemoryRedaction.forSharing($0.title) + "\n" + String(DeckMemoryRedaction.forSharing($0.body).prefix(1_500))
        }.joined(separator: "\n\n")
        let flag = correcting ? "\nNOTE FROM THE APP: the person seems to be correcting something in part 1. Find what, and write it as a correction note in their own words.\n" : ""
        return DeckMemoryFlowPrompts.fill(prompts.helperTurn, ["who": who, "flag": flag, "part": part, "before": before.isEmpty ? "None." : before,
            "stored": DeckMemoryFlowHelperPrompt.stored(stored), "topics": open, "checklist": checklist.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    static func noteType(_ raw: String?) -> DeckMemoryNoteType {
        var kind = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
        if kind == "howto" { kind = "how-to" }
        if kind == "openitem" || kind == "open" { kind = "open-item" }
        return DeckMemoryNoteType.standard.first { $0.rawValue == kind } ?? .note
    }

    /// Reads the helper's answer. Lenient about wrapping (code fences, a sentence before the JSON), strict about content.
    public static func parse(_ raw: String) throws -> DeckMemoryFlowHelperAnswer {
        let value = try object(in: raw)
        var answer = DeckMemoryFlowHelperAnswer()
        let board = value["board"]
        answer.result = clean(board["result"].string, limit: 600)
        answer.proof = clean(board["proof"].string, limit: 300)
        if board.has("waiting"), let waiting = board["waiting"].string { answer.waiting = clean(waiting, limit: 300) }
        if !answer.result.isEmpty {
            var state = DeckMemoryResultState(rawValue: (board["state"].string ?? "").trimmingCharacters(in: .whitespaces).lowercased()) ?? .attempted
            // The app's rule, not the AI's: verified needs proof.
            if state == .verified, answer.proof.isEmpty { state = .reported }
            answer.state = state
        }
        for item in (value["notes"].elements ?? []).prefix(maximumNotes) {
            let text = clean(item["text"].string, limit: 1_200)
            guard !text.isEmpty else { continue }
            var title = clean(item["title"].string, limit: 120)
            if title.isEmpty { title = String(text.prefix(60)) }
            let replaces = item["replaces"].number.flatMap { $0 == $0.rounded() && $0 >= 1 && $0 < 10_000 ? Int($0) : nil }
            answer.notes.append(.init(type: noteType(item["type"].string), title: title, text: text, replaces: replaces,
                                      short: DeckMemoryShortTitle.cleaned(item["short"].string)))
        }
        for item in (value["topics"].elements ?? []).prefix(maximumTopics) {
            let title = clean(item["title"].string, limit: 120), text = clean(item["text"].string, limit: 4_000)
            guard !title.isEmpty, !text.isEmpty else { continue }
            answer.topics.append(.init(title: title, text: text))
        }
        return answer
    }

    /// The first complete JSON object in the text.
    static func object(in raw: String) throws -> NativeRPCValue {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = try? NativeRPCValue.parseJSON(Data(text.utf8)), value.fields != nil { return value }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let value = try? NativeRPCValue.parseJSON(Data(text[start...end].utf8)), value.fields != nil else {
            throw NativeRPCError(code: "malformed", message: "The helper did not answer in the agreed form.")
        }
        return value
    }
    static func clean(_ text: String?, limit: Int) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) : trimmed
    }
}

/// Runs the helper through the AI app the person is already signed in to: Claude Code
/// (`claude --print`), Codex (`codex exec`) or Gemini (`gemini -p`). No key, no new service.
/// The run has no tools, loads no settings or hooks, keeps no conversation on disk, and
/// works in an empty folder of the app's own.
public struct DeckMemoryFlowCLIRunner: DeckMemoryFlowHelperRunning {
    public static let names = ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini"]
    private let providers: BackendNativeProviders
    private let workFolder: URL
    private let environment: [String: String]
    private let launch: BackendRoutinesLaunch
    public init(providers: BackendNativeProviders, workFolder: URL,
                environment: [String: String] = ProcessInfo.processInfo.environment, launch: BackendRoutinesLaunch? = nil) {
        self.providers = providers; self.workFolder = workFolder; self.environment = environment
        self.launch = launch ?? BackendRoutinesNativeLauncher.launch
    }

    /// A model name only makes sense for the AI it belongs to: "sonnet" given to Codex would fail every run.
    public static func model(_ model: String, for ai: String) -> String {
        let name = model.trimmingCharacters(in: .whitespaces).lowercased()
        let claude = ["sonnet", "opus", "haiku", "fable", "opusplan"].contains { name == $0 || name.hasPrefix($0 + "[") } || name.hasPrefix("claude")
        switch ai {
        case "claude": return name.isEmpty || !(claude) ? "sonnet" : model
        case "codex": return claude || name.hasPrefix("gemini") ? "" : model
        case "gemini": return name.hasPrefix("gemini") ? model : ""
        default: return ""
        }
    }

    /// The command line for one AI. `answerFile` is where Codex writes its last message.
    public static func arguments(_ request: DeckMemoryFlowHelperRequest, answerFile: String) -> (arguments: [String], stdin: String)? {
        let whole = request.system + "\n\n" + request.prompt
        switch request.ai {
        case "claude":
            return (["--print", "--output-format", "json", "--model", request.model.isEmpty ? "sonnet" : request.model,
                     "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                     "--disable-slash-commands", "--system-prompt", request.system], request.prompt)
        case "codex":
            return (["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only"]
                    + (request.model.isEmpty ? [] : ["-m", request.model]) + ["-o", answerFile, "-"], whole)
        case "gemini":
            return ((request.model.isEmpty ? [] : ["-m", request.model])
                    + ["-p", "Follow the instructions given on standard input. Answer with the JSON object only."], whole)
        default: return nil
        }
    }

    /// Which of the three AI apps are installed here.
    public func installed() async -> [String] {
        guard let path = try? await providers.loginPath() else { return [] }
        return ["claude", "codex", "gemini"].filter { BackendNativeProviders.lookup($0, path: path) != nil }
    }

    public func run(_ request: DeckMemoryFlowHelperRequest) async throws -> DeckMemoryFlowHelperReply {
        let name = Self.names[request.ai] ?? request.ai
        let path = try await providers.loginPath()
        guard let command = BackendNativeProviders.lookup(request.ai, path: path) else {
            throw NativeRPCError(code: "unavailable", message: "\(name) is not installed on this Mac, so the note helper cannot use it.")
        }
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let answerFile = workFolder.appendingPathComponent("answer-" + UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: answerFile) }
        guard let plan = Self.arguments(request, answerFile: answerFile.path) else {
            throw NativeRPCError(code: "unsupported", message: "The note helper can run on Claude Code, Codex or Gemini.")
        }
        // Never a child of the app's own sessions: no session id, no parent run identity.
        var env = BackendSessionEnvironment.stripInherited(environment)
        env["PATH"] = path
        // Marked, so no hook or capture ever treats the helper's own run as a conversation.
        env[DeckMemoryFlowNames.helperRunVariable] = "1"
        let result = try await launch(.init(command: command, args: plan.arguments, cwd: workFolder.path, env: env, stdin: plan.stdin,
                                            cancellation: BackendMCPCancellation(), timeoutMs: request.timeoutMilliseconds))
        let said = Self.firstLine(result.stderr)
        switch request.ai {
        case "claude":
            guard let value = try? NativeRPCValue.parseJSON(Data(result.stdout.utf8)), value.fields != nil else {
                throw NativeRPCError(code: "failed", message: Self.failure(name, code: result.code, said: said.isEmpty ? Self.firstLine(result.stdout) : said))
            }
            let text = value["result"].string ?? ""
            if value["is_error"].bool == true || text.isEmpty {
                throw NativeRPCError(code: "failed", message: Self.failure(name, code: result.code, said: text.isEmpty ? said : Self.firstLine(text)))
            }
            let usage = value["usage"]
            let read = [usage["input_tokens"], usage["cache_creation_input_tokens"], usage["cache_read_input_tokens"]].compactMap(\.number).reduce(0, +)
            return .init(text: text, inputTokens: usage.fields == nil ? nil : Int(read), outputTokens: usage["output_tokens"].number.map { Int($0) })
        case "codex":
            let text = (try? String(contentsOf: answerFile, encoding: .utf8)) ?? ""
            guard result.code == 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeRPCError(code: "failed", message: Self.failure(name, code: result.code, said: said))
            }
            return .init(text: text)
        default:
            guard result.code == 0, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeRPCError(code: "failed", message: Self.failure(name, code: result.code, said: said))
            }
            return .init(text: result.stdout)
        }
    }
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(240))
    }
    static func failure(_ name: String, code: Int?, said: String) -> String {
        let lower = said.lowercased()
        if lower.contains("login") || lower.contains("log in") || lower.contains("sign in") || lower.contains("unauthor") || lower.contains("credential") || lower.contains("api key") {
            return "\(name) is not signed in, so the note helper could not run. Sign in to \(name) and it will catch up by itself."
        }
        if lower.contains("limit") || lower.contains("quota") || lower.contains("overloaded") {
            return "\(name) is at its usage limit right now. The note helper will try again later."
        }
        if code == nil { return "\(name) did not answer in time. The note helper will try again later." }
        return "\(name) could not answer (\(said.isEmpty ? "exit \(code ?? -1)" : said))."
    }
}
