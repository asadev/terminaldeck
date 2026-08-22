package dev.terminaldeck.android.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

/**
 * The type scale, matching iOS point for point.
 *
 * ## Why iOS's sizes and not the desktop's
 *
 * `tokens.css` is a desktop sheet: 14px body, 13px callout, 11.5px caption. Those are correct at
 * arm's length on a 27-inch display and are two stops too small in a hand. iOS solved the same
 * problem by keeping the desktop's *structure* — the same ladder of roles, the same negative
 * tracking on the display sizes — and setting it at the sizes a phone reads at. This is that
 * ladder, and the sizes are the ones `ios/TerminalDeck/Screens/` actually sets, role for role:
 *
 * | Role | iOS | Where |
 * |---|---|---|
 * | `largeTitle` | 28 semibold | a screen that owns the window — pairing, add server |
 * | `title` | 20 semibold | a navigation title, a sheet's heading |
 * | `rowTitle` | 17 semibold | the name of a session in the list |
 * | `body` | 16 regular | the title of a settings row |
 * | `control` | 15 regular | what is typed into a field, a chip's label |
 * | `value` | 14 regular | what a settings row currently says |
 * | `footnote` | 13 regular | a secondary line, the text inside an ⓘ |
 * | `caption` | 12 regular | a path, a note under a card, a named absence |
 * | `overline` | 11 semibold, +0.6 tracking, uppercase | a section caption |
 *
 * Nine roles is more than a scale needs and fewer than a screen invents on its own. The brief's
 * rule is that hierarchy comes from **weight and colour** rather than from a size for every
 * thought, which only holds if there is a fixed set of sizes to be disciplined about.
 *
 * ## `sp`, and the one place that is wrong
 *
 * Everything here is `sp`, so a person who has turned their system font up gets bigger text — the
 * platform's own promise, and one iOS keeps too through Dynamic Type. The exception is the terminal
 * itself, which is sized in raw pixels: the character cell decides how many columns the desktop is
 * told about, and scaling it with the system setting would mean two phones side by side reporting
 * different terminal widths for the same screen. That is `TEXT_SIZE_PX` in `TerminalScreen`, and
 * pinch-to-zoom is how it is changed.
 *
 * ## Tracking
 *
 * Negative on the display sizes and positive on the caption, which is the same curve `--t-*-ls`
 * describes and the same one every system typeface is drawn for: large text needs to be pulled
 * together and small uppercase text needs to be let out.
 */
object DeckType {
    /** Trim the extra leading the platform adds above the first line and below the last. Without
     *  it a two-line row is taller than the sum of its parts and no padding value makes a card and
     *  its neighbour agree. */
    private val trim = LineHeightStyle(
        alignment = LineHeightStyle.Alignment.Center,
        trim = LineHeightStyle.Trim.None,
    )

    val largeTitle = TextStyle(
        fontSize = 28.sp,
        lineHeight = 34.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = (-0.022).em,
        lineHeightStyle = trim,
    )

    /**
     * A question that owns a sheet — *Push to this repository?* Between [largeTitle] and [title],
     * and it exists because that one string is the whole content of the screen it is on: a person
     * is being asked to approve a `git push` from a machine, and the question has to be readable
     * at arm's length without being the 28sp a screen title is.
     */
    val question = TextStyle(
        fontSize = 22.sp,
        lineHeight = 28.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = (-0.019).em,
        lineHeightStyle = trim,
    )

    val title = TextStyle(
        fontSize = 20.sp,
        lineHeight = 25.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = (-0.014).em,
        lineHeightStyle = trim,
    )

    val rowTitle = TextStyle(
        fontSize = 17.sp,
        lineHeight = 22.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = (-0.01).em,
        lineHeightStyle = trim,
    )

    val body = TextStyle(
        fontSize = 16.sp,
        lineHeight = 21.sp,
        fontWeight = FontWeight.Normal,
        lineHeightStyle = trim,
    )

    val control = TextStyle(
        fontSize = 15.sp,
        lineHeight = 20.sp,
        fontWeight = FontWeight.Normal,
        lineHeightStyle = trim,
    )

    val value = TextStyle(
        fontSize = 14.sp,
        lineHeight = 19.sp,
        fontWeight = FontWeight.Normal,
        lineHeightStyle = trim,
    )

    val footnote = TextStyle(
        fontSize = 13.sp,
        lineHeight = 18.sp,
        fontWeight = FontWeight.Normal,
        lineHeightStyle = trim,
    )

    val caption = TextStyle(
        fontSize = 12.sp,
        lineHeight = 17.sp,
        fontWeight = FontWeight.Normal,
        lineHeightStyle = trim,
    )

    /**
     * A section caption. Uppercased at the call site rather than here, because `textCase` has no
     * Compose equivalent and a style that silently rewrote its own text would be a style that
     * shouted somebody's machine name at them.
     */
    val overline = TextStyle(
        fontSize = 11.sp,
        lineHeight = 14.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.055.em,
        lineHeightStyle = trim,
    )

    /**
     * Mono, and only where the characters are meant to be counted: a path, a fingerprint, a version,
     * a server address, the terminal. Mono is this app's promise that the string is exact — setting
     * an ordinary sentence in it makes the sentence read as one more directory.
     */
    val mono = caption.copy(fontFamily = FontFamily.Monospace)
    val monoFootnote = footnote.copy(fontFamily = FontFamily.Monospace)
    val monoValue = value.copy(fontFamily = FontFamily.Monospace)
    /** A repository name, a host id read at a glance: mono at the size a row title is set. */
    val monoBody = body.copy(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium)
    val monoSmall = TextStyle(
        fontSize = 11.sp,
        lineHeight = 15.sp,
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Medium,
        lineHeightStyle = trim,
    )
}

/**
 * The same ladder, seen from Material.
 *
 * Every screen in this app already asks for `MaterialTheme.typography.*`, so the ladder has to be
 * reachable through those names or half the app would keep the framework's defaults — a 16sp
 * `bodyLarge` at `Normal` next to a 17sp `rowTitle` at `SemiBold` is the sort of near-miss that
 * reads as sloppiness without ever looking like a bug. The mapping is by *role*, not by name
 * length: `titleLarge` is what a navigation bar sets, so it is [DeckType.title]; `titleMedium` is
 * what a list row's name sets, so it is [DeckType.rowTitle].
 */
internal val DeckTypography = Typography(
    displayLarge = DeckType.largeTitle,
    displayMedium = DeckType.largeTitle,
    displaySmall = DeckType.title,
    headlineLarge = DeckType.largeTitle,
    headlineMedium = DeckType.title,
    headlineSmall = DeckType.title,
    titleLarge = DeckType.title,
    titleMedium = DeckType.rowTitle,
    titleSmall = DeckType.body,
    bodyLarge = DeckType.body,
    bodyMedium = DeckType.value,
    bodySmall = DeckType.footnote,
    labelLarge = DeckType.control,
    labelMedium = DeckType.value,
    labelSmall = DeckType.caption,
)
