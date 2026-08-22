package dev.terminaldeck.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.protocol.CopilotArguments
import dev.terminaldeck.android.protocol.CopilotConsentQuestion
import dev.terminaldeck.android.protocol.CopilotSessionRow
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckSheetChrome
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.kit.DeckStatusDot
import dev.terminaldeck.android.ui.kit.DeckTag
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

/**
 * The two references hanging off the copilot screen: the confirmation this phone must answer, and
 * the sessions the copilot started.
 *
 * Both are sheets rather than pushes, for the reason [SessionDetailSheet] gives about itself — *a
 * reference somebody opens, reads and closes, not a place they are going*. The first is the only
 * control in this file, and the argument for its shape is the longest thing here, because it is the
 * screen this feature is most easily made worse by.
 */

/**
 * A confirmation, and the two buttons that answer it.
 *
 * ## Why this phone may answer at all
 *
 * The `alter` tier's safety property used to be *a human at the machine says yes* — and that argument
 * was superseded for a reason worth understanding: the second factor was never **geography**.
 * Somebody who walks away from an unlocked desktop has taken their geography with them. It was
 * *reaching the dialog required an authorisation the requesting party did not already hold* — and
 * that is now having been paired as one of the owner's own devices, which is decided at the machine
 * and cannot be changed without pairing again.
 *
 * So a device holding `alter` answers **its own run's** questions, and nothing else's.
 *
 * ## The failure this fixes even when it cannot answer
 *
 * A desktop dialog on a screen nobody is looking at, timing out in silence two minutes later, with
 * the copilot then reporting a refusal nobody understands. A phone that shows the question *while it
 * is still answerable* fixes that whether or not it can answer it — which is why a question this
 * device may only watch is still drawn, with no buttons and a sentence saying where to go.
 *
 * ## The countdown is on it, and it is load bearing
 *
 * "There is a decision here" is worthless without "how long have I got", and the deadline is not a
 * deferral: it **expires into a refusal**. The number is the machine's own `expiresAt`, ticked
 * locally.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CopilotConsentSheet(
    question: CopilotConsentQuestion,
    /**
     * Whether this phone holds the whole question rather than only its id.
     *
     * Not the same as "the machine would accept an answer from here", and the two come apart in a
     * case that is not rare: **there is no replay**, so a phone that reconnects while a confirmation
     * is outstanding gets the watch row and no `copilot.ask`. It then holds an id and not a request,
     * and answering on an id alone is answering blind — which is the reflex Yes this whole design
     * refuses.
     */
    decidable: Boolean,
    onAnswer: (Boolean) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = DeckTheme.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val left = countdownSeconds(question.expiresAt)

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
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .padding(top = Space.x5, bottom = Space.x8),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("The copilot is asking", style = DeckType.title, color = colors.primary)
                Spacer(Modifier.weight(1f))
                if (question.tier.isNotEmpty()) DeckTag(question.tier)
            }
            Spacer(Modifier.height(Space.x2))
            Text(
                // The machine's own summary, verbatim. Nothing on this screen rewrites what a tool
                // said it wanted to do.
                text = question.summary.ifEmpty { question.tool },
                style = DeckType.question,
                color = colors.primary,
            )

            val lines = CopilotArguments.lines(question.args)
            if (lines.isNotEmpty()) {
                SectionCaption("What it would do")
                DeckGroup {
                    lines.forEachIndexed { index, (name, value) ->
                        if (index > 0) DeckDivider(startIndent = Space.card)
                        Row(
                            verticalAlignment = Alignment.Top,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = Space.card, vertical = Space.x2),
                        ) {
                            Text(name, style = DeckType.footnote, color = colors.faint)
                            Spacer(Modifier.width(Space.x3))
                            // Untrusted display text: a value a tool produced, which on this wire may
                            // have come from a file on the machine. Drawn as text, never parsed.
                            Text(
                                text = value,
                                style = DeckType.mono,
                                color = colors.primary,
                                maxLines = 4,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(Space.x4))
            Text(
                text = when {
                    left == null -> "This expires on the machine."
                    // The deadline is not a deferral: it expires into a refusal, and saying so is
                    // the difference between "answer when you get a moment" and "answer now".
                    left > 0 -> "Expires in ${left}s, into a no."
                    else -> "Expired."
                },
                style = DeckType.footnote,
                color = if (left != null && left <= 10) colors.critical else colors.warning,
            )

            Spacer(Modifier.height(Space.x5))
            if (decidable) {
                DeckPrimaryButton(label = "Allow once", onClick = { onAnswer(true) })
                Spacer(Modifier.height(Space.x2))
                DeckQuietButton(label = "Refuse", onClick = { onAnswer(false) })
            } else {
                // The honest version of "you cannot answer this here": it says where the answer has
                // to come from rather than drawing a button whose only outcome is a refusal.
                DeckFootnote(
                    "This one was raised by another device's run, so it is answered there or at the " +
                        "machine. It is shown here because a confirmation nobody sees is one that " +
                        "times out into a refusal that nobody understands."
                )
                Spacer(Modifier.height(Space.x3))
                DeckQuietButton(label = "Close", onClick = onDismiss)
            }
        }
    }
}

/**
 * The sessions the copilot started, each linked back to the turn that made it.
 *
 * The point of the screen is the link: a session in the ordinary list is a folder with an agent in
 * it, and one here is *the thing the copilot did when you asked it something* — which is the only
 * place that connection is visible at all.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CopilotSessionsSheet(
    sessions: List<CopilotSessionRow>,
    machineLabel: String,
    onOpen: (String) -> Unit,
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
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .padding(top = Space.x5, bottom = Space.x8),
        ) {
            Text("Started by the copilot", style = DeckType.title, color = colors.primary)
            Spacer(Modifier.height(Space.x4))

            if (sessions.isEmpty()) {
                DeckGroup {
                    Text(
                        text = "The copilot on $machineLabel has not started a session.",
                        style = DeckType.body,
                        color = colors.faint,
                        modifier = Modifier.padding(Space.card),
                    )
                }
            } else {
                DeckGroup {
                    sessions.forEachIndexed { index, row ->
                        if (index > 0) DeckDivider(startIndent = Space.card)
                        Row(
                            verticalAlignment = Alignment.Top,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = Space.card, vertical = Space.x3),
                        ) {
                            DeckStatusDot(row.status, modifier = Modifier.padding(top = 6.dp))
                            Spacer(Modifier.width(Space.x3))
                            Column(
                                modifier = Modifier.weight(1f),
                                verticalArrangement = Arrangement.spacedBy(Space.half),
                            ) {
                                Text(
                                    text = row.title.ifEmpty { row.id },
                                    style = DeckType.rowTitle,
                                    color = colors.primary,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    text = row.cwd,
                                    style = DeckType.mono,
                                    color = colors.faint,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    if (row.provider.isNotEmpty()) {
                                        DeckTag(row.provider)
                                        Spacer(Modifier.width(Space.x2))
                                    }
                                    Text(row.status, style = DeckType.caption, color = colors.faint)
                                }
                            }
                            Spacer(Modifier.width(Space.x2))
                            DeckQuietButton(
                                label = "Open",
                                onClick = { onOpen(row.id) },
                                modifier = Modifier.width(84.dp),
                            )
                        }
                    }
                }
            }

            DeckFootnote(
                "These are ordinary sessions on $machineLabel — the same list the Sessions tab shows. " +
                    "What this screen adds is which of them the copilot started."
            )
        }
    }
}

/**
 * Seconds left, recomputed once a second.
 *
 * A `produceState` loop rather than a recomposition per frame: the value only changes once a second
 * and the screen behind it is a card, not an animation. Null when the machine sent no deadline —
 * which draws a sentence rather than a countdown from zero.
 */
@Composable
private fun countdownSeconds(expiresAt: Long): Int? {
    if (expiresAt <= 0) return null
    val seconds by produceState(initialValue = remainingSeconds(expiresAt), expiresAt) {
        while (true) {
            value = remainingSeconds(expiresAt)
            if (value <= 0) break
            delay(1_000)
        }
    }
    return seconds
}

private fun remainingSeconds(expiresAt: Long): Int =
    ((expiresAt - System.currentTimeMillis()).coerceAtLeast(0) / 1000.0).roundToInt()
