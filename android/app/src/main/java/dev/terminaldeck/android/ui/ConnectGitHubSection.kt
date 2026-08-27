package dev.terminaldeck.android.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import dev.terminaldeck.android.github.ConnectGitHubView
import dev.terminaldeck.android.protocol.GitHubHostWire
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * "Connect GitHub" for the **machine on screen** — the self-contained section the server/machine
 * detail page mounts.
 *
 * This is the phone half of the flip: the login lives on the machine now, and this section only
 * triggers a sign-in, shows the code, and reports the result. Nothing here ever sees a token.
 *
 * ## Mounting it
 *
 * It is fed by a [dev.terminaldeck.android.github.ConnectGitHubController], one per machine. The
 * server-page lane draws it with the controller's snapshot and wires the three verbs:
 *
 * ```
 * viewModel.uiState.value.github?.let { gh ->
 *     ConnectGitHubSection(
 *         view = gh,
 *         onConnect = viewModel::connectGitHub,
 *         onCancel = viewModel::cancelGitHub,
 *         onDisconnect = viewModel::disconnectGitHub,
 *     )
 * }
 * ```
 *
 * A null `github` view means the machine did not advertise the `github` capability — an older host,
 * or a guest — so the page draws nothing here, exactly as [ServerSettingsSection] does for a machine
 * that does not serve `settings`. The page should call `viewModel.openGitHub()` when it appears, so
 * the status is read once; the `github.changed` push keeps it fresh after that.
 *
 * ## The states, in the order they happen
 *
 *  - **Reading** — `view.host` is null: one round trip to a machine that may be a continent away, so
 *    it says what it is waiting for rather than spinning.
 *  - **Not set up** — `appConfigured` is false: the machine has no OAuth app to sign in with, so the
 *    failure is shown and there is no Connect button, only an optional link to set one up.
 *  - **Connect** — configured and not connected: one button.
 *  - **Waiting** — a device-flow sign-in is in flight: the code, a copy button, an open-in-browser
 *    button, and a Cancel. The person types the code on GitHub; the host pushes the result.
 *  - **Connected** — "Connected as @login", and a Disconnect.
 */
@Composable
fun ConnectGitHubSection(
    view: ConnectGitHubView,
    onConnect: () -> Unit,
    onCancel: () -> Unit,
    onDisconnect: () -> Unit,
) {
    val colors = DeckTheme.colors
    val host = view.host

    if (host == null) {
        // A sentence, not a spinner — the same shape [ServerSettingsSection] uses: a spinner is
        // indistinguishable from a hang, and this read is one round trip over a relay.
        DeckGroup {
            Text(
                text = "Reading this machine’s GitHub…",
                style = DeckType.body,
                color = colors.faint,
                modifier = Modifier.padding(Space.card),
            )
        }
        return
    }

    DeckGroup {
        Column(modifier = Modifier.padding(Space.card)) {
            when {
                host.pending != null -> WaitingForCode(host.pending!!, busy = view.busy, onCancel = onCancel)
                host.connected -> Connected(host, busy = view.busy, onDisconnect = onDisconnect)
                !host.appConfigured -> NotConfigured(host)
                else -> Connect(host, busy = view.busy, onConnect = onConnect)
            }
        }
    }

    // A request this phone gave up waiting for — kept separate from the machine's own [failure],
    // which is drawn beside the control it belongs to above.
    view.localFailure?.let { sentence ->
        DeckFootnote(text = sentence, color = colors.warning)
    }

    DeckFootnote(
        "This signs in the machine, not this phone. The login and the token stay on the machine; " +
            "this phone only starts it and shows the code."
    )
}

@Composable
private fun Connect(host: GitHubHostWire, busy: Boolean, onConnect: () -> Unit) {
    val colors = DeckTheme.colors
    Text(
        text = "Connect this machine to GitHub so its sessions can push and pull.",
        style = DeckType.footnote,
        color = colors.faint,
    )
    host.failure?.let {
        Spacer(Modifier.height(Space.x2))
        Text(text = it, style = DeckType.footnote, color = colors.warning)
    }
    Spacer(Modifier.height(Space.x3))
    DeckPrimaryButton(
        label = if (busy) "Starting…" else "Connect GitHub",
        onClick = onConnect,
        enabled = !busy,
    )
}

@Composable
private fun WaitingForCode(pending: dev.terminaldeck.android.protocol.GitHubPendingWire, busy: Boolean, onCancel: () -> Unit) {
    val colors = DeckTheme.colors
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current

    Text(
        text = "On GitHub, enter this code:",
        style = DeckType.footnote,
        color = colors.faint,
    )
    Spacer(Modifier.height(Space.x2))
    // Selectable and mono: it is a string a person is transcribing between two screens on one phone,
    // and mono is what this app promises for exact, countable data.
    SelectionContainer {
        Text(
            text = pending.userCode,
            style = DeckType.largeTitle.copy(
                fontFamily = FontFamily.Monospace,
                // Let out rather than tracked negative, the one string in this app a person reads a
                // character at a time.
                letterSpacing = 0.06.em,
            ),
            color = colors.primary,
        )
    }
    Spacer(Modifier.height(Space.x3))
    DeckPrimaryButton(
        label = "Open GitHub",
        onClick = {
            // The plain verification URI, never `verification_uri_complete`: the "complete" one fills
            // the code in and so grants access if the link is forwarded.
            if (pending.verificationUri.startsWith("https://")) {
                try {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(pending.verificationUri)))
                } catch (e: ActivityNotFoundException) {
                    // A phone with no browser; the code is on screen either way, so nothing useful to say.
                }
            }
        },
    )
    Spacer(Modifier.height(Space.x2))
    DeckQuietButton(
        label = "Copy code",
        onClick = { clipboard.setText(AnnotatedString(pending.userCode)) },
    )
    Spacer(Modifier.height(Space.x3))
    Row(verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(
            modifier = Modifier.width(14.dp).height(14.dp),
            strokeWidth = 2.dp,
            color = colors.accent,
        )
        Spacer(Modifier.width(Space.x2))
        Text(
            text = "Waiting for you to authorize it on GitHub…",
            style = DeckType.caption,
            color = colors.faint,
        )
    }
    Spacer(Modifier.height(Space.x2))
    DeckQuietButton(
        label = "Cancel",
        onClick = onCancel,
        enabled = !busy,
    )
}

@Composable
private fun Connected(host: GitHubHostWire, busy: Boolean, onDisconnect: () -> Unit) {
    val colors = DeckTheme.colors
    Text(
        text = "@${host.login.orEmpty()}",
        style = DeckType.monoValue.copy(fontWeight = FontWeight.Medium),
        color = colors.primary,
    )
    val subtitle = host.name?.takeIf { it.isNotBlank() }
        ?: host.source?.takeIf { it.isNotBlank() }?.let { "Signed in via $it" }
    subtitle?.let {
        Spacer(Modifier.height(Space.x1))
        Text(text = it, style = DeckType.caption, color = colors.faint)
    }
    host.failure?.let {
        Spacer(Modifier.height(Space.x2))
        Text(text = it, style = DeckType.footnote, color = colors.warning)
    }
    Spacer(Modifier.height(Space.x3))
    DeckQuietButton(
        label = if (busy) "Working…" else "Disconnect",
        onClick = onDisconnect,
        enabled = !busy,
    )
    Spacer(Modifier.height(Space.x2))
    Text(
        text = "The machine forgets the login. This does not revoke the token at GitHub.",
        style = DeckType.caption,
        color = colors.faint,
    )
}

@Composable
private fun NotConfigured(host: GitHubHostWire) {
    val colors = DeckTheme.colors
    val context = LocalContext.current
    Text(
        text = host.failure?.takeIf { it.isNotBlank() }
            ?: "This machine has no GitHub app set up to sign in with.",
        style = DeckType.footnote,
        color = colors.warning,
    )
    host.installUrl?.takeIf { it.startsWith("https://") }?.let { url ->
        Spacer(Modifier.height(Space.x3))
        DeckQuietButton(
            label = "Set it up on GitHub",
            onClick = {
                try {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                } catch (e: ActivityNotFoundException) {
                    // No browser to open; nothing useful to do about it.
                }
            },
        )
    }
}
