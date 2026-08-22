package dev.terminaldeck.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.ServerSettingsView
import dev.terminaldeck.android.protocol.ServerSettingKey
import dev.terminaldeck.android.protocol.ServerSettingWire
import dev.terminaldeck.android.protocol.ServerSettingsLabels
import dev.terminaldeck.android.ui.kit.DeckChip
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.InfoDot
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

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
 *
 * ## A section, not a screen
 *
 * It used to be a pushed screen with its own bar, reached from the switcher sheet. It is a section
 * of the Settings tab now, which is where iOS keeps it and where the two rows belong: these are
 * facts about the machine on screen, and they read as facts when they sit under the rows that name
 * that machine rather than behind one more push. The screen it replaced had exactly these controls
 * and the same sentence at the foot, one level further away.
 */
@Composable
fun ServerSettingsSection(
    view: ServerSettingsView,
    onApply: (ServerSettingKey, String) -> Unit,
) {
    val colors = DeckTheme.colors
    val rows = view.rows
    if (rows == null) {
        /*
         * A sentence, not a spinner.
         *
         * A spinner is indistinguishable from a hang, and this read is one round trip to a machine
         * that may be a continent away over a relay — so the honest thing on screen is what is being
         * waited for. The same words iOS uses, so somebody with both does not think they are looking
         * at two different states.
         */
        DeckGroup {
            Text(
                text = "Reading this machine’s settings…",
                style = DeckType.body,
                color = colors.faint,
                modifier = Modifier.padding(Space.card),
            )
        }
        return
    }

    DeckGroup {
        rows.forEachIndexed { index, row ->
            if (index > 0) DeckDivider(startIndent = Space.card)
            // `rows` has already been filtered to known keys by the controller's merge, so `known`
            // is non-null here; the null branch is the belt-and-braces that keeps this exhaustive
            // without drawing anything for a key a future build might add.
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
        }
    }

    /*
     * The machine's own sentence, verbatim, in the ink its outcome deserves — the quiet tier for a
     * confirmation and the critical one for a refusal. It sits where the footnote does so a refusal
     * does not shove the layout around; only its colour changes.
     */
    view.notice?.let { notice ->
        DeckFootnote(
            text = notice.text,
            color = if (notice.ok) colors.secondary else colors.critical,
        )
    }

    DeckFootnote(
        "These belong to the machine, not this phone — every device that reaches it sees the same two."
    )
}

/**
 * The coding tool a fresh session starts with.
 *
 * Capsule chips rather than a dropdown, because the whole list is two or three ids and a menu that
 * has to be opened to see two options is a menu that hides them. The chosen one is filled with the
 * accent; the rest are the raised surface. Wrapping, because a fourth provider on a narrow phone
 * must fall to a second line rather than clip.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ProviderRow(row: ServerSettingWire, busy: Boolean, onApply: (String) -> Unit) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.padding(horizontal = Space.card, vertical = Space.x3)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text("Default coding tool", style = DeckType.body, color = colors.primary)
            InfoDot(
                about = "the default coding tool",
                text = "Which agent this machine starts a new session with when nothing else says. " +
                    "Only the ones it can actually launch are offered — the list is the machine's, " +
                    "not this app's.",
            )
            Spacer(Modifier.weight(1f))
            if (busy) Text("Working…", style = DeckType.value, color = colors.faint)
        }
        Spacer(Modifier.height(Space.x2))
        // The ids the machine said it can start; if it sent none, the current value is still offered
        // so the control is never empty.
        val ids = row.options?.takeIf { it.isNotEmpty() } ?: listOf(row.value)
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(Space.x2),
            verticalArrangement = Arrangement.spacedBy(Space.x2),
        ) {
            for (id in ids) {
                val on = id == row.value
                DeckChip(
                    label = ServerSettingsLabels.provider(id),
                    selected = on,
                    // The current value and any press while busy are inert; only a different id is a
                    // real choice, matching the PWA.
                    enabled = !busy && !on,
                    onClick = { onApply(id) },
                )
            }
        }
    }
}

/**
 * Whether the machine restores its last layout at launch.
 *
 * A filled check rather than a `Switch`, which is the one place on this screen the reference wins
 * over the platform and it is worth saying why: a Material switch is a *pending* control — you flip
 * it and the app catches up — and this one is a **request to a machine that can refuse**. The check
 * marks the value the server just told us it holds, which is exactly what a refused apply needs to
 * be able to snap back to without the control appearing to undo itself.
 */
@Composable
private fun ToggleRow(row: ServerSettingWire, busy: Boolean, onApply: (String) -> Unit) {
    val colors = DeckTheme.colors
    val on = row.value == "true"
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .then(if (busy) Modifier else Modifier.clickable { onApply(if (on) "false" else "true") })
            .padding(horizontal = Space.card, vertical = Space.x3),
    ) {
        Text(
            text = "Restore sessions at launch",
            style = DeckType.body,
            color = colors.primary,
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.width(Space.x2))
        if (busy) {
            Text("Working…", style = DeckType.value, color = colors.faint)
        } else {
            Icon(
                imageVector = if (on) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
                contentDescription = if (on) "On" else "Off",
                tint = if (on) colors.accent else colors.faint,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}
