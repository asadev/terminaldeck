package dev.terminaldeck.android.ui.kit

import android.app.Dialog
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import dev.terminaldeck.android.ui.theme.DeckTheme

/**
 * Paint a sheet's **own window** in the app's appearance.
 *
 * A `ModalBottomSheet` is a [Dialog], and a dialog gets a window of its own. `enableEdgeToEdge` in
 * `MainActivity` decorates the *activity's* window and reaches nothing else — so a sheet opened in
 * the dark theme sat over a light navigation bar, with light icons on light. Seen on a Pixel 2 at
 * API 31 on 2026-08-22: the session-details sheet, dark, with a white bar under it.
 *
 * Called from inside a sheet's content, which is where a `DialogWindowProvider` is reachable.
 * A no-op anywhere else, so it cannot be wrong when a screen is not in a dialog.
 */
@Composable
fun DeckSheetChrome() {
    val view = LocalView.current
    val colors = DeckTheme.colors
    val scrim = colors.background.toArgb()
    val dark = colors.isDark
    SideEffect {
        val window = (view.parent as? DialogWindowProvider)?.window ?: return@SideEffect
        window.navigationBarColor = scrim
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        val controller = WindowCompat.getInsetsController(window, view)
        // The **icons**, not the bar: `isAppearanceLight*` means "the bar is light, so draw dark
        // icons on it". Which is the opposite of the flag's name read quickly, and is the reason a
        // dark sheet with this set wrong shows a bar with nothing visible on it at all.
        controller.isAppearanceLightNavigationBars = !dark
        controller.isAppearanceLightStatusBars = !dark
    }
}
