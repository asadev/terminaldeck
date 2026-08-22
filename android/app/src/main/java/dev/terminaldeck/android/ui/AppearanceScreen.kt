package dev.terminaldeck.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckSegmented
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.theme.Appearance
import dev.terminaldeck.android.ui.theme.AppearanceStore
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.Space
import dev.terminaldeck.android.ui.theme.currentAppearance

/**
 * System, Light or Dark — one control, and it takes effect on the press.
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
 * ## Why the terminal is named out loud
 *
 * Because it is the one surface where a person might reasonably expect the setting **not** to apply,
 * and it does: the emulator's palette is installed from the resolved appearance in `MainActivity`,
 * so a session opened in Light is drawn on paper rather than on ink. Saying so is cheaper than
 * somebody choosing Light, seeing their terminal go white, and assuming it is broken.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppearanceScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val colors = DeckTheme.colors
    val current = currentAppearance()
    val options = Appearance.entries

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
                    "too — a session opened in Light is drawn dark-on-paper."
            )
        }
    }
}
