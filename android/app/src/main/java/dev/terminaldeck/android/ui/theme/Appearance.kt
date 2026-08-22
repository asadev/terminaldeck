package dev.terminaldeck.android.ui.theme

import android.content.Context
import android.content.res.Configuration
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf

/**
 * Light, dark, or whatever the phone is set to.
 *
 * Asad, of the other client: *"mobile iOS is only dark mode — it should have both, in settings."*
 * Android was in exactly the same state and worse, because it was pinned dark in **four** places
 * rather than three: `darkColorScheme()` with no light half to switch to, `Theme.TerminalDeck`
 * inheriting `android:Theme.Material.NoActionBar` with a hard-coded dark `windowBackground`,
 * `windowLightStatusBar=false` in that same style, and `enableEdgeToEdge(SystemBarStyle.dark(…),
 * SystemBarStyle.dark(…))` in `MainActivity`. The order matters when removing them: while the
 * window background and the bar styles are pinned, nothing Compose does has any visible effect at
 * the edges of the screen.
 *
 * ## Three choices, and System is the default
 *
 * Because a phone already has this setting — in Quick Settings, and on a schedule — and an app that
 * ignores it is an app that comes up white at midnight. The other two exist because a terminal is a
 * thing some people want dark on a bright desk and some want light on a dim one, and neither of
 * them is wrong.
 *
 * [System] resolves through the configuration on every read rather than being decided once at
 * launch. That is the difference between *following* the phone and *guessing what the phone
 * currently says*: a preference resolved to light at launch would stop tracking the moment the
 * phone crossed into its dark schedule with the app open, which is the case this setting exists to
 * serve. `MainActivity` already declares `uiMode` in `configChanges`, so the change arrives as a
 * recomposition rather than as a restart.
 *
 * ## `SharedPreferences`, not the vault
 *
 * It is a preference, not a secret, and it must survive a relaunch. `DeviceVault` is an encrypted
 * file holding credentials; putting a theme in it would mean a theme that cannot be read until the
 * keystore is available, on the frame where the window background is being chosen.
 */
enum class Appearance {
    /** Follow the phone. The default, and the only one that keeps tracking. */
    System,
    Light,
    Dark;

    /** What the control reads. Sentence case, like every other value in settings. */
    val label: String
        get() = when (this) {
            System -> "System"
            Light -> "Light"
            Dark -> "Dark"
        }

    /**
     * Whether this resolves dark, given what the phone currently says.
     *
     * [System] asks the configuration; the other two ignore it, which is the whole point of
     * choosing one.
     */
    fun isDark(configuration: Configuration): Boolean = when (this) {
        Light -> false
        Dark -> true
        System ->
            (configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    }

    companion object {
        /**
         * The stored name.
         *
         * `.v1` because a stored preference outlives the build that wrote it: if these cases ever
         * change meaning, the key changes with them rather than a new build inheriting a value that
         * means something else. Spelled the same as the iOS defaults key — the two stores are on
         * different devices and will never meet, and one spelling is still one fewer thing that can
         * drift.
         */
        const val KEY = "terminaldeck.appearance.v1"

        private const val FILE = "terminaldeck.preferences"

        /**
         * Read off disk.
         *
         * Falls back to [System] on anything unexpected — an absent key on a fresh install, and a
         * value written by a build whose cases were different. A preference read off disk is input,
         * and the failure to design for is a phone that comes up in a scheme nobody chose.
         */
        fun stored(context: Context): Appearance {
            val raw = context.applicationContext
                .getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .getString(KEY, null)
            return entries.firstOrNull { it.name == raw } ?: System
        }

        fun save(context: Context, appearance: Appearance) {
            context.applicationContext
                .getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY, appearance.name)
                .apply()
        }
    }
}

/**
 * The one live copy of the preference for the whole process.
 *
 * A single piece of observable state rather than a value threaded down through four screens, and
 * the reason is which way it has to travel: the control that changes it is a row deep inside a
 * sheet, and the thing that has to repaint is the root of the window three levels above it. The
 * iOS client solves the identical problem with `@AppStorage` on both ends — a live view of one
 * defaults key rather than a binding passed through screens that do not care — and this is the same
 * shape with the same justification.
 *
 * Seeded from disk on first touch and written back on every change, so the tap and the save are the
 * same gesture: there is no Apply and nothing to confirm.
 */
object AppearanceStore {
    private val state: MutableState<Appearance?> = mutableStateOf(null)

    /**
     * Read it before the first frame.
     *
     * Called from `MainActivity.onCreate` *before* `setContent`, because the window background is
     * chosen from it and a window painted the wrong colour for one frame is the white flash this
     * whole file exists to prevent.
     */
    fun prime(context: Context): Appearance {
        val loaded = state.value ?: Appearance.stored(context).also { state.value = it }
        return loaded
    }

    /** The current preference, as observable state. Reading it in a composable subscribes to it. */
    val current: State<Appearance?> get() = state

    fun set(context: Context, appearance: Appearance) {
        Appearance.save(context, appearance)
        state.value = appearance
    }
}

/**
 * The preference, resolved and observable, for a composable.
 *
 * Returns [Appearance.System] before [AppearanceStore.prime] has run, which cannot happen in the
 * app itself and does happen in a `@Preview`.
 */
@Composable
fun currentAppearance(): Appearance = AppearanceStore.current.value ?: Appearance.System
