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
 * `terminal-theme.ts` is `"#8ae234"` here, so the two files can be diffed by eye and by a script —
 * which `TerminalSchemeTest` now does, reading the TypeScript at test time — and so the hex field in
 * the editor stores exactly what somebody typed rather than a value that has been through two
 * conversions. [Companion.normalise] is the one gate a string passes to become a colour, and
 * [Companion.parse] the one place it becomes an int.
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
    /**
     * Inert on Android for the same reason. The emulator inverts a selection rather than filling it.
     *
     * The one slot that may carry an alpha — `#rrggbbaa`. The shared table declares six of the
     * built-ins with one (`#3b8fee29` for Deck Dark, `#ffffff40` for Tango and Campbell) because on
     * a client that *does* fill, a selection is drawn under text that has to stay readable. This
     * module used to refuse eight digits outright and flattened those six onto their own
     * backgrounds, which made them colours no other client had. See [Companion.parseOrNull] for why
     * the permission is granted to this slot and to nothing else.
     */
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
         * Canonical form of whatever somebody typed, or `null` if it was not a colour.
         *
         * `normaliseColour` in the shared file, with one restriction that file does not have.
         * Tolerant on the way in, because this also reads a half-finished hex field: a missing `#`,
         * upper case, and the short forms, which are doubled the way CSS itself doubles them so that
         * a three-digit colour means here what it means in the sheet somebody copied it out of.
         *
         * **[alpha] is off by default and that is the load-bearing part.** `installTerminalPalette`
         * hands the emulator these strings, and `TerminalColors.parse` on the other side reads eight
         * digits as `#aarrggbb` — the opposite end from `#rrggbbaa`. So `#3b8fee29` typed into a
         * *background* would arrive as a translucent `#8fee29`, drawing over whatever the last frame
         * left behind: the wrong colour and a rendering bug, from a value nobody could have known
         * was wrong. Nineteen slots therefore stay six digits, and [TerminalSlot.carriesAlpha] opens
         * the door for the one that never reaches the emulator at all.
         */
        fun normalise(raw: String, alpha: Boolean = false): String? {
            val body = raw.trim().removePrefix("#").lowercase(Locale.ROOT)
            val expanded = when (body.length) {
                3 -> body.map { "$it$it" }.joinToString("")
                4 -> if (alpha) body.map { "$it$it" }.joinToString("") else return null
                6 -> body
                8 -> if (alpha) body else return null
                else -> return null
            }
            if (!expanded.all { it.isDigit() || it in 'a'..'f' }) return null
            return "#$expanded"
        }

        /**
         * The same string as an **opaque** ARGB int, or `null` when it is not a colour.
         *
         * Opaque even when [alpha] let eight digits through, because everything downstream of this
         * paints with it: the emulator's table, the preview, the editor's swatch. `opaquePart` in the
         * shared file says the same thing from the other direction — *the six-digit part, for a
         * control that cannot express transparency* — and a 28dp chip at sixteen per cent over a
         * card is exactly such a control: it would read as an empty square rather than as a colour.
         * The alpha survives where it is meant to, in the stored string.
         *
         * Returns `null` rather than throwing or guessing, so the field can say *that is not a
         * colour* while somebody is still halfway through typing one.
         */
        fun parseOrNull(raw: String, alpha: Boolean = false): Int? {
            val hex = normalise(raw, alpha) ?: return null
            return 0xff000000.toInt() or hex.substring(1, 7).toInt(16)
        }

        /** The same, for a value already known to be good — every colour in a built-in is. */
        fun parse(raw: String, alpha: Boolean = false): Int =
            parseOrNull(raw, alpha) ?: 0xff000000.toInt()

        /** Back to the canonical `#rrggbb`, lower case, which is the form every scheme is written in. */
        fun format(argb: Int): String =
            String.format(Locale.ROOT, "#%06x", argb and 0xffffff)

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
    val normalised = TerminalScheme.normalise(raw, slot.carriesAlpha) ?: return null
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
    CursorAccent("Text under the cursor", { it.cursorAccent }, { s, v -> s.copy(cursorAccent = v) }),
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

    /**
     * Whether this slot may be written `#rrggbbaa`.
     *
     * Exactly one, and the reason is the same reason [paintedHere] is false for it: the selection is
     * the only colour that never reaches `TerminalColors.updateWith`, so it is the only one where
     * eight digits cannot be misread as `#aarrggbb` by the emulator's own parser. The shared table
     * declares six built-ins with an alpha in this slot and none anywhere else, so this permission
     * is the whole of the difference between mirroring that table and rewriting it.
     */
    val carriesAlpha: Boolean
        get() = this == Selection
}
