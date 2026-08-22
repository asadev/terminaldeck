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
import androidx.compose.foundation.layout.height
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
import dev.terminaldeck.android.transport.detail

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
 * ## Both doors are here, side by side
 *
 * A code is read off a machine somebody is standing at. A server is a machine nobody is standing at
 * — that is what makes it a server — so it has no screen to show a code on and nobody to press
 * Approve. Both ceremonies end in a row on this list, so both belong at the bottom of this list;
 * putting the server one behind an overflow menu would be hiding the only way in for the machines
 * this product is named after.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MachinesScreen(
    hosts: List<HostSummary>,
    onBack: () -> Unit,
    onSelect: (String) -> Unit,
    onRename: (String, String?) -> Unit,
    onForget: (String) -> Unit,
    onAddHost: () -> Unit,
    onAddServer: () -> Unit,
) {
    var renaming by remember { mutableStateOf<HostSummary?>(null) }
    var forgetting by remember { mutableStateOf<HostSummary?>(null) }

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
            for (host in hosts) {
                MachineRow(
                    host = host,
                    onSelect = { onSelect(host.hostId) },
                    onRename = { renaming = host },
                    onForget = { forgetting = host },
                )
            }

            Spacer(Modifier.height(6.dp))

            AddRow(
                icon = Icons.Filled.Add,
                title = "Pair another machine",
                subtitle = if (hosts.size == 1) {
                    "The one above stays paired and stays connected."
                } else {
                    "The ones above stay paired and stay connected."
                },
                onClick = onAddHost,
            )
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
    onSelect: () -> Unit,
    onRename: () -> Unit,
    onForget: () -> Unit,
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
