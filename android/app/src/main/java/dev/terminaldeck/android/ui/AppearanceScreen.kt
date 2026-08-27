package dev.terminaldeck.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.store.TerminalTextSize
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckRow
import dev.terminaldeck.android.ui.kit.DeckSegmented
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.theme.Appearance
import dev.terminaldeck.android.ui.theme.AppearanceStore
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space
import dev.terminaldeck.android.ui.theme.TerminalSchemeStore
import dev.terminaldeck.android.ui.theme.TerminalSchemes
import dev.terminaldeck.android.ui.theme.currentAppearance

/**
 * System, Light or Dark — and, underneath it, what the terminal itself is painted in.
 *
 * Asad, of the other client: *"mobile iOS is only dark mode — it should have both, in settings."*
 * Android was in the same state and worse: pinned dark in four places, none of which any screenshot
 * on a dark phone would have shown. [Appearance] carries the whole argument for the three choices
 * and for System being the default.
 *
 * ## Why there is no Apply
 *
 * The store is written on the tap and the window resolves the appearance on every recomposition, so
 * the whole app is repainted behind this screen while the finger is still on it. That is the answer
 * to *did that do anything* — a confirm button here would put a step between a choice and its only
 * observable effect.
 *
 * ## Why the terminal has its own row now
 *
 * Because the two settings answer different questions and one of them used to answer both. The
 * app's appearance decides the chrome; the terminal's scheme decides the ninety per cent of the
 * screen that is program output — and Asad asked for that to be a choice, on *"phone also, for
 * Windows, for MacBook, all of them"*. Folding it into System/Light/Dark would mean somebody who
 * wants a black terminal on a light phone cannot have one, which is one of the more ordinary things
 * to want.
 *
 * The row still names the terminal on this screen, because this is where somebody comes looking. It
 * carries the current scheme's name as its value, so the answer to *what is my terminal set to* does
 * not require opening anything.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppearanceScreen(onBack: () -> Unit, onTerminalColours: () -> Unit) {
    val context = LocalContext.current
    val colors = DeckTheme.colors
    val current = currentAppearance()
    val options = Appearance.entries
    val dark = current.isDark(LocalConfiguration.current)

    // Terminal text size — a global stepper, phone-wide like the scheme above it.
    // It moved here from the main Settings list on 2026-08-26 (B4): it is a
    // terminal *appearance* setting, so it belongs on the Appearance page with
    // the terminal's other appearance settings rather than buried among the
    // app's general ones. Only the placement changed — it is the same one stepper
    // reading and writing the same `TerminalTextSize` store.
    var textSize by remember { mutableIntStateOf(TerminalTextSize.load(context)) }

    // Subscribes to both, so choosing a scheme two screens down updates this row on the way back.
    val chosenId = TerminalSchemeStore.selectedId.value ?: TerminalSchemes.MATCH_APPEARANCE
    TerminalSchemeStore.customSchemes.value
    val schemeName =
        if (chosenId == TerminalSchemes.MATCH_APPEARANCE) "Match appearance"
        else TerminalSchemeStore.scheme(chosenId)?.name ?: "Match appearance"

    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = "Appearance", onBack = onBack) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = Space.screen),
        ) {
            SectionCaption("Appearance")
            DeckSegmented(
                options = options.map { it.label },
                selectedIndex = options.indexOf(current),
                onSelect = { AppearanceStore.set(context, options[it]) },
            )
            DeckFootnote(
                "System follows the phone, including its dark schedule. The terminal follows this " +
                    "too, unless you give it colours of its own below."
            )

            Spacer(Modifier.height(Space.x5))
            SectionCaption("Terminal")
            DeckGroup {
                DeckRow(
                    title = "Terminal colours",
                    value = schemeName,
                    icon = Icons.Filled.Palette,
                    onClick = onTerminalColours,
                    modifier = Modifier.testTag("row.terminalColours"),
                )
                DeckDivider()
                // Moved here from the main Settings list, unchanged: the same
                // global stepper, now beside the terminal's other appearance
                // settings where somebody comes looking for it.
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = Space.card, end = Space.x1, top = Space.x2, bottom = Space.x2),
                ) {
                    Icon(
                        Icons.Filled.TextFields,
                        contentDescription = null,
                        tint = colors.secondary,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(Space.x3))
                    Text(
                        text = "Text size",
                        style = DeckType.body,
                        color = colors.primary,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = TerminalTextSize.label(textSize),
                        style = DeckType.monoValue,
                        color = colors.faint,
                    )
                    IconButton(
                        enabled = TerminalTextSize.canGoSmaller(textSize),
                        onClick = {
                            textSize = TerminalTextSize.smaller(textSize)
                            TerminalTextSize.save(context, textSize)
                        },
                    ) {
                        Icon(Icons.Filled.Remove, contentDescription = "Smaller terminal text", tint = colors.secondary)
                    }
                    IconButton(
                        enabled = TerminalTextSize.canGoLarger(textSize),
                        onClick = {
                            textSize = TerminalTextSize.larger(textSize)
                            TerminalTextSize.save(context, textSize)
                        },
                    ) {
                        Icon(Icons.Filled.Add, contentDescription = "Bigger terminal text", tint = colors.secondary)
                    }
                }
            }
            DeckFootnote(
                "Pure black, Solarized, Nord, Dracula and the rest — or your own. Changes reach an " +
                    "open session straight away."
            )
            DeckFootnote(
                "A session already open picks this up the next time you open it — the column count " +
                    "is the font, so changing it resizes the session on the machine."
            )
        }
    }
}
