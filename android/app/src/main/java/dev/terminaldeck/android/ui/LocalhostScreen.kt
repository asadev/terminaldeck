package dev.terminaldeck.android.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.DevServerView
import dev.terminaldeck.android.LocalhostView
import dev.terminaldeck.android.ports.LocalhostRow
import dev.terminaldeck.android.ports.PortCatalog
import dev.terminaldeck.android.ports.PortCategory
import dev.terminaldeck.android.ports.PortRowAction
import dev.terminaldeck.android.ports.LocalhostSection
import dev.terminaldeck.android.protocol.DevServerStatus
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.kit.DeckTag
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * Everything the machine is serving, and everything it could serve, on one screen that is not a wall.
 *
 * Asad, opening the phone app: *"I can already see a big list of local hosts. So it should not be
 * like that… we need to fold it in a better way"*, and then the three things that would fix it —
 * rename them, categorise them, and *"I don't see any kind of option here to make anyone up or make
 * anyone activated"*. A transcription of `ios/TerminalDeck/Screens/LocalhostListView.swift`.
 *
 * ## 1. It is grouped, from facts
 *
 * `PortCatalog` holds the rules and the reasoning. The short version is that every group is derived
 * from something the wire carries — a process name, a proven dev-server port, this product's own
 * binary — and the three groups that are noise start folded rather than hidden.
 *
 * ## 2. Rows can be named, and naming one promotes it
 *
 * `PortBook` holds the names, on this phone, against the machine and the port. A named port is lifted
 * to the top group, which is the whole of *"we can keep some in the list and we can keep some
 * folded"* — one gesture, one meaning.
 *
 * ## 3. The dev servers are here too, and they are the Start button
 *
 * The port list can only ever say what is *already* running. A project whose server is not up is a
 * row with a Start on it, and this is the screen both halves belong on, because they answer the same
 * question. A dev server that is `ready` is joined to its own port row rather than drawn beside it.
 *
 * ## Two verbs on a port, and they are different acts
 *
 * **Open here** serves the page on this phone's own loopback through the tunnel and shows it — the
 * page in your hand. **Open on the machine** puts a tab on that machine's screen through `web.open`.
 * Both are offered because both are the right answer to different questions, and each is drawn only
 * when the machine advertised the capability behind it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LocalhostScreen(
    /** Null when this machine never advertised `localhost`. The screen then says only that. */
    view: LocalhostView?,
    devServers: DevServerView?,
    sections: List<LocalhostSection>,
    machineLabel: String,
    /** Whether a page may be served here — the tunnel half, which is `localhost` too. */
    canServeHere: Boolean,
    /**
     * Whether the machine's socket is up.
     *
     * Separate from [view] being null, because the two are different facts and only one of them is
     * about the machine: capabilities are cleared when a link is taken down, so a disconnected
     * machine and one that never offered `localhost` both arrive here with nothing — and telling
     * somebody their Mac "does not share its ports" while it is merely unreachable is the app
     * inventing a limitation.
     */
    live: Boolean,
    onRefresh: () -> Unit,
    onServeHere: (Int) -> Unit,
    onOpenOnMachine: (Int) -> Unit,
    onStartDevServer: (String) -> Unit,
    onOpenSession: (String) -> Unit,
    onCopyAddress: (Int) -> Unit,
    onRename: (Int, String?) -> Unit,
    isFolded: (PortCategory) -> Boolean,
    onFold: (PortCategory, Boolean) -> Unit,
) {
    val colors = DeckTheme.colors
    var renaming by remember { mutableStateOf<LocalhostRow?>(null) }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            DeckTopBar(
                title = "Localhost",
                subtitle = machineLabel,
                actions = {
                    if (view != null) {
                        IconButton(onClick = onRefresh) {
                            Icon(Icons.Filled.Refresh, contentDescription = "Look again", tint = colors.secondary)
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
                .padding(horizontal = Space.screen)
                .padding(top = Space.x2, bottom = Space.x10),
        ) {
            if (view == null) {
                // A named absence, not an empty list — and the *right* absence: nothing is known
                // about a machine this phone cannot reach, which is a different sentence from a
                // machine that has looked and does not share its ports.
                DeckGroup {
                    Text(
                        text = if (live) {
                            "$machineLabel does not share what is listening on it."
                        } else {
                            "Not connected to $machineLabel, so there is nothing to show yet."
                        },
                        style = DeckType.body,
                        color = colors.faint,
                        modifier = Modifier.padding(Space.card),
                    )
                }
                return@Column
            }

            if (view.ports == null && sections.isEmpty()) {
                DeckGroup {
                    Text(
                        text = "Looking at what $machineLabel is serving…",
                        style = DeckType.body,
                        color = colors.faint,
                        modifier = Modifier.padding(Space.card),
                    )
                }
                return@Column
            }

            if (sections.isEmpty()) {
                DeckGroup {
                    Text(
                        text = "Nothing is listening on $machineLabel, and none of the folders it " +
                            "shares has a dev server to start.",
                        style = DeckType.body,
                        color = colors.faint,
                        modifier = Modifier.padding(Space.card),
                    )
                }
            }

            for (section in sections) {
                val folded = isFolded(section.category)
                SectionHeader(
                    title = section.category.title,
                    count = section.rows.size,
                    folded = folded,
                    onToggle = { onFold(section.category, !folded) },
                )
                AnimatedVisibility(visible = !folded) {
                    DeckGroup {
                        section.rows.forEachIndexed { index, row ->
                            if (index > 0) DeckDivider(startIndent = Space.card)
                            PortRow(
                                row = row,
                                starting = devServers?.starting == row.dev?.folder && row.dev != null,
                                opening = view.opening == row.port,
                                canServeHere = canServeHere,
                                canOpenOnMachine = view.canOpen,
                                onServeHere = onServeHere,
                                onOpenOnMachine = onOpenOnMachine,
                                onStartDevServer = onStartDevServer,
                                onOpenSession = onOpenSession,
                                onCopyAddress = onCopyAddress,
                                onRename = { renaming = row },
                            )
                        }
                    }
                }
            }

            view.notice?.let { notice ->
                DeckFootnote(
                    text = notice.text,
                    color = if (notice.ok) colors.secondary else colors.critical,
                )
            }

            DeckFootnote(
                "Open here serves the page on this phone at the same port number the machine uses, " +
                    "so the links a dev server writes for itself keep working. Nothing is tunnelled " +
                    "until you tap, and closing the page closes the tunnel."
            )
        }
    }

    renaming?.let { row ->
        val port = row.port
        if (port == null) {
            renaming = null
        } else {
            RenamePortSheet(
                port = port,
                current = row.name,
                onSave = { name ->
                    onRename(port, name)
                    renaming = null
                },
                onDismiss = { renaming = null },
            )
        }
    }
}

/**
 * A group's header, which is also the control that folds it.
 *
 * The count is on the header rather than inside, because the whole point of a folded group is to
 * answer *how much is in there* without opening it — `Other services · 7` is the sentence that makes
 * folding safe.
 */
@Composable
private fun SectionHeader(title: String, count: Int, folded: Boolean, onToggle: () -> Unit) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(start = Space.captionIndent, top = Space.x5, bottom = Space.x2),
    ) {
        Icon(
            imageVector = if (folded) Icons.AutoMirrored.Filled.KeyboardArrowRight else Icons.Filled.KeyboardArrowDown,
            contentDescription = if (folded) "Show $title" else "Hide $title",
            tint = colors.faint,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(Space.half))
        Text(title.uppercase(), style = DeckType.overline, color = colors.faint)
        Spacer(Modifier.width(Space.x2))
        Text("$count", style = DeckType.overline, color = colors.faint)
    }
}

/**
 * One row: what it is, and the two or three things that can be done with it.
 *
 * The verbs are buttons rather than a swipe. Android has no system swipe-action on a `Column` of
 * cards, and hand-rolling one would give a gesture that is not the platform's — no rubber band, no
 * interaction with the back gesture at the left edge. A row that fits three short buttons does not
 * need a hidden gesture to reach them.
 */
@Composable
private fun PortRow(
    row: LocalhostRow,
    starting: Boolean,
    opening: Boolean,
    canServeHere: Boolean,
    canOpenOnMachine: Boolean,
    onServeHere: (Int) -> Unit,
    onOpenOnMachine: (Int) -> Unit,
    onStartDevServer: (String) -> Unit,
    onOpenSession: (String) -> Unit,
    onCopyAddress: (Int) -> Unit,
    onRename: () -> Unit,
) {
    val colors = DeckTheme.colors
    val dev = row.dev
    val port = row.port
    var menu by remember { mutableStateOf(false) }

    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = Space.card, vertical = Space.x3)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title(row),
                    style = DeckType.rowTitle,
                    color = colors.primary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(Space.half))
                Text(
                    text = subtitle(row),
                    style = DeckType.mono,
                    color = colors.faint,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (dev != null) {
                Spacer(Modifier.width(Space.x2))
                DeckTag(devWord(dev.status, starting))
            }
            /*
             * The row's overflow: name it, and copy its address.
             *
             * Copy is here rather than beside the two Open buttons because three weighted buttons on
             * a 360dp phone leave 110dp each and *"On the machine"* does not fit in that. It is worth
             * keeping: `http://localhost:3000` pasted into the machine's own terminal is the thing
             * somebody wants when neither Open is the right answer.
             */
            if (port != null) {
                Spacer(Modifier.width(Space.x1))
                Box {
                    IconButton(onClick = { menu = true }, modifier = Modifier.size(32.dp)) {
                        Icon(
                            Icons.Filled.MoreVert,
                            contentDescription = "More for port $port",
                            tint = colors.faint,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(
                            text = { Text(if (row.name == null) "Name this port" else "Rename") },
                            onClick = {
                                menu = false
                                onRename()
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Copy address") },
                            onClick = {
                                menu = false
                                onCopyAddress(port)
                            },
                        )
                    }
                }
            }
        }

        // The server's own latest output line, while it is starting. Untrusted display text — it is
        // bytes a process on the machine printed — so it is drawn as text and never parsed.
        dev?.note?.takeIf { it.isNotEmpty() && dev.status == DevServerStatus.Starting }?.let { note ->
            Spacer(Modifier.height(Space.half))
            Text(note, style = DeckType.mono, color = colors.faint, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        // Why it failed, in a sentence the machine wrote.
        dev?.message?.takeIf { dev.status == DevServerStatus.Failed }?.let { message ->
            Spacer(Modifier.height(Space.half))
            Text(message, style = DeckType.caption, color = colors.critical)
        }

        Spacer(Modifier.height(Space.x2))
        Row(horizontalArrangement = Arrangement.spacedBy(Space.x2)) {
            /*
             * The page, here. Only for a port that is genuinely answering — a dev server that is
             * `starting` has no proven port and a tunnel to a number nobody is listening on is a
             * spinner that ends in a sentence.
             */
            if (port != null && canServeHere && isServable(row)) {
                DeckQuietButton(
                    label = if (opening) "Opening…" else "Open here",
                    onClick = { onServeHere(port) },
                    enabled = !opening,
                    modifier = Modifier.weight(1f),
                )
            }
            if (port != null && canOpenOnMachine && isServable(row)) {
                DeckQuietButton(
                    label = "On the machine",
                    onClick = { onOpenOnMachine(port) },
                    enabled = !opening,
                    modifier = Modifier.weight(1f),
                )
            }
            when (val second = PortCatalog.secondAction(row)) {
                is PortRowAction.Start -> DeckQuietButton(
                    label = if (starting) "Starting…" else "Start",
                    onClick = { onStartDevServer(second.folder) },
                    enabled = !starting,
                    modifier = Modifier.weight(1f),
                )
                is PortRowAction.Retry -> DeckQuietButton(
                    label = if (starting) "Starting…" else "Try again",
                    onClick = { onStartDevServer(second.folder) },
                    enabled = !starting,
                    modifier = Modifier.weight(1f),
                )
                is PortRowAction.OpenSession -> DeckQuietButton(
                    label = "Session",
                    onClick = { onOpenSession(second.id) },
                    modifier = Modifier.weight(1f),
                )
                // Copy is in the row's overflow, where it does not compete for width with the two
                // Opens. There is nothing to draw here for a plain port.
                is PortRowAction.CopyAddress -> Unit
                PortRowAction.None -> Unit
            }
        }
    }
}

/**
 * Whether there is something on the other end to serve.
 *
 * A `ready` dev server, or a plain listening port. A `starting` or `failed` one has no proven port —
 * and offering a page for one would be exactly the thing `DevServerReport` says a client must never
 * do: put an address under a server that is not there.
 */
private fun isServable(row: LocalhostRow): Boolean =
    row.entry != null || row.dev?.status == DevServerStatus.Ready

private fun title(row: LocalhostRow): String {
    row.name?.let { return it }
    row.dev?.let { return folderName(it.folder) }
    val entry = row.entry ?: return "Port"
    return entry.process.ifEmpty { "localhost:${entry.port}" }
}

private fun subtitle(row: LocalhostRow): String {
    val port = row.port
    val bits = mutableListOf<String>()
    if (port != null) bits += "localhost:$port"
    row.entry?.process?.takeIf { it.isNotEmpty() && it != row.name }?.let { bits += it }
    row.dev?.command?.takeIf { it.isNotEmpty() }?.let { bits += it }
    if (bits.isEmpty()) row.dev?.folder?.let { bits += it }
    return bits.joinToString(" · ")
}

/** The one word a dev-server row wears. `Starting…` while this phone's own start is in flight. */
private fun devWord(status: DevServerStatus, starting: Boolean): String = when {
    starting -> "Starting"
    status == DevServerStatus.Ready -> "Ready"
    status == DevServerStatus.Starting -> "Starting"
    status == DevServerStatus.Failed -> "Failed"
    status == DevServerStatus.Idle -> "Idle"
    else -> "Unknown"
}
