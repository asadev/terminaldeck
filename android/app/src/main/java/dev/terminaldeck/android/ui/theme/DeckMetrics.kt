package dev.terminaldeck.android.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The spacing rhythm, the radii and the control heights — `src/renderer/styles/tokens.css`'s
 * `--sp-*`, `--radius-*` and `--control-h*`, in `dp`.
 *
 * An 8-point rhythm with 4-point half-steps, which is Apple's and which the desktop already keeps.
 * The point of naming them is not brevity — `16.dp` is shorter than `Space.x4` — it is that a
 * screen built out of a scale cannot drift a control two points off its neighbour, which is
 * precisely what a screen built out of literals does over a year.
 */
object Space {
    val half: Dp = 2.dp     // --sp-05
    val x1: Dp = 4.dp       // --sp-1
    val x15: Dp = 6.dp      // --sp-15
    val x2: Dp = 8.dp       // --sp-2
    val x3: Dp = 12.dp      // --sp-3
    val x4: Dp = 16.dp      // --sp-4
    val x5: Dp = 20.dp      // --sp-5
    val x6: Dp = 24.dp      // --sp-6
    val x8: Dp = 32.dp      // --sp-8
    val x10: Dp = 40.dp     // --sp-10
    val x12: Dp = 48.dp     // --sp-12
    val x16: Dp = 64.dp     // --sp-16

    /**
     * The margin a screen's content keeps from the edge of the phone, and the inset a card's
     * content keeps from the edge of the card. Both 16 — which is what makes a caption sitting
     * outside a card line up with nothing and look deliberate rather than nearly aligned.
     */
    val screen: Dp = x4
    val card: Dp = x4

    /**
     * How far a caption sits in from the screen margin. Four points, so an uppercase caption reads
     * as belonging to the card below it without pretending to be inside it — the iOS grouped-list
     * relationship, which is the shape both other clients use.
     */
    val captionIndent: Dp = x1
}

/** `--radius-*`. */
object Radius {
    val sm: Dp = 6.dp
    val md: Dp = 8.dp
    val lg: Dp = 12.dp
    val xl: Dp = 16.dp

    /** A card holding rows. Fourteen rather than twelve, matching `SettingsGroup` on iOS. */
    val group: Dp = 14.dp

    /** A field, a chip's container, a sheet's top corners. */
    val field: Dp = 10.dp
    val sheet: Dp = 20.dp

    val small = RoundedCornerShape(sm)
    val medium = RoundedCornerShape(md)
    val large = RoundedCornerShape(lg)
    val groupShape = RoundedCornerShape(group)
    val fieldShape = RoundedCornerShape(field)
    val sheetShape = RoundedCornerShape(topStart = sheet, topEnd = sheet)
}

/**
 * The two numbers a finger cares about.
 *
 * 44 is Apple's minimum target and 48 is Android's; the larger of the two is used for both, because
 * a control that is comfortable on one platform and marginal on the other is a control that gets
 * reported once, on whichever it is worse.
 */
object Hit {
    val min: Dp = 48.dp

    /** A row in a card. Tall enough for two lines of value text without growing. */
    val row: Dp = 52.dp
}

/** How long a thing takes: `--dur-fast` / `--dur` / `--dur-slow`, in milliseconds. */
object Motion {
    const val FAST = 120
    const val NORMAL = 200
    const val SLOW = 320
}
