/**
 * Noticing that something happened on a machine, and deciding whether it is
 * worth a person's attention.
 *
 * This is the reason to have this app on a phone at all. Everything else here —
 * the terminal, the key bar, the tunnel — is for when you have already decided
 * to look. This is the part that tells you to look: an agent has stopped and is
 * waiting for an answer, or the thing you started twenty minutes ago has
 * finished. Without it the phone is a window you have to keep opening.
 *
 * ## What it is, and what it is honestly not
 *
 * It is **transitions in the session list**, computed on this phone from the
 * frames the desktop already sends. A session that was `working` and is now
 * `waiting` wants you; one that was `working` and is now `completed` is done.
 * No new wire verb, no polling, nothing the desktop has to be taught.
 *
 * It is **not** a push notification service, and the difference matters to
 * anybody relying on it. A phone with this app suspended in a pocket is not
 * running, its socket is gone, and nothing on the relay is allowed to wake it —
 * there is no APNs certificate in this product and no server holding one. So an
 * alert can only be raised while the app is running: in the foreground, or in
 * the grace window iOS gives after you put the phone down (see
 * `BackgroundGrace`). Anything that happened while it was asleep is caught up on
 * the next connection and reported as a summary rather than pretended to be
 * live. `AlertsView` says exactly this on screen, because a person deciding
 * whether to trust a notification deserves to know what it cannot promise.
 *
 * ## Why transitions and not states
 *
 * A state would fire every time the list arrived. Connect to a machine with
 * three sessions sitting at a prompt and you would be told three times about
 * something that happened while you were asleep, every time the socket blinked.
 * A transition fires once, when it changes, which is also the only moment that
 * is news.
 *
 * The first list from a machine therefore *seeds* and announces nothing. That is
 * deliberate and it is the same rule: a session that was already waiting before
 * this phone ever heard of it did not just start waiting.
 */

import Foundation

/// The desktop's status vocabulary, as far as this file needs to read it.
///
/// Free-form on the wire — the vocabulary belongs to the desktop and a newer
/// build may send a word this one has never seen — so unknown statuses fall
/// through every set here and produce no alert, rather than being guessed at.
enum SessionStatusWords {
    /// The session has stopped and cannot continue without a person. This is the
    /// alert people install the app for.
    static let wantsYou: Set<String> = ["waiting", "input"]
    /// The agent finished its turn. The work is done; nothing is being asked.
    static let finished = "completed"
    /// The process is gone.
    static let ended = "exited"
}

/// One thing worth telling somebody about.
struct SessionAlert: Equatable {
    enum Kind: Equatable {
        /// Stopped and asking. Makes a sound.
        case needsYou
        /// Finished its turn, or the process ended. Arrives quietly.
        case finished
    }

    let hostId: String
    let hostName: String
    let sessionId: String
    let sessionTitle: String
    let kind: Kind
    /// Only on a session that actually exited, and only when the desktop said.
    let exitCode: Int?

    /// The line at the top of the notification. The session's own name, because
    /// that is what the person recognises — it is the folder they are working
    /// in, and it is what the row in the list says too.
    var title: String { sessionTitle }

    /**
     * The line underneath, which has to answer "so what" on a lock screen.
     *
     * Named machine and all: a phone paired with three computers cannot say
     * "waiting for you" and leave somebody guessing which one they have to walk
     * over to.
     */
    var body: String {
        switch kind {
        case .needsYou:
            return "Waiting for you on \(hostName)."
        case .finished:
            if let exitCode, exitCode != 0 {
                return "Stopped on \(hostName) — exit \(exitCode)."
            }
            return exitCode == nil ? "Finished on \(hostName)." : "Ended on \(hostName)."
        }
    }

    /**
     * One session, named the same way everywhere.
     *
     * It is the notification's `threadIdentifier`, so a machine's alerts group
     * instead of stacking as four unrelated banners; it is also its *request*
     * identifier, which is what makes a second alert about the same session
     * replace the first rather than pile on top of it; and it is the key
     * `DeckModel` files "when he left this session" under. Three uses, one
     * spelling — a second one would let two of them disagree about which
     * session they meant.
     */
    var thread: String { Self.thread(hostId: hostId, sessionId: sessionId) }

    static func thread(hostId: String, sessionId: String) -> String {
        "\(hostId).\(sessionId)"
    }
}

/// Whether a batch of changes is news or a catch-up.
///
/// The distinction only matters for what is *done* with the alerts, not for
/// whether they are raised: a reconnect that lands while the app is on screen
/// is somebody watching the list refill, and interrupting them with four
/// banners about it is worse than a line of text. See `DeckModel`.
enum AlertReason: Equatable {
    /// A frame arrived on a connection that was already up.
    case live
    /// The first list after a connection came back. What is in it happened while
    /// this phone was not listening.
    case catchUp
}

/**
 * What each session was doing last time anybody looked.
 *
 * Keyed by machine and then by session, because session ids are unique per host
 * and nothing makes them unique across hosts — a single flat dictionary would
 * let one machine's session id shadow another's and report the wrong machine's
 * work as finished.
 */
@MainActor
final class SessionAlerts {

    private var known: [String: [String: String]] = [:]

    /// What this phone saw last, for the tests and for nothing else.
    func lastKnownStatus(host: String, session: String) -> String? {
        known[host]?[session]
    }

    /**
     * Take a machine's session list and say what is worth mentioning.
     *
     * Returns nothing at all the first time it sees a machine — see the header.
     * Sessions that have vanished from the list are forgotten rather than
     * reported: a session the desktop has stopped listing is one this phone can
     * no longer say anything true about.
     */
    func observe(hostId: String,
                 hostName: String,
                 sessions: [RemoteSession]) -> [SessionAlert] {
        let previous = known[hostId]
        var current: [String: String] = [:]
        var alerts: [SessionAlert] = []

        for session in sessions {
            current[session.id] = session.status
            guard let previous else { continue }
            guard let was = previous[session.id] else {
                /*
                 * A session that was not in the previous list.
                 *
                 * Silent, even when it arrives already waiting. It is either one
                 * this phone just asked for — in which case the person is
                 * looking at it — or one somebody started on the desktop, and
                 * "a new session exists" is not a thing to interrupt anybody
                 * for. What is worth an alert is that session *changing* later,
                 * which the next list will catch.
                 */
                continue
            }
            guard was != session.status else { continue }
            if let kind = kind(from: was, to: session.status) {
                alerts.append(SessionAlert(hostId: hostId,
                                           hostName: hostName,
                                           sessionId: session.id,
                                           sessionTitle: session.title,
                                           kind: kind,
                                           exitCode: session.status == SessionStatusWords.ended
                                               ? session.exitCode : nil))
            }
        }

        known[hostId] = current
        return alerts
    }

    /// A machine that was unpaired, or taken down. Its sessions are not going to
    /// change again, and keeping them would make a re-pair look like a machine
    /// where everything happened at once.
    func forget(hostId: String) {
        known.removeValue(forKey: hostId)
    }

    /**
     * Which transitions are news.
     *
     * Into "wants you" from anything else, and into a finished state from
     * anything that was still going. Deliberately narrow:
     *
     *  - **Nothing for `working`.** A session starting work is the app doing
     *    what it was told; being buzzed about it is how people turn
     *    notifications off.
     *  - **Nothing for a session that was already finished.** `completed` →
     *    `exited` is one thing ending twice as far as a person is concerned.
     *  - **Nothing for a word this build does not know.** The vocabulary belongs
     *    to the desktop and a newer one may add to it; guessing what an unknown
     *    status means is how an app invents an event.
     */
    private func kind(from was: String, to now: String) -> SessionAlert.Kind? {
        if SessionStatusWords.wantsYou.contains(now) {
            return SessionStatusWords.wantsYou.contains(was) ? nil : .needsYou
        }
        if now == SessionStatusWords.finished || now == SessionStatusWords.ended {
            let alreadyDone = was == SessionStatusWords.finished || was == SessionStatusWords.ended
            return alreadyDone ? nil : .finished
        }
        return nil
    }
}

/**
 * The one line the session list shows after the app has been away.
 *
 * Written here rather than in the view because it is a counting sentence with
 * three shapes and an "and", which is exactly the kind of string that ends up
 * saying "1 sessions" in one of them.
 */
enum AwayReport {
    static func sentence(for alerts: [SessionAlert]) -> String? {
        guard !alerts.isEmpty else { return nil }
        let waiting = alerts.filter { $0.kind == .needsYou }.count
        let finished = alerts.filter { $0.kind == .finished }.count

        var parts: [String] = []
        if waiting > 0 {
            parts.append(waiting == 1 ? "1 session needs you" : "\(waiting) sessions need you")
        }
        if finished > 0 {
            parts.append(finished == 1 ? "1 finished" : "\(finished) finished")
        }
        return "While you were away: \(parts.joined(separator: ", "))."
    }
}
