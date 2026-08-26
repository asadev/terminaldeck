package dev.terminaldeck.android.ui

/**
 * The touch key row, and the sticky Ctrl behind it.
 *
 * Transcribed from `pwa/src/keybar.ts`, including the reasoning, because the two clients should
 * not disagree about what Ctrl does.
 *
 * ## Why this exists at all
 *
 * The Android software keyboard has no Esc, no Tab, no Ctrl and no arrows, and it hides `|`, `/`,
 * `-` and `~` behind two page flips. Every one of those is on the critical path of using a
 * terminal: Ctrl+C stops a runaway process, Tab completes a path, the up arrow recalls the last
 * command, `~` starts a home path and `|` builds a pipeline. Without this row the app renders a
 * terminal that can type prose at a shell and nothing else.
 *
 * ## Why Ctrl is sticky rather than held
 *
 * A finger cannot hold a chord. Ctrl therefore arms, and the next key folds into it — the same
 * interaction every phone keyboard uses for shift. Arming is a toggle, so a mistaken tap is undone
 * by tapping again rather than by being forced to spend it on a key.
 *
 * An armed Ctrl is always spent by the next key, **including a key it cannot combine with**.
 * Leaving it armed after a key it does not apply to means it fires on the key after that, which is
 * how a sticky modifier turns a `w` into a Ctrl+W and closes something.
 *
 * ## No Compose in this file
 *
 * The state machine is where the bugs live, and it is unit-tested on a plain JVM. The row that
 * draws it is in `TerminalScreen`.
 */

enum class KeyBarKey(val id: String, val label: String, val title: String) {
    Esc("esc", "esc", "Escape"),
    Tab("tab", "tab", "Tab"),
    Ctrl("ctrl", "ctrl", "Control — applies to the next key"),
    Up("up", "↑", "Up arrow"),
    Down("down", "↓", "Down arrow"),
    Left("left", "←", "Left arrow"),
    Right("right", "→", "Right arrow"),
    Pipe("pipe", "|", "Pipe"),
    Slash("slash", "/", "Slash"),
    Dash("dash", "-", "Hyphen"),
    Tilde("tilde", "~", "Tilde"),
}

/**
 * The fixed bar, in tap order, and it is only five keys now.
 *
 * This used to be every key in the enum in one horizontal scroll, which is the shape iOS threw out
 * and wrote down why in `KeyPlan`: a scrolling bar has no fixed positions, so no muscle memory ever
 * forms and the key you want is always mid-swipe. The bar now carries only what is pressed *while
 * typing a command* — `esc` `tab` `ctrl` `↑` `↓` — and everything else (the horizontal arrows, the
 * symbols, the signals, alt and the function keys) moved into the grid the *more keys* button opens.
 * See [KeyGrid.groups].
 *
 * Ctrl sits third rather than first: on a phone held one-handed the far left of the row is the
 * least reachable spot, and Esc and Tab are the two that get hit blind. The enum keeps all of its
 * members — [KeyBar.press] and its tests still speak for the arrows and symbols the grid now draws —
 * but the bar shows this handful.
 */
val KEY_BAR: List<KeyBarKey> = listOf(
    KeyBarKey.Esc,
    KeyBarKey.Tab,
    KeyBarKey.Ctrl,
    KeyBarKey.Up,
    KeyBarKey.Down,
)

/** What a press produced: bytes for the session, and the modifier state after it. */
data class KeyPress(val data: String, val ctrl: Boolean)

object KeyBar {

    /**
     * The ASCII control byte for a character, or null when there is not one.
     *
     * This is the actual rule rather than a table of guesses: a control character is the printable
     * one with bits 6 and 7 cleared, which is defined for `@` through `_` and, by the same masking,
     * the lowercase letters. Space is `@` under another name and `?` is the odd one at 0x7F.
     *
     * Everything else returns null, deliberately. Terminals disagree about Ctrl+`/` — the mask says
     * 0x0F, several emulators send 0x1F — and this client cannot ask which one is on the other end
     * of the socket, so it does not invent an answer.
     */
    fun controlByteFor(char: Char): String? = when {
        char == ' ' -> "\u0000"
        char == '?' -> "\u007f"
        char.code in 0x40..0x5f -> (char.code and 0x1f).toChar().toString()
        char.code in 0x61..0x7a -> (char.code and 0x1f).toChar().toString()
        else -> null
    }

    /**
     * Press a key from the row.
     *
     * @param ctrl whether Ctrl is currently armed.
     */
    fun press(key: KeyBarKey, ctrl: Boolean): KeyPress = when (key) {
        KeyBarKey.Ctrl -> KeyPress("", !ctrl)

        // Arrows under Ctrl are the word-motion sequences xterm defines; sending the plain arrow
        // instead would silently drop the modifier the user just armed.
        KeyBarKey.Up -> KeyPress(if (ctrl) CSI + "1;5A" else CSI + "A", false)
        KeyBarKey.Down -> KeyPress(if (ctrl) CSI + "1;5B" else CSI + "B", false)
        KeyBarKey.Right -> KeyPress(if (ctrl) CSI + "1;5C" else CSI + "C", false)
        KeyBarKey.Left -> KeyPress(if (ctrl) CSI + "1;5D" else CSI + "D", false)

        KeyBarKey.Esc -> KeyPress(ESC, false)
        KeyBarKey.Tab -> KeyPress(if (ctrl) CSI + "Z" else "\t", false)

        // A character key: fold Ctrl in if there is a control byte for it, and spend the modifier
        // either way.
        KeyBarKey.Pipe -> character('|', ctrl)
        KeyBarKey.Slash -> character('/', ctrl)
        KeyBarKey.Dash -> character('-', ctrl)
        KeyBarKey.Tilde -> character('~', ctrl)
    }

    /**
     * Escape, written as an escape.
     *
     * A raw 0x1B byte in source is invisible in every diff and in every editor, and a sequence
     * missing its introducer types `[A` at the shell instead of moving the cursor — which looks
     * like a broken key rather than a broken constant.
     */
    private const val ESC = "\u001b"

    /** Escape followed by `[`, spelled out so no sequence below hides its introducer. */
    private const val CSI = "\u001b["

    private fun character(char: Char, ctrl: Boolean): KeyPress =
        KeyPress(if (ctrl) controlByteFor(char) ?: char.toString() else char.toString(), false)
}

/**
 * What is in the grid the *more keys* button opens, and what each key sends.
 *
 * Transcribed from `ios/TerminalDeck/Terminal/KeyPlan.swift`, groups and order and all, so the two
 * phones do not disagree about what a key does or where a thumb finds it. Pure data, like the rest
 * of this file, so the one thing worth getting wrong - does every key send the bytes a terminal
 * acts on - is answerable without a screenshot. The Compose that draws it is [KeyGridSheet].
 *
 * ## Why a second model beside [KeyBarKey]
 *
 * The bar's engine ([KeyBar.press]) is a tested state machine about one thing - the sticky Ctrl -
 * and its keys all resolve to a chord or a character. The grid holds kinds the bar never has: an
 * app action (copy, paste), a raw signal byte, a second sticky modifier (alt). Bending the enum to
 * carry all of that would break the very tests that keep Ctrl honest, so the grid gets its own flat
 * data and shares nothing but the escape bytes below.
 *
 * ## Cursor keys send the CSI form, matching the bar rather than the terminal's mode
 *
 * iOS asks the emulator whether it is in application-cursor mode and sends `ESC O A` when it is.
 * This client's bar has always sent the plain `ESC [ A` regardless - see [KeyBar.press] - so the
 * grid does the same: a grid whose arrows disagreed with the bar's directly above it would be the
 * worse bug. Lifting both to honour the mode is a real change and belongs to the bar's engine, not
 * to the surface that draws the keys.
 *
 * The control bytes are built from their code points ([Char.toChar] of 3, 27, ...) rather than
 * written as escapes: a raw 0x1B in source is invisible in every diff and every editor, and the
 * number says plainly which byte it is.
 */
enum class GridModifier { Ctrl, Meta }

/** What pressing a grid key does. The three that are not bytes are handled by the screen. */
sealed interface GridAction {
    /** Literal bytes for the session, already encoded. */
    data class Bytes(val data: String) : GridAction
    /** A cursor key - resolved to `ESC [ <final>` at press time. See the header on the mode. */
    data class Cursor(val final: Char) : GridAction
    /** A sticky modifier the terminal owns; [GridModifier.Meta] is alt, [GridModifier.Ctrl] the bar's. */
    data class Mod(val modifier: GridModifier) : GridAction
    /** Copy the selection or the screen - the app's business, not the wire's. */
    data object Copy : GridAction
    /** Paste the clipboard. */
    data object Paste : GridAction
}

/**
 * One key cap in the grid.
 *
 * [label] is what is written on it - a glyph for the arrows, a word for the rest, because `esc` and
 * `home` have no icon anyone would know. [title] is what a screen reader says and what a test finds
 * the cap by when the label is a symbol. [repeats] is true only for the arrows, where holding to
 * move the cursor is wanted; holding `~` for forty tildes, or `^C` for forty interrupts, is not.
 */
data class GridKey(
    val label: String,
    val title: String,
    val action: GridAction,
    val repeats: Boolean = false,
)

/** A labelled run of keys - the header is the whole point, against a wall of identical squares. */
data class GridGroup(val title: String, val keys: List<GridKey>)

object KeyGrid {

    /** Escape (0x1B), built from its code point so no raw control byte hides in the source. */
    private val ESC: String = 27.toChar().toString()

    /** Escape followed by `[`, spelled out so no sequence below loses its introducer. */
    private val CSI: String = ESC + "["

    /** `ESC [ <final>`, the CSI cursor/edit form. Home and End travel this way too - they are cursor keys. */
    fun cursorBytes(final: Char): String = CSI + final

    /**
     * The bytes for a function key, as xterm sends them - from a table, not a formula.
     *
     * F1-F4 are SS3 (`ESC O P`...`ESC O S`); F5 up are CSI with a number that skips 16, 22 and 27,
     * because the DEC keyboard those came from had keys a PC one does not. Written out because that
     * is the only way it is right.
     */
    fun functionBytes(number: Int): String = when (number) {
        1 -> ESC + "OP"
        2 -> ESC + "OQ"
        3 -> ESC + "OR"
        4 -> ESC + "OS"
        5 -> CSI + "15~"
        6 -> CSI + "17~"
        7 -> CSI + "18~"
        8 -> CSI + "19~"
        9 -> CSI + "20~"
        10 -> CSI + "21~"
        11 -> CSI + "23~"
        12 -> CSI + "24~"
        else -> ""
    }

    private fun symbolTitle(char: String): String = when (char) {
        "|" -> "Pipe"
        "/" -> "Slash"
        "\\" -> "Backslash"
        "-" -> "Hyphen"
        "_" -> "Underscore"
        "~" -> "Tilde"
        ":" -> "Colon"
        "*" -> "Asterisk"
        else -> char
    }

    /**
     * The grid, in the order the groups are read - by how often a group is wanted, not by taxonomy.
     *
     * Edit and signals are what a thumb reaches for in a hurry and open at the top; symbols are what
     * it reaches for while typing; the function keys nobody presses twice a week are last.
     */
    val groups: List<GridGroup> = listOf(
        GridGroup("Edit", listOf(
            GridKey("copy", "Copy the selection, or the screen", GridAction.Copy),
            GridKey("paste", "Paste", GridAction.Paste),
        )),
        GridGroup("Signals", listOf(
            // Written out rather than composed from Ctrl, because these four are the ones worth one
            // tap: interrupt (^C=3), end-of-file (^D=4), suspend (^Z=26), clear (^L=12).
            GridKey("^C", "Interrupt", GridAction.Bytes(3.toChar().toString())),
            GridKey("^D", "End of file", GridAction.Bytes(4.toChar().toString())),
            GridKey("^Z", "Suspend", GridAction.Bytes(26.toChar().toString())),
            GridKey("^L", "Clear the screen", GridAction.Bytes(12.toChar().toString())),
        )),
        GridGroup("Navigation", listOf(
            GridKey("←", "Left arrow", GridAction.Cursor('D'), repeats = true),
            GridKey("→", "Right arrow", GridAction.Cursor('C'), repeats = true),
            GridKey("home", "Home", GridAction.Cursor('H')),
            GridKey("end", "End", GridAction.Cursor('F')),
            GridKey("pgup", "Page up", GridAction.Bytes(CSI + "5~")),
            GridKey("pgdn", "Page down", GridAction.Bytes(CSI + "6~")),
        )),
        GridGroup("Symbols", listOf("|", "/", "\\", "-", "_", "~", ":", "*").map { char ->
            GridKey(char, symbolTitle(char), GridAction.Bytes(char))
        }),
        GridGroup("Modifiers", listOf(
            GridKey("alt", "Alt - sends the next key with an Escape prefix", GridAction.Mod(GridModifier.Meta)),
        )),
        GridGroup("Function", (1..12).map { number ->
            GridKey("F$number", "Function key $number", GridAction.Bytes(functionBytes(number)))
        }),
    )
}
