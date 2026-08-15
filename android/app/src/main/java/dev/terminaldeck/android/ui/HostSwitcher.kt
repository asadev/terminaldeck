package dev.terminaldeck.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.HostSummary
import dev.terminaldeck.android.transport.TransportState
import dev.terminaldeck.android.transport.detail

/**
 * Every machine this phone is paired with, and the four things that can be done to one.
 *
 * ## Why it is a list of live machines rather than a picker
 *
 * The reason to pair a phone with two computers is to know which of them is busy without walking to
 * either. So every row carries that machine's *own* connection — green only when its socket is up
 * right now, and the machine's own sentence underneath when it is not — rather than the app's. All
 * of them are connected all of the time, which is what makes those dots mean anything and what makes
 * tapping one instant instead of a handshake.
 *
 * A session count appears only while the machine is live. A number left over from the last
 * connection under a green dot would be the one thing this sheet exists to show, being wrong.
 *
 * ## Why one machine still opens it
 *
 * It is not a picker — it is where machines are managed. With one paired there is nothing to switch
 * to, but renaming it, forgetting it and adding a second are all here and nowhere else, so a sheet
 * that hid itself below two machines would leave the first user with no way to reach any of them.
 */
@Composable
fun HostSwitcherSheet(
    hosts: List<HostSummary>,
    onSelect: (String) -> Unit,
    onRename: (String, String?) -> Unit,
    onForget: (String) -> Unit,
    onAddHost: () -> Unit,
    onDismiss: () -> Unit,
) {
    var renaming by remember { mutableStateOf<HostSummary?>(null) }
    var forgetting by remember { mutableStateOf<HostSummary?>(null) }
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }

    BackHandler(onBack = onDismiss)

    /*
     * Drawn inside this composition rather than as a `ModalBottomSheet`.
     *
     * `ModalBottomSheet` puts the sheet in its own window, and that window takes its system-bar
     * appearance from the *system* light/dark setting rather than from this app's theme — so on a
     * phone set to light, opening the switcher painted a white navigation bar under an all-black
     * app. That is the same trap `MainActivity` already sidesteps by declaring both bars dark
     * explicitly, and a second window is the one place that declaration does not reach.
     *
     * There is no second window here, so there is nothing to re-theme: the scrim and the sheet are
     * ordinary composables above the screen that opened them.
     */
    Box(modifier = Modifier.fillMaxSize()) {
        AnimatedVisibility(visible = shown, enter = fadeIn(), exit = fadeOut()) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(SCRIM)
                    // Tapping away closes it. No ripple: the scrim is a way out, not a control.
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onDismiss,
                    )
            )
        }

        AnimatedVisibility(
            visible = shown,
            enter = slideInVertically(initialOffsetY = { it }),
            exit = slideOutVertically(targetOffsetY = { it }),
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                    .background(MaterialTheme.colorScheme.surface)
                    // Swallows the taps the scrim would otherwise catch and close on.
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = {},
                    )
                    .verticalScroll(rememberScrollState())
                    .navigationBarsPadding()
                    .padding(top = 10.dp, bottom = 12.dp),
            ) {
                // The grab handle. Decorative, and the sheet says so — it is not draggable, and a
                // handle that looked draggable and was not would be a lie about an affordance.
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterHorizontally)
                        .padding(bottom = 14.dp)
                        .size(width = 32.dp, height = 4.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(MaterialTheme.colorScheme.outline)
                )

                Text(
                    text = if (hosts.size > 1) "Your machines" else "Your machine",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 10.dp),
                )

                for (host in hosts) {
                    HostRow(
                        host = host,
                        onClick = {
                            onSelect(host.hostId)
                            onDismiss()
                        },
                        onRename = { renaming = host },
                        onForget = { forgetting = host },
                    )
                }

                HorizontalDivider(
                    color = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                )

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp)
                        .clickable {
                            onDismiss()
                            onAddHost()
                        }
                        .padding(horizontal = 20.dp, vertical = 12.dp),
                ) {
                    Icon(
                        Icons.Filled.Add,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(20.dp),
                    )
                    Spacer(Modifier.width(14.dp))
                    Column {
                        Text(
                            text = "Pair another machine",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        // Said here because it is the sentence that stops somebody worrying about it.
                        Text(
                            text = if (hosts.size == 1) {
                                "The one above stays paired and stays connected."
                            } else {
                                "The ones above stay paired and stay connected."
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
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
private fun HostRow(
    host: HostSummary,
    onClick: () -> Unit,
    onRename: () -> Unit,
    onForget: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val tint = connectionTint(host.connection)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clickable(onClick = onClick)
            .background(
                if (host.selected) MaterialTheme.colorScheme.surfaceVariant else Color.Transparent
            )
            .padding(start = 20.dp, end = 8.dp, top = 10.dp, bottom = 10.dp),
    ) {
        Box(modifier = Modifier.size(9.dp).clip(CircleShape).background(tint))
        Spacer(Modifier.width(14.dp))

        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = host.label,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                // Only while the machine is saying so. See the note on HostSummary.sessionCount.
                host.sessionCount?.let { count ->
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = if (count == 1) "1 session" else "$count sessions",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        // Outlined rather than filled. The selected row is already tinted with
                        // `surfaceVariant`, so a chip filled with it vanished into exactly the row
                        // whose session count matters most.
                        modifier = Modifier
                            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(6.dp))
                            .padding(horizontal = 7.dp, vertical = 3.dp),
                    )
                }
            }
            Spacer(Modifier.height(3.dp))
            Text(
                text = host.connection.detail,
                style = MaterialTheme.typography.bodySmall,
                color = tint,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            // The id, because two machines with no nickname are otherwise six characters that look
            // the same, and this is the string the desktop shows next to its own pairing code.
            Text(
                text = host.hostId,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        if (host.selected) {
            Icon(
                Icons.Filled.Check,
                contentDescription = "On screen",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp),
            )
        }

        Box {
            IconButton(onClick = { menu = true }) {
                Icon(
                    Icons.Filled.MoreVert,
                    contentDescription = "More for ${host.label}",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(
                    text = { Text(if (host.nickname == null) "Name this machine" else "Rename") },
                    onClick = {
                        menu = false
                        onRename()
                    },
                )
                DropdownMenuItem(
                    text = { Text("Forget", color = MaterialTheme.colorScheme.error) },
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
 * Give a machine a name.
 *
 * The whole of why this exists: a host id is 26 characters of base32 and the relay address is the
 * same for every machine behind that relay, so neither is something a person can pick their laptop
 * out of a list by — and picking the right machine out of a list is the whole of multi-host.
 */
@Composable
private fun RenameDialog(host: HostSummary, onDone: (String?) -> Unit, onCancel: () -> Unit) {
    var name by remember(host.hostId) { mutableStateOf(host.nickname.orEmpty()) }

    AlertDialog(
        onDismissRequest = onCancel,
        containerColor = MaterialTheme.colorScheme.surface,
        title = { Text("Name this machine") },
        text = {
            Column {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    singleLine = true,
                    label = { Text("Name") },
                    // Two examples, and the second one is the point: the list this names routinely
                    // holds a Mac and a Windows PC at once, and a placeholder offering only the one
                    // is the same small untruth as a screen that calls every machine a Mac.
                    placeholder = { Text("Studio Mac, Work PC…") },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = MaterialTheme.colorScheme.onSurface,
                        unfocusedTextColor = MaterialTheme.colorScheme.onSurface,
                        focusedBorderColor = MaterialTheme.colorScheme.primary,
                        unfocusedBorderColor = MaterialTheme.colorScheme.outline,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    text = "Only on this phone. Clearing it goes back to ${host.hostId.take(6)}.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onDone(name.trim().ifEmpty { null }) }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}

/**
 * Forgetting is destructive and asks first.
 *
 * It says what it costs — a new pairing code, from that machine — because the alternative reading of
 * "Forget" is "hide it from this list", and somebody who thinks that is what they are doing finds
 * out otherwise standing in a different room from the computer.
 */
@Composable
private fun ForgetDialog(
    host: HostSummary,
    lastOne: Boolean,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onCancel,
        containerColor = MaterialTheme.colorScheme.surface,
        title = { Text("Forget ${host.label}?") },
        text = {
            Text(
                text = buildString {
                    append("This phone will need a new pairing code from that machine to connect again.")
                    if (!lastOne) append(" Your other machines are not affected.")
                    append(" Nothing running on it is stopped.")
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text("Forget", color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text("Keep") } },
    )
}

/**
 * The one place a connection state becomes a colour.
 *
 * Shared by the switcher's dots and the session list's banner so the two cannot disagree about what
 * green means — which they would, being written a week apart.
 */
/** Dark enough to say "the thing behind this is not the thing to touch", light enough to see it. */
private val SCRIM = Color(0xB3000000)

@Composable
fun connectionTint(state: TransportState): Color = when (state) {
    is TransportState.Online -> MaterialTheme.colorScheme.primary
    is TransportState.Connecting, is TransportState.Pending -> MaterialTheme.colorScheme.secondary
    is TransportState.Waiting,
    is TransportState.Rejected,
    is TransportState.Incompatible,
    -> MaterialTheme.colorScheme.error
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}
