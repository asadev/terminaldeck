package dev.terminaldeck.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.terminaldeck.android.credential.CredentialQuestion
import dev.terminaldeck.android.github.GitHubAccount
import dev.terminaldeck.android.protocol.CredentialOperation

/**
 * The approval prompt — the one screen that is the entire explanation of the credential proxy.
 *
 * There is deliberately no paragraph anywhere in this app saying that the token is never stored on
 * the other machine. Asad cut that copy and he is right: a sentence in a settings pane that nobody
 * reads is not security, it is decoration. What is left is this, and this has to carry the whole
 * idea in three lines:
 *
 *  - **the repository**, so an approval is about one thing and not about everything the account can
 *    reach;
 *  - **the account**, so somebody can see whose name goes on the commit;
 *  - **the machine that asked, by name**, which is the line that makes it a question rather than a
 *    formality. "Approve a push" is not answerable. "Approve a push from *Work PC*" is.
 *
 * ## When the repository has no name
 *
 * The desktop sends null when git gave it no path to derive one from — a gist, a wiki, a
 * self-hosted layout — and this says so rather than inventing a name. That is not pedantry: the one
 * screen in this feature that exists to tell the truth about what is being approved must not be
 * capable of naming the wrong thing. "Always for this repo" disappears with it, because there is
 * nothing to attach the always to and the desktop refuses to record one.
 *
 * ## Back is Deny, not dismiss
 *
 * The far end is a `git push` sitting on a socket. Leaving without deciding would make it wait out
 * the full minute and then fail with "nobody answered on your device" — a worse outcome than either
 * button, and one nobody would have chosen on purpose. So there is no way off this sheet that is
 * not an answer: the scrim does not close it, and the system back gesture *denies*, which is what
 * back means everywhere else on this platform and is the safe half of the two.
 *
 * ## Drawn in this composition rather than as a `Dialog`
 *
 * The same reason `HostSwitcherSheet` is: a second window takes its system-bar appearance from the
 * *system* light/dark setting rather than from this app's theme, so on a phone set to light it
 * paints a white navigation bar under an all-black app.
 */
@Composable
fun CredentialPromptSheet(
    question: CredentialQuestion,
    /** The account whose name goes on the commit, if there still is one. */
    account: GitHubAccount?,
    /** How many more questions are behind this one. Zero is the normal case. */
    queued: Int,
    onApprove: (remember: Boolean) -> Unit,
    onDeny: () -> Unit,
) {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }

    BackHandler(onBack = onDeny)

    Box(modifier = Modifier.fillMaxSize()) {
        AnimatedVisibility(visible = shown, enter = fadeIn(), exit = fadeOut()) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(PROMPT_SCRIM)
                    // Swallows taps rather than closing. A tap outside is not one of the three
                    // answers, and there is a `git push` waiting on one of them.
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = {},
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
                    .navigationBarsPadding()
                    .padding(start = 24.dp, end = 24.dp, top = 26.dp, bottom = 18.dp),
            ) {
                Text(
                    text = title(question),
                    fontSize = 21.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )

                if (question.repo != null) {
                    Spacer(Modifier.height(6.dp))
                    // Mono because it is data: an `owner/name` is a thing somebody typed and can
                    // check character by character, which is exactly what this line is for.
                    Text(
                        text = question.repo,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Medium,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }

                Spacer(Modifier.height(22.dp))

                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    PromptRow("Account", account?.let { "@${it.login}" } ?: "none connected", mono = true)
                    PromptRow("Host", question.origin, mono = true)
                    // The line the whole prompt turns on. Not mono: it is the name a person gave
                    // their machine, which is prose rather than data.
                    PromptRow("Asked by", question.machineName, mono = false)
                }

                if (queued > 0) {
                    Spacer(Modifier.height(14.dp))
                    Text(
                        // Said rather than left as a surprise: answering this one puts another
                        // question on screen, and a sheet that reappeared unannounced reads as a
                        // tap that did not take.
                        text = if (queued == 1) "1 more question after this one." else "$queued more questions after this one.",
                        fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                Spacer(Modifier.height(24.dp))

                Button(
                    onClick = { onApprove(false) },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.primary,
                        contentColor = MaterialTheme.colorScheme.onPrimary,
                    ),
                ) {
                    Text("Approve", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }

                // Only when there is a repository to remember. See the header.
                if (question.repo != null) {
                    Spacer(Modifier.height(10.dp))
                    Button(
                        onClick = { onApprove(true) },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                        shape = RoundedCornerShape(12.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.surfaceVariant,
                            contentColor = MaterialTheme.colorScheme.onSurface,
                        ),
                    ) {
                        Text("Always for this repo", fontSize = 15.sp, fontWeight = FontWeight.Medium)
                    }
                }

                Spacer(Modifier.height(4.dp))
                TextButton(
                    onClick = onDeny,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 46.dp),
                ) {
                    Text(
                        text = "Deny",
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

/**
 * The question, in the words of whatever git is doing.
 *
 * `prompt` is true for a push in every case a desktop sends today, but the verb is read off
 * `operation` rather than assumed: the two are separate fields precisely so a client can say what
 * is happening rather than what it expected to happen.
 */
private fun title(question: CredentialQuestion): String {
    val verb = if (question.operation == CredentialOperation.Write) "Push" else "Sign in"
    if (question.repo == null) return "$verb to a repository on ${question.origin}?"
    return if (question.operation == CredentialOperation.Write) {
        "Push to this repository?"
    } else {
        "Sign in to this repository?"
    }
}

@Composable
private fun PromptRow(label: String, value: String, mono: Boolean) {
    Row(verticalAlignment = Alignment.Top, modifier = Modifier.fillMaxWidth()) {
        Text(
            text = label,
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(78.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = value,
            fontSize = if (mono) 13.sp else 14.sp,
            fontWeight = if (mono) FontWeight.Medium else FontWeight.Normal,
            fontFamily = if (mono) FontFamily.Monospace else null,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}

/** Darker than the switcher's, because this one is a question rather than a menu. */
private val PROMPT_SCRIM = Color(0xCC000000)
