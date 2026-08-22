package dev.terminaldeck.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.AddServerView
import dev.terminaldeck.android.protocol.EnrollMethod
import dev.terminaldeck.android.signin.INSTALL_COMMAND
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
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * Adding a **server**: an address, a login it already trusts, and no desktop anywhere in it.
 *
 * ## Why this screen exists and the pair screen could not be stretched to cover it
 *
 * Pairing trades six digits minted by the app at the other end. That works between two computers a
 * person sits at and it cannot work for a server, because there is nobody there to read a code to
 * and nothing running to mint one. The two ceremonies are different all the way down — different
 * facts travel, different thing proves the trust, different failures — and `SERVERS-DESIGN.md`
 * settles it in one line: *a server is never "paired" and a device is never "signed in to".* So
 * this is a second screen rather than a mode of the first, and every sentence on it uses the verb
 * that belongs to the kind.
 *
 * ## The three fields, and why none of them can be dropped
 *
 * - **Server address.** The relay, the host id and the server's key, pasted as one string. It has
 *   to carry the key: a host id is a hash, so nothing can be derived from it, and fetching the key
 *   from the relay would be asking the attacker for the fingerprint of the machine you are about to
 *   trust. [dev.terminaldeck.android.signin.ServerAddress] carries the full argument and reads every
 *   shape one plausibly arrives in.
 * - **Username.** A real login on that machine. The server checks it against its own sshd.
 * - **Password or private key.** The thing that proves the login. Sent once, inside the sealed
 *   channel, and kept nowhere: not in the vault, not in the view model, not in this screen after it
 *   succeeds. The footer says so, because a screen that asks for a server password without saying
 *   what becomes of it is one a careful person is right to refuse.
 *
 * ## Never a dead control
 *
 * The button is disabled only while a sign-in is genuinely in flight or a field is genuinely empty,
 * and the wait carries a sentence rather than a bare spinner — this is the longest wait in the app,
 * because the server runs an SSH probe and a memory-hard hash before it answers. Every failure
 * comes back as the server's own words where the server gave any, and the screen stays up with the
 * fields still filled in, because the fix is almost always one character in one of them.
 *
 * The one thing this screen cannot do is install Terminal Deck on a bare machine — a phone cannot
 * SSH. It says so, and shows the one line to run there, rather than offering a button that would
 * fail.
 */
@Composable
fun AddServerScreen(
    view: AddServerView,
    onSignIn: (address: String, username: String, secret: String, method: EnrollMethod) -> Unit,
    onCancel: () -> Unit,
) {
    var address by rememberSaveable { mutableStateOf("") }
    var username by rememberSaveable { mutableStateOf("") }
    /*
     * The secret is `remember`, not `rememberSaveable`, and that is deliberate.
     *
     * `rememberSaveable` writes through to the saved-instance bundle, which the system persists to
     * disk for a process it may kill in the background. A server password in there would outlive the
     * app, in plaintext, in a place nothing in this codebase can reach to clear. So it survives a
     * rotation only for as long as this composition does, and a person coming back to a killed
     * process types it again — which is the correct trade for the one field in this app that is
     * somebody's actual server password.
     */
    var secret by remember { mutableStateOf("") }
    var method by rememberSaveable { mutableStateOf(EnrollMethod.Password) }
    var showInstall by rememberSaveable { mutableStateOf(false) }

    val clipboard = LocalClipboardManager.current
    val busy = view.busy
    val colors = DeckTheme.colors

    // Back means cancel, and while a sign-in is in flight it means cancel that too — the view model
    // says out loud that the server may still finish its half, because a phone cannot call an SSH
    // probe back.
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
                text = "Add a server",
                style = DeckType.largeTitle,
                color = colors.primary,
            )
            /*
             * The paragraph that used to be under this title is behind the ⓘ.
             *
             * Three lines of prose above the first field, explaining what the screen is to somebody
             * who has already tapped "Add a server" and can therefore be assumed to know. *"I don't
             * want any kind of long descriptions anywhere. Just if somewhere it's very required,
             * give the i icon."* This is the shape that instruction asks for, and it is the same
             * shape `AddServerView.swift` uses beside every one of its labels.
             */
            InfoDot(
                about = "adding a server",
                text = "Sign in to a server with the username and password — or key — you already " +
                    "use for it. Nothing has to be running on a desktop, and nobody has to be " +
                    "sitting at it.",
            )
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onCancel) {
                Text("Cancel", style = DeckType.control, color = colors.accent)
            }
        }

        Spacer(Modifier.height(Space.x5))

        /* -------------------------------------------------------------- the address -- */

        SectionCard {
            FieldLabel(
                title = "Server address",
                about = "server addresses",
                note = "A server prints this. It carries three things — where to meet it, which " +
                    "machine it is, and the key that proves it is that machine — and no password " +
                    "or token, so it is safe to send yourself. Paste the whole block.",
            )
            DeckTextField(
                value = address,
                onValueChange = { address = it },
                placeholder = "td1 wss://…  HOSTID…  key…",
                // Several lines, because an address is long and a single-line field shows a person
                // the last thirty characters of what they pasted and nothing else — which is no way
                // to check whether the whole thing arrived.
                singleLine = false,
                minLines = 2,
                maxLines = 4,
                enabled = !busy,
                // Mono, because an address is data: a thing somebody checks character by character.
                mono = true,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    imeAction = ImeAction.Next,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                ),
            )
            Spacer(Modifier.height(Space.x2))
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(
                    onClick = { clipboard.getText()?.text?.trim()?.let { address = it } },
                    enabled = !busy,
                ) {
                    Icon(
                        Icons.Filled.ContentPaste,
                        contentDescription = null,
                        tint = if (busy) colors.faint else colors.accent,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(Space.x2))
                    Text(
                        text = "Paste",
                        style = DeckType.value,
                        color = if (busy) colors.faint else colors.accent,
                    )
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { showInstall = !showInstall }) {
                    Text(
                        text = if (showInstall) "Hide" else "Where do I get this?",
                        style = DeckType.value,
                        color = colors.accent,
                    )
                }
            }
            if (showInstall) {
                Spacer(Modifier.height(Space.x1))
                Text(
                    // Said plainly rather than offered as a button. This phone cannot SSH, so an
                    // Install button here would be a control that can only ever fail — the same
                    // reason the browser client shows this line instead of a button.
                    text = "Nothing installed on it yet? Run this on the server itself, then come " +
                        "back and paste the address it prints:",
                    style = DeckType.caption,
                    color = colors.faint,
                )
                Spacer(Modifier.height(Space.x2))
                CommandRow(INSTALL_COMMAND) { clipboard.setText(AnnotatedString(INSTALL_COMMAND)) }
            }
        }

        Spacer(Modifier.height(Space.x3))

        /* ---------------------------------------------------------------- the login -- */

        SectionCard {
            FieldLabel(
                title = "Username",
                about = "the username",
                note = "The account you would use to SSH into that server. The server checks it " +
                    "against its own SSH — this app never sees whether it was right, only that " +
                    "the server said so.",
            )
            DeckTextField(
                value = username,
                onValueChange = { username = it },
                placeholder = "root, ubuntu, asad…",
                enabled = !busy,
                mono = true,
                keyboardOptions = KeyboardOptions(
                    // No autocorrect and no capitalisation: a login is not a word, and a phone
                    // keyboard that helpfully capitalises the first letter of one is a sign-in that
                    // fails for a reason nobody can see.
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
                note = "Whichever that account already accepts. A key must be an unencrypted " +
                    "private key — one with a passphrase on it cannot be used here, because " +
                    "nothing on this screen can ask you for the passphrase on the server's " +
                    "behalf. Terminal Deck keeps neither: what it keeps is the credential the " +
                    "server mints in exchange for it, which that server can revoke on its own.",
            )
            /*
             * A segmented control rather than two chips.
             *
             * There are exactly two answers to one question and they are mutually exclusive, which
             * is the definition of this control and not of a chip row — two chips are two things
             * that could each be on. The pair this replaces were outlined pills, of which the
             * chosen one had a tinted fill and an accent border, and photographed on a phone they
             * read as *enabled* beside *disabled* rather than as a choice.
             */
            DeckSegmented(
                options = listOf("Password", "Private key"),
                selectedIndex = if (method == EnrollMethod.Password) 0 else 1,
                enabled = !busy,
                onSelect = { index ->
                    val next = if (index == 0) EnrollMethod.Password else EnrollMethod.Key
                    // The secret is cleared with the method rather than carried across. A password
                    // left in the field after switching to Key is a password that gets sent as a
                    // private key and refused, and the sentence that comes back is about the wrong
                    // thing entirely.
                    if (next != method) secret = ""
                    method = next
                },
            )

            Spacer(Modifier.height(Space.x3))
            DeckSecretField(
                value = secret,
                onValueChange = { secret = it },
                placeholder = if (method == EnrollMethod.Password) {
                    "The password for that account"
                } else {
                    "-----BEGIN OPENSSH PRIVATE KEY-----"
                },
                enabled = !busy,
                mono = true,
                singleLine = method == EnrollMethod.Password,
                minLines = if (method == EnrollMethod.Password) 1 else 3,
            )
            if (method == EnrollMethod.Key) {
                Spacer(Modifier.height(Space.x2))
                // A key cannot be typed on a phone. Without this the Key option would be a control
                // that exists and cannot be used, which is the same thing as one that does not work.
                TextButton(
                    onClick = { clipboard.getText()?.text?.let { secret = it } },
                    enabled = !busy,
                ) {
                    Icon(
                        Icons.Filled.ContentPaste,
                        contentDescription = null,
                        tint = if (busy) colors.faint else colors.accent,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(Space.x2))
                    Text(
                        text = "Paste key",
                        style = DeckType.value,
                        color = if (busy) colors.faint else colors.accent,
                    )
                }
            }
        }

        /* --------------------------------------------------------------- the outcome -- */

        view.error?.let { sentence ->
            Spacer(Modifier.height(Space.x3))
            /*
             * A card, not a red-bordered box.
             *
             * The failure this screen reports is almost always one wrong character in one of the
             * fields above, and the fields are still filled in. A red outline around the sentence
             * makes the whole screen read as broken; the sentence in the warning ink inside an
             * ordinary card says *this did not work* without saying *start again*. Same shape iOS
             * uses, for the same reason.
             */
            SectionCard {
                Text(
                    // The server's own words wherever it gave any. A refused login and a
                    // rate-limited one are one sentence over there on purpose — the wire must not be
                    // usable to tell a bad guess from a lockout — and nothing here tries to take
                    // them apart again.
                    text = sentence,
                    style = DeckType.footnote,
                    color = colors.warning,
                )
            }
        }

        Spacer(Modifier.height(Space.x5))

        DeckPrimaryButton(
            label = if (busy) "Signing in…" else "Sign in",
            onClick = { onSignIn(address, username, secret, method) },
            enabled = !busy && address.isNotBlank() && username.isNotBlank() && secret.isNotEmpty(),
            leading = if (busy) {
                {
                    CircularProgressIndicator(
                        strokeWidth = 2.dp,
                        color = colors.onAccent,
                        modifier = Modifier.size(16.dp),
                    )
                }
            } else null,
        )

        view.working?.let { sentence ->
            DeckFootnote(
                // The sentence, not just the spinner. This wait is seconds long — the server runs a
                // real SSH probe against its own sshd and then a memory-hard hash to mint the
                // credential — and a spinner with nothing beside it is indistinguishable from one
                // that has stuck.
                "$sentence It is checking the login on the server itself, which takes a moment."
            )
        }

        Spacer(Modifier.height(Space.x2))
        DeckFootnote(
            "The password or key is sent once, encrypted end to end, to prove the login. It is not " +
                "saved on this phone. What is saved is the credential the server hands back, behind " +
                "the Android Keystore — the same as a paired machine's."
        )
    }
}

/* -------------------------------------------------------------------------- */

/**
 * A card on this screen.
 *
 * Eighteen points of inset rather than sixteen, because these cards hold *fields* rather than rows
 * and a field's own border needs room to not look like it is touching the card's edge. The border
 * the card itself used to carry is gone — see [DeckGroup].
 */
@Composable
private fun SectionCard(content: @Composable ColumnScope.() -> Unit) {
    DeckGroup {
        Column(modifier = Modifier.padding(18.dp), content = content)
    }
}

/** A line to run somewhere else, with the one button that makes it usable from a phone. */
@Composable
private fun CommandRow(command: String, onCopy: () -> Unit) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(Radius.fieldShape)
            // The sunken surface: a command to run somewhere else is the one thing on this screen
            // that is not of this screen, and a well reads as quoted where a raised card reads as
            // offered.
            .background(colors.sunken)
            .border(1.dp, colors.hairline, Radius.fieldShape)
            .padding(start = Space.x3, end = Space.x1, top = Space.x2, bottom = Space.x2),
    ) {
        Text(
            text = command,
            style = DeckType.mono,
            color = colors.primary,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onCopy) {
            Icon(
                Icons.Filled.ContentCopy,
                contentDescription = "Copy",
                tint = colors.accent,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}
