package dev.terminaldeck.android.ui.theme

import com.termux.terminal.TerminalColors
import com.termux.terminal.TerminalSession
import java.util.Properties

/**
 * A chosen colour scheme, installed into the vendored emulator.
 *
 * ## The bug this closed, and the request that widened it
 *
 * The emulator ships Termux's own default scheme — a brighter xterm chart with `#00cd00` for green,
 * `#6495ed` for blue and `#000000` for the ground. The desktop and iOS both render the Tango-derived
 * set that `tokens.css` declares as `--ansi-*`. So **the same session rendered in two different
 * colour schemes depending on which screen it was read on**, which is not a small thing on a client
 * whose entire content is coloured program output: a diff's red and green, an agent's status lines
 * and a compiler's error markers were all a different colour on the phone from the machine they
 * came from.
 *
 * That is fixed by handing the emulator this product's own sixteen. What changed since is that the
 * sixteen are no longer the *only* sixteen: Asad asked for the terminal colour to be a choice, on
 * *"phone also, for Windows, for MacBook, all of them"*. So this function takes a [TerminalScheme]
 * rather than a boolean, and the boolean it used to take now lives one level up, in
 * [TerminalSchemeStore.resolve], where *which* scheme is a question rather than an assumption.
 *
 * Nothing in the vendored module is edited. `TerminalColorScheme.updateWith(Properties)` is the
 * emulator's own public door for exactly this — it is what Termux's own colour-properties file goes
 * through — and the keys it takes (`color0`…`color15`, `foreground`, `background`, `cursor`) are the
 * ones written below. See `VENDORED.md`: the rule is to reach the vendored code through its API
 * rather than to fork it, so that the next upgrade is a copy rather than a merge.
 *
 * ## Why the cursor is stated rather than derived
 *
 * `updateWith` will pick a cursor for you when none is given — white on a dark ground, black on a
 * light one — and that is a reasonable default and the wrong answer here. Every scheme states its
 * own caret, and a scheme's caret is part of the scheme: Nord's is `#d8dee9` and Campbell's is white
 * because their authors said so. Passing `cursor` explicitly also stops
 * `setCursorColorForBackground` from running at all, which is what makes the result deterministic
 * enough to assert in a test.
 *
 * ## The three keys are all there are
 *
 * A scheme carries twenty-one colours and this hands over nineteen. `cursorAccent` and
 * `selectionBackground` have no key here because the emulator has no slot for them — it inverts for
 * both. [TerminalScheme] says so where the fields are declared, and the editor says so on the two
 * rows. They are carried rather than dropped so that a scheme edited on a phone is still a whole
 * scheme when it reaches a desktop.
 *
 * ## When this runs
 *
 * Once before the first session is attached, and again on every change to the appearance *or* to the
 * scheme. The table is process-wide static state inside the emulator (`TerminalColors.COLOR_SCHEME`),
 * and a `TerminalColors` instance copies from it at construction — so a session that already exists
 * keeps the old table until it is told to re-read, which is what [refreshLiveSession] is for.
 */
fun installTerminalPalette(scheme: TerminalScheme) {
    val props = Properties()
    scheme.ansi.forEachIndexed { index, value -> props["color$index"] = value }
    props["foreground"] = scheme.foreground
    props["background"] = scheme.background
    props["cursor"] = scheme.cursor
    TerminalColors.COLOR_SCHEME.updateWith(props)
}

/**
 * Make a session already on screen re-read the scheme.
 *
 * `TerminalColors.reset()` copies the defaults back over the current table, which also discards any
 * colour a program set with `OSC 4` — and that is correct rather than regrettable. The scheme just
 * changed; a palette a program tuned for the ground that is no longer there is not worth preserving,
 * and a program that cares re-emits its own sequences on the next redraw.
 *
 * This is the whole of what makes an edit land on a live session: somebody dragging a hex field in
 * Settings is changing static state the open terminal has already copied, and without this the
 * change would appear on the next session and never on the one they are looking at.
 *
 * Null-safe on the emulator because a session that has not been given a size yet has none.
 */
fun refreshLiveSession(session: TerminalSession?) {
    session?.emulator?.mColors?.reset()
}
