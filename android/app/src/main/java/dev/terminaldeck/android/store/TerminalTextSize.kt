package dev.terminaldeck.android.store

import android.content.Context

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

    /** What this app has always drawn at, and what it still starts at. */
    const val STANDARD = 28

    /** One press of the smaller/larger control, and one step of a pinch. */
    const val STEP = 2

    private const val FILE = "terminaldeck.display"
    private const val KEY = "terminal.textSizePx.v1"

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
        context.applicationContext
            .getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .edit()
            .putInt(KEY, clamp(size))
            .apply()
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
