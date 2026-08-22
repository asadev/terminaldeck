package dev.terminaldeck.android.ui.kit

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.activity.compose.BackHandler
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Hit
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * The shapes this product's screens are made of.
 *
 * There are four of them and that is on purpose. A grouped card, a caption above it, a row inside
 * it and a sentence below it — every settings-shaped screen on the desktop, on the phone and in the
 * browser is those four in some order, and the reason to give them names is that the alternative is
 * each screen re-deciding a card's radius and a caption's tracking and landing two points apart.
 *
 * The rules they encode, in the design brief's own order:
 *
 *  1. **Separate with space.** Then with a tint. Only then with a line. A card is a fill with a
 *     radius, not an outline — which is the single biggest visual difference between this and the
 *     `1.dp` border on `colorScheme.outline` these screens were drawn with.
 *  2. **One hairline, and only where space cannot go.** Two rows inside one card have no gap
 *     between them, so they get [DeckDivider] and nothing else in the app does.
 *  3. **No paragraph next to a control.** Anything longer than a line goes behind an [InfoDot];
 *     what stays on screen is the one sentence that names an absence — see [DeckFootnote].
 */

/**
 * A card holding rows.
 *
 * Fill and radius, no border. The border version is what these screens had, and on a dark ground a
 * 9%-alpha outline around a 3%-lighter fill is two nearly-invisible edges doing one job — it reads
 * as a rectangle someone forgot to finish rather than as a raised surface.
 */
@Composable
fun DeckGroup(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(Radius.groupShape)
            .background(DeckTheme.colors.surface),
        content = content,
    )
}

/**
 * The one line in the app.
 *
 * Half a point tall — a hairline is meant to read as an edge rather than as a rule — and indented
 * past the icon column so the rows above and below it read as a stack rather than as two cards. The
 * indent is [Space.x4] + the icon column + its gutter, which is why it is a parameter with a
 * default rather than a literal at each call site.
 */
@Composable
fun DeckDivider(startIndent: Dp = 46.dp) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = startIndent)
            .height(0.5.dp)
            .background(DeckTheme.colors.hairline)
    )
}

/**
 * The caption over a card.
 *
 * Uppercase, 11sp semibold, tracked out, in the quietest ink — and *outside* the card, indented
 * four points from the screen margin. That last detail is the one that makes a screen read as
 * designed rather than as assembled: a caption flush with the card edge reads as a heading inside
 * it, and a caption flush with the screen edge reads as a heading for the whole page.
 *
 * Uppercased here rather than in the style, because Compose has no `textCase` and a style that
 * rewrote its own text would shout somebody's machine name at them the first time one was passed in.
 */
@Composable
fun SectionCaption(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text.uppercase(),
        style = DeckType.overline,
        color = DeckTheme.colors.faint,
        modifier = modifier
            .fillMaxWidth()
            .padding(start = Space.captionIndent, top = Space.x6, bottom = Space.x2),
    )
}

/**
 * The sentence under a card.
 *
 * This is the app's *named absence*: the one form of prose that has earned its place, because it
 * says what a thing genuinely cannot do and who would have to change it, where. *"These belong to
 * the machine, not this phone."* *"There is no notification server, so a phone that has been asleep
 * is caught up the next time it connects rather than woken."* The alternative to a sentence like
 * that is not a cleaner screen; it is somebody waiting two hours for a buzz that was never coming.
 *
 * Everything that is **not** a named absence — an explanation of how a control works, a
 * reassurance, a description of what the screen is — belongs behind an [InfoDot] instead. Asad,
 * twice in one recording: *"I don't want any kind of long descriptions anywhere"*, and *"let the
 * smart people use it. Smart people knows how it works."*
 *
 * Deliberately not the error colour by default. Nothing has gone wrong: somebody made a choice at a
 * keyboard, and this is that choice being reported rather than a fault being raised.
 */
@Composable
fun DeckFootnote(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = DeckTheme.colors.faint,
) {
    Text(
        text = text,
        style = DeckType.caption,
        color = color,
        modifier = modifier
            .fillMaxWidth()
            .padding(start = Space.captionIndent, end = Space.captionIndent, top = Space.x2),
    )
}

/**
 * A row in a card: an icon, a title, what it currently is, and a chevron.
 *
 * **The value is the whole point.** A row that reads only "Alerts" has to be opened to find out
 * that nothing has changed; a row that reads "Alerts · 1 kind" has already answered. Every row of
 * this shape in the app carries one, and a row with nothing true to say passes an empty string
 * rather than inventing a placeholder.
 *
 * The icon column is a fixed 18dp regardless of the glyph, so the titles line up down the card. The
 * chevron is drawn only when there is somewhere to go: a row with no `onClick` is a fact, not a
 * door, and a chevron on it would be an affordance that does nothing.
 */
@Composable
fun DeckRow(
    title: String,
    modifier: Modifier = Modifier,
    /**
     * What the row currently *is* — on the trailing edge, where iOS puts it.
     *
     * Mutually exclusive with [subtitle] in practice: a row answers its question either in three
     * words beside the title or in a sentence under it, and doing both is a row with two answers.
     */
    value: String = "",
    /**
     * A sentence under the title, for a row whose answer does not fit in three words.
     *
     * *"The ones above stay paired and stay connected."* *"Sign in with its address and your login.
     * No desktop needed."* Those are not values, they are the thing that decides whether somebody
     * taps the row — said before the tap rather than discovered afterwards.
     */
    subtitle: String = "",
    icon: ImageVector? = null,
    /** The ink for the title. The accent for a row that *adds* something; the primary ink for a row
     *  that opens something that already exists. */
    titleColor: Color? = null,
    /** Drawn in place of the value — a switch, a chip row, "Working…". */
    trailing: (@Composable () -> Unit)? = null,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = Hit.min)
            .then(
                if (onClick != null && enabled) Modifier.clickable(onClick = onClick) else Modifier
            )
            .padding(horizontal = Space.card, vertical = Space.x3),
    ) {
        if (icon != null) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = colors.secondary,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(Space.x3))
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = DeckType.body,
                color = when {
                    !enabled -> colors.faint
                    titleColor != null -> titleColor
                    else -> colors.primary
                },
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (subtitle.isNotEmpty()) {
                Text(
                    text = subtitle,
                    style = DeckType.caption,
                    color = colors.faint,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Spacer(Modifier.width(Space.x2))
        when {
            trailing != null -> trailing()
            value.isNotEmpty() -> Text(
                text = value,
                style = DeckType.value,
                color = colors.faint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (onClick != null) {
            Spacer(Modifier.width(Space.x1))
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.faint,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

/**
 * The bar at the top of a pushed screen: a back affordance, a title, and what the title is *of*.
 *
 * Not `TopAppBar`. Material's is 64dp tall with a 22sp title and 16dp of leading inset before the
 * navigation icon, and this app's pushed screens each carry a two-line title — the screen's name
 * over the machine it belongs to — which Material's slot renders at a size that pushes the second
 * line into the content. The layout here is iOS's: the name and the machine stacked, the back
 * affordance at the leading edge, and nothing else unless a screen has a verb of its own.
 *
 * The back **arrow** is Android's, not a chevron with the previous screen's name beside it. That is
 * one of the three places this client keeps the platform's convention rather than the reference's,
 * because the arrow is what pairs with the system back gesture that is doing most of the work.
 */
@Composable
fun DeckTopBar(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    onBack: (() -> Unit)? = null,
    actions: (@Composable () -> Unit)? = null,
) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .background(colors.background)
            /*
             * A hand-rolled bar under `enableEdgeToEdge` gets no insets for free.
             *
             * `Scaffold` only insets its `topBar` slot if what is in it consumes the window insets
             * itself, which Material's own `TopAppBar` does and this does not — so without this the
             * title draws *behind the clock*. Photographed on the emulator with "This server"
             * overlapping the status bar, which is exactly the class of thing that is invisible
             * from the code and obvious in a screenshot.
             */
            .statusBarsPadding()
            .heightIn(min = 56.dp)
            .padding(end = Space.x2, top = Space.x1, bottom = Space.x1),
    ) {
        if (onBack != null) {
            IconButton(onClick = onBack) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = colors.primary,
                )
            }
        } else {
            Spacer(Modifier.width(Space.screen))
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = DeckType.title,
                color = colors.primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (!subtitle.isNullOrEmpty()) {
                Text(
                    text = subtitle,
                    style = DeckType.caption,
                    color = colors.faint,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        actions?.invoke()
    }
}

/**
 * What a screen says when it has nothing to list.
 *
 * One sentence, centred, in the quiet ink — and the sentence **names the thing**. "No sessions" does
 * not say whose with two machines paired, and an empty list while the socket is down does not mean
 * the machine is idle; it means nothing is known either way. Both of those are cases this app has
 * had reported, and both are fixed by writing the sentence at the call site rather than by having a
 * component that guesses one.
 */
@Composable
fun DeckEmptyState(text: String, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier.fillMaxSize().padding(horizontal = Space.x8),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = DeckType.footnote,
            color = DeckTheme.colors.faint,
        )
    }
}

/*
 * There is no `DeckSheet` here, and that is deliberate.
 *
 * A sheet component was written for this kit and deleted before it shipped, because all three
 * sheets in the app already have their own — each drawn inside its own composition rather than as a
 * `ModalBottomSheet`, for a reason that is written on `HostSwitcherSheet` and is worth reading: a
 * `ModalBottomSheet` gets its own window, and a second window takes its system-bar appearance from
 * the *system* light/dark setting rather than from this app's theme.
 *
 * Unifying them is a real refactor with a real risk of changing three behaviours at once, and a
 * component nothing calls is not a design system, it is a file. When somebody unifies them,
 * `HostSwitcher.kt` is the reference.
 */
