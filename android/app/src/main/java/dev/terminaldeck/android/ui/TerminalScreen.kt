package dev.terminaldeck.android.ui

import android.graphics.Typeface
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.InputMethodManager
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.termux.terminal.KeyHandler
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import dev.terminaldeck.android.session.RemoteSessionBinding
import dev.terminaldeck.android.transport.TransportState
import dev.terminaldeck.android.transport.detail
import dev.terminaldeck.android.transport.isOnline

/**
 * A remote session, rendered by Termux's `TerminalView`.
 *
 * The view is a plain Android `View` inside `AndroidView`, and that is the point: reimplementing a
 * VT emulator in Compose would be months of work to arrive somewhere behind where Termux already
 * is. What Compose owns here is the chrome — the bar, the key row, the insets — and nothing inside
 * the black rectangle.
 *
 * ## Why the redraw is driven from outside
 *
 * `TerminalView` does not observe anything. It repaints when someone calls `onScreenUpdated()`, and
 * upstream that someone is the activity's session client. Here the emulator is fed from a socket
 * thread, so the path is: bytes → `TerminalSession.feedOutput` → main-thread handler → emulator →
 * `onTextChanged` → a tick in the view model → this composable's `update` block → `onScreenUpdated`.
 * Long, but every hop is load-bearing, and the alternative — letting the transport call into the
 * view — is what makes a terminal crash on rotation.
 *
 * ## The strip that says the connection is gone
 *
 * A terminal that is still drawing its last screen while the socket is down is the failure this
 * whole client is written to avoid: someone types Ctrl+C into it and walks away believing the job
 * stopped. So when the transport is not [TransportState.Online] a strip appears over the bar with
 * the reason, and the key row goes with it — a key that cannot land should not look pressable.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalScreen(
    binding: RemoteSessionBinding,
    title: String,
    subtitle: String,
    screenTick: Long,
    transport: TransportState,
    onBack: () -> Unit,
    onKey: (String) -> Unit,
    onCopy: () -> Unit,
    onPaste: () -> Unit,
) {
    val context = LocalContext.current
    val client = remember(binding) { DeckTerminalViewClient() }
    var ctrlArmed by remember(binding) { mutableStateOf(false) }

    val terminalView = remember(binding) {
        TerminalView(context, null).apply {
            setTerminalViewClient(client)
            // setTextSize builds the renderer; setTypeface dereferences it. Order matters.
            setTextSize(TEXT_SIZE_PX)
            setTypeface(Typeface.MONOSPACE)
            isFocusable = true
            isFocusableInTouchMode = true
            keepScreenOn = true
            setBackgroundColor(TERMINAL_BACKGROUND)
            client.view = this
            attachSession(binding.session)
        }
    }

    // The key row's Ctrl has to reach the typing path too: a letter from the soft keyboard or a
    // hardware key while Ctrl is armed must produce a chord, which `TerminalView` asks about
    // through `readControlKey`. It also has to be *spent* there — see `consumeCtrl`.
    client.ctrl = { ctrlArmed }
    client.consumeCtrl = { ctrlArmed = false }

    // Without this the first focusable in the window is the back button, so a hardware keyboard —
    // or `adb shell input text` — drives the app bar instead of the terminal, and Enter navigates
    // back rather than running anything. Focus does not raise the soft keyboard on its own; that
    // stays an explicit tap on the keyboard button.
    LaunchedEffect(terminalView) { terminalView.requestFocus() }

    Scaffold(
        containerColor = Color(TERMINAL_BACKGROUND),
        topBar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(MaterialTheme.colorScheme.background)
                    // A hand-rolled top bar under `enableEdgeToEdge` gets no insets for free the
                    // way `TopAppBar` does, so without this the title draws under the clock.
                    .statusBarsPadding(),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
                ) {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back to sessions",
                            tint = MaterialTheme.colorScheme.onBackground,
                        )
                    }
                    Column(modifier = Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(
                                modifier = Modifier
                                    .size(7.dp)
                                    .clip(CircleShape)
                                    .background(
                                        if (transport.isOnline) MaterialTheme.colorScheme.primary
                                        else MaterialTheme.colorScheme.error
                                    )
                            )
                            Spacer(Modifier.width(7.dp))
                            Text(
                                text = title,
                                style = MaterialTheme.typography.titleMedium,
                                color = MaterialTheme.colorScheme.onBackground,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        Text(
                            text = subtitle,
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    IconButton(onClick = onCopy) {
                        Icon(
                            Icons.Filled.ContentCopy,
                            contentDescription = "Copy the whole transcript",
                            tint = MaterialTheme.colorScheme.onBackground,
                        )
                    }
                    IconButton(onClick = onPaste) {
                        Icon(
                            Icons.Filled.ContentPaste,
                            contentDescription = "Paste into the session",
                            tint = MaterialTheme.colorScheme.onBackground,
                        )
                    }
                    IconButton(onClick = {
                        terminalView.requestFocus()
                        val imm = context.getSystemService(InputMethodManager::class.java)
                        imm?.showSoftInput(terminalView, InputMethodManager.SHOW_IMPLICIT)
                    }) {
                        Icon(
                            Icons.Filled.Keyboard,
                            contentDescription = "Show keyboard",
                            tint = MaterialTheme.colorScheme.onBackground,
                        )
                    }
                }

                if (!transport.isOnline) {
                    Text(
                        text = transport.detail,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(MaterialTheme.colorScheme.error)
                            .padding(horizontal = 12.dp, vertical = 4.dp),
                    )
                }
            }
        },
        bottomBar = {
            KeyRow(
                enabled = transport.isOnline,
                ctrl = ctrlArmed,
                onPress = { key ->
                    val press = KeyBar.press(key, ctrlArmed)
                    ctrlArmed = press.ctrl
                    if (press.data.isNotEmpty()) onKey(press.data)
                },
                modifier = Modifier.imePadding().navigationBarsPadding(),
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 6.dp, vertical = 4.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color(TERMINAL_BACKGROUND)),
        ) {
            AndroidView(
                factory = { terminalView },
                modifier = Modifier.fillMaxSize(),
                update = { view ->
                    // `screenTick` has to be read *inside* this lambda. `AndroidView` reruns the
                    // update block when the lambda instance changes, and a lambda that captures
                    // nothing is memoised — so a version that only called `onScreenUpdated()` would
                    // paint the first frame and then never repaint again.
                    if (screenTick >= 0) view.onScreenUpdated()
                },
            )
        }
    }
}

/**
 * The key row.
 *
 * Scrolls horizontally rather than wrapping or shrinking: eleven keys do not fit across a phone at
 * a size a thumb can hit, and a row of 24dp targets is a row nobody uses. Ctrl shows its armed
 * state, because a sticky modifier the user cannot see is a modifier that fires on the wrong key.
 */
@Composable
private fun KeyRow(
    enabled: Boolean,
    ctrl: Boolean,
    onPress: (KeyBarKey) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.background)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 8.dp, vertical = 6.dp),
    ) {
        for (key in KEY_BAR) {
            val armed = key == KeyBarKey.Ctrl && ctrl
            Text(
                text = key.label,
                style = MaterialTheme.typography.titleMedium,
                color = when {
                    !enabled -> MaterialTheme.colorScheme.outline
                    armed -> MaterialTheme.colorScheme.onPrimary
                    else -> MaterialTheme.colorScheme.onSurface
                },
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .background(
                        when {
                            armed -> MaterialTheme.colorScheme.primary
                            else -> MaterialTheme.colorScheme.surfaceVariant
                        }
                    )
                    .clickable(enabled = enabled) { onPress(key) }
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            )
        }
    }
}

/**
 * The view's half of the Termux contract.
 *
 * Everything here is a policy decision about a phone with no physical keyboard, which is why it
 * lives in the UI layer rather than next to the protocol: none of it is a fact about the session,
 * and all of it would be answered differently on a tablet with a keyboard case.
 */
private class DeckTerminalViewClient : TerminalViewClient {

    /**
     * Set once, immediately after construction.
     *
     * The client and the view need each other — `TerminalView` calls `onScale` and expects the
     * client to apply the resulting font size — and one of the two references has to be late. This
     * one, because the view's constructor is the thing that cannot be deferred.
     */
    var view: TerminalView? = null

    /** Whether the key row's Ctrl is armed. Read on every key event and every code point. */
    var ctrl: () -> Boolean = { false }

    /**
     * Spend the armed Ctrl.
     *
     * Without this the modifier survives the key it applied to and fires again on the next one:
     * arming Ctrl and typing `c` interrupts the job, and then the next `l` is a Ctrl+L that clears
     * the screen nobody asked to clear. The key row spends its own presses in `KeyBar.press`; this
     * is the other half, for characters that arrive through the keyboard instead.
     */
    var consumeCtrl: () -> Unit = {}

    private var textSizePx = TEXT_SIZE_PX

    /**
     * Pinch to zoom.
     *
     * The contract is the odd part and is worth stating: `TerminalView` accumulates the gesture's
     * scale factor, hands it over, and adopts whatever comes back as the new accumulator. Returning
     * 1.0 after acting is how the gesture is consumed — return the input unchanged and the factor
     * keeps growing until a single pinch has resized the font ten times.
     */
    override fun onScale(scale: Float): Float {
        if (scale < 0.9f || scale > 1.1f) {
            val next = (if (scale > 1f) textSizePx + 2 else textSizePx - 2)
                .coerceIn(MIN_TEXT_SIZE_PX, MAX_TEXT_SIZE_PX)
            if (next != textSizePx) {
                textSizePx = next
                // This reflows the emulator, which reports a new size, which becomes a `resize`
                // frame. Zooming on the phone genuinely changes the width of the remote terminal.
                view?.setTextSize(next)
            }
            return 1f
        }
        return scale
    }

    override fun onSingleTapUp(e: MotionEvent?) = Unit

    /**
     * Back leaves the terminal; it does not send Escape.
     *
     * Termux maps it to Escape because Termux *is* the terminal. Terminal Deck has a session list
     * behind this screen, and a back gesture that silently sends a control character instead of
     * navigating is the kind of thing that loses someone's place in an agent conversation. Escape
     * is on the key row, where it is visible.
     */
    override fun shouldBackButtonBeMappedToEscape(): Boolean = false

    override fun shouldEnforceCharBasedInput(): Boolean = true

    override fun shouldUseCtrlSpaceWorkaround(): Boolean = false

    override fun isTerminalViewSelected(): Boolean = true

    override fun copyModeChanged(copyMode: Boolean) = Unit

    override fun onKeyDown(keyCode: Int, e: KeyEvent?, session: TerminalSession?): Boolean = false

    /**
     * The end of a hardware key press, and where an armed Ctrl is spent for keys that never become
     * a code point — the arrows and the function keys, which `TerminalView` routes through
     * `KeyHandler` instead.
     */
    override fun onKeyUp(keyCode: Int, e: KeyEvent?): Boolean {
        consumeCtrl()
        return false
    }

    /**
     * Returning false lets `TerminalView` start its own text selection, which is the whole copy
     * story: the selection handles, the action mode and its Copy item are Termux's, and Copy calls
     * back through `TerminalSessionClient.onCopyTextToClipboard`.
     */
    override fun onLongPress(event: MotionEvent?): Boolean = false

    override fun readControlKey(): Boolean = ctrl()

    override fun readAltKey(): Boolean = false

    override fun readShiftKey(): Boolean = false

    override fun readFnKey(): Boolean = false

    /**
     * Returning false hands the code point back to `TerminalView`, which encodes it through
     * [KeyHandler] and writes it to the session — which is exactly what should happen. Intercepting
     * here would mean reimplementing UTF-8 and control-key encoding badly.
     */
    override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession?): Boolean {
        // Called once per code point, *after* `readControlKey` has already been folded into
        // `ctrlDown` — which makes this the one place a sticky modifier can be spent without
        // stealing it from the key that armed it. `false` hands the code point back to
        // `TerminalView`, which encodes it through [KeyHandler] and writes it to the session.
        consumeCtrl()
        return false
    }

    override fun onEmulatorSet() = Unit

    override fun logError(tag: String?, message: String?) = Unit

    override fun logWarn(tag: String?, message: String?) = Unit

    override fun logInfo(tag: String?, message: String?) = Unit

    override fun logDebug(tag: String?, message: String?) = Unit

    override fun logVerbose(tag: String?, message: String?) = Unit

    override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) = Unit

    override fun logStackTrace(tag: String?, e: Exception?) = Unit
}

/**
 * Text size in pixels, not sp.
 *
 * `TerminalRenderer` takes a raw pixel size and derives the character cell from it, and the cell
 * is what decides how many columns the desktop is told about. Scaling it with the system font
 * setting would mean two phones side by side reporting different terminal widths for the same
 * screen — so the size is fixed and pinch-to-zoom is the way to change it.
 */
private const val TEXT_SIZE_PX = 28
private const val MIN_TEXT_SIZE_PX = 14
private const val MAX_TEXT_SIZE_PX = 64

private const val TERMINAL_BACKGROUND = 0xFF0B0D10.toInt()
