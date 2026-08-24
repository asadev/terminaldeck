package dev.terminaldeck.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.protocol.EnrollMethod
import dev.terminaldeck.android.servers.LoginPhase
import dev.terminaldeck.android.servers.harnessLogin
import dev.terminaldeck.android.servers.PrivateKeyReadback
import dev.terminaldeck.android.servers.ServerCredentialKind
import dev.terminaldeck.android.servers.ServersState
import dev.terminaldeck.android.servers.StoredServer
import dev.terminaldeck.android.signin.ServerAddress
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.DeckSecretField
import dev.terminaldeck.android.ui.kit.DeckSegmented
import dev.terminaldeck.android.ui.kit.DeckTextField
import dev.terminaldeck.android.ui.kit.FieldLabel
import dev.terminaldeck.android.ui.kit.InfoDot
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * Everything the login screen needs from the app around it.
 *
 * One object rather than eleven parameters, because it is also the seam: `MainActivity` builds it
 * out of the view model and the connector, and nothing in here is a Compose type.
 */
data class ServerLoginView(
    /** The connector's state — the phase, the last look, the install. */
    val servers: ServersState,
    /** True while the relay route is in flight. The two routes share one button. */
    val relayBusy: Boolean = false,
    /** What the relay route is doing, in its own sentence. */
    val relayWorking: String? = null,
    /** The relay route's last refusal. */
    val relayError: String? = null,
    /** Set once the relay route has landed a machine. Its name. */
    val connected: String? = null,
)

/**
 * **The** login screen. One of them.
 *
 * ## What was wrong, in his words
 *
 * > *"Right now on iOS the add-server page tells us: if you don't have a server yet, copy this
 * > command and paste it there — curl … terminaldeck install. **I don't want that command.** …
 * > First they log in to the server. Then it checks whether the headless Terminal Deck already
 * > exists there. If it exists it brings it up and asks you to connect; if not it gives the option
 * > to install — you click, it installs, then you can connect. That's all. Very simple, just like
 * > MacBook. No extra command, nothing."*
 *
 * > *"I want the standard way to sign in used everywhere — server address, username, and password
 * > or key. If that is the standard, keep exactly that standard everywhere."*
 *
 * iOS was rebuilt to do that. This screen is the Android half, and until it existed the phone had
 * **no SSH client at all** — `ServerAddress` refuses a bare hostname by construction ("there is no
 * address without a key in it"), so the SSH route was unreachable rather than merely
 * unimplemented, and `AddServerScreen` printed `curl -fsSL https://terminaldeck.dev/install.sh |
 * sh` for a person to go and type on the machine. That line is deleted, not hidden.
 *
 * ## The address field takes either thing, and says which it got
 *
 * There are genuinely two ways to reach a machine, and both are here — they were never two
 * *screens*, they are two things that can be in one field:
 *
 *  - a hostname or IP, which is an ordinary SSH login to a bare server; or
 *  - the **server address** a host that is already running prints — a block carrying a relay, a
 *    host id and a key — for a machine somebody sent you the address of and that you have no SSH
 *    login for.
 *
 * [ServerAddress.parse] decides, because the block announces itself and a hostname cannot be
 * mistaken for one. The person is told which was recognised, under the field, before they press
 * anything. The fork is in the transport where it belongs, not in the navigation.
 *
 * ## The key field says what actually arrived
 *
 * Not a character count. A count cannot tell a whole key from one whose seven lines were flattened
 * into one — it is identical either way. What is under the field is [PrivateKeyReadback]: the line
 * count, whether BEGIN and END are both there, and whether **the reader that is about to sign with
 * it** could read it.
 *
 * ## The step after the login is part of the login
 *
 * A successful SSH login does not close this screen. It becomes a receipt with three things on it:
 * what the server proved itself with, and [HostStepCard] — the check, the install, the start and
 * the connect, in that order, on the screen somebody is already standing on.
 */
@Composable
fun ServerLoginScreen(
    view: ServerLoginView,
    onLogIn: (address: String, port: String, username: String, secret: String, kind: ServerCredentialKind) -> Unit,
    onSignIn: (address: String, username: String, secret: String, method: EnrollMethod) -> Unit,
    onCancel: () -> Unit,
    hostStep: @Composable (StoredServer) -> Unit,
) {
    val context = LocalContext.current
    /*
     * A login handed in by whoever launched the app, in a debug build only.
     *
     * `servers/HarnessLogin.kt` carries the argument in full; the short version is that the
     * interesting half of this screen is what happens *after* the button — a real handshake, a real
     * host key, a real probe of a real machine — and none of that can be photographed from a
     * fixture. The release source set compiles a version that returns null and reads nothing.
     *
     * It fills the fields and presses nothing.
     */
    val prefill = remember { harnessLogin(context) }

    var address by rememberSaveable { mutableStateOf(prefill?.address.orEmpty()) }
    var port by rememberSaveable { mutableStateOf(prefill?.port.orEmpty()) }
    var username by rememberSaveable { mutableStateOf(prefill?.username.orEmpty()) }
    /*
     * The secret is `remember`, not `rememberSaveable`, and that is deliberate.
     *
     * `rememberSaveable` writes through to the saved-instance bundle, which the system persists to
     * disk for a process it may kill in the background. A server password in there would outlive
     * the app, in plaintext, in a place nothing in this codebase can reach to clear. So it survives
     * a rotation only for as long as this composition does, and a person coming back to a killed
     * process types it again — which is the correct trade for the one field in this app that is
     * somebody's actual server password.
     */
    var secret by remember { mutableStateOf(prefill?.secret.orEmpty()) }
    var method by rememberSaveable { mutableStateOf(prefill?.method ?: EnrollMethod.Password) }

    val clipboard = LocalClipboardManager.current
    val colors = DeckTheme.colors

    /*
     * What is in the address field, as this screen understands it.
     *
     * Recomputed rather than stored: a stored answer is one that can disagree with the field it
     * describes.
     */
    val pastedAddress = ServerAddress.parse(address) is ServerAddress.Companion.Result.Ok

    val login = view.servers.login
    val busy = view.servers.isSigningIn || view.relayBusy
    val arrived = login as? LoginPhase.Added

    BackHandler(onBack = onCancel)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = Space.screen)
            .padding(top = Space.x5, bottom = Space.x8),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text(
                text = "Log in to a server",
                style = DeckType.largeTitle,
                color = colors.primary,
            )
            InfoDot(
                about = "logging in to a server",
                text = "Its address, the account you already use on it, and the password or key " +
                    "that account already accepts. Nothing has to be running on a desktop, and " +
                    "nobody has to be sitting at that machine. It also takes the whole server " +
                    "address a machine already running Terminal Deck prints, if somebody sent you " +
                    "one.",
            )
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onCancel) {
                Text(
                    text = if (arrived != null || view.connected != null) "Done" else "Cancel",
                    style = DeckType.control,
                    color = colors.accent,
                )
            }
        }

        Spacer(Modifier.height(Space.x5))

        when {
            /*
             * Connected — and **the card stays**, because Disconnect is on it.
             *
             * *"…then you can connect, and disconnect if you want."* A receipt with nothing to
             * press on it would tell somebody their phone is attached to a machine and give them
             * no way to detach it, on the one screen where they were just told they could. So the
             * connected headline goes *above* the same card, which redraws with Disconnect and
             * Stop now that the server is linked.
             */
            view.connected != null && arrived != null ->
                Connected(view.connected) { hostStep(arrived.server) }
            view.connected != null -> Connected(view.connected) {}
            arrived != null -> Arrived(arrived.server, hostStep)
            busy -> Working(view)
            else -> Form(
                view = view,
                address = address,
                onAddress = { address = it },
                port = port,
                onPort = { port = it },
                username = username,
                onUsername = { username = it },
                secret = secret,
                onSecret = { secret = it },
                method = method,
                onMethod = { next ->
                    // The two fields hold different things and one is never the other. Carrying a
                    // typed password into the key field would be offering to send a password as a
                    // private key.
                    if (next != method) secret = ""
                    method = next
                },
                pastedAddress = pastedAddress,
                onPasteAddress = { clipboard.getText()?.text?.trim()?.let { address = it } },
                onPasteKey = { clipboard.getText()?.text?.let { secret = it } },
                onSubmit = {
                    if (pastedAddress) {
                        onSignIn(address.trim(), username, secret, method)
                    } else {
                        onLogIn(
                            address.trim(),
                            port.trim(),
                            username,
                            secret,
                            if (method == EnrollMethod.Key) ServerCredentialKind.KEY else ServerCredentialKind.PASSWORD,
                        )
                    }
                },
            )
        }
    }
}

/* --------------------------------------------------------------------- form -- */

@Composable
private fun ColumnScope.Form(
    view: ServerLoginView,
    address: String,
    onAddress: (String) -> Unit,
    port: String,
    onPort: (String) -> Unit,
    username: String,
    onUsername: (String) -> Unit,
    secret: String,
    onSecret: (String) -> Unit,
    method: EnrollMethod,
    onMethod: (EnrollMethod) -> Unit,
    pastedAddress: Boolean,
    onPasteAddress: () -> Unit,
    onPasteKey: () -> Unit,
    onSubmit: () -> Unit,
) {
    val colors = DeckTheme.colors
    val failure = currentFailure(view)

    failure?.let { (headline, advice) ->
        /*
         * A card, not a red-bordered box.
         *
         * The failure this screen reports is almost always one wrong character in one of the fields
         * below, and the fields are still filled in. A red outline around the sentence makes the
         * whole screen read as broken; the sentence in the warning ink inside an ordinary card says
         * *this did not work* without saying *start again*. Same shape iOS uses, for the same
         * reason.
         */
        SectionCard {
            Text(text = headline, style = DeckType.footnote, color = colors.warning)
            if (advice.isNotEmpty()) {
                Spacer(Modifier.height(Space.x1))
                Text(text = advice, style = DeckType.caption, color = colors.secondary)
            }
        }
        Spacer(Modifier.height(Space.x3))
    }

    /* ------------------------------------------------------- address + port -- */

    SectionCard {
        FieldLabel(
            title = "Server address",
            about = "the address",
            note = "The name or number you would put after `ssh` — `example.com`, or an IP " +
                "address, reachable from this phone's network. It also takes the whole server " +
                "address block a machine already running Terminal Deck prints, if somebody sent " +
                "you one: that carries its own endpoint, so the port is not used with it.",
        )
        DeckTextField(
            value = address,
            onValueChange = onAddress,
            placeholder = "example.com",
            // Several lines, because a pasted server address is long and a single-line field shows
            // a person the last thirty characters of what they pasted and nothing else — which is
            // no way to check whether the whole thing arrived.
            singleLine = false,
            minLines = 1,
            maxLines = 5,
            enabled = !view.servers.isSigningIn,
            mono = true,
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Uri,
                imeAction = ImeAction.Next,
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
            ),
        )
        Spacer(Modifier.height(Space.x2))
        PasteRow(label = "Paste", enabled = !view.servers.isSigningIn, onPaste = onPasteAddress)

        if (pastedAddress) {
            Spacer(Modifier.height(Space.x2))
            Row(verticalAlignment = Alignment.Top) {
                Icon(
                    Icons.Filled.CheckCircle,
                    contentDescription = null,
                    tint = colors.positive,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.width(Space.x2))
                Text(
                    text = "That is a server address — this phone will meet that machine through " +
                        "its relay, so the port is not used.",
                    style = DeckType.caption,
                    color = colors.secondary,
                )
            }
        }

        Spacer(Modifier.height(Space.x5))
        FieldLabel(
            title = "Port",
            about = "the port",
            note = "Leave it empty unless whoever set the server up gave you a number. SSH is " +
                "usually 22 — but a server that was moved off 22 will not answer on it at all, " +
                "and that is a failure nothing else on this screen could explain.",
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            DeckTextField(
                value = port,
                onValueChange = { typed -> onPort(typed.filter { it.isDigit() }.take(5)) },
                placeholder = "22",
                // Disabled rather than hidden when a server address is in the field above it: a
                // field that disappears reads as a screen that changed, and the sentence beside it
                // already says why.
                enabled = !pastedAddress && !view.servers.isSigningIn,
                mono = true,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Number,
                    imeAction = ImeAction.Next,
                ),
                modifier = Modifier.width(96.dp),
            )
            Spacer(Modifier.width(Space.x3))
            Text(
                text = if (pastedAddress) "Not used with a server address." else "Empty means 22.",
                style = DeckType.caption,
                color = colors.faint,
            )
        }
    }

    Spacer(Modifier.height(Space.x3))

    /* ----------------------------------------------------------- the login -- */

    SectionCard {
        FieldLabel(
            title = "Username",
            about = "the username",
            note = "The account you would use to sign in to that server. The server checks it " +
                "against its own SSH — nothing here decides whether it was right.",
        )
        DeckTextField(
            value = username,
            onValueChange = onUsername,
            placeholder = "root, ubuntu, asad…",
            enabled = !view.servers.isSigningIn,
            mono = true,
            keyboardOptions = KeyboardOptions(
                // No autocorrect and no capitalisation: a login is not a word, and a phone keyboard
                // that helpfully capitalises the first letter of one is a sign-in that fails for a
                // reason nobody can see.
                keyboardType = KeyboardType.Ascii,
                imeAction = ImeAction.Next,
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
            ),
        )

        Spacer(Modifier.height(Space.x5))
        FieldLabel(
            title = "How you sign in",
            about = "the two ways in",
            note = "Whichever that account already accepts. A key must have no passphrase on it: " +
                "nothing here can ask you for the passphrase on the server's behalf. " +
                "`ssh-keygen -t ed25519` makes one that works.",
        )
        DeckSegmented(
            options = listOf("Password", "Private key"),
            selectedIndex = if (method == EnrollMethod.Password) 0 else 1,
            enabled = !view.servers.isSigningIn,
            onSelect = { index -> onMethod(if (index == 0) EnrollMethod.Password else EnrollMethod.Key) },
        )

        Spacer(Modifier.height(Space.x3))
        DeckSecretField(
            value = secret,
            onValueChange = onSecret,
            placeholder = if (method == EnrollMethod.Password) {
                "The password for that account"
            } else {
                "-----BEGIN OPENSSH PRIVATE KEY-----"
            },
            enabled = !view.servers.isSigningIn,
            mono = true,
            singleLine = method == EnrollMethod.Password,
            minLines = if (method == EnrollMethod.Password) 1 else 3,
        )
        if (method == EnrollMethod.Key) {
            Spacer(Modifier.height(Space.x2))
            // A key cannot be typed on a phone. Without this the Key option would be a control that
            // exists and cannot be used, which is the same thing as one that does not work.
            PasteRow(label = "Paste key", enabled = !view.servers.isSigningIn, onPaste = onPasteKey)
            KeyReadback(secret)
        }
    }

    Spacer(Modifier.height(Space.x5))

    val canSubmit = address.isNotBlank() && username.isNotBlank() && secret.isNotEmpty()
    DeckPrimaryButton(
        label = "Log in",
        onClick = onSubmit,
        enabled = !view.servers.isSigningIn && !view.relayBusy && canSubmit,
    )

    DeckFootnote(
        "This is an ordinary SSH login, the same one a terminal would make. Terminal Deck keeps it " +
            "on this phone, behind the Android Keystore, and sends it to nothing but that server."
    )
}

/**
 * What arrived in the key field, in the words of the reader that will sign with it.
 *
 * The whole point is that *"this key is readable"* is a claim something already checked, rather
 * than a character count dressed up as one.
 */
@Composable
private fun ColumnScope.KeyReadback(secret: String) {
    val colors = DeckTheme.colors
    val readback = remember(secret) { PrivateKeyReadback.of(secret) }
    val sentence = readback.sentence ?: return

    Spacer(Modifier.height(Space.x2))
    Row(verticalAlignment = Alignment.Top) {
        Icon(
            Icons.Filled.CheckCircle,
            contentDescription = null,
            tint = if (readback.isGood) colors.positive else colors.warning,
            modifier = Modifier.size(14.dp),
        )
        Spacer(Modifier.width(Space.x2))
        Column {
            Text(
                text = sentence,
                style = DeckType.caption,
                color = if (readback.isGood) colors.secondary else colors.warning,
            )
            (readback as? PrivateKeyReadback.Bad)?.let {
                Text(text = it.advice, style = DeckType.caption, color = colors.secondary)
            }
        }
    }
}

/* ------------------------------------------------------------------ waiting -- */

/**
 * The waits, each named.
 *
 * Reaching a server, being checked by it, and being signed in fail in different ways and take
 * different lengths of time, and somebody watching a phone for fifteen seconds is entitled to know
 * which. A spinner with nothing beside it is indistinguishable from one that has stuck.
 */
@Composable
private fun ColumnScope.Working(view: ServerLoginView) {
    val colors = DeckTheme.colors
    val headline = when {
        view.relayBusy -> view.relayWorking ?: "Reaching that machine"
        view.servers.login is LoginPhase.Looking -> "Looking at that server"
        else -> "Signing in to that server"
    }
    val detail = when {
        view.relayBusy ->
            "It is checking the username and the password or key against its own SSH. It does not " +
                "answer until that comes back."
        view.servers.login is LoginPhase.Looking ->
            "It accepted the login. This is it being asked whether Terminal Deck is already on it."
        else ->
            "Opening an SSH connection and checking the server's identity before anything is sent " +
                "to it."
    }

    Row(verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(
            strokeWidth = 2.dp,
            color = colors.accent,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(Space.x3))
        Text(text = headline, style = DeckType.title, color = colors.primary)
    }
    Spacer(Modifier.height(Space.x3))
    Text(text = detail, style = DeckType.footnote, color = colors.secondary)
}

/* ----------------------------------------------- the step after the login -- */

/**
 * Logged in — and the next step is on this screen rather than behind it.
 *
 * Two things, in the order they matter: what the server proved itself with, and the
 * check-and-install step. *"Right after logging in we need to have the step for
 * checking/installing headless Terminal Deck."*
 */
@Composable
private fun ColumnScope.Arrived(server: StoredServer, hostStep: @Composable (StoredServer) -> Unit) {
    val colors = DeckTheme.colors

    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            Icons.Filled.CheckCircle,
            contentDescription = null,
            tint = colors.positive,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(Space.x3))
        Text(text = "Logged in to ${server.name}", style = DeckType.title, color = colors.primary)
    }

    Spacer(Modifier.height(Space.x4))

    /*
     * The fingerprint, shown once and kept.
     *
     * This is the only moment it can be checked: from here on it is what every connection is
     * compared against, and a server answering with a different one is refused before a password is
     * offered. Printed in the form `ssh-keygen -lf` prints, so it can be checked against any other
     * tool.
     */
    server.hostKey?.let { key ->
        SectionCard {
            Text(text = "IT PROVED ITSELF WITH", style = DeckType.overline, color = colors.faint)
            Spacer(Modifier.height(Space.x1))
            Text(text = key.fingerprint, style = DeckType.mono, color = colors.primary)
            Spacer(Modifier.height(Space.x1))
            Text(
                text = "${key.algorithm}. Every later connection is checked against this.",
                style = DeckType.caption,
                color = colors.faint,
            )
        }
        Spacer(Modifier.height(Space.x3))
    }

    hostStep(server)
}

/* ---------------------------------------------------------------- connected -- */

@Composable
private fun ColumnScope.Connected(name: String, card: @Composable () -> Unit) {
    val colors = DeckTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            Icons.Filled.CheckCircle,
            contentDescription = null,
            tint = colors.positive,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(Space.x3))
        Text(text = name, style = DeckType.title, color = colors.primary)
    }
    Spacer(Modifier.height(Space.x3))
    Text(
        text = "Connected. It is in your machines now, and its sessions are on the Sessions tab.",
        style = DeckType.footnote,
        color = colors.secondary,
    )
    Spacer(Modifier.height(Space.x4))
    card()
    DeckFootnote(
        "Terminal Deck keeps your sign-in behind this phone's Keystore and sends it to nothing but " +
            "that machine."
    )
}

/* -------------------------------------------------------------------- parts -- */

/** Whichever route last refused, in its own words. Never this screen's guess. */
private fun currentFailure(view: ServerLoginView): Pair<String, String>? {
    (view.servers.login as? LoginPhase.Failed)?.let { return it.headline to it.advice }
    view.relayError?.let { return it to "" }
    return null
}

@Composable
private fun PasteRow(label: String, enabled: Boolean, onPaste: () -> Unit) {
    val colors = DeckTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Start) {
        TextButton(onClick = onPaste, enabled = enabled) {
            Icon(
                Icons.Filled.ContentPaste,
                contentDescription = null,
                tint = if (enabled) colors.accent else colors.faint,
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.width(Space.x2))
            Text(
                text = label,
                style = DeckType.value,
                color = if (enabled) colors.accent else colors.faint,
            )
        }
    }
}

/**
 * A card on this screen.
 *
 * Eighteen points of inset rather than sixteen, because these cards hold *fields* rather than rows
 * and a field's own border needs room to not look like it is touching the card's edge.
 */
@Composable
internal fun SectionCard(content: @Composable ColumnScope.() -> Unit) {
    DeckGroup {
        Column(modifier = Modifier.padding(18.dp), content = content)
    }
}
