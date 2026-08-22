package dev.terminaldeck.android.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/**
 * Every colour role this app has, resolved for one appearance.
 *
 * ## Why this exists beside Material's `ColorScheme`
 *
 * Material 3 has slots for a product with a colour: primary, secondary, tertiary and three
 * containers each. This product has **one** accent and three tiers of grey ink, and the roles it
 * genuinely needs — *the quiet tier between body and faint*, *the wash under a finger on a row that
 * is not a button*, *the fill of a key cap*, *what a status word is coloured* — have no Material
 * slot at all. Squeezing them in means `tertiaryContainer` meaning "pressed key" in one file and
 * something else in the next.
 *
 * So both exist and each is asked what it is for. [DeckColors] is the vocabulary: it is what a
 * screen in this app reaches for. [deckColorScheme] is the same values poured into Material's slots
 * so that the framework's own controls — the ripple, the snackbar, the dialog, the text field's
 * cursor — are drawn in this palette rather than in purple. Neither is a copy of the other; the
 * second is derived from the first, here, once.
 *
 * ## `statusColor` is not a `when` at the call site
 *
 * The status vocabulary belongs to the session layer and is free-form on the wire (`protocol.ts`:
 * *"the status vocabulary belongs to the session layer"*), so an unrecognised word must get a
 * neutral colour rather than be dropped or guessed at. One function, mirroring
 * `Theme.statusColor` on iOS, is what keeps two screens from disagreeing about what amber means.
 */
@Immutable
data class DeckColors(
    val isDark: Boolean,

    /* Surfaces */
    val background: Color,
    /** A card sitting on the background. Space separates things in this app; this is for the cases
     *  where space genuinely cannot — two rows inside one card have no gap between them. */
    val surface: Color,
    /** A surface on a surface: a chip inside a card, a key cap, a selected row. */
    val surfaceHigh: Color,
    /** The well cut into the chrome. The terminal's ground in the dark theme. */
    val sunken: Color,

    /* Ink */
    val primary: Color,
    val secondary: Color,
    /** The quietest tier. A value, a caption, a path, a chevron. */
    val faint: Color,

    /* The one accent */
    val accent: Color,
    val accentPressed: Color,
    val accentSoft: Color,
    val onAccent: Color,

    /* Lines and washes */
    val hairline: Color,
    val hairlineStrong: Color,
    val pressed: Color,

    /* Meaning */
    val working: Color,
    val waiting: Color,
    val input: Color,
    val completed: Color,
    val positive: Color,
    val warning: Color,
    val critical: Color,
    val criticalFill: Color,
    val onCriticalFill: Color,
    val neutralAction: Color,

    /* The key bar */
    val key: Color,
    val keyPressed: Color,
    val keyDisabled: Color,
    val keyLabel: Color,
    val keyLabelFaint: Color,

    /* The terminal */
    val terminalPaper: Color,
    val terminalInk: Color,
) {
    /**
     * The dot and the status word on a session row.
     *
     * The vocabulary belongs to the desktop, so an unknown status gets a neutral colour rather than
     * being dropped or guessed at. `running` is carried alongside `working` because this client
     * shipped a build that spelled it that way and a phone that greys out a running session is
     * worse than one that accepts both spellings.
     */
    fun status(status: String): Color = when (status) {
        "working", "running" -> working
        "waiting" -> waiting
        "input" -> input
        "completed" -> completed
        "exited" -> critical
        "idle" -> faint
        else -> faint
    }
}

private fun colors(dark: Boolean) = DeckColors(
    isDark = dark,
    background = Ink.background.color(dark),
    surface = Ink.raised.color(dark),
    surfaceHigh = Ink.raisedHigh.color(dark),
    sunken = Ink.sunken.color(dark),
    primary = Ink.primary.color(dark),
    secondary = Ink.secondary.color(dark),
    faint = Ink.muted.color(dark),
    accent = Ink.accent.color(dark),
    accentPressed = Ink.accentPressed.color(dark),
    accentSoft = Ink.accentSoft.color(dark),
    onAccent = Ink.onAccent.color(dark),
    hairline = Ink.hairline.color(dark),
    hairlineStrong = Ink.hairlineStrong.color(dark),
    pressed = Ink.pressed.color(dark),
    working = Ink.working.color(dark),
    waiting = Ink.waiting.color(dark),
    input = Ink.input.color(dark),
    completed = Ink.completed.color(dark),
    positive = Ink.positive.color(dark),
    warning = Ink.warning.color(dark),
    critical = Ink.critical.color(dark),
    criticalFill = Ink.criticalFill.color(dark),
    onCriticalFill = Ink.onCriticalFill.color(dark),
    neutralAction = Ink.neutralAction.color(dark),
    key = Ink.key.color(dark),
    keyPressed = Ink.keyPressed.color(dark),
    keyDisabled = Ink.keyDisabled.color(dark),
    keyLabel = Ink.primary.color(dark),
    keyLabelFaint = Ink.muted.color(dark),
    terminalPaper = Ink.terminalPaper.color(dark),
    terminalInk = Ink.terminalInk.color(dark),
)

internal val DeckLightColors = colors(dark = false)
internal val DeckDarkColors = colors(dark = true)

/**
 * The same values, poured into Material's slots.
 *
 * Read this as a mapping table rather than as code — every line is a decision about which of this
 * product's roles the framework should reach for when it draws something we did not draw:
 *
 *  - **`primary` is the accent, and `secondary` is amber.** Not because amber is a second brand
 *    colour, but because `connectionTint` and the session list already spend `secondary` on *this
 *    wants you* and would otherwise have to reach around Material to say it.
 *  - **`outline` is the hairline tint, not a grey.** Every border in this app is a strength of the
 *    ink, so it sits correctly on a card and on the canvas without either knowing about the other.
 *  - **`surfaceContainer*` are set explicitly.** Menus, dialogs and the date-style surfaces read
 *    those rather than `surface`, and leaving them at the default is how a dropdown ends up a
 *    different grey from the sheet it opened over — visible, and never obvious from the code.
 *  - **`inverseSurface` is deliberately the *other* appearance's raised grey.** That is what a
 *    snackbar is drawn on, and a snackbar is one of the three places (with the ripple and the
 *    system back gesture) where this app keeps Android's own convention rather than iOS's, because
 *    a toast that looked like an iOS banner would be a control nobody on this platform recognises.
 */
internal fun deckColorScheme(dark: Boolean): ColorScheme {
    val c = if (dark) DeckDarkColors else DeckLightColors
    val inverse = if (dark) DeckLightColors else DeckDarkColors
    val base = if (dark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = c.accent,
        onPrimary = c.onAccent,
        primaryContainer = c.accentSoft,
        onPrimaryContainer = c.primary,
        inversePrimary = c.accentPressed,

        secondary = c.waiting,
        onSecondary = c.onAccent,
        secondaryContainer = c.surfaceHigh,
        onSecondaryContainer = c.primary,

        tertiary = c.positive,
        onTertiary = c.onAccent,
        tertiaryContainer = c.surfaceHigh,
        onTertiaryContainer = c.primary,

        background = c.background,
        onBackground = c.primary,

        surface = c.surface,
        onSurface = c.primary,
        surfaceVariant = c.surfaceHigh,
        onSurfaceVariant = c.faint,
        surfaceTint = c.accent,
        surfaceBright = c.surfaceHigh,
        surfaceDim = c.sunken,
        surfaceContainerLowest = c.background,
        surfaceContainerLow = c.surface,
        surfaceContainer = c.surface,
        surfaceContainerHigh = c.surfaceHigh,
        surfaceContainerHighest = c.surfaceHigh,

        inverseSurface = inverse.surface,
        inverseOnSurface = inverse.primary,

        error = c.critical,
        onError = c.onCriticalFill,
        errorContainer = c.criticalFill,
        onErrorContainer = c.onCriticalFill,

        outline = c.hairline,
        outlineVariant = c.hairline,
        scrim = Color.Black,
    )
}

/**
 * How a screen reaches the palette: `DeckTheme.colors`.
 *
 * `staticCompositionLocalOf` rather than `compositionLocalOf` because the value changes exactly
 * once per appearance switch, and when it does every screen has to be redrawn anyway — the static
 * variant skips the per-read subscription that only pays for itself when a value changes often.
 *
 * The default is the dark set rather than an error, so a `@Preview` or a unit test that renders a
 * component outside [TerminalDeckTheme] draws something correct instead of throwing.
 */
val LocalDeckColors = staticCompositionLocalOf { DeckDarkColors }
