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
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.IconButton
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import dev.terminaldeck.android.ui.kit.DeckEmptyState
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckStatusDot
import dev.terminaldeck.android.ui.kit.DeckTag
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space
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
    /**
     * The rows this phone has put away on the machine on screen, and the ones pulled to the top.
     *
     * Passed in already split rather than derived here, so that the count on the ⋯ item and the rows
     * on the screen behind it come from one calculation. Empty when nothing is archived, which is
     * the ordinary case and draws no menu item at all.
     */
    listed: List<RemoteSessionView> = state.sessions,
    archived: List<RemoteSessionView> = emptyList(),
    isPinned: (RemoteSessionView) -> Boolean = { false },
    onArchive: (RemoteSessionView) -> Unit = {},
    onPin: (RemoteSessionView, Boolean) -> Unit = { _, _ -> },
    onArchivedList: () -> Unit = {},
    /** Everything the wire says about one session, as a sheet. Long-press, and the terminal's ⋯. */
    onDetails: (RemoteSessionView) -> Unit = {},
    /**
     * Give a session a name of this person's choosing — the Rename row's action.
     *
     * *"for being able to rename sessions."* An empty name is not a cancel and not a mistake: it
     * tells the machine to derive its own from the folder again, the only way to undo a rename
     * without knowing what the folder is called. Offered per row only when the machine advertised
     * the verb — [DeckUiState.canRenameSessions] — the same absent-not-greyed rule the ✕ follows.
     */
    onRename: (RemoteSessionView, String) -> Unit = { _, _ -> },
    /** The line that says what changed while the app was gone, and the tap that dismisses it. */
    onDismissAwayReport: () -> Unit = {},
) {
    val snackbar = remember { SnackbarHostState() }
    var folderMenu by remember { mutableStateOf(false) }
    var switcher by remember { mutableStateOf(false) }
    // Set to the row a person asked to close; the confirm dialog is drawn while it is non-null.
    var closing by remember { mutableStateOf<RemoteSessionView?>(null) }
    // Set to the row a person asked to rename; the name dialog is drawn while it is non-null.
    var renaming by remember { mutableStateOf<RemoteSessionView?>(null) }
    LaunchedEffect(state.notice) {
        state.notice?.let { snackbar.showSnackbar(it) }
    }

    // The switcher is a sibling of the whole screen rather than of its content, so the scrim covers
    // the bar the switcher was opened from. A sheet with the title still bright above it reads as a
    // menu belonging to that title rather than as the app's list of machines.
    Box(modifier = Modifier.fillMaxSize()) {

    Scaffold(
        containerColor = DeckTheme.colors.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = DeckTheme.colors.background,
                    titleContentColor = DeckTheme.colors.primary,
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
                            .padding(horizontal = Space.x15, vertical = Space.x1),
                    ) {
                        Column(modifier = Modifier.weight(1f, fill = false)) {
                            Text(
                                text = if (switchable) state.hostLabel else "Terminal Deck",
                                style = DeckType.title,
                                color = DeckTheme.colors.primary,
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
                                style = DeckType.caption,
                                color = DeckTheme.colors.faint,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        if (switchable) {
                            Spacer(Modifier.width(4.dp))
                            Icon(
                                Icons.Filled.ExpandMore,
                                contentDescription = "Your machines",
                                tint = DeckTheme.colors.faint,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                },
                /*
                 * One item in the ⋯, and it is a place rather than an action: **Archived**.
                 *
                 * Refresh and Reconnect were both in it and both are gone — *"Refresh, what does it
                 * actually do? Pull-to-refresh would be the natural gesture. Reconnect, I don't know
                 * why we need it… if they are useless and everything is automatically working, we
                 * need to remove them."* The gesture is on the list and the one control that does
                 * something a person cannot otherwise do — Retry, while the socket is down — is on
                 * the connection banner.
                 *
                 * The whole ⋯ is absent when nothing is archived on this machine, because then it
                 * opens a screen that says only that nothing is there.
                 */
                actions = {
                    if (archived.isNotEmpty()) {
                        var overflow by remember { mutableStateOf(false) }
                        Box {
                            IconButton(onClick = { overflow = true }) {
                                Icon(
                                    Icons.Filled.MoreVert,
                                    contentDescription = "More",
                                    tint = DeckTheme.colors.faint,
                                )
                            }
                            DropdownMenu(expanded = overflow, onDismissRequest = { overflow = false }) {
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            if (archived.size == 1) {
                                                "Archived · 1"
                                            } else {
                                                "Archived · ${archived.size}"
                                            }
                                        )
                                    },
                                    onClick = { overflow = false; onArchivedList() },
                                )
                            }
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
                        containerColor = DeckTheme.colors.accent,
                        contentColor = DeckTheme.colors.onAccent,
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
            AwayLine(state.awayReport, onDismissAwayReport)
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
                if (listed.isEmpty()) {
                    // Still inside the pull box: an empty list is exactly where somebody reaches for
                    // this gesture, so a screen that only offered it once there was something to
                    // scroll would be missing the case it is for.
                    EmptyState(
                        state = state,
                        // Empty *because of this phone* rather than because of the machine, which is
                        // a different sentence and a different way out: the sessions exist, this
                        // phone put them away, and the fix is the place they were put — not a New
                        // Session button, and certainly not "no sessions on that machine", which is
                        // the one thing that is not true.
                        everythingArchived = state.live && archived.isNotEmpty(),
                        onArchivedList = onArchivedList,
                    )
                } else {
                    LazyColumn(
                        contentPadding = PaddingValues(
                            start = Space.screen,
                            end = Space.screen,
                            top = Space.x2,
                            // Room for the New Session button to float over without covering the
                            // last row, which it did — measured on a 5.0" screen with four sessions.
                            bottom = 96.dp,
                        ),
                        verticalArrangement = Arrangement.spacedBy(Space.x2),
                        modifier = Modifier
                            .fillMaxSize()
                            .alpha(if (state.live) 1f else 0.55f),
                    ) {
                        items(listed, key = { it.id }) { session ->
                            SessionCard(
                                session = session,
                                live = state.live,
                                pinned = isPinned(session),
                                onClick = { onOpen(session) },
                                // Absent, not disabled, when the machine never advertised `close`.
                                onClose = if (state.canCloseSessions) ({ closing = session }) else null,
                                // Absent, not disabled, when the machine never advertised `rename`.
                                onRename = if (state.canRenameSessions) ({ renaming = session }) else null,
                                onArchive = { onArchive(session) },
                                onPin = { onPin(session, !isPinned(session)) },
                                onDetails = { onDetails(session) },
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

    renaming?.let { session ->
        RenameSessionDialog(
            session = session,
            onConfirm = { name ->
                renaming = null
                onRename(session, name)
            },
            onCancel = { renaming = null },
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
        containerColor = DeckTheme.colors.surface,
        titleContentColor = DeckTheme.colors.primary,
        textContentColor = DeckTheme.colors.secondary,
        // *"instead of saying close just say delete… they know that click it will go
        // away completely."* The verb ends a session on the machine; Delete says so.
        title = { Text("Delete ${session.title}?") },
        text = {
            Text(
                text = "The session stops on the $machineNoun and does not come back.",
                style = DeckType.footnote,
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text("Delete session", style = DeckType.control, color = DeckTheme.colors.critical)
            }
        },
        dismissButton = {
            TextButton(onClick = onCancel) {
                Text("Keep", style = DeckType.control, color = DeckTheme.colors.accent)
            }
        },
    )
}

/**
 * Giving a session a name, in the one shape a phone has for a short piece of typed text.
 *
 * *"for being able to rename sessions."* A `TextField` inside a dialog rather than a screen of its
 * own: it is one line with one answer, and a screen for it would be a screen to get out of. Save is
 * not destructive and is the default; the field starts on the session's current title.
 *
 * The empty field is allowed through on purpose — it is how the machine is told to derive its own
 * name from the folder again, the only way to undo a rename without knowing what that folder is
 * called. The line under the field says so, because an empty box that means something is a thing
 * nobody guesses. The row is not changed here: it changes when the machine's next `sessions` frame
 * arrives, so the name people see is the one the machine kept.
 */
@Composable
private fun RenameSessionDialog(
    session: RemoteSessionView,
    onConfirm: (String) -> Unit,
    onCancel: () -> Unit,
) {
    val colors = DeckTheme.colors
    // Seeded from the current title and keyed to the session, so the machine re-reading this row
    // every few seconds cannot throw the half-typed draft away underneath the person typing it.
    var text by remember(session.id) { mutableStateOf(session.title) }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onCancel,
        containerColor = colors.surface,
        titleContentColor = colors.primary,
        textContentColor = colors.secondary,
        // The title names the session, so a list of eight `agent` rows cannot produce a rename of
        // the wrong one.
        title = { Text("Rename ${session.title}") },
        text = {
            Column {
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    singleLine = true,
                    placeholder = { Text("Name", color = colors.faint) },
                    // The one green in the box: the focus edge and the caret, so the field reads as
                    // this app's rather than as the platform's default blue.
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = colors.accent,
                        cursorColor = colors.accent,
                        focusedTextColor = colors.primary,
                        unfocusedTextColor = colors.primary,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(Space.x2))
                Text(
                    text = "Every device signed in here sees the new name. Leave it empty to go " +
                        "back to the folder's own name.",
                    style = DeckType.footnote,
                    color = colors.faint,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(text) }) {
                Text("Save", style = DeckType.control, color = colors.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onCancel) {
                Text("Cancel", style = DeckType.control, color = colors.secondary)
            }
        },
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
        style = DeckType.caption,
        // Deliberately not the error colour. Nothing has gone wrong: somebody made a choice at a
        // keyboard, and this is that choice being reported rather than a fault being raised.
        color = DeckTheme.colors.faint,
        modifier = Modifier.fillMaxWidth().padding(horizontal = Space.screen, vertical = Space.x2),
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
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = Space.screen, top = Space.x15, end = Space.x2, bottom = Space.x15),
    ) {
        Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(tint))
        Spacer(Modifier.width(Space.x2))
        Text(
            // A sentence, in the app's own face. It was set in the mono face — not by choice, but
            // because the theme this replaces defined `bodySmall` as monospaced, so every quiet
            // line in the app came out looking like program output. Mono is reserved for strings
            // whose characters are meant to be counted, and "Could not reach that desktop" is not
            // one of them.
            text = state.detail + countdown(retryAt),
            style = DeckType.caption,
            color = tint,
            modifier = Modifier.weight(1f),
        )
        if (state !is TransportState.Online && state !is TransportState.Connecting) {
            TextButton(onClick = onReconnect) {
                Text("Retry", style = DeckType.value, color = DeckTheme.colors.accent)
            }
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
private fun EmptyState(
    state: DeckUiState,
    everythingArchived: Boolean = false,
    onArchivedList: () -> Unit = {},
) {
    // Scrollable even with nothing in it, so the pull gesture above has something to pull.
    /*
     * A **sentence in all three cases**, never a spinner.
     *
     * A spinner is indistinguishable from a hang, which is the same reason the connection banner
     * counts down rather than spinning. The three sentences say three genuinely different things:
     * the socket is being opened, the machine has nothing running, or nothing is known either way
     * because there is no socket. Every one names the machine, because with two paired "no sessions"
     * does not say whose.
     */
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
    ) {
        DeckEmptyState(
            text = when {
                !state.loaded && state.transport is TransportState.Connecting ->
                    "Reaching ${state.hostLabel}…"
                everythingArchived ->
                    "Every session on ${state.hostLabel} is archived — they are still running there."
                state.transport.isOnline -> "No sessions on ${state.hostLabel}."
                else -> "Not connected to ${state.hostLabel}, so there is nothing to show yet."
            }
        )
        // Not a New Session button. There is nothing wrong here and nothing to start.
        if (everythingArchived) {
            TextButton(onClick = onArchivedList) {
                Text("Show archived", style = DeckType.control, color = DeckTheme.colors.accent)
            }
        }
    }
}

/**
 * One session, and the four things that can be done to its row.
 *
 * Asad asked for a gesture: *"close the session (with a confirmation), archive, move. When we will
 * have a lot of sessions we will not like to have all of them over here."* iOS answers that with
 * `swipeActions`, which exists inside a `List` and has the system's rubber band and its interaction
 * with the back gesture at the left edge. Android has neither for a column of cards, and
 * hand-rolling a drag would give a swipe that is not the platform's — a different depth and a
 * different feel from every other app on the phone, in exchange for hiding four verbs behind a
 * gesture nobody is told about.
 *
 * So the verbs are a **long press**, which is Android's own convention for "more about this row",
 * and the ✕ stays on the card because closing is the one that is not undoable and belongs in sight.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionCard(
    session: RemoteSessionView,
    live: Boolean,
    pinned: Boolean = false,
    onClick: () -> Unit,
    /** Null when the machine does not advertise `close`; the ✕ is absent then, never disabled. */
    onClose: (() -> Unit)? = null,
    /** Null when the machine does not advertise `rename`; the Rename row is absent then, never greyed. */
    onRename: (() -> Unit)? = null,
    onArchive: () -> Unit = {},
    onPin: () -> Unit = {},
    onDetails: () -> Unit = {},
) {
    var menu by remember { mutableStateOf(false) }
    val colors = DeckTheme.colors
    /*
     * A fill and a radius, no outline.
     *
     * It was outlined, and on a dark ground a 9%-alpha border around a 3%-lighter fill is two
     * nearly-invisible edges doing one job — it reads as a rectangle somebody forgot to finish
     * rather than as a raised surface.
     */
    DeckGroup {
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(onClick = onClick, onLongClick = { menu = true })
                .padding(
                    start = Space.card,
                    top = Space.x3,
                    end = if (onClose != null) Space.x1 else Space.card,
                    bottom = Space.x3,
                ),
        ) {
            // Aligned with the first line of the title rather than centred on the whole row, so a
            // long path on the second line does not push the dot away from the name it belongs to.
            DeckStatusDot(session.status, modifier = Modifier.padding(top = 7.dp))
            Spacer(Modifier.width(Space.x3))

            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = session.title,
                        style = DeckType.rowTitle,
                        color = colors.primary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (pinned) {
                        Spacer(Modifier.width(Space.x15))
                        Icon(
                            Icons.Filled.PushPin,
                            contentDescription = "Pinned",
                            tint = colors.accent,
                            modifier = Modifier.size(13.dp),
                        )
                    }
                }
                Spacer(Modifier.height(Space.x15))
                Text(
                    text = session.cwd,
                    style = DeckType.mono,
                    color = colors.faint,
                    maxLines = 1,
                    // Tail-truncated, and it is the wrong end: what matters in a path is the folder
                    // at the end, not the `/Users/…` every row shares. Compose gained
                    // `TextOverflow.StartEllipsis` in 1.8 and this build is on an older BOM, so it
                    // is noted rather than faked — a hand-rolled head-truncation would need a text
                    // measurement pass per row in a lazy list to be correct at any width.
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(Space.x2))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    DeckTag(session.provider)
                    Spacer(Modifier.width(Space.x2))
                    Text(
                        // `status` is free-form on the wire, so it is shown rather than mapped. A
                        // phone that renders an unrecognised status as "unknown" is worse than one
                        // that renders the word the desktop actually sent. When the socket is down
                        // the word is qualified rather than dropped: it was true when it arrived.
                        text = buildString {
                            append(session.status)
                            session.exitCode?.let { append(" · exit $it") }
                            if (!live) append(" · as of the last connection")
                        },
                        style = DeckType.caption,
                        color = statusColor(session),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            if (onClose != null) {
                IconButton(onClick = onClose, modifier = Modifier.size(36.dp)) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = "Delete ${session.title}",
                        tint = colors.faint,
                        modifier = Modifier.size(18.dp),
                    )
                }
            } else {
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = colors.faint,
                    modifier = Modifier.padding(top = 2.dp).size(18.dp),
                )
            }

            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(
                    text = { Text("Details") },
                    onClick = { menu = false; onDetails() },
                )
                // Rename, above the shelf verbs: a name is about *this* session and goes to the
                // machine, where Pin and Archive are this phone's own bookkeeping and never leave
                // it. *"for being able to rename sessions."* Absent, not greyed, over a machine that
                // never advertised the verb — the rule every row on this menu follows.
                if (onRename != null) {
                    DropdownMenuItem(
                        text = { Text("Rename") },
                        onClick = { menu = false; onRename() },
                    )
                }
                DropdownMenuItem(
                    text = { Text(if (pinned) "Unpin" else "Pin to the top") },
                    onClick = { menu = false; onPin() },
                )
                DropdownMenuItem(
                    text = { Text("Archive") },
                    onClick = { menu = false; onArchive() },
                )
                // The same confirm the ✕ raises, wired to the same door so the two ask with one
                // amount of care — the defect a menu straight to close beside a swipe that asked
                // first would be. *"instead of saying close just say delete… they know it will go
                // away completely."* Absent, not greyed, when the machine never advertised `close`.
                if (onClose != null) {
                    DropdownMenuItem(
                        text = { Text("Delete", color = colors.critical) },
                        onClick = { menu = false; onClose() },
                    )
                }
            }
        }
    }
}

/**
 * What changed while the app was away, as one line above the list.
 *
 * The honest half of having no push service. A reconnect that lands while somebody is looking at
 * this screen is them watching the list refill, and interrupting that with four notifications is
 * worse than a sentence — so a catch-up is reported here and a live change is raised on the lock
 * screen. See `SessionAlerts`.
 *
 * It is dismissed by a tap because it is about a moment: leaving it up after it has been read would
 * make the next reconnect's line look like the same one.
 */
@Composable
private fun AwayLine(text: String?, onDismiss: () -> Unit) {
    if (text == null) return
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(DeckTheme.colors.surfaceHigh)
            .clickable(onClick = onDismiss)
            .padding(horizontal = Space.x3, vertical = Space.x2),
    ) {
        Text(
            text = text,
            style = DeckType.footnote,
            color = DeckTheme.colors.primary,
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.width(Space.x2))
        Icon(
            Icons.Filled.Close,
            contentDescription = "Dismiss",
            tint = DeckTheme.colors.faint,
            modifier = Modifier.size(16.dp),
        )
    }
}

/**
 * The colour of the status *word*, which is not always the colour of the dot.
 *
 * The dot asks `DeckColors.status` and gets the vocabulary's own answer. The word has one extra fact
 * available to it — the exit code — and a session that exited non-zero is critical whatever word
 * came with it, while one that exited cleanly is finished rather than failed. That is the only
 * divergence, and it is here rather than in the palette because an exit code is a property of this
 * client's [RemoteSessionView] and not of the colour table.
 */
@Composable
private fun statusColor(session: RemoteSessionView): Color {
    val colors = DeckTheme.colors
    return when {
        session.exitCode != null && session.exitCode != 0 -> colors.critical
        session.exitCode != null -> colors.completed
        else -> colors.status(session.status)
    }
}
