package dev.terminaldeck.android.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.terminaldeck.android.github.GitHubAccount
import dev.terminaldeck.android.github.GitHubSignIn
import dev.terminaldeck.android.github.SignInPhase

/**
 * Where a GitHub account gets onto this phone, and the only setup this feature has.
 *
 * The design brief's shape is: *once, on their own device, they connect GitHub inside their own copy
 * of the app; when they join a folder, nothing at all; the first push, a prompt*. This is the first
 * of those three. Without it the approval prompt is a screen nobody can ever reach, because a phone
 * with no account answers every request with `no-account` and is never asked to prompt.
 *
 * ## Two ways in, both ending in the same place
 *
 * **Sign in** is GitHub's device flow: a short code, read off this screen and typed into a browser.
 * The consent page will say *GitHub CLI*, because this project has not registered an OAuth
 * application of its own and borrows that public client id — and the screen says so rather than
 * letting it be a surprise. See `GitHubSignIn`.
 *
 * **Paste a token** is the fallback the design keeps on purpose: a fine-grained personal access
 * token, scoped to one repository, with an expiry. If it leaks, the blast radius is one repository
 * somebody already chose to share.
 *
 * ## What this screen does not say
 *
 * There is no line here about the token never being stored on the other machine. That copy was cut
 * deliberately: the approval prompt already names the repository, the account and the machine that
 * asked, and that is the explanation. A sentence in a settings pane that nobody reads is not
 * security, it is decoration.
 */
@Composable
fun GitHubSheet(
    account: GitHubAccount?,
    phase: SignInPhase,
    signIn: GitHubSignIn,
    onDisconnect: () -> Unit,
    onDismiss: () -> Unit,
) {
    var shown by remember { mutableStateOf(false) }
    var pasting by remember { mutableStateOf(false) }
    var typed by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { shown = true }

    val leave = {
        // Stops the poll. Without this the flow keeps waking the radio every five seconds for a
        // code nobody is going to type.
        signIn.cancel()
        onDismiss()
    }
    BackHandler(onBack = leave)

    Box(modifier = Modifier.fillMaxSize()) {
        AnimatedVisibility(visible = shown, enter = fadeIn(), exit = fadeOut()) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(SHEET_SCRIM)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = leave,
                    )
            )
        }

        AnimatedVisibility(
            visible = shown,
            enter = slideInVertically(initialOffsetY = { it }),
            exit = slideOutVertically(targetOffsetY = { it }),
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                    .background(MaterialTheme.colorScheme.surface)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = {},
                    )
                    .verticalScroll(rememberScrollState())
                    .navigationBarsPadding()
                    .padding(start = 20.dp, end = 20.dp, top = 22.dp, bottom = 16.dp),
            ) {
                Text(
                    text = "GitHub",
                    fontSize = 19.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    // What the account is *for*, in one line, because a screen offering a sign-in
                    // with no stated purpose is a screen people close.
                    text = "Machines you work on ask this phone when git needs a login.",
                    fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )

                Spacer(Modifier.height(18.dp))

                if (account != null) {
                    ConnectedAccount(account, onDisconnect)
                } else {
                    when (phase) {
                        is SignInPhase.Waiting -> WaitingForCode(phase, onCancel = signIn::cancel)
                        is SignInPhase.Starting, is SignInPhase.Finishing -> Working()
                        else -> {
                            if (phase is SignInPhase.Failed) Failure(phase.sentence)
                            Connect(
                                pasting = pasting,
                                typed = typed,
                                onTyped = { typed = it },
                                onStart = {
                                    signIn.clearFailure()
                                    signIn.start()
                                },
                                onPaste = {
                                    signIn.clearFailure()
                                    pasting = true
                                },
                                onUseToken = {
                                    signIn.useToken(typed)
                                    typed = ""
                                },
                                onCancelPaste = {
                                    pasting = false
                                    typed = ""
                                },
                            )
                        }
                    }
                }

                Spacer(Modifier.height(6.dp))
                TextButton(onClick = leave, modifier = Modifier.fillMaxWidth()) {
                    Text("Close", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun ConnectedAccount(account: GitHubAccount, onDisconnect: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "@${account.login}",
                fontSize = 16.sp,
                fontWeight = FontWeight.Medium,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                // Which of the two it is, because revoking them happens in two different places and
                // "revoke it on GitHub" without saying where is not an instruction.
                text = when (account.source) {
                    GitHubAccount.Source.SignIn -> "Signed in. Revoke under Settings → Applications on GitHub."
                    GitHubAccount.Source.Token -> "Personal access token. Revoke it in its own list on GitHub."
                },
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
    Spacer(Modifier.height(16.dp))
    Button(
        onClick = onDisconnect,
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        shape = RoundedCornerShape(12.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant,
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
    ) {
        Text("Disconnect", fontSize = 15.sp, fontWeight = FontWeight.Medium)
    }
    Spacer(Modifier.height(8.dp))
    Text(
        // The true claim and no more: this ends what *this phone* can answer. It does not reach
        // into GitHub, and saying it did would be a claim this app cannot keep.
        text = "Nothing on this phone can answer a machine's request afterwards.",
        fontSize = 12.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun Connect(
    pasting: Boolean,
    typed: String,
    onTyped: (String) -> Unit,
    onStart: () -> Unit,
    onPaste: () -> Unit,
    onUseToken: () -> Unit,
    onCancelPaste: () -> Unit,
) {
    if (!pasting) {
        Button(
            onClick = onStart,
            modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = MaterialTheme.colorScheme.primary,
                contentColor = MaterialTheme.colorScheme.onPrimary,
            ),
        ) {
            Text("Sign in with GitHub", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        }
        if (GitHubSignIn.CLIENT_IS_BORROWED) {
            Spacer(Modifier.height(8.dp))
            Text(
                // Said before the browser opens rather than left as a surprise on GitHub's own
                // consent page. It disappears on its own the day this project registers an app.
                text = "GitHub will name the app “GitHub CLI” — this project has not registered its own yet.",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.height(14.dp))
        TextButton(onClick = onPaste, modifier = Modifier.fillMaxWidth()) {
            Text("Paste a token instead", color = MaterialTheme.colorScheme.primary)
        }
        Spacer(Modifier.height(2.dp))
        Text(
            text = "A fine-grained token scoped to one repository, with an expiry.",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        return
    }

    OutlinedTextField(
        value = typed,
        onValueChange = onTyped,
        singleLine = true,
        label = { Text("Personal access token") },
        modifier = Modifier.fillMaxWidth(),
        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = ImeAction.Done),
    )
    Spacer(Modifier.height(12.dp))
    Button(
        onClick = onUseToken,
        enabled = typed.isNotBlank(),
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        shape = RoundedCornerShape(12.dp),
    ) {
        Text("Use this token", fontSize = 15.sp, fontWeight = FontWeight.Medium)
    }
    Spacer(Modifier.height(4.dp))
    TextButton(onClick = onCancelPaste, modifier = Modifier.fillMaxWidth()) {
        Text("Back", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun WaitingForCode(phase: SignInPhase.Waiting, onCancel: () -> Unit) {
    val context = LocalContext.current
    Text(
        text = "Type this code on GitHub:",
        fontSize = 13.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(Modifier.height(8.dp))
    // Selectable, because the alternative is somebody transcribing eight characters between two
    // screens on one phone. Mono, because it is exact and countable — which is what mono promises
    // everywhere in this product.
    SelectionContainer {
        Text(
            text = phase.userCode,
            fontSize = 28.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
    Spacer(Modifier.height(16.dp))
    Button(
        onClick = {
            // The plain verification URI, never `verification_uri_complete`: the "complete" one
            // fills the code in for you, which makes it a link that grants access if it is
            // forwarded or lands in a browser's history on a shared device.
            try {
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(phase.verificationUri)))
            } catch (e: ActivityNotFoundException) {
                // A phone with no browser at all. There is nothing useful to do about it and the
                // code is on screen either way, so this is deliberately silent rather than a
                // failure sentence about a state nobody is in.
            }
        },
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        shape = RoundedCornerShape(12.dp),
    ) {
        Text("Open GitHub", fontSize = 15.sp, fontWeight = FontWeight.Medium)
    }
    Spacer(Modifier.height(10.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(modifier = Modifier.width(14.dp).height(14.dp), strokeWidth = 2.dp)
        Spacer(Modifier.width(10.dp))
        Text(
            text = "Waiting for the code to be entered…",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    Spacer(Modifier.height(6.dp))
    TextButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) {
        Text("Cancel", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Working() {
    Row(verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(modifier = Modifier.width(16.dp).height(16.dp), strokeWidth = 2.dp)
        Spacer(Modifier.width(12.dp))
        Text(
            text = "Talking to GitHub…",
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun Failure(sentence: String) {
    Text(
        text = sentence,
        fontSize = 13.sp,
        color = MaterialTheme.colorScheme.secondary,
    )
    Spacer(Modifier.height(14.dp))
}

private val SHEET_SCRIM = Color(0x99000000)
