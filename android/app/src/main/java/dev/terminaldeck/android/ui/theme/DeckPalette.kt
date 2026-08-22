package dev.terminaldeck.android.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * The palette, in one place, in both appearances.
 *
 * These values are not invented here. They are `src/renderer/styles/tokens.css` read across — the
 * same hexes the desktop ships and the same table `ios/TerminalDeck/App/Theme.swift` carries —
 * because the phone, the tablet and the desktop are one product and somebody holding two of them
 * can see a quarter-stop of difference in a grey even when they cannot name it. When that file
 * changes, this one changes with it, and `PaletteParityTest` fails until it does.
 *
 * ## What this replaces
 *
 * The set this replaces was `#3DDC84` on `#0B0D10` — Android's own brand green on a blue-tinted
 * charcoal — with `#8B93A1` as the quiet ink. None of those three exists anywhere else in this
 * product. The green is the platform's logo colour, which is a stranger's brand worn as if it were
 * ours; the charcoal ran four levels of blue ahead of red, which is the same mistake the desktop
 * was reported for in the other direction (it used to run warm, and read as faintly orange once a
 * whole screen was filled with it). Both are fixed here rather than papered over downstream.
 *
 * ## Both appearances are first-class
 *
 * Every role below is a [Duo] — a light value and a dark value — so no colour can exist in one
 * appearance and not the other. That is the rule `tokens.css` names for itself (*"never define a
 * colour only inside `[data-theme='dark']`"*) and the failure this whole file is fixing: the
 * Android app was pinned dark in four separate places and had no light half to switch to.
 *
 * The light values are `tokens.css`'s own light theme, carried across exactly as the dark ones
 * were. They are **not** the dark ones lightened. A light theme derived by lightening a dark one
 * gets the surfaces roughly right and every ink on them wrong, because the ink has to travel the
 * other way and by a different amount — which is how a "light mode" ends up as grey text on grey
 * cards.
 *
 * ## Why the greys are exactly neutral
 *
 * `r == g == b`, deliberately, on every surface in both appearances. Invisible in a swatch, and the
 * difference between a screen that reads as grey and one that reads as tinted once it fills a
 * phone. `PaletteParityTest` asserts it rather than trusting the eye.
 */

/**
 * One colour, written the way the CSS writes it.
 *
 * A hex literal rather than three integers, because that is the form these values are read across
 * in — `#191919` in `tokens.css` is `0x191919` here, and a transcription error is visible on the
 * line rather than hidden in an argument order. The alpha is separate because the tints
 * (`--border`, `--bg-hover`) are a colour *and* a strength, and the strength differs between the
 * appearances while the colour does not.
 */
@JvmInline
value class Shade private constructor(private val packed: Long) {
    constructor(hex: Int, alpha: Float = 1f) : this(
        (hex.toLong() and 0xffffffL) or ((alpha.coerceIn(0f, 1f) * 255f + 0.5f).toLong() shl 32)
    )

    val red: Int get() = ((packed shr 16) and 0xff).toInt()
    val green: Int get() = ((packed shr 8) and 0xff).toInt()
    val blue: Int get() = (packed and 0xff).toInt()
    val alpha: Float get() = ((packed shr 32) and 0xff).toInt() / 255f

    /** The Compose colour. */
    val color: Color get() = Color(red = red, green = green, blue = blue, alpha = (alpha * 255f + 0.5f).toInt())

    /**
     * The `0xAARRGGBB` integer the terminal emulator wants. `TerminalRenderer` takes packed ints and
     * has no notion of a Compose colour, so the one conversion lives here rather than at the call
     * site.
     */
    val argb: Int
        get() = (((alpha * 255f + 0.5f).toInt() and 0xff) shl 24) or (red shl 16) or (green shl 8) or blue
}

/**
 * One role, in both appearances.
 *
 * Everything in [Ink] is one of these, which is what makes "a colour that only exists in the dark"
 * unrepresentable rather than merely discouraged.
 */
data class Duo(val light: Shade, val dark: Shade) {
    fun shade(dark: Boolean): Shade = if (dark) this.dark else light
    fun color(dark: Boolean): Color = shade(dark).color
}

/**
 * The raw values. Internal to the theme package so no screen can reach past [DeckColors] and
 * hard-code a hex.
 */
internal object Ink {
    /* Surfaces. `--bg-primary` … `--bg-sunken`, both themes. */
    val background = Duo(light = Shade(0xffffff), dark = Shade(0x191919))
    val raised = Duo(light = Shade(0xf5f5f5), dark = Shade(0x202020))
    val raisedHigh = Duo(light = Shade(0xededed), dark = Shade(0x252525))
    val sunken = Duo(light = Shade(0xeaeaea), dark = Shade(0x121212))

    /*
     * Text. `--text-primary` / `--text-secondary` / `--text-muted`.
     *
     * The light tier is checked against `--bg-tertiary`, the lightest surface a card uses, rather
     * than against white: 14.6:1, 6.5:1 and 4.9:1. Even the quietest tier is AA body text wherever
     * it lands, which is the property that stops a light theme from being grey-on-grey.
     */
    val primary = Duo(light = Shade(0x1c1c1c), dark = Shade(0xededed))
    val secondary = Duo(light = Shade(0x545454), dark = Shade(0xa8a8a8))
    val muted = Duo(light = Shade(0x666666), dark = Shade(0x8f8f8f))

    /*
     * The application icon's own blue, and the ink that goes on top of it.
     *
     * `build/art/icon.mjs` paints the card's spine as a gradient from `#3b8fee` down to `#2371d6`;
     * the dark theme takes the top stop verbatim and the light theme walks the same hue (≈213°)
     * down in lightness until it clears AA as text on paper. `onAccent` flips because no single
     * blue is both readable as text on `#191919` and dark enough for white to sit on top of it —
     * Apple's own dark-mode tinted controls make the same trade.
     */
    val accent = Duo(light = Shade(0x1a66c4), dark = Shade(0x3b8fee))
    val accentPressed = Duo(light = Shade(0x124a92), dark = Shade(0x7db4f5))
    val onAccent = Duo(light = Shade(0xffffff), dark = Shade(0x0f1114))
    /** `--accent-soft`: the accent as a wash, for a selected row that must not become a button. */
    val accentSoft = Duo(light = Shade(0x1a66c4, alpha = 0.10f), dark = Shade(0x3b8fee, alpha = 0.16f))

    /*
     * Status. The desktop's `--status-*`, unchanged: blue means working, amber means it wants you,
     * green means it finished, red means it stopped.
     *
     * The light half is the same hue walked the other way rather than a lightening, because every
     * one of these is set as *text* somewhere in this app and not only as a dot.
     */
    val working = Duo(light = Shade(0x1667c8), dark = Shade(0x64a6e8))
    val waiting = Duo(light = Shade(0x8f5800), dark = Shade(0xddb04a))
    val input = Duo(light = Shade(0xb83c08), dark = Shade(0xf0913f))
    val completed = Duo(light = Shade(0x19714a), dark = Shade(0x5fbf95))
    val critical = Duo(light = Shade(0xbd3a2c), dark = Shade(0xff6f60))
    val positive = Duo(light = Shade(0x19714a), dark = Shade(0x5fbf95))
    val warning = Duo(light = Shade(0x8f5800), dark = Shade(0xddb04a))

    /**
     * `--critical-fill` and the ink on it: a filled destructive button, where the label is white in
     * both appearances because the fill is dark enough in both.
     */
    val criticalFill = Duo(light = Shade(0xbd3a2c), dark = Shade(0xcf3d2c))
    val onCriticalFill = Duo(light = Shade(0xffffff), dark = Shade(0xffffff))

    /*
     * Tints — a strength of the ink rather than a named grey, so a control sits on any surface
     * without knowing which one it is.
     *
     * The base flips with the appearance and that is the whole trick: a dark theme tints *towards
     * white*, a light theme tints *towards the ink*. A light theme that kept the white tint would
     * be painting white on near-white, which is how a pressed state ends up invisible.
     *
     * `rgb(56, 56, 56)` is `tokens.css`'s own tint base for the light theme, so the strengths below
     * land where they were tuned to land.
     */
    val hairline = Duo(light = Shade(0x383838, alpha = 0.10f), dark = Shade(0xffffff, alpha = 0.09f))
    val hairlineStrong = Duo(light = Shade(0x383838, alpha = 0.18f), dark = Shade(0xffffff, alpha = 0.17f))
    val pressed = Duo(light = Shade(0x383838, alpha = 0.055f), dark = Shade(0xffffff, alpha = 0.055f))
    val key = Duo(light = Shade(0x383838, alpha = 0.11f), dark = Shade(0xffffff, alpha = 0.10f))
    val keyPressed = Duo(light = Shade(0x383838, alpha = 0.24f), dark = Shade(0xffffff, alpha = 0.22f))
    val keyDisabled = Duo(light = Shade(0x383838, alpha = 0.05f), dark = Shade(0xffffff, alpha = 0.05f))

    /**
     * The fill under an action that carries no meaning of its own.
     *
     * The only role in this file that is **the same in both appearances**, because it has only one
     * thing to be readable against and that thing is white in both. `#767676` carries white at
     * 4.6:1; Apple's own neutral swipe action (`#8e8e93`) is 2.8:1 and this is deliberately darker.
     */
    val neutralAction = Duo(light = Shade(0x767676), dark = Shade(0x767676))

    /*
     * The terminal's own paper and ink — its own pair rather than a reuse of a surface.
     *
     * On paper the terminal must **not** be the app's canvas. `tokens.css` says why, in the words
     * of the person who reported it: a terminal painted `--bg-primary` in the light theme *"is pure
     * white, and inside the terminal itself it is a little bit different, like kind of grey"* — it
     * stops being a terminal and becomes an empty document with a cursor in it. `#e8e8e8` is the
     * desktop's `--terminal-bg`, and it is the same hex the desktop paints so the two products'
     * terminals are one colour.
     */
    val terminalPaper = Duo(light = Shade(0xe8e8e8), dark = Shade(0x121212))
    val terminalInk = Duo(light = Shade(0x141414), dark = Shade(0xededed))

    /**
     * The sixteen ANSI colours, in both appearances, in the order the wire numbers them.
     *
     * ## The dark set is the desktop's, verbatim
     *
     * Those sixteen hexes are what a session looks like in the window on the Mac — `@xterm/xterm`'s
     * Tango-derived defaults, now declared outright as `--ansi-*` in `tokens.css`. The vendored
     * emulator's own default is a *different* set (a brighter xterm chart, `#00cd00` green,
     * `#6495ed` blue), so until this table existed the same session rendered in two different
     * colour schemes depending on whether it was read on the phone or on the Mac. Installing the
     * desktop's set ends that; see [installTerminalPalette].
     *
     * ## The light set is the same sixteen, walked down until they can be read
     *
     * Scaled toward black — which preserves hue and saturation exactly and moves only value — until
     * each clears its target on `#e8e8e8`. The normal eight target 4.6:1 and the bright eight
     * target 7:1, because on a dark ground "bright" means lighter and on paper it means darker;
     * given both the same target they collapse onto each other.
     *
     * Three deliberate exceptions, each a property of what an ANSI palette *is*: black and bright
     * black keep their places on the ramp (they already clear, and darkening bright black past
     * black would invert the pair), and white and bright white are left alone and are unreadable as
     * foreground on paper — because they are used as *backgrounds* as often as foregrounds, and
     * darkening them would turn `ESC[47m` into a black band. Every light terminal scheme in use
     * makes the same trade, the desktop included.
     */
    val ansi: List<Duo> = listOf(
        Duo(light = Shade(0x2e3436), dark = Shade(0x2e3436)),  // black
        Duo(light = Shade(0xcc0000), dark = Shade(0xcc0000)),  // red
        Duo(light = Shade(0x3b7405), dark = Shade(0x4e9a06)),  // green
        Duo(light = Shade(0x7c6500), dark = Shade(0xc4a000)),  // yellow
        Duo(light = Shade(0x3465a4), dark = Shade(0x3465a4)),  // blue
        Duo(light = Shade(0x75507b), dark = Shade(0x75507b)),  // magenta
        Duo(light = Shade(0x057375), dark = Shade(0x06989a)),  // cyan
        Duo(light = Shade(0xd3d7cf), dark = Shade(0xd3d7cf)),  // white
        Duo(light = Shade(0x555753), dark = Shade(0x555753)),  // bright black
        Duo(light = Shade(0x951a1a), dark = Shade(0xef2929)),  // bright red
        Duo(light = Shade(0x335413), dark = Shade(0x8ae234)),  // bright green
        Duo(light = Shade(0x534d1a), dark = Shade(0xfce94f)),  // bright yellow
        Duo(light = Shade(0x384e65), dark = Shade(0x729fcf)),  // bright blue
        Duo(light = Shade(0x5d445b), dark = Shade(0xad7fa8)),  // bright magenta
        Duo(light = Shade(0x135454), dark = Shade(0x34e2e2)),  // bright cyan
        Duo(light = Shade(0xeeeeec), dark = Shade(0xeeeeec)),  // bright white
    )
}
