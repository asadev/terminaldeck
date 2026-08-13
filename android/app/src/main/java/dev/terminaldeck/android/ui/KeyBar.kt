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
 * The row, in tap order.
 *
 * Ctrl sits third rather than first: on a phone held one-handed the far left of the row is the
 * least reachable spot, and Esc and Tab are the two that get hit blind.
 */
val KEY_BAR: List<KeyBarKey> = KeyBarKey.entries.toList()

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
