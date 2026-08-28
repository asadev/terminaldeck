package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.HostSummary
import dev.terminaldeck.android.protocol.HostVersion
import dev.terminaldeck.android.servers.StoredServer
import dev.terminaldeck.android.transport.detail
import dev.terminaldeck.android.ui.theme.DeckTheme

/**
 * Every machine this phone is paired with, on a screen instead of in a sheet.
 *
 * The switcher in the session list's title stays — it is the fastest way to change machines while
 * looking at sessions. This is the other half: the place where a machine is *managed* rather than
 * merely chosen, which a title menu was always a bad shape for. Asad on the desktop's equivalent:
 * *"I am not able to edit the name of this account and I don't know where it belongs to… I should be
 * able to edit the account, delete and add."* Same three verbs, on the phone, in one place — and
 * pushed from Settings, exactly as on iOS.
 *
 * Every row carries what that machine is doing right now, because every host holds its socket from
 * launch whether or not it is on screen. A list of machines that could not say which of them was
 * busy would be a list of names. A session count appears only while that machine is live: a number
 * left over from the last connection under a green dot would be the one thing this screen exists to
 * show, being wrong.
 *
 * ## Two labeled lists, a door under each
 *
 * Remote machines and servers are shown as two separate lists under their own headings, exactly as
 * on iOS — *"you should have 2 separate lists of remote machines and servers… just directly inside
 * server page no need that informative page for server."* A code is read off a machine somebody is
 * standing at; a server is a machine nobody is standing at — that is what makes it a server — so it
 * has no screen to show a code on and nobody to press Approve. Each list ends in its own door: "Pair
 * another machine" under the machines, "Add a server" under the servers. Neither hides behind an
 * overflow menu — that would be hiding the only way in for the machines this product is named after.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MachinesScreen(
    hosts: List<HostSummary>,
    /** The servers this phone can log in to and manage, whether or not it has connected as one. */
    servers: List<StoredServer>,
    /** The machines this phone is paired with, so a connected server can say which of them it is. */
    pairedHostIds: Set<String>,
    onBack: () -> Unit,
    onSelect: (String) -> Unit,
    onRename: (String, String?) -> Unit,
    onForget: (String) -> Unit,
    onAddHost: () -> Unit,
    onAddServer: () -> Unit,
    onOpenServer: (String) -> Unit,
) {
    var renaming by remember { mutableStateOf<HostSummary?>(null) }
    var forgetting by remember { mutableStateOf<HostSummary?>(null) }

    // Two labeled lists, not one. His words:
    //
    //   > "you should have 2 separate lists of remote machines and servers so we wont have to click
    //   > this icon to go inside the page and then go inside server page just directly inside server
    //   > page no need that informative page for server."
    //
    // A box connected as a server is BOTH a paired machine (joined by linkedHostId) and a server.
    // It was shown in both lists for a while; that was wrong. His rule, said plainly:
    //   > "if a server is connected as a server, why keep it in remote machines too? It should be
    //   > just the server, one thing only, in the server list."
    // So the machine-half of a connected server is dropped from "Remote machines" (see
    // remoteMachines) and the box shows once, under Servers, where its lifecycle + GitHub live. Its
    // sessions are on the Sessions tab. serverByHost still maps a connected server to its host id so
    // remoteMachines can exclude it (and for the ⋯ shortcut to the server page).
    val serverByHost: Map<String, StoredServer> =
        servers.mapNotNull { server ->
            server.linkedHostId?.takeIf { it in pairedHostIds }?.let { hostId -> hostId to server }
        }.toMap()

    // Remote machines = the paired machines that are NOT already a server below.
    val remoteMachines = hosts.filter { it.hostId !in serverByHost.keys }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                    titleContentColor = MaterialTheme.colorScheme.onBackground,
                ),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back to settings",
                            tint = MaterialTheme.colorScheme.onBackground,
                        )
                    }
                },
                title = { Text("Machines", style = MaterialTheme.typography.titleMedium) },
            )
        },
    ) { padding ->
        Column(
            verticalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            // REMOTE MACHINES — the paired machines, and the door to pair another.
            SectionLabel("REMOTE MACHINES", top = 0.dp)

            for (host in remoteMachines) {
                MachineRow(
                    host = host,
                    // Non-null when this machine is also a connected server: its ⋯ menu then offers
                    // the same server page as a shortcut. That server also has its own row under
                    // "Servers" below — two doors to one page, on purpose.
                    linkedServer = serverByHost[host.hostId],
                    onSelect = { onSelect(host.hostId) },
                    onRename = { renaming = host },
                    onForget = { forgetting = host },
                    onOpenServer = onOpenServer,
                )
            }

            AddRow(
                icon = Icons.Filled.Add,
                title = "Pair another machine",
                subtitle = when {
                    remoteMachines.isEmpty() -> "Pair a machine to reach it from your phone."
                    remoteMachines.size == 1 -> "The one above stays paired and stays connected."
                    else -> "The ones above stay paired and stay connected."
                },
                onClick = onAddHost,
            )

            /*
             * SERVERS — every server this phone can sign in to, connected or not, each opening its
             * own page directly. The heading is always drawn: it labels the "Add a server" door
             * below, the way "Remote machines" labels "Pair another machine". A connected server
             * appears here as well as above — under two headings the two rows are two jobs on one
             * box, not the duplicate he objected to. See the note above serverByHost.
             */
            SectionLabel("SERVERS", top = 10.dp)

            for (server in servers) {
                ServerListRow(
                    server = server,
                    connected = server.linkedHostId?.let { it in pairedHostIds } == true,
                    onOpen = { onOpenServer(server.id) },
                )
            }

            AddRow(
                icon = Icons.Filled.Dns,
                title = "Add a server",
                // The one line on this row, and it earns it: it is the whole difference between the
                // two doors, and somebody who reads "add a server" without it will go looking for a
                // code that no server will ever show them.
                subtitle = "Sign in with the login that server already trusts. No desktop needed.",
                onClick = onAddServer,
            )

            Text(
                text = "A machine stays on this list until you forget it. Forgetting one leaves this " +
                    "phone signed out of it — the machine keeps running, and pairing again is a new code.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp),
            )
        }
    }

    renaming?.let { host ->
        RenameDialog(
            host = host,
            onDone = { name ->
                onRename(host.hostId, name)
                renaming = null
            },
            onCancel = { renaming = null },
        )
    }

    forgetting?.let { host ->
        ForgetDialog(
            host = host,
            lastOne = hosts.size == 1,
            onConfirm = {
                forgetting = null
                onForget(host.hostId)
            },
            onCancel = { forgetting = null },
        )
    }
}

@Composable
private fun MachineRow(
    host: HostSummary,
    /** Set when this machine is a server that connected — the ⋯ menu then offers its server page. */
    linkedServer: StoredServer?,
    onSelect: () -> Unit,
    onRename: () -> Unit,
    onForget: () -> Unit,
    onOpenServer: (String) -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(
                1.dp,
                if (host.selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                RoundedCornerShape(12.dp),
            )
            .clickable(onClick = onSelect)
            .padding(start = 14.dp, top = 12.dp, end = 4.dp, bottom = 12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(9.dp)
                .clip(CircleShape)
                .background(
                    // Green only while that machine's own socket is up right now. Every other state
                    // says what is actually happening, on the line below.
                    if (host.isOnline) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    }
                )
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = host.label,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = summary(host),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            HostVersion.hostVersionLine(host.appVersion, host.hostKind).takeIf { it.isNotEmpty() }?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Box {
            IconButton(onClick = { menu = true }) {
                Icon(
                    Icons.Filled.MoreVert,
                    contentDescription = "Actions for ${host.label}",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                // When this machine is a connected server, its server page no longer has its own row
                // in the list below (one box, one row), so the way to install/update/start/stop/
                // remove/forget it lives here instead.
                linkedServer?.let { server ->
                    DropdownMenuItem(
                        text = { Text("Server settings") },
                        onClick = {
                            menu = false
                            onOpenServer(server.id)
                        },
                    )
                }
                DropdownMenuItem(
                    text = { Text("Rename") },
                    onClick = {
                        menu = false
                        onRename()
                    },
                )
                DropdownMenuItem(
                    text = { Text("Forget ${host.label}", color = MaterialTheme.colorScheme.error) },
                    onClick = {
                        menu = false
                        onForget()
                    },
                )
            }
        }
    }
}

/**
 * One server on the list — a door to its own page, where install, update, start, stop and remove
 * live.
 *
 * The name leads because it is what somebody is looking for; the address under it is monospaced and
 * dimmed because it is data, and it is also the answer to *"I don't know where it belongs to"*. The
 * status line says the one thing that separates a server from a machine here: whether this phone is
 * *connected* to the host on it, as opposed to merely being able to log in and manage it. Both are
 * true of a connected server and they are not the same fact.
 */
@Composable
private fun ServerListRow(
    server: StoredServer,
    connected: Boolean,
    onOpen: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(12.dp))
            .clickable(onClick = onOpen)
            .padding(start = 14.dp, top = 12.dp, end = 8.dp, bottom = 12.dp),
    ) {
        Icon(
            Icons.Filled.Dns,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = server.name,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            // Not the address twice: a server nobody has renamed is called by its address, and
            // printing `user@<the same address>` under it is one fact on two lines. When they
            // differ, the line is the thing somebody would type.
            Text(
                text = if (server.name == server.where) {
                    "as ${server.username}"
                } else {
                    "${server.username}@${server.where}"
                },
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = if (connected) {
                    "Connected — its sessions are on the Sessions tab."
                } else {
                    "Signed in over SSH. Not connected as a machine."
                },
                style = MaterialTheme.typography.bodySmall,
                color = if (connected) DeckTheme.colors.positive else MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * What a row says about a machine.
 *
 * Sessions when it is up, because that is the number worth switching for; the machine's own
 * connection sentence when it is not, because then the session count is history.
 */
@Composable
private fun summary(host: HostSummary): String {
    if (!host.live) return host.connection.detail
    val running = host.sessions.count { it.status != "exited" }
    if (running == 0) return "nothing running"
    val working = host.sessions.count { it.status == "working" }
    val sessions = if (running == 1) "1 session" else "$running sessions"
    return if (working > 0) "$sessions, $working working" else sessions
}

/**
 * A section heading inside the list — "REMOTE MACHINES" over the machines, "SERVERS" over the
 * servers. One shape drawn twice, so the two lists cannot drift into two different-looking captions.
 * `top` is the air above it: none for the first heading, ten to part "Servers" from the "Pair another
 * machine" door above it (on top of the column's own ten-point spacing).
 */
@Composable
private fun SectionLabel(text: String, top: androidx.compose.ui.unit.Dp) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 4.dp, top = top, bottom = 2.dp),
    )
}

@Composable
private fun AddRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(14.dp))
        Column {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.primary,
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
