package dev.terminaldeck.android.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * Terminal Deck's palette, such as it is.
 *
 * Dark, and dark regardless of the system setting. That is a deliberate refusal rather than an
 * unfinished light theme: the whole screen below the app bar is a terminal, terminals are dark, and
 * a white chrome wrapped around a black rectangle reads as two applications sharing a window. Apps
 * that own a single dark canvas — editors, video players, camera viewfinders — all make the same
 * call.
 *
 * The colours are here rather than pulled from `src/shared/brand.ts` because that file is
 * TypeScript in the desktop build and there is no shared source of truth across the two yet.
 */
private val DeckGreen = Color(0xFF3DDC84)
private val DeckInk = Color(0xFF0B0D10)
private val DeckSurface = Color(0xFF14171C)
private val DeckSurfaceHigh = Color(0xFF1D2128)
private val DeckOutline = Color(0xFF2A2F38)
private val DeckText = Color(0xFFE6E9EF)
private val DeckMuted = Color(0xFF8B93A1)
private val DeckAmber = Color(0xFFE3B341)

private val DarkColors = darkColorScheme(
    primary = DeckGreen,
    onPrimary = DeckInk,
    secondary = DeckAmber,
    background = DeckInk,
    onBackground = DeckText,
    surface = DeckSurface,
    onSurface = DeckText,
    surfaceVariant = DeckSurfaceHigh,
    onSurfaceVariant = DeckMuted,
    outline = DeckOutline,
    outlineVariant = DeckOutline,
)

private val DeckTypography = Typography(
    titleLarge = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold),
    titleMedium = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium),
    bodyMedium = TextStyle(fontSize = 14.sp),
    bodySmall = TextStyle(fontSize = 12.sp, fontFamily = FontFamily.Monospace),
    labelSmall = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.6.sp),
)

@Composable
fun TerminalDeckTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = DarkColors,
        typography = DeckTypography,
        content = content,
    )
}
