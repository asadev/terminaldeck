import Foundation
import TerminalDeckNativeCore

/// The agent-controls owner the native graph did not have (INT-A, 7 Oct 2026).
///
/// A whole port of src/main/agent-controls.ts: `readControls` (:1587),
/// `applyControl` (:2403) and `discoverModels` (:2682), over the same four
/// things host-core.ts:2678 hands that module as its `SessionAccess` — the
/// session's PTY screen and write, the session's own Claude config directory,
/// and the ledger's remembered model. One owner serves `agents.controls`,
/// `agents.models`, `agents.set_control` and the task driver's
/// `setAgentControl`, so a tool and a task can never be two ways of typing
/// `/model` into somebody's terminal.
public protocol BackendCompositionAgentControlsOwning: Sendable {
    /// agent-controls.ts:1587 readControls → ControlsReading. Passive: nothing is typed.
    func read(sessionID: String?, cwd: String?, provider: String?, onThisMachine: Bool) async -> NativeRPCValue
    /// agent-controls.ts:2682 discoverModels → { models, message }. Opens and cancels `/model`.
    func models(sessionID: String, provider: String?) async throws -> NativeRPCValue
    /// agent-controls.ts:2403 applyControl → { ok, message, reading }.
    func apply(sessionID: String, cwd: String?, control: String, value: String, provider: String?, onThisMachine: Bool) async throws -> NativeRPCValue
    /// host-core.ts:2759 `controls.apply`: cwd and provider looked up per call from the session table.
    @discardableResult func setAgentControl(sessionID: String, control: String, value: String) async throws -> NativeRPCValue
}

public struct BackendCompositionDeckToolsAgentControls: BackendCompositionAgentControlsOwning, Sendable {
    /// agent-controls.ts:1753 ApplyTimings.
    public struct Timings: Sendable {
        public let poll: Int, echo: Int, command: Int, cycleStep: Int
        public init(poll: Int, echo: Int, command: Int, cycleStep: Int) {
            self.poll = poll; self.echo = echo; self.command = command; self.cycleStep = cycleStep
        }
        /// agent-controls.ts:1764 SHIPPED_TIMINGS.
        public static let shipped = Timings(poll: 120, echo: 2500, command: 6000, cycleStep: 2500)
    }

    /// agent-controls.ts:328 SessionAccess, plus the session-table lookup
    /// host-core.ts:2759 makes for `controls.apply`.
    public struct Access: Sendable {
        /// Type into the session's terminal, exactly as a person would. A write
        /// to a session that is gone is dropped, as `PtyManager.write` drops it.
        public let write: @Sendable (_ sessionID: String, _ data: String) async -> Void
        /// The visible screen once everything written has been parsed, or nil when there is no such session.
        public let screen: @Sendable (_ sessionID: String) async -> String?
        /// The session's own row (cwd, provider), or nil.
        public let session: @Sendable (_ sessionID: String) async -> BackendSessionMeta?
        /// session-account.ts establishedConfigDir: nil keeps every file fallback on the app's own Claude directory.
        public let configDir: (@Sendable (_ sessionID: String) async -> String?)?
        /// Remember a model only after the CLI confirmed the person's selection.
        public let rememberModel: (@Sendable (_ sessionID: String, _ model: String) async -> Void)?
        public init(write: @escaping @Sendable (_ sessionID: String, _ data: String) async -> Void,
                    screen: @escaping @Sendable (_ sessionID: String) async -> String?,
                    session: @escaping @Sendable (_ sessionID: String) async -> BackendSessionMeta?,
                    configDir: (@Sendable (_ sessionID: String) async -> String?)?,
                    rememberModel: (@Sendable (_ sessionID: String, _ model: String) async -> Void)?) {
            self.write = write; self.screen = screen; self.session = session; self.configDir = configDir; self.rememberModel = rememberModel
        }
        /// host-core.ts:2678 controlAccess over the native owners: `ptys.write`/`ptys.screen`
        /// → BackendPTYManager, `establishedConfigDir` → BackendAccountAttribution,
        /// `ledger.update(id, { model })` → the Store's open-session ledger.
        public static func local(manager: BackendPTYManager, attribution: BackendAccountAttribution, store: NativeStateStore) -> Access {
            Access(write: { id, data in _ = try? manager.write(id, data: data) },
                   screen: { id in manager.screen(id) },
                   session: { id in manager.list().first { $0.id == id } },
                   configDir: { id in await attribution.establishedConfigDir(sessionID: id) },
                   rememberModel: { id, model in _ = try? await store.ledgerUpdate(id, patch: .object([.init("model", .string(model))])) })
        }
    }

    public let access: Access
    /// Owner-wide transcript stores with the app's own Claude directory as primary
    /// (transcript.ts transcriptDirs: primary + paired-device homes, home-scoped).
    /// Its `configDirectory` is also `claudeConfigDir()` for the settings fallbacks.
    public let transcripts: NativeTranscriptScope
    private let environment: [String: String]
    private let timings: Timings

    public init(access: Access, transcripts: NativeTranscriptScope, environment: [String: String], timings: Timings = .shipped) {
        self.access = access; self.transcripts = transcripts; self.environment = environment; self.timings = timings
    }

    /// transcript.ts configDirs(): `claudeConfigDir()` first, paired-device homes,
    /// the copilot's scoped home — and NOT the profile stores, which
    /// `readModelFromTranscript` reaches only through the session's own configDir.
    public static func transcriptScope(configuration: BackendAccountConfiguration, dataRoot: URL) -> NativeTranscriptScope {
        var scope = NativeTranscriptScope(configDirectory: configuration.systemDirectory("claude"),
            deviceHomesRoot: dataRoot.appendingPathComponent("remote/device-home").path, homeScopes: configuration.homeScopes)
        scope.homeScopes.append(BackendCopilotSessionRuntime.homeScope(userData: dataRoot.path))
        return scope
    }

    private var claudeConfigDirectory: String { transcripts.configDirectory }

    // MARK: - Public operations

    public func read(sessionID: String?, cwd: String?, provider: String?, onThisMachine: Bool = true) async -> NativeRPCValue {
        await readControls(sessionID: sessionID, cwd: cwd, provider: provider, local: onThisMachine)
    }

    /// Runs to completion even if the asking call is cancelled: the TS has no
    /// cancellation here, and stopping between the clear and the put-back would
    /// strand the person's draft — the one outcome this module exists to prevent.
    public func models(sessionID: String, provider: String?) async throws -> NativeRPCValue {
        let owner = self
        return try await Task { try await owner.discoverModels(sessionID: sessionID, provider: provider) }.value
    }

    public func apply(sessionID: String, cwd: String?, control: String, value: String, provider: String?, onThisMachine: Bool = true) async throws -> NativeRPCValue {
        let owner = self
        return try await Task {
            try await owner.applyControl(sessionID: sessionID, cwd: cwd, control: control, value: value, provider: provider, local: onThisMachine).wire
        }.value
    }

    @discardableResult
    public func setAgentControl(sessionID: String, control: String, value: String) async throws -> NativeRPCValue {
        let row = await access.session(sessionID)
        return try await apply(sessionID: sessionID, cwd: row?.cwd, control: control, value: value, provider: row?.provider, onThisMachine: true)
    }
}

// MARK: - Readings (agent-controls.ts:135-330)

extension BackendCompositionDeckToolsAgentControls {
    struct Reading: Equatable, Sendable {
        var value: String? = nil
        var label: String? = nil
        var source: String? = nil
        var unavailableReason: String? = nil
        static let unknown = Reading()
        var wire: NativeRPCValue {
            var fields: [NativeRPCValue.Field] = [.init("value", value.map(NativeRPCValue.string) ?? .null),
                .init("label", label.map(NativeRPCValue.string) ?? .null), .init("source", source.map(NativeRPCValue.string) ?? .null)]
            if let unavailableReason { fields.append(.init("unavailableReason", .string(unavailableReason))) }
            return .object(fields)
        }
    }
    struct Presence: Sendable {
        let running: Bool, evidence: String?, saw: String?
        static let absent = Presence(running: false, evidence: nil, saw: nil)
        static func screen(_ saw: String?) -> Presence { saw.map { Presence(running: true, evidence: "screen", saw: $0) } ?? .absent }
        var wire: NativeRPCValue {
            .object([.init("running", .bool(running)), .init("evidence", evidence.map(NativeRPCValue.string) ?? .null),
                .init("saw", saw.map(NativeRPCValue.string) ?? .null)])
        }
    }
    enum Composer: Equatable, Sendable { case ready, typing(String), choosing(String), working(String), unknown }
    enum Carry: Equatable, Sendable { case clear, carry(String), refuse(String) }
    enum Typed: Sendable { case ok, failed(String) }
    struct Answer: Sendable { let ok: Bool; let text: String; let scope: String? }
    struct Outcome: Sendable {
        let ok: Bool, message: String, reading: Reading
        var wire: NativeRPCValue { .object([.init("ok", .bool(ok)), .init("message", .string(message)), .init("reading", reading.wire)]) }
    }
}

/// runCommand's answer, carryDraft's answer, and runCommand's first wait —
/// file-scope because Swift does not nest types in generic functions.
enum BackendAgentControlsCommand<T: Sendable>: Sendable { case answered(T), failed(String) }
enum BackendAgentControlsCarried<T: Sendable>: Sendable { case ran(T, note: String), refused(String) }
enum BackendAgentControlsStep<T: Sendable>: Sendable { case done(T), dialog(String) }
enum BackendAgentControlsFast: Sendable { case answered(BackendCompositionDeckToolsAgentControls.Reading?), failed(String) }
enum BackendAgentControlsPlan: Sendable { case landed(String?), failed(String) }

// MARK: - Screen reading (agent-controls.ts:440-1240), pure

extension BackendCompositionDeckToolsAgentControls {
    /// agent-controls.ts:400 PERMISSION_MODES, in shift+tab order.
    static var permissionModes: [(id: String, label: String, phrase: String)] { [
        ("auto", "Auto", "auto mode on"), ("manual", "Manual", "manual mode on"), ("acceptEdits", "Accept edits", "accept edits on"),
        ("plan", "Plan", "plan mode on"), ("bypass", "Bypass", "bypass permissions on"),
    ] }
    /// agent-controls.ts:415 EFFORT_LEVELS.
    static var effortLevels: [(id: String, label: String)] { [
        ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra high"), ("max", "Max"), ("ultracode", "Ultracode"), ("auto", "Auto"),
    ] }
    /// agent-controls.ts:957 SCOPE_TEXT.
    static func scopeText(_ scope: String) -> String { scope == "default" ? "saved as your default for new sessions" : "this session only" }
    static func permissionLabel(_ id: String) -> String { permissionModes.first(where: { $0.id == id })?.label ?? id }

    /// agent-controls.ts:1806 CLEAR_COMPOSER (ctrl+u).
    static let clearComposer = "\u{15}"
    /// agent-controls.ts:720 POINTER, :731 CHOICE_LINE, :734 COMPOSER_LINE, :1058 STATUS_RULE.
    static let choiceLine = #"^[❯>]\s*\d+\.\s+\S"#
    static let composerLine = #"^[❯>](.*)$"#
    static let statusRule = #"^─{10,}.*─$"#
    /// agent-controls.ts:632 WORKING_ON_SCREEN. The third arm's `\S` is one
    /// UTF-16 unit in JavaScript, so an astral first character never matches it.
    static var workingOnScreen: [(String, NSRegularExpression.Options)] { [
        (#"esc to interrupt"#, [.caseInsensitive]),
        (#"\(\s*\d+s\s*·\s*[↑↓][^)]*\)"#, []),
        (#"^(?![⏺⎿❯>│╭╰])[^\s\x{10000}-\x{10FFFF}]\s+[A-Za-z][A-Za-z-]*…"#, []),
    ] }
    /// agent-controls.ts:1161 COMMAND_ERRORS, flags kept (all /gi, one /gim).
    static var commandErrors: [(String, NSRegularExpression.Options)] { [
        (#"Model '[^']*' not found[^\n]*"#, [.caseInsensitive]),
        (#"Model '[^']*' is not in the list of available models"#, [.caseInsensitive]),
        (#"Model '[^']*' is restricted by your organization's settings[^\n]*"#, [.caseInsensitive]),
        (#"(?:^|(?<=⎿ {1,3}))[A-Z][A-Za-z0-9 .+-]{0,40} isn't available for your account yet\.[^\n]*"#, [.caseInsensitive, .anchorsMatchLines]),
        (#"Failed to validate model:[^\n]*"#, [.caseInsensitive]),
        (#"Invalid argument:[^\n]*"#, [.caseInsensitive]),
        (#"Unknown model '[^']*'"#, [.caseInsensitive]),
        (#"Fast mode unavailable:[^\n]*"#, [.caseInsensitive]),
        (#"Failed to set effort level:[^\n]*"#, [.caseInsensitive]),
        (#"Effort '[^']*' exceeds your organization's limit[^\n]*"#, [.caseInsensitive]),
        (#"Ultracode [^\n]*Valid options are:[^\n]*"#, [.caseInsensitive]),
        (#"(?:Cleared effort from settings|Effort set to auto for this session), but CLAUDE_CODE_EFFORT_LEVEL=[^\n]*"#, [.caseInsensitive]),
        (#"Not applied:[^\n]*"#, [.caseInsensitive]),
    ] }

    /// session-activity.ts stripAnsi.
    static func stripAnsi(_ input: String) -> String {
        guard input.unicodeScalars.contains(where: { $0 == "\u{1B}" || $0 == "\r" }) else { return input }
        var text = input
        for pattern in [#"\x1b\[[0-9;?]*[ -/]*[@-~]"#, #"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"#, #"\x1b[()#][0-9A-Za-z]"#, #"\x1b."#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text.replacingOccurrences(of: "\r", with: "\n", options: .literal)
    }
    /// agent-controls.ts:444 — non-empty trimmed lines, oldest first.
    static func lines(_ screen: String) -> [String] {
        stripAnsi(screen).components(separatedBy: "\n").map(BackendSharedText.trim).filter { !$0.isEmpty }
    }
    static func composerText(_ line: String) -> String? {
        guard let match = Pattern.first(line, composerLine) else { return nil }
        return Pattern.group(line, match, 1)
    }
    /// agent-controls.ts:459.
    static func readPermissionMode(_ screen: String) -> String? {
        for line in lines(screen).suffix(5).reversed() {
            for mode in permissionModes where line.range(of: mode.phrase, options: .caseInsensitive) != nil { return mode.id }
        }
        return nil
    }
    /// agent-controls.ts:514 (AGENT_ON_SCREEN :481, FOOTER_HINT :501).
    static func readAgentFromScreen(_ screen: String) -> String? {
        for line in lines(screen) {
            if Pattern.test(line, #"╭─+\s*Claude Code v\d"#) || line.range(of: "esc to interrupt", options: .caseInsensitive) != nil { return line }
            if Pattern.test(line, #"\(shift\+tab to cycle\)|\? for shortcuts"#, [.caseInsensitive]),
               permissionModes.contains(where: { line.range(of: $0.phrase, options: .caseInsensitive) != nil }) { return line }
        }
        return nil
    }
    /// agent-controls.ts:736.
    static func readComposer(_ screen: String) -> Composer {
        let all = lines(screen)
        for line in all where Pattern.test(line, choiceLine) { return .choosing(line) }
        for line in all {
            for (pattern, options) in workingOnScreen where Pattern.test(line, pattern, options) { return .working(line) }
        }
        for line in all.reversed() {
            guard let raw = composerText(line) else { continue }
            let text = BackendSharedText.trim(raw)
            return text.isEmpty ? .ready : .typing(text)
        }
        return .unknown
    }
    /// agent-controls.ts:832 readSwitchDialog.
    static func readSwitchDialog(_ screen: String) -> (kind: String, target: String, asking: String)? {
        let all = lines(screen)
        let headings = [("model", #"^Switch model\?$"#), ("effort", #"^Change effort level\?$"#)]
        guard let heading = headings.first(where: { entry in all.contains { Pattern.test($0, entry.1, [.caseInsensitive]) } }) else { return nil }
        for line in all {
            if let match = Pattern.first(line, #"^❯\s*1\.\s*Yes,\s*switch to\s+(.+?)$"#, [.caseInsensitive]), let target = Pattern.group(line, match, 1) {
                return (heading.0, BackendSharedText.trim(target), line)
            }
        }
        return nil
    }
    /// agent-controls.ts:857 countMatches and the three counters.
    static func countMatches(_ screen: String, _ pattern: String, _ options: NSRegularExpression.Options) -> Int {
        Pattern.matches(lines(screen).joined(separator: "\n"), pattern, options).count
    }
    static func countModelConfirmations(_ screen: String) -> Int { countMatches(screen, #"(?:Set model to|Kept model as)\s+\S"#, [.caseInsensitive]) }
    static func countEffortConfirmations(_ screen: String) -> Int { countMatches(screen, #"(?:Set effort level to|Effort level set to)\s+\S"#, [.caseInsensitive]) }
    static func countFastAnnouncements(_ screen: String) -> Int { countMatches(screen, #"Fast mode (?:ON|OFF|unavailable|is not available)"#, [.caseInsensitive]) }

    /// agent-controls.ts:914 refuseByProvider. `provider == nil` is the shell
    /// somebody typed an agent into: the screen decides.
    static func refuseByProvider(_ provider: String?, _ agent: Presence) -> String? {
        if provider == "claude" { return nil }
        if provider == "shell" { return "This session is a shell, not an agent CLI, so there is nothing in it to set a model on." }
        guard let provider else {
            return agent.running ? nil : "Nothing on this session’s screen says Claude Code is running in it, and these controls are Claude Code’s commands."
        }
        let named = provider == "codex" ? "Codex" : provider == "gemini" ? "Gemini" : provider
        return "These type Claude Code’s own commands into the session. How \(named) changes this at runtime has not been established, so nothing is sent rather than something being guessed at."
    }
    /// agent-controls.ts:941 scopeOf.
    static func scopeOf(_ tail: String) -> String? {
        if tail.range(of: "saved as your default", options: .caseInsensitive) != nil { return "default" }
        if Pattern.test(tail, #"\bthis session\b"#, [.caseInsensitive]) { return "session" }
        return nil
    }
    /// agent-controls.ts:975 readModelConfirmation.
    static func readModelConfirmation(_ screen: String) -> (name: String, scope: String?)? {
        let text = lines(screen).joined(separator: "\n")
        let found = Pattern.matches(text, #"(?:Set model to|Kept model as)\s+(.+?)(?:\s+and saved\b|\s+for this session only\b|$)([^\n]*)"#,
            [.caseInsensitive, .anchorsMatchLines])
        guard let last = found.last, let raw = Pattern.group(text, last, 1) else { return nil }
        let name = BackendSharedText.trim(raw)
        guard !name.isEmpty else { return nil }
        return (name, scopeOf(Pattern.group(text, last, 0) ?? ""))
    }
    static func readModelFromScreen(_ screen: String) -> String? { readModelConfirmation(screen)?.name }
    /// agent-controls.ts:1006 readEffortConfirmation.
    static func readEffortConfirmation(_ screen: String) -> (level: String, scope: String?)? {
        let text = lines(screen).joined(separator: "\n")
        let found = Pattern.matches(text, #"(?:Set effort level to\s+([a-z]+)|Effort level set to\s+(auto))([^\n]*)"#, [.caseInsensitive])
        guard let last = found.last, let level = Pattern.group(text, last, 1) ?? Pattern.group(text, last, 2) else { return nil }
        return (level.lowercased(), scopeOf(Pattern.group(text, last, 0) ?? ""))
    }
    static func readEffortFromScreen(_ screen: String) -> String? { readEffortConfirmation(screen)?.level }
    /// agent-controls.ts:1077 readFastIndicator: the `↯` in the rule above the command line.
    static func readFastIndicator(_ screen: String) -> String? {
        let all = lines(screen)
        guard let composer = all.lastIndex(where: { composerText($0) != nil }), composer >= 1 else { return nil }
        for index in stride(from: composer - 1, through: max(0, composer - 3), by: -1) where Pattern.test(all[index], statusRule) {
            return all[index].contains("↯") ? "on" : "off"
        }
        return nil
    }
    /// agent-controls.ts:1101 readFastFromScreen.
    static func readFastFromScreen(_ screen: String) -> Reading? {
        let text = lines(screen).joined(separator: "\n")
        if let refused = Pattern.first(text, #"Fast mode (?:unavailable|is not available)[:.]?\s*(.*)$"#, [.caseInsensitive, .anchorsMatchLines]) {
            let reason = BackendSharedText.trim(Pattern.group(text, refused, 1) ?? "")
            return Reading(value: "off", label: "Off", source: "screen", unavailableReason: reason.isEmpty ? "Fast mode is not available on this account" : reason)
        }
        guard let last = Pattern.matches(text, #"Fast mode (ON|OFF)\b"#).last, let state = Pattern.group(text, last, 1) else { return nil }
        let on = state == "ON"
        return Reading(value: on ? "on" : "off", label: on ? "On" : "Off", source: "screen")
    }
    /// agent-controls.ts:1138 readFast.
    static func readFast(_ screen: String) -> Reading? {
        let announced = readFastFromScreen(screen)
        guard let now = readFastIndicator(screen) else { return announced }
        var reading = Reading(value: now, label: now == "on" ? "On" : "Off", source: "screen")
        if now == "off", let reason = announced?.unavailableReason { reading.unavailableReason = reason }
        return reading
    }
    /// agent-controls.ts:1201 readCommandError: the LAST refusal on the screen.
    static func readCommandError(_ screen: String) -> String? {
        let text = lines(screen).joined(separator: "\n")
        var best: (at: Int, text: String)?
        for (pattern, options) in commandErrors {
            for hit in Pattern.matches(text, pattern, options) where best == nil || hit.range.location >= best!.at {
                best = (hit.range.location, BackendSharedText.trim((text as NSString).substring(with: hit.range)))
            }
        }
        return best?.text
    }
    /// agent-controls.ts:1232 countCommandErrors.
    static func countCommandErrors(_ screen: String) -> Int {
        let text = lines(screen).joined(separator: "\n")
        return commandErrors.reduce(0) { $0 + Pattern.matches(text, $1.0, $1.1).count }
    }
    /// agent-controls.ts:1508 readModelFromWelcome.
    static func readModelFromWelcome(_ screen: String) -> String? {
        for line in lines(screen) {
            if let match = Pattern.first(line, #"│\s*(\S.*?)\s+with\s+\S+(?:\s+effort)?\s*·"#), let name = Pattern.group(line, match, 1) {
                return BackendSharedText.trim(name)
            }
        }
        return nil
    }

    /// agent-controls.ts:1829 refuseToType — the long register, after a press.
    static func refuseToType(_ state: Composer) -> String? {
        switch state {
        case .ready: return nil
        case .working: return "This session is mid-turn. A command typed now would land in whatever it asks next rather than on the command line, so nothing was sent — try again once it has finished."
        case .choosing(let asking): return "This session is waiting on a choice (“\(asking)”). Pressing return now would answer it instead of running a command, so nothing was sent."
        case .typing(let text): return "There is unsent text at this session’s prompt (“\(text)”). A command typed now would run into the middle of it, so nothing was sent — clear the prompt and pick again."
        case .unknown: return "This session’s prompt is not on screen, so there is nowhere to type that could be checked first."
        }
    }
    /// agent-controls.ts:1891 draftIsWhole.
    static func draftIsWhole(_ all: [String], _ composerAt: Int) -> Bool {
        composerAt + 1 >= all.count || Pattern.test(all[composerAt + 1], statusRule)
    }
    /// agent-controls.ts:1899 composerRow, from the bottom.
    static func composerRow(_ all: [String]) -> Int { all.lastIndex { composerText($0) != nil } ?? -1 }
    /// agent-controls.ts:1928 readCarry, with :1920 SHORT_REFUSAL.
    static func readCarry(_ screen: String) -> Carry {
        switch readComposer(screen) {
        case .ready: return .clear
        case .working: return .refuse("This session is mid-turn.")
        case .choosing: return .refuse("This session is waiting on an answer on screen.")
        case .unknown: return .refuse("This session’s prompt is not on screen.")
        case .typing(let draft):
            let all = lines(screen), at = composerRow(all)
            if at == -1 || !draftIsWhole(all, at) { return .refuse("A multi-line draft is sitting at this prompt.") }
            return .carry(draft)
        }
    }
    /// agent-controls.ts:1959 promptIsFree.
    static func promptIsFree(_ screen: String) -> Bool {
        let all = lines(screen)
        if all.contains(where: { Pattern.test($0, choiceLine) }) { return false }
        let at = composerRow(all)
        guard at != -1, let text = composerText(all[at]) else { return false }
        return BackendSharedText.trim(text).isEmpty
    }
    /// agent-controls.ts:2017 withNote.
    static func withNote(_ message: String, _ note: String) -> String { note.isEmpty ? message : message + " " + note }

    /// JavaScript-faithful regex helpers (BackendSharedText.javascriptPattern maps \s \S \d \b).
    /// Compiled per call: NSRegularExpression is not stored across concurrency domains.
    enum Pattern {
        static func compile(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: BackendSharedText.javascriptPattern(pattern), options: options)
        }
        static func matches(_ text: String, _ pattern: String, _ options: NSRegularExpression.Options = []) -> [NSTextCheckingResult] {
            guard let regex = compile(pattern, options) else { return [] }
            return regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
        }
        static func first(_ text: String, _ pattern: String, _ options: NSRegularExpression.Options = []) -> NSTextCheckingResult? {
            compile(pattern, options)?.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count))
        }
        static func test(_ text: String, _ pattern: String, _ options: NSRegularExpression.Options = []) -> Bool { first(text, pattern, options) != nil }
        static func group(_ text: String, _ match: NSTextCheckingResult, _ index: Int) -> String? {
            guard index < match.numberOfRanges else { return nil }
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return nil }
            return (text as NSString).substring(with: range)
        }
    }
}

// MARK: - Settings and transcript reading (agent-controls.ts:1243-1546)

extension BackendCompositionDeckToolsAgentControls {
    /// agent-controls.ts:1252 readSettingsFile: an object, or {} when missing or broken.
    static func readSettingsFile(_ path: String) -> NativeRPCValue {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? NativeRPCValue.parseJSON(data), parsed.fields != nil else { return .object([]) }
        return parsed
    }
    /// agent-controls.ts:1248 readClaudeSettings(configDir = claudeConfigDir()).
    func readClaudeSettings(_ configDir: String?) -> NativeRPCValue {
        Self.readSettingsFile(URL(fileURLWithPath: configDir ?? claudeConfigDirectory).appendingPathComponent("settings.json").path)
    }
    /// agent-controls.ts:1281 SETTINGS_PERMISSION_MODES: six names known, `dontAsk` known but unreachable.
    static let settingsPermissionNames: Set<String> = ["acceptEdits", "auto", "bypassPermissions", "manual", "plan", "dontAsk"]
    static let settingsPermissionModes: [String: String] = ["acceptEdits": "acceptEdits", "auto": "auto", "bypassPermissions": "bypass", "manual": "manual", "plan": "plan"]
    /// agent-controls.ts:1317 readPermissionDefault: local over project over user, first file that names a mode.
    func readPermissionDefault(cwd: String?, configDir: String?) -> Reading {
        var files: [String] = []
        if let cwd, !cwd.isEmpty {
            let folder = URL(fileURLWithPath: cwd).appendingPathComponent(".claude")
            files += [folder.appendingPathComponent("settings.local.json").path, folder.appendingPathComponent("settings.json").path]
        }
        files.append(URL(fileURLWithPath: configDir ?? claudeConfigDirectory).appendingPathComponent("settings.json").path)
        for file in files {
            let permissions = Self.readSettingsFile(file)["permissions"]
            guard permissions.fields != nil, let named = permissions["defaultMode"].string else { continue }
            // A name this build does not know is not guessed at.
            guard Self.settingsPermissionNames.contains(named), let id = Self.settingsPermissionModes[named] else { return .unknown }
            return Reading(value: id, label: Self.permissionLabel(id), source: "settings")
        }
        return .unknown
    }
    /// agent-controls.ts:1355 effortFromSettings.
    static func effortFromSettings(_ settings: NativeRPCValue) -> Reading {
        if settings["ultracode"].bool == true { return Reading(value: "ultracode", label: "Ultracode", source: "settings") }
        let level = settings["effortLevel"].string?.lowercased() ?? ""
        guard let known = effortLevels.first(where: { $0.id == level }) else { return .unknown }
        return Reading(value: known.id, label: known.label, source: "settings")
    }
    /// agent-controls.ts:1379 fastFromSettings: only if the file actually says.
    static func fastFromSettings(_ settings: NativeRPCValue) -> Reading {
        guard let on = settings["fastMode"].bool else { return .unknown }
        return Reading(value: on ? "on" : "off", label: on ? "On" : "Off", source: "settings")
    }
    /// agent-controls.ts:1535 modelFromSettings.
    static func modelFromSettings(_ settings: NativeRPCValue) -> Reading {
        guard let raw = settings["model"].string, !BackendSharedText.trim(raw).isEmpty else { return .unknown }
        let alias = BackendSharedText.trim(raw)
        let row = BackendSharedModelCatalog.foldDefaultRow(BackendSharedModelCatalog.fallbackModels).first { $0.alias == alias }
        let label = row?.model ?? (alias.hasPrefix("claude-") ? BackendCompositionSuppliers.modelLabel(alias) : alias)
        return Reading(value: alias, label: label, source: "settings")
    }
    /// agent-controls.ts:1409 readModelFromTranscript: the newest transcript
    /// across every store (the session's own store replacing the primary one),
    /// walked back at most 4000 lines to the newest assistant line a real model served.
    func readModelFromTranscript(cwd: String, configDir: String?) -> String? {
        var scope = transcripts
        if let configDir { scope.configDirectory = configDir }
        guard let newest = try? NativeTranscriptPaths.newest(cwd, scope: scope),
              let data = try? Data(contentsOf: URL(fileURLWithPath: newest.path), options: .alwaysMapped) else { return nil }
        return Self.newestModel(in: data)
    }
    static func newestModel(in data: Data) -> String? {
        let needle = Array(#""model""#.utf8)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            var end = raw.count, examined = 0
            while examined < 4000 {
                var start = end
                while start > 0 && raw[start - 1] != 10 { start -= 1 }
                examined += 1
                let line = UnsafeRawBufferPointer(rebasing: raw[start..<end])
                if Self.bytesContain(line, needle), let model = Self.assistantModel(Data(line)) { return model }
                if start == 0 { break }
                end = start - 1
            }
            return nil
        }
    }
    private static func bytesContain(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard line.count >= needle.count else { return false }
        for offset in 0...(line.count - needle.count) {
            var hit = true
            for index in 0..<needle.count where line[offset + index] != needle[index] { hit = false; break }
            if hit { return true }
        }
        return false
    }
    /// One transcript line: `type: "assistant"`, `message.model`, never `<synthetic>`.
    private static func assistantModel(_ line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
              let model = message["model"] as? String else { return nil }
        let trimmed = BackendSharedText.trim(model)
        return trimmed.isEmpty || trimmed == "<synthetic>" ? nil : trimmed
    }
}

// MARK: - readControls (agent-controls.ts:1587)

extension BackendCompositionDeckToolsAgentControls {
    func readControls(sessionID: String?, cwd: String?, provider: String?, local: Bool) async -> NativeRPCValue {
        // Read once, so every fallback below asks about the same account (agent-controls.ts:1603).
        let store: String?
        if local, let sessionID, let configDir = access.configDir { store = await configDir(sessionID) } else { store = nil }
        let screen: String?
        if let sessionID { screen = await access.screen(sessionID) } else { screen = nil }
        let agent = Presence.screen(screen.flatMap(Self.readAgentFromScreen))
        let gate: NativeRPCValue
        if let screen, case .refuse(let reason) = Self.readCarry(screen) {
            gate = .object([.init("canType", .bool(false)), .init("reason", .string(reason))])
        } else if screen == nil {
            gate = .object([.init("canType", .bool(false)), .init("reason", .string("That session is no longer running."))])
        } else {
            gate = .object([.init("canType", .bool(true)), .init("reason", .null)])
        }
        func reading(model: Reading, effort: Reading, fast: Reading, permission: Reading) -> NativeRPCValue {
            .object([.init("model", model.wire), .init("effort", effort.wire), .init("fast", fast.wire), .init("permission", permission.wire),
                .init("live", .bool(screen != nil)), .init("agent", agent.wire), .init("gate", gate)])
        }
        if let foreign = Self.refuseByProvider(provider, agent) {
            let blocked = Reading(unavailableReason: foreign)
            return reading(model: blocked, effort: blocked, fast: blocked, permission: blocked)
        }
        let permission: Reading
        if let screen, let mode = Self.readPermissionMode(screen) { permission = Reading(value: mode, label: Self.permissionLabel(mode), source: "screen") }
        else { permission = local ? readPermissionDefault(cwd: cwd, configDir: store) : .unknown }
        let settings = local ? readClaudeSettings(store) : .object([])
        let model: Reading
        if let screen, let confirmed = Self.readModelFromScreen(screen) { model = Reading(value: confirmed, label: confirmed, source: "screen") }
        else if let cwd, !cwd.isEmpty, local, let raw = readModelFromTranscript(cwd: cwd, configDir: store) {
            model = Reading(value: raw, label: BackendCompositionSuppliers.modelLabel(raw), source: "transcript")
        } else if let screen, let welcomed = Self.readModelFromWelcome(screen) { model = Reading(value: welcomed, label: welcomed, source: "screen") }
        else { model = Self.modelFromSettings(settings) }
        let effort: Reading
        // This process's environment, which is this machine's (agent-controls.ts:1705).
        let override = local ? BackendSharedText.trim(environment["CLAUDE_CODE_EFFORT_LEVEL"] ?? "").lowercased() : ""
        if !override.isEmpty { effort = Reading(value: override, label: Self.effortLevels.first(where: { $0.id == override })?.label ?? override, source: "env") }
        else if let screen, let confirmed = Self.readEffortFromScreen(screen) {
            effort = Reading(value: confirmed, label: Self.effortLevels.first(where: { $0.id == confirmed })?.label ?? confirmed, source: "screen")
        } else { effort = Self.effortFromSettings(settings) }
        let fast = screen.flatMap(Self.readFast) ?? Self.fastFromSettings(settings)
        return reading(model: model, effort: effort, fast: fast, permission: permission)
    }
}

// MARK: - Applying (agent-controls.ts:1766-2645)

extension BackendCompositionDeckToolsAgentControls {
    /// agent-controls.ts:1771 waitForScreen.
    func waitForScreen<T: Sendable>(_ sessionID: String, _ timeout: Int, _ done: (String) -> T?) async throws -> T? {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(timings.poll))
            guard let screen = await access.screen(sessionID) else { return nil }
            if let answer = done(screen) { return answer }
        }
        return nil
    }
    /// agent-controls.ts:1997 putBackDraft — never with a return.
    func putBackDraft(_ sessionID: String, _ draft: String) async throws -> String {
        let free: Bool? = try await waitForScreen(sessionID, timings.command) { (screen: String) -> Bool? in Self.promptIsFree(screen) ? true : nil }
        guard free != nil else { return "Your draft could not be put back at the prompt — it read “\(draft)”." }
        await access.write(sessionID, BackendSessionSwitchDeferred.replayWrites(draft, submit: false).typed)
        return "Your draft is back at the prompt, unsent."
    }
    /// agent-controls.ts:2065 carryDraft.
    func carryDraft<T: Sendable>(_ sessionID: String, _ run: () async throws -> T) async throws -> BackendAgentControlsCarried<T> {
        guard let screen = await access.screen(sessionID), case .carry(let draft) = Self.readCarry(screen) else {
            let value = try await run()
            return .ran(value, note: "")
        }
        await access.write(sessionID, Self.clearComposer)
        let emptied: Bool? = try await waitForScreen(sessionID, timings.echo) { (screen: String) -> Bool? in Self.promptIsFree(screen) ? true : nil }
        if emptied == nil {
            guard let now = await access.screen(sessionID) else { return .refused("That session is no longer running.") }
            if case .typing(let text) = Self.readComposer(now), text == draft {
                return .refused("This session’s prompt would not clear — it still reads “\(draft)”, so nothing was typed and nothing was changed.")
            }
            if Self.promptIsFree(now) {
                let value = try await run()
                let note = try await putBackDraft(sessionID, draft)
                return .ran(value, note: note)
            }
            return .refused("Cleared this session’s prompt to make room for the command and something else took the keyboard before it could be typed, so nothing was changed. Your draft read “\(draft)” — the CLI’s own Ctrl+Y pastes it back.")
        }
        let value = try await run()
        let note = try await putBackDraft(sessionID, draft)
        return .ran(value, note: note)
    }
    /// agent-controls.ts:2153 typeCommand: the return only once the composer reads back as exactly the command.
    func typeCommand(_ sessionID: String, _ command: String) async throws -> Typed {
        guard let screen = await access.screen(sessionID) else { return .failed("That session is no longer running.") }
        if let refusal = Self.refuseToType(Self.readComposer(screen)) { return .failed(refusal) }
        await access.write(sessionID, command)
        let landed: Bool? = try await waitForScreen(sessionID, timings.echo) { (later: String) -> Bool? in
            if case .typing(let text) = Self.readComposer(later), text == command { return true }
            return nil
        }
        guard landed != nil else {
            await access.write(sessionID, Self.clearComposer)
            return .failed("Typed “\(command)” but it did not appear on this session’s command line, so the return was not sent and the line was cleared again. Nothing was run.")
        }
        await access.write(sessionID, "\r")
        return .ok
    }
    /// agent-controls.ts:2209 runCommand: answers only its own Switch/Change dialog, cursor already on Yes.
    func runCommand<T: Sendable>(_ sessionID: String, _ command: String, kind: String, _ settled: (String) -> T?) async throws -> BackendAgentControlsCommand<T> {
        let typed = try await typeCommand(sessionID, command)
        if case .failed(let message) = typed { return .failed(message) }
        let step: BackendAgentControlsStep<T>? = try await waitForScreen(sessionID, timings.command) { (screen: String) -> BackendAgentControlsStep<T>? in
            if let done = settled(screen) { return .done(done) }
            if let dialog = Self.readSwitchDialog(screen), dialog.kind == kind { return .dialog(dialog.target) }
            return nil
        }
        func stuck() async -> String {
            if let still = Self.readSwitchDialog(await access.screen(sessionID) ?? "") {
                return "The session is asking whether to switch to \(still.target) and has not moved on. Nothing was changed."
            }
            return "Typed \(command) but the CLI has not answered yet."
        }
        guard let step else { return .failed(await stuck()) }
        if case .done(let value) = step { return .answered(value) }
        await access.write(sessionID, "\r")
        guard let after = try await waitForScreen(sessionID, timings.command, settled) else { return .failed(await stuck()) }
        return .answered(after)
    }
    /// agent-controls.ts:2250 cycleOnce: shift+tab is CSI Z.
    func cycleOnce(_ sessionID: String, from: String) async throws -> String? {
        await access.write(sessionID, "\u{1B}[Z")
        return try await waitForScreen(sessionID, timings.cycleStep) { (screen: String) -> String? in
            guard let now = Self.readPermissionMode(screen), now != from else { return nil }
            return now
        }
    }
    /// agent-controls.ts:2297 applyPermission.
    func applyPermission(_ sessionID: String, target: String) async throws -> (ok: Bool, message: String, mode: String?) {
        guard let wanted = Self.permissionModes.first(where: { $0.id == target }) else {
            return (false, "\(target) is not a permission mode this build can reach.", nil)
        }
        guard let screen = await access.screen(sessionID) else { return (false, "That session is no longer running.", nil) }
        let composer = Self.readComposer(screen)
        switch composer {
        case .ready, .typing: break
        default: return (false, Self.refuseToType(composer) ?? "", nil)
        }
        let startedAt = Self.readPermissionMode(screen)
        if let startedAt, startedAt == wanted.id { return (true, "Already in \(wanted.label) mode.", startedAt) }
        if wanted.id == "plan" {
            let carried: BackendAgentControlsCarried<BackendAgentControlsPlan> = try await carryDraft(sessionID) { () async throws -> BackendAgentControlsPlan in
                let typed = try await typeCommand(sessionID, "/plan")
                if case .failed(let message) = typed { return .failed(message) }
                let landed: String? = try await waitForScreen(sessionID, timings.command) { (screen: String) -> String? in Self.readPermissionMode(screen) == "plan" ? "plan" : nil }
                return .landed(landed)
            }
            switch carried {
            case .refused(let message): return (false, message, nil)
            case .ran(.failed(let message), let note): return (false, Self.withNote(message, note), nil)
            case .ran(.landed(let landed), let note):
                if let landed { return (true, Self.withNote("Enabled plan mode.", note), landed) }
                return (false, Self.withNote("Typed /plan but the footer did not change.", note), Self.readPermissionMode(await access.screen(sessionID) ?? ""))
            }
        }
        guard let startedAt else {
            return (false, "The permission footer is not on screen, so the current mode is unknown — cycling from an unknown start would be a guess.", nil)
        }
        var current = startedAt, seen = [startedAt]
        for _ in 0..<(Self.permissionModes.count + 1) {
            guard let next = try await cycleOnce(sessionID, from: current) else { return (false, "Pressed shift+tab but the footer stayed on \(current).", current) }
            current = next
            if current == wanted.id { return (true, "Switched to \(wanted.label) mode.", current) }
            if current == startedAt {
                return (false, "This session's cycle only offers \(seen.joined(separator: ", ")) — \(wanted.label) is not available in it.", current)
            }
            seen.append(current)
        }
        return (false, "Gave up cycling; the footer is on \(current).", current)
    }
    /// agent-controls.ts:2717 currentModel.
    func currentModel(_ sessionID: String, cwd: String?, configDir: String?) async -> Reading {
        if let screen = await access.screen(sessionID), let confirmed = Self.readModelFromScreen(screen) {
            return Reading(value: confirmed, label: confirmed, source: "screen")
        }
        guard let cwd, !cwd.isEmpty, let raw = readModelFromTranscript(cwd: cwd, configDir: configDir) else { return .unknown }
        return Reading(value: raw, label: BackendCompositionSuppliers.modelLabel(raw), source: "transcript")
    }

    /// agent-controls.ts:2403 applyControl. Success is never assumed from bytes
    /// written; the reading is always re-read from the session.
    func applyControl(sessionID id: String, cwd: String?, control: String, value: String, provider: String?, local: Bool) async throws -> Outcome {
        let store: String?
        if local, let configDir = access.configDir { store = await configDir(id) } else { store = nil }
        guard let opening = await access.screen(id) else { return Outcome(ok: false, message: "That session is no longer running.", reading: .unknown) }
        // Checked beside access.write, not trusted to the caller (agent-controls.ts:2422).
        if let foreign = Self.refuseByProvider(provider, Presence.screen(Self.readAgentFromScreen(opening))) {
            return Outcome(ok: false, message: foreign, reading: .unknown)
        }
        switch control {
        case "permission":
            let outcome = try await applyPermission(id, target: value)
            return Outcome(ok: outcome.ok, message: outcome.message,
                reading: outcome.mode.map { Reading(value: $0, label: Self.permissionLabel($0), source: "screen") } ?? .unknown)
        case "model":
            guard BackendSharedModelCatalog.isTypeableModelValue(value) else {
                return Outcome(ok: false, message: "\(value) is not a model name that can be typed at a command line.", reading: .unknown)
            }
            let before = Self.countModelConfirmations(opening), errorsBefore = Self.countCommandErrors(opening)
            let carried: BackendAgentControlsCarried<BackendAgentControlsCommand<Answer>> = try await carryDraft(id) { () async throws -> BackendAgentControlsCommand<Answer> in
                try await runCommand(id, "/model \(value)", kind: "model") { (screen: String) -> Answer? in
                    if Self.countCommandErrors(screen) > errorsBefore, let failure = Self.readCommandError(screen) { return Answer(ok: false, text: failure, scope: nil) }
                    guard Self.countModelConfirmations(screen) > before, let now = Self.readModelConfirmation(screen) else { return nil }
                    return Answer(ok: true, text: now.name, scope: now.scope)
                }
            }
            let fallbackCwd = local ? cwd : nil
            switch carried {
            case .refused(let message): return Outcome(ok: false, message: message, reading: await currentModel(id, cwd: fallbackCwd, configDir: store))
            case .ran(.failed(let message), let note):
                return Outcome(ok: false, message: Self.withNote(message, note), reading: await currentModel(id, cwd: fallbackCwd, configDir: store))
            case .ran(.answered(let answer), let note):
                guard answer.ok else { return Outcome(ok: false, message: Self.withNote(answer.text, note), reading: await currentModel(id, cwd: fallbackCwd, configDir: store)) }
                if local { await access.rememberModel?(id, value) }
                let scope = answer.scope.map { " — \(Self.scopeText($0))." } ?? "."
                return Outcome(ok: true, message: Self.withNote("Model is now \(answer.text)\(scope)", note), reading: Reading(value: answer.text, label: answer.text, source: "screen"))
            }
        case "effort":
            guard let known = Self.effortLevels.first(where: { $0.id == value }) else {
                return Outcome(ok: false, message: "\(value) is not one of the levels the CLI accepts.", reading: .unknown)
            }
            let before = Self.countEffortConfirmations(opening), errorsBefore = Self.countCommandErrors(opening)
            let carried: BackendAgentControlsCarried<BackendAgentControlsCommand<Answer>> = try await carryDraft(id) { () async throws -> BackendAgentControlsCommand<Answer> in
                try await runCommand(id, "/effort \(value)", kind: "effort") { (screen: String) -> Answer? in
                    if Self.countCommandErrors(screen) > errorsBefore, let failure = Self.readCommandError(screen) { return Answer(ok: false, text: failure, scope: nil) }
                    guard Self.countEffortConfirmations(screen) > before, let now = Self.readEffortConfirmation(screen), now.level == value else { return nil }
                    return Answer(ok: true, text: now.level, scope: now.scope)
                }
            }
            func fallback() -> Reading { Self.effortFromSettings(local ? readClaudeSettings(store) : .object([])) }
            switch carried {
            case .refused(let message): return Outcome(ok: false, message: message, reading: fallback())
            case .ran(.failed(let message), let note): return Outcome(ok: false, message: Self.withNote(message, note), reading: fallback())
            case .ran(.answered(let answer), let note):
                guard answer.ok else { return Outcome(ok: false, message: Self.withNote(answer.text, note), reading: fallback()) }
                let scope = answer.scope.map { " — \(Self.scopeText($0))." } ?? "."
                return Outcome(ok: true, message: Self.withNote("Effort is now \(known.label)\(scope)", note), reading: Reading(value: value, label: known.label, source: "screen"))
            }
        case "fast":
            guard value == "on" || value == "off" else { return Outcome(ok: false, message: "Fast mode is on or off.", reading: .unknown) }
            let before = Self.countFastAnnouncements(opening)
            let carried: BackendAgentControlsCarried<BackendAgentControlsFast> = try await carryDraft(id) { () async throws -> BackendAgentControlsFast in
                let typed = try await typeCommand(id, "/fast \(value)")
                if case .failed(let message) = typed { return .failed(message) }
                // A change prints an announcement; a no-op prints nothing and the ↯ settles it.
                let answer: Reading? = try await waitForScreen(id, timings.command) { (screen: String) -> Reading? in
                    if Self.countFastAnnouncements(screen) > before { return Self.readFast(screen) }
                    return Self.readFastIndicator(screen) == value ? Self.readFast(screen) : nil
                }
                return .answered(answer)
            }
            func fallback() -> Reading { Self.fastFromSettings(local ? readClaudeSettings(store) : .object([])) }
            switch carried {
            case .refused(let message): return Outcome(ok: false, message: message, reading: fallback())
            case .ran(.failed(let message), let note): return Outcome(ok: false, message: Self.withNote(message, note), reading: fallback())
            case .ran(.answered(let answer), let note):
                guard let answer else {
                    return Outcome(ok: false, message: Self.withNote("Typed /fast \(value) but the session has not shown it taking effect — it is most likely mid-turn, so the command is sitting in its input queue.", note), reading: fallback())
                }
                if let reason = answer.unavailableReason { return Outcome(ok: false, message: Self.withNote(reason, note), reading: answer) }
                return Outcome(ok: answer.value == value, message: Self.withNote("Fast mode \(answer.label ?? "").", note), reading: answer)
            }
        default:
            return Outcome(ok: false, message: "Unknown control \(control).", reading: .unknown)
        }
    }

    /// agent-controls.ts:2682 discoverModels: open the session's own picker, read it, Esc out.
    func discoverModels(sessionID id: String, provider: String?) async throws -> NativeRPCValue {
        func result(_ rows: [BackendSharedModelRow], _ message: String?) -> NativeRPCValue {
            .object([.init("models", .array(rows.map { row in
                .object([.init("alias", .string(row.alias)), .init("name", .string(row.name)), .init("model", .string(row.model)),
                    .init("note", .string(row.note)), .init("current", .bool(row.current)), .init("recommended", .bool(row.recommended))])
            })), .init("message", message.map(NativeRPCValue.string) ?? .null)])
        }
        guard let opening = await access.screen(id) else { return result([], "That session is no longer running.") }
        if let foreign = Self.refuseByProvider(provider, Presence.screen(Self.readAgentFromScreen(opening))) { return result([], foreign) }
        let typed = try await typeCommand(id, "/model")
        if case .failed(let message) = typed { return result([], message) }
        let rows: [BackendSharedModelRow]?
        do { rows = try await waitForScreen(id, timings.command) { (screen: String) -> [BackendSharedModelRow]? in BackendSharedModelCatalog.readModelPicker(screen) } }
        catch { await access.write(id, "\u{1B}"); throw error }
        // Esc goes out whether or not the picker was read (agent-controls.ts:2700).
        await access.write(id, "\u{1B}")
        guard let rows else { return result([], "Opened the model list but could not read it, so it was cancelled and nothing changed.") }
        return result(BackendSharedModelCatalog.foldDefaultRow(rows), nil)
    }
}
