package dev.terminaldeck.android.ui

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.runtime.DisposableEffect
import dev.terminaldeck.android.alerts.AlertCenter
import dev.terminaldeck.android.alerts.AlertPermission
import dev.terminaldeck.android.alerts.AlertSettings
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * Alerts: the switches, and the sentence that says what they can and cannot do.
 *
 * ## The honest paragraph is the point of this screen
 *
 * Two switches would fit in a menu. What does not fit in a menu, and what a person deciding whether
 * to rely on this deserves before they do, is that a phone whose app has been killed is not
 * reachable: this product has no push service, so an alert can only be raised while the app's
 * process is alive. Everything that happened while it was gone is caught up on the next connection
 * and shown as a line at the top of the session list instead.
 *
 * Saying that costs a paragraph. Not saying it costs somebody a two-hour wait for a buzz that was
 * never coming, and that is the sort of thing an app is uninstalled over.
 *
 * ## Why the permission button is not a switch
 *
 * The system prompt can be asked once and a refusal is permanent as far as the app is concerned.
 * Before it, this screen offers a button that asks; after a refusal there is nothing this app can do
 * at all, so it says so and offers the Settings app, which is the only place it can be undone.
 * Drawing a switch for something the app cannot change would be a control that lies.
 *
 * ## Why it re-reads on resume
 *
 * The one thing this screen shows that it does not own is the system's answer, and the only place
 * that changes is the Settings app — which is to say, while this screen is in the background with
 * the button that sent somebody there still on it. Re-reading on resume is what stops a person
 * coming back to *"Alerts are off"* after having just turned them on.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AlertsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val colors = DeckTheme.colors

    var permission by remember { mutableStateOf(AlertCenter.permission(context)) }
    var needsYou by remember { mutableStateOf(AlertSettings.needsYou(context)) }
    var finished by remember { mutableStateOf(AlertSettings.finished(context)) }

    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        // The launcher's own boolean is about the dialog; the permission is re-read from the system
        // so this screen never shows an answer it inferred rather than one Android gave.
        permission = AlertCenter.permission(context)
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) permission = AlertCenter.permission(context)
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = "Alerts", onBack = onBack) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .padding(top = Space.x2, bottom = Space.x10),
        ) {
            when (permission) {
                AlertPermission.NotAsked -> {
                    Block(
                        title = "Get told when a machine needs you",
                        detail = "A session that stops and waits for an answer can put a notification " +
                            "on this phone, so you do not have to keep opening the app to check.",
                    )
                    Spacer(Modifier.height(Space.x5))
                    DeckPrimaryButton(
                        label = "Turn on alerts",
                        onClick = {
                            if (AlertCenter.asksPermission) {
                                ask.launch(android.Manifest.permission.POST_NOTIFICATIONS)
                            } else {
                                // Below Android 13 there is no prompt: the manifest declaration is
                                // the whole of it, and the only way this state is reachable is
                                // notifications switched off for the app in Settings.
                                openAppSettings(context)
                            }
                        },
                    )
                }

                AlertPermission.Denied -> {
                    Block(
                        title = "Alerts are off",
                        detail = "Notifications are turned off for Terminal Deck in the Settings app. " +
                            "Nothing here can turn them back on — that switch lives over there.",
                    )
                    Spacer(Modifier.height(Space.x5))
                    DeckQuietButton(label = "Open Settings", onClick = { openAppSettings(context) })
                }

                AlertPermission.Allowed -> {
                    Block(title = "Alerts are on", detail = "Choose what is worth interrupting you for.")
                    Spacer(Modifier.height(Space.x6))
                    DeckGroup {
                        SwitchRow(
                            title = "A session needs you",
                            detail = "It has stopped and is waiting for an answer. Makes a sound.",
                            checked = needsYou,
                            onCheckedChange = {
                                needsYou = it
                                AlertSettings.setNeedsYou(context, it)
                            },
                        )
                        DeckDivider(startIndent = Space.card)
                        SwitchRow(
                            title = "A session finishes",
                            detail = "The agent finished its turn, or the session ended. Silent.",
                            checked = finished,
                            onCheckedChange = {
                                finished = it
                                AlertSettings.setFinished(context, it)
                            },
                        )
                    }
                }
            }

            Spacer(Modifier.height(Space.x8))
            Text(
                text = "What this can and cannot reach",
                style = DeckType.footnote.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
                color = colors.secondary,
                modifier = Modifier.padding(start = Space.captionIndent),
            )
            DeckFootnote(
                "Alerts are raised by this app while its process is alive — open, or in the " +
                    "background until Android reclaims it. Terminal Deck has no notification " +
                    "server, so a phone whose app has been killed cannot be woken by a machine."
            )
            DeckFootnote(
                "Anything that happened while it was gone is picked up the next time the app " +
                    "connects, and the session list says what changed."
            )
        }
    }
}

/**
 * The one place outside this app that can change the answer above.
 *
 * `APPLICATION_DETAILS_SETTINGS` rather than `APP_NOTIFICATION_SETTINGS`, because the second does
 * not exist on every Android this app runs on and the first lands one tap away on all of them.
 */
private fun openAppSettings(context: android.content.Context) {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
        data = Uri.fromParts("package", context.packageName, null)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    try {
        context.startActivity(intent)
    } catch (_: android.content.ActivityNotFoundException) {
        // A device with no settings activity for this. Nothing to say — the sentence above already
        // explains where the switch lives, and a toast about a missing Settings app helps nobody.
    }
}

/**
 * A title and its paragraph, with the spacing the design brief asks for: the title brighter, the
 * description dimmer, and room between them.
 */
@Composable
private fun Block(title: String, detail: String) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(title, style = DeckType.title, color = colors.primary)
        Spacer(Modifier.height(Space.x2))
        Text(detail, style = DeckType.control, color = colors.secondary)
    }
}

/**
 * One kind of alert, and whether it is on.
 *
 * A real `Switch` here rather than the check the server-settings rows use, and the difference is
 * which side owns the value: this one is a preference on this phone that takes effect the instant it
 * is flipped, so the pending-then-settles animation a Material switch draws is telling the truth.
 */
@Composable
private fun SwitchRow(
    title: String,
    detail: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Space.card, vertical = Space.x3),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = DeckType.body, color = colors.primary)
            Spacer(Modifier.height(Space.half))
            Text(detail, style = DeckType.caption, color = colors.faint)
        }
        Spacer(Modifier.width(Space.x3))
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
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
