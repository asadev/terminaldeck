package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.LocalhostAddress
import dev.terminaldeck.android.MachineBrowserView
import dev.terminaldeck.android.protocol.BrowserSurfaceWire
import dev.terminaldeck.android.protocol.LocalPort
import dev.terminaldeck.android.protocol.MachineWindow
import dev.terminaldeck.android.protocol.WindowSession
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckEmptyState
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.kit.DeckSegmented
import dev.terminaldeck.android.ui.kit.DeckTextField
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.FieldLabel
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.kit.DeckSheetChrome
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * The machine's browser, brought to the phone: the windows open on the machine, the tabs it says can
 * be watched, and the one pill that opens a new one.
 *
 * A port of `ios/TerminalDeck/Screens/MachineBrowserView.swift`. Reached from Settings — *Watch
 * browser* — and drawn only when the machine advertised `browser.control` or `watch`, which a host
 * offers to one of the owner's own devices and never to a guest. Tapping any row opens the driven
 * window ([MachineWindowScreen]) — verbatim, on why there is one destination and not two:
 *
 *   > *"why they are two different type… it should be the same case, or all the options should be
 *   > available at least."*
 *
 * ## One kind of thing in the list
 *
 *   > *"things should not be mixed in the list of browsing windows… we should be able just to see only
 *   > the open windows, and then we can just click on any of them… it should be smooth, simple."*
 *
 * So the list is the machine's open windows, with the watch strip's front tab (and any tab no window
 * claims) above them — and nothing else. No icon column, because *"everybody knows this is browser
 * window, these are browsers"*; no paragraph under a title, because *"I don't want any kind of long
 * descriptions anywhere"* — a row is a title, a URL, and a few capsules that say what it is.
 *
 * ## Nothing here is optimistic
 *
 * Every window verb answers with the whole list, so the screen redrawing is the confirmation and no
 * row is removed or badge drawn ahead of the machine agreeing. The one softening is [MachineBrowserView.asked],
 * a line the banner shows for a beat after an open or attach, because the effect of `browser.window.open`
 * lands a moment after the press.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MachineBrowserScreen(
    view: MachineBrowserView,
    /** The machine's watchable surfaces, from the watch capability — the front tab and any tab no
     *  window row claims are drawn above the windows. */
    surfaces: List<BrowserSurfaceWire>,
    /** The machine's listening ports, offered as tap-to-fill suggestions in the new-window sheet —
     *  *"A port is an address."* */
    ports: List<LocalPort>,
    machineLabel: String,
    live: Boolean,
    profilesOffered: Boolean,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    /** Open the driven window for a window id — or a surface's own id, `""` for the front tab. */
    onOpenWindow: (String) -> Unit,
    onNewWindow: (url: String?, isolated: Boolean, session: String?) -> Unit,
    onBind: (id: String, session: String?) -> Unit,
    onClose: (id: String) -> Unit,
    onProfiles: () -> Unit,
) {
    var showNew by remember { mutableStateOf(false) }
    var overflow by remember { mutableStateOf(false) }

    // The tabs the machine casts that no window row already names — the front tab (`""`) first, then
    // any orphaned surface. A window and a surface with the same id are one row, drawn as the window.
    val windowIds = view.windows.map { it.id }.toSet()
    val unclaimed = surfaces
        .filter { it.window !in windowIds }
        .sortedBy { if (it.window.isEmpty()) 0 else 1 }

    Scaffold(
        containerColor = DeckTheme.colors.background,
        topBar = {
            DeckTopBar(
                title = "Browser",
                subtitle = machineLabel,
                onBack = onBack,
                actions = {
                    // The pair that used to be two toolbar items, kept together — `+` on the left,
                    // `…` on the right, one cluster: *"they should stay together like before, but like
                    // both will be on right side, one pill."* The `+` is absent, not disabled, when the
                    // machine will not take a window from this phone.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = { showNew = true }) {
                            Icon(
                                Icons.Filled.Add,
                                contentDescription = "New window",
                                tint = DeckTheme.colors.accent,
                            )
                        }
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
                                    text = { Text("Refresh") },
                                    onClick = { overflow = false; onRefresh() },
                                )
                                if (profilesOffered) {
                                    DropdownMenuItem(
                                        text = { Text("Browser profiles") },
                                        onClick = { overflow = false; onProfiles() },
                                    )
                                }
                            }
                        }
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen),
        ) {
            // The optimistic line first, then the machine's own word on the last answer.
            (view.asked ?: view.notice)?.let { line ->
                Spacer(Modifier.padding(top = Space.x3))
                DeckGroup {
                    Text(
                        text = line,
                        style = DeckType.footnote,
                        color = DeckTheme.colors.secondary,
                        modifier = Modifier.padding(Space.card),
                    )
                }
            }

            if (view.windows.isEmpty() && unclaimed.isEmpty()) {
                DeckEmptyState(
                    text = if (view.loaded) {
                        "No window is open in $machineLabel's browser. Press + to open one there."
                    } else {
                        // Not the same sentence: nothing has answered yet, so "nothing open" would be
                        // a claim about a machine that has not said.
                        "Asking $machineLabel what its browser has open…"
                    },
                    modifier = Modifier.padding(top = Space.x16),
                )
            } else {
                if (unclaimed.isNotEmpty()) {
                    SectionCaption("Tabs")
                    unclaimed.forEach { surface ->
                        SurfaceCard(
                            surface = surface,
                            sessions = view.sessions,
                            onOpen = { onOpenWindow(surface.window) },
                            onAttach = { session -> onNewWindow(surface.url, false, session) },
                        )
                        Spacer(Modifier.padding(top = Space.x2))
                    }
                }

                if (view.windows.isNotEmpty()) {
                    SectionCaption("Windows")
                    view.windows.forEach { window ->
                        WindowCard(
                            window = window,
                            sessions = view.sessions,
                            live = surfaces.firstOrNull { it.window == window.id }?.live == true,
                            onOpen = { onOpenWindow(window.id) },
                            onBind = { session -> onBind(window.id, session) },
                            onClose = { onClose(window.id) },
                        )
                        Spacer(Modifier.padding(top = Space.x2))
                    }
                }

                if (view.notDrawn > 0) {
                    // A silent cut reads as "that is all of them" — so it is said.
                    DeckFootnote("${view.notDrawn} more not shown.")
                }
            }

            Spacer(Modifier.padding(top = Space.x8))
        }
    }

    if (showNew) {
        NewWindowSheet(
            ports = ports,
            onDismiss = { showNew = false },
            onOpen = { url, isolated ->
                onNewWindow(url, isolated, null)
                showNew = false
            },
        )
    }
}

/* ------------------------------------------------------------------------- rows -- */

/**
 * One window open on the machine — the whole card taps to drive it, the `…` acts on it without
 * driving, and a swipe from the right closes it.
 *
 *   > *"from the outside we can just make it archive, close, or connect to any session, or things from
 *   > three dots and all the relevant stuff."* — *"We can swipe them left and right… just like
 *   > WhatsApp."*
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WindowCard(
    window: MachineWindow,
    sessions: List<WindowSession>,
    live: Boolean,
    onOpen: () -> Unit,
    onBind: (String?) -> Unit,
    onClose: () -> Unit,
) {
    // A swipe from the right closes the window on the machine. It snaps back rather than removing the
    // row here: the list redraws from the machine's own answer, so nothing is drawn gone before it is.
    val dismiss = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) {
                onClose()
                false
            } else {
                false
            }
        }
    )
    SwipeToDismissBox(
        state = dismiss,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(Radius.groupShape)
                    .background(DeckTheme.colors.criticalFill)
                    .padding(horizontal = Space.card),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Text("Delete", style = DeckType.value, color = DeckTheme.colors.onCriticalFill)
            }
        },
    ) {
        DeckGroup {
            RowBody(
                title = window.label.ifEmpty { "Untitled" },
                url = window.url,
                onOpen = onOpen,
                menu = {
                    WindowMenu(
                        window = window,
                        sessions = sessions,
                        onBind = onBind,
                        onClose = onClose,
                    )
                },
                marks = {
                    if (window.isBound) {
                        Mark(window.slot ?: "", DeckTheme.colors.accent)
                        val owner = window.sessionTitle?.takeIf { it.isNotEmpty() } ?: window.session
                        if (!owner.isNullOrEmpty()) {
                            Text(
                                text = owner,
                                style = DeckType.caption,
                                color = DeckTheme.colors.secondary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    if (live) Mark("Live", DeckTheme.colors.positive)
                    if (window.isolated) Mark("Private", DeckTheme.colors.secondary)
                    if (window.recording) Mark("Recording", DeckTheme.colors.critical)
                },
            )
        }
    }
}

/** A tab the machine casts that no window row claims — the front tab, or an orphan. Tapping opens it;
 *  the `…` attaches it to a session by re-opening its address as a bound window (a front tab has no id
 *  to bind, so the same address is opened again and *that* window attached). */
@Composable
private fun SurfaceCard(
    surface: BrowserSurfaceWire,
    sessions: List<WindowSession>,
    onOpen: () -> Unit,
    onAttach: (String) -> Unit,
) {
    DeckGroup {
        RowBody(
            title = surface.displayTitle,
            url = surface.url,
            onOpen = onOpen,
            menu = if (surface.url.isNotEmpty() && sessions.isNotEmpty()) {
                { SurfaceMenu(sessions = sessions, onAttach = onAttach) }
            } else {
                null
            },
            marks = {
                if (surface.live) Mark("Live", DeckTheme.colors.positive)
            },
        )
    }
}

/** The shape shared by a window row and a surface row: a tappable body of title + url + marks, and a
 *  trailing `…` that is its own hit target so a menu press never opens the window by mistake. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun RowBody(
    title: String,
    url: String,
    onOpen: () -> Unit,
    menu: (@Composable () -> Unit)?,
    marks: @Composable () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 60.dp)
            .clickable(onClick = onOpen)
            .padding(start = Space.card, top = Space.x3, bottom = Space.x3, end = Space.x1),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = DeckType.rowTitle,
                color = DeckTheme.colors.primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            // The url is drawn only when it says something the title does not — a page that has named
            // itself, whose title is not just its address again.
            if (url.isNotEmpty() && url != title) {
                Text(
                    text = url,
                    style = DeckType.mono,
                    color = DeckTheme.colors.faint,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(Space.x1),
                verticalArrangement = Arrangement.spacedBy(Space.half),
                modifier = Modifier.padding(top = Space.half),
            ) {
                marks()
            }
        }
        if (menu != null) {
            menu()
        } else {
            Spacer(Modifier.width(Space.x2))
        }
    }
}

/** The `…` on a window row: attach to a session, detach, delete. Every verb real. */
@Composable
private fun WindowMenu(
    window: MachineWindow,
    sessions: List<WindowSession>,
    onBind: (String?) -> Unit,
    onClose: () -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Filled.MoreVert, contentDescription = "Window actions", tint = DeckTheme.colors.faint)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            if (sessions.isNotEmpty()) {
                // "Attach to a session" — one item per session. The `· N windows` count is what says
                // whether this becomes the session's B1 or its B4, which is choosing what the agent
                // will call it. A check on the one this window already holds.
                sessions.forEach { session ->
                    DropdownMenuItem(
                        leadingIcon = {
                            Icon(
                                if (session.id == window.session) Icons.Filled.Check else Icons.Filled.Terminal,
                                contentDescription = null,
                                tint = DeckTheme.colors.secondary,
                                modifier = Modifier.size(18.dp),
                            )
                        },
                        text = { Text(sessionRow(session)) },
                        onClick = { open = false; onBind(session.id) },
                    )
                }
            }
            if (window.isBound) {
                DropdownMenuItem(
                    text = { Text("Detach", color = DeckTheme.colors.secondary) },
                    onClick = { open = false; onBind(null) },
                )
            }
            DropdownMenuItem(
                text = { Text("Delete window", color = DeckTheme.colors.critical) },
                onClick = { open = false; onClose() },
            )
        }
    }
}

/** The `…` on a surface row: attach the tab to a session by re-opening its address as a bound window. */
@Composable
private fun SurfaceMenu(sessions: List<WindowSession>, onAttach: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Filled.MoreVert, contentDescription = "Tab actions", tint = DeckTheme.colors.faint)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            sessions.forEach { session ->
                DropdownMenuItem(
                    leadingIcon = {
                        Icon(
                            Icons.Filled.Terminal,
                            contentDescription = null,
                            tint = DeckTheme.colors.secondary,
                            modifier = Modifier.size(18.dp),
                        )
                    },
                    text = { Text(sessionRow(session)) },
                    onClick = { open = false; onAttach(session.id) },
                )
            }
        }
    }
}

/** A capsule on a row: a slot name, Live, Private, Recording. Tinted fill at low opacity, the tint's
 *  own ink — the same shape iOS draws, and the app's own way of saying a small fact on a card. */
@Composable
private fun Mark(text: String, color: androidx.compose.ui.graphics.Color) {
    if (text.isEmpty()) return
    Text(
        text = text,
        style = DeckType.monoSmall,
        color = color,
        modifier = Modifier
            .clip(Radius.small)
            .background(color.copy(alpha = 0.14f))
            .padding(horizontal = Space.x15, vertical = Space.half),
    )
}

/** A session's label with its window count — `title`, `title · 1 window`, `title · N windows`. */
private fun sessionRow(session: WindowSession): String {
    val name = session.title.ifEmpty { session.id }
    return when (session.windows) {
        0 -> name
        1 -> "$name · 1 window"
        else -> "$name · ${session.windows} windows"
    }
}

/* ----------------------------------------------------------------- new window -- */

/**
 * Open a window on the machine — a blank one, a page, a port, or a search.
 *
 *   > *"I wanted it to be like ONE page where I can start a new window."*
 *
 * The address field is the whole of it: [LocalhostAddress.classify] decides what a line is, so
 * `google.com`, `https://…`, `3000` and `what is my ip` all do the obvious thing, and the machine's
 * own listening ports sit under it as one-tap suggestions — *"A port is an address."* Private is a
 * choice made here, before the window exists, because a login typed into a window that turned out to
 * be shared is already in the machine's cookie jar by the time anybody thinks to convert it.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun NewWindowSheet(
    ports: List<LocalPort>,
    onDismiss: () -> Unit,
    onOpen: (url: String?, isolated: Boolean) -> Unit,
) {
    val colors = DeckTheme.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var address by remember { mutableStateOf("") }
    var isolated by remember { mutableStateOf(false) }
    var refused by remember { mutableStateOf<String?>(null) }

    fun go() {
        val typed = address.trim()
        if (typed.isEmpty()) {
            // A blank window opens on the machine, honouring the Private choice.
            onOpen(null, isolated)
            return
        }
        when (val classified = LocalhostAddress.classify(typed)) {
            // A port on the machine opens on the machine's own loopback — this whole screen drives the
            // machine's browser, so even a port is a page over there rather than a tunnel on the phone.
            is LocalhostAddress.Typed.Tunnel -> onOpen("http://localhost:${classified.port}${classified.path}", isolated)
            is LocalhostAddress.Typed.Page -> onOpen(classified.url, isolated)
            is LocalhostAddress.Typed.Search -> onOpen(classified.url, isolated)
            is LocalhostAddress.Typed.Refused -> refused = classified.why
        }
    }

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
                .padding(horizontal = Space.screen)
                .padding(top = Space.x5, bottom = Space.x8),
        ) {
            Text("New window", style = DeckType.title, color = colors.primary)
            Spacer(Modifier.padding(top = Space.x4))

            FieldLabel("Open in")
            DeckSegmented(
                options = listOf("Shared", "Private"),
                selectedIndex = if (isolated) 1 else 0,
                onSelect = { isolated = it == 1 },
            )

            Spacer(Modifier.padding(top = Space.x4))
            FieldLabel("Address")
            DeckTextField(
                value = address,
                onValueChange = { address = it; refused = null },
                placeholder = "Address or search",
                mono = true,
                singleLine = true,
            )
            refused?.let { why ->
                DeckFootnote(why, color = colors.warning)
            }

            if (ports.isNotEmpty()) {
                Spacer(Modifier.padding(top = Space.x3))
                FieldLabel("Listening on this machine")
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(Space.x2),
                    verticalArrangement = Arrangement.spacedBy(Space.x2),
                ) {
                    ports.forEach { port ->
                        Text(
                            text = port.port.toString(),
                            style = DeckType.monoValue,
                            color = colors.primary,
                            modifier = Modifier
                                .clip(Radius.fieldShape)
                                .background(colors.surfaceHigh)
                                .clickable { address = port.port.toString(); refused = null }
                                .padding(horizontal = Space.x3, vertical = Space.x2),
                        )
                    }
                }
            }

            Spacer(Modifier.padding(top = Space.x5))
            Row {
                DeckQuietButton(label = "Cancel", onClick = onDismiss, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(Space.x3))
                DeckPrimaryButton(label = "Open", onClick = { go() }, modifier = Modifier.weight(1f))
            }
        }
    }
}
