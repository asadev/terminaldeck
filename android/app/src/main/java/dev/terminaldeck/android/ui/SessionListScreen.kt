package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.IconButton
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.DeckUiState
import dev.terminaldeck.android.protocol.RemoteSessionView
import dev.terminaldeck.android.transport.TransportState
import dev.terminaldeck.android.transport.detail
import dev.terminaldeck.android.transport.isOnline
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

/**
 * The sessions running on the machine on screen.
 *
 * Deliberately not a dashboard. The protocol carries six fields per session and this screen shows
 * all six, because the phone's job is to let someone decide which session to look at from a bus —
 * anything richer belongs on the desktop, which is the same reasoning `protocol.ts` gives for
 * keeping version 1 tiny.
 *
 * ## The title is the switcher — when there is something to switch to
 *
 * With several machines paired, the one question this screen has to answer before any other is
 * *which computer am I looking at* — so the machine's name is the title rather than the app's, and
 * the title is the control that changes it. See [HostSwitcherSheet], which now answers only that
 * question: naming a machine, forgetting one, pairing another and adding a server are on the
 * **Machines** screen inside Settings, which is where iOS puts them and why a single-machine title
 * is no longer a control at all.
 *
 * ## The indicator never claims a connection it does not have
 *
 * There is one live state, and the dot is only green in it. Everything else says what is actually
 * happening and, when a retry is scheduled, when it will happen — a countdown rather than a
 * spinner, because a spinner is indistinguishable from a hang.
 *
 * When the connection drops the list is kept rather than emptied: it is the last true thing the
 * desktop said. But it is dimmed and the statuses stop being claims about now, which is the
 * difference between showing history and lying about the present.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionListScreen(
    state: DeckUiState,
    onOpen: (RemoteSessionView) -> Unit,
    onRefresh: () -> Unit,
    onReconnect: () -> Unit,
    /** Null means "wherever that machine would have started one" — see `DeckViewModel.newSession`. */
    onNewSession: (String?) -> Unit,
    onSelectHost: (String) -> Unit,
    /**
     * End a session on the machine on screen. Drawn per row only when [DeckUiState.canCloseSessions]
     * — the machine advertised `close` — and confirmed once here before it is sent, because closing
     * is not undoable. The row is removed on the machine's `closed` answer, not on this tap.
     */
    onCloseSession: (RemoteSessionView) -> Unit = {},
) {
    val snackbar = remember { SnackbarHostState() }
    var folderMenu by remember { mutableStateOf(false) }
    var switcher by remember { mutableStateOf(false) }
    // Set to the row a person asked to close; the confirm dialog is drawn while it is non-null.
    var closing by remember { mutableStateOf<RemoteSessionView?>(null) }
    LaunchedEffect(state.notice) {
        state.notice?.let { snackbar.showSnackbar(it) }
    }

    // The switcher is a sibling of the whole screen rather than of its content, so the scrim covers
    // the bar the switcher was opened from. A sheet with the title still bright above it reads as a
    // menu belonging to that title rather than as the app's list of machines.
    Box(modifier = Modifier.fillMaxSize()) {

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                    titleContentColor = MaterialTheme.colorScheme.onBackground,
                ),
                title = {
                    /*
                     * The title is the switcher — but only when there is something to switch to.
                     *
                     * With one machine paired there is nothing to pick, and everything that used to
                     * justify opening this sheet anyway (rename, forget, pair another, add a server,
                     * GitHub, Devices, This server) is on the Settings tab now. So a single machine
                     * gets the product's name and no chevron, exactly as on iOS, rather than a
                     * control that opens a list of one.
                     *
                     * When it *is* a control, the whole title is: a name with an arrow next to it
                     * that only responds on the arrow is a target the width of a fingernail.
                     */
                    val switchable = state.hasSeveralHosts
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(10.dp))
                            .then(if (switchable) Modifier.clickable { switcher = true } else Modifier)
                            .padding(horizontal = 6.dp, vertical = 4.dp),
                    ) {
                        Column(modifier = Modifier.weight(1f, fill = false)) {
                            Text(
                                text = if (switchable) state.hostLabel else "Terminal Deck",
                                style = MaterialTheme.typography.titleLarge,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                // The machine's public name at the relay, which is the only name the
                                // protocol gives it. `welcome.deviceName` is this phone's.
                                text = if (switchable) {
                                    "${state.hosts.size} machines · tap to switch"
                                } else {
                                    state.pairing?.hostId ?: "not paired"
                                },
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        if (switchable) {
                            Spacer(Modifier.width(4.dp))
                            Icon(
                                Icons.Filled.ExpandMore,
                                contentDescription = "Your machines",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                },
                /*
                 * No Refresh button, and its absence is the decision.
                 *
                 * *"Refresh, what does it actually do? Pull-to-refresh would be the natural
                 * gesture."* It asked the machine for a session list the machine already pushes
                 * whenever it changes, so the button's whole job was to make somebody wonder whether
                 * the list was stale. The gesture is on the list below, where a list's refresh
                 * belongs; the one control that does something a person cannot otherwise do —
                 * Retry, while the socket is down — is on the connection banner.
                 */
            )
        },
        floatingActionButton = {
            // Absent, not disabled, when the machine never advertised `create` — and equally when it
            // has chosen no folders for this phone, because that machine will refuse every session
            // this button could ask for. A control that exists only to be refused is a fake feature.
            // What that state gets instead is [FolderNote], which says who has to change it, where.
            if (state.canStartSession) {
                Box {
                    ExtendedFloatingActionButton(
                        onClick = {
                            // One destination is not a choice, so it does not get a menu. A grant of
                            // exactly one folder starts there on the tap — and the folder is named
                            // on the line above the list, so the thing the old picker never managed
                            // to say, *where this starts*, is on screen before the tap rather than
                            // discovered afterwards.
                            //
                            // With no list at all — a machine older than the field, with nothing
                            // running — the machine picks its own default, which is exactly what its
                            // own New Session button does with nothing filled in.
                            val only = state.onlyGrantedFolder
                            when {
                                only != null -> onNewSession(only)
                                state.startableFolders.isEmpty() -> onNewSession(null)
                                else -> folderMenu = true
                            }
                        },
                        containerColor = MaterialTheme.colorScheme.primary,
                        contentColor = MaterialTheme.colorScheme.onPrimary,
                        icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                        text = { Text("New session") },
                    )
                    DropdownMenu(expanded = folderMenu, onDismissRequest = { folderMenu = false }) {
                        // The rows are decided in [DeckUiState.folderChoices] rather than here: what
                        // this menu offers is the thing that was wrong, and a list assembled inside a
                        // composable can only be checked by reading it. Either way every row is a
                        // folder the machine will accept — a picker built from anything else offers
                        // choices that fail.
                        for (choice in state.folderChoices) {
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        text = choice.label,
                                        // Mono for a path and nothing else. "Where the Mac would" is
                                        // a sentence, and setting it in the terminal face would make
                                        // it read as one more directory.
                                        fontFamily = if (choice.isPath) FontFamily.Monospace else null,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                },
                                onClick = {
                                    folderMenu = false
                                    onNewSession(choice.folder)
                                },
                            )
                        }
                    }
                }
            }
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            ConnectionBanner(state.transport, onReconnect)
            FolderNote(state)

            /*
             * Pull to refresh — the gesture that replaced the button.
             *
             * It asks the machine for its session list again. That list is *pushed* whenever it
             * changes, so this is not how the screen stays current; it is what somebody does when
             * they do not believe it, which is a real thing to want and is worth exactly one
             * gesture. The spinner is the platform's, and it settles on the answer rather than on a
             * timer, so a pull against a machine that has gone quiet ends when the socket does.
             */
            val refreshing = state.transport.isOnline && !state.loaded
            PullToRefreshBox(
                isRefreshing = refreshing,
                onRefresh = onRefresh,
                modifier = Modifier.fillMaxSize(),
            ) {
                if (state.sessions.isEmpty()) {
                    // Still inside the pull box: an empty list is exactly where somebody reaches for
                    // this gesture, so a screen that only offered it once there was something to
                    // scroll would be missing the case it is for.
                    EmptyState(state)
                } else {
                    LazyColumn(
                        contentPadding = PaddingValues(16.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier
                            .fillMaxSize()
                            .alpha(if (state.live) 1f else 0.55f),
                    ) {
                        items(state.sessions, key = { it.id }) { session ->
                            SessionCard(
                                session = session,
                                live = state.live,
                                onClick = { onOpen(session) },
                                // Absent, not disabled, when the machine never advertised `close`.
                                onClose = if (state.canCloseSessions) ({ closing = session }) else null,
                            )
                        }
                    }
                }
            }
        }
    }

    if (switcher) {
        HostSwitcherSheet(
            hosts = state.hosts,
            onSelect = onSelectHost,
            onDismiss = { switcher = false },
        )
    }

    closing?.let { session ->
        CloseSessionDialog(
            session = session,
            machineNoun = state.machineNoun,
            onConfirm = {
                closing = null
                onCloseSession(session)
            },
            onCancel = { closing = null },
        )
    }

    }
}

/**
 * The one confirm before a session is ended.
 *
 * Closing does not come back, so it asks — and the sentence says three things and no more: which
 * session, what happens to it, and that it is gone for good. It deliberately does not say "are you
 * sure"; the two buttons already ask that. The row is not removed here — it goes on the machine's
 * `closed` answer, for the reason [DeckViewModel] gives — so the destructive button just sends and
 * dismisses.
 */
@Composable
private fun CloseSessionDialog(
    session: RemoteSessionView,
    machineNoun: String,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
) {
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onCancel,
        containerColor = MaterialTheme.colorScheme.surface,
        title = { Text("Close ${session.title}?") },
        text = {
            Text(
                text = "The session stops on the $machineNoun and does not come back.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text("Close session", color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text("Keep") } },
    )
}

/**
 * Where a new session would start, in the two cases where nothing else on screen says.
 *
 * This is the answer to the complaint the folder grants exist for: *the picker shows one folder and
 * I cannot explain why*. Both sentences below name the machine, because the fact being reported is
 * the machine's and the remedy is on it — the phone is the one device in the room that cannot fix
 * either of these.
 *
 * Nothing is drawn in the ordinary case. A machine that granted several folders explains itself the
 * moment the menu opens, and a line repeating that would be furniture on the screen someone opens
 * to check on a build.
 *
 * The path is monospaced inside an otherwise ordinary sentence, deliberately: mono is this app's
 * promise that the characters are exact and countable, which is true of a path and of nothing else
 * in the line.
 */
@Composable
private fun FolderNote(state: DeckUiState) {
    if (!state.canCreateSessions) return
    val only = state.onlyGrantedFolder
    val text = when {
        state.noFoldersGranted -> AnnotatedString(state.noFoldersSentence)
        only != null -> buildAnnotatedString {
            append("New sessions start in ")
            withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) { append(only) }
            append(" — the one folder the ${state.machineNoun} has shared with this phone.")
        }
        else -> return
    }

    Text(
        text = text,
        style = MaterialTheme.typography.bodySmall,
        // Deliberately not the error colour. Nothing has gone wrong: somebody made a choice at a
        // keyboard, and this is that choice being reported rather than a fault being raised.
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

@Composable
private fun ConnectionBanner(state: TransportState, onReconnect: () -> Unit) {
    val tint = connectionTint(state)
    val retryAt = when (state) {
        is TransportState.Waiting -> state.retryAt
        is TransportState.Pending -> state.retryAt
        else -> null
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
    ) {
        Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(tint))
        Spacer(Modifier.width(8.dp))
        Text(
            text = state.detail + countdown(retryAt),
            style = MaterialTheme.typography.bodySmall,
            color = tint,
            modifier = Modifier.weight(1f),
        )
        if (state !is TransportState.Online && state !is TransportState.Connecting) {
            TextButton(onClick = onReconnect) { Text("Retry") }
        }
    }
}

/**
 * " · retrying in 4s", recomputed every second.
 *
 * A `produceState` loop rather than a recomposition-on-every-frame animation: the value only
 * changes once a second and the screen behind it is a list, not an animation.
 */
@Composable
private fun countdown(retryAt: Long?): String {
    if (retryAt == null) return ""
    val seconds by produceState(initialValue = remaining(retryAt), retryAt) {
        while (true) {
            value = remaining(retryAt)
            if (value <= 0) break
            delay(1_000)
        }
    }
    return if (seconds > 0) " · retrying in ${seconds}s" else " · retrying…"
}

private fun remaining(retryAt: Long): Int =
    ((retryAt - System.currentTimeMillis()).coerceAtLeast(0) / 1000.0).roundToInt()

@Composable
private fun EmptyState(state: DeckUiState) {
    // Scrollable even with nothing in it, so the pull gesture above has something to pull.
    Box(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
        contentAlignment = Alignment.Center,
    ) {
        if (!state.loaded && state.transport is TransportState.Connecting) {
            CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
        } else {
            Text(
                text = if (state.transport.isOnline) {
                    // Named, because with two machines paired "no sessions" does not say whose.
                    "No sessions on ${state.hostLabel}."
                } else {
                    // Not "no sessions": nothing is known either way while the socket is down, and
                    // an empty list would read as a machine with nothing running on it.
                    "Not connected to ${state.hostLabel}, so there is nothing to show yet."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SessionCard(
    session: RemoteSessionView,
    live: Boolean,
    onClick: () -> Unit,
    /** Null when the machine does not advertise `close`; the ✕ is absent then, never disabled. */
    onClose: (() -> Unit)? = null,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(start = 14.dp, top = 14.dp, end = if (onClose != null) 4.dp else 14.dp, bottom = 14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusDot(session)
            Spacer(Modifier.width(10.dp))
            Text(
                text = session.title,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            ProviderChip(session.provider)
            if (onClose != null) {
                Spacer(Modifier.width(4.dp))
                IconButton(onClick = onClose, modifier = Modifier.size(32.dp)) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = "Close ${session.title}",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }

        Spacer(Modifier.height(8.dp))

        Text(
            text = session.cwd,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )

        Spacer(Modifier.height(6.dp))

        Text(
            // `status` is free-form on the wire, so it is shown rather than mapped. A phone that
            // renders an unrecognised status as "unknown" is worse than one that renders the word
            // the desktop actually sent. When the socket is down the word is qualified rather than
            // dropped: it was true when it arrived.
            text = buildString {
                append(session.status)
                session.exitCode?.let { append(" · exit $it") }
                if (!live) append(" · as of the last connection")
            },
            style = MaterialTheme.typography.labelSmall,
            color = statusColor(session),
        )
    }
}

@Composable
private fun StatusDot(session: RemoteSessionView) {
    Box(modifier = Modifier.size(9.dp).clip(CircleShape).background(statusColor(session)))
}

@Composable
private fun ProviderChip(provider: String) {
    Text(
        text = provider.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

@Composable
private fun statusColor(session: RemoteSessionView): Color = when {
    session.exitCode != null && session.exitCode != 0 -> MaterialTheme.colorScheme.error
    session.exitCode != null -> MaterialTheme.colorScheme.onSurfaceVariant
    session.status == "running" -> MaterialTheme.colorScheme.primary
    session.status == "waiting" -> MaterialTheme.colorScheme.secondary
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}
