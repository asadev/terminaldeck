package dev.terminaldeck.android.ui

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.AppLock
import dev.terminaldeck.android.AppLockAvailability
import dev.terminaldeck.android.AppLockStore
import dev.terminaldeck.android.caveat
import dev.terminaldeck.android.noun
import dev.terminaldeck.android.refusal
import dev.terminaldeck.android.title
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.InfoDot
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space
import kotlinx.coroutines.launch

/**
 * The two screens the app lock has — the switch that turns it on and the door it puts in front of the
 * app — plus the plain mark that stands in for the recents thumbnail. The Android half of
 * `ios/TerminalDeck/Screens/AppLockScreen.swift`.
 *
 * iOS presents the door in a `UIWindow` above the alert level so it covers sheets as well as the app.
 * This app's sheets are drawn inside the same composition rather than as separate windows (see the
 * note on `DeckSurfaces`), so the Android equivalent is simpler: [AppLockOverlay] is the last child
 * of the root `Box` in `TerminalDeckApp`, drawn on top of everything under it, and that is above every
 * one of them.
 */

/** The live lock for this composition. Reading its state below subscribes the caller to it. */
@Composable
fun appLock(): AppLock = AppLockStore.currentOrDefault()

/**
 * What sits over the app when it must not be seen: the door when locked, and the plain mark when the
 * app is merely on its way into the recents overview with the lock on. Mirrors iOS's `AppLockCover`.
 */
@Composable
fun AppLockOverlay(lock: AppLock) {
    if (lock.isLocked) AppLockScreen(lock) else AppLockShieldMark()
}

/**
 * A padlock on the theme's own ground: what fills the frame while the app is shielded but not yet
 * locked. `FLAG_SECURE` already blanks the actual recents thumbnail; this is what the person sees for
 * the instant between losing the foreground and the shield coming down again on return.
 */
@Composable
fun AppLockShieldMark() {
    val colors = DeckTheme.colors
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background)
            .swallowTouches(),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.Lock,
            contentDescription = null,
            tint = colors.faint,
            modifier = Modifier.size(34.dp),
        )
    }
}

/**
 * The door. One button, one sentence, and never a dead end behind it.
 *
 * The only ways off this screen are a successful authentication and — in the single state where
 * nothing could ever authenticate, a phone with no screen lock — the **Continue** button.
 */
@Composable
fun AppLockScreen(lock: AppLock) {
    val colors = DeckTheme.colors
    val scope = rememberCoroutineScope()
    val availability = lock.availability()
    val biometric = availability is AppLockAvailability.Biometric

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background)
            .swallowTouches(),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .padding(horizontal = Space.x8),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.weight(1f))

            Icon(
                imageVector = if (biometric) Icons.Filled.Fingerprint else Icons.Filled.Lock,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(44.dp),
            )
            Spacer(Modifier.height(Space.x5))

            Text(
                text = "Terminal Deck is locked",
                style = DeckType.question,
                color = colors.primary,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(Space.x2))

            Text(
                text = if (lock.stranded) {
                    "There is nothing left on this phone to unlock it with."
                } else {
                    "Unlock with ${availability.noun} to open it."
                },
                style = DeckType.control,
                color = colors.secondary,
                textAlign = TextAlign.Center,
            )

            lock.trouble?.let { trouble ->
                Spacer(Modifier.height(Space.x4))
                Text(
                    text = trouble,
                    style = DeckType.footnote,
                    color = colors.warning,
                    textAlign = TextAlign.Center,
                )
            }

            Spacer(Modifier.height(Space.x6))
            if (lock.stranded) {
                // The one state where pressing Unlock again could never help. Deleting the app is the
                // alternative, so this is the door: it opens, and Settings says what happened.
                DeckPrimaryButton(
                    label = "Continue",
                    onClick = { lock.continueWithoutLock() },
                )
            } else {
                DeckPrimaryButton(
                    label = if (lock.working) "Asking…" else "Unlock",
                    enabled = !lock.working,
                    onClick = { scope.launch { lock.unlock() } },
                )
            }

            Spacer(Modifier.weight(1f))

            Text(
                text = AppLockText.rule(availability),
                style = DeckType.caption,
                color = colors.faint,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(bottom = Space.x6),
            )
        }
    }

    /*
     * The prompt raises itself, and `promptToken` is what says when.
     *
     * `LaunchedEffect(promptToken)` runs once when this screen appears — the cold start — and again
     * each time the token moves, which [AppLock] does only when the app comes back from the background
     * to a still-locked screen. It deliberately does not move when the app merely goes inactive, so a
     * cancelled prompt is not re-raised for ever. This is the Compose equivalent of iOS's `.task(id:)`.
     */
    LaunchedEffect(lock.promptToken) {
        lock.unlock()
    }
}

/**
 * The switch, its caption, and whatever sentence the last attempt produced — dropped into
 * `SettingsScreen` as a single call, the way iOS drops `AppLockSection` into `DeckSettingsView`.
 *
 * The row is never hidden on a phone that cannot do this: it is disabled with the reason directly
 * underneath, so somebody looking for a feature they were told about finds out why it is unavailable
 * rather than failing to find it at all.
 */
@Composable
fun AppLockSection(lock: AppLock) {
    val colors = DeckTheme.colors
    val scope = rememberCoroutineScope()
    // Asked fresh on every draw, never cached — a screen lock can be removed and a fingerprint
    // enrolled while this app is in the background, and a cached answer is how a screen offers a
    // fingerprint to somebody who turned it off.
    val availability = lock.availability()
    val on = lock.enabled
    val biometric = availability is AppLockAvailability.Biometric

    // A sentence from an attempt made ten minutes ago is not news. It goes when the screen does.
    DisposableEffect(Unit) {
        onDispose { lock.clearTrouble() }
    }

    SectionCaption("Lock")
    DeckGroup {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Space.card, vertical = Space.x3),
        ) {
            Icon(
                imageVector = if (biometric) Icons.Filled.Fingerprint else Icons.Filled.Lock,
                contentDescription = null,
                tint = if (availability.canLock || on) colors.secondary else colors.faint,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(Space.x3))
            Text(
                text = availability.title,
                style = DeckType.body,
                color = colors.primary,
                modifier = Modifier.weight(1f),
            )
            InfoDot(about = "the app lock", text = AppLockText.GRACE)
            Spacer(Modifier.width(Space.x2))
            Switch(
                checked = on,
                // Off and impossible is disabled with the reason under it; already on stays switchable
                // whatever the phone can do now, because somebody whose screen lock changed still has
                // to be able to take the lock off.
                enabled = !lock.working && (availability.canLock || on),
                onCheckedChange = { wanted -> scope.launch { lock.setEnabled(wanted) } },
                colors = SwitchDefaults.colors(
                    checkedThumbColor = colors.onAccent,
                    checkedTrackColor = colors.accent,
                    uncheckedThumbColor = colors.faint,
                    uncheckedTrackColor = colors.surfaceHigh,
                    uncheckedBorderColor = colors.hairlineStrong,
                ),
            )
        }
    }

    lock.trouble?.let { DeckFootnote(it, color = colors.warning) }
    lock.notice?.let { DeckFootnote(it, color = colors.warning) }
    val refusal = availability.refusal
    if (refusal != null && !on) {
        DeckFootnote(refusal)
    } else {
        availability.caveat?.let { DeckFootnote(it) }
    }
    // The rule, not the mechanism — one line. The other half is behind the InfoDot above.
    DeckFootnote(AppLockText.line(availability))
}

/**
 * The sentences both screens say, written once so they cannot drift apart.
 *
 * [line] is the rule and goes under the switch, where a person is deciding. [GRACE] is the mechanism
 * and goes behind the InfoDot, where a person who has already been surprised goes looking. [rule] is
 * both, for the lock screen — a mostly empty screen with room for the whole thing — and it is built
 * from the other two rather than being a third copy.
 */
object AppLockText {

    /** **When it asks**, in one line, naming the thing this phone will actually put in front of you. */
    fun line(availability: AppLockAvailability): String =
        "Terminal Deck asks for ${availability.noun} when it starts, and again after " +
            "${AppLock.GRACE_WORDS} away."

    /** What does **not** count as having been away. Behind the InfoDot. */
    const val GRACE =
        "Coming back from the recents overview, another app or a notification for a moment does not ask."

    /** Both, for the lock screen, which has the room. */
    fun rule(availability: AppLockAvailability): String = "${line(availability)} $GRACE"
}

/**
 * Swallow taps so nothing behind an opaque cover can be reached through it — a no-op clickable with no
 * ripple, which is the lightest thing that actually consumes a press.
 */
@Composable
private fun Modifier.swallowTouches(): Modifier = this.clickable(
    interactionSource = remember { MutableInteractionSource() },
    indication = null,
) {}
