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
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.termux.terminal.KeyHandler
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import dev.terminaldeck.android.SessionBarView
import dev.terminaldeck.android.session.RemoteSessionBinding
import dev.terminaldeck.android.transfer.UploadPhase
import dev.terminaldeck.android.transfer.UploadView
import dev.terminaldeck.android.store.TerminalTextSize
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
    /**
     * What to call the machine this session is running on — `DeckUiState.machineNoun`.
     *
     * Required, and grouped with the other facts rather than given a default, because a default is
     * exactly how this screen came to call every machine a Mac: the attach button's description was
     * a literal, and a phone paired to a Windows PC read "Send a photo, video or file to the Mac".
     * A caller that has to supply it is a caller that has to think about which machine it means.
     */
    hostNoun: String,
    onBack: () -> Unit,
    onKey: (String) -> Unit,
    /**
     * Copy out.
     *
     * The argument is what is selected on screen right now, or null. It is passed rather than read
     * by the view model because only the view knows about a selection — and the fallback (the
     * visible screen) is only reachable from the emulator, which only the binding has. The choice
     * between them belongs with the rest of the policy, so both are handed over and the view model
     * decides.
     */
    onCopy: (String?) -> Unit,
    onPaste: () -> Unit,
    /** Absent, not disabled, when the machine never advertised `upload`. See `DeckUiState.canSendFiles`. */
    canSendFiles: Boolean = false,
    onSendPhoto: () -> Unit = {},
    onSendFile: () -> Unit = {},
    upload: UploadView? = null,
    onCancelUpload: () -> Unit = {},
    onDismissUpload: () -> Unit = {},
    /**
     * The one-line result of the last thing the user did here.
     *
     * This screen had no way to show one, and the omission was invisible from the code: `notify`
     * wrote to the state, the *session list* had a `SnackbarHost`, and this screen did not — so
     * every "Copied 4 lines from the screen" and every "The clipboard is empty" went nowhere. Copy
     * and paste are silent by nature; without a confirmation they feel broken exactly when they
     * worked. Found by tapping Copy on a real emulator and watching nothing happen.
     */
    notice: String? = null,
    /**
     * The plan ring, the context bar, the login this session runs as, and the way into the
     * conversation. Null over a machine that advertises none of `usage`/`account`/`chat`/`send` —
     * which gets a terminal that is exactly what it was rather than a bar with nothing in it.
     */
    bar: SessionBarView? = null,
    onRefreshUsage: () -> Unit = {},
    onSwitchAccount: (String) -> Unit = {},
    /** The way into the conversation. Absent when this machine serves no transcript for it. */
    onOpenChat: () -> Unit = {},
    /** Everything about this one session, as a sheet. iOS reaches it from here and from the row. */
    onDetails: () -> Unit = {},
    /**
     * Whether this session has a control cluster worth opening.
     *
     * Absent, not disabled: a machine that does not serve `controls`, and a session that is a plain
     * shell rather than an agent, both get a terminal that is exactly what it was rather than a
     * button that opens onto an explanation. The desktop's own cluster withdraws itself over
     * `/bin/zsh` for the same reason.
     */
    hasControls: Boolean = false,
    onControls: () -> Unit = {},
) {
    val context = LocalContext.current
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(notice) { notice?.let { snackbar.showSnackbar(it) } }
    // Read once, when the screen is built. A session already open picks up a change made in Settings
    // the next time it is opened — setting the font resizes the *remote* terminal, so doing it under
    // somebody's fingers while they read output is the wrong moment.
    val storedTextSize = remember { TerminalTextSize.load(context) }
    val client = remember(binding) { DeckTerminalViewClient(storedTextSize) { size -> TerminalTextSize.save(context, size) } }
    var ctrlArmed by remember(binding) { mutableStateOf(false) }
    var attachOpen by remember { mutableStateOf(false) }

    val terminalView = remember(binding) {
        TerminalView(context, null).apply {
            setTerminalViewClient(client)
            // setTextSize builds the renderer; setTypeface dereferences it. Order matters.
            setTextSize(storedTextSize)
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
        snackbarHost = { SnackbarHost(snackbar) },
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
                    IconButton(onClick = {
                        // Read at the moment of the tap, not remembered: a selection made and then
                        // dismissed must not still be what Copy takes.
                        val selection = terminalView.takeIf { it.isSelectingText() }?.selectedText
                        onCopy(selection?.takeIf { it.isNotEmpty() })
                        terminalView.stopTextSelectionMode()
                    }) {
                        Icon(
                            Icons.Filled.ContentCopy,
                            // Says both halves, because Copy means two different things depending on
                            // whether anything is selected and a control whose meaning changes
                            // silently is one people stop trusting. Long-press is discoverable in
                            // the same breath rather than being a gesture nobody is told about.
                            contentDescription = "Copy the selection, or the screen. Long-press the terminal to select.",
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
                    if (canSendFiles) {
                        Box {
                            IconButton(onClick = { attachOpen = true }) {
                                Icon(
                                    Icons.Filled.AttachFile,
                                    // Read aloud by TalkBack, which makes it the one label on this
                                    // screen a blind user hears in full — and the one that named the
                                    // wrong computer for as long as the noun was a literal here.
                                    contentDescription = "Send a photo, video or file to the $hostNoun",
                                    tint = MaterialTheme.colorScheme.onBackground,
                                )
                            }
                            DropdownMenu(expanded = attachOpen, onDismissRequest = { attachOpen = false }) {
                                DropdownMenuItem(
                                    text = { Text("Photo or video") },
                                    leadingIcon = { Icon(Icons.Filled.Image, contentDescription = null) },
                                    onClick = {
                                        attachOpen = false
                                        onSendPhoto()
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("File") },
                                    leadingIcon = { Icon(Icons.AutoMirrored.Filled.InsertDriveFile, contentDescription = null) },
                                    onClick = {
                                        attachOpen = false
                                        onSendFile()
                                    },
                                )
                            }
                        }
                    }
                    if (hasControls) {
                        IconButton(onClick = onControls) {
                            Icon(
                                Icons.Filled.Tune,
                                contentDescription = "Model, effort, fast mode and permission for this session",
                                tint = MaterialTheme.colorScheme.onBackground,
                            )
                        }
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

                // Between the title and the connection strip, so both stay legible: the chips
                // are about the session, the strip is about the socket, and the strip has to be the
                // last thing before the terminal or it reads as a property of whatever is under it.
                bar?.let { row ->
                    SessionBarRow(
                        view = row,
                        onRefresh = onRefreshUsage,
                        onSwitchAccount = onSwitchAccount,
                        onOpenChat = onOpenChat,
                    )
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
            Column(modifier = Modifier.imePadding().navigationBarsPadding()) {
                // Above the keys rather than over the terminal: it has to stay readable while the
                // keyboard is up, and an overlay on the terminal would cover the output the file is
                // about to be used on.
                if (upload != null) {
                    UploadRow(upload, onCancel = onCancelUpload, onDismiss = onDismissUpload)
                }
                KeyRow(
                    enabled = transport.isOnline,
                    ctrl = ctrlArmed,
                    onPress = { key ->
                        val press = KeyBar.press(key, ctrlArmed)
                        ctrlArmed = press.ctrl
                        if (press.data.isNotEmpty()) onKey(press.data)
                    },
                )
            }
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
 * The file on its way to the Mac.
 *
 * The bar is driven by `acked`, which is what the Mac says it has *written* — not by what this phone
 * has handed to the socket. Drawn the other way it would fill in two seconds on any file that fits
 * in a read buffer and then sit at 100% for a minute, which is not a progress bar.
 *
 * The path is on screen from the moment the Mac names it, before the bytes move, so a person can see
 * where the file is going while Cancel still means something. Cancel is always there while it is
 * running, because the failure this feature must not have is a transfer that has stalled and cannot
 * be stopped from the phone.
 */
@Composable
private fun UploadRow(upload: UploadView, onCancel: () -> Unit, onDismiss: () -> Unit) {
    val failed = upload.phase is UploadPhase.Failed
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = upload.name,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = if (upload.isRunning) onCancel else onDismiss) {
                Text(if (upload.isRunning) "Cancel" else "Dismiss")
            }
        }
        if (upload.isRunning) {
            LinearProgressIndicator(
                progress = { upload.fraction },
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
            )
        }
        Text(
            text = upload.detail,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = if (failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
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
private class DeckTerminalViewClient(
    /** The stored size this terminal was built at, so a pinch steps from it rather than from 28. */
    private val startingTextSizePx: Int,
    /** Where a pinch's new size is written. See [TerminalTextSize]. */
    private val onTextSize: (Int) -> Unit,
) : TerminalViewClient {

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

    private var textSizePx = startingTextSizePx

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
            val next = if (scale > 1f) {
                TerminalTextSize.larger(textSizePx)
            } else {
                TerminalTextSize.smaller(textSizePx)
            }
            if (next != textSizePx) {
                textSizePx = next
                // This reflows the emulator, which reports a new size, which becomes a `resize`
                // frame. Zooming on the phone genuinely changes the width of the remote terminal.
                view?.setTextSize(next)
                // And it is remembered, so the next launch draws at the size the last pinch chose
                // rather than back at the default — which is also the number the Settings row reads.
                onTextSize(next)
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
// The size, its bounds and its step now live in [TerminalTextSize], because the pinch is no longer
// the only thing that sets them: the Settings row writes the same number, and two copies of a bound
// is how a stepper and a gesture end up disagreeing about the maximum.

private const val TERMINAL_BACKGROUND = 0xFF0B0D10.toInt()
