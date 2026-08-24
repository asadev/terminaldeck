package dev.terminaldeck.android.ui.theme

/**
 * The schemes that ship with the app.
 *
 * ## This file is a mirror. It is not a design.
 *
 * The scheme is declared once for the whole product in `src/shared/terminal-theme.ts` — the file the
 * desktop's xterm.js reads — and everything here is that file in Kotlin: the same ids, the same
 * names, the same hexes, in the same order. iOS carries the third copy in
 * `TerminalScheme.swift` and says the same thing at the top of it.
 *
 * That was not true until now, and the way it stopped being true is the reason this paragraph
 * exists. This module wrote its table before the shared file existed, so it was a *sibling*
 * declaration rather than a mirror, and eleven values had drifted by the time anybody looked: Tango
 * was a dark grey here and pure black everywhere else, Dark Grey was `#2b2b2b` here and `#262626`
 * everywhere else, One Half Light's yellow was one digit out, and the four schemes this product owns
 * carried different names and a different selection colour. Asad asked for this choice on *"phone
 * also, for Windows, for MacBook, all of them"*, and a scheme that is not the same scheme on Android
 * is the feature failing on one of the three. `TerminalSchemeTest` now reads the TypeScript at test
 * time and fails on any drift, which is the only thing that keeps this true after the next edit.
 *
 * ## These values are not invented here
 *
 * Every scheme below except the first four is somebody else's published palette, transcribed. That
 * is the point: a person who chose Nord did not choose *a bluish grey* — they chose `#2e3440`, and a
 * scheme that is nearly Nord is worse than no Nord at all, because it looks right until it is next
 * to the real one. Where a palette has more than one circulating spelling, the shared file's is the
 * one taken, because the argument about which sheet is canonical has to be had once rather than
 * three times.
 *
 * ## The first four are this product's own
 *
 * [deckDark] is what this app has always drawn. [pureBlack] and [darkGrey] are the same sixteen
 * colours on a different paper, because that is what the request actually was — a choice of
 * *ground*, mostly — and a person who wants a black terminal wants their output to keep looking the
 * way it looks. [deckLight] is the light half, and it exists because Settings already promises it in
 * so many words: *"a session opened in Light is drawn dark-on-paper"*. A default that ignored the
 * app's appearance would break a sentence that is on screen today.
 *
 * ## Why the sixteen differ between the two Deck schemes
 *
 * They are `tokens.css`'s two declarations, and the light one is not the dark one lightened. The
 * dark sixteen were drawn for a near-black ground; on `#e8e8e8` paper the same yellow reads at
 * 2.05:1 and bright yellow at 1.01:1 — output a program went to the trouble of colouring, rendered
 * as a blank line. `tokens.css` carries the derivation; this file carries the result.
 */
object TerminalSchemes {

    /** The sixteen this app draws in the dark: `tokens.css`'s `[data-theme='dark']` block. */
    private val darkAnsi = listOf(
        "#2e3436", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
        "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec",
    )

    /** The sixteen it draws on paper: `tokens.css`'s light block, walked down for contrast. */
    private val lightAnsi = listOf(
        "#2e3436", "#cc0000", "#3b7405", "#7c6500", "#3465a4", "#75507b", "#057375", "#d3d7cf",
        "#555753", "#951a1a", "#335413", "#534d1a", "#384e65", "#5d445b", "#135454", "#eeeeec",
    )

    /**
     * Assemble a scheme from its five roles and its sixteen.
     *
     * A helper rather than twenty-one arguments at each call site, because the failure this file has
     * to avoid is a transcription error, and a call that reads as five named colours plus a list is
     * one a person can check against a published sheet without counting commas.
     */
    private fun scheme(
        id: String,
        name: String,
        background: String,
        foreground: String,
        cursor: String,
        cursorAccent: String,
        selection: String,
        ansi: List<String>,
    ): TerminalScheme {
        require(ansi.size == 16) { "$id has ${ansi.size} ANSI colours, not 16" }
        return TerminalScheme(
            id = id,
            name = name,
            background = background,
            foreground = foreground,
            cursor = cursor,
            cursorAccent = cursorAccent,
            selectionBackground = selection,
            black = ansi[0], red = ansi[1], green = ansi[2], yellow = ansi[3],
            blue = ansi[4], magenta = ansi[5], cyan = ansi[6], white = ansi[7],
            brightBlack = ansi[8], brightRed = ansi[9], brightGreen = ansi[10], brightYellow = ansi[11],
            brightBlue = ansi[12], brightMagenta = ansi[13], brightCyan = ansi[14], brightWhite = ansi[15],
        )
    }

    /**
     * What this app has drawn since the first session ran in it.
     *
     * `--terminal-bg` / `--terminal-fg` from the dark theme, and `--accent` for the caret — the
     * caret is the accent on every client in this product, because it is the one moving thing on
     * the screen and the accent is what this app uses to mean *here*.
     *
     * The selection is the desktop's `--accent-soft`, `rgba(59,143,238,0.16)`, written the way the
     * shared table writes it: `#3b8fee29`, eight digits, `0.16 × 255` rounded. It used to be
     * flattened onto this background here on the grounds that a scheme is opaque — which was true of
     * *this* module and of nothing else, so the flattened value was a colour no other client had.
     * The alpha is carried now. It still changes nothing about what this phone draws: the vendored
     * emulator inverts a selection rather than filling one, and `installTerminalPalette` never hands
     * this slot over. See the note on [TerminalScheme] for the one place that distinction matters.
     */
    val deckDark = scheme(
        id = "deck-dark",
        name = "Deck Dark",
        background = "#191919",
        foreground = "#ededed",
        cursor = "#3b8fee",
        cursorAccent = "#191919",
        selection = "#3b8fee29",
        ansi = darkAnsi,
    )

    /**
     * And its light theme. `--terminal-bg` / `--terminal-fg` from the light theme.
     *
     * The paper is deliberately not the chrome's white: a white terminal on a white toolbar stops
     * looking like a terminal. `--accent-soft` in the light theme is `rgba(26,102,196,0.1)` → `1a`.
     */
    val deckLight = scheme(
        id = "deck-light",
        name = "Deck Light",
        background = "#e8e8e8",
        foreground = "#141414",
        cursor = "#1a66c4",
        cursorAccent = "#e8e8e8",
        selection = "#1a66c41a",
        ansi = lightAnsi,
    )

    /**
     * The one he asked for by name: *"we can choose pure black as background"*.
     *
     * The app's dark scheme over a true black ground rather than a new palette — the sixteen were
     * drawn for a near-black surface and are exactly as legible on `#000000`. The selection is a step
     * heavier than the app's, because sixteen per cent of the accent over `#191919` is visible and
     * over black is very nearly not.
     *
     * On a phone specifically it is also the only scheme that is *actually* black: an OLED panel
     * does not light a `#000000` pixel at all.
     */
    val pureBlack = scheme(
        id = "pure-black",
        name = "Pure Black",
        background = "#000000",
        foreground = "#ededed",
        cursor = "#3b8fee",
        cursorAccent = "#000000",
        selection = "#3b8fee3d",
        ansi = darkAnsi,
    )

    /**
     * The other end of the same idea: a ground light enough to read as grey rather than as black,
     * for a bright room.
     */
    val darkGrey = scheme(
        id = "dark-grey",
        name = "Dark Grey",
        background = "#262626",
        foreground = "#ededed",
        cursor = "#3b8fee",
        cursorAccent = "#262626",
        selection = "#3b8fee33",
        ansi = darkAnsi,
    )

    /**
     * Solarized Dark — Ethan Schoonover, ethanschoonover.com/solarized.
     *
     * base03 ground, base0 ink, and the accent set unchanged. The bright half is the rest of the
     * base ramp rather than brighter accents, which is the design and is what most bad copies of
     * Solarized "fix".
     */
    val solarizedDark = scheme(
        id = "solarized-dark",
        name = "Solarized Dark",
        background = "#002b36",
        foreground = "#839496",
        cursor = "#93a1a1",
        cursorAccent = "#002b36",
        selection = "#073642",
        ansi = listOf(
            "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
        ),
    )

    /**
     * Solarized Light — the same palette, same source, base3 ground and base00 ink.
     *
     * The sixteen are identical to the dark scheme's by design: that invariance is the whole claim
     * Solarized makes.
     */
    val solarizedLight = scheme(
        id = "solarized-light",
        name = "Solarized Light",
        background = "#fdf6e3",
        foreground = "#657b83",
        cursor = "#586e75",
        cursorAccent = "#fdf6e3",
        selection = "#eee8d5",
        ansi = listOf(
            "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
        ),
    )

    /**
     * Nord — nordtheme.com. nord0 ground, nord4 ink; the sixteen are the project's own terminal
     * mapping (nord1/3 for the two blacks, nord7 for bright cyan, nord5/6 for the two whites).
     */
    val nord = scheme(
        id = "nord",
        name = "Nord",
        background = "#2e3440",
        foreground = "#d8dee9",
        cursor = "#d8dee9",
        cursorAccent = "#2e3440",
        selection = "#434c5e",
        ansi = listOf(
            "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
            "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
        ),
    )

    /** Dracula — draculatheme.com, the project's published ANSI set. */
    val dracula = scheme(
        id = "dracula",
        name = "Dracula",
        background = "#282a36",
        foreground = "#f8f8f2",
        cursor = "#f8f8f2",
        cursorAccent = "#282a36",
        selection = "#44475a",
        ansi = listOf(
            "#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
            "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
        ),
    )

    /**
     * Gruvbox Dark — morhetz/gruvbox, the "dark medium" ground with the neutral/bright pairs the
     * palette defines.
     */
    val gruvboxDark = scheme(
        id = "gruvbox-dark",
        name = "Gruvbox Dark",
        background = "#282828",
        foreground = "#ebdbb2",
        cursor = "#ebdbb2",
        cursorAccent = "#282828",
        selection = "#504945",
        ansi = listOf(
            "#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
            "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
        ),
    )

    /** One Half Dark — sonph/onehalf. */
    val oneHalfDark = scheme(
        id = "one-half-dark",
        name = "One Half Dark",
        background = "#282c34",
        foreground = "#dcdfe4",
        cursor = "#dcdfe4",
        cursorAccent = "#282c34",
        selection = "#474e5d",
        ansi = listOf(
            "#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#dcdfe4",
            "#5a6374", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#dcdfe4",
        ),
    )

    /** One Half Light — the same project's light half. */
    val oneHalfLight = scheme(
        id = "one-half-light",
        name = "One Half Light",
        background = "#fafafa",
        foreground = "#383a42",
        cursor = "#383a42",
        cursorAccent = "#fafafa",
        selection = "#bfceff",
        ansi = listOf(
            "#383a42", "#e45649", "#50a14f", "#c18301", "#0184bc", "#a626a4", "#0997b3", "#fafafa",
            "#4f525d", "#df6c75", "#98c379", "#e4c07a", "#61afef", "#c577dd", "#56b5c1", "#ffffff",
        ),
    )

    /**
     * Tango Dark — the GNOME Tango palette over a black ground.
     *
     * This is where the app's own dark sixteen came from, which is why [deckDark] and this look
     * related: the difference is the ground and the ink, not the palette. The one place the sixteen
     * themselves differ is slot zero — Tango's black is a real `#000000`, where the app's is
     * `#2e3436` so that a black-on-black run still has an edge against `#191919` paper.
     *
     * This scheme was drawn on `#2e3436` here until the tables were diffed, which made it the one
     * scheme on the phone that was a dark grey where the desktop showed a black — and black is the
     * ground he named. That is the drift the guard in `TerminalSchemeTest` exists to catch next
     * time, before it reaches a screen he is looking at.
     */
    val tango = scheme(
        id = "tango",
        name = "Tango Dark",
        background = "#000000",
        foreground = "#d3d7cf",
        cursor = "#ffffff",
        cursorAccent = "#000000",
        selection = "#ffffff40",
        ansi = listOf(
            "#000000", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
            "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec",
        ),
    )

    /**
     * Campbell — the palette that ships as the default on Windows, and the one most people arriving
     * from that platform already have in their eye.
     */
    val campbell = scheme(
        id = "campbell",
        name = "Campbell",
        background = "#0c0c0c",
        foreground = "#cccccc",
        cursor = "#ffffff",
        cursorAccent = "#0c0c0c",
        selection = "#ffffff40",
        ansi = listOf(
            "#0c0c0c", "#c50f1f", "#13a10e", "#c19c00", "#0037da", "#881798", "#3a96dd", "#cccccc",
            "#767676", "#e74856", "#16c60c", "#f9f1a5", "#3b78ff", "#b4009e", "#61d6d6", "#f2f2f2",
        ),
    )

    /**
     * Everything that ships, in the order the picker draws them.
     *
     * The app's own two first, because they are what a session already looks like; then the two Asad
     * named, pure black and a dark grey; then the palettes people arrive already knowing. The order
     * is `BUILTIN_SCHEMES`'s order and the guard asserts it, so that the picker on this phone and
     * the picker on the desktop are the same list read top to bottom.
     */
    val builtIns: List<TerminalScheme> = listOf(
        deckDark,
        deckLight,
        pureBlack,
        darkGrey,
        solarizedDark,
        solarizedLight,
        nord,
        dracula,
        gruvboxDark,
        oneHalfDark,
        oneHalfLight,
        tango,
        campbell,
    )

    /** The ids that are shipped, so a stored custom scheme can never shadow one. */
    val builtInIds: Set<String> = builtIns.map { it.id }.toSet()

    fun builtIn(id: String): TerminalScheme? = builtIns.firstOrNull { it.id == id }

    /**
     * The reserved choice that is not a scheme: *follow the app's appearance*.
     *
     * The default, and it has to be, because a fixed default would silently overrule the Light
     * setting the Appearance screen offers one row above it — and that screen says in so many words
     * that a session opened in Light is drawn on paper. A person who picks a scheme by name has
     * overruled it on purpose; a person who has never opened this screen has not.
     *
     * The value is `follow-app` rather than the `auto` this module used to write, for the reason the
     * ids exist at all: it is `FOLLOW_APP_SCHEME_ID` in the shared file and `followAppID` on iOS,
     * and a *stored choice* that spells the default differently on one client is the same defect as
     * a scheme that spells Nord differently. Nothing has shipped with `auto` in it, and a stored id
     * that names no scheme already falls back to the appearance — see [TerminalSchemeStore.resolve]
     * — so an install that somehow carries the old spelling lands on exactly this behaviour anyway.
     */
    const val MATCH_APPEARANCE = "follow-app"

    /** What [MATCH_APPEARANCE] resolves to, given what the app's appearance currently resolves to. */
    fun forAppearance(dark: Boolean): TerminalScheme = if (dark) deckDark else deckLight
}
