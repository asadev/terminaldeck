package dev.terminaldeck.android.alerts

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import dev.terminaldeck.android.R

/**
 * Putting an alert on the lock screen, and the two settings that gate it.
 *
 * [SessionAlerts] decides *that* something happened. This decides what Android is told about it and
 * routes a tap back to the app. A transcription of `ios/TerminalDeck/App/AlertCenter.swift`, with
 * the two things Android does differently stated where they arise.
 *
 * ## Two channels, not one
 *
 * A channel is the unit a person turns off, and the two kinds of alert deserve different answers to
 * "may this make a noise". A session that wants you makes a sound, because that is the whole point
 * of being told: an agent has stopped mid-task and every minute after that is wasted. A session that
 * has *finished* arrives silently — it is worth seeing next time you look at the phone and it is not
 * worth a buzz, and an app that buzzes for both is one people turn off entirely inside a week, which
 * loses them the alert that mattered. On iOS that is a per-notification sound flag; on Android
 * importance lives on the channel, so it is two channels.
 *
 * ## No badge
 *
 * Deliberately. A badge would have to be a number about the machines, and this app cannot keep one
 * true: the moment the process is killed the sessions carry on changing and nothing here is running
 * to notice. A red "2" that means "two sessions needed you at some point before lunch" is a lie in a
 * place people trust, and there is no push service behind this product to make it honest. The
 * notifications themselves are timestamped and are not.
 *
 * ## Permission is asked when it is chosen, never at launch
 *
 * On Android 13 and up the system prompt is one question, and a refusal is permanent as far as the
 * app is concerned. Asking it in the first three seconds of the first launch — before the phone has
 * been paired with anything, when there is nothing to be notified about — is how it gets refused. It
 * is asked from `AlertsScreen`, which is reached by somebody who has gone looking for it.
 */
object AlertCenter {

    /** The channel a session that has stopped and is asking posts on. Makes a sound. */
    const val CHANNEL_NEEDS_YOU = "sessions.needs-you"

    /** The channel a finished session posts on. Silent by design — see the header. */
    const val CHANNEL_FINISHED = "sessions.finished"

    /**
     * Declare the channels.
     *
     * Idempotent, and called from `Application.onCreate` rather than lazily before the first post:
     * a channel that does not exist when a notification names it is a notification Android drops
     * without a word, and creating one *at* post time is a race with the very first alert.
     *
     * Importance is set once, at creation, and Android will not let it be raised afterwards — which
     * is correct and is why the two kinds are separate channels rather than one channel whose
     * importance this code would want to change.
     */
    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val needsYou = NotificationChannel(
            CHANNEL_NEEDS_YOU,
            "A session needs you",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "A session on one of your machines has stopped and is waiting for an answer."
            enableVibration(true)
        }
        val finished = NotificationChannel(
            CHANNEL_FINISHED,
            "A session finished",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "A session on one of your machines finished its turn, or its process ended."
            setSound(null, null)
            enableVibration(false)
        }
        manager.createNotificationChannel(needsYou)
        manager.createNotificationChannel(finished)
    }

    /**
     * Whether this build has to ask for permission at all.
     *
     * Below Android 13 the manifest declaration is the whole of it, and there is no prompt to offer —
     * so the screen must not draw a button that opens nothing.
     */
    val asksPermission: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU

    /** What Android says about this app's notifications. */
    fun permission(context: Context): AlertPermission {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            // Switched off in the system settings, which is the same answer whichever Android this
            // is: nothing this app posts will be shown, and only the Settings app can undo it.
            return AlertPermission.Denied
        }
        if (!asksPermission) return AlertPermission.Allowed
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
        return if (granted == PackageManager.PERMISSION_GRANTED) AlertPermission.Allowed else AlertPermission.NotAsked
    }

    /**
     * Raise one alert.
     *
     * Silent about its own failures on purpose: the caller is a frame handler on a socket, and a
     * notification that could not be posted — permission withdrawn a moment ago, a channel a person
     * has blocked — is not something to interrupt a session over. It answers whether it posted so
     * the tests can say so.
     */
    fun post(context: Context, alert: SessionAlert): Boolean {
        if (permission(context) != AlertPermission.Allowed) return false
        if (!AlertSettings.wants(context, alert.kind)) return false

        val channel = when (alert.kind) {
            SessionAlert.Kind.NeedsYou -> CHANNEL_NEEDS_YOU
            SessionAlert.Kind.Finished -> CHANNEL_FINISHED
        }
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_HOST, alert.hostId)
            putExtra(EXTRA_SESSION, alert.sessionId)
        }
        val pending = open?.let {
            PendingIntent.getActivity(
                context,
                alert.thread.hashCode(),
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val notification = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_deck)
            .setContentTitle(alert.title)
            .setContentText(alert.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(alert.body))
            .setPriority(
                if (alert.kind == SessionAlert.Kind.NeedsYou) {
                    NotificationCompat.PRIORITY_HIGH
                } else {
                    NotificationCompat.PRIORITY_LOW
                },
            )
            // Grouped by session, which is also the id: a second alert about the same session
            // replaces the first rather than piling on top of it.
            .setGroup(alert.hostId)
            .setAutoCancel(true)
            .setShowWhen(true)
            .apply { pending?.let { setContentIntent(it) } }
            .build()

        return try {
            NotificationManagerCompat.from(context).notify(alert.thread, ID, notification)
            true
        } catch (_: SecurityException) {
            // The permission was withdrawn between the check and the post. Nothing to say about it.
            false
        }
    }

    /** The machine a tap arrived about, so the app can open the session it was raised for. */
    const val EXTRA_HOST = "dev.terminaldeck.alert.host"
    const val EXTRA_SESSION = "dev.terminaldeck.alert.session"

    /**
     * One numeric id for every alert, with the *tag* carrying the session.
     *
     * `notify(tag, id, …)` keys on the pair, so a constant id plus a per-session tag gives exactly
     * the behaviour wanted: one live notification per session, replaced rather than stacked.
     */
    private const val ID = 1
}

/** What Android says about this app's notifications. */
enum class AlertPermission {
    /** Nobody has been asked yet. The only state from which asking is possible. */
    NotAsked,
    Allowed,

    /** Refused, or switched off in the system settings. Only the Settings app can undo it. */
    Denied,
}

/**
 * What the person has switched on.
 *
 * Separate from the permission, because they answer different questions: Android says whether this
 * app *may* interrupt, and these say whether it *should*.
 *
 * Both default to on. The permission prompt is the real gate — nothing can be delivered until
 * somebody says yes to that — so defaulting these off would mean two switches to reach the feature
 * and a person who granted permission and then received nothing.
 */
object AlertSettings {
    private const val FILE = "terminaldeck.preferences"
    const val KEY_NEEDS_YOU = "terminaldeck.alerts.needsYou.v1"
    const val KEY_FINISHED = "terminaldeck.alerts.finished.v1"

    fun needsYou(context: Context): Boolean = prefs(context).getBoolean(KEY_NEEDS_YOU, true)

    fun finished(context: Context): Boolean = prefs(context).getBoolean(KEY_FINISHED, true)

    fun setNeedsYou(context: Context, on: Boolean) {
        prefs(context).edit().putBoolean(KEY_NEEDS_YOU, on).apply()
    }

    fun setFinished(context: Context, on: Boolean) {
        prefs(context).edit().putBoolean(KEY_FINISHED, on).apply()
    }

    fun wants(context: Context, kind: SessionAlert.Kind): Boolean = when (kind) {
        SessionAlert.Kind.NeedsYou -> needsYou(context)
        SessionAlert.Kind.Finished -> finished(context)
    }

    /** How many kinds are on. What the Settings row says without being opened. */
    fun enabledCount(context: Context): Int =
        (if (needsYou(context)) 1 else 0) + (if (finished(context)) 1 else 0)

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
}
