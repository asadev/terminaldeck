package dev.terminaldeck.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.SessionControlsView
import dev.terminaldeck.android.protocol.ControlCatalog
import dev.terminaldeck.android.protocol.ControlName
import dev.terminaldeck.android.protocol.ControlOption
import dev.terminaldeck.android.protocol.ControlsReadingWire
import dev.terminaldeck.android.protocol.SessionControls

/**
 * The session's control cluster on a phone — model, effort, fast mode, permission — as a sheet
 * raised from the terminal.
 *
 * The view half of [dev.terminaldeck.android.SessionControlsController], and the same drawing iOS
 * keeps in `SessionControlsView.swift`. A chip shows a control's current value; tapping it opens the
 * rows underneath. A blocked chip **opens onto its rows too, with the reason above them** — the rule
 * used to be the opposite (open onto the far end's sentence, never a dead menu) until Asad opened
 * Model and got a paragraph where the models should have been: *"they are also not control they are
 * just descriptions which i dont want always."* Prose instead of a menu is a second way of being a
 * dead menu, so the rows are always drawn — unpressable when blocked, because the tick is worth
 * seeing even in a moment it cannot change — and the reason is one short line above them. The ticked
 * row is whatever the far end re-read after the change settled, so a refused apply reverts by
 * construction; a failure keeps its sentence, a confirmation clears itself.
 *
 * Fast mode lives at the end of the model sheet — where the desktop keeps it — because the CLI
 * couples them: switching model turns fast mode off.
 *
 * ## Why this is not a `ModalBottomSheet`
 *
 * The same reason [HostSwitcherSheet] is not: `ModalBottomSheet` puts itself in its own window, and
 * that window takes its system-bar appearance from the *system* light/dark setting rather than from
 * this app's theme, so on a phone set to light it paints a white navigation bar under an all-black
 * terminal. There is no second window here — the scrim and the panel are ordinary composables above
 * the screen that opened them, and the back gesture closes the panel rather than the session.
 */
@Composable
fun SessionControlsSheet(
    view: SessionControlsView,
    onApply: (ControlName, String) -> Unit,
    onDismissNotice: () -> Unit,
    onDismiss: () -> Unit,
) {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }
    /** Which chip's rows are open. Fast is never here — its switch lives in the model sheet. */
    var open by remember { mutableStateOf<ControlName?>(null) }

    BackHandler(onBack = onDismiss)

    Box(modifier = Modifier.fillMaxSize()) {
        AnimatedVisibility(visible = shown, enter = fadeIn(), exit = fadeOut()) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(SHEET_SCRIM)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onDismiss,
                    )
            )
        }

        AnimatedVisibility(
            visible = shown,
            enter = slideInVertically(initialOffsetY = { it }),
            exit = slideOutVertically(targetOffsetY = { it }),
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                    .background(MaterialTheme.colorScheme.background)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = {},
                    )
                    .navigationBarsPadding(),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 14.dp),
                ) {
                    Text(
                        text = "Controls",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onBackground,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = onDismiss) { Text("Done") }
                }

                val reading = view.reading
                if (reading == null || !SessionControls.clusterShown(reading)) {
                    // The session went quiet, exited, or is a plain shell — nothing honest to show,
                    // so the sheet says so rather than drawing empty chips.
                    Text(
                        text = "This session has no agent to set a model, effort or permission on.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(20.dp),
                    )
                } else {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier
                            .verticalScroll(rememberScrollState())
                            .padding(16.dp),
                    ) {
                        for (control in listOf(ControlName.Model, ControlName.Effort, ControlName.Permission)) {
                            ControlChip(
                                control = control,
                                reading = reading,
                                busy = view.busy,
                                isOpen = open == control,
                                onToggle = { open = if (open == control) null else control },
                                onApply = onApply,
                            )
                        }
                        view.notice?.let { notice ->
                            Row(
                                verticalAlignment = Alignment.Top,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(MaterialTheme.colorScheme.surface)
                                    .padding(start = 14.dp, top = 12.dp, end = 4.dp, bottom = 12.dp),
                            ) {
                                Text(
                                    text = notice.text,
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = if (notice.ok) {
                                        MaterialTheme.colorScheme.onSurfaceVariant
                                    } else {
                                        MaterialTheme.colorScheme.error
                                    },
                                    modifier = Modifier.weight(1f),
                                )
                                IconButton(onClick = onDismissNotice, modifier = Modifier.size(32.dp)) {
                                    Icon(
                                        Icons.Filled.Close,
                                        contentDescription = "Dismiss",
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.size(16.dp),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * One chip and, when it is open, its rows.
 *
 * A chip mid-change is genuinely disabled — there is a queue behind it, not a sentence to open onto
 * — unless it is the one working, which keeps its own "Working…" reading.
 */
@Composable
private fun ControlChip(
    control: ControlName,
    reading: ControlsReadingWire,
    busy: ControlName?,
    isOpen: Boolean,
    onToggle: () -> Unit,
    onApply: (ControlName, String) -> Unit,
) {
    val blocked = SessionControls.blocked(control, reading)
    // Fast mode's work shows on the model chip, because its switch lives in the model sheet.
    val working = busy == control || (control == ControlName.Model && busy == ControlName.Fast)
    val locked = busy != null && !working

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 52.dp)
                .clickable(enabled = !locked, onClick = onToggle)
                .padding(horizontal = 14.dp, vertical = 12.dp),
        ) {
            Text(
                text = ControlCatalog.name(control),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.width(10.dp))
            Text(
                text = if (working) "Working…" else SessionControls.chipText(control, reading),
                style = MaterialTheme.typography.titleMedium,
                // A blocked chip reads quiet rather than absent: it still opens, onto the reason.
                color = if (blocked == null) {
                    MaterialTheme.colorScheme.onSurface
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Spacer(Modifier.weight(1f))
            Icon(
                if (isOpen) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
        }

        if (isOpen) {
            HorizontalDivider(color = MaterialTheme.colorScheme.outline)
            // The reason above the rows, never in their place. iOS swapped this round after Asad
            // opened Model and got a paragraph where the list of models should have been: *"they are
            // also not control they are just descriptions which i dont want always."* Prose instead
            // of a menu is not the cure for a dead menu, it is a second way of being one. So the rows
            // are drawn whether or not the control is blocked — the ticked row is worth seeing even
            // in a moment it cannot be changed — and the one short line rides above them.
            if (blocked != null) ReasonLine(blocked)
            for (option in ControlCatalog.rows(control)) {
                option.group?.let { Caption(it) }
                OptionRow(
                    option = option,
                    current = SessionControls.chosen(reading.reading(control), option),
                    // Drawn but not pressable when blocked — a press would only be answered with a
                    // refusal, and that is the dead click this app is repeatedly audited for.
                    enabled = busy == null && blocked == null,
                    usable = blocked == null,
                    onClick = { onApply(control, option.id) },
                )
            }
            if (control == ControlName.Model) {
                FastSection(reading = reading, busy = busy, alreadySaid = blocked, onApply = onApply)
            }
        }
    }
}

@Composable
private fun OptionRow(
    option: ControlOption,
    current: Boolean,
    enabled: Boolean,
    // Draws the row quiet and refuses the press when the control is blocked — the row is still worth
    // reading, it is where the tick is, and a press that would only be refused is a dead click.
    usable: Boolean = true,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Box(modifier = Modifier.size(18.dp), contentAlignment = Alignment.Center) {
            if (current) {
                Icon(
                    Icons.Filled.Check,
                    contentDescription = "In use",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        Spacer(Modifier.width(10.dp))
        Column {
            Text(
                text = option.label,
                style = MaterialTheme.typography.bodyLarge,
                color = if (usable) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            option.hint?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/**
 * Fast mode, at the end of the model sheet.
 *
 * The far end's sentence when barred; a switch when its state has been read; and the two rows under
 * a caption when nothing has said which it is — never a switch drawn at a position nobody
 * established.
 */
@Composable
private fun FastSection(
    reading: ControlsReadingWire,
    busy: ControlName?,
    // The model chip's own reason, passed in for one case: the session's typing gate blocks all four
    // controls at once, so without it a mid-turn model sheet would print the same sentence twice, a
    // few rows apart, about the same session. An account refusal that belongs only to fast mode is
    // never the same string, so it still gets its line.
    alreadySaid: String?,
    onApply: (ControlName, String) -> Unit,
) {
    val fast = reading.fast
    val barred = SessionControls.blocked(ControlName.Fast, reading)
    Caption(ControlCatalog.name(ControlName.Fast))
    // The reason above the control, not in its place — the same swap the chips above made. A block
    // used to replace the whole switch with the far end's sentence; now the switch stays, showing
    // what is in force, and does not accept a press. *"Fast mode requires usage credits"* is worth
    // reading beside a switch that says Off; it is not worth reading instead of one.
    if (barred != null && barred != alreadySaid) ReasonLine(barred)
    when {
        fast.value == "on" || fast.value == "off" -> {
            val on = fast.value == "on"
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .clickable(enabled = barred == null && (busy == null || busy == ControlName.Fast)) {
                        onApply(ControlName.Fast, SessionControls.fastFlip(fast))
                    }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = ControlCatalog.name(ControlName.Fast),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "off if you switch model",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (busy == ControlName.Fast) {
                    Text(
                        text = "Working…",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    // A read-only picture the whole row flips — a real Switch beside a clickable row
                    // would be two controls for one act. Quiet rather than green when barred, so it
                    // reads as showing a state rather than offering a change.
                    Icon(
                        if (on) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                        contentDescription = if (on) "Fast mode is on" else "Fast mode is off",
                        tint = if (on && barred == null) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                        modifier = Modifier.size(22.dp),
                    )
                }
            }
        }

        else -> for (option in ControlCatalog.fast) {
            OptionRow(
                option = option,
                current = false,
                enabled = busy == null && barred == null,
                usable = barred == null,
                onClick = { onApply(ControlName.Fast, option.id) },
            )
        }
    }
}

/**
 * The one short line a block gets, above the rows it does not replace.
 *
 * Quieter than the rows and deliberately not an error: nothing has failed, and every state that
 * reaches here — a turn in flight, a dialog on screen, an account without the credits for fast mode
 * — is a fact about right now rather than about this control.
 */
@Composable
private fun ReasonLine(text: String) {
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 10.dp, bottom = 2.dp),
    ) {
        Icon(
            Icons.Outlined.Info,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(14.dp),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun Caption(text: String) {
    Text(
        text = text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 10.dp, bottom = 2.dp),
    )
}

/**
 * The scrim over the screen a sheet was raised from.
 *
 * Its own constant rather than the switcher's, because a top-level `private val` is scoped to the
 * file that declares it — and the two are deliberately the same value, so a sheet in this app always
 * dims what it covers by the same amount.
 */
private val SHEET_SCRIM = Color(0xB3000000)
