import Foundation
import TerminalDeckNativeCore

/// The one door other parts of the app use to tell the memory flow something happened.
/// Every call returns at once, never throws and never blocks the caller: a session's
/// launch, a hook or Hoot's reply must not wait for memory. Signals that arrive before
/// the flow has started are kept (bounded) and delivered when it starts.
///
/// L8 HOST: call `DeckMemoryFlowInbox.sessionTurnEnded(_:)` when a terminal session's
/// agent finished its answer and stopped (Claude Stop hook; Codex/Gemini quiet edge).
/// L6 HOOT: nothing to call (the flow listens to Hoot's own event stream).
public enum DeckMemoryFlowInbox {
    public enum Signal: Sendable, Equatable {
        case sessionTurnEnded(DeckMemoryFlowTurn)
        /// A session did something worth reading its record for (a prompt went in, a tool ran).
        case sessionActivity(sessionID: String, at: Double)
        /// The person said "you should have noted X".
        case correction(text: String, ownerKey: String?, at: Double)
    }
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (Signal) -> Void)?
        var waiting: [Signal] = []
        var catchUp: (@Sendable (String, Double) async -> Bool)?
        var typed: [String: [Typed]] = [:]
    }
    private struct Typed: Sendable { var text: String; var author: DeckMemoryAuthor; var givenBy: String?; var at: Double }

    /// Read what this session said since the helper last looked and bring its notes and
    /// "where we are" topics up to date NOW, without the usual pause.
    /// true = up to date; false = it took longer than `timeout` seconds, the helper is off, or
    /// the flow has not started. Nothing is lost on false: the diary has it and the normal
    /// job still runs. `session` is the app's session id.
    public static func catchUp(session: String, timeout: Double = 60) async -> Bool {
        guard let work = box.lock.withLock({ box.catchUp }) else { return false }
        return await work(session, max(1, timeout))
    }
    public static func attachCatchUp(_ work: (@Sendable (String, Double) async -> Bool)?) {
        box.lock.withLock { box.catchUp = work }
    }
    private static let box = Box()
    static let maximumWaiting = 256

    public static func sessionTurnEnded(_ turn: DeckMemoryFlowTurn) { post(.sessionTurnEnded(turn)) }
    public static func sessionActivity(sessionID: String, at: Double = Date().timeIntervalSince1970 * 1000) {
        post(.sessionActivity(sessionID: sessionID, at: at))
    }
    /// A correction is appended to the checklist, so the helper notes that kind of thing from now on.
    public static func correction(_ text: String, ownerKey: String? = nil, at: Double = Date().timeIntervalSince1970 * 1000) {
        post(.correction(text: text, ownerKey: ownerKey, at: at))
    }

    public static func post(_ signal: Signal) {
        let deliver: (@Sendable (Signal) -> Void)? = box.lock.withLock {
            if let handler = box.handler { return handler }
            if box.waiting.count >= maximumWaiting { box.waiting.removeFirst() }
            box.waiting.append(signal)
            return nil
        }
        deliver?(signal)
    }
    /// The running flow takes the door. Signals kept so far are handed over in order.
    public static func attach(_ handler: @escaping @Sendable (Signal) -> Void) {
        let kept: [Signal] = box.lock.withLock {
            box.handler = handler
            defer { box.waiting = [] }
            return box.waiting
        }
        for signal in kept { handler(signal) }
    }
    public static func detach() { box.lock.withLock { box.handler = nil; box.catchUp = nil } }
    /// For checks only.
    static func resetForTesting() { box.lock.withLock { box.handler = nil; box.waiting = []; box.catchUp = nil; box.typed = [:] } }

    // MARK: Who really typed a message

    /// The "user" side of a terminal session is not always the person: Hoot, a lead or the task
    /// engine type into sessions too. Whoever makes the app type `text` into a session calls this
    /// right after the write (L6 HOOT: sessions.start's delivery line and sessions.send). The diary
    /// then stamps that message with its real author, and only the person's own words can become a
    /// preference, a correction or a checklist line. Returns at once.
    ///
    /// The task engine (FORK-TASKS): a brief, or a comment passed on into a session, is typed by the
    /// APP, so `by: .app`, with `givenBy` saying whose task or words it carries: "person",
    /// "orchestrator" (Hoot), or "agent:<id>". The diary keeps it beside the row (`given_by`).
    public static func typed(sessionID: String, text: String, by author: DeckMemoryAuthor, givenBy: String? = nil,
                             at: Double = Date().timeIntervalSince1970 * 1000) {
        let wanted = squeeze(text)
        guard !sessionID.isEmpty, !wanted.isEmpty else { return }
        let giver = givenBy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
        box.lock.withLock {
            var list = (box.typed[sessionID] ?? []).filter { at - $0.at < typedLifetime }
            list.append(.init(text: wanted, author: author, givenBy: giver, at: at))
            if list.count > maximumTyped { list.removeFirst(list.count - maximumTyped) }
            box.typed[sessionID] = list
        }
    }
    /// Hoot typed this into the session (not the person).
    public static func typedByOrchestrator(sessionID: String, text: String, at: Double = Date().timeIntervalSince1970 * 1000) {
        typed(sessionID: sessionID, text: text, by: .orchestrator, at: at)
    }
    /// For the capture: who the app typed this message for, if it did. One typed text answers for one message.
    static func typedAuthor(sessionID: String, text: String) -> DeckMemoryAuthor? { typedSender(sessionID: sessionID, text: text)?.author }
    /// The same, with whose task or words the app was carrying when it typed (nil when nobody said).
    static func typedSender(sessionID: String, text: String) -> (author: DeckMemoryAuthor, givenBy: String?)? {
        let said = squeeze(text)
        guard !said.isEmpty else { return nil }
        return box.lock.withLock {
            guard var list = box.typed[sessionID], let index = list.firstIndex(where: { matches($0.text, said) }) else { return nil }
            let found = list.remove(at: index)
            box.typed[sessionID] = list.isEmpty ? nil : list
            return (found.author, found.givenBy)
        }
    }
    /// A session closed: what was typed into it is forgotten.
    static func forgetTyped(sessionID: String) { box.lock.withLock { box.typed[sessionID] = nil } }

    static let typedLifetime = 3_600_000.0, maximumTyped = 32
    static func squeeze(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ") }
    /// The same words, or one inside the other when it is long enough not to be a coincidence
    /// (a CLI may show a typed brief with a line added before or after it).
    static func matches(_ typed: String, _ said: String) -> Bool {
        if typed == said { return true }
        let short = typed.count <= said.count ? typed : said, long = typed.count <= said.count ? said : typed
        return short.count >= 40 && long.contains(short)
    }
}
