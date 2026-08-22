package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.ServerSettingsView
import dev.terminaldeck.android.protocol.ServerSettingKey
import dev.terminaldeck.android.protocol.ServerSettingWire
import dev.terminaldeck.android.protocol.ServerSettingsLabels

/**
 * The "This server" section: the two settings the machine on screen owns rather than this phone —
 * the coding tool a fresh session starts with, and whether the last layout is restored at launch.
 *
 * Transcribed from `pwa/src/server-settings.ts`. Changing one here changes the *server*, the same on
 * every device that reaches it, so the footer says so. Nothing is drawn until a `settings.state`
 * answers; while an apply is in flight both controls lock and the pressed one reads "Working…"; the
 * value shown is always the machine's own re-read from `settings.applied`, so a refused apply reverts
 * by construction, and the machine's own sentence is shown verbatim either way.
 *
 * The keys and the allowlist are [ServerSettingKey] from the protocol, so the picker cannot compose a
 * frame for a key the desktop's parser would refuse; the only thing decided here is the label for a
 * provider id, via [ServerSettingsLabels].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ServerSettingsScreen(
    view: ServerSettingsView,
    machineLabel: String,
    onBack: () -> Unit,
    onApply: (ServerSettingKey, String) -> Unit,
) {
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
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                title = {
                    Column {
                        Text("This server", style = MaterialTheme.typography.titleLarge, maxLines = 1)
                        Text(
                            text = machineLabel,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                },
            )
        },
    ) { padding ->
        val rows = view.rows
        if (rows == null) {
            Box(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentAlignment = Alignment.Center,
            ) { CircularProgressIndicator(color = MaterialTheme.colorScheme.primary) }
            return@Scaffold
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            for (row in rows) {
                // `rows` has already been filtered to known keys by the controller's merge, so
                // `known` is non-null here; the null branch is the belt-and-braces that keeps this
                // exhaustive without drawing anything for a key a future build might add.
                when (row.known) {
                    ServerSettingKey.DefaultProvider -> ProviderRow(
                        row = row,
                        busy = view.busy == ServerSettingKey.DefaultProvider,
                        onApply = { onApply(ServerSettingKey.DefaultProvider, it) },
                    )
                    ServerSettingKey.RestoreSessions -> ToggleRow(
                        row = row,
                        busy = view.busy == ServerSettingKey.RestoreSessions,
                        onApply = { onApply(ServerSettingKey.RestoreSessions, it) },
                    )
                    null -> Unit
                }
                Spacer(Modifier.height(14.dp))
            }

            view.notice?.let { notice ->
                Text(
                    text = notice.text,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (notice.ok) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                )
                Spacer(Modifier.height(10.dp))
            }

            Text(
                text = "These belong to the machine, not this phone — every device that reaches it sees the same two.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ProviderRow(row: ServerSettingWire, busy: Boolean, onApply: (String) -> Unit) {
    Column {
        Text(
            text = "Default coding tool",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.height(8.dp))
        // The ids the machine said it can start; if it sent none, the current value is still offered
        // so the control is never empty.
        val ids = row.options?.takeIf { it.isNotEmpty() } ?: listOf(row.value)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (id in ids) {
                val on = id == row.value
                ProviderChoice(
                    label = ServerSettingsLabels.provider(id),
                    selected = on,
                    // The current value and any press while busy are inert; only a different id is a
                    // real choice, matching the PWA.
                    enabled = !busy && !on,
                    onClick = { onApply(id) },
                )
            }
        }
        if (busy) {
            Spacer(Modifier.height(6.dp))
            Text("Working…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun ProviderChoice(label: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val container = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surface
    val content = if (selected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
    Text(
        text = label,
        style = MaterialTheme.typography.bodyMedium,
        color = content,
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(container)
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(8.dp))
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    )
}

@Composable
private fun ToggleRow(row: ServerSettingWire, busy: Boolean, onApply: (String) -> Unit) {
    val on = row.value == "true"
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(12.dp))
            .then(if (busy) Modifier else Modifier.clickable { onApply(if (on) "false" else "true") })
            .padding(14.dp),
    ) {
        Text(
            text = "Restore sessions at launch",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = if (busy) "Working…" else if (on) "On" else "Off",
            style = MaterialTheme.typography.bodyMedium,
            color = if (on && !busy) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
