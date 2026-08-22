package dev.terminaldeck.android.ui.theme

import com.termux.terminal.TerminalColors
import com.termux.terminal.TerminalSession
import java.util.Locale
import java.util.Properties

/**
 * The desktop's sixteen ANSI colours, installed into the vendored emulator.
 *
 * ## The bug this closes
 *
 * The emulator ships Termux's own default scheme — a brighter xterm chart with `#00cd00` for green,
 * `#6495ed` for blue and `#000000` for the ground. The desktop and iOS both render the Tango-derived
 * set that `tokens.css` declares as `--ansi-*`. So **the same session rendered in two different
 * colour schemes depending on which screen it was read on**, which is not a small thing on a client
 * whose entire content is coloured program output: a diff's red and green, an agent's status lines
 * and a compiler's error markers were all a different colour on the phone from the machine they
 * came from.
 *
 * Nothing in the vendored module is edited to fix it. `TerminalColorScheme.updateWith(Properties)`
 * is the emulator's own public door for exactly this — it is what Termux's own colour-properties
 * file goes through — and the keys it takes (`color0`…`color15`, `foreground`, `background`,
 * `cursor`) are the ones written below. See `VENDORED.md`: the rule is to reach the vendored code
 * through its API rather than to fork it, so that the next upgrade is a copy rather than a merge.
 *
 * ## Why the cursor is stated rather than derived
 *
 * `updateWith` will pick a cursor for you when none is given — white on a dark ground, black on a
 * light one — and that is a reasonable default and the wrong answer here. The caret is the accent
 * in this product, on every client, because it is the one moving thing on the screen and the accent
 * is what this app uses to mean *here*. Passing `cursor` explicitly also stops
 * `setCursorColorForBackground` from running at all, which is what makes the result deterministic
 * enough to assert in a test.
 *
 * ## When this runs
 *
 * Once before the first session is attached, and again on every appearance change. The scheme is
 * process-wide static state inside the emulator (`TerminalColors.COLOR_SCHEME`), and a
 * `TerminalColors` instance copies from it at construction — so a session that already exists keeps
 * the old table until it is told to re-read, which is what [refreshLiveSession] is for. That is the
 * same shape iOS needs for the same reason: `TerminalBridge.applyColors` re-applies on a trait
 * change because SwiftTerm flattens whatever colour it is handed at the instant it is handed it.
 */
fun installTerminalPalette(dark: Boolean) {
    val props = Properties()
    Ink.ansi.forEachIndexed { index, duo -> props["color$index"] = hex(duo.shade(dark)) }
    props["foreground"] = hex(Ink.terminalInk.shade(dark))
    props["background"] = hex(Ink.terminalPaper.shade(dark))
    props["cursor"] = hex(Ink.accent.shade(dark))
    TerminalColors.COLOR_SCHEME.updateWith(props)
}

/**
 * Make a session already on screen re-read the scheme.
 *
 * `TerminalColors.reset()` copies the defaults back over the current table, which also discards any
 * colour a program set with `OSC 4` — and that is correct rather than regrettable. The appearance
 * just changed; a palette a program tuned for the ground that is no longer there is not worth
 * preserving, and a program that cares re-emits its own sequences on the next redraw.
 *
 * Null-safe on the emulator because a session that has not been given a size yet has none.
 */
fun refreshLiveSession(session: TerminalSession?) {
    session?.emulator?.mColors?.reset()
}

/** `#rrggbb`, which is the one form `TerminalColors.parse` accepts besides `rgb:`. */
private fun hex(shade: Shade): String =
    String.format(Locale.ROOT, "#%02x%02x%02x", shade.red, shade.green, shade.blue)
