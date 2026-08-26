package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.ui.kit.DeckSheetChrome
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * Everything that is not on the fixed bar, in a sheet the *more keys* button opens.
 *
 * iOS makes this the terminal's `inputView` and swaps it for the keyboard so the terminal above does
 * not move by a point — a trick a Compose screen has no equivalent of. A bottom sheet is the shape
 * Android reaches for the same intent, and the one this app already uses for a session's other
 * controls; it is named `KeyGridSheet` for that reason. It stays up while keys are pressed — you tap
 * `^C` and then a letter without it closing under you — and a swipe or the scrim puts it away.
 *
 * The groups, their order and every byte come from [KeyGrid], which is transcribed from
 * `ios/TerminalDeck/Terminal/KeyPlan.swift`. Edit and signals open at the top because they are what a
 * thumb reaches for in a hurry; the function keys are last. Six caps to a row, matching iOS: past
 * six, a cap falls under the 44dp a thumb needs once the gaps are paid for. A short row is padded
 * with empty space rather than stretched, so `copy` and `paste` are the same size as the `^C` under
 * them — the grid's whole readability is every cap being one size.
 *
 * ## The one press this sheet does not resolve itself
 *
 * A cap is handed back to the caller through [onKey] rather than turned into bytes here, because the
 * screen owns the meaning of a press: `copy` reads the terminal's selection, `paste` reaches the
 * clipboard, and `alt` arms a modifier that folds into the *next* thing typed on the soft keyboard —
 * none of which this sheet can see. The armed alt is drawn from [metaArmed] so its state shows on the
 * cap the same way the bar's Ctrl does.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun KeyGridSheet(
    metaArmed: Boolean,
    onKey: (GridKey) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = DeckTheme.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.background,
        shape = Radius.sheetShape,
        dragHandle = null,
    ) {
        DeckSheetChrome()
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .padding(top = Space.x2, bottom = Space.x8),
            verticalArrangement = Arrangement.spacedBy(Space.x4),
        ) {
            for (group in KeyGrid.groups) {
                KeyGridGroup(group = group, metaArmed = metaArmed, onKey = onKey)
            }
        }
    }
}

@Composable
private fun KeyGridGroup(
    group: GridGroup,
    metaArmed: Boolean,
    onKey: (GridKey) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Space.x2)) {
        Text(
            // Uppercased here rather than in the data, because the overline role is an uppercase one
            // and the byte tables read better in their natural case.
            text = group.title.uppercase(),
            style = DeckType.overline,
            color = DeckTheme.colors.keyLabelFaint,
        )
        // Rows of six. `chunked` pads nothing, so the last row is short and the caps below fill the
        // gap with empty weight — the same-size rule the header note explains.
        for (rowKeys in group.keys.chunked(COLUMNS)) {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.x15), modifier = Modifier.fillMaxWidth()) {
                for (key in rowKeys) {
                    KeyGridCap(
                        key = key,
                        armed = metaArmed && key.action == GridAction.Mod(GridModifier.Meta),
                        onKey = onKey,
                        modifier = Modifier.weight(1f),
                    )
                }
                // Pad a short row so its caps do not stretch to double width.
                repeat(COLUMNS - rowKeys.size) {
                    Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun KeyGridCap(
    key: GridKey,
    armed: Boolean,
    onKey: (GridKey) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = DeckTheme.colors
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(44.dp)
            .clip(Radius.medium)
            .background(
                when {
                    armed -> colors.accent
                    pressed -> colors.keyPressed
                    else -> colors.key
                }
            )
            .clickable(interactionSource = interaction, indication = null) { onKey(key) }
            .padding(horizontal = Space.x1),
    ) {
        Text(
            text = key.label,
            style = DeckType.control,
            color = if (armed) colors.onAccent else colors.keyLabel,
            textAlign = TextAlign.Center,
            maxLines = 1,
        )
    }
}

/** Six across, the number iOS settled on for the 44dp target once the gaps are paid for. */
private const val COLUMNS = 6
