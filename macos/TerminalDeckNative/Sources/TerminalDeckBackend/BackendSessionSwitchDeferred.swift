import Foundation
import TerminalDeckNativeCore

/// Port of src/main/switch-later.ts and its wiring in src/main/index.ts
/// (armSwitchLater, fireSwitch, typeIntoSession). The choice is made now and
/// takes effect at the next message he sends: every keystroke still reaches
/// the old session, only the Enter of a real message is withheld, the switch
/// runs, and his line is replayed into the replacement. The line holds only
/// characters he typed; it is sent for him only when the copy is certain.
public actor BackendSessionSwitchDeferred {
    /// TS `Composing` plus `feed`/`step`/`continueEscape`/`escapeSequence`.
    /// `escape` is the TS `pending` sequence. Walks Unicode scalars, as the TS
    /// `for…of` walks code points.
    struct Editor: Sendable {
        var characters: [Character] = []
        var cursor = 0
        var exact = true
        var escape = ""
        var pasting = false
        var text: String { String(characters) }
        /// TS: certain, and nothing half-arrived (`exact && pending === '' && !pasting`).
        var sendable: Bool { exact && escape.isEmpty && !pasting }

        private static let esc: Unicode.Scalar = "\u{1b}"
        private static let bel: Unicode.Scalar = "\u{7}"
        private static let cr: Unicode.Scalar = "\r"
        private static let lf: Unicode.Scalar = "\n"
        private static let csi: Unicode.Scalar = "["
        private static let ss3: Unicode.Scalar = "O"
        private static let backslash: Unicode.Scalar = "\\"
        private static let introducers: Set<Unicode.Scalar> = ["[", "]", "O", "P", "^", "_", "X"]

        mutating func reset() { self = Editor() }

        /// TS `feed`: fold a chunk in, stopping at the Enter that ends the message.
        /// `before`/`after` are the chunk either side of that Enter.
        mutating func feed(_ input: String) -> (submit: String.Index?, before: String, after: String) {
            let scalars = input.unicodeScalars
            var index = scalars.startIndex
            while index < scalars.endIndex {
                if step(scalars[index]) {
                    let next = scalars.index(after: index)
                    return (index, String(String.UnicodeScalarView(scalars[scalars.startIndex..<index])),
                            String(String.UnicodeScalarView(scalars[next...])))
                }
                index = scalars.index(after: index)
            }
            return (nil, input, "")
        }

        private mutating func insert(_ scalar: Unicode.Scalar) {
            let at = min(max(0, cursor), characters.count)
            characters.insert(Character(scalar), at: at); cursor = at + 1
        }
        /// TS `unsure`: the line stands; the claim does not.
        private mutating func unsure() { exact = false; escape = "" }
        /// TS `abandon`: an Escape that spoils a sequence opens the next one.
        private mutating func abandon(_ scalar: Unicode.Scalar) { exact = false; escape = scalar == Self.esc ? "\u{1b}" : "" }
        private static func control(_ scalar: Unicode.Scalar) -> Bool { scalar.value < 0x20 || scalar.value == 0x7f }

        /// TS `step`; true is SUBMITS.
        private mutating func step(_ ch: Unicode.Scalar) -> Bool {
            if !escape.isEmpty { return continueEscape(ch) }
            if ch == Self.esc { escape = "\u{1b}"; return false }
            if pasting {
                // A newline inside a paste is text, and the certainty goes with it.
                if ch == Self.cr || ch == Self.lf { insert(Self.lf); exact = false; return false }
                if Self.control(ch) { unsure(); return false }
                insert(ch); return false
            }
            if ch == Self.cr || ch == Self.lf { return true }
            switch ch.value {
            case 0x03: reset()                                                  // Ctrl-C: certain again, on an empty line
            case 0x08, 0x7f:
                if cursor > 0, cursor <= characters.count { characters.remove(at: cursor - 1); cursor -= 1 }
            case 0x15: characters.removeFirst(min(cursor, characters.count)); cursor = 0
            case 0x0b: if cursor < characters.count { characters.removeSubrange(cursor...) }
            case 0x17:
                var kept = Array(characters.prefix(cursor))
                while let last = kept.last, last.isWhitespace { kept.removeLast() }
                while let last = kept.last, !last.isWhitespace { kept.removeLast() }
                characters = kept + characters.dropFirst(cursor); cursor = kept.count
            case 0x01: cursor = 0
            case 0x05: cursor = characters.count
            case 0x02: cursor = max(0, cursor - 1)
            case 0x06: cursor = min(characters.count, cursor + 1)
            default:
                // Tab and every other C0 byte: nothing is appended.
                if Self.control(ch) { unsure() } else { insert(ch) }
            }
            return false
        }

        /// TS `continueEscape`: every sequence ends interpreted or discarded
        /// whole; no path out of here appends a byte to the line.
        private mutating func continueEscape(_ ch: Unicode.Scalar) -> Bool {
            // His Enter is never eaten, whatever is half-arrived in front of it.
            if ch == Self.cr || ch == Self.lf { return true }
            let pending = Array(escape.unicodeScalars)
            if pending.count == 1 {
                if ch == Self.esc { return false }                              // a fresh sequence; the abandoned one is dropped
                if Self.introducers.contains(ch) { escape.unicodeScalars.append(ch); return false }
                unsure(); return false                                           // ESC b, ESC f, …: consumed, never appended
            }
            let introducer = pending[1]
            if introducer == Self.csi {
                let code = ch.value
                if (0x30...0x3f).contains(code) || (0x20...0x2f).contains(code) { escape.unicodeScalars.append(ch); return false }
                if (0x40...0x7e).contains(code) {
                    sequence(params: String(String.UnicodeScalarView(pending.dropFirst(2))), final: ch); return false
                }
                abandon(ch); return false
            }
            if introducer == Self.ss3 {
                if (0x40...0x7e).contains(ch.value) { sequence(params: "", final: ch); return false }
                abandon(ch); return false
            }
            // OSC, DCS, PM, APC: somebody else's payload up to BEL or ESC \.
            if ch == Self.bel { unsure(); return false }
            if ch == Self.backslash && pending.last == Self.esc { unsure(); return false }
            escape.unicodeScalars.append(ch); return false
        }

        /// TS `escapeSequence`: only the bare forms are acted on.
        private mutating func sequence(params: String, final: Unicode.Scalar) {
            let bare = params.isEmpty || params == "1"
            let end = characters.count
            escape = ""
            // Focus reports and SGR mouse reports are the terminal talking, not keys.
            if (final == "I" || final == "O") && params.isEmpty { return }
            if (final == "M" || final == "m") && params.hasPrefix("<") { return }
            switch final {
            case "D": if bare { cursor = max(0, cursor - 1) } else { unsure() }
            case "C": if bare { cursor = min(end, cursor + 1) } else { unsure() }
            case "H": if bare { cursor = 0 } else { unsure() }
            case "F": if bare { cursor = end } else { unsure() }
            case "~":
                switch params {
                case "1", "7": cursor = 0
                case "4", "8": cursor = end
                case "3": if cursor >= 0, cursor < end { characters.remove(at: cursor) }
                case "200": pasting = true
                case "201": pasting = false
                default: unsure()
                }
            default: unsure()                                                   // up/down and the rest: words stay, certainty goes
            }
        }
    }

    public struct Armed: Sendable {
        public let sessionID: String
        public let accountID: String
        public let accountName: String
        public let armedAt: Date
        /// TS armSwitchLater / armedSwitches answer.
        public var wireValue: NativeRPCValue {
            .object([.init("sessionId", .string(sessionID)), .init("profileId", .string(accountID)), .init("accountName", .string(accountName)),
                .init("note", .string(BackendSessionSwitchDeferred.armedNote(accountName: accountName)))])
        }
    }

    /// Everything the register reaches outside itself, injected for tests (REQ S5-7).
    struct Hooks: Sendable {
        var subject: @Sendable (String, String) async throws -> (name: String, inPlace: Bool)
        var perform: @Sendable (String, String) async throws -> String
        var status: @Sendable (String) async -> BackendSessionStatus
        var write: @Sendable (String, String) async throws -> Void
        var sleep: @Sendable (Duration) async throws -> Void
    }

    /// TS REPLAY_SETTLE_MS and REPLAY_SUBMIT_GAP_MS.
    static let replaySettle: Duration = .milliseconds(400)
    static let replaySubmitGap: Duration = .milliseconds(50)

    private let lifecycle: BackendSessionLifecycleCoordinator?
    private let switches: BackendSessionSwitchCoordinator?
    private let hooks: Hooks?
    private let emit: @Sendable (BackendSessionLifecycleEvent) -> Void
    private var editors: [String: Editor] = [:]
    private var armed: [String: Armed] = [:]
    private var queueing: [String: String] = [:]
    private var recovery: [String: String] = [:]
    private var observer: UUID?
    private var work: [String: Task<Void, Never>] = [:]
    private init(lifecycle: BackendSessionLifecycleCoordinator?, switches: BackendSessionSwitchCoordinator?, hooks: Hooks?,
                 emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) {
        self.lifecycle = lifecycle; self.switches = switches; self.hooks = hooks; self.emit = emit
    }
    public static func start(lifecycle: BackendSessionLifecycleCoordinator, switches: BackendSessionSwitchCoordinator,
                             emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) async -> BackendSessionSwitchDeferred {
        let owner = BackendSessionSwitchDeferred(lifecycle: lifecycle, switches: switches, hooks: nil, emit: emit)
        await owner.attach(); return owner
    }
    /// A register over injected hooks: no lifecycle, no switch coordinator, no real sleeps.
    static func forTesting(_ hooks: Hooks, emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) -> BackendSessionSwitchDeferred {
        BackendSessionSwitchDeferred(lifecycle: nil, switches: nil, hooks: hooks, emit: emit)
    }
    private func attach() async {
        guard let lifecycle else { return }
        await lifecycle.setTypingOwner { [weak self] id, data in
            guard let self else { throw BackendSessionFailure.closed }; try await self.write(sessionID: id, data: data)
        }
        observer = await lifecycle.observe { [weak self] event in
            switch event { case .exit(let id, _), .removed(let id, _): await self?.ended(id); default: break }
        }
    }

    /* ---------------------------------------------------------- the seams -- */

    private func subject(_ sessionID: String, _ accountID: String) async throws -> (name: String, inPlace: Bool) {
        if let hooks { return try await hooks.subject(sessionID, accountID) }
        guard let switches else { throw BackendSessionFailure.closed }
        let plan = try await switches.subject(sessionID: sessionID, accountID: accountID)
        guard plan.refusal == nil, let target = plan.to else { throw BackendSessionFailure.unsupported(plan.refusal ?? "This session cannot be switched.") }
        return (target.name, plan.mode == .inPlace)
    }
    private func status(_ sessionID: String) async -> BackendSessionStatus {
        if let hooks { return await hooks.status(sessionID) }
        guard let lifecycle else { return .exited }
        return await lifecycle.status(sessionID: sessionID)
    }
    private func direct(_ sessionID: String, _ data: String) async throws {
        if let hooks { try await hooks.write(sessionID, data); return }
        guard let lifecycle else { throw BackendSessionFailure.closed }
        try await lifecycle.writeDirect(sessionID: sessionID, data: data)
    }
    private func pause(_ duration: Duration) async throws {
        if let hooks { try await hooks.sleep(duration); return }
        try await Task.sleep(for: duration)
    }
    /// Runs the switch and answers the replacement's id. The note travels with
    /// the `.replaced` event (TS SESSION_SWITCHED_CHANNEL).
    private func performSwitch(_ change: Armed, note: String) async throws -> String {
        if let hooks { return try await hooks.perform(change.sessionID, change.accountID) }
        guard let switches else { throw BackendSessionFailure.closed }
        return try await switches.perform(sessionID: change.sessionID, accountID: change.accountID, note: note).session.id
    }

    /* ------------------------------------------------------- the register -- */

    /// TS armSwitchLater. A switch made in place restarts nothing, so it is made now.
    public func arm(sessionID: String, accountID: String) async throws -> NativeRPCValue {
        let target = try await subject(sessionID, accountID)
        if target.inPlace {
            let id: String, note: String
            if let switches {
                let result = try await switches.perform(sessionID: sessionID, accountID: accountID)
                id = result.session.id
                note = result.phase == .awaitingReread ? "The login change is waiting for this provider's next credential reread."
                    : Self.switchedNote(accountName: target.name, submitted: false, line: "")
            } else {
                id = try await performSwitch(Armed(sessionID: sessionID, accountID: accountID, accountName: target.name, armedAt: Date()), note: "")
                note = Self.switchedNote(accountName: target.name, submitted: false, line: "")
            }
            return .object([.init("sessionId", .string(id)), .init("profileId", .string(accountID)), .init("note", .string(note))])
        }
        let value = Armed(sessionID: sessionID, accountID: accountID, accountName: target.name, armedAt: Date())
        armed[sessionID] = value; return value.wireValue
    }
    public func list() -> [Armed] { armed.values.sorted { $0.armedAt < $1.armedAt } }
    public func cancel(sessionID: String) async { armed[sessionID] = nil; await switches?.cancel(sessionID: sessionID) }
    public func recoveryDraft(sessionID: String) -> String? { recovery[sessionID] }
    /// Test seam: what the lifecycle's typing owner calls.
    func typed(sessionID: String, data: String) async throws { try await write(sessionID: sessionID, data: data) }
    /// Test seam: wait for a fired switch and its replay to finish.
    func waitForIdle(sessionID: String) async { if let task = work[sessionID] { await task.value } }

    /// TS typeIntoSession + PendingSwitches.observe.
    private func write(sessionID: String, data: String) async throws {
        if queueing[sessionID] != nil {
            guard (queueing[sessionID]?.utf8.count ?? 0) + data.utf8.count <= 256 * 1024 else { throw BackendSessionFailure.invalidInput("Typing queued during the switch exceeded its draft budget.") }
            queueing[sessionID, default: ""] += data; return
        }
        var editor = editors[sessionID] ?? Editor()
        let result = editor.feed(data)
        guard result.submit != nil else {
            if editor.characters.count > 256 * 1024 { editor.characters.removeAll(); editor.cursor = 0; editor.exact = false }
            editors[sessionID] = editor; try await direct(sessionID, data); return
        }
        // Only a real message fires: not an empty line, not an answer to a question.
        var candidate = armed[sessionID]
        if candidate != nil {
            if editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { candidate = nil }
            else if await status(sessionID) == .input { candidate = nil }
        }
        guard let change = candidate else {
            editor.reset()
            var remaining = result.after
            while !remaining.isEmpty {
                let suffix = editor.feed(remaining)
                if suffix.submit != nil { editor.reset(); remaining = suffix.after } else { break }
            }
            editors[sessionID] = editor
            try await direct(sessionID, data); return
        }
        armed[sessionID] = nil
        let line = editor.text, submit = editor.sendable
        editors[sessionID] = Editor(); queueing[sessionID] = result.after
        // What he typed before the Enter still reaches the old session; the Enter does not.
        if !result.before.isEmpty { try await direct(sessionID, result.before) }
        work[sessionID] = Task { [weak self] in await self?.fire(change, line: line, submit: submit) }
    }

    /// TS fireSwitch: switch, tell the window, settle, then the line and — only
    /// when the copy is certain — the Enter, as two writes.
    private func fire(_ change: Armed, line: String, submit: Bool) async {
        defer { work[change.sessionID] = nil }
        let replacement: String
        do {
            replacement = try await performSwitch(change, note: Self.switchedNote(accountName: change.accountName, submitted: submit, line: line))
        } catch {
            // The old session is still running with his line in its prompt;
            // what he typed meanwhile goes where it would have gone.
            let later = queueing.removeValue(forKey: change.sessionID) ?? ""
            if !later.isEmpty { try? await direct(change.sessionID, later) }
            emit(.switchFailed(sessionID: change.sessionID, message: error.localizedDescription))
            return
        }
        let later = queueing.removeValue(forKey: change.sessionID) ?? ""
        editors[replacement] = Editor(); recovery[change.sessionID] = nil
        guard !line.isEmpty else { if !later.isEmpty { try? await direct(replacement, later) }; return }
        do {
            try await pause(Self.replaySettle)
            let writes = Self.replayWrites(line, submit: submit)
            try await direct(replacement, writes.typed)
            if submit {
                try await pause(Self.replaySubmitGap)
                try await direct(replacement, writes.enter)
                if !later.isEmpty { try await direct(replacement, later) }
            } else if !later.isEmpty { recovery[replacement] = line + later }
        } catch {
            recovery[replacement] = line + later
            emit(.switchFailed(sessionID: replacement, message: "Switched to \(change.accountName), but your message could not be typed into the new session: " + error.localizedDescription))
        }
    }
    private func ended(_ id: String) { armed[id] = nil; editors[id] = nil; if queueing[id] == nil { recovery[id] = nil } }
    public func stop() async {
        armed.removeAll(); editors.removeAll()
        for task in work.values { task.cancel() }; work.removeAll()
        if let lifecycle {
            await lifecycle.setTypingOwner(nil)
            if let observer { await lifecycle.removeObserver(observer) }
        }
        observer = nil
    }

    /* ------------------------------------------------------------- saying -- */

    /// TS replayWrites: the line, then the Enter, as two writes. A line with an
    /// `@` gets a trailing space only when an Enter follows.
    static func replayWrites(_ line: String, submit: Bool = true) -> (typed: String, enter: String) {
        (submit && line.contains("@") ? line + " " : line, "\r")
    }
    /// TS armedNote.
    static func armedNote(accountName: String) -> String { "Switching to \(accountName) when you send your next message." }
    /// TS switchedNote.
    static func switchedNote(accountName: String, submitted: Bool, line: String = " ") -> String {
        if line.isEmpty { return "Switched to \(accountName)." }
        return submitted ? "Switched to \(accountName) and sent your message."
            : "Switched to \(accountName). Your message is in the prompt — check it and press Enter."
    }
}
