package dev.terminaldeck.android.ui.theme

/**
 * The schemes that ship with the app.
 *
 * ## These values are not invented here
 *
 * Every scheme below except the first four is somebody else's published palette, transcribed. That
 * is the point: a person who chose Nord did not choose *a bluish grey* — they chose `#2e3440`, and a
 * scheme that is nearly Nord is worse than no Nord at all, because it looks right until it is next
 * to the real one. Where a palette has more than one circulating spelling, the one taken is named in
 * the comment above it, so the next person to compare against a screenshot knows which sheet to
 * compare against rather than guessing.
 *
 * ## The first four are this product's own
 *
 * [terminalDeck] is what this app has always drawn, written down for the first time. [pureBlack] and
 * [darkGrey] are the same sixteen colours on a different paper, because that is what the request
 * actually was — a choice of *ground*, mostly — and a person who wants a black terminal wants their
 * output to keep looking the way it looks. [terminalDeckLight] is the light half, and it exists
 * because Settings already promises it in so many words: *"a session opened in Light is drawn
 * dark-on-paper"*. A default that ignored the app's appearance would break a sentence that is on
 * screen today.
 *
 * ## Why the sixteen differ between the two Terminal Deck schemes
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
     * The selection is the desktop's `--accent-soft` — `rgba(59,143,238,0.16)` — flattened onto this
     * background, because a scheme is opaque by construction (see `TerminalScheme.parseOrNull`).
     * It is stored for the desktop's benefit and this phone does not paint with it.
     */
    val terminalDeck = scheme(
        id = "terminaldeck",
        name = "Terminal Deck",
        background = "#191919",
        foreground = "#ededed",
        cursor = "#3b8fee",
        cursorAccent = "#0f1114",
        selection = "#1e2c3b",
        ansi = darkAnsi,
    )

    /** The same product scheme on paper. `--terminal-bg` / `--terminal-fg` from the light theme. */
    val terminalDeckLight = scheme(
        id = "terminaldeck-light",
        name = "Terminal Deck Light",
        background = "#e8e8e8",
        foreground = "#141414",
        cursor = "#1a66c4",
        cursorAccent = "#ffffff",
        selection = "#d3ddec",
        ansi = lightAnsi,
    )

    /** Asked for by name. The product's sixteen, on nothing at all. */
    val pureBlack = scheme(
        id = "pure-black",
        name = "Pure black",
        background = "#000000",
        foreground = "#ededed",
        cursor = "#3b8fee",
        cursorAccent = "#000000",
        selection = "#091726",
        ansi = darkAnsi,
    )

    /**
     * A ground that is plainly grey rather than plainly black.
     *
     * `#2b2b2b` is two steps up the app's own surface ramp from `--terminal-bg`, far enough from
     * `#191919` to be a different choice rather than a rounding of it.
     */
    val darkGrey = scheme(
        id = "dark-grey",
        name = "Dark grey",
        background = "#2b2b2b",
        foreground = "#ededed",
        cursor = "#3b8fee",
        cursorAccent = "#0f1114",
        selection = "#2e3b4a",
        ansi = darkAnsi,
    )

    /** Ethan Schoonover's Solarized, dark. The base16 mapping the reference iTerm scheme uses. */
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

    /** The same sixteen — Solarized is one palette — on `base3`, with the ink walked the other way. */
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

    /** Arctic Ice Studio's Nord, in the terminal mapping the project publishes (`nord0`…`nord15`). */
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

    /** Zeno Rocha's Dracula, from the project's own terminal specification. */
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

    /** Pavel Pertsev's Gruvbox, dark, **medium** contrast — the variant the project ships as default. */
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

    /**
     * Son A. Pham's One Half, dark.
     *
     * Taken from Windows Terminal's built-in "One Half Dark" rather than from the vim colourscheme,
     * because that is the spelling with a stated cursor and selection — the vim one has neither, and
     * a terminal needs both.
     */
    val oneHalfDark = scheme(
        id = "one-half-dark",
        name = "One Half Dark",
        background = "#282c34",
        foreground = "#dcdfe4",
        cursor = "#a3b3cc",
        cursorAccent = "#282c34",
        selection = "#474e5d",
        ansi = listOf(
            "#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#dcdfe4",
            "#5a6374", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#dcdfe4",
        ),
    )

    /** The same source's light half, from the same Windows Terminal sheet, for the same reason. */
    val oneHalfLight = scheme(
        id = "one-half-light",
        name = "One Half Light",
        background = "#fafafa",
        foreground = "#383a42",
        cursor = "#4f525d",
        cursorAccent = "#fafafa",
        selection = "#bfceff",
        ansi = listOf(
            "#383a42", "#e45649", "#50a14f", "#c18401", "#0184bc", "#a626a4", "#0997b3", "#fafafa",
            "#4f525d", "#df6c75", "#98c379", "#e4c07a", "#61afef", "#c577dd", "#56b5c1", "#ffffff",
        ),
    )

    /**
     * The Tango Desktop Project's palette, on Tango's own `Aluminium`/`Sky` ground.
     *
     * The sixteen are the same sixteen [terminalDeck] uses — that set *is* Tango-derived, and this
     * app has drawn it since the beginning. What makes this a different choice is the paper:
     * `#2e3436` rather than `#191919`, which is GNOME Terminal's Tango and reads a half-step warmer
     * and lighter.
     */
    val tango = scheme(
        id = "tango",
        name = "Tango",
        background = "#2e3436",
        foreground = "#d3d7cf",
        cursor = "#d3d7cf",
        cursorAccent = "#2e3436",
        selection = "#555753",
        ansi = darkAnsi,
    )

    /** Windows Terminal's default scheme, as Microsoft publishes it. */
    val campbell = scheme(
        id = "campbell",
        name = "Campbell",
        background = "#0c0c0c",
        foreground = "#cccccc",
        cursor = "#ffffff",
        cursorAccent = "#0c0c0c",
        selection = "#ffffff",
        ansi = listOf(
            "#0c0c0c", "#c50f1f", "#13a10e", "#c19c00", "#0037da", "#881798", "#3a96dd", "#cccccc",
            "#767676", "#e74856", "#16c60c", "#f9f1a5", "#3b78ff", "#b4009e", "#61d6d6", "#f2f2f2",
        ),
    )

    /**
     * Everything that ships, in the order the picker draws them.
     *
     * This product's own four first, because they are what somebody already has and the list has to
     * start with *where I am now*; then the published schemes, dark and light together where a
     * palette has both halves.
     */
    val builtIns: List<TerminalScheme> = listOf(
        terminalDeck,
        terminalDeckLight,
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
     */
    const val MATCH_APPEARANCE = "auto"

    /** What [MATCH_APPEARANCE] resolves to, given what the app's appearance currently resolves to. */
    fun forAppearance(dark: Boolean): TerminalScheme = if (dark) terminalDeck else terminalDeckLight
}
