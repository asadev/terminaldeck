import Foundation
import TerminalDeckNativeCore

/// 14 Nov phone link, the root on the Mac's side (Asad: "If I type something, it takes half a minute to reach my
/// terminal ... the connection stopped kind of thing is coming again and again"). Every message to a phone or the web
/// rides one ordered, reliable data channel (`td.ctl`), and before this the Mac handed the channel everything at once:
/// a busy session's output queued there without limit, and the heartbeat's answer and the echo of what he typed waited
/// behind it until the phone gave up (its pong grace is 10 s).
///
/// Now the channel is handed only as much as keeps its own queue under `lowMark`; the rest waits here, in two classes:
/// - `answer`: the heartbeat answer (`pong`) and every frame with a TOP-LEVEL `rid` (the answer to one of his own
///   requests, an `error` with a rid included). Always first.
/// - `stream`: everything else (terminal output and its replay, session lists, unasked lists, chat pages, browser
///   pictures), in the order it came.
/// Newest only, among frames still waiting in `stream`: a whole list sent again on change (`sessions`, `folders`), an
/// unasked `panel.rows` for the same panel, path and view (also dropped when any answer for that list arrives), and a
/// browser window's picture (`browser.frame`): a newer one replaces the waiting one, at the back.
/// A session whose live output waits here past `mostSessionBacklogBytes` or `mostSessionBacklogMs` has that output
/// dropped for this connection only, and the host sends the session afresh (`attached`, its screen, its status: what a
/// re-open sends), after which its live output goes on. More than `mostWaitingBytes` waiting in all ends the link (the
/// phone reconnects as after any link failure). No new frame type or field: an older phone sees only frames it knows.
final class BackendRemoteLinkOutbox: @unchecked Sendable {
    enum Class: Equatable { case answer, stream }
    /// The channel's own queue is topped up only while it holds at most this many bytes (what is already handed to the
    /// channel cannot be overtaken, so this is what an answer can still wait behind: under a second at 20 KB/s).
    static let lowMark: UInt64 = 16 * 1024
    /// An answer is handed to the channel while it holds at most this much (more means the link itself is failing).
    static let answerMark: UInt64 = 64 * 1024
    /// A session's live output waiting here for one connection, at most.
    static let mostSessionBacklogBytes = 256 * 1024
    static let mostSessionBacklogMs: Double = 2_000
    /// Everything waiting here for one link, at most (more: the link ends).
    static let mostWaitingBytes = 2 * 1024 * 1024
    /// Why a link ends over `mostWaitingBytes` (the host logs it as "link: ended …").
    static let tooMuchWaited = "More than 2 MB waited for the direct link."
    /// The channel says when its queue is low; this timer is only the safety net (ms).
    static let pollMs = 100
    /// More than `lowMark` waiting (here and in the channel) for this long: the link is slow (ms).
    static let slowAfterMs: Double = 1_000
    /// 14 Nov 18:20Z (0220zd, his phone over TURN: answers arrived, session screens never did): the channel's own
    /// reading of its queue cannot be trusted to fall. The stream class is never starved: when nothing of it has left
    /// for `starveMs` while something waits, it goes while the channel reads at most `starvedMark`, and at least one
    /// frame a `starveMs` whatever the channel reads (correctness before pacing). Each episode is logged once.
    static let starveMs: Double = 1_000
    static let starvedMark: UInt64 = 256 * 1024
    /// A stream frame that waited longer than this is logged (at most once per `waitLogEveryMs` per link).
    static let waitLogMs: Double = 2_000
    static let waitLogEveryMs: Double = 10_000
    /// Whole lists sent again on change, unasked: only the newest waiting one goes.
    static let newestOnly: Set<String> = ["sessions", "folders"]

    struct Item {
        let data: Data
        let type: String
        let answer: Bool
        let session: String?
        /// Live terminal output (not a replay): what counts toward a session's backlog.
        let live: Bool
        /// What a newer frame of the same kind replaces while this one waits (nil: nothing).
        let replaceKey: String?
        /// A `panel.rows` list's panel, path and view (asked or not).
        let listKey: String?
        let at: Double
    }

    private let lock = NSLock()
    private var answers: [Item] = []
    private var stream: [Item] = []
    private var total = 0
    private var backlog: [String: Int] = [:]
    private var resyncing: Set<String> = []
    private var stopped = false
    private var polling = false
    private var overSince: Double?
    /// When a stream frame last left (or the stream last started waiting), the last forced frame, a logged episode.
    private var streamMovedAt: Double = 0
    private var forcedAt: Double = 0
    private var starving = false
    private var waitLoggedAt: Double = -.infinity
    /// A session's `attached` that left, waiting for its `status` (the end of the screen): when it was put.
    private var screens: [String: Double] = [:]
    private let log: @Sendable (String) -> Void
    private let label: @Sendable () -> String
    private let send: @Sendable (Data) -> Bool
    private let queued: @Sendable () -> UInt64
    private let now: @Sendable () -> Double
    private let failed: @Sendable (String) -> Void
    private let resync: @Sendable (String) -> Void
    private let listsLost: @Sendable () -> Void
    /// link.keep (17 Nov): a failed hand to the channel keeps what waits (the frame included) for `takeAll`, so the
    /// connection can carry it over the relay; `droppedAll` says something waiting was thrown away instead.
    var keepOnFailure = false
    private var droppedAll = false

    init(send: @escaping @Sendable (Data) -> Bool, queued: @escaping @Sendable () -> UInt64,
         now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 },
         failed: @escaping @Sendable (String) -> Void, resync: @escaping @Sendable (String) -> Void,
         listsLost: @escaping @Sendable () -> Void = {}, log: @escaping @Sendable (String) -> Void = { _ in },
         label: @escaping @Sendable () -> String = { "a device" }) {
        self.send = send; self.queued = queued; self.now = now; self.failed = failed; self.resync = resync; self.listsLost = listsLost
        self.log = log; self.label = label
    }

    /// Which class a serialized frame is in: `pong`, or a top-level `rid` (never a rid deep inside a list or a page).
    static func classOf(_ text: String) -> Class { parse(text).answer ? .answer : .stream }

    private static func parse(_ text: String) -> (type: String, answer: Bool, value: NativeRPCValue?) {
        let type = BackendRemoteLinkPath.type(of: text).map(String.init) ?? ""
        if type == "pong" { return (type, true, nil) }
        // Terminal output and pictures never answer a request: not decoded for that (they are the bulk).
        if type == "output" || type == "browser.frame" { return (type, false, nil) }
        let value = try? NativeRPCValue.parseJSON(Data(text.utf8))
        return (type, value?["rid"].string != nil, value)
    }

    private func item(_ text: String) -> Item {
        let (type, answer, value) = Self.parse(text)
        var session: String?, replaceKey: String?, listKey: String?
        switch type {
        case "output": session = Self.leadingField("id", in: text)
        case "attached", "status": session = value?["id"].string
        case "browser.frame": replaceKey = Self.leadingField("window", in: text).map { "browser.frame\u{0}" + $0 }
        case "panel.rows":
            listKey = [value?["panel"].string ?? "", value?["path"].string ?? "", value?["view"].string ?? ""].joined(separator: "\u{0}")
            if !answer { replaceKey = listKey.map { "panel.rows\u{0}" + $0 } }
        default:
            if Self.newestOnly.contains(type) { replaceKey = type }
        }
        let live = type == "output" && !text.contains(#""replay":true"#)
        return Item(data: Data(text.utf8), type: type, answer: answer, session: session, live: live,
                    replaceKey: replaceKey, listKey: listKey, at: now())
    }

    /// A bulk frame's leading string field without decoding its data (`output`: `id`; `browser.frame`: `window`; the
    /// host serializes fields in schema order, right after `t`).
    static func leadingField(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "\"" + name + "\":\"") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Takes one frame; false once the link has failed (nothing more goes).
    @discardableResult
    func put(_ text: String) -> Bool {
        let entry = item(text)
        var dropped: String?, over = false, lost = false
        let open = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            if entry.type == "attached", let session = entry.session { resyncing.remove(session) }
            // Output older than the fresh screen that is on its way: that screen already holds it.
            if entry.type == "output", let session = entry.session, resyncing.contains(session) { return true }
            // Any answer for a list makes a waiting unasked copy of it stale: it must never land after the answer.
            if let listKey = entry.listKey { remove { $0.type == "panel.rows" && !$0.answer && $0.listKey == listKey } }
            if let key = entry.replaceKey { remove { $0.replaceKey == key } }
            if entry.answer { answers.append(entry) } else {
                if stream.isEmpty { streamMovedAt = entry.at }
                stream.append(entry)
            }
            total += entry.data.count
            if total > Self.mostWaitingBytes {
                lost = stopAll(); over = true; droppedAll = true
                return true
            }
            if entry.live, let session = entry.session {
                backlog[session, default: 0] += entry.data.count
                if backlog[session, default: 0] > Self.mostSessionBacklogBytes { dropBacklog(session); dropped = session }
            }
            return true
        }
        if over {
            if lost { listsLost() }
            failed(Self.tooMuchWaited)
            return false
        }
        if let dropped { resync(dropped) }
        guard open else { return false }
        pump()
        return true
    }

    /// Removes waiting stream frames (under the lock).
    private func remove(_ match: (Item) -> Bool) {
        stream.removeAll { item in
            guard match(item) else { return false }
            total -= item.data.count
            if item.live, let session = item.session {
                let left = (backlog[session] ?? 0) - item.data.count
                backlog[session] = left > 0 ? left : nil
            }
            return true
        }
    }

    /// The session's queued output for this connection goes (under the lock); the host sends it afresh.
    private func dropBacklog(_ session: String) {
        remove { $0.type == "output" && $0.session == session }
        backlog[session] = nil
        resyncing.insert(session)
    }

    /// Everything waiting goes (under the lock); true when an unasked list was among it.
    private func stopAll() -> Bool {
        let lost = stream.contains { $0.type == "panel.rows" && !$0.answer }
        stopped = true; answers = []; stream = []; total = 0; backlog = [:]
        return lost
    }

    /// A fresh screen could not be sent (the session is gone, or no replay source): live output goes on as it comes.
    func resyncAbandoned(_ session: String) { lock.withLock { _ = resyncing.remove(session) } }

    /// Hands the channel what it can take now; true while something still waits. The channel's low-water notice and,
    /// as a safety net, a slow timer call it again.
    @discardableResult
    func pump() -> Bool {
        var failedNow = false, lost = false, stale: [String] = [], notes: [String] = []
        let waiting = lock.withLock { () -> Bool in
            while !stopped {
                let inChannel = queued()
                let next: Item
                let at = now()
                // A starvation episode: nothing of the stream left for `starveMs`. It lasts until the channel reads
                // `lowMark` or less again (a reading that never falls must not slow the stream to a frame a second).
                if inChannel <= Self.lowMark { starving = false }
                else if !stream.isEmpty, !starving, at - streamMovedAt > Self.starveMs {
                    starving = true
                    notes.append("link: \(label()) had nothing of the stream leave for \(Int(at - streamMovedAt)) ms while the channel read \(inChannel / 1024) KB waiting; sent anyway")
                }
                let force = starving && at - forcedAt >= Self.starveMs
                let answerLimit = starving ? Self.starvedMark : Self.answerMark
                // An answer is small and goes at once unless the channel is far behind (`answerMark`); it always goes
                // before the stream, starving or not.
                if !answers.isEmpty {
                    guard inChannel <= answerLimit || force else { break }
                    if inChannel > answerLimit { forcedAt = at }
                    next = answers.removeFirst()
                }
                else if inChannel > (starving ? Self.starvedMark : Self.lowMark), !force { break }
                else if let head = stream.first {
                    // Over `starvedMark` while starving: one frame a `starveMs`, whatever the channel reads.
                    if inChannel > Self.starvedMark { forcedAt = at }
                    if head.live, let session = head.session, now() - head.at > Self.mostSessionBacklogMs {
                        dropBacklog(session); stale.append(session); continue
                    }
                    next = stream.removeFirst()
                    streamMovedAt = at
                    if next.live, let session = next.session {
                        let left = (backlog[session] ?? 0) - next.data.count
                        backlog[session] = left > 0 ? left : nil
                    }
                    if at - next.at > Self.waitLogMs, at - waitLoggedAt > Self.waitLogEveryMs {
                        waitLoggedAt = at
                        notes.append("link: a \(next.type) waited \(Int(at - next.at)) ms in the outbox for \(label())")
                    }
                    if let session = next.session {
                        if next.type == "attached" { screens[session] = next.at }
                        if next.type == "status", let put = screens.removeValue(forKey: session) {
                            notes.append("open: screen \(session.prefix(8)) left for \(label()) in \(Int(at - put)) ms")
                        }
                    }
                } else { break }
                total -= next.data.count
                if !send(next.data) {
                    if keepOnFailure {
                        if next.answer { answers.insert(next, at: 0) } else { stream.insert(next, at: 0) }
                        total += next.data.count; stopped = true
                    } else { lost = stopAll(); droppedAll = true }
                    failedNow = true
                }
            }
            noteSlow()
            let more = !stopped && (!answers.isEmpty || !stream.isEmpty)
            if more && !polling { polling = true; startPolling() }
            return more
        }
        for note in notes { log(note) }
        for session in stale { resync(session) }
        if lost { listsLost() }
        if failedNow { failed("A message could not go on the direct link.") }
        return waiting
    }

    /// Whether more than `lowMark` waits, here and in the channel, and since when (under the lock).
    private func noteSlow() {
        if UInt64(total) + queued() > Self.lowMark { overSince = overSince ?? now() } else { overSince = nil }
    }
    /// More than `lowMark` has been waiting for over `slowAfterMs`: frames that can be made smaller should be.
    var isSlow: Bool { lock.withLock { noteSlow(); return overSince.map { now() - $0 > Self.slowAfterMs } ?? false } }

    private func startPolling() {
        Task.detached { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(Self.pollMs))
                guard let self else { return }
                if !self.pump() {
                    let done = self.lock.withLock { () -> Bool in
                        if self.answers.isEmpty && self.stream.isEmpty || self.stopped { self.polling = false; return true }
                        return false
                    }
                    if done { return }
                }
            }
        }
    }

    /// The link is replaced or ends: what waits is dropped (answers included: a link-only connection closes with its
    /// link, and the phone asks again on the next one). An unasked list among it is reported lost, so the host does not
    /// count it as delivered (`listsLost`).
    func stop() {
        let lost = lock.withLock { () -> Bool in
            let waited = !answers.isEmpty || !stream.isEmpty
            return stopped && !waited ? false : stopAll()
        }
        if lost { listsLost() }
    }
    /// Bytes waiting here.
    var waitingBytes: Int { lock.withLock { total } }
    /// link.keep: stops and hands back everything that waits, in the order it would have gone (answers, then the
    /// stream); nil when something waiting was already thrown away (then the connection cannot carry on safely).
    func takeAll() -> [Data]? {
        lock.withLock { () -> [Data]? in
            defer { stopped = true; answers = []; stream = []; total = 0; backlog = [:] }
            return droppedAll ? nil : (answers + stream).map(\.data)
        }
    }
}
