package dev.terminaldeck.android.alerts

import dev.terminaldeck.android.protocol.RemoteSessionView

/**
 * Noticing that something happened on a machine, and deciding whether it is worth a person's
 * attention.
 *
 * This is the reason to have this app on a phone at all. Everything else here — the terminal, the
 * key bar, the tunnel — is for when you have already decided to look. This is the part that tells
 * you to look: an agent has stopped and is waiting for an answer, or the thing you started twenty
 * minutes ago has finished. Without it the phone is a window you have to keep opening.
 *
 * A transcription of `ios/TerminalDeck/App/SessionAlerts.swift`, and the reasoning is that file's.
 *
 * ## What it is, and what it is honestly not
 *
 * It is **transitions in the session list**, computed on this phone from the frames the desktop
 * already sends. A session that was `working` and is now `waiting` wants you; one that was `working`
 * and is now `completed` is done. No new wire verb, no polling, nothing the desktop has to be
 * taught.
 *
 * It is **not** a push notification service, and the difference matters to anybody relying on it. A
 * phone with this app killed in a pocket is not running, its socket is gone, and nothing on the
 * relay is allowed to wake it — there is no FCM key in this product and no server holding one. So an
 * alert can only be raised while the app's process is alive. Anything that happened while it was
 * gone is caught up on the next connection and reported as a summary rather than pretended to be
 * live. [AwayReport] is that summary and `AlertsScreen` says exactly this on screen, because a
 * person deciding whether to trust a notification deserves to know what it cannot promise.
 *
 * ## Why transitions and not states
 *
 * A state would fire every time the list arrived. Connect to a machine with three sessions sitting
 * at a prompt and you would be told three times about something that happened while you were asleep,
 * every time the socket blinked. A transition fires once, when it changes, which is also the only
 * moment that is news.
 *
 * The first list from a machine therefore *seeds* and announces nothing. That is deliberate and it
 * is the same rule: a session that was already waiting before this phone ever heard of it did not
 * just start waiting.
 */
class SessionAlerts {

    /**
     * What each session was doing last time anybody looked.
     *
     * Keyed by machine and then by session, because session ids are unique per host and nothing
     * makes them unique across hosts — a single flat map would let one machine's session id shadow
     * another's and report the wrong machine's work as finished.
     */
    private val known = HashMap<String, Map<String, String>>()

    /** What this phone saw last, for the tests and for nothing else. */
    fun lastKnownStatus(host: String, session: String): String? = known[host]?.get(session)

    /**
     * Take a machine's session list and say what is worth mentioning.
     *
     * Returns nothing at all the first time it sees a machine — see the header. Sessions that have
     * vanished from the list are forgotten rather than reported: a session the desktop has stopped
     * listing is one this phone can no longer say anything true about.
     */
    fun observe(hostId: String, hostName: String, sessions: List<RemoteSessionView>): List<SessionAlert> {
        val previous = known[hostId]
        val current = HashMap<String, String>(sessions.size)
        val alerts = mutableListOf<SessionAlert>()

        for (session in sessions) {
            current[session.id] = session.status
            if (previous == null) continue
            /*
             * A session that was not in the previous list is silent, even when it arrives already
             * waiting. It is either one this phone just asked for — in which case the person is
             * looking at it — or one somebody started at the desk, and "a new session exists" is not
             * a thing to interrupt anybody for. What is worth an alert is that session *changing*
             * later, which the next list will catch.
             */
            val was = previous[session.id] ?: continue
            if (was == session.status) continue
            val kind = kind(was, session.status) ?: continue
            alerts += SessionAlert(
                hostId = hostId,
                hostName = hostName,
                sessionId = session.id,
                sessionTitle = session.title,
                kind = kind,
                exitCode = if (session.status == SessionStatusWords.ENDED) session.exitCode else null,
            )
        }

        known[hostId] = current
        return alerts
    }

    /**
     * A machine that was unpaired, or taken down.
     *
     * Its sessions are not going to change again, and keeping them would make a re-pair look like a
     * machine where everything happened at once.
     */
    fun forget(hostId: String) {
        known.remove(hostId)
    }

    /**
     * Which transitions are news.
     *
     * Into "wants you" from anything else, and into a finished state from anything that was still
     * going. Deliberately narrow:
     *
     *  - **Nothing for `working`.** A session starting work is the app doing what it was told; being
     *    buzzed about it is how people turn notifications off.
     *  - **Nothing for a session that was already finished.** `completed` → `exited` is one thing
     *    ending twice as far as a person is concerned.
     *  - **Nothing for a word this build does not know.** The vocabulary belongs to the desktop and a
     *    newer one may add to it; guessing what an unknown status means is how an app invents an
     *    event.
     */
    private fun kind(was: String, now: String): SessionAlert.Kind? {
        if (now in SessionStatusWords.WANTS_YOU) {
            return if (was in SessionStatusWords.WANTS_YOU) null else SessionAlert.Kind.NeedsYou
        }
        if (now == SessionStatusWords.FINISHED || now == SessionStatusWords.ENDED) {
            val alreadyDone = was == SessionStatusWords.FINISHED || was == SessionStatusWords.ENDED
            return if (alreadyDone) null else SessionAlert.Kind.Finished
        }
        return null
    }
}

/**
 * The desktop's status vocabulary, as far as this file needs to read it.
 *
 * Free-form on the wire — the vocabulary belongs to the desktop and a newer build may send a word
 * this one has never seen — so unknown statuses fall through every set here and produce no alert,
 * rather than being guessed at.
 */
object SessionStatusWords {
    /** The session has stopped and cannot continue without a person. The alert people install for. */
    val WANTS_YOU: Set<String> = setOf("waiting", "input")

    /** The agent finished its turn. The work is done; nothing is being asked. */
    const val FINISHED = "completed"

    /** The process is gone. */
    const val ENDED = "exited"
}

/** One thing worth telling somebody about. */
data class SessionAlert(
    val hostId: String,
    val hostName: String,
    val sessionId: String,
    val sessionTitle: String,
    val kind: Kind,
    /** Only on a session that actually exited, and only when the desktop said. */
    val exitCode: Int? = null,
) {
    enum class Kind {
        /** Stopped and asking. Makes a sound. */
        NeedsYou,

        /** Finished its turn, or the process ended. Arrives quietly. */
        Finished,
    }

    /**
     * The line at the top of the notification.
     *
     * The session's own name, because that is what the person recognises — it is the folder they are
     * working in, and it is what the row in the list says too.
     */
    val title: String get() = sessionTitle.ifEmpty { "Session" }

    /**
     * The line underneath, which has to answer "so what" on a lock screen.
     *
     * Named machine and all: a phone paired with three computers cannot say "waiting for you" and
     * leave somebody guessing which one they have to walk over to.
     */
    val body: String
        get() = when (kind) {
            Kind.NeedsYou -> "Waiting for you on $hostName."
            Kind.Finished -> when {
                exitCode != null && exitCode != 0 -> "Stopped on $hostName — exit $exitCode."
                exitCode == null -> "Finished on $hostName."
                else -> "Ended on $hostName."
            }
        }

    /**
     * One session, named the same way everywhere.
     *
     * It is the notification's group key, so a machine's alerts group instead of stacking as four
     * unrelated banners; it is also its *id*, which is what makes a second alert about the same
     * session replace the first rather than pile on top of it. Two uses, one spelling — a second
     * would let them disagree about which session they meant.
     */
    val thread: String get() = thread(hostId, sessionId)

    companion object {
        fun thread(hostId: String, sessionId: String): String = "$hostId.$sessionId"
    }
}

/**
 * Whether a batch of changes is news or a catch-up.
 *
 * The distinction only matters for what is *done* with the alerts, not for whether they are raised:
 * a reconnect that lands while the app is on screen is somebody watching the list refill, and
 * interrupting them with four banners about it is worse than a line of text.
 */
enum class AlertReason {
    /** A frame arrived on a connection that was already up. */
    Live,

    /** The first list after a connection came back. What is in it happened while nobody listened. */
    CatchUp,
}

/**
 * The one line the session list shows after the app has been away.
 *
 * Written here rather than in the view because it is a counting sentence with three shapes and an
 * "and", which is exactly the kind of string that ends up saying "1 sessions" in one of them.
 */
object AwayReport {
    fun sentence(alerts: List<SessionAlert>): String? {
        if (alerts.isEmpty()) return null
        val waiting = alerts.count { it.kind == SessionAlert.Kind.NeedsYou }
        val finished = alerts.count { it.kind == SessionAlert.Kind.Finished }

        val parts = mutableListOf<String>()
        if (waiting > 0) parts += if (waiting == 1) "1 session needs you" else "$waiting sessions need you"
        if (finished > 0) parts += if (finished == 1) "1 finished" else "$finished finished"
        return "While you were away: ${parts.joinToString(", ")}."
    }
}
