package dev.terminaldeck.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import dev.terminaldeck.android.servers.ServerCredentialKind
import dev.terminaldeck.android.servers.ServersState
import dev.terminaldeck.android.ui.kit.DeckDestructiveText
import dev.terminaldeck.android.ui.kit.InfoDot
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * One server, from the phone — what it is, what it is running, and the verbs that manage the host
 * on it: install, update, start, stop, connect, disconnect, remove.
 *
 * ## The order on the screen is the order he described
 *
 * > *"Then all the server-related stuff comes up… Then it checks whether the headless Terminal Deck
 * > already exists on that server. If it exists, it brings it up and asks you to connect. If it does
 * > not exist, it gives the option to install — you click, it installs, then you can connect, and
 * > disconnect if you want."*
 *
 * The host card is first because it is the thing with buttons on it and the reason somebody opened
 * this page. It is the *same* [HostStepCard] the login screen draws — install, update, start,
 * connect, disconnect and remove are written once, not twice, so the two screens cannot drift into
 * disagreeing about what a server can do. The login screen passes `justLoggedIn`, which changes the
 * lead-in sentence and hides the destructive Remove; this page leaves it off, so Remove is here and
 * only here, one tap from Forget, the way the desktop keeps them.
 *
 * ## Why there is no "what is running" panel like iOS
 *
 * The phone asks a server **one** probe — is the host on it, and could it be — not the desktop's
 * second survey of services, listeners and containers. This app has no screen for that panel, and
 * shipping the probe so nothing reads it would be a script to keep in step for a feature that does
 * not exist. So this page is the host, the sign-in it is reached by, and the way to forget it —
 * every fact on it read in the one round trip the card already makes.
 *
 * ## Nothing here polls
 *
 * The card measures when it is opened and again when a Check is pressed. A live page would be a
 * timer per server, which the standing rule bans — so what is drawn is stamped with when it was
 * measured, and the age is shown rather than hidden.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ServerDetailScreen(
    serverId: String,
    state: ServersState,
    /** The machines this phone is paired with, so a connected server can say "connected". */
    pairedHostIds: Set<String>,
    now: () -> Long = System::currentTimeMillis,
    onBack: () -> Unit,
    onCheck: () -> Unit,
    onInstall: () -> Unit,
    onStartAndConnect: () -> Unit,
    onConnect: () -> Unit,
    onStop: () -> Unit,
    onDisconnect: () -> Unit,
    onRemove: (alsoData: Boolean) -> Unit,
    onRename: (String) -> Unit,
    onForget: () -> Unit,
) {
    val colors = DeckTheme.colors
    val server = state.servers.firstOrNull { it.id == serverId }
    var renaming by remember { mutableStateOf(false) }
    var forgetting by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = colors.background,
                    titleContentColor = colors.primary,
                ),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back to machines",
                            tint = colors.primary,
                        )
                    }
                },
                title = {
                    Text(server?.name ?: "Server", style = MaterialTheme.typography.titleMedium)
                },
                actions = {
                    /*
                     * Rename, which the connector could already do and the app offered nowhere — so
                     * the name a server was given at the login screen was the name it kept forever.
                     * *"I am not able to edit the name of this account… I should be able to edit the
                     * account, delete and add."* Delete is the row at the bottom, add is the login
                     * screen; this is the third.
                     */
                    if (server != null) {
                        IconButton(onClick = { renaming = true }) {
                            Icon(Icons.Filled.Edit, contentDescription = "Rename", tint = colors.primary)
                        }
                    }
                },
            )
        },
    ) { padding ->
        if (server == null) {
            // Forgotten from here, or from another surface sharing this connector, while its page was
            // open. A true thing to say rather than a screen of blanks.
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(Space.screen),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "This server is not on this phone any more.",
                    style = DeckType.body,
                    color = colors.secondary,
                )
            }
            return@Scaffold
        }

        val linked = server.linkedHostId?.let { it in pairedHostIds } == true

        Column(
            verticalArrangement = Arrangement.spacedBy(Space.x4),
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .padding(top = Space.x3, bottom = Space.x8),
        ) {
            /*
             * One line, not two. The address is already in the bar above; what is left is the line
             * somebody would actually type — `root@host`, with the port when it is not 22.
             */
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = "${server.username}@${server.where}",
                    style = DeckType.mono,
                    color = colors.secondary,
                )
                server.hostKey?.let { key ->
                    InfoDot(
                        about = "this server's identity",
                        text = "It proved itself with ${key.algorithm} ${key.fingerprint}. Every " +
                            "connection is checked against that, and a server answering with a " +
                            "different key is refused before your password is offered.",
                    )
                }
            }

            HostStepCard(
                server = server,
                state = state,
                justLoggedIn = false,
                // The relay connect this card starts runs through the same sign-in the login screen
                // uses; its in-flight spinner belongs to that flow. Here the card's own working
                // spinner covers install, start, stop and remove, and a landed connect redraws this
                // into Disconnect.
                connecting = false,
                connectError = null,
                linked = linked,
                onCheck = onCheck,
                onInstall = onInstall,
                onUpdate = onInstall,
                onStartAndConnect = onStartAndConnect,
                onConnect = onConnect,
                onStop = onStop,
                onDisconnect = onDisconnect,
                onRemove = onRemove,
            )

            /*
             * How this phone gets back in — the true statement the Face-ID switch used to sit on
             * top of. The sign-in is in this phone's Keystore, marked to this device and sent to
             * nothing but that machine.
             */
            SectionCard {
                Text(text = "Getting back in", style = DeckType.rowTitle, color = colors.primary)
                Spacer(Modifier.height(Space.x1))
                Text(
                    text = if (server.credential == ServerCredentialKind.KEY) {
                        "This phone holds a private key for ${server.username}@${server.address}, in " +
                            "the Keystore."
                    } else {
                        "This phone holds the password for ${server.username}@${server.address}, in " +
                            "the Keystore."
                    },
                    style = DeckType.caption,
                    color = colors.secondary,
                )
            }

            state.views[serverId]?.let { view ->
                Text(
                    text = "Measured ${ago(view.measuredAt, now())}. Nothing here refreshes on its " +
                        "own — press Check to look again.",
                    style = DeckType.caption,
                    color = colors.faint,
                )
            }

            /*
             * Forget, the other destructive thing on this page and a tap from Remove above. Remove
             * takes the host off that server; this takes only this phone's record of it — the two
             * are the same kind of act on two different things, which is why they read alike and sit
             * together. Nothing on that server changes.
             */
            DeckDestructiveText(
                label = "Forget this server",
                onClick = { forgetting = true },
            )
        }
    }

    if (renaming && server != null) {
        RenameServerDialog(
            current = server.name,
            onDone = { name ->
                renaming = false
                onRename(name)
            },
            onCancel = { renaming = false },
        )
    }

    if (forgetting && server != null) {
        ForgetServerDialog(
            name = server.name,
            onConfirm = {
                forgetting = false
                onForget()
            },
            onCancel = { forgetting = false },
        )
    }
}

/**
 * Rename the server on this phone. The name is this phone's label — nothing on the server reads it,
 * which is not obvious and so is said. The connector caps it and refuses an empty one.
 */
@Composable
private fun RenameServerDialog(current: String, onDone: (String) -> Unit, onCancel: () -> Unit) {
    var name by remember { mutableStateOf(current) }
    AlertDialog(
        onDismissRequest = onCancel,
        containerColor = MaterialTheme.colorScheme.surface,
        title = { Text("Rename this server") },
        text = {
            Column {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    singleLine = true,
                    label = { Text("Name") },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = MaterialTheme.colorScheme.onSurface,
                        unfocusedTextColor = MaterialTheme.colorScheme.onSurface,
                        focusedBorderColor = MaterialTheme.colorScheme.primary,
                        unfocusedBorderColor = MaterialTheme.colorScheme.outline,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(Space.x2))
                Text(
                    text = "This is the name on this phone. Nothing on the server changes.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onDone(name.trim()) }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}

/**
 * Forgetting a server is destructive on this phone and says what it costs before it happens: nothing
 * on that server changes, this phone stops holding its address and its sign-in.
 */
@Composable
private fun ForgetServerDialog(name: String, onConfirm: () -> Unit, onCancel: () -> Unit) {
    AlertDialog(
        onDismissRequest = onCancel,
        containerColor = MaterialTheme.colorScheme.surface,
        title = { Text("Forget $name?") },
        text = {
            Text(
                text = "Nothing on that server changes. This phone stops holding its address and " +
                    "its sign-in.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text("Forget it", color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text("Keep it") } },
    )
}

/**
 * A coarse "how long ago", computed once at composition rather than ticked by a timer — the same
 * events-not-polling rule the rest of this feature is built on. Good enough to tell "just now" from
 * "an hour ago", which is all the age of a one-shot measurement has to convey.
 */
private fun ago(at: Long, now: Long): String {
    val seconds = ((now - at) / 1000).toInt().coerceAtLeast(0)
    if (seconds < 60) return "just now"
    val minutes = seconds / 60
    if (minutes < 60) return if (minutes == 1) "1 minute ago" else "$minutes minutes ago"
    val hours = minutes / 60
    if (hours < 24) return if (hours == 1) "1 hour ago" else "$hours hours ago"
    val days = hours / 24
    return if (days == 1) "1 day ago" else "$days days ago"
}
