package dev.terminaldeck.android.ui.kit

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Hit
import dev.terminaldeck.android.ui.theme.Motion
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * The ⓘ, and the only place an explanation is allowed to live.
 *
 * Asad, twice in one recording, and the instruction most often broken while fixing something else:
 *
 *   > *"here you have a very long description… Remove this full shit. I don't want any kind of long
 *   > descriptions anywhere. Just if somewhere it's very required, give the i icon like other ones,
 *   > information icon in the settings, same way."*
 *
 *   > *"don't put any single statement in anywhere… We want simplicity. Let the smart people use
 *   > it. Smart people knows how it works."*
 *
 * So a screen carries controls and figures, and anything that would have been a paragraph under one
 * of them goes behind this. Nothing is lost — it is reachable by tap and by TalkBack, which reads
 * the text as the control's own description — and nothing is on screen that somebody who already
 * knows how the thing works has to read past.
 *
 * ## A popup, not a disclosure
 *
 * A disclosure pushes everything below it down the page, so reading the second explanation moves
 * the third somewhere else. The desktop's Settings window made the same call and iOS uses a
 * `.popover` for the same reason. This is the same shape, positioned by [clampedTo] so a 280dp
 * bubble hanging off a control near the right edge of a small phone lands on screen rather than
 * half off it — which is what an unclamped anchor-aligned popup does, and what makes people believe
 * the control is broken.
 */
@Composable
fun InfoDot(
    about: String,
    text: String,
    modifier: Modifier = Modifier,
) {
    var showing by remember { mutableStateOf(false) }
    val colors = DeckTheme.colors

    Box(modifier = modifier) {
        IconButton(
            onClick = { showing = true },
            modifier = Modifier.size(28.dp).semantics { contentDescription = "About $about. $text" },
        ) {
            Icon(
                imageVector = Icons.Outlined.Info,
                contentDescription = null,
                tint = colors.faint,
                modifier = Modifier.size(16.dp),
            )
        }

        if (showing) {
            Popup(
                popupPositionProvider = clampedTo(margin = with(LocalDensity.current) { Space.x3.roundToPx() }),
                onDismissRequest = { showing = false },
                properties = PopupProperties(focusable = true),
            ) {
                Box(
                    modifier = Modifier
                        .width(280.dp)
                        .clip(Radius.large)
                        .background(colors.surfaceHigh)
                        .border(1.dp, colors.hairline, Radius.large)
                        .padding(Space.x3),
                ) {
                    Text(text = text, style = DeckType.footnote, color = colors.primary)
                }
            }
        }
    }
}

/**
 * Below the anchor when there is room, above it when there is not, and never off either edge.
 *
 * Compose's built-in alignment-based popup positioning aligns to the anchor and lets the result
 * overflow. This clamps horizontally into the window and flips vertically, which between them cover
 * both ways an ⓘ near a screen edge goes wrong.
 */
private fun clampedTo(margin: Int): PopupPositionProvider = object : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset {
        val x = (anchorBounds.center.x - popupContentSize.width / 2)
            .coerceIn(margin, (windowSize.width - popupContentSize.width - margin).coerceAtLeast(margin))
        val below = anchorBounds.bottom + margin
        val y = if (below + popupContentSize.height <= windowSize.height - margin) {
            below
        } else {
            (anchorBounds.top - popupContentSize.height - margin).coerceAtLeast(margin)
        }
        return IntOffset(x, y)
    }
}

/**
 * The label over a field: a short uppercase name, and the ⓘ that carries everything else.
 *
 * The pairing is the point. Without somewhere for the explanation to go, a label grows into a
 * sentence and then into a paragraph, and this app has been through that once already.
 */
@Composable
fun FieldLabel(
    title: String,
    modifier: Modifier = Modifier,
    about: String? = null,
    note: String? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth().padding(bottom = Space.x2),
    ) {
        Text(
            text = title.uppercase(),
            style = DeckType.overline,
            color = DeckTheme.colors.faint,
        )
        if (about != null && note != null) {
            Spacer(Modifier.width(Space.half))
            InfoDot(about = about, text = note)
        }
        Spacer(Modifier.weight(1f))
        trailing?.invoke()
    }
}

/**
 * A segmented control: one track, one thumb, and as many answers as there are segments.
 *
 * ## Why this shape and not `SegmentedButton`
 *
 * Material's own is a row of outlined pills that each grow a check mark when chosen. It answers
 * *which of these is on* by drawing a tick, and this control's job is to answer *which one of these
 * is it* — which the thumb does by being somewhere, at a glance, without reading. That is the same
 * reason the desktop and iOS both use a track-and-thumb here, and a screen where the phone shows
 * ticks and the Mac shows a thumb is a screen that reads as two products.
 *
 * ## The thumb moves, and it moves in 200ms
 *
 * Not decoration: the animation is what tells you the control is one thing with a state rather than
 * three buttons of which one happens to be filled. `--dur` is the app's own middle duration, and
 * the phone's *remove animations* setting turns it off through the platform's animation scale
 * without this needing to know.
 *
 * The whole control takes its own line rather than sitting beside a title. Rendered the other way
 * at 360dp — the narrowest phone this app supports — three segments had 190dp between them and
 * "System" came out as "Syste".
 */
@Composable
fun DeckSegmented(
    options: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    if (options.isEmpty()) return
    val colors = DeckTheme.colors
    val trackHeight = 34.dp
    val inset = 2.dp

    BoxWithConstraints(
        modifier = modifier
            .fillMaxWidth()
            .height(trackHeight)
            .clip(RoundedCornerShape(9.dp))
            .background(colors.surfaceHigh),
    ) {
        val segment = (maxWidth - inset * 2) / options.size
        val offset by animateDpAsState(
            targetValue = inset + segment * selectedIndex.coerceIn(0, options.lastIndex),
            animationSpec = tween(durationMillis = Motion.NORMAL),
            label = "segmentThumb",
        )

        Box(
            modifier = Modifier
                .offset(x = offset, y = inset)
                .width(segment)
                .height(trackHeight - inset * 2)
                .clip(RoundedCornerShape(7.dp))
                .background(if (enabled) colors.background else colors.pressed)
                .border(1.dp, colors.hairline, RoundedCornerShape(7.dp))
        )

        Row(modifier = Modifier.fillMaxWidth().height(trackHeight)) {
            options.forEachIndexed { index, label ->
                val on = index == selectedIndex
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .weight(1f)
                        .height(trackHeight)
                        .then(
                            if (enabled) Modifier.clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                // No ripple: the thumb moving *is* the feedback, and a ripple on top
                                // of a moving thumb reads as two things happening.
                                indication = null,
                            ) { onSelect(index) } else Modifier
                        ),
                ) {
                    Text(
                        text = label,
                        style = DeckType.footnote.copy(
                            fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                        ),
                        color = when {
                            !enabled -> colors.faint
                            on -> colors.primary
                            else -> colors.secondary
                        },
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = Space.x1),
                    )
                }
            }
        }
    }
}

/**
 * A capsule that is one of several answers to one question — the provider a machine starts sessions
 * with, and anything else that is a short list of ids rather than a boolean.
 *
 * Filled with the accent when it is the answer and with the raised surface when it is not. Not
 * outlined: an outlined chip beside a filled one reads as *enabled* beside *disabled* rather than
 * as two choices, which is exactly backwards for a control where every option is available.
 *
 * The chosen chip is inert on purpose — pressing the answer that is already true would send an
 * apply the machine has to refuse. So is every chip while an apply is in flight.
 */
@Composable
fun DeckChip(
    label: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit = {},
) {
    val colors = DeckTheme.colors
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Text(
        text = label,
        style = DeckType.value.copy(
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        ),
        color = if (selected) colors.onAccent else colors.primary,
        maxLines = 1,
        modifier = modifier
            .clip(CircleShape)
            .background(
                when {
                    selected && pressed -> colors.accentPressed
                    selected -> colors.accent
                    pressed -> colors.hairlineStrong
                    else -> colors.surfaceHigh
                }
            )
            .clickable(
                interactionSource = interaction,
                indication = null,
                enabled = enabled,
                onClick = onClick,
            )
            .padding(horizontal = Space.x3, vertical = 7.dp),
    )
}

/**
 * A small mono tag on a row — the provider a session is running, a device that is this phone.
 *
 * Mono and uppercase-preserving: `claude` and `codex` are program names, and a tag that
 * title-cased them would be renaming somebody's tool. Filled with the raised surface, which is what
 * keeps it legible on a card *and* on a selected row — an outlined version disappeared into exactly
 * the selected row whose tag mattered most, which is how the outline came to be there and why it is
 * gone again.
 */
@Composable
fun DeckTag(text: String, modifier: Modifier = Modifier) {
    val colors = DeckTheme.colors
    Text(
        text = text,
        style = DeckType.monoSmall,
        color = colors.secondary,
        maxLines = 1,
        modifier = modifier
            .clip(RoundedCornerShape(5.dp))
            .background(colors.surfaceHigh)
            .padding(horizontal = 7.dp, vertical = 2.dp),
    )
}

/**
 * The dot that says what a session is doing.
 *
 * A dot rather than a word because the row already carries the word, and colour rather than shape
 * because the vocabulary is the desktop's and an unrecognised status has to land somewhere neutral
 * rather than be drawn as a guess. See `DeckColors.status`.
 */
@Composable
fun DeckStatusDot(status: String, modifier: Modifier = Modifier, size: Dp = 9.dp) {
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .background(DeckTheme.colors.status(status))
    )
}

/* ---------------------------------------------------------------------- fields -- */

/**
 * A text field with this app's chrome on it.
 *
 * `OutlinedTextField` is 56dp tall with a floating label that occupies a second line of space, a
 * 1dp outline that thickens to 2dp on focus, and a notch cut in that outline for the label to sit
 * in. None of that exists on the other two clients: a field there is a filled rounded rectangle
 * with a hairline around it and its name in small caps *above* it, which is [FieldLabel]. This is
 * that, built on `BasicTextField` so there is nothing to override.
 *
 * The focus ring is the accent at full strength rather than a thicker hairline, because a hairline
 * that gets thicker is a change nobody sees on a phone in daylight.
 */
@Composable
fun DeckTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    enabled: Boolean = true,
    mono: Boolean = false,
    singleLine: Boolean = true,
    minLines: Int = 1,
    maxLines: Int = if (singleLine) 1 else 6,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    /** What the keyboard's action key does — the address bars pass an `onGo` here so Enter submits,
     *  which is how a browser has always worked and why they carry no Go button of their own. */
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    /**
     * Override the face for the one field that is not ordinary text.
     *
     * There is exactly one: the six-digit pairing code, which is set large, monospaced and let out
     * because it is being copied off another screen a character at a time. A parameter rather than
     * a second component, because everything else about it — the fill, the radius, the focus ring,
     * the caret colour — is the same field.
     */
    textStyle: TextStyle? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val colors = DeckTheme.colors
    val interaction = remember { MutableInteractionSource() }
    var focused by remember { mutableStateOf(false) }
    val style = (textStyle ?: if (mono) DeckType.monoValue else DeckType.control)
        .copy(color = colors.primary)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = Hit.min)
            .clip(Radius.fieldShape)
            .background(colors.surface)
            .border(
                width = 1.dp,
                color = if (focused) colors.accent else colors.hairline,
                shape = Radius.fieldShape,
            )
            .padding(horizontal = Space.x3, vertical = Space.x2),
    ) {
        Box(modifier = Modifier.weight(1f)) {
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                enabled = enabled,
                singleLine = singleLine,
                minLines = minLines,
                maxLines = maxLines,
                textStyle = style,
                cursorBrush = SolidColor(colors.accent),
                keyboardOptions = keyboardOptions,
                keyboardActions = keyboardActions,
                visualTransformation = visualTransformation,
                interactionSource = interaction,
                modifier = Modifier
                    .fillMaxWidth()
                    .onFocusChangedCompat { focused = it },
            )
            if (value.isEmpty() && placeholder.isNotEmpty()) {
                Text(
                    text = placeholder,
                    style = style.copy(color = colors.faint),
                    maxLines = if (singleLine) 1 else 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (trailing != null) {
            Spacer(Modifier.width(Space.x1))
            trailing()
        }
    }
}

/**
 * The masked-secret row: a password or a private key, and the one control that reveals it.
 *
 * Masked by default and revealed only while somebody is holding the toggle open, because the case
 * this is drawn for is typing a server password on a bus. The reveal exists at all because the
 * other case is *pasting* a forty-line private key and needing to see that it arrived whole — a
 * secret field with no way to check what is in it is a field people paste into twice.
 *
 * **Nothing here stops the platform offering to save it.** That is stated rather than papered over:
 * measured on the other client, four different shapes of secure field all raised the system's *save
 * this password* offer, including the documented opt-out. The honest response is not a comment
 * claiming a fix — it is the screen's closing line saying what *this app* keeps, which is the
 * credential the server mints in exchange, not the password.
 */
@Composable
fun DeckSecretField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    enabled: Boolean = true,
    mono: Boolean = false,
    singleLine: Boolean = true,
    minLines: Int = 1,
) {
    var revealed by remember { mutableStateOf(false) }
    val colors = DeckTheme.colors
    DeckTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        placeholder = placeholder,
        enabled = enabled,
        mono = mono,
        singleLine = singleLine,
        minLines = minLines,
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
        visualTransformation = if (revealed) VisualTransformation.None else PasswordVisualTransformation(),
        trailing = {
            IconButton(onClick = { revealed = !revealed }, modifier = Modifier.size(32.dp)) {
                Icon(
                    imageVector = if (revealed) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                    contentDescription = if (revealed) "Hide" else "Show",
                    tint = colors.faint,
                    modifier = Modifier.size(18.dp),
                )
            }
        },
    )
}

/* --------------------------------------------------------------------- buttons -- */

/**
 * The one action on a screen.
 *
 * Filled with the accent, and there is exactly one of these per screen: *the* accent means "this is
 * the action", and a screen where four things are blue has no accent at all.
 */
@Composable
fun DeckPrimaryButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    leading: (@Composable () -> Unit)? = null,
) {
    val colors = DeckTheme.colors
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Row(
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 50.dp)
            .clip(Radius.large)
            .background(
                when {
                    !enabled -> colors.surfaceHigh
                    pressed -> colors.accentPressed
                    else -> colors.accent
                }
            )
            .clickable(interactionSource = interaction, indication = null, enabled = enabled, onClick = onClick)
            .padding(horizontal = Space.x4),
    ) {
        if (leading != null) {
            leading()
            Spacer(Modifier.width(Space.x2))
        }
        Text(
            text = label,
            style = DeckType.control.copy(fontWeight = FontWeight.SemiBold),
            color = if (enabled) colors.onAccent else colors.faint,
        )
    }
}

/** The second thing on a screen — Cancel, Back, Paste a token instead. A surface, not an accent. */
@Composable
fun DeckQuietButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val colors = DeckTheme.colors
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = Hit.min)
            .clip(Radius.large)
            .background(if (pressed) colors.hairlineStrong else colors.surfaceHigh)
            .clickable(interactionSource = interaction, indication = null, enabled = enabled, onClick = onClick)
            .padding(horizontal = Space.x4),
    ) {
        Text(
            text = label,
            style = DeckType.control,
            color = if (enabled) colors.primary else colors.faint,
        )
    }
}

/**
 * A verb that does not come back — Remove, Close session, Forget.
 *
 * Text on the canvas rather than a red fill, and the fill is kept for the confirm inside a dialog.
 * A screen with a red rectangle on it reads as an alarm; the thing being reported here is that one
 * of several rows can be removed.
 */
@Composable
fun DeckDestructiveText(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val colors = DeckTheme.colors
    Text(
        text = label,
        style = DeckType.value.copy(fontWeight = FontWeight.Medium),
        color = if (enabled) colors.critical else colors.faint,
        modifier = modifier
            .clip(Radius.medium)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = Space.x3, vertical = Space.x2),
    )
}

/**
 * `Modifier.onFocusChanged`, imported here so the field above reads in one piece.
 *
 * A named extension rather than the import at the top, because `onFocusChanged` on a `Modifier` in
 * a file that also defines a `focused` local is the sort of line that gets accidentally deleted in
 * a merge and produces a field whose ring never lights.
 */
private fun Modifier.onFocusChangedCompat(onChanged: (Boolean) -> Unit): Modifier =
    this.onFocusChanged { onChanged(it.isFocused) }

/** A text style that is the app's own default ink, for the rare `BasicText` outside a component. */
@Composable
fun deckTextStyle(): TextStyle = LocalTextStyle.current.copy(color = DeckTheme.colors.primary)

/** The colour a control uses for the wash under a finger when it has no fill of its own. */
@Composable
fun deckPressedTint(): Color = DeckTheme.colors.pressed
