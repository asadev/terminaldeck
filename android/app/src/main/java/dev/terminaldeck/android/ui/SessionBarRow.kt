package dev.terminaldeck.android.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.SessionBarView
import dev.terminaldeck.android.protocol.AccountWire
import dev.terminaldeck.android.protocol.foreignAccount
import kotlin.math.roundToInt

/**
 * The session's bar: how much of the plan is gone, how full the context window is, which login it
 * runs as, and the way into the conversation.
 *
 * A transcription of `pwa/src/session-bar.ts` and of the iOS bar. Every figure here is the far
 * machine's own, read by the same `readUsage` and `readContextWindow` that draw the bar at the desk,
 * which is what keeps one session from having two truths depending on which screen is looking at it.
 *
 * ## No sentences, and no zeros
 *
 * A figure that is not known is a chip that is **not drawn** — never one drawn at zero, which reads
 * as *"you have used nothing"* and is the opposite of what an unreported window means. A switch the
 * far end would refuse is a row that cannot be pressed rather than one that produces an error. The
 * rule is Asad's, stated four times: *"don't put any single statement in anywhere… We want
 * simplicity. Let the smart people use it."*
 *
 * The one press that costs anything is the ring: [onRefresh] boots a whole agent on the other
 * machine, so it happens because a finger asked and never on its own.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionBarRow(
    view: SessionBarView,
    onRefresh: () -> Unit,
    onSwitchAccount: (String) -> Unit,
    onOpenChat: () -> Unit,
) {
    var picking by remember { mutableStateOf(false) }

    // Nothing known and nothing to press is a bar with nothing in it. Absent rather than an empty
    // strip that spends a row of a phone screen saying nothing.
    val empty = view.plan == null && view.context == null && view.account == null && !view.hasTranscript
    if (empty) return

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.background)
            .padding(horizontal = 12.dp, vertical = 4.dp),
    ) {
        view.plan?.let { plan ->
            UsageRing(
                fraction = plan,
                busy = view.busy,
                onClick = if (view.canRefresh) onRefresh else null,
            )
        }

        view.context?.let { context ->
            ContextBar(fraction = context, modifier = Modifier.weight(1f))
        }
        if (view.context == null) Spacer(Modifier.weight(1f))

        view.account?.let { account ->
            AccountChip(
                account = account,
                enabled = view.canSwitchAccount && !view.busy,
                onClick = { picking = true },
            )
        }

        if (view.hasTranscript) {
            Icon(
                Icons.AutoMirrored.Filled.Chat,
                contentDescription = "Read this session as a conversation",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .size(20.dp)
                    .clickable(onClick = onOpenChat),
            )
        }
    }

    if (picking) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { picking = false },
            sheetState = sheetState,
            containerColor = MaterialTheme.colorScheme.surface,
        ) {
            AccountSheet(
                current = view.account,
                accounts = view.accounts,
                onPick = { id ->
                    picking = false
                    onSwitchAccount(id)
                },
            )
        }
    }
}

/**
 * The plan ring: the **highest** window in use, not an average.
 *
 * A person is limited by whichever window they are nearest the end of, so picking "the five-hour
 * one" would draw a calm ring while the weekly window is what actually stops them working. A ring is
 * one number, so it is the worst one.
 */
@Composable
private fun UsageRing(fraction: Double, busy: Boolean, onClick: (() -> Unit)?) {
    val percent = (fraction * 100).roundToInt()
    val track = MaterialTheme.colorScheme.outline
    // Amber past four-fifths, because the point of the ring is to be noticed before the window
    // closes rather than after. One step, not a gradient: two colours are a fact, five are a mood.
    val ink = if (fraction >= 0.8) MaterialTheme.colorScheme.secondary else MaterialTheme.colorScheme.primary
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(28.dp)
            .then(if (onClick != null && !busy) Modifier.clickable(onClick = onClick) else Modifier)
            .semantics { contentDescription = "Plan usage $percent percent. Tap to re-read." },
    ) {
        Canvas(modifier = Modifier.size(24.dp)) {
            val stroke = Stroke(width = 3.dp.toPx())
            val inset = stroke.width / 2
            val box = Size(size.width - stroke.width, size.height - stroke.width)
            drawArc(
                color = track,
                startAngle = -90f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = androidx.compose.ui.geometry.Offset(inset, inset),
                size = box,
                style = stroke,
            )
            drawArc(
                color = if (busy) track else ink,
                startAngle = -90f,
                sweepAngle = (360.0 * fraction).toFloat(),
                useCenter = false,
                topLeft = androidx.compose.ui.geometry.Offset(inset, inset),
                size = box,
                style = stroke,
            )
        }
    }
}

/** How full this session's context window is. A bar rather than a ring: it is a length, not a clock. */
@Composable
private fun ContextBar(fraction: Double, modifier: Modifier = Modifier) {
    val percent = (fraction * 100).roundToInt()
    Column(
        modifier = modifier.semantics { contentDescription = "Context window $percent percent full." },
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(MaterialTheme.colorScheme.outline),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(fraction.toFloat().coerceIn(0f, 1f))
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(
                        if (fraction >= 0.8) MaterialTheme.colorScheme.secondary
                        else MaterialTheme.colorScheme.primary
                    ),
            )
        }
    }
}

@Composable
private fun AccountChip(account: AccountWire, enabled: Boolean, onClick: () -> Unit) {
    Text(
        text = account.name,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurface,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(6.dp))
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 8.dp, vertical = 4.dp),
    )
}

/**
 * Every login the machine has.
 *
 * A row belonging to a *different agent* than the session is running is drawn and is not pressable:
 * the far side already refuses that switch with a sentence, and nothing on this bar draws sentences,
 * so a row that could be pressed and could only ever do nothing is worse than a row that cannot.
 * Both providers have to be known before two of them can be said to differ — a row whose own
 * provider is null stays pressable rather than being dimmed because an older machine did not name
 * its agent.
 */
@Composable
private fun AccountSheet(
    current: AccountWire?,
    accounts: List<AccountWire>,
    onPick: (String) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(bottom = 12.dp),
    ) {
        Text(
            text = "Account",
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
        )
        for (account in accounts) {
            val here = account.id == current?.id
            val foreign = foreignAccount(current, account)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .then(
                        if (here || foreign) Modifier
                        else Modifier.clickable { onPick(account.id) }
                    )
                    .padding(horizontal = 20.dp, vertical = 12.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = account.name,
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (foreign) {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        } else {
                            MaterialTheme.colorScheme.onSurface
                        },
                    )
                    account.provider?.let { provider ->
                        Text(
                            text = provider,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                if (here) {
                    Icon(
                        Icons.Filled.Check,
                        contentDescription = "In use",
                        tint = MaterialTheme.colorScheme.primary,
                    )
                }
            }
        }
    }
}
