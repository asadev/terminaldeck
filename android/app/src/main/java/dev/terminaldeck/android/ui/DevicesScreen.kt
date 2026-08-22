package dev.terminaldeck.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import dev.terminaldeck.android.DeviceRosterView
import dev.terminaldeck.android.protocol.DeviceRoster
import dev.terminaldeck.android.protocol.DeviceRosterRow
import dev.terminaldeck.android.ui.kit.DeckDestructiveText
import dev.terminaldeck.android.ui.kit.DeckEmptyState
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckTag
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * Every device signed in to the machine on screen, and the one verb that removes one.
 *
 * Reached from the switcher and drawn only over a machine that advertised the roster — the
 * capability is withheld from a guest at the source, so a phone that gets here is entitled to
 * manage it. The three sentences per row come from [DeviceRoster], which is testable where this
 * drawing is not; removing is confirmed once, because it does not come back and doubles as sign-out
 * for the device in your hand.
 *
 * Honest states: a sentence rather than a spinner until the first `devices.rows` answers; the
 * machine's own sentence under a removal, kept for a refusal and cleared for a confirmation by the
 * controller; and the roster kept fresh after the first read by the `devices.changed` push rather
 * than a poll.
 */
@Composable
fun DevicesScreen(
    view: DeviceRosterView,
    machineLabel: String,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onRevoke: (String) -> Unit,
) {
    var removing by remember { mutableStateOf<DeviceRosterRow?>(null) }
    val colors = DeckTheme.colors

    Scaffold(
        containerColor = colors.background,
        topBar = {
            DeckTopBar(
                title = "Devices",
                subtitle = machineLabel,
                onBack = onBack,
                actions = {
                    TextButton(onClick = onRefresh) {
                        Text("Refresh", style = DeckType.value, color = colors.accent)
                    }
                },
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            val rows = view.rows
            when {
                rows == null -> DeckEmptyState("Reading the devices on $machineLabel…", Modifier.weight(1f))

                // Named, because "no devices" does not say whose with two machines paired.
                rows.isEmpty() -> DeckEmptyState("No devices are signed in to $machineLabel.", Modifier.weight(1f))

                else -> LazyColumn(
                    contentPadding = PaddingValues(
                        start = Space.screen,
                        end = Space.screen,
                        top = Space.x3,
                        bottom = Space.x6,
                    ),
                    verticalArrangement = Arrangement.spacedBy(Space.x2),
                    modifier = Modifier.weight(1f),
                ) {
                    items(rows, key = { it.id }) { row ->
                        DeviceCard(
                            row = row,
                            isMe = row.id == view.myDeviceId,
                            busy = view.busy == row.id,
                            onRemove = { removing = row },
                        )
                    }
                }
            }

            view.notice?.let { notice ->
                DeckFootnote(
                    text = notice.text,
                    color = if (notice.ok) colors.secondary else colors.critical,
                    modifier = Modifier.padding(horizontal = Space.screen, vertical = Space.x2),
                )
            }
        }
    }

    removing?.let { row ->
        val isMe = row.id == view.myDeviceId
        AlertDialog(
            onDismissRequest = { removing = null },
            containerColor = colors.surface,
            titleContentColor = colors.primary,
            textContentColor = colors.secondary,
            title = { Text("Remove ${row.name}?", style = DeckType.title) },
            text = {
                Text(
                    text = if (isMe) {
                        "This is the device you are on. Removing it signs this phone out and drops " +
                            "its connection. You will need a new pairing code to connect again."
                    } else {
                        DeviceRoster.removeQuestion(row)
                    },
                    style = DeckType.footnote,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    removing = null
                    onRevoke(row.id)
                }) { Text("Remove", style = DeckType.control, color = colors.critical) }
            },
            dismissButton = {
                TextButton(onClick = { removing = null }) {
                    Text("Keep", style = DeckType.control, color = colors.accent)
                }
            },
        )
    }
}

/**
 * One device: what it is called, whether it is this phone, what standing it has, when it was last
 * seen, and the fingerprint that identifies its key.
 *
 * A card with a fill and a radius — no outline. The fingerprint is mono and the rest is not, which
 * is this app's one typographic promise: mono means *these characters are exact and countable*,
 * which is true of a key fingerprint and of nothing else on the row.
 */
@Composable
private fun DeviceCard(
    row: DeviceRosterRow,
    isMe: Boolean,
    busy: Boolean,
    onRemove: () -> Unit,
) {
    val colors = DeckTheme.colors
    DeckGroup {
        Column(modifier = Modifier.padding(horizontal = Space.card, vertical = Space.x3)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = row.name,
                    style = DeckType.rowTitle,
                    color = colors.primary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (isMe) {
                    DeckTag("this phone")
                    Spacer(Modifier.width(Space.x2))
                }
                DeckDestructiveText(
                    label = if (busy) "Removing…" else "Remove",
                    onClick = onRemove,
                    enabled = !busy,
                )
            }

            Spacer(Modifier.height(Space.x15))
            Text(DeviceRoster.standing(row), style = DeckType.footnote, color = colors.secondary)
            Text(
                text = DeviceRoster.lastSeen(row, System.currentTimeMillis()),
                style = DeckType.footnote,
                color = colors.faint,
            )
            Spacer(Modifier.height(Space.x15))
            Text(
                text = DeviceRoster.fingerprint(row),
                style = DeckType.mono,
                color = colors.faint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
