package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.filled.Web
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.DeckUiState
import dev.terminaldeck.android.protocol.ServerSettingKey
import dev.terminaldeck.android.store.TerminalTextSize

/**
 * Settings: the machines, the phone's own account, what this machine owns, and how the terminal is
 * drawn.
 *
 * The Android half of the change iOS made when the app stopped being one list with a `…` in the
 * corner. Everything that is not a session — the machine you are typing into, the device roster, the
 * GitHub account, the browser windows that can be watched, the terminal's text size — used to be
 * behind the switcher sheet, which is where features go to be undiscovered. This is the same
 * inventory, in the same order, on the same second tab.
 *
 * ## Why Machines is pushed from here rather than being a tab
 *
 * *"maybe this machines thing can go inside the settings this page overall… Here we can have a
 * section, we click and we reach to this page and we can connect."* Pairing a machine is done once;
 * a bottom tab is for the screens somebody moves between all day. The switcher in the session
 * list's title stays, because *which machine am I typing into* is worth one tap — and it is now
 * only that, with the management verbs here.
 *
 * ## What is not on this screen
 *
 * **Alerts.** iOS has a row here for notification permission and the two kinds worth interrupting
 * for. This build has no notification permission, no channel and no delivery, so the row would be a
 * switch wired to nothing — the one thing the design brief refuses. **Theme.** iOS offers
 * system/light/dark; this app is dark whatever the system says, deliberately, so a picker with one
 * position is furniture. Both are gaps rather than decisions to differ, and both are named out loud
 * rather than quietly missing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    state: DeckUiState,
    onMachines: () -> Unit,
    onDevices: () -> Unit,
    onWatch: () -> Unit,
    onGitHub: () -> Unit,
    onApplyServerSetting: (ServerSettingKey, String) -> Unit,
) {
    val context = LocalContext.current
    var textSize by remember { mutableIntStateOf(TerminalTextSize.load(context)) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                    titleContentColor = MaterialTheme.colorScheme.onBackground,
                ),
                title = { Text("Settings", style = MaterialTheme.typography.titleMedium) },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(top = 12.dp, bottom = 28.dp),
        ) {
            SettingsGroup {
                SettingsRow(
                    title = "Machines",
                    value = if (state.hosts.size == 1) "1 paired" else "${state.hosts.size} paired",
                    icon = Icons.Filled.Computer,
                    onClick = onMachines,
                )
                // Devices and Watch act on the machine on screen, so each is drawn only when that
                // machine advertised the capability behind it. An older machine, or a guest, sees
                // neither — exactly the screen it had before, not a row explaining a gap.
                state.devices?.let { devices ->
                    SettingsDivider()
                    SettingsRow(
                        title = "Devices",
                        value = devices.rows?.size?.let { count ->
                            if (count == 1) "1 device" else "$count devices"
                        } ?: "",
                        icon = Icons.Filled.PhoneAndroid,
                        onClick = onDevices,
                    )
                }
                state.watch?.let {
                    SettingsDivider()
                    SettingsRow(
                        title = "Watch browser",
                        value = "",
                        icon = Icons.Filled.Web,
                        onClick = onWatch,
                    )
                }
                SettingsDivider()
                SettingsRow(
                    title = "GitHub",
                    // "Not connected" is said plainly rather than left blank: a row with no second
                    // line reads as a feature with nothing behind it.
                    value = state.gitHubAccount?.let { "@${it.login}" } ?: "Not connected",
                    valueIsData = state.gitHubAccount != null,
                    icon = Icons.Filled.Person,
                    onClick = onGitHub,
                )
            }

            state.serverSettings?.let { settings ->
                SectionCaption("This server")
                ServerSettingsSection(view = settings, onApply = onApplyServerSetting)
            }

            SectionCaption("Terminal")
            SettingsGroup {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
                ) {
                    Icon(
                        Icons.Filled.TextFields,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(12.dp))
                    Text(
                        text = "Text size",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = TerminalTextSize.label(textSize),
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    IconButton(
                        enabled = TerminalTextSize.canGoSmaller(textSize),
                        onClick = {
                            textSize = TerminalTextSize.smaller(textSize)
                            TerminalTextSize.save(context, textSize)
                        },
                    ) {
                        Icon(Icons.Filled.Remove, contentDescription = "Smaller terminal text")
                    }
                    IconButton(
                        enabled = TerminalTextSize.canGoLarger(textSize),
                        onClick = {
                            textSize = TerminalTextSize.larger(textSize)
                            TerminalTextSize.save(context, textSize)
                        },
                    ) {
                        Icon(Icons.Filled.Add, contentDescription = "Bigger terminal text")
                    }
                }
            }
            Caption(
                "A session already open picks this up the next time you open it — the column count " +
                    "is the font, so changing it resizes the session on the machine."
            )

            SectionCaption("About")
            SettingsGroup {
                AboutRow(
                    icon = Icons.Filled.Info,
                    title = "Terminal Deck",
                    value = state.clientVersion,
                )
                if (state.hostAppVersion.isNotEmpty()) {
                    SettingsDivider()
                    AboutRow(
                        icon = if (state.hostKind == "headless") Icons.Filled.Dns else Icons.Filled.Computer,
                        title = "This ${state.machineNoun}",
                        value = state.hostAppVersion,
                    )
                }
            }
            // Only when this app is genuinely ahead of the machine — default-closed in
            // [DeckUiState.serverBehindSentence]. No button: the wire carries no update verb, so
            // this is a fact, not an action.
            state.serverBehindSentence?.let { Caption(it) }
            Caption(
                "This phone talks to your own machines. There is no notification server in " +
                    "Terminal Deck, so a phone that has been asleep is caught up the next time it " +
                    "connects rather than woken."
            )
        }
    }
}

/* -------------------------------------------------------------------------- */
/* The small pieces every settings row is made of                             */
/* -------------------------------------------------------------------------- */

@Composable
private fun SettingsGroup(content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(12.dp)),
    ) { content() }
}

@Composable
private fun SettingsDivider() {
    HorizontalDivider(
        color = MaterialTheme.colorScheme.outline,
        modifier = Modifier.padding(start = 46.dp),
    )
}

@Composable
private fun SectionCaption(text: String) {
    Text(
        text = text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = 22.dp, bottom = 8.dp),
    )
}

/** A sentence under a group. Never the error colour — none of these is a fault being raised. */
@Composable
private fun Caption(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp).padding(top = 8.dp),
    )
}

/**
 * One row that leads somewhere.
 *
 * The whole row is the control, not the chevron: a title with an arrow next to it that only responds
 * on the arrow is a target the width of a fingernail.
 */
@Composable
private fun SettingsRow(
    title: String,
    value: String,
    icon: ImageVector,
    valueIsData: Boolean = false,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        if (value.isNotEmpty()) {
            Text(
                text = value,
                style = MaterialTheme.typography.bodySmall,
                // Mono for a login, because a login is data — a thing somebody checks character by
                // character — and not for a count, which is a sentence.
                fontFamily = if (valueIsData) FontFamily.Monospace else null,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.width(6.dp))
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
    }
}

/** A row that states a fact and leads nowhere, so it is not clickable and has no chevron. */
@Composable
private fun AboutRow(icon: ImageVector, title: String, value: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp, vertical = 13.dp),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
