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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
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
import dev.terminaldeck.android.servers.HostOnServer
import dev.terminaldeck.android.servers.HostProbe
import dev.terminaldeck.android.servers.HostRunning
import dev.terminaldeck.android.servers.ServerInstallState
import dev.terminaldeck.android.servers.ServersState
import dev.terminaldeck.android.servers.StoredServer
import dev.terminaldeck.android.ui.kit.DeckDestructiveText
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
    /**
     * Put this app's own build on a server that is behind it. The same verb Install is — it stages
     * the release tarball over the open session and re-surveys — so update and install cannot drift
     * into two answers about what version a server ends up on.
     */
    onUpdate: () -> Unit,
    onStartAndConnect: () -> Unit,
    onConnect: () -> Unit,
    onStop: () -> Unit,
    /**
     * Bring the host up without pairing this phone — the standalone "open" of the lifecycle row, as
     * distinct from [onStartAndConnect]'s start-and-pair. Only ever called from a server's own page.
     */
    onStart: () -> Unit = {},
    /**
     * Restart the host over SSH against its systemd user unit — his "one button to restart", which
     * also *activates* a stopped or unitless host. Only ever called from a server's own page.
     */
    onRestart: () -> Unit = {},
    onDisconnect: () -> Unit,
    /**
     * Take the host off that server. The boolean is the second of the two answers the confirmation
     * offers — whether what the host stored on that server (the devices paired to it) goes too. Only
     * ever called from a server's own page, never the fresh-login step; see the gate below.
     */
    onRemove: (alsoData: Boolean) -> Unit = {},
) {
    val colors = DeckTheme.colors
    val look = state.views[server.id]?.host
    val install = state.installs[server.id] ?: ServerInstallState()
    val isWorking = state.working.contains(server.id)
    // The remove sheet. `false` is the only state anything else can put it in.
    var confirmingRemove by remember { mutableStateOf(false) }

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

            /*
             * **Update**, wherever the host is installed and behind.
             *
             * > *"whenever there is a new update for headless… it should show the update button also
             * > next to where we install and we can see we installed it… so we can just directly
             * > update anytime directly from the connected device."*
             *
             * Drawn above the branch below rather than inside one of its arms, and that placement is
             * the requirement rather than a layout choice: a host can be behind while stopped, while
             * running, while connected and while refusing, and an Update that only appeared in one of
             * those is the dead end this replaces. It runs the same verb Install does — silent when
             * level or ahead, see [HostProbe.updateAvailable].
             */
            val updateTo = HostProbe.updateAvailable(host, state.appVersion)
            if (updateTo != null) {
                DeckPrimaryButton(
                    label = "Update it to $updateTo",
                    onClick = onUpdate,
                    enabled = !install.isBusy && !isWorking,
                )
                Spacer(Modifier.height(Space.x2))
                // The number it is on now, because "update" without it is a button that cannot be
                // judged. Its own version is on the line above this card; this is the other half.
                Text(
                    text = "This server is on ${host.version}. Restarting it is part of the update, " +
                        "so any session it is running ends.",
                    style = DeckType.caption,
                    color = colors.faint,
                )
                Spacer(Modifier.height(Space.x3))
            }

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
                    // Stop sits beside Disconnect only on the login step. On the server's own page
                    // the lifecycle row below owns Stop/Start/Restart, so a Stop here too would be
                    // the duplicate control §4.1 bans — two Stops a person cannot tell apart.
                    if (host.running == HostRunning.YES && justLoggedIn) {
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
                     * **Start and connect**, one button, because that is the sentence — and only on
                     * the login step.
                     *
                     * *"If it exists, it brings it up and asks you to connect."* Two presses with a
                     * wait between them is what this was, and the wait has nothing in it for the
                     * person to decide — a host that is installed and stopped, on a screen where
                     * somebody just asked to use it, is going to be started.
                     *
                     * On the server's own page it is gone: bringing the host up there is the
                     * lifecycle row's **Start** below, and **Connect** appears once it is running.
                     * Offering both a combined start-and-connect and a standalone Start would be two
                     * ways to start on one screen — the duplicate §4.1 rules out.
                     */
                    if (justLoggedIn) {
                        DeckPrimaryButton(
                            label = "Start it and connect",
                            onClick = onStartAndConnect,
                            enabled = !isWorking && !connecting,
                        )
                    }
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
                    // The server page's Stop is the lifecycle row below; only the login step's is here.
                    if (justLoggedIn) {
                        Spacer(Modifier.height(Space.x3))
                        DeckQuietButton(label = "Stop", onClick = onStop, enabled = !isWorking)
                    }
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
                    /*
                     * **The one refusal that has a button.**
                     *
                     * A host too old to print a server address is an *installed* host nothing can
                     * reach — so Install, which lives in the `!isInstalled` arm above, never drew
                     * for it, and the sentence used to send somebody to a desktop. [HostProbe
                     * .hostPackage] fetches this app's own release now, so the phone carries the
                     * newer build in the only sense that matters. `whyNot` is asked first, so a box
                     * that has since lost its compiler gets its reason rather than a button that
                     * would fail two minutes in. A relay that is off or still dialling gets no
                     * button here — installing repairs neither.
                     */
                    if (HostProbe.needsNewerBuild(host)) {
                        Spacer(Modifier.height(Space.x3))
                        val why = HostProbe.whyNot(look.room)
                        if (why != null) {
                            Stated(why)
                        } else {
                            DeckPrimaryButton(
                                label = "Install ${state.appVersion} on this server",
                                onClick = onInstall,
                                enabled = !install.isBusy && !isWorking,
                            )
                        }
                    }
                    Spacer(Modifier.height(Space.x3))
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.x3)) {
                        DeckQuietButton(
                            label = "Look again",
                            onClick = onCheck,
                            enabled = !isWorking,
                            modifier = Modifier.weight(1f),
                        )
                        // Stop is the lifecycle row's on the server page; a second here would be the
                        // duplicate §4.1 bans. Look again stays — it is a re-survey, not lifecycle.
                        if (justLoggedIn) {
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
        }

        /*
         * **Manage the host on this server** — restart, stop, start — his own words pinned:
         *
         * > "we should have one button to restart the terminal deck — if it is not automatically
         * > activated we click restart and it activates it on the server; if we want to close it we
         * > can close, if we want to open we can open. We cannot do it directly on a headless
         * > server, so we need the control here in the server page to manage whenever it is needed
         * > (heavy CPU, many browser tabs, many sessions)."
         *
         * §4.1, honestly: Restart whenever it is installed (on a stopped host it is the "activates
         * it" he described); Stop only when running; Start only when not. Each runs over SSH against
         * the systemd user unit, independent of the host's protocol version, so it works against a
         * server this app has never updated — and none silently no-ops: the header spinner turns
         * while the work is in flight and a restart that does not come back up is reported by the
         * survey after it. This is where Stop and Start live on the server's own page; the connect
         * branches shed theirs so a person never meets two of the same verb on one screen. Not on
         * the login step, which keeps its own and is not where he asked for these.
         */
        if (look != null && look.host.isInstalled && !justLoggedIn) {
            Spacer(Modifier.height(Space.x3))
            Text(
                text = "Manage the host on this server",
                style = DeckType.value,
                color = colors.secondary,
            )
            Spacer(Modifier.height(Space.x2))
            DeckPrimaryButton(label = "Restart it", onClick = onRestart, enabled = !isWorking)
            Spacer(Modifier.height(Space.x2))
            if (look.host.running == HostRunning.YES) {
                DeckQuietButton(label = "Stop", onClick = onStop, enabled = !isWorking)
            } else {
                DeckQuietButton(label = "Start", onClick = onStart, enabled = !isWorking)
            }
            Spacer(Modifier.height(Space.x2))
            Text(
                text = "A server has no screen of its own, so restart, stop and start happen here " +
                    "over the connection this phone already holds.",
                style = DeckType.caption,
                color = colors.faint,
            )
        }

        /*
         * The way back, and it is one row rather than a branch of the chain above, because "take it
         * off this server" is true of an installed host in every one of those states — running,
         * stopped, connected, or too old to dial.
         *
         * Not on the login screen. `justLoggedIn` is somebody two seconds into arriving, who asked
         * to *use* this server; a destructive control is not what that moment is for, and the
         * server's own page is one tap away and is where the desktop keeps it too.
         */
        if (look != null && look.host.isInstalled && !justLoggedIn) {
            Spacer(Modifier.height(Space.x3))
            DeckDestructiveText(
                label = HostProbe.removeLabel,
                // Faint rather than gone while something else is in flight — a removal that started
                // at the same moment as an install would be two scripts racing over one server.
                enabled = !install.isBusy && !isWorking,
                onClick = { confirmingRemove = true },
            )
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

    if (confirmingRemove && look != null) {
        RemoveHostDialog(
            host = look.host,
            onRemove = { alsoData ->
                confirmingRemove = false
                onRemove(alsoData)
            },
            onCancel = { confirmingRemove = false },
        )
    }
}

/**
 * The confirmation before a host is taken off a server, stating the consequence as the two answers
 * it actually has.
 *
 * The desktop asks this with a tick box beside a button. A phone dialog is a list of verbs, so the
 * box becomes the second verb: what the host stored on that server — the devices paired to it, the
 * folders each of them may use — is kept by one and taken by the other, and
 * [HostProbe.removeConsequence] names both before anything is pressed.
 */
@Composable
private fun RemoveHostDialog(
    host: HostOnServer,
    onRemove: (alsoData: Boolean) -> Unit,
    onCancel: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onCancel,
        containerColor = MaterialTheme.colorScheme.surface,
        title = { Text(HostProbe.removeLabel) },
        text = {
            Text(
                text = HostProbe.removeConsequence(host, alsoData = false),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        // Two destructive answers, stacked, with Keep as the dismiss — the phone shape of the
        // desktop's button-and-tickbox. The plain removal leads, because keeping what was paired is
        // what somebody replacing the host with a newer one expects.
        confirmButton = {
            Column(horizontalAlignment = Alignment.End) {
                TextButton(onClick = { onRemove(false) }) {
                    Text("Remove it", color = MaterialTheme.colorScheme.error)
                }
                TextButton(onClick = { onRemove(true) }) {
                    Text("Remove it and everything it stored", color = MaterialTheme.colorScheme.error)
                }
            }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text("Keep it") } },
    )
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
