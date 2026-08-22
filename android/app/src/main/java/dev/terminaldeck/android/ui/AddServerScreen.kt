package dev.terminaldeck.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.AddServerView
import dev.terminaldeck.android.protocol.EnrollMethod
import dev.terminaldeck.android.signin.INSTALL_COMMAND

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
    var revealed by remember { mutableStateOf(false) }
    var showInstall by rememberSaveable { mutableStateOf(false) }

    val clipboard = LocalClipboardManager.current
    val busy = view.busy

    // Back means cancel, and while a sign-in is in flight it means cancel that too — the view model
    // says out loud that the server may still finish its half, because a phone cannot call an SSH
    // probe back.
    BackHandler(onBack = onCancel)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text(
                text = "Add a server",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onCancel) { Text("Cancel") }
        }

        Spacer(Modifier.height(6.dp))
        Text(
            text = "Sign in to a server with the username and password — or key — you already use " +
                "for it. Nothing has to be running on a desktop, and nobody has to be sitting at it.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(20.dp))

        /* -------------------------------------------------------------- the address -- */

        SectionCard {
            FieldLabel("Server address")
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = address,
                onValueChange = { address = it },
                placeholder = { Text("td1 wss://…  HOSTID…  key…") },
                // Several lines, because an address is long and a single-line field shows a person
                // the last thirty characters of what they pasted and nothing else — which is no way
                // to check whether the whole thing arrived.
                minLines = 2,
                maxLines = 4,
                enabled = !busy,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    imeAction = ImeAction.Next,
                ),
                // Mono, because an address is data: a thing somebody checks character by character.
                textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace),
                colors = fieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(
                    onClick = { clipboard.getText()?.text?.let { address = it } },
                    enabled = !busy,
                ) {
                    Icon(Icons.Filled.ContentPaste, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Paste")
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { showInstall = !showInstall }) {
                    Text(if (showInstall) "Hide" else "Where do I get this?")
                }
            }
            if (showInstall) {
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "A server address is three things printed together: the relay address " +
                        "(wss://…), the server's 26-character host id, and its key. Terminal Deck " +
                        "on the server prints all three — copy the whole line.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    // Said plainly rather than offered as a button. This phone cannot SSH, so an
                    // Install button here would be a control that can only ever fail — the same
                    // reason the browser client shows this line instead of a button.
                    text = "Nothing installed on it yet? Run this on the server itself, then come " +
                        "back and paste the address it prints:",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(8.dp))
                CommandRow(INSTALL_COMMAND) { clipboard.setText(AnnotatedString(INSTALL_COMMAND)) }
            }
        }

        Spacer(Modifier.height(14.dp))

        /* ---------------------------------------------------------------- the login -- */

        SectionCard {
            FieldLabel("Username")
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = username,
                onValueChange = { username = it },
                placeholder = { Text("root") },
                singleLine = true,
                enabled = !busy,
                keyboardOptions = KeyboardOptions(
                    // No autocorrect and no capitalisation: a login is not a word, and a phone
                    // keyboard that helpfully capitalises the first letter of one is a sign-in that
                    // fails for a reason nobody can see.
                    keyboardType = KeyboardType.Ascii,
                    imeAction = ImeAction.Next,
                ),
                textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace),
                colors = fieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(18.dp))
            FieldLabel("Sign in with")
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                MethodChip(
                    label = "Password",
                    selected = method == EnrollMethod.Password,
                    enabled = !busy,
                ) {
                    // The secret is cleared with the method rather than carried across. A password
                    // left in the field after switching to Key is a password that gets sent as a
                    // private key and refused, and the sentence that comes back is about the wrong
                    // thing entirely.
                    if (method != EnrollMethod.Password) secret = ""
                    method = EnrollMethod.Password
                }
                MethodChip(
                    label = "Private key",
                    selected = method == EnrollMethod.Key,
                    enabled = !busy,
                ) {
                    if (method != EnrollMethod.Key) secret = ""
                    method = EnrollMethod.Key
                }
            }

            Spacer(Modifier.height(14.dp))
            OutlinedTextField(
                value = secret,
                onValueChange = { secret = it },
                label = { Text(if (method == EnrollMethod.Password) "Password" else "Private key") },
                placeholder = {
                    Text(
                        if (method == EnrollMethod.Password) "" else "-----BEGIN OPENSSH PRIVATE KEY-----",
                    )
                },
                singleLine = method == EnrollMethod.Password,
                minLines = if (method == EnrollMethod.Password) 1 else 3,
                maxLines = if (method == EnrollMethod.Password) 1 else 6,
                enabled = !busy,
                visualTransformation = if (revealed) {
                    VisualTransformation.None
                } else {
                    PasswordVisualTransformation()
                },
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    imeAction = ImeAction.Done,
                ),
                textStyle = LocalTextStyle.current.copy(fontFamily = FontFamily.Monospace),
                colors = fieldColors(),
                trailingIcon = {
                    IconButton(onClick = { revealed = !revealed }) {
                        Icon(
                            imageVector = if (revealed) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                            contentDescription = if (revealed) "Hide" else "Show",
                        )
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
            if (method == EnrollMethod.Key) {
                Spacer(Modifier.height(8.dp))
                // A key cannot be typed on a phone. Without this the Key option would be a control
                // that exists and cannot be used, which is the same thing as one that does not work.
                TextButton(
                    onClick = { clipboard.getText()?.text?.let { secret = it } },
                    enabled = !busy,
                ) {
                    Icon(Icons.Filled.ContentPaste, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Paste key")
                }
            }
        }

        /* --------------------------------------------------------------- the outcome -- */

        view.error?.let { sentence ->
            Spacer(Modifier.height(14.dp))
            SectionCard(border = MaterialTheme.colorScheme.error) {
                Text(
                    // The server's own words wherever it gave any. A refused login and a
                    // rate-limited one are one sentence over there on purpose — the wire must not be
                    // usable to tell a bad guess from a lockout — and nothing here tries to take
                    // them apart again.
                    text = sentence,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }

        Spacer(Modifier.height(18.dp))

        Button(
            onClick = { onSignIn(address, username, secret, method) },
            enabled = !busy && address.isNotBlank() && username.isNotBlank() && secret.isNotEmpty(),
            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (busy) {
                CircularProgressIndicator(
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(10.dp))
            }
            Text(if (busy) "Signing in…" else "Sign in")
        }

        view.working?.let { sentence ->
            Spacer(Modifier.height(10.dp))
            Text(
                // The sentence, not just the spinner. This wait is seconds long — the server runs a
                // real SSH probe against its own sshd and then a memory-hard hash to mint the
                // credential — and a spinner with nothing beside it is indistinguishable from one
                // that has stuck.
                text = "$sentence It is checking the login on the server itself, which takes a moment.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        Spacer(Modifier.height(16.dp))
        Text(
            text = "The password or key is sent once, encrypted end to end, to prove the login. It " +
                "is not saved on this phone. What is saved is the credential the server hands back, " +
                "behind the Android Keystore — the same as a paired machine's.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(24.dp))
    }
}

/* -------------------------------------------------------------------------- */

@Composable
private fun SectionCard(
    border: androidx.compose.ui.graphics.Color = MaterialTheme.colorScheme.outline,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(1.dp, border, RoundedCornerShape(14.dp))
            .padding(18.dp),
    ) { content() }
}

@Composable
private fun FieldLabel(text: String) {
    Text(
        text = text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/**
 * One of the two ways to prove a login.
 *
 * A pair of chips rather than a dropdown: there are exactly two, both are one word, and a menu that
 * hides one of two choices behind a tap is a menu that hides the one somebody needs.
 */
@Composable
private fun MethodChip(label: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val border = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(10.dp))
            .background(
                if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.14f)
                else MaterialTheme.colorScheme.surface
            )
            .border(1.dp, border, RoundedCornerShape(10.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
        )
    }
}

/** A line to run somewhere else, with the one button that makes it usable from a phone. */
@Composable
private fun CommandRow(command: String, onCopy: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(MaterialTheme.colorScheme.background)
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(10.dp))
            .padding(start = 12.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
    ) {
        Text(
            text = command,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onCopy) {
            Icon(Icons.Filled.ContentCopy, contentDescription = "Copy", modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun fieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = MaterialTheme.colorScheme.onSurface,
    unfocusedTextColor = MaterialTheme.colorScheme.onSurface,
    focusedBorderColor = MaterialTheme.colorScheme.primary,
    unfocusedBorderColor = MaterialTheme.colorScheme.outline,
)
