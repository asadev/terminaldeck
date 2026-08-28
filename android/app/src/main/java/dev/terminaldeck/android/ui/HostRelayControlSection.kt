package dev.terminaldeck.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.background
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.hostcontrol.HostControlView
import dev.terminaldeck.android.protocol.HostControlWire
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * **Manage the host over the relay** — status, restart, stop — the self-contained section the server
 * page mounts when the server is a connected machine.
 *
 * ## "The relay is the network." — Asad's rule, pinned
 *
 * A server page reaches one box by two roads: an SSH address it was added with, and the relay it is
 * paired over. Asad's SSH address is a Tailscale name (`imza-pc-wsl`) that drops on its own — and
 * when it does, the SSH survey on this page reports the box as unreachable while every session on it
 * is still running over the public relay. This section is the other road: when the server is a
 * connected machine, its status and its restart/stop go over the relay, independent of whether the
 * SSH address answers.
 *
 * It is the sibling of [ConnectGitHubSection]: fed by a
 * [dev.terminaldeck.android.hostcontrol.HostControlController] (one per machine), drawn only when
 * that controller's [HostControlView] is non-null — which is exactly when the machine is connected
 * and advertised `host.control`. An older host that never learned the verb yields a null view, so
 * the page falls back to its SSH lifecycle controls, and [HostStepCard] withholds its own SSH
 * Restart/Stop row when this one is live so there are never two.
 *
 * There is no Start here on purpose: a stopped host is not connected over the relay, so bringing one
 * up stays on the SSH page.
 */
@Composable
fun HostRelayControlSection(
    view: HostControlView,
    onRestart: () -> Unit,
    onStop: () -> Unit,
) {
    val colors = DeckTheme.colors
    DeckGroup {
        Column(modifier = Modifier.padding(Space.card)) {
            Text(text = "The host, over the relay", style = DeckType.value, color = colors.primary)
            Spacer(Modifier.height(Space.x2))

            val host = view.host
            if (host != null) {
                StatusLines(host)
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(Space.x2))
                    Text(
                        text = "Reaching the host over the relay…",
                        style = DeckType.footnote,
                        color = colors.secondary,
                    )
                }
            }

            Spacer(Modifier.height(Space.x3))
            Text(
                text = "Reached over the relay, so these work even when this server's address is offline.",
                style = DeckType.footnote,
                color = colors.faint,
            )
            Spacer(Modifier.height(Space.x3))

            // His "one button to restart", over the relay this time.
            DeckPrimaryButton(label = "Restart it", onClick = onRestart, enabled = !view.busy)
            Spacer(Modifier.height(Space.x2))
            Row(verticalAlignment = Alignment.CenterVertically) {
                DeckQuietButton(label = "Stop", onClick = onStop, enabled = !view.busy)
                if (view.busy) {
                    Spacer(Modifier.width(Space.x2))
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                }
            }

            host?.note?.let { note ->
                Spacer(Modifier.height(Space.x2))
                Text(text = note, style = DeckType.footnote, color = colors.secondary)
            }
        }
    }

    // A verb this phone gave up waiting for — over the relay this usually means the host dropped the
    // socket as it acted, not that it failed. Kept outside the card like the GitHub section's.
    view.localFailure?.let { sentence ->
        DeckFootnote(text = sentence, color = colors.warning)
    }
}

@Composable
private fun StatusLines(host: HostControlWire) {
    val colors = DeckTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        // It answered over the relay, so it is running — the whole point of the card is that this is
        // true even when the SSH survey above could not say so.
        Spacer(
            Modifier
                .size(7.dp)
                .clip(CircleShape)
                .background(colors.positive)
        )
        Spacer(Modifier.width(Space.x2))
        Text(
            text = if (host.version.isBlank()) "Running" else "Running ${host.version}",
            style = DeckType.footnote,
            color = colors.secondary,
        )
    }
    Spacer(Modifier.height(Space.x1))
    Text(text = detailLine(host), style = DeckType.caption, color = colors.faint)
}

private fun detailLine(host: HostControlWire): String {
    val parts = mutableListOf<String>()
    if (host.uptimeSeconds > 0) parts.add("up for ${spell(host.uptimeSeconds)}")
    when (host.managed) {
        "systemd" -> parts.add("kept running by systemd, so a restart comes back on its own")
        "direct" -> parts.add("started directly, so a restart re-launches it")
        else -> {}
    }
    return if (parts.isEmpty()) "Reached over the relay." else parts.joinToString(" · ")
}

private fun spell(seconds: Long): String {
    val days = seconds / 86400
    if (days >= 1) return if (days == 1L) "1 day" else "$days days"
    val hours = seconds / 3600
    if (hours >= 1) return if (hours == 1L) "1 hour" else "$hours hours"
    val minutes = maxOf(1L, seconds / 60)
    return if (minutes == 1L) "1 minute" else "$minutes minutes"
}
