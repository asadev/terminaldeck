package dev.terminaldeck.android.ui.theme

import kotlinx.serialization.Serializable
import java.util.Locale

/**
 * One terminal colour scheme — twenty-one colours, named the way every other client names them.
 *
 * ## Why this shape and not a nicer one
 *
 * Asad asked for the terminal colour choice on *"phone also, for Windows, for MacBook, all of
 * them"*, which makes this a **contract** rather than a model: the same ids, the same names and the
 * same hexes have to exist on the desktop, on iOS and here, or somebody who picks Nord on their Mac
 * and Nord on their phone is looking at two different greens and has no way to say which one is
 * wrong. So the field names below are `@xterm/xterm`'s `ITheme` field names verbatim —
 * `cursorAccent`, `selectionBackground`, `brightBlack` — even where a more Kotlin-ish name exists,
 * because the desktop hands this object straight to xterm and a rename here is a translation layer
 * that can drift.
 *
 * The colours are **strings** rather than packed ints for the same reason. `#8ae234` in
 * `terminal-theme.ts` is `"#8ae234"` here, so the two files can be diffed by eye and by a script,
 * and so the hex field in the editor stores exactly what somebody typed rather than a value that
 * has been through two conversions. [Companion.parse] is the one place a string becomes a colour.
 *
 * ## Two of these do nothing on Android, and that is said out loud
 *
 * The vendored emulator draws a selection and the text under a block cursor by **inverting**, not by
 * filling with a colour: `TerminalRenderer` passes `reverseVideo || invertCursorTextColor ||
 * insideSelection` into one flag and there is no palette slot behind it. So [selectionBackground]
 * and [cursorAccent] are carried, stored, edited and round-tripped — because the scheme is the same
 * scheme on every client and a phone that silently dropped two fields would hand a mangled copy
 * back — and they change nothing about what this phone draws. `VENDORED.md`'s rule is to reach the
 * emulator through its API rather than fork it, and its API (`TerminalColorScheme.updateWith`) has
 * exactly three non-indexed keys: `foreground`, `background`, `cursor`.
 *
 * Saying so in the editor is the honest half. A row that looks like a control and moves nothing is
 * the "switch wired to nothing" this app's brief refuses.
 */
@Serializable
data class TerminalScheme(
    /** Stable across renames and across clients. A built-in's id is the same word on every platform. */
    val id: String,
    /** What the picker reads. Sentence case, like every other value in settings. */
    val name: String,
    val background: String,
    val foreground: String,
    val cursor: String,
    /**
     * The text colour under a block cursor. Inert on Android — see the note on this class — and
     * carried so a scheme edited here is still a whole scheme when it reaches a desktop.
     */
    val cursorAccent: String,
    /** Inert on Android for the same reason. The emulator inverts a selection rather than filling it. */
    val selectionBackground: String,
    val black: String,
    val red: String,
    val green: String,
    val yellow: String,
    val blue: String,
    val magenta: String,
    val cyan: String,
    val white: String,
    val brightBlack: String,
    val brightRed: String,
    val brightGreen: String,
    val brightYellow: String,
    val brightBlue: String,
    val brightMagenta: String,
    val brightCyan: String,
    val brightWhite: String,
) {

    /**
     * The sixteen, in the order the wire numbers them: `color0`…`color15`.
     *
     * Derived rather than stored, so there is one spelling of each colour and no second list that
     * can disagree with the fields above about what green is.
     */
    val ansi: List<String>
        get() = listOf(
            black, red, green, yellow, blue, magenta, cyan, white,
            brightBlack, brightRed, brightGreen, brightYellow,
            brightBlue, brightMagenta, brightCyan, brightWhite,
        )

    /** Whether this scheme's paper is dark, which is what a preview needs to pick a border. */
    val isDark: Boolean get() = luminance(parse(background)) < 0.5

    /**
     * A copy of this scheme that belongs to the person editing it.
     *
     * Editing a built-in makes a copy — never an edit in place — because a built-in is a shared
     * name. If "Nord" on this phone were somebody's tweaked Nord, then "use Nord" would stop meaning
     * one thing across their machines, which is the whole property the ids exist to hold.
     *
     * The new id is random rather than derived from the old one: two copies of Nord made on two
     * phones must not collide if these ever sync, and a derived id (`nord.copy`) collides on the
     * second copy made on the *same* phone.
     */
    fun copyForEditing(newId: String, newName: String): TerminalScheme =
        copy(id = newId, name = newName)

    companion object {

        /** How many colours a scheme has, all in. Five roles plus the sixteen. */
        const val SLOT_COUNT = 21

        /**
         * `#rrggbb` (or `#rgb`) to an opaque ARGB int.
         *
         * Tolerant on the way in because this also reads what somebody typed into the hex field —
         * a missing `#`, upper case, the three-digit short form — and strict about what it returns:
         * always opaque. Alpha is deliberately not representable. `TerminalColors.parse` on the
         * emulator side accepts `#aarrggbb`, and a scheme with a translucent background there draws
         * over whatever the last frame left behind rather than compositing, which looks like a
         * rendering bug and is a scheme nobody could have known was wrong.
         *
         * Returns `null` rather than throwing or guessing, so the field can say *that is not a
         * colour* while somebody is still halfway through typing one.
         */
        fun parseOrNull(raw: String): Int? {
            val body = raw.trim().removePrefix("#")
            val expanded = when (body.length) {
                3 -> body.map { "$it$it" }.joinToString("")
                6 -> body
                else -> return null
            }
            if (!expanded.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) return null
            return 0xff000000.toInt() or expanded.toInt(16)
        }

        /** The same, for a value already known to be good — every colour in a built-in is. */
        fun parse(raw: String): Int = parseOrNull(raw) ?: 0xff000000.toInt()

        /** Back to the canonical `#rrggbb`, lower case, which is the form every scheme is written in. */
        fun format(argb: Int): String =
            String.format(Locale.ROOT, "#%06x", argb and 0xffffff)

        /** Canonical form of whatever somebody typed, or `null` if it was not a colour. */
        fun normalise(raw: String): String? = parseOrNull(raw)?.let { format(it) }

        /**
         * Relative luminance, the sRGB one, used only to decide whether a preview sits on a dark
         * ground. Not a contrast check and not presented as one.
         */
        fun luminance(argb: Int): Double {
            fun channel(value: Int): Double {
                val v = value / 255.0
                return if (v <= 0.03928) v / 12.92 else Math.pow((v + 0.055) / 1.055, 2.4)
            }
            val r = channel((argb shr 16) and 0xff)
            val g = channel((argb shr 8) and 0xff)
            val b = channel(argb and 0xff)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
    }
}

/**
 * This scheme with [raw] typed into [slot] — or `null` when there is nothing to commit.
 *
 * Two refusals, and the second is the one that matters.
 *
 *  - **Not a colour.** Somebody clearing a field to retype it passes through `#`, `#8`, `#8a`, and
 *    a screen that committed those would flash the terminal three times per edit.
 *  - **The same colour it already was.** `#000` normalises to `#000000`, which is what the field
 *    already held — so deleting three characters off Pure black's background and stopping is not an
 *    edit, and must not be treated as one. It matters here more than it would anywhere else,
 *    because on a built-in the *first* commit forks a copy: without this, opening a shipped scheme
 *    and pressing backspace once would silently create "Pure black copy" and move the selection
 *    onto it, having changed nothing at all.
 *
 * A function rather than a condition inside the editor's `onValueChange`, so the rule can be tested
 * without a keyboard.
 */
fun TerminalScheme.withTyped(slot: TerminalSlot, raw: String): TerminalScheme? {
    val normalised = TerminalScheme.normalise(raw) ?: return null
    if (normalised == slot.read(this)) return null
    return slot.write(this, normalised)
}

/**
 * The twenty-one editable roles, in the order the editor lists them.
 *
 * An enum with accessors rather than twenty-one hand-written rows, because the editor, the tests
 * and the "is every colour a colour" check all want to walk the same list, and a hand-written screen
 * is how a scheme ends up with a field nothing can edit.
 */
enum class TerminalSlot(
    val label: String,
    val read: (TerminalScheme) -> String,
    val write: (TerminalScheme, String) -> TerminalScheme,
) {
    Background("Background", { it.background }, { s, v -> s.copy(background = v) }),
    Foreground("Text", { it.foreground }, { s, v -> s.copy(foreground = v) }),
    Cursor("Cursor", { it.cursor }, { s, v -> s.copy(cursor = v) }),
    CursorAccent("Cursor text", { it.cursorAccent }, { s, v -> s.copy(cursorAccent = v) }),
    Selection("Selection", { it.selectionBackground }, { s, v -> s.copy(selectionBackground = v) }),
    Black("Black", { it.black }, { s, v -> s.copy(black = v) }),
    Red("Red", { it.red }, { s, v -> s.copy(red = v) }),
    Green("Green", { it.green }, { s, v -> s.copy(green = v) }),
    Yellow("Yellow", { it.yellow }, { s, v -> s.copy(yellow = v) }),
    Blue("Blue", { it.blue }, { s, v -> s.copy(blue = v) }),
    Magenta("Magenta", { it.magenta }, { s, v -> s.copy(magenta = v) }),
    Cyan("Cyan", { it.cyan }, { s, v -> s.copy(cyan = v) }),
    White("White", { it.white }, { s, v -> s.copy(white = v) }),
    BrightBlack("Bright black", { it.brightBlack }, { s, v -> s.copy(brightBlack = v) }),
    BrightRed("Bright red", { it.brightRed }, { s, v -> s.copy(brightRed = v) }),
    BrightGreen("Bright green", { it.brightGreen }, { s, v -> s.copy(brightGreen = v) }),
    BrightYellow("Bright yellow", { it.brightYellow }, { s, v -> s.copy(brightYellow = v) }),
    BrightBlue("Bright blue", { it.brightBlue }, { s, v -> s.copy(brightBlue = v) }),
    BrightMagenta("Bright magenta", { it.brightMagenta }, { s, v -> s.copy(brightMagenta = v) }),
    BrightCyan("Bright cyan", { it.brightCyan }, { s, v -> s.copy(brightCyan = v) }),
    BrightWhite("Bright white", { it.brightWhite }, { s, v -> s.copy(brightWhite = v) });

    /**
     * Whether this phone's emulator actually paints with this colour.
     *
     * False for exactly two, and the editor says which. See the note on [TerminalScheme].
     */
    val paintedHere: Boolean
        get() = this != CursorAccent && this != Selection
}
