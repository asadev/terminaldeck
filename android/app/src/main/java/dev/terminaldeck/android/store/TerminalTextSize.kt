package dev.terminaldeck.android.store

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * How big the terminal draws, remembered between launches.
 *
 * The pinch has always changed the size and has never remembered it, so every relaunch put the font
 * back where it started — which is the bug a person notices once a day. This is the other half, and
 * it is also what makes the *Text size* row in Settings a real control rather than a picture: both
 * paths write here, so there is one stored number and one place that can be wrong.
 *
 * ## Pixels, not sp
 *
 * `TerminalRenderer` takes a raw pixel size and derives the character cell from it, and the cell is
 * what decides how many columns the desktop is told about. Scaling with the system font setting
 * would mean two phones side by side reporting different terminal widths for the same screen. The
 * bounds are the ones the pinch has always enforced.
 *
 * Ordinary [android.content.SharedPreferences] and deliberately not the encrypted vault: this is a
 * font size. Nothing here is a secret, and putting it behind the Keystore would make a preference
 * read cost a keystore round-trip on the path that builds the terminal.
 */
object TerminalTextSize {

    /** Below this a `1`, an `l` and an `I` are the same shape on a phone screen. */
    const val MINIMUM = 14

    /** Above this a portrait phone cannot hold a shell prompt on one line. */
    const val MAXIMUM = 64

    /**
     * The size a fresh install starts at, until somebody changes it.
     *
     * > *"By default in the mobile application the text size should be around 14pt as the standard
     * > size of the text inside the terminal by default."*
     *
     * His "14pt" is a point size; this store is raw pixels — see the class note, where the pixel
     * count is what fixes the column width and is deliberately never scaled to a physical point. So
     * 14 cannot go here literally: 14 px is [MINIMUM], the smallest, unreadable end. The app's own
     * anchor pairs iOS's 12 pt standard with 28 px here, so 14 pt lands at 28 * 14 / 12 = 32 — kept
     * even to sit on the [STEP] grid. Was 28. This moves only the fresh-install default: [load]
     * returns it solely when nothing has been saved, so a size the person already picked is untouched.
     */
    const val STANDARD = 32

    /** One press of the smaller/larger control, and one step of a pinch. */
    const val STEP = 2

    private const val FILE = "terminaldeck.display"
    private const val KEY = "terminal.textSizePx.v1"

    /**
     * The size in use, as a stream every open terminal follows the moment it changes.
     *
     * iOS reaches the same end with a `terminalTextSizeChanged` notification and the same reasoning:
     * *"one setting … for all of them"* is only true if a terminal already on screen catches up
     * without being re-opened. Before this, a size changed in Settings — or by a pinch in one
     * session — reached the *other* open terminals only when they were next opened, which is the
     * exact shape of a setting that looks broken: you change it, you go back, and the terminal you
     * were reading is the size it always was.
     *
     * Starts at `0`, meaning *nothing has announced a change this run* — a terminal keys off [load]
     * for its first size and only follows this once it actually moves. `StateFlow` conflates equal
     * values, so a redundant [save] of the size already in use does not repaint every session: the
     * guard iOS spells out (`clamped != before`) is here the flow refusing to re-emit what it holds.
     */
    private val _live = MutableStateFlow(0)
    val live: StateFlow<Int> = _live.asStateFlow()

    /**
     * The size in use.
     *
     * [STANDARD] until somebody changes it, and clamped on the way out so a value stored by a build
     * with different bounds cannot produce a one-pixel terminal.
     */
    fun load(context: Context): Int {
        val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        val saved = prefs.getInt(KEY, 0)
        return if (saved <= 0) STANDARD else clamp(saved)
    }

    fun save(context: Context, size: Int) {
        val clamped = clamp(size)
        context.applicationContext
            .getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .edit()
            .putInt(KEY, clamped)
            .apply()
        // After the write, so a terminal that follows [live] and re-reads never sees a value the
        // store has not committed yet. The flow conflates, so the session that *caused* this size —
        // a pinch already applied to its own view — is not asked to apply it a second time.
        _live.value = clamped
    }

    /**
     * Held inside the bounds.
     *
     * Every path into a font size goes through here — the stepper, the pinch, the read at launch —
     * so there is one place that can be wrong.
     */
    fun clamp(size: Int): Int = size.coerceIn(MINIMUM, MAXIMUM)

    fun larger(size: Int): Int = clamp(size + STEP)

    fun smaller(size: Int): Int = clamp(size - STEP)

    fun canGoLarger(size: Int): Boolean = clamp(size) < MAXIMUM

    fun canGoSmaller(size: Int): Boolean = clamp(size) > MINIMUM

    /** What the row reads. Mono in the UI, because it is a measurement. */
    fun label(size: Int): String = "${clamp(size)} px"
}
