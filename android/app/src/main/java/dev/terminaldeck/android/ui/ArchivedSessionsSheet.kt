package dev.terminaldeck.android.ui

import androidx.compose.foundation.clickable
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.protocol.RemoteSessionView
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckSheetChrome
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.kit.DeckStatusDot
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * The sessions this phone has put away, and the one sentence that keeps the feature honest.
 *
 * Transcribed from `ios/TerminalDeck/Screens/ArchivedSessionsView.swift`.
 *
 * ## Why this screen exists at all, rather than archive being one-way
 *
 * Because a one-way archive is a delete with a friendlier word on it, and there is nothing on this
 * phone that can delete a session. An archive that could not be undone would also make the swipe
 * frightening, and a frightening swipe is one nobody uses — which would leave the long list exactly
 * as long, with a gesture on it people have learned to avoid.
 *
 * ## And why the sentence at the foot is load-bearing
 *
 * The real risk of this feature is not that somebody cannot find a row. It is that somebody archives
 * four sessions, believes they have **stopped** four agents, closes the app, and comes back to a
 * machine that has been working — or waiting on a question — for two hours. So the screen says what
 * archiving did and did not do, in the place people arrive when they wonder where something went.
 *
 * ## Only rows the machine is still listing
 *
 * The store keeps an id until it is bounded out; this screen is handed the *intersection* of that
 * and the live session list. A machine that has been restarted has archived ids for sessions that no
 * longer exist and there is nothing to draw for them — a row for a session that has gone would offer
 * a tap that opens a terminal on nothing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArchivedSessionsSheet(
    sessions: List<RemoteSessionView>,
    /** What to call the machine in the sentence at the foot. A name, because somebody with two
     *  paired needs to know which one is still working. */
    machine: String,
    onUnarchive: (String) -> Unit,
    onOpen: (RemoteSessionView) -> Unit,
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
            Text("Archived", style = DeckType.title, color = colors.primary)
            Spacer(Modifier.height(Space.x4))

            if (sessions.isEmpty()) {
                DeckGroup {
                    Text(
                        text = "Nothing is archived on $machine.",
                        style = DeckType.body,
                        color = colors.faint,
                        modifier = Modifier.padding(Space.card),
                    )
                }
            } else {
                DeckGroup {
                    sessions.forEachIndexed { index, session ->
                        if (index > 0) DeckDivider(startIndent = Space.card)
                        ArchivedRow(
                            session = session,
                            onOpen = { onOpen(session) },
                            onUnarchive = { onUnarchive(session.id) },
                        )
                    }
                }
            }

            DeckFootnote(
                "Archiving is about this list, not about the machine. Every session here is still " +
                    "on $machine and still doing whatever it was doing — closing one is the ✕ on " +
                    "its row, and that is a different act."
            )
        }
    }
}

/**
 * One archived row: what it is, and the one verb that puts it back.
 *
 * The row itself opens the session — an archived session is not a stopped one, and the most likely
 * reason somebody came here is that they want the thing they put away. **Restore** is a button
 * rather than a swipe: this list is short by construction and a gesture that only exists on one
 * screen is a gesture nobody finds.
 */
@Composable
private fun ArchivedRow(session: RemoteSessionView, onOpen: () -> Unit, onUnarchive: () -> Unit) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpen)
            .padding(horizontal = Space.card, vertical = Space.x3),
    ) {
        DeckStatusDot(session.status)
        Spacer(Modifier.width(Space.x3))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Space.half)) {
            Text(
                text = session.title,
                style = DeckType.rowTitle,
                color = colors.primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = statusLine(session),
                style = DeckType.mono,
                color = colors.faint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(Space.x3))
        DeckQuietButton(
            label = "Restore",
            onClick = onUnarchive,
            modifier = Modifier.width(96.dp),
        )
    }
}


