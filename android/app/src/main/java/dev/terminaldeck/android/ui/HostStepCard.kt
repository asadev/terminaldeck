package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.servers.HostProbe
import dev.terminaldeck.android.servers.HostRunning
import dev.terminaldeck.android.servers.ServerInstallState
import dev.terminaldeck.android.servers.ServersState
import dev.terminaldeck.android.servers.StoredServer
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * **The step right after logging in**: is the headless host on this server, and what happens next.
 *
 * ## The requirement
 *
 * > *"Right after logging in we need to have the step for checking/installing headless Terminal
 * > Deck."*
 *
 * > *"Then it checks whether the headless Terminal Deck already exists on that server. If it
 * > exists, it brings it up and asks you to connect. If it does not exist, it gives the option to
 * > install — you click, it installs, then you can connect, and disconnect if you want."*
 *
 * ## No control is drawn hopefully
 *
 * §4.1 of `SERVERS-DESIGN.md`. Install is absent when [HostProbe.whyNot] has an answer, and that
 * answer is on screen where the button would have been. Connect is absent when the host has no
 * address to dial, and [HostProbe.connectRefusal] says why. Start is absent when it is already
 * running. Nothing here is a button that would fail if pressed.
 *
 * ## Never a command to copy
 *
 * There is no `curl … | sh` on this card and there is not going to be. *"I don't want that
 * command."* The phone holds a real SSH connection to this server; if something can be installed,
 * this app installs it, watched, with the server's own output when it goes wrong.
 */
@Composable
fun HostStepCard(
    server: StoredServer,
    state: ServersState,
    /** True on the login screen, where this is a *step* somebody has just arrived at. */
    justLoggedIn: Boolean = false,
    /** True while the relay sign-in this card's Connect started is in flight. */
    connecting: Boolean = false,
    /** The relay sign-in's last refusal, when the connect is what produced it. */
    connectError: String? = null,
    /** True when this server's connect has landed and there is a machine to take away again. */
    linked: Boolean = false,
    onCheck: () -> Unit,
    onInstall: () -> Unit,
    onStartAndConnect: () -> Unit,
    onConnect: () -> Unit,
    onStop: () -> Unit,
    onDisconnect: () -> Unit,
) {
    val colors = DeckTheme.colors
    val look = state.views[server.id]?.host
    val install = state.installs[server.id] ?: ServerInstallState()
    val isWorking = state.working.contains(server.id)

    SectionCard {
        /* ----------------------------------------------------------- head -- */
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Icon(
                Icons.Filled.Inventory2,
                contentDescription = null,
                tint = colors.secondary,
                modifier = Modifier.size(15.dp),
            )
            Spacer(Modifier.width(Space.x2))
            Text(
                text = if (justLoggedIn) "Terminal Deck on this server" else "Terminal Deck",
                style = DeckType.rowTitle,
                color = colors.primary,
            )
            Spacer(Modifier.weight(1f))
            if (isWorking || install.isBusy) {
                CircularProgressIndicator(
                    strokeWidth = 2.dp,
                    color = colors.accent,
                    modifier = Modifier.size(14.dp),
                )
            }
        }

        Spacer(Modifier.height(Space.x3))

        /* ------------------------------------------------------ the line -- */
        when {
            look != null -> {
                Text(
                    text = HostProbe.line(look.host),
                    style = DeckType.footnote,
                    color = colors.secondary,
                )
                HostProbe.reachLine(look.host)?.let {
                    Spacer(Modifier.height(Space.x1))
                    Text(text = it, style = DeckType.caption, color = colors.faint)
                }
            }

            isWorking -> Text(
                text = "Looking at what is on this server.",
                style = DeckType.footnote,
                color = colors.faint,
            )

            else -> {
                Text(
                    text = "Nothing has been looked at on this server yet.",
                    style = DeckType.footnote,
                    color = colors.faint,
                )
                Spacer(Modifier.height(Space.x3))
                DeckPrimaryButton(label = "Check this server", onClick = onCheck)
            }
        }

        if (install.step != ServerInstallState.Step.IDLE) {
            Spacer(Modifier.height(Space.x3))
            Progress(install)
        }

        /* ------------------------------------------------------ controls -- */
        if (look != null) {
            val host = look.host
            Spacer(Modifier.height(Space.x4))
            when {
                !host.isInstalled -> {
                    val refusal = HostProbe.whyNot(look.room)
                    if (refusal != null) {
                        Stated(refusal)
                    } else {
                        DeckPrimaryButton(
                            label = "Install it on this server",
                            onClick = onInstall,
                            enabled = !install.isBusy && !isWorking,
                        )
                        Spacer(Modifier.height(Space.x2))
                        Text(
                            text = "It goes into your home folder on that server, needs no " +
                                "administrator access, and can be taken off again from here. " +
                                "Nothing is copied and pasted anywhere — this app runs it over the " +
                                "connection you just made.",
                            style = DeckType.caption,
                            color = colors.faint,
                        )
                    }
                }

                /*
                 * **Weighted, because `DeckQuietButton` fills its width.**
                 *
                 * Two of them in a plain `Row` is one button and a second one pushed off the right
                 * edge of the phone. Photographed: a card showing Disconnect and, at
                 * `host.running == YES`, a Stop that was simply not on screen — a control that
                 * exists, is enabled, and cannot be reached, which is §4.1's fault wearing the
                 * costume of a layout bug.
                 */
                linked -> Row(horizontalArrangement = Arrangement.spacedBy(Space.x3)) {
                    DeckQuietButton(
                        label = "Disconnect",
                        onClick = onDisconnect,
                        modifier = Modifier.weight(1f),
                    )
                    if (host.running == HostRunning.YES) {
                        DeckQuietButton(
                            label = "Stop",
                            onClick = onStop,
                            enabled = !isWorking,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }

                host.running != HostRunning.YES -> {
                    /*
                     * **Start and connect**, one button, because that is the sentence.
                     *
                     * *"If it exists, it brings it up and asks you to connect."* Two presses with a
                     * wait between them is what this was, and the wait has nothing in it for the
                     * person to decide — a host that is installed and stopped, on a screen where
                     * somebody just asked to use it, is going to be started.
                     */
                    DeckPrimaryButton(
                        label = "Start it and connect",
                        onClick = onStartAndConnect,
                        enabled = !isWorking && !connecting,
                    )
                }

                state.canConnect(server.id) -> {
                    DeckPrimaryButton(
                        label = "Connect",
                        onClick = onConnect,
                        enabled = !isWorking && !connecting,
                    )
                    if (justLoggedIn) {
                        Spacer(Modifier.height(Space.x2))
                        Text(
                            text = "Connecting signs this phone in to the host running on that " +
                                "server, so it appears in your machines and its sessions open on " +
                                "the Sessions tab.",
                            style = DeckType.caption,
                            color = colors.faint,
                        )
                    }
                    Spacer(Modifier.height(Space.x3))
                    DeckQuietButton(label = "Stop", onClick = onStop, enabled = !isWorking)
                }

                else -> {
                    /*
                     * Running, and nothing to dial yet.
                     *
                     * Almost always the few seconds a freshly started host spends reaching its
                     * relay — which is exactly the gap the "start it and connect" button lands in.
                     * So the refusal comes with a way to ask again rather than a sentence and a
                     * dead end: telling somebody to wait without giving them the button is telling
                     * them to close the app.
                     */
                    HostProbe.connectRefusal(host)?.let { Stated(it) }
                    Spacer(Modifier.height(Space.x3))
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.x3)) {
                        DeckQuietButton(
                            label = "Look again",
                            onClick = onCheck,
                            enabled = !isWorking,
                            modifier = Modifier.weight(1f),
                        )
                        DeckQuietButton(
                            label = "Stop",
                            onClick = onStop,
                            enabled = !isWorking,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }

        /* ----------------------------------------------------- connecting -- */
        if (connecting) {
            Spacer(Modifier.height(Space.x3))
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(
                    strokeWidth = 2.dp,
                    color = colors.accent,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.width(Space.x2))
                Text(
                    text = "Connecting this phone to the host.",
                    style = DeckType.caption,
                    color = colors.secondary,
                )
            }
        }
        connectError?.let {
            Spacer(Modifier.height(Space.x3))
            Text(text = it, style = DeckType.caption, color = colors.warning)
        }
        state.problems[server.id]?.let { trouble ->
            Spacer(Modifier.height(Space.x3))
            Text(text = trouble.headline, style = DeckType.footnote, color = colors.warning)
            if (trouble.advice.isNotEmpty()) {
                Text(text = trouble.advice, style = DeckType.caption, color = colors.secondary)
            }
        }
    }
}

/**
 * The install, as it happens — the finished steps, the current line, and the server's own output
 * when something goes wrong.
 *
 * The failure detail is the installer's, verbatim, never a sentence this app invents about a script
 * it did not write.
 */
@Composable
private fun ColumnScope.Progress(install: ServerInstallState) {
    val colors = DeckTheme.colors
    var showingOutput by remember { mutableStateOf(false) }

    for (line in install.done) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(
                Icons.Filled.Check,
                contentDescription = null,
                tint = colors.positive,
                modifier = Modifier.size(13.dp),
            )
            Spacer(Modifier.width(Space.x2))
            Text(text = line, style = DeckType.caption, color = colors.secondary)
        }
        Spacer(Modifier.height(Space.x2))
    }
    if (install.line.isNotEmpty()) {
        Text(
            text = install.line,
            style = DeckType.footnote,
            color = if (install.step == ServerInstallState.Step.FAILED) colors.warning else colors.primary,
        )
    }
    if (install.detail.isNotEmpty()) {
        Spacer(Modifier.height(Space.x1))
        Text(text = install.detail, style = DeckType.caption, color = colors.secondary)
    }
    if (install.output.isNotEmpty()) {
        Spacer(Modifier.height(Space.x2))
        TextButton(onClick = { showingOutput = !showingOutput }) {
            Text(
                text = if (showingOutput) "Hide what the installer said" else "What the installer said",
                style = DeckType.value,
                color = colors.accent,
            )
        }
        if (showingOutput) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 220.dp)
                    .clip(Radius.fieldShape)
                    .background(colors.sunken)
                    .verticalScroll(rememberScrollState())
                    .padding(Space.x3),
            ) {
                // The server's own words, in its own shape. A terminal's output reflowed into a
                // paragraph is unreadable, so it scrolls sideways instead.
                Row(modifier = Modifier.horizontalScroll(rememberScrollState())) {
                    Text(
                        text = install.output.takeLast(4000),
                        style = DeckType.monoSmall,
                        color = colors.secondary,
                    )
                }
            }
        }
    }
}

/**
 * A sentence shown **in place of** a control — never a dash, never an empty row, and never a button
 * that would fail if pressed.
 */
@Composable
private fun ColumnScope.Stated(text: String) {
    Text(text = text, style = DeckType.caption, color = DeckTheme.colors.secondary)
}

/**
 * Whether a Connect can be offered, asked of the state a screen already holds.
 *
 * The same question `ServerConnector.canConnect` asks, and it is here as well rather than only
 * there because a composable must be able to decide what to *draw* without calling into something
 * that can touch the credential store.
 */
private fun ServersState.canConnect(id: String): Boolean =
    views[id]?.host?.host?.address?.isNotEmpty() == true
