package dev.terminaldeck.android.alerts

import android.content.Intent

/**
 * Where a notification tap is routed back to the session it was raised for.
 *
 * [AlertCenter] writes the machine and the session onto the notification's launch intent; this reads
 * them back and hands them to whoever is wired to open a session. The mirror of iOS
 * `NotificationRouter`, and it exists for the same reason iOS's does: a tap can be delivered to the
 * activity **during launch**, before the composition has run and wired [open]. Without somewhere to
 * put it, that tap would bring the app to the front and open nothing — which was the whole of the
 * gap: the target was on the intent and nothing ever read it. So a target that arrives before [open]
 * is set is held in [pending] and flushed the moment it is.
 *
 * A process-wide object because there is one activity and one composition, exactly as the iOS router
 * is a shared singleton.
 */
object AlertRouter {

    /** A tap whose target arrived before the composition wired [open], held until it can be opened. */
    private var pending: Pair<String, String>? = null

    /**
     * How the app opens a session — set by the composition, cleared on the way out.
     *
     * Setting it flushes any tap that arrived before the composition was ready, which is the whole
     * reason the pending buffer exists.
     */
    var open: ((String, String) -> Unit)? = null
        set(value) {
            field = value
            if (value != null) {
                pending?.let { (host, session) ->
                    pending = null
                    value(host, session)
                }
            }
        }

    /**
     * Route one host+session target: open it now if the app is ready, or hold it until it is.
     *
     * The pure core, so the launch-race behaviour can be tested without an Android intent. Empty ids
     * are dropped — a malformed intent is not a session — and `DeckViewModel.openFromAlert` validates
     * the id's shape again before it navigates.
     */
    fun deliver(hostId: String?, sessionId: String?) {
        if (hostId.isNullOrEmpty() || sessionId.isNullOrEmpty()) return
        val opener = open
        if (opener != null) opener(hostId, sessionId) else pending = hostId to sessionId
    }

    /**
     * Route the target off a notification's launch intent.
     *
     * The extras are removed as they are read, so a rotation — which re-delivers the same intent —
     * does not re-open the session behind whatever the person navigated to since. A no-op on an
     * ordinary launch, whose intent carries neither extra.
     */
    fun deliver(intent: Intent?) {
        val host = intent?.getStringExtra(AlertCenter.EXTRA_HOST)
        val session = intent?.getStringExtra(AlertCenter.EXTRA_SESSION)
        intent?.removeExtra(AlertCenter.EXTRA_HOST)
        intent?.removeExtra(AlertCenter.EXTRA_SESSION)
        deliver(host, session)
    }

    /** Forget any wired opener and any held target. For tests, and for a clean activity teardown. */
    fun reset() {
        open = null
        pending = null
    }
}
