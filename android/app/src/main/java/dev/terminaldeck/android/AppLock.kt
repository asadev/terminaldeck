package dev.terminaldeck.android

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * The lock on the front door of the app — one switch, and it asks once. The Android half of
 * `ios/TerminalDeck/App/AppLock.swift`, state for state and rule for rule.
 *
 * ## The requirement, and what it is not
 *
 * Asad, of the iOS build: *"I wanted this face lock actually not just for one specific server — make
 * it for the overall application. On the main page of settings just give it there, as optional for
 * the overall application. If somebody wants to keep it they can."* So this knows nothing about
 * servers and nothing about the credential vault. It is **one** row on the main Settings page, off
 * on every install that exists today — an absent preference reads as off — and it asks in exactly two
 * situations: when the app **starts** (a fresh process is constructed locked) and when it comes back
 * after being away for **more than five minutes**. Switching to a password manager, answering a call,
 * glancing at a notification — none of those is "away", and a lock that asked on every one of them is
 * the toll booth he threw out.
 *
 * Five is the same window Apple settled on for its own biometric reuse duration, and it is short
 * enough that a phone put down on a desk is locked before somebody else reaches it — which is the
 * threat this exists for. The number lives here once so the screen that states it and the rule that
 * enforces it cannot drift apart, and it is said on screen in both places it applies.
 *
 * ## Where the "on" flag lives, and why that is enough
 *
 * `SharedPreferences`, like [dev.terminaldeck.android.ui.theme.Appearance] and
 * [dev.terminaldeck.android.store.TerminalTextSize] — the phone-local settings. It is a preference,
 * not a secret, and the protection is not the flag: it is that **turning it off asks for the screen
 * lock first**. Somebody holding a borrowed, unlocked phone cannot switch this off, because the
 * switch itself is behind the sensor. The key is spelled the same as iOS's on purpose — the two
 * stores are on different devices and will never meet, and one spelling is one fewer thing that can
 * drift.
 *
 * ## What actually asks — and the one place this differs from iOS
 *
 * iOS calls `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`, which is biometry with the
 * passcode behind it, shown as a sheet **that never sends the app to the background**. Android's
 * permission-free, dependency-free equivalent is `KeyguardManager.createConfirmDeviceCredentialIntent`
 * — the system's own confirm screen, biometric with the PIN/pattern/password behind it — and it is a
 * separate activity, so raising it **stops this one**. That is the whole reason [wentToBackground]
 * guards on [isAuthenticating] where iOS does not: returning from the confirm screen is not "away",
 * and the grace clock must not start when the app is only behind its own unlock prompt. [MainActivity]
 * owns that authenticator, because an activity result belongs to an activity; this object holds only
 * the policy and is handed the authenticator through [authenticator].
 */
class AppLock(
    /**
     * The application context the enabled flag is written through. `null` in a `@Preview` and in the
     * throwaway instance [AppLockStore] hands back before [AppLockStore.prime] has run, where there
     * is nothing to persist and nothing that should try.
     */
    private val appContext: Context?,
    initiallyEnabled: Boolean,
    /** Five minutes, in milliseconds. A parameter so a test drives it against a made-up clock rather
     *  than by sleeping, exactly as iOS makes `grace` and `now` injectable. */
    val grace: Long = GRACE_MS,
) {
    /**
     * The clock. A property so the five-minute rule can be walked in microseconds against a made-up
     * value rather than by waiting five minutes, the same shape iOS gives `AppLock.now`.
     */
    var now: () -> Long = { System.currentTimeMillis() }

    /**
     * What this phone can do about locking, and one authentication. Defaults to the do-nothing gate
     * so a `@Preview` and the pre-`prime` instance render a coherent (off, unlockable-by-nothing)
     * screen; [MainActivity] swaps in the real one, bound to the activity and its confirm-credential
     * launcher, the moment it exists.
     */
    var authenticator: AppLockAuthenticator = AppLockAuthenticator.Unavailable

    /* --------------------------------------------------------------------------- state -- */

    /** Whether the person has turned the lock on. Off on every fresh install. */
    var enabled: Boolean by mutableStateOf(initiallyEnabled)
        private set

    /**
     * Whether the lock screen is up right now. Constructed equal to [enabled]: a fresh process is a
     * locked process, decided here rather than in an effect so the very first composition already
     * knows and there is no frame in which the session list shows before the lock does.
     */
    var isLocked: Boolean by mutableStateOf(initiallyEnabled)
        private set

    /**
     * Whether the app's content should be covered without the lock screen being up — the moment
     * between leaving the foreground and the recents thumbnail being taken. Only ever true with the
     * lock on.
     */
    var isShielded: Boolean by mutableStateOf(false)
        private set

    /** The one sentence both screens draw: the lock screen when an unlock did not work, the Settings
     *  row when the switch would not move. They are never on screen together, so one property is honest. */
    var trouble: String? by mutableStateOf(null)
        private set

    /** Something done on the person's behalf they should know about — today, exactly one thing: the
     *  lock turning itself off because the phone stopped having a screen lock. */
    var notice: String? by mutableStateOf(null)
        private set

    /** A confirm prompt is up, or an authentication is in flight. */
    var working: Boolean by mutableStateOf(false)
        private set

    /**
     * Set while the system's own confirm screen is up. Load-bearing: that screen stops this activity,
     * and treating a stop during authentication as "went away" would start the grace clock every time
     * somebody unlocked. See the guards in [wentToBackground] and [wentInactive].
     */
    var isAuthenticating: Boolean by mutableStateOf(false)
        private set

    /** True in the one state that cannot authenticate anybody: the phone has no screen lock at all.
     *  The screen offers a way in rather than a locked door. */
    var stranded: Boolean by mutableStateOf(false)
        private set

    /**
     * Bumped whenever the lock screen should raise a prompt by itself. The screen watches it with a
     * `LaunchedEffect(promptToken)`, so a cold start asks once and a return to a still-locked app asks
     * again — and a cancelled prompt does not loop, because nothing bumps this when the app merely
     * goes inactive.
     */
    var promptToken: Int by mutableStateOf(0)
        private set

    /** What the window shield watches: anything the person must not see. */
    val isCovered: Boolean get() = isLocked || isShielded

    /* ------------------------------------------------------------------------ lifetime -- */

    private var leftAt: Long? = null
    private var wasBackgrounded = false

    /** What this phone can do about locking, asked fresh — never cached, because a screen lock can be
     *  removed and a fingerprint enrolled while this app is in the background. */
    fun availability(): AppLockAvailability = authenticator.availability()

    /* ---------------------------------------------------------------------- lifecycle -- */

    /**
     * The app is losing the foreground — the recents overview is opening, a call is coming in.
     *
     * This is where the privacy cover goes on and it is not where the lock goes on: inactive is not
     * away. The [isAuthenticating] guard matters most — the confirm screen makes this activity pause,
     * and covering the screen underneath its own unlock prompt would be the app hiding from itself.
     */
    fun wentInactive() {
        if (enabled && !isAuthenticating && !isLocked) isShielded = true
    }

    /**
     * The app has actually left the screen, and the grace clock starts here.
     *
     * Guarded on [isAuthenticating] where iOS is not, and this is the one deliberate divergence from
     * the source: iOS's biometric sheet leaves the app merely inactive, so its `wentToBackground`
     * only ever runs for a real departure. Android's confirm-credential screen is a separate activity
     * that genuinely stops this one, so without this guard every unlock would look like a five-minute
     * errand and re-lock the moment the person got back in.
     */
    fun wentToBackground() {
        if (isAuthenticating) return
        leftAt = now()
        wasBackgrounded = true
        if (enabled && !isLocked) isShielded = true
    }

    /**
     * The app is back in front of the person.
     *
     * Three outcomes and the middle one is the requirement: away longer than the grace locks it, away
     * for less does nothing, and returning to an app that was already locked raises the prompt again
     * so somebody who left mid-unlock is not staring at a button they have to go and find.
     */
    fun becameActive() {
        isShielded = false
        if (!wasBackgrounded) return
        wasBackgrounded = false
        val away = leftAt?.let { now() - it } ?: 0L
        leftAt = null
        if (!enabled) return
        if (!isLocked && away >= grace) {
            lockNow()
        } else if (isLocked) {
            promptToken += 1
        }
    }

    private fun lockNow() {
        isLocked = true
        trouble = null
        stranded = false
        promptToken += 1
    }

    /* ------------------------------------------------------------------------- unlock -- */

    /**
     * Ask, once, and say exactly what happened if it did not work.
     *
     * Nothing here can leave the person outside: every outcome except success leaves the **Unlock**
     * button on screen, and the one outcome where pressing it again could never help — a phone with no
     * screen lock — opens the app and turns the lock off instead of pretending.
     */
    suspend fun unlock() {
        if (!isLocked || isAuthenticating) return

        val availability = availability()
        if (!availability.canLock) {
            stranded = true
            trouble = "This phone has no screen lock any more, so there is nothing left to unlock " +
                "with. Continue into Terminal Deck — the lock is off until you set a screen lock and " +
                "turn it back on."
            return
        }

        isAuthenticating = true
        working = true
        trouble = null
        val outcome = authenticator.authenticate("Unlock Terminal Deck")
        isAuthenticating = false
        working = false

        when (outcome) {
            AppLockOutcome.Unlocked -> {
                isLocked = false
                leftAt = null
                wasBackgrounded = false
                trouble = null
            }
            // Not a failure and never reported as one. The button is still there.
            AppLockOutcome.Cancelled ->
                trouble = "Cancelled — nothing was opened. Press Unlock when you are ready."
            AppLockOutcome.Unavailable ->
                trouble = "This phone's screen lock is not available right now. Press Unlock to try again."
            is AppLockOutcome.Failed ->
                trouble = "${outcome.message} Press Unlock to try again."
        }
    }

    /**
     * The way out of the one state nothing can authenticate: the lock goes off, the app opens, and
     * Settings says why rather than leaving somebody to wonder where their switch went.
     */
    fun continueWithoutLock() {
        enabled = false
        persist(false)
        isLocked = false
        stranded = false
        trouble = null
        leftAt = null
        wasBackgrounded = false
        notice = "The lock turned itself off: this phone no longer has a screen lock, so there was " +
            "nothing left to unlock with."
    }

    /* --------------------------------------------------------------------- the switch -- */

    /**
     * Turn the lock on or off. Both directions cost exactly one prompt, and both earn it:
     *
     *  - **On** proves the screen lock this phone claims actually asks, right now, with the person
     *    holding it — rather than discovering at the airport that it never did.
     *  - **Off** is the one that matters. Without it a phone handed over unlocked for thirty seconds
     *    is a phone whose lock the holder can switch off, and the feature protects nothing.
     *
     * A cancelled prompt changes nothing and says nothing: the switch springs back, which is the
     * whole of the message.
     */
    suspend fun setEnabled(wanted: Boolean) {
        if (working || wanted == enabled) return
        trouble = null
        notice = null

        val availability = availability()
        if (wanted && !availability.canLock) {
            trouble = availability.refusal
            return
        }

        isAuthenticating = true
        working = true
        val outcome = authenticator.authenticate(
            if (wanted) "Turn on the lock for Terminal Deck" else "Turn off the lock for Terminal Deck"
        )
        isAuthenticating = false
        working = false

        when (outcome) {
            AppLockOutcome.Unlocked -> {
                enabled = wanted
                persist(wanted)
                // Whoever just authenticated is in. Turning the lock on must not then drop its own
                // lock screen over the Settings page they are standing on.
                isLocked = false
                leftAt = null
                wasBackgrounded = false
            }
            AppLockOutcome.Cancelled -> Unit
            AppLockOutcome.Unavailable ->
                trouble = "This phone's screen lock is not available right now."
            is AppLockOutcome.Failed ->
                trouble = outcome.message
        }
    }

    /** Clears whatever sentence is on screen. The Settings section calls it when the person leaves,
     *  so a refusal from ten minutes ago is not still there. */
    fun clearTrouble() {
        trouble = null
    }

    private fun persist(on: Boolean) {
        appContext?.let { save(it, on) }
    }

    companion object {
        /** Five minutes. */
        const val GRACE_MS: Long = 300_000L

        /** "five minutes", spelled the way the two screens say it out loud. */
        const val GRACE_WORDS = "five minutes"

        /**
         * The stored name. `.v1` because a preference outlives the build that wrote it: if this ever
         * changes meaning, the key changes with it. Spelled the same as the iOS defaults key on
         * purpose — see the class note.
         */
        const val KEY = "terminaldeck.applock.v1"

        /** The same preferences file [dev.terminaldeck.android.ui.theme.Appearance] uses: these are
         *  the phone-local settings, and they belong together. */
        private const val FILE = "terminaldeck.preferences"

        /** Read off disk. Absent — every install today — reads as off. */
        fun stored(context: Context): Boolean =
            context.applicationContext
                .getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .getBoolean(KEY, false)

        fun save(context: Context, on: Boolean) {
            context.applicationContext
                .getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY, on)
                .apply()
        }
    }
}

/**
 * The one live copy of the lock for the whole process.
 *
 * A single instance rather than one per screen, and the reason is which way its state travels: the
 * switch that changes it is a row deep in Settings, and the thing that has to repaint is the overlay
 * at the root of the window. Same shape and same justification as
 * [dev.terminaldeck.android.ui.theme.AppearanceStore]. It is instantiated older than any screen —
 * [prime] runs in `MainActivity.onCreate`, before `setContent` — because a fresh process is a locked
 * process and the first composition must already know.
 */
object AppLockStore {
    private var instance: AppLock? = null

    /**
     * Build the lock, once, from the stored flag. Called before the first frame so the overlay is up
     * on the first pass rather than after a frame of the session list.
     */
    fun prime(context: Context): AppLock =
        instance ?: AppLock(
            appContext = context.applicationContext,
            initiallyEnabled = AppLock.stored(context),
        ).also { instance = it }

    /** The primed instance, or null before [prime] — what the lifecycle callbacks read, since a stop
     *  arriving before the first composition should simply find nothing to do. */
    fun lockOrNull(): AppLock? = instance

    /** The primed instance, or a throwaway default so a `@Preview` renders. The default is off and
     *  unwired, so it draws as "no lock" rather than throwing. */
    fun currentOrDefault(): AppLock =
        instance ?: AppLock(appContext = null, initiallyEnabled = false)
}

/**
 * Which biometric this phone has, so a screen can name the right one rather than saying "Face" to
 * somebody holding a fingerprint reader — the same care iOS takes with `BiometryKind`.
 */
enum class BiometryKind {
    Fingerprint,
    Face,
    Iris,
    /** Hardware is present but its modality is not one Android will name. */
    Generic;

    /** How the two screens refer to it in a sentence: "asks for your fingerprint", "unlock with your face". */
    val noun: String
        get() = when (this) {
            Fingerprint -> "your fingerprint"
            Face -> "your face"
            Iris -> "your iris"
            Generic -> "biometrics"
        }
}

/**
 * What this phone can do about locking the app, right now.
 *
 * Three states, mirroring iOS's biometry / passcode / impossible. The distinction is cosmetic — the
 * actual unlock always goes through the system confirm screen, which offers the biometric if one is
 * enrolled and the PIN/pattern/password behind it either way — so this only decides the icon, the
 * label and whether the switch can move at all.
 */
sealed interface AppLockAvailability {

    /** Whether the lock can be turned on: false only when the phone has no screen lock to ask with. */
    val canLock: Boolean

    /** A biometric is enrolled and usable. The passcode is behind it. */
    data class Biometric(val kind: BiometryKind) : AppLockAvailability {
        override val canLock: Boolean get() = true
    }

    /** No usable biometric, but the phone has a screen lock — which is a real lock. */
    data object DeviceCredential : AppLockAvailability {
        override val canLock: Boolean get() = true
    }

    /** No screen lock at all. Nothing can be locked and nothing could unlock it. */
    data object None : AppLockAvailability {
        override val canLock: Boolean get() = false
    }
}

/** The thing this phone will actually put in front of the person, named for the sentences that say
 *  when it asks. Never a biometric name on a device that only has a PIN set. */
val AppLockAvailability.noun: String
    get() = when (this) {
        is AppLockAvailability.Biometric -> kind.noun
        AppLockAvailability.DeviceCredential -> "your screen lock"
        AppLockAvailability.None -> "your screen lock"
    }

/** What the switch in Settings reads. */
val AppLockAvailability.title: String
    get() = when (this) {
        is AppLockAvailability.Biometric -> "Lock the app with ${kind.noun}"
        AppLockAvailability.DeviceCredential -> "Lock the app with your screen lock"
        AppLockAvailability.None -> "Lock the app"
    }

/**
 * The one line under the switch when the lock is available but a biometric is not what will ask, or
 * null when there is nothing to explain — one clause, never a paragraph, the way iOS pared its own
 * caveats down to the half a person cannot work out by looking.
 */
val AppLockAvailability.caveat: String?
    get() = when (this) {
        AppLockAvailability.DeviceCredential ->
            "No fingerprint or face is set up, so this asks for your screen lock."
        else -> null
    }

/** Why the lock cannot be turned on, in the person's terms — or null when it can. */
val AppLockAvailability.refusal: String?
    get() = when (this) {
        AppLockAvailability.None ->
            "This phone has no screen lock, so there is nothing to lock the app with. Set a PIN, " +
                "pattern or password in Settings, then turn this on."
        else -> null
    }

/**
 * How an unlock ended. A smaller set than iOS's `BiometryOutcome`, and honestly so: the system
 * confirm screen handles lockout and enrolment changes inside itself and hands back only success or
 * dismissal, so there is nothing here to distinguish "locked out" from "cancelled" the way
 * LocalAuthentication's typed errors let iOS. [Failed] carries a system message for the rare case the
 * screen could not be shown at all.
 */
sealed interface AppLockOutcome {
    /** Authenticated. */
    data object Unlocked : AppLockOutcome
    /** Dismissed, or the system took the prompt away. Not a failure and never reported as one. */
    data object Cancelled : AppLockOutcome
    /** There is no screen lock to show — reachable only if one was removed between the check and the ask. */
    data object Unavailable : AppLockOutcome
    /** The confirm screen could not be raised, in the system's own words rather than a guess. */
    data class Failed(val message: String) : AppLockOutcome
}

/**
 * What the policy asks of the platform, kept behind an interface so [AppLock] holds no Android type
 * and stays a plain state machine — the same split iOS draws between `AppLock` and `BiometricGate`.
 * The real one lives in [MainActivity], where the activity and its result launcher are.
 */
interface AppLockAuthenticator {
    /** What this phone can do about locking, asked fresh every time. */
    fun availability(): AppLockAvailability

    /** Raise the system confirm screen and wait for its answer. */
    suspend fun authenticate(reason: String): AppLockOutcome

    /** The do-nothing gate a `@Preview` and the pre-`prime` instance carry: nothing can be locked and
     *  nothing could unlock it. */
    object Unavailable : AppLockAuthenticator {
        override fun availability(): AppLockAvailability = AppLockAvailability.None
        override suspend fun authenticate(reason: String): AppLockOutcome = AppLockOutcome.Unavailable
    }
}
