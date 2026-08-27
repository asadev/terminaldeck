package dev.terminaldeck.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Contrast
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Web
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.runtime.DisposableEffect
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import dev.terminaldeck.android.DeckUiState
import dev.terminaldeck.android.alerts.AlertCenter
import dev.terminaldeck.android.alerts.AlertPermission
import dev.terminaldeck.android.alerts.AlertSettings
import dev.terminaldeck.android.protocol.ServerSettingKey
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckRow
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.Space
import dev.terminaldeck.android.ui.theme.currentAppearance

/**
 * Settings: the machines, the phone's own account, what this machine owns, and how the terminal is
 * drawn.
 *
 * The Android half of the change iOS made when the app stopped being one list with a `…` in the
 * corner. Everything that is not a session — the machine you are typing into, the device roster, the
 * GitHub account, the browser windows that can be watched, the terminal's text size — used to be
 * behind the switcher sheet, which is where features go to be undiscovered. This is the same
 * inventory, in the same order, on the same second tab.
 *
 * ## Why Machines is pushed from here rather than being a tab
 *
 * *"maybe this machines thing can go inside the settings this page overall… Here we can have a
 * section, we click and we reach to this page and we can connect."* Pairing a machine is done once;
 * a bottom tab is for the screens somebody moves between all day. The switcher in the session
 * list's title stays, because *which machine am I typing into* is worth one tap — and it is now
 * only that, with the management verbs here.
 *
 * ## Alerts and Appearance
 *
 * Both were gaps in the first pass of this screen and both are closed. **Alerts** is a real
 * permission, two real channels and real delivery — see [AlertCenter] — so the row states how many
 * kinds are on, or that the system has them switched off. **Appearance** is System/Light/Dark, and
 * this app is no longer dark whatever the phone says: the whole palette has both halves and the
 * window resolves one of them once, in `TerminalDeckTheme`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    state: DeckUiState,
    onMachines: () -> Unit,
    onDevices: () -> Unit,
    onWatch: () -> Unit,
    onAlerts: () -> Unit,
    onAppearance: () -> Unit,
    onApplyServerSetting: (ServerSettingKey, String) -> Unit,
) {
    val context = LocalContext.current
    val colors = DeckTheme.colors

    /*
     * The alert row's value is read on every resume rather than once.
     *
     * Both halves of it can change without this screen being touched: the switches move on the
     * Alerts screen a push away, and the system permission moves in the Settings app. A row that
     * said "2 kinds" after somebody had just turned notifications off would be the one line on this
     * screen that is wrong, and it would be wrong in the place people check.
     */
    var alertsValue by remember { mutableStateOf(alertsSummary(context)) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) alertsValue = alertsSummary(context)
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val appearance = currentAppearance()

    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = "Settings") },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .padding(top = Space.x3, bottom = Space.x8),
        ) {
            DeckGroup {
                DeckRow(
                    title = "Machines",
                    value = if (state.hosts.size == 1) "1 paired" else "${state.hosts.size} paired",
                    icon = Icons.Filled.Computer,
                    onClick = onMachines,
                )
                // Devices and Watch act on the machine on screen, so each is drawn only when that
                // machine advertised the capability behind it. An older machine, or a guest, sees
                // neither — exactly the screen it had before, not a row explaining a gap.
                state.devices?.let { devices ->
                    DeckDivider()
                    DeckRow(
                        title = "Devices",
                        value = devices.rows?.size?.let { count ->
                            if (count == 1) "1 device" else "$count devices"
                        } ?: "",
                        icon = Icons.Filled.PhoneAndroid,
                        onClick = onDevices,
                    )
                }
                state.watch?.let {
                    DeckDivider()
                    DeckRow(
                        title = "Watch browser",
                        icon = Icons.Filled.Web,
                        onClick = onWatch,
                    )
                }
                // GitHub is no longer a phone-wide row here: the login lives on the machine now, so
                // "Connect GitHub" is a section on the machine's own page — see [ConnectGitHubSection].
            }

            SectionCaption("This phone")
            DeckGroup {
                DeckRow(
                    title = "Alerts",
                    value = alertsValue,
                    icon = Icons.Filled.Notifications,
                    onClick = onAlerts,
                )
                DeckDivider()
                DeckRow(
                    title = "Appearance",
                    value = appearance.label,
                    icon = Icons.Filled.Contrast,
                    onClick = onAppearance,
                )
            }

            // Phone-local, like Alerts and Appearance above it, and off until somebody moves it. The
            // switch is behind the screen lock in both directions — see [AppLockSection] and [AppLock].
            AppLockSection(appLock())

            state.serverSettings?.let { settings ->
                SectionCaption("This server")
                ServerSettingsSection(view = settings, onApply = onApplyServerSetting)
            }

            // The terminal's text size moved to the Appearance page on 2026-08-26
            // (B4): it is a terminal appearance setting and belongs with the
            // terminal's other appearance settings there, not buried in this
            // general list. See [AppearanceScreen].

            SectionCaption("About")
            DeckGroup {
                DeckRow(
                    title = "Terminal Deck",
                    value = state.clientVersion,
                    icon = Icons.Filled.Info,
                )
                if (state.hostAppVersion.isNotEmpty()) {
                    DeckDivider()
                    DeckRow(
                        title = "This ${state.machineNoun}",
                        value = state.hostAppVersion,
                        icon = if (state.hostKind == "headless") Icons.Filled.Dns else Icons.Filled.Computer,
                    )
                }
            }
            // Only when this app is genuinely ahead of the machine — default-closed in
            // [DeckUiState.serverBehindSentence]. No button: the wire carries no update verb, so
            // this is a fact, not an action.
            state.serverBehindSentence?.let { DeckFootnote(it) }
            DeckFootnote(
                "This phone talks to your own machines. There is no notification server in " +
                    "Terminal Deck, so a phone whose app has been killed is caught up the next time " +
                    "it connects rather than woken."
            )
        }
    }
}

/**
 * What the Alerts row says without being opened.
 *
 * Three answers and they are not interchangeable: the system has them off, nobody has been asked,
 * or this many kinds are on. *"Off"* when the person switched both off is deliberately the same word
 * as *"Off"* when the system did — from the row's point of view they are the same fact, and which of
 * the two it was is the first thing the screen behind it says.
 */
private fun alertsSummary(context: android.content.Context): String =
    when (AlertCenter.permission(context)) {
        AlertPermission.Denied -> "Off"
        AlertPermission.NotAsked -> "Not set up"
        AlertPermission.Allowed -> when (AlertSettings.enabledCount(context)) {
            0 -> "Off"
            1 -> "1 kind"
            else -> "2 kinds"
        }
    }
