package dev.terminaldeck.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.HostSummary
import dev.terminaldeck.android.protocol.RemoteSessionView
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckSheetChrome
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckStatusDot
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * Everything the wire says about one session, on one sheet.
 *
 * The desktop puts this under the session's name as two chips — one says *where* it runs and one
 * says *who* it runs as — plus a status line in its toolbar. On a phone there is no room for chips
 * under a title, and the answer is not to shrink them: it is a sheet reachable from the row and from
 * the session itself, holding the same facts with room to read them. Transcribed from
 * `ios/TerminalDeck/Screens/SessionDetailView.swift`.
 *
 * ## What it does *not* offer, and why each one is missing
 *
 * This is where somebody will look for the two things they cannot do, so it is worth writing down
 * why they are not here rather than leaving the gap to be rediscovered.
 *
 *  - **Renaming a session.** Not on this sheet. There *is* a verb for it now — `rename`, which the
 *    session list's row menu sends when the machine advertises it — but a name is about *this*
 *    session while everything else here is a fact off the wire, so the rename lives on the row a
 *    person is already acting on rather than behind a second sheet.
 *  - **Choosing which account a session runs as.** `create` carries `cwd`, `cols`, `rows` and
 *    `provider`; it does not carry an account, and no frame reports which one a running session got.
 *    The *other* account question — which login this phone answers a git prompt with — is not here
 *    either: it is one account for the whole phone, so it is one row in Settings, not a line on
 *    every session sheet. See the removal note where that card used to be.
 *
 * ## The folder is a control, not a caption
 *
 * The same rule the desktop's chip follows: it does not move the running session — a pty has one
 * working directory for its whole life — so what it offers is a **new** session in that folder.
 * That is the honest version of "change the folder", and it is the version the wire can serve.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionDetailSheet(
    session: RemoteSessionView,
    host: HostSummary,
    /** The folders this machine is granting this device right now, not the session's own path. */
    startableFolders: List<String>,
    canStart: Boolean,
    /** Offered only from the list, where opening it is somewhere to go. Null from inside the session. */
    onOpen: (() -> Unit)?,
    onNewSessionHere: (String) -> Unit,
    onCopy: (String) -> Unit,
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
            /* The name, and what it is doing, in the two sizes the rest of the app uses for
             * exactly this pair. */
            Text(session.title, style = DeckType.question, color = colors.primary)
            Spacer(Modifier.height(Space.x2))
            Row(verticalAlignment = Alignment.CenterVertically) {
                DeckStatusDot(session.status)
                Spacer(Modifier.width(Space.x15))
                Text(statusLine(session), style = DeckType.monoFootnote, color = colors.secondary)
            }

            /*
             * Where it runs — the folder, and the one thing this phone can honestly do with one.
             *
             * The path is drawn whole rather than truncated. It is the answer to "which checkout is
             * this", it is the one string here somebody may want to read character by character, and
             * a sheet is where there is finally room for it — the list row above truncates from the
             * head because a row has no room, which is a different screen making a different trade.
             */
            SectionCaption("Folder")
            DeckGroup {
                Row(
                    verticalAlignment = Alignment.Top,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onCopy(session.cwd) }
                        .padding(horizontal = Space.card, vertical = Space.x3),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = folderName(session.cwd),
                            style = DeckType.body,
                            color = colors.primary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Spacer(Modifier.height(Space.half))
                        Text(session.cwd, style = DeckType.mono, color = colors.faint)
                    }
                    Spacer(Modifier.width(Space.x3))
                    // Rendered without this and it was a card that copied a path with nothing on it
                    // saying so — a control whose only signal that it is one is that you happened to
                    // press it. The glyph is the affordance; the whole card stays the target.
                    Icon(
                        Icons.Filled.ContentCopy,
                        contentDescription = "Copy the folder path",
                        tint = colors.faint,
                        modifier = Modifier.size(16.dp).padding(top = 2.dp),
                    )
                }

                /*
                 * A new session in this folder, which is what the desktop's folder chip means by
                 * "change the folder".
                 *
                 * Offered only when the machine is currently granting this device that exact folder.
                 * A session's `cwd` is not automatically a folder this phone may start in — the
                 * grant is per device and editable at the desk at any moment — so a button drawn off
                 * the session's own path would be one whose only outcome is a refusal on a machine
                 * whose grant has since been narrowed.
                 */
                if (session.cwd in startableFolders && canStart) {
                    DeckDivider(startIndent = Space.card)
                    ActionRow(icon = Icons.Filled.Add, title = "New session here") {
                        onNewSessionHere(session.cwd)
                    }
                }
            }

            /* What it is. Facts, each of them straight off the wire. */
            SectionCaption("Session")
            DeckGroup {
                FactRow("Agent", session.provider.ifEmpty { "—" }, mono = true)
                DeckDivider(startIndent = Space.card)
                FactRow("Status", statusLine(session), mono = true)
                DeckDivider(startIndent = Space.card)
                // The id, because it is what a log on the machine is showing. Mono, and allowed to
                // wrap: half an id identifies nothing.
                FactRow("ID", session.id, mono = true, wraps = true)
            }

            if (onOpen != null) {
                Spacer(Modifier.height(Space.x3))
                DeckGroup {
                    ActionRow(icon = Icons.Filled.Terminal, title = "Open session", onClick = onOpen)
                }
            }

            /*
             * Which machine — the question a phone paired with three of them must never leave open.
             * The same answer the Machines screen gives, here because a session is only meaningful
             * with a machine attached to it.
             */
            SectionCaption("Machine")
            DeckGroup {
                FactRow("Name", host.label, mono = false)
                DeckDivider(startIndent = Space.card)
                // The neutral noun for a machine that never said what it is — `HostPlatform.UNKNOWN`
                // reads "desktop", which is true of every machine this app can reach and singles out
                // none of them.
                FactRow("Kind", host.hostPlatform.noun, mono = false)
                DeckDivider(startIndent = Space.card)
                FactRow("Address", host.relayUrl, mono = true, wraps = true)
            }

            /*
             * There is no Git logins row here any more.
             *
             * > *"there is one option called Git login… it is for settings, it's not for per session,
             * > so let's not show the GitHub also in that page — inside the session details, in the
             * > normal sessions too, in the copilot too, because it is the same everywhere anyway."*
             *
             * The GitHub this phone would hand over when git asks is **one account for the whole
             * phone**, not a property of a session. It was drawn per session because a session is
             * where somebody stands when a push is about to happen — but that is about *timing*, not
             * ownership, and a setting shown on twenty session sheets reads as twenty settings. It is
             * one row on the Settings tab now, which is where it always really lived; see [GitHubSheet],
             * opened from there. Matches iOS `SessionDetailView`, which removed the same card.
             */

            DeckFootnote(
                "A session's folder and the login its agent runs as are set on the machine. This " +
                    "phone can start a new session in a folder the machine grants it, and nothing else."
            )
        }
    }
}

/**
 * The status, in one line, with the exit code when there is one.
 *
 * `status` is free-form on the wire, so it is shown rather than mapped: a phone that rendered an
 * unrecognised status as "unknown" is worse than one that rendered the word the machine chose.
 */
internal fun statusLine(session: RemoteSessionView): String {
    val code = session.exitCode
    return if (code != null) "${session.status} · exit $code" else session.status
}

/** The last component of a path, which is what a person calls the project. */
internal fun folderName(path: String): String =
    path.trimEnd('/').substringAfterLast('/').ifEmpty { path }

@Composable
private fun FactRow(name: String, value: String, mono: Boolean, wraps: Boolean = false) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier.fillMaxWidth().padding(horizontal = Space.card, vertical = Space.x3),
    ) {
        Text(name, style = DeckType.body, color = colors.primary)
        Spacer(Modifier.width(Space.x4))
        Text(
            text = value,
            style = if (mono) DeckType.monoValue else DeckType.value,
            color = colors.faint,
            maxLines = if (wraps) 4 else 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
        )
    }
}

@Composable
private fun ActionRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, onClick: () -> Unit) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = Space.card, vertical = Space.x3),
    ) {
        Icon(icon, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(Space.x3))
        Text(title, style = DeckType.body, color = colors.accent)
    }
}
