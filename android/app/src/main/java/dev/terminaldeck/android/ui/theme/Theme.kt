package dev.terminaldeck.android.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.foundation.text.selection.TextSelectionColors
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration

/**
 * The theme, and the only place a screen may learn a colour, a size or a radius.
 *
 * Three things are provided together and none of them works alone:
 *
 *  1. **[LocalDeckColors]** — this product's vocabulary. `DeckTheme.colors.faint` rather than a
 *     Material slot that happens to be the right grey today.
 *  2. **A Material `ColorScheme` derived from the same values** — so the framework's own controls
 *     (ripple, snackbar, dialog, text-field cursor, progress indicator) are drawn in this palette
 *     rather than in Material's purple, and so the forty-odd `MaterialTheme.colorScheme.*` reads
 *     already written across these screens resolve to the right thing.
 *  3. **The type ladder and the corner radii**, for the same reason.
 *
 * ## The appearance is resolved here and nowhere else
 *
 * One call site decides light or dark for the whole window. That rule is the change rather than a
 * tidiness: the client this replaces stated *dark* in four places, and every one of them was an
 * override that would have silently ignored a person's choice. `ThemeRuleTest` walks the source and
 * fails if a `darkColorScheme(`, a `lightColorScheme(` or a `SystemBarStyle.dark(` comes back
 * anywhere outside this package.
 */
@Composable
fun TerminalDeckTheme(
    appearance: Appearance = currentAppearance(),
    content: @Composable () -> Unit,
) {
    val configuration = LocalConfiguration.current
    val dark = appearance.isDark(configuration)
    val colors = if (dark) DeckDarkColors else DeckLightColors
    val scheme = remember(dark) { deckColorScheme(dark) }

    /*
     * Selected text is the accent at half strength, with the handles at full.
     *
     * Compose's default derives both from `primary`, which is already right — but the *background*
     * default is `primary` at 40%, and this app sets selections over a terminal's ground where 40%
     * of a blue does not read as a selection at all. Half, matching `Palette.selection` on iOS, and
     * stated rather than inherited so the two clients cannot drift.
     */
    val selection = remember(dark) {
        TextSelectionColors(handleColor = colors.accent, backgroundColor = colors.accent.copy(alpha = 0.5f))
    }

    CompositionLocalProvider(
        LocalDeckColors provides colors,
        LocalTextSelectionColors provides selection,
    ) {
        MaterialTheme(
            colorScheme = scheme,
            typography = DeckTypography,
            shapes = DeckShapes,
            content = content,
        )
    }
}

/**
 * The radii, seen from Material.
 *
 * `extraSmall` through `extraLarge` are what a `Card`, an `AlertDialog`, a `DropdownMenu` and a
 * `Button` reach for when nothing overrides them. Material's defaults run rounder than this product
 * at the large end (28dp on a dialog) and squarer at the small end, and both are visible next to a
 * hand-drawn 14dp card on the same screen.
 */
private val DeckShapes = Shapes(
    extraSmall = RoundedCornerShape(Radius.sm),
    small = RoundedCornerShape(Radius.md),
    medium = RoundedCornerShape(Radius.field),
    large = RoundedCornerShape(Radius.group),
    extraLarge = RoundedCornerShape(Radius.sheet),
)

/**
 * `DeckTheme.colors` — the accessor a screen uses.
 *
 * An object rather than a bare `LocalDeckColors.current` at every call site, because the name is
 * what makes the rule readable: *colours come from the theme*. It reads the same way
 * `MaterialTheme.colorScheme` does, which is deliberate — the two sit next to each other in this
 * codebase and should look like siblings rather than like one of them being a workaround.
 */
object DeckTheme {
    val colors: DeckColors
        @Composable @ReadOnlyComposable get() = LocalDeckColors.current

    val type: Typography
        @Composable @ReadOnlyComposable get() = MaterialTheme.typography
}
