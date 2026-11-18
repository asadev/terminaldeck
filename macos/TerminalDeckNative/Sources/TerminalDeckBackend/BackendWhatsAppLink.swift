import Foundation
import TerminalDeckNativeCore

/// One WhatsApp agent read by THIS computer (DESIGN-WHATSAPP.md sections 4 and 5): its poll loop, his messages into the
/// receiver, and the receiver's answers and approvals back to him. Exactly one link per agent per app (the engine holds
/// them by agent id), and only on the computer that is the agent's reader. Sends to him go strictly one after another.
actor BackendWhatsAppLink {
    struct Clock: Sendable {
        var now: @Sendable () -> Date
        var sleep: @Sendable (_ seconds: Double) async -> Void
        static let live = Clock(now: { Date() }, sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) })
    }
    /// Timings of design sections 1 and 4 (tests shorten the waits through the clock, never these rules).
    enum Timing {
        static let pollTimeout = 25
        /// 15 polls a minute.
        static let pollGap = 4.0
        static let typingEvery = 20.0
        static let watchEvery = 2.0
        static let lateAfter: TimeInterval = 24 * 3600
        static let terminalQuiet = 2.0
        static let terminalLongest = 120.0
        static let terminalLines = 40
        static let imageLimit = 5 * 1024 * 1024
        static let otherLimit = 16 * 1024 * 1024
        /// After a 409 while the record still names this computer: poll again after this long (review fault 2).
        static let afterReplaced = 30.0
    }
    enum Words {
        static let late = "This reached me late; send it again if you still need it."
        static let notRead = "I read text, pictures and documents here."
        static let ended = "That session has ended. Choose where I should answer in Terminal Deck."
        static let nowhere = "This WhatsApp agent is not received anywhere right now. Choose where I should answer in Terminal Deck."
        static let reply = "Reply 1 to allow, 2 to deny."
        static let fileTooLarge = "That file is larger than WhatsApp lets me fetch."
        static let documentKind = "I read pictures, PDF and text documents here."
        static let noOutput = "(no output)"
        static let terminalTextOnly = "A terminal takes text only here."
    }

    let agentID: String
    private let key: String
    private let transport: any WhatsAppTransport
    private let receivers: any WhatsAppReceiverPort
    private let clock: Clock
    /// The engine's record of this agent now, and a change to it saved and sent to every computer.
    private let read: @Sendable () async -> WhatsAppAgentRecord?
    private let update: @Sendable (_ change: @escaping @Sendable (inout WhatsAppAgentRecord) -> Void) async -> Void
    /// A 409 (a newer reader) or a refused key: the engine re-reads the settings.
    private let stopped: @Sendable (_ why: StopReason) async -> Void
    enum StopReason: Sendable { case notReader, keyRefused }
    /// The fingerprint of the key this link reads with (never the key).
    nonisolated let keyID: String
    /// True while the synced record still names THIS computer as the reader, with this key.
    private let stillReader: @Sendable () async -> Bool
    /// True while the receiver session is moving to another computer (or was handed over from here): nothing is read
    /// and the reading position is left where it is, so the computer that takes the session answers it, once.
    private let holding: @Sendable () async -> Bool

    private var polling: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    private var outbox: Task<Void, Never>?
    private var target: WhatsAppTarget?
    /// The receiver's turns already given to him (an answer is sent once).
    private var deliveredTurn: String?
    private var seededTurn = false
    private var askedApprovals: Set<String> = []
    /// The ONE approval asked on WhatsApp and not yet answered (review fault 3): the next is asked only when this one is
    /// answered or gone; "1" / "2" count only when written at or after it was asked.
    private var openApproval: (target: WhatsAppTarget, id: String, askedAt: Date)?
    /// His message the typing indicator belongs to, while the receiver works on it.
    private var typingFor: String?
    private var typedAt: Date?
    private var lastPoll: Date?
    private struct TerminalReply {
        let id = UUID()
        let target: WhatsAppTarget
        let text: String
        let to: String
        let before: String
        let sentAt: Double
    }
    private var terminalReply: TerminalReply?
    private var terminalWaiting: Task<Void, Never>?

    init(agentID: String, key: String, transport: any WhatsAppTransport, receivers: any WhatsAppReceiverPort, clock: Clock = .live,
         read: @escaping @Sendable () async -> WhatsAppAgentRecord?,
         update: @escaping @Sendable (_ change: @escaping @Sendable (inout WhatsAppAgentRecord) -> Void) async -> Void,
         stopped: @escaping @Sendable (_ why: StopReason) async -> Void,
         stillReader: @escaping @Sendable () async -> Bool = { true },
         holding: @escaping @Sendable () async -> Bool = { false }) {
        self.agentID = agentID; self.key = key; self.transport = transport; self.receivers = receivers; self.clock = clock
        self.read = read; self.update = update; self.stopped = stopped; self.stillReader = stillReader; self.holding = holding
        keyID = WhatsAppAgentIDs.fingerprint(key)
    }

    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in await self?.run() }
        watching = Task { [weak self] in await self?.watch() }
    }
    func stop() { polling?.cancel(); watching?.cancel(); terminalWaiting?.cancel(); polling = nil; watching = nil; terminalWaiting = nil; terminalReply = nil }
    var isRunning: Bool { polling != nil }
    /// The session his messages go to now (nil until the first one, or after it ended).
    var currentTarget: WhatsAppTarget? { target }

    // MARK: Reading (one reader per agent)

    private func pollSpaced(offset: Int64?, timeout: Int) async -> WhatsAppPoll {
        if let lastPoll {
            let wait = Timing.pollGap - clock.now().timeIntervalSince(lastPoll)
            if wait > 0 { await clock.sleep(wait) }
        }
        lastPoll = clock.now()
        return await transport.poll(key: key, offset: offset, timeout: timeout)
    }

    private func run() async {
        while !Task.isCancelled {
            guard let record = await read(), !record.removed, !record.refused else { return }
            // The session is moving to another computer: no poll from here (no 409 for the taker), the position kept.
            if await holding() { await clock.sleep(Timing.pollGap); continue }
            // First connect of this key: read the backlog only to learn the creator and the head; answer nothing of it.
            if record.offset == nil {
                guard let head = await learnHead() else { return }
                guard await stillReader() else { polling = nil; await stopped(.notReader); return }
                let creator = head.creator
                await update { $0.offset = head.offset; if let creator { $0.creator = creator } }
                continue
            }
            let result = await pollSpaced(offset: record.offset, timeout: Timing.pollTimeout)
            guard !Task.isCancelled else { return }
            switch result {
            case .nothing: continue
            case .replaced:
                // Fault 2: another reader polled. While the record still names this computer, try again in ~30 s
                // (a one-off check or a computer that has not heard yet); otherwise stop and let the settings decide.
                guard await stillReader() else { polling = nil; await stopped(.notReader); return }
                await clock.sleep(Timing.afterReplaced)
            case .keyRefused: polling = nil; await update { $0.refused = true }; await stopped(.keyRefused); return
            case .backOff(let seconds): await clock.sleep(max(1, seconds))
            case .messages(let messages, let next):
                // Fault 2: the batch is handled only while the record still names this computer (a take-over is
                // never answered twice by a computer that woke up late).
                guard await stillReader() else { polling = nil; await stopped(.notReader); return }
                // A batch that arrives as the move starts is not taken and the position not moved: WhatsApp gives it
                // again from the same position to the computer that takes the session (answered once, there).
                if await holding() { continue }
                for message in messages where !Task.isCancelled { await take(message) }
                let newest = messages.filter { $0.kind != .reaction }.map { $0.timestamp.timeIntervalSince1970 * 1000 }.max()
                let creator = messages.last?.from
                await update { record in
                    record.offset = next
                    if record.creator == nil, let creator { record.creator = creator }
                    if let newest { record.lastMessageAt = max(record.lastMessageAt ?? 0, newest) }
                }
            }
        }
    }

    /// The backlog read with `timeout=0` until nothing is left: the creator (from any message) and the head.
    private func learnHead() async -> (offset: Int64, creator: String?)? {
        var offset: Int64 = 0, creator: String?
        while !Task.isCancelled {
            switch await pollSpaced(offset: offset, timeout: 0) {
            case .nothing: return (offset, creator)
            case .messages(let messages, let next):
                if let from = messages.last?.from { creator = from }
                if next == offset { return (offset, creator) }
                offset = next
            case .replaced:
                guard await stillReader() else { polling = nil; await stopped(.notReader); return nil }
                await clock.sleep(Timing.afterReplaced)
            case .keyRefused: polling = nil; await update { $0.refused = true }; await stopped(.keyRefused); return nil
            case .backOff(let seconds): await clock.sleep(max(1, seconds))
            }
        }
        return nil
    }

    // MARK: One message from him

    static func approvalAnswer(_ text: String?) -> Bool? {
        switch text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "allow": return true
        case "2", "deny": return false
        default: return nil
        }
    }

    func take(_ message: WhatsAppInbound) async {
        guard let record = await read() else { return }
        // Only the creator can write to an agent; anything else is not his and is left alone.
        if let creator = record.creator, creator != message.from { return }
        if record.creator == nil { let from = message.from; await update { $0.creator = from } }
        if message.kind == .reaction { return }
        // A message he writes from WhatsApp turns the switch on by itself: it is answered there.
        if !record.isSending { await update { $0.sending = true } }
        let to = message.from
        if clock.now().timeIntervalSince(message.timestamp) > Timing.lateAfter {
            _ = await transport.markRead(key: key, messageID: message.id, typing: false)
            send(Words.late, to: to); return
        }
        switch message.kind {
        case .text, .image, .document: break
        default:
            _ = await transport.markRead(key: key, messageID: message.id, typing: false)
            send(Words.notRead, to: to); return
        }
        if record.endedSession {
            _ = await transport.markRead(key: key, messageID: message.id, typing: false)
            send(Words.ended, to: to)
            await update { $0.endedSession = false }
            return
        }
        // "1" / "2" answers the one open question, only when written at or after it was asked (fault 3).
        if message.kind == .text, let allow = Self.approvalAnswer(message.text), let open = openApproval,
           message.timestamp >= Date(timeIntervalSince1970: open.askedAt.timeIntervalSince1970.rounded(.down)) {
            openApproval = nil
            if (try? await receivers.approve(open.target, approvalID: open.id, allow: allow)) == true {
                _ = await transport.markRead(key: key, messageID: message.id, typing: true)
                typingFor = message.id; typedAt = clock.now()
                return
            }
        }
        let found: WhatsAppTarget?
        do { found = try await receivers.target(for: record.receiver, conversationName: record.name, agentID: agentID) }
        catch { found = nil }
        guard let target = found else {
            _ = await transport.markRead(key: key, messageID: message.id, typing: false)
            if case .session = record.receiver {
                await update { $0.receiver = .nowhere }
                send(Words.ended, to: to)
            } else { send(Words.nowhere, to: to) }
            return
        }
        if self.target != target { self.target = target; seededTurn = false }
        // Fault 4: a terminal takes text only; a picture or document is never typed into the shell.
        if target.isTerminal, message.kind != .text {
            _ = await transport.markRead(key: key, messageID: message.id, typing: false)
            send(Words.terminalTextOnly, to: to); return
        }
        _ = await transport.markRead(key: key, messageID: message.id, typing: true)
        typingFor = message.id; typedAt = clock.now()
        // Pictures and documents arrive as attachments of his message.
        var text = message.text ?? message.caption ?? ""
        var attachments: [WhatsAppAttachment] = []
        if message.kind == .image || message.kind == .document, let media = message.mediaID {
            let limit = message.kind == .image ? Timing.imageLimit : Timing.otherLimit
            guard let fetched = await transport.media(key: key, id: media, limit: limit) else {
                typingFor = nil; send(Words.fileTooLarge, to: to); return
            }
            switch Self.attachmentKind(fetched.mimeType) {
            case .chat: attachments.append(.init(data: fetched.data, mimeType: fetched.mimeType, fileName: message.fileName ?? fetched.fileName))
            case .text:
                let name = message.fileName ?? fetched.fileName ?? "document"
                text += (text.isEmpty ? "" : "\n\n") + name + ":\n" + String(decoding: fetched.data.prefix(131_072), as: UTF8.self)
            case .refused: typingFor = nil; send(Words.documentKind, to: to); return
            }
        }
        if target.isTerminal { await terminal(target, text: text, to: to); return }
        // The answer to THIS message must be sent even when it is ready before the next look: what was there before
        // is the only thing marked as already given.
        if !seededTurn {
            seededTurn = true
            if let before = await receivers.turn(target) {
                switch before.state { case .done, .failed, .idle: deliveredTurn = before.turnID; default: break }
            }
        }
        do {
            try await receivers.say(target, text: text, attachments: attachments)
        } catch {
            typingFor = nil
            send("That did not reach the chat: " + Self.plain(error), to: to)
        }
    }

    enum AttachmentKind { case chat, text, refused }
    /// What a chat takes as an attachment (pictures and PDF), what is read as text, and what is not taken.
    static func attachmentKind(_ mime: String) -> AttachmentKind {
        let lower = mime.lowercased()
        if ["image/png", "image/jpeg", "image/gif", "image/webp", "application/pdf"].contains(lower) { return .chat }
        if lower.hasPrefix("text/") || ["application/json", "application/xml", "text/csv"].contains(lower) { return .text }
        return .refused
    }
    static func plain(_ error: Error) -> String {
        let words = (error as? LocalizedError)?.errorDescription ?? "it was refused."
        return String(words.prefix(300))
    }

    /// AI answers come from the same record as sessions_result, after the CLI's own turn-end receipt.
    /// The wait is separate from intake: a permission reply must reach the AI while it is still working.
    private func terminal(_ target: WhatsAppTarget, text: String, to: String) async {
        let before = await receivers.screen(target) ?? ""
        let record = await receivers.terminalRecord(target)
        let sentAt = clock.now().timeIntervalSince1970 * 1_000
        do { try await receivers.type(target, text: text + "\r") }
        catch { typingFor = nil; send("That did not reach the terminal: " + Self.plain(error), to: to); return }
        let reply = TerminalReply(target: target, text: text, to: to, before: before, sentAt: sentAt)
        guard record != nil else { await terminalScreen(reply); return }
        terminalWaiting?.cancel()
        terminalReply = reply
        terminalWaiting = Task { [weak self] in await self?.waitForTerminal(reply) }
    }

    private func waitForTerminal(_ reply: TerminalReply) async {
        let started = Date(timeIntervalSince1970: reply.sentAt / 1_000)
        while !Task.isCancelled, terminalReply?.id == reply.id {
            await clock.sleep(0.5)
            guard !Task.isCancelled else { return }
            await lookTerminal(reply)
            if clock.now().timeIntervalSince(started) >= Timing.terminalLongest { break }
        }
        // After 120 s intake stays free, and the normal watcher delivers a later turn end.
        if terminalReply?.id == reply.id { terminalWaiting = nil }
    }

    private func lookTerminal(_ reply: TerminalReply) async {
        guard terminalReply?.id == reply.id else { return }
        guard let record = await receivers.terminalRecord(reply.target) else {
            guard terminalReply?.id == reply.id else { return }
            terminalReply = nil; terminalWaiting = nil
            await terminalScreen(reply)
            return
        }
        guard let ended = record.endedAt, ended > reply.sentAt,
              let at = record.answeredAt, at > reply.sentAt, at <= ended,
              let answer = record.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty,
              terminalReply?.id == reply.id else { return }
        terminalReply = nil; terminalWaiting = nil; typingFor = nil; openApproval = nil
        if await read()?.isSending == true { send(answer, to: reply.to) }
    }

    private func terminalScreen(_ reply: TerminalReply) async {
        let started = Date(timeIntervalSince1970: reply.sentAt / 1_000)
        var last = reply.before, changedAt: Date?
        while !Task.isCancelled {
            await clock.sleep(0.5)
            let now = await receivers.screen(reply.target) ?? last
            if now != last { last = now; changedAt = clock.now() }
            if let changedAt, clock.now().timeIntervalSince(changedAt) >= Timing.terminalQuiet { break }
            if clock.now().timeIntervalSince(started) >= Timing.terminalLongest { break }
            if changedAt == nil, clock.now().timeIntervalSince(started) >= Timing.terminalQuiet * 3 { break }
        }
        guard !Task.isCancelled else { return }
        typingFor = nil
        let output = Self.cleanTerminal(Self.newLines(before: reply.before, after: last, maximumLines: nil), echo: reply.text)
        send(output.isEmpty ? Words.noOutput : "```\n" + output + "\n```", to: reply.to, format: false)
    }

    /// Shell fallback only. Keep command output, strip terminal chrome and undecodable glyphs before limiting lines.
    static func cleanTerminal(_ screen: String, echo: String) -> String {
        func spaces(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.compactMap { scalar in
                if scalar.value == 0xFFFD { return nil }
                let specialSpace = scalar.properties.generalCategory == .spaceSeparator || [0x09, 0x200B, 0x2060, 0xFEFF].contains(scalar.value)
                return specialSpace ? UnicodeScalar(0x20) : scalar
            }))
        }
        let echo = spaces(echo).trimmingCharacters(in: .whitespaces)
        var lines = spaces(screen).components(separatedBy: .newlines).compactMap { raw -> String? in
            let hadFrame = raw.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
            var content = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !(0x2500...0x257F).contains($0.value) }))
            while content.last?.isWhitespace == true { content.removeLast() }
            let line = content.trimmingCharacters(in: .whitespaces)
            if hadFrame && line.isEmpty { return nil }
            let prompt = #"^.*?[❯›$%#>]\s*(.*)$"#
            if let range = line.range(of: prompt, options: .regularExpression) {
                let tail = String(line[range]).replacingOccurrences(of: prompt, with: "$1", options: .regularExpression)
                if tail.isEmpty || tail == echo { return nil }
            }
            if line.range(of: #"^(?:[✻✽✢✶✳*]\s+.*\bfor\s+\d|Ran \d+ (?:shell command|tool)|[?] for shortcuts|.*(?:bypass permissions|accept edits) on|.*(?:context left|Context left|esc to interrupt))"#, options: .regularExpression) != nil { return nil }
            return hadFrame ? line : content
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.suffix(Timing.terminalLines).joined(separator: "\n")
    }

    /// The lines the terminal printed after `before` (the screen's last lines when it scrolled), at most 40.
    static func newLines(before: String, after: String, maximumLines: Int? = Timing.terminalLines) -> String {
        // Keep the row being edited: dropping a partial "$ " prefix would leave a bare command echo to send.
        let completeBefore = before.lastIndex(of: "\n").map { String(before[...$0]) } ?? ""
        let fresh = after.hasPrefix(before) ? String(after.dropFirst(completeBefore.count)) : after
        var lines = fresh.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return (maximumLines.map { Array(lines.suffix($0)) } ?? lines).joined(separator: "\n")
    }

    // MARK: The receiver's answers and approvals back to him (every final answer, wherever it was asked)

    private func watch() async {
        while !Task.isCancelled {
            await clock.sleep(Timing.watchEvery)
            guard !Task.isCancelled else { return }
            await look()
        }
    }

    /// One look at the receiver: a new final answer, a new approval, the typing indicator kept alive, an ended session.
    func look() async {
        guard let record = await read(), !record.removed, let to = record.creator else { return }
        if target == nil, record.receiver != .nowhere {
            target = try? await receivers.target(for: record.receiver, conversationName: record.name, agentID: agentID)
            seededTurn = false
        }
        guard let target else { return }
        if target.isTerminal {
            if let turn = await receivers.turn(target), record.isSending, case .needsApproval(let approvals) = turn.state {
                askApproval(approvals, target: target, to: to)
            }
            if let reply = terminalReply, terminalWaiting == nil { await lookTerminal(reply) }
            return
        }
        guard await receivers.isOpen(target) else {
            self.target = nil
            // Closed because it MOVED to another computer: not ended. The record stays as it is until the taker
            // rewrites it (receiver and reader there); nothing goes Nowhere, no "ended" line.
            if await holding() { return }
            if case .session = record.receiver { await update { $0.receiver = .nowhere; $0.endedSession = true } }
            return
        }
        guard let turn = await receivers.turn(target) else { return }
        // The switch off: nothing goes to WhatsApp; what ends meanwhile counts as given, so turning it on sends no backlog.
        guard record.isSending else {
            switch turn.state {
            case .done, .failed: deliveredTurn = turn.turnID; seededTurn = true
            case .needsApproval(let approvals): for approval in approvals { askedApprovals.insert(approval.id) }
            default: break
            }
            typingFor = nil
            return
        }
        // What was already there when this link began is not sent again.
        if !seededTurn {
            seededTurn = true
            switch turn.state {
            case .done, .failed, .idle: deliveredTurn = turn.turnID; return
            default: break
            }
        }
        switch turn.state {
        case .working:
            if let wamid = typingFor, clock.now().timeIntervalSince(typedAt ?? .distantPast) >= Timing.typingEvery {
                typedAt = clock.now()
                _ = await transport.markRead(key: key, messageID: wamid, typing: true)
            }
        case .needsApproval(let approvals):
            askApproval(approvals, target: target, to: to)
        case .done(let answer):
            guard turn.turnID != deliveredTurn else { return }
            deliveredTurn = turn.turnID; typingFor = nil; openApproval = nil
            let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { send(clean, to: to) }
        case .failed(let reason):
            guard turn.turnID != deliveredTurn else { return }
            deliveredTurn = turn.turnID; typingFor = nil; openApproval = nil
            send(reason, to: to)
        case .idle: break
        }
    }

    private func askApproval(_ approvals: [WhatsAppApproval], target: WhatsAppTarget, to: String) {
        // One question at a time; keep the existing approval IDs and 1/2 reply path.
        if let open = openApproval, approvals.contains(where: { $0.id == open.id }) { return }
        openApproval = nil
        if let next = approvals.first(where: { !askedApprovals.contains($0.id) }) {
            askedApprovals.insert(next.id)
            openApproval = (target, next.id, clock.now())
            send(Self.approvalText(next), to: to, format: false)
        }
    }

    static func approvalText(_ approval: WhatsAppApproval) -> String {
        var lines = [approval.summary.trimmingCharacters(in: .whitespacesAndNewlines)]
        let detail = approval.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { lines.append("```\n" + String(detail.prefix(3000)) + "\n```") }
        lines.append(Words.reply)
        return lines.joined(separator: "\n\n")
    }

    // MARK: Sends, strictly one after another

    /// Formatted for WhatsApp (unless already), split at 4096, each piece after the one before. Only ever to `to`,
    /// which is always an inbound `from` (the creator).
    func send(_ text: String, to: String, format: Bool = true) {
        let pieces = WhatsAppText.split(format ? WhatsAppText.format(text) : text)
        let previous = outbox
        let key = key, transport = transport, clock = clock
        outbox = Task {
            await previous?.value
            for piece in pieces {
                var tries = 0
                while tries < 3 {
                    tries += 1
                    switch await transport.send(key: key, to: to, text: piece) {
                    case .backOff(let seconds): await clock.sleep(max(1, seconds)); continue
                    default: break
                    }
                    break
                }
            }
        }
    }
    /// Waits until everything queued has been sent (tests, and a tool's send).
    func flushed() async { await outbox?.value }
}
