package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.DeckUiState
import dev.terminaldeck.android.transport.TransportState
import dev.terminaldeck.android.transport.detail

/**
 * Pairing, and the wait that follows it.
 *
 * ## Four states, not one screen with a spinner
 *
 * - **No pairing.** A field for the code and a button for the camera.
 * - **Paired, waiting for approval.** The pairing worked; a human has to press a button on the
 *   machine. This is not an error and is deliberately not drawn as one — it is the normal path, and
 *   the client polls it on the reconnect schedule rather than making the user retry.
 * - **A code, and nothing at the other end of it.** The phone has stored a pairing code and nothing
 *   has ever answered it. New, and the reason for this rewrite.
 * - **Refused.** The credential is gone and the only way forward is a new code.
 *
 * The waiting state is the one that matters. `device-auth.ts` will not admit a device until
 * someone approves it, so a client that treated the refusal as a failure would send people back to
 * scan the QR again — spending a second single-use token to reach the same wait.
 *
 * ## Why the third state had to be split out of the second
 *
 * This screen used to decide "waiting for approval" from `pairing != null && !approved`, which is
 * true from the instant a code is *parsed* — before a byte has been sent. So while the client's
 * handshake was failing on every single attempt, the header said **"Paired with a Mac. Waiting to
 * be let in."** directly above a card reading **"Could not reach that Mac."** Both sentences on
 * screen at once, and only the second one true.
 *
 * That is not a wording bug. It is a screen that renders a total connection failure as a
 * successful pairing awaiting a human — which is precisely the disguise that let a client unable
 * to complete a single handshake look like it was working normally, for as long as nobody looked
 * at a packet. The failure now gets its own words, its own card and no spinner, and the claim
 * "paired, waiting" is made only when the machine has actually answered: see
 * [DeckUiState.awaitingApproval].
 *
 * ## Why every sentence here says "desktop" and not "Mac"
 *
 * It is the other half of the same honesty, and it is not a hedge. `welcome.hostPlatform` is what
 * tells a client what kind of computer it is talking to, and on this screen it has usually not
 * arrived: `server.ts` sends the field on the `welcome` that *admits* a device and deliberately not
 * on the one that mints a credential and then refuses — so a phone waiting for approval genuinely
 * does not know. [DeckUiState.machineNoun] answers "desktop" until something says otherwise, and
 * that word is threaded through every sentence below rather than any of them naming a machine.
 *
 * The alternative is what was here before: the literal word "Mac" in eleven sentences, shown to
 * whoever had scanned the code. A Windows user was told to go and approve a device on "the Mac".
 *
 * ## The fingerprints are shown, not hidden behind a details link
 *
 * Both of them: the machine's, so the person can see the same six groups the desktop is showing,
 * and this phone's, so they can find the right row in the desktop's approval list. Neither is secret
 * and neither is a security boundary on its own, but they are what turns "trust this device" from
 * a dialog you dismiss into one you can check.
 */
@Composable
fun PairingScreen(
    state: DeckUiState,
    onPair: (String) -> Unit,
    onScan: () -> Unit,
    onForget: () -> Unit,
    onRetry: () -> Unit,
    /**
     * Back to the machines that already work.
     *
     * Null while this is the first machine — there is genuinely nowhere to go, and a Cancel that
     * leads to an empty app is worse than no Cancel. Non-null the moment one machine has been let
     * in, because from then on this screen is something the user opened rather than the state of the
     * app, and a screen with no way out is how "add a machine" becomes "my phone forgot my machine".
     */
    onCancel: (() -> Unit)? = null,
) {
    var code by remember { mutableStateOf("") }
    /*
     * What to call the computer at the other end, in every sentence on this screen.
     *
     * Read once into a local so the eleven sentences below cannot disagree with each other — and,
     * more to the point, so there is one place to look when asking what this screen claims to know.
     * Usually "desktop" here, and that is correct rather than vague: see the header.
     */
    val noun = state.machineNoun
    /*
     * Adding wins over everything below it.
     *
     * The user asked for an empty field, and the machine on screen may be perfectly happy — so
     * without this the "add a machine" tap would land on a card describing the machine they already
     * have, which reads as the tap having done nothing.
     */
    val adding = state.addingHost
    // Three mutually exclusive readings of the same stored code. `awaitingApproval` requires the
    // machine to have answered; `unreachable` is the case that used to borrow the first one's words.
    val awaitingApproval = !adding && state.awaitingApproval
    val unreachable = !adding && state.hostUnreachable
    // A refusal is not an unreachable machine and must not borrow its words either — same mistake,
    // one state along. `Rejected` clears the credential but leaves the pairing record, so without
    // this branch a refused phone reads "Paired with a desktop that is not answering" over a card
    // saying the desktop refused it.
    val refused = unreachable &&
        (state.transport is TransportState.Rejected || state.transport is TransportState.Incompatible)

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
                text = if (adding) "Add a machine" else "Terminal Deck",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier.weight(1f),
            )
            // Only when there is somewhere to go back to. See `onCancel`.
            onCancel?.let {
                TextButton(onClick = it) { Text("Your machines") }
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(
            text = when {
                // Nothing is claimed about any machine here: the user asked for a field.
                adding -> "Pair this phone with another computer. The ones you already have stay " +
                    "paired and stay connected."
                // It answered on this attempt and asked for a human. The only case in which the
                // claim "paired, waiting" is true of the present tense.
                awaitingApproval -> "Paired with a $noun. Waiting to be let in."
                // Answered, and said no. Not the same as silence, and waiting will not change it.
                refused && state.transport is TransportState.Incompatible ->
                    "That $noun and this app speak different versions."
                refused -> "That $noun refused this phone."
                // It has answered before but is not answering now — a true and useful distinction
                // from the case below, because the pairing itself is fine.
                unreachable && state.hostEverAnswered -> "Paired with a $noun that is not answering."
                // And here nothing has ever answered. Says what is actually known: a code was
                // entered. Claims nothing on the machine's behalf, because it has said nothing —
                // including what kind of machine it is, which is why `noun` is at its most neutral
                // on exactly this branch.
                unreachable -> "This phone has a code for a $noun it cannot reach."
                else -> "Pair this phone with your $noun."
            },
            style = MaterialTheme.typography.bodyMedium,
            color = if (unreachable) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(20.dp))

        when {
            awaitingApproval -> WaitingCard(state, noun, onRetry, onForget)
            unreachable -> UnreachableCard(state, noun, onRetry, onForget)
            else -> EnterCard(
                code = code,
                noun = noun,
                error = state.pairingError,
                onCode = { code = it },
                onPair = { onPair(code) },
                onScan = onScan,
            )
        }

        Spacer(Modifier.height(24.dp))
        FingerprintRow("This phone", state.deviceFingerprint)
        // Not while adding: those rows describe the machine already on screen, and printing its key
        // under a form for a different computer is the screen answering a question nobody asked.
        state.pairing?.takeIf { !adding }?.let {
            Spacer(Modifier.height(10.dp))
            FingerprintRow("That machine", it.hostFingerprint)
            Spacer(Modifier.height(10.dp))
            FingerprintRow("Relay", it.relayUrl)
        }
    }
}

@Composable
private fun EnterCard(
    code: String,
    /**
     * What to call the machine holding the code, from [DeckUiState.machineNoun].
     *
     * Passed in rather than defaulted to a word, because a default is how a screen quietly keeps
     * saying "desktop" after the machine has told it what it is — and, in the other direction, how
     * a hardcoded "Mac" survives a rewrite meant to remove it.
     */
    noun: String,
    error: String?,
    onCode: (String) -> Unit,
    onPair: () -> Unit,
    onScan: () -> Unit,
) {
    Card {
        Text(
            text = "On the $noun, open Terminal Deck → Remote → Pair a device. " +
                "Scan the code, or paste the link it shows.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(16.dp))
        OutlinedTextField(
            value = code,
            onValueChange = onCode,
            label = { Text("Pairing link") },
            placeholder = { Text("terminaldeck://pair#…") },
            singleLine = false,
            maxLines = 3,
            isError = error != null,
            supportingText = error?.let { { Text(it, color = MaterialTheme.colorScheme.error) } },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            colors = OutlinedTextFieldDefaults.colors(
                focusedTextColor = MaterialTheme.colorScheme.onSurface,
                unfocusedTextColor = MaterialTheme.colorScheme.onSurface,
                focusedBorderColor = MaterialTheme.colorScheme.primary,
                unfocusedBorderColor = MaterialTheme.colorScheme.outline,
            ),
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = onPair,
                enabled = code.isNotBlank(),
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
                modifier = Modifier.weight(1f),
            ) { Text("Pair") }
            TextButton(onClick = onScan, modifier = Modifier.weight(1f)) { Text("Scan QR") }
        }
    }
}

/**
 * The machine answered and asked for a human. The genuine wait, and the only card that may say so.
 *
 * It used to carry a `refused` branch that dimmed the spinner and reddened the text, because this
 * card was shown for every unapproved state including the failing ones. It is now reached only from
 * [DeckUiState.awaitingApproval] — which requires [TransportState.Pending], which requires the
 * machine to have answered on this attempt — so the spinner is unconditional and honest: something
 * really is in progress, and it really is a person.
 */
@Composable
private fun WaitingCard(state: DeckUiState, noun: String, onRetry: () -> Unit, onForget: () -> Unit) {
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(
                strokeWidth = 2.dp,
                color = MaterialTheme.colorScheme.secondary,
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.width(12.dp))
            Text(
                text = state.transport.detail,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
        Spacer(Modifier.height(12.dp))
        Text(
            // The one sentence on this screen that sends a person walking to a machine, and so the
            // one that suffers most from naming the wrong kind. It reads "desktop" here by design:
            // the welcome that mints a credential and then refuses carries no `hostPlatform`, so at
            // this exact moment nothing has said what the machine is. `ios/Harness/host-standin.ts`
            // reproduces that omission on purpose rather than being more generous than the product.
            text = "Approve this phone in Terminal Deck on the $noun. It keeps checking on its own " +
                "— there is nothing to do here.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = onRetry,
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) { Text("Check now") }
            TextButton(onClick = onForget) { Text("Use a different code") }
        }
    }
}

/**
 * A code is stored and nothing has ever answered it.
 *
 * Deliberately *not* the waiting card with different words. No spinner, because a spinner next to
 * a state that is failing is its own kind of lie — the retries are real but there is nothing to
 * wait for yet. No instruction to go and approve anything either: telling someone to press a button
 * on a machine that has never heard from this phone sends them to the wrong room, which is exactly
 * what this screen did while the handshake was one byte short.
 *
 * What it says instead is what is actually known: the phone is trying, this is why it might be
 * failing, and here is what can be done about it. Which extends to the noun — a machine that has
 * never answered has never said what it is, so this card is the last place that may guess.
 */
@Composable
private fun UnreachableCard(state: DeckUiState, noun: String, onRetry: () -> Unit, onForget: () -> Unit) {
    val transport = state.transport

    Card {
        Text(
            text = transport.detail,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.error,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            text = when {
                // A version mismatch is not fixed by a new code, and offering one would send
                // someone round a loop that cannot end.
                transport is TransportState.Incompatible ->
                    "Update whichever of the two is older. Pairing again will reach the same refusal."
                transport is TransportState.Rejected ->
                    "That $noun refused this phone. A new pairing code is the only way forward."
                // Paired for real, and now unreachable. Approving it changes nothing until the two
                // can reach each other, and saying "go and approve it" would send someone to the
                // wrong room — which is what this screen used to do.
                state.hostEverAnswered ->
                    "This phone is paired but not approved yet, and the $noun is not answering. " +
                        "Approving it will not help until the two can reach each other — check that " +
                        "the $noun is awake and that Terminal Deck is running on it."
                else ->
                    "The code was accepted by this phone, but that $noun has never answered it. " +
                        "Check that Terminal Deck is running and awake on the $noun, that both are " +
                        "online, and that the code has not expired."
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        (transport as? TransportState.Waiting)?.let {
            Spacer(Modifier.height(8.dp))
            Text(
                text = "Tried ${it.attempts} time${if (it.attempts == 1) "" else "s"} so far.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.height(14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = onRetry,
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) { Text("Try again") }
            TextButton(onClick = onForget) { Text("Use a different code") }
        }
    }
}

@Composable
private fun Card(content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(14.dp))
            .padding(18.dp),
    ) { content() }
}

@Composable
private fun FingerprintRow(label: String, value: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.outline)
        )
        Spacer(Modifier.width(10.dp))
        Column {
            Text(
                text = label.uppercase(),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = value,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}
