package dev.terminaldeck.android.ui

import android.graphics.Typeface
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.InputMethodManager
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AddToQueue
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.KeyboardHide
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Web
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardCapitalization
import dev.terminaldeck.android.ui.kit.DeckTextField
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space
import dev.terminaldeck.android.ui.theme.TerminalScheme
import dev.terminaldeck.android.ui.theme.currentTerminalScheme
import dev.terminaldeck.android.ui.theme.installTerminalPalette
import dev.terminaldeck.android.ui.theme.refreshLiveSession
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
     * The plan ring, the context bar and the login this session runs as. Null over a machine that
     * advertises none of `usage`/`account`/`send` — which gets a terminal that is exactly what it
     * was rather than a bar with nothing in it.
     */
    bar: SessionBarView? = null,
    onRefreshUsage: () -> Unit = {},
    onSwitchAccount: (String) -> Unit = {},
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
    /**
     * Whether this machine will let a session be given a name — the Rename row's gate.
     * `DeckUiState.canRenameSessions`; absent, not disabled, on a machine too old to advertise it.
     */
    canRenameSessions: Boolean = false,
    /**
     * Whether this screen is the **copilot's own conversation** rather than an ordinary session or a
     * terminal the copilot happened to start.
     *
     * The flag iOS passes for exactly the same reasons, and it gates three things the way iOS does:
     * the copilot has no Session details and no Rename (its name is the one thing that is the same on
     * every machine — *"give copilot a little bit of its own respect"*), and Restart is the copilot's
     * **only** way to a fresh conversation, so it appears here and nowhere else.
     *
     * On Android today it is always false through this screen: the copilot's conversation is drawn by
     * `CopilotScreen`, and a terminal reached from the Copilot tab is one the copilot *started* — an
     * ordinary session. The parity is built in regardless, so the day that conversation is a terminal
     * this screen is already correct.
     */
    isCopilot: Boolean = false,
    /** Send `rename { id, title }`. Empty title = take the name off, machine derives from the folder. */
    onRename: (String) -> Unit = {},
    /** End the copilot's conversation and start a fresh one in the same folder — copilot only. */
    onRestartCopilot: () -> Unit = {},
    /**
     * The attach-a-browser-window section of the ⋯ menu.
     *
     * Absent unless [canAttachBrowser] — a machine that will not be driven refuses every one of these
     * frames at the source, so *"absent, not disabled"* is the only honest state. When shown it is
     * **last** in the menu, because its length is however many windows the machine has open and is not
     * this app's to bound — *"they can be too many so they can just keep scrolling but they will not
     * have to scroll all the way … to reach the basic options."*
     *
     * The window list and the bind/open verbs are the browser lane's to supply — none of that
     * infrastructure (`SessionWindowPicker`, the machine's window roster, the released-window memory)
     * exists on Android yet — so this screen draws the section from what it is handed and defaults to
     * empty, which the integrator wires once the lane lands.
     */
    canAttachBrowser: Boolean = false,
    browserWindows: List<TerminalBrowserWindow> = emptyList(),
    onAttachWindow: (String) -> Unit = {},
    onOpenNewWindow: () -> Unit = {},
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
    // Alt, sticky like Ctrl, but living here rather than only on a key: it is armed in the key grid
    // and folds an Escape prefix into the *next* character typed on the soft keyboard — see the
    // client's `onCodePoint`. Keyed on the binding so a new session starts with it clear.
    var metaArmed by remember(binding) { mutableStateOf(false) }
    var overflowOpen by remember { mutableStateOf(false) }
    var findOpen by remember(binding) { mutableStateOf(false) }
    var gridOpen by remember { mutableStateOf(false) }
    var renaming by remember(binding) { mutableStateOf(false) }
    var typedName by remember(binding) { mutableStateOf("") }

    /*
     * The terminal's paper, and it is not the app's canvas.
     *
     * In the light theme it is deliberately *not* `--bg-primary`, in the words of the person who
     * reported it on the desktop: a terminal painted the canvas colour *"is pure white, and inside
     * the terminal itself it is a little bit different, like kind of grey"* — it stops being a
     * terminal and becomes an empty document with a cursor in it.
     *
     * This was one hard-coded `#0B0D10`, a blue-tinted near-black that exists nowhere else in the
     * product and had no light half at all. It then became `--terminal-bg`, one hex per appearance.
     * It is now **the chosen scheme's own background**, which is the only version of this that can
     * be right: a person who picked Pure black picked `#000000` for the well *and* for the ninety
     * pixels of view around it that the emulator never paints, and taking the ground from the app's
     * theme while the sixteen came from the scheme is exactly how a terminal ends up with a hairline
     * of the wrong colour down one edge.
     */
    val scheme = currentTerminalScheme(DeckTheme.colors.isDark)
    val paper = Color(TerminalScheme.parse(scheme.background))
    val paperIsDark = scheme.isDark

    val terminalView = remember(binding) {
        TerminalView(context, null).apply {
            setTerminalViewClient(client)
            // setTextSize builds the renderer; setTypeface dereferences it. Order matters.
            setTextSize(storedTextSize)
            setTypeface(Typeface.MONOSPACE)
            isFocusable = true
            isFocusableInTouchMode = true
            keepScreenOn = true
            client.view = this
            attachSession(binding.session)
        }
    }

    /*
     * Re-applied on every scheme change, on the view *and* on the emulator.
     *
     * The `View` keeps whatever `setBackgroundColor` was last given, and the emulator's colour table
     * is a copy taken from the process-wide scheme when the session was constructed — so a session
     * already open when somebody switches to Light, or drags a hex field two screens away, keeps the
     * old palette until it is told to re-read. `refreshLiveSession` is that telling, and
     * `onScreenUpdated` is what makes the repaint happen on this frame rather than on the next byte
     * of output — which matters most for the session nobody is typing into, the one that would
     * otherwise sit there in the old colours looking like the setting did nothing.
     *
     * Keyed on the whole scheme, not on `paperIsDark`: editing green changes neither the appearance
     * nor the choice, and an effect that only watched those two would miss every edit.
     */
    LaunchedEffect(scheme, binding) {
        installTerminalPalette(scheme)
        refreshLiveSession(binding.session)
        terminalView.setBackgroundColor(paper.toArgb())
        terminalView.onScreenUpdated()
    }

    // The key row's Ctrl has to reach the typing path too: a letter from the soft keyboard or a
    // hardware key while Ctrl is armed must produce a chord, which `TerminalView` asks about
    // through `readControlKey`. It also has to be *spent* there — see `consumeCtrl`.
    client.ctrl = { ctrlArmed }
    client.consumeCtrl = { ctrlArmed = false }

    // Alt (meta) reaches the same typing path: armed in the grid, it makes the next soft-keyboard
    // character arrive with an Escape prefix — `alt-b`, `alt-f`, `alt-.` — which is the byte a shell
    // acts on. `sendMeta` writes the Escape ahead of the character (built from its code point, 27,
    // rather than a raw control byte in source), and it is spent by that character in `onCodePoint`.
    client.meta = { metaArmed }
    client.consumeMeta = { metaArmed = false }
    client.sendMeta = { onKey(27.toChar().toString()) }

    // Find-in-output searches this session's own buffer and scrolls its view, so it is built from the
    // two and lives as long as the binding does. See [TerminalFindSession].
    val find = remember(binding) { TerminalFindSession(binding, terminalView) }

    /*
     * The size follows Settings and the other sessions' pinches, live, without being re-opened.
     *
     * `TerminalTextSize.live` is the stream `save` writes to — a stepper in Settings, or a pinch in
     * any session on the phone. Applied only when it actually differs from what this view is drawn at,
     * because `setTextSize` reflows the emulator and re-reads the scheme, so re-applying the size a
     * pinch just set on *this* view would resize the remote terminal for nothing. The session that
     * caused the change is already the right size, so the guard is what stops the echo. iOS reaches
     * the same end with `terminalTextSizeChanged` and the same guard.
     */
    val liveTextSize by TerminalTextSize.live.collectAsState()
    LaunchedEffect(liveTextSize) {
        if (liveTextSize > 0) client.applyExternalTextSize(liveTextSize, terminalView)
    }

    // Without this the first focusable in the window is the back button, so a hardware keyboard —
    // or `adb shell input text` — drives the app bar instead of the terminal, and Enter navigates
    // back rather than running anything. Focus does not raise the soft keyboard on its own; that
    // stays an explicit tap on the keyboard button.
    LaunchedEffect(terminalView) { terminalView.requestFocus() }

    // Copy the selection, or the visible screen when there is none — read at the moment of the tap,
    // never remembered, because a selection made and then dismissed must not still be what Copy takes.
    // Shared by the top-bar button and the grid's `copy` cap so the two are one act, not two that can
    // drift.
    val copyFromTerminal: () -> Unit = {
        val selection = terminalView.takeIf { it.isSelectingText() }?.selectedText
        onCopy(selection?.takeIf { it.isNotEmpty() })
        terminalView.stopTextSelectionMode()
    }

    // One switch turns a grid key into its effect — the same shape as iOS `KeyboardAccessory.press`,
    // and the reason the grid hands a `GridKey` back rather than deciding for itself: bytes go to the
    // session, a cursor key is resolved against the CSI form, the two modifiers arm, and copy/paste
    // are the app's business. Ctrl is on the bar, not the grid, but the branch is here for symmetry.
    val handleGridKey: (GridKey) -> Unit = { key ->
        when (val action = key.action) {
            is GridAction.Bytes -> if (action.data.isNotEmpty()) onKey(action.data)
            is GridAction.Cursor -> onKey(KeyGrid.cursorBytes(action.final))
            is GridAction.Mod -> when (action.modifier) {
                GridModifier.Meta -> metaArmed = !metaArmed
                GridModifier.Ctrl -> ctrlArmed = !ctrlArmed
            }
            GridAction.Copy -> copyFromTerminal()
            GridAction.Paste -> onPaste()
        }
    }

    Scaffold(
        /*
         * The chrome is the app's canvas; the terminal is the well cut into it.
         *
         * Both were `paper` before, which made the 6dp inset and the 8dp radius below invisible — a
         * rounded rectangle drawn in the same colour as what is behind it is not a rounded
         * rectangle. On paper the difference is `#ffffff` against `#e8e8e8` and the terminal finally
         * reads as recessed, which is the whole reason `--terminal-bg` is its own token rather than
         * a reuse of a surface.
         */
        containerColor = DeckTheme.colors.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(DeckTheme.colors.background)
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
                            tint = DeckTheme.colors.primary,
                        )
                    }
                    Column(modifier = Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(
                                modifier = Modifier
                                    .size(7.dp)
                                    .clip(CircleShape)
                                    .background(
                                        // Green for connected, matching the switcher's dots and the
                                        // session list's banner. It was the accent blue, which is
                                        // the colour this app spends on *the thing to press*.
                                        if (transport.isOnline) DeckTheme.colors.positive
                                        else DeckTheme.colors.critical
                                    )
                            )
                            Spacer(Modifier.width(7.dp))
                            Text(
                                text = title,
                                style = DeckType.rowTitle,
                                color = DeckTheme.colors.primary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        Text(
                            text = subtitle,
                            style = DeckType.mono,
                            color = DeckTheme.colors.faint,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    IconButton(onClick = copyFromTerminal) {
                        Icon(
                            Icons.Filled.ContentCopy,
                            // Says both halves, because Copy means two different things depending on
                            // whether anything is selected and a control whose meaning changes
                            // silently is one people stop trusting. Long-press is discoverable in
                            // the same breath rather than being a gesture nobody is told about.
                            contentDescription = "Copy the selection, or the screen. Long-press the terminal to select.",
                            tint = DeckTheme.colors.primary,
                        )
                    }
                    IconButton(onClick = onPaste) {
                        Icon(
                            Icons.Filled.ContentPaste,
                            contentDescription = "Paste into the session",
                            tint = DeckTheme.colors.primary,
                        )
                    }
                    /*
                     * The ⋯ is the terminal's menu, and it is drawn where the terminal is.
                     *
                     * Everything under it acts on this session: Find searches its buffer, the send
                     * rows hand it a file, Rename names it, Model & effort steers the agent in it. It
                     * is the whole menu now — Send moved in off the top bar (tried as a key-bar
                     * button, reverted: *"keep photo and file button back in the drop down, it was
                     * more easier to understand"*) and Model & effort moved in off its own icon, so
                     * the bar carries only Copy, Paste, this, and the keyboard. The order is iOS's:
                     * Find, then the facts (Details, Rename, Model & effort), then Send, then the two
                     * whose length is not fixed — Restart and the browser windows — last.
                     */
                    Box {
                        IconButton(onClick = { overflowOpen = true }) {
                            Icon(
                                Icons.Filled.MoreVert,
                                contentDescription = "Session actions",
                                tint = DeckTheme.colors.primary,
                            )
                        }
                        DropdownMenu(expanded = overflowOpen, onDismissRequest = { overflowOpen = false }) {
                            // Find, at the top, because on a phone it is the thing this menu is opened
                            // for most.
                            DropdownMenuItem(
                                text = { Text("Find in output") },
                                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                                onClick = {
                                    overflowOpen = false
                                    findOpen = true
                                },
                            )
                            // Session details — the folder/account facts the desktop shows as chips.
                            // Not on the copilot: that sheet answers *which session is this*, and the
                            // copilot is not one — *"anything that is more about a generic session"*.
                            if (!isCopilot) {
                                DropdownMenuItem(
                                    text = { Text("Session details") },
                                    leadingIcon = { Icon(Icons.Filled.Info, contentDescription = null) },
                                    onClick = {
                                        overflowOpen = false
                                        onDetails()
                                    },
                                )
                            }
                            // Rename — a name of his own on this session. Gated on the machine's
                            // `rename`, and never on the copilot: its name is the one thing the same on
                            // every machine, *"give copilot a little bit of its own respect"*.
                            if (canRenameSessions && !isCopilot) {
                                DropdownMenuItem(
                                    text = { Text("Rename session") },
                                    leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                                    onClick = {
                                        overflowOpen = false
                                        typedName = title
                                        renaming = true
                                    },
                                )
                            }
                            // Model, effort, fast mode, permission — shown only when an agent is
                            // drawing this session, never over a plain shell. See [SessionControls].
                            if (hasControls) {
                                DropdownMenuItem(
                                    text = { Text("Model & effort") },
                                    leadingIcon = { Icon(Icons.Filled.Tune, contentDescription = null) },
                                    onClick = {
                                        overflowOpen = false
                                        onControls()
                                    },
                                )
                            }
                            // Send — a sentence with a glyph in the one place a session's actions live.
                            // Absent, not disabled, when the machine cannot receive a file.
                            if (canSendFiles) {
                                HorizontalDivider()
                                DropdownMenuItem(
                                    text = { Text("Send Photo or Video") },
                                    leadingIcon = { Icon(Icons.Filled.Image, contentDescription = null) },
                                    onClick = {
                                        overflowOpen = false
                                        onSendPhoto()
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("Send File") },
                                    leadingIcon = { Icon(Icons.AutoMirrored.Filled.InsertDriveFile, contentDescription = null) },
                                    onClick = {
                                        overflowOpen = false
                                        onSendFile()
                                    },
                                )
                            }
                            // The last two, whose length is not this menu's to bound. The divider
                            // above them earns its place only when one of them is there.
                            if (isCopilot || canAttachBrowser) HorizontalDivider()
                            // Restart, the copilot's only way to a fresh conversation — *"keep restart
                            // for copilot only"*. Never on an ordinary session, which has the list's +
                            // and a Delete beside every row instead.
                            if (isCopilot) {
                                DropdownMenuItem(
                                    text = { Text("Restart session") },
                                    leadingIcon = { Icon(Icons.Filled.Refresh, contentDescription = null) },
                                    enabled = transport.isOnline,
                                    onClick = {
                                        overflowOpen = false
                                        onRestartCopilot()
                                    },
                                )
                            }
                            // Attach a browser window — last, and however long the machine's window
                            // list happens to be. One flat list of names: the one this session holds
                            // wears a check, the one it let go of a come-back arrow, then New window.
                            if (canAttachBrowser) {
                                Text(
                                    text = "Attach a browser window".uppercase(),
                                    style = DeckType.overline,
                                    color = DeckTheme.colors.faint,
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                                )
                                for (window in browserWindows) {
                                    val windowIcon = when (window.kind) {
                                        TerminalWindowKind.Held -> Icons.Filled.Check
                                        TerminalWindowKind.Returning -> Icons.AutoMirrored.Filled.ArrowBack
                                        TerminalWindowKind.PhonePage -> Icons.Filled.PhoneAndroid
                                        TerminalWindowKind.Other -> Icons.Filled.Web
                                    }
                                    DropdownMenuItem(
                                        text = { Text(window.label) },
                                        leadingIcon = { Icon(windowIcon, contentDescription = null) },
                                        onClick = {
                                            overflowOpen = false
                                            onAttachWindow(window.id)
                                        },
                                    )
                                }
                                // The plus-on-a-window row that makes one rather than borrowing one —
                                // *"instead it should show the plus icon so they can understand it
                                // properly"* — with two words, because the section header already says
                                // these are browser windows.
                                DropdownMenuItem(
                                    text = { Text("New window") },
                                    leadingIcon = { Icon(Icons.Filled.AddToQueue, contentDescription = null) },
                                    onClick = {
                                        overflowOpen = false
                                        onOpenNewWindow()
                                    },
                                )
                            }
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
                            tint = DeckTheme.colors.primary,
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
                    )
                }

                if (!transport.isOnline) {
                    Text(
                        text = transport.detail,
                        style = DeckType.caption,
                        // White on the critical *fill*, not the critical ink on the canvas: this is
                        // a band rather than a sentence, and `--critical-fill-ink` is white in both
                        // appearances because the fill is dark enough in both.
                        color = DeckTheme.colors.onCriticalFill,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(DeckTheme.colors.criticalFill)
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
                    onMore = { gridOpen = true },
                    // Dismiss means *give me the screen back*, so it puts the keyboard away and closes
                    // the grid with it — leaving a grid up would be answering half of that.
                    onHideKeyboard = {
                        val imm = context.getSystemService(InputMethodManager::class.java)
                        imm?.hideSoftInputFromWindow(terminalView.windowToken, 0)
                        gridOpen = false
                    },
                )
            }
        },
    ) { padding ->
        /*
         * The well the terminal sits in, and the hairline that makes it one.
         *
         * The inset and the radius used to be visible for free, because the terminal's paper was
         * `--bg-sunken` — a step *below* the app's canvas — while the chrome around it was the
         * canvas itself. That is no longer something this screen is allowed to assume: the ground
         * is now whichever scheme somebody chose, and the product's own **Deck Dark** scheme is
         * `#191919`, which is exactly the app's canvas in the dark. Left alone, the default would
         * have drawn a rounded rectangle in the same colour as the thing behind it, which is not a
         * rounded rectangle — the precise defect the sunken paper was introduced to fix, arriving
         * back through the front door.
         *
         * A hairline fixes it for *every* scheme rather than for the one that was checked, which is
         * the only version of this that survives somebody typing their own hex into the editor.
         */
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 6.dp, vertical = 4.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(paper)
                .border(1.dp, DeckTheme.colors.hairline, RoundedCornerShape(8.dp)),
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

            // TODO(integrator): mount SessionBrowserOverlay here — over the terminal well, above the
            // AndroidView and below the find bar — once the browser lane's `SessionBrowserOverlay(...)`
            // lands. It is not called from this branch: the composable does not exist in this lane, and
            // the attach-a-browser-window menu section above is its counterpart on the ⋯ side.

            // Find floats over the top of the scrollback rather than pushing it down — taking rows off
            // a session is a `resize` on the wire, and a search must not disturb what it reads.
            if (findOpen) {
                FindBar(
                    find = find,
                    // The term is kept: re-opening to look for the same string is the common case, and
                    // throwing it away would make the second search cost the same typing as the first.
                    onClose = { findOpen = false },
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(6.dp),
                )
            }
        }
    }

    // Rename — one line, one answer, the same alert the session list draws. An empty field is allowed
    // through: it is how the machine is told to go back to the folder's own name.
    if (renaming) {
        AlertDialog(
            onDismissRequest = { renaming = false },
            containerColor = DeckTheme.colors.surface,
            titleContentColor = DeckTheme.colors.primary,
            textContentColor = DeckTheme.colors.secondary,
            title = { Text("Rename ${title}") },
            text = {
                Column {
                    DeckTextField(
                        value = typedName,
                        onValueChange = { typedName = it },
                        placeholder = "Name",
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
                    )
                    Spacer(Modifier.size(Space.x3))
                    Text(
                        text = "Every device signed in here sees the new name. " +
                            "Leave it empty to go back to the folder's own name.",
                        style = DeckType.footnote,
                        color = DeckTheme.colors.secondary,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    renaming = false
                    onRename(typedName)
                }) {
                    Text("Save", style = DeckType.control, color = DeckTheme.colors.accent)
                }
            },
            dismissButton = {
                TextButton(onClick = { renaming = false }) {
                    Text("Cancel", style = DeckType.control, color = DeckTheme.colors.primary)
                }
            },
        )
    }

    // The grid the *more keys* button opens. Its `alt` cap arms [metaArmed], which lives up here so it
    // survives the sheet closing and is spent by the next character typed on the soft keyboard.
    if (gridOpen) {
        KeyGridSheet(
            metaArmed = metaArmed,
            onKey = handleGridKey,
            onDismiss = { gridOpen = false },
        )
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
            .background(DeckTheme.colors.surface)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = upload.name,
                style = DeckType.value,
                color = DeckTheme.colors.primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = if (upload.isRunning) onCancel else onDismiss) {
                Text(
                    text = if (upload.isRunning) "Cancel" else "Dismiss",
                    style = DeckType.value,
                    color = DeckTheme.colors.accent,
                )
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
            style = DeckType.mono,
            color = if (failed) DeckTheme.colors.critical else DeckTheme.colors.faint,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * The fixed key row, and the two pinned buttons that never move.
 *
 * Five keys now — `esc` `tab` `ctrl` `↑` `↓` — filling the width equally rather than scrolling. A
 * scrolling bar has no fixed positions, so no muscle memory ever forms for a key that moves under a
 * swipe; everything else moved into the grid the *more keys* button opens. Ctrl shows its armed
 * state, because a sticky modifier the user cannot see is one that fires on the wrong key. See
 * [KEY_BAR] and [KeyGrid].
 *
 * *more* and *dismiss* are pinned hard right at a fixed size, in the same place on every phone — the
 * whole reason the bar does not scroll. iOS pins the identical pair for the identical reason, and
 * proves in `KeyPlan` that the set fits the narrowest phone.
 */
@Composable
private fun KeyRow(
    enabled: Boolean,
    ctrl: Boolean,
    onPress: (KeyBarKey) -> Unit,
    onMore: () -> Unit,
    onHideKeyboard: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = DeckTheme.colors
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .background(colors.background)
            .padding(horizontal = 8.dp, vertical = 6.dp),
    ) {
        for (key in KEY_BAR) {
            val armed = key == KeyBarKey.Ctrl && ctrl
            val interaction = remember { MutableInteractionSource() }
            val pressed by interaction.collectIsPressedAsState()
            Text(
                text = key.label,
                style = DeckType.control,
                textAlign = TextAlign.Center,
                maxLines = 1,
                // A cap is a tint of the ink, not a named grey, so the bar picks up whatever is behind
                // it and works over the light keyboard as well as the dark. The disabled and pressed
                // states are their own values; every key felt dead before there was a pressed one,
                // which is the one thing a key row must never do.
                color = when {
                    !enabled -> colors.faint
                    armed -> colors.onAccent
                    else -> colors.keyLabel
                },
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(
                        when {
                            !enabled -> colors.keyDisabled
                            armed -> colors.accent
                            pressed -> colors.keyPressed
                            else -> colors.key
                        }
                    )
                    .clickable(interactionSource = interaction, indication = null, enabled = enabled) {
                        onPress(key)
                    }
                    .padding(vertical = 10.dp),
            )
        }
        // A wider gap so the pinned pair reads as chrome, not as two more keys.
        Spacer(Modifier.width(6.dp))
        KeyChromeButton(Icons.Filled.GridView, "More keys", onMore)
        KeyChromeButton(Icons.Filled.KeyboardHide, "Hide the keyboard", onHideKeyboard)
    }
}

/**
 * One of the two pinned buttons on the key row — a square of the same height as a key, wearing the
 * key's own fill so the pair reads as chrome sitting at the end of the row rather than as more keys.
 */
@Composable
private fun KeyChromeButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    val colors = DeckTheme.colors
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(44.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (pressed) colors.keyPressed else colors.key)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick),
    ) {
        Icon(icon, contentDescription = label, tint = colors.keyLabel, modifier = Modifier.size(22.dp))
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

    /** Whether the grid's Alt is armed. Read on every code point, the way [ctrl] is. */
    var meta: () -> Boolean = { false }

    /** Spend the armed Alt — the same reason [consumeCtrl] exists, for the other sticky modifier. */
    var consumeMeta: () -> Unit = {}

    /**
     * Write the Escape an armed Alt prefixes onto the next character.
     *
     * Alt is not a byte the way Ctrl folds into one; it is the ESC a shell reads before a letter as
     * `alt-<letter>`. So the screen supplies a way to emit that ESC ahead of the character, and it
     * goes out through the same `input` path as every other keystroke.
     */
    var sendMeta: () -> Unit = {}

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

    /**
     * Adopt a size chosen somewhere else — a Settings stepper, or a pinch in another session.
     *
     * Guarded on an actual change, because `setTextSize` reflows the emulator and the guard is what
     * keeps the session that *caused* a live change (its own pinch already applied) from resizing the
     * remote terminal a second time for the same number. The pinch above updates [textSizePx] before
     * the broadcast reaches here, so its own echo is a no-op.
     */
    fun applyExternalTextSize(px: Int, view: TerminalView) {
        val clamped = TerminalTextSize.clamp(px)
        if (clamped == textSizePx) return
        textSizePx = clamped
        view.setTextSize(clamped)
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
        // stealing it from the key that armed it.
        //
        // An armed Alt goes out first, as the Escape a shell reads before this character as
        // `alt-<char>`, and is spent by it — `sendMeta` writes the ESC ahead, then `false` hands the
        // character to `TerminalView` to encode and write after it, so the two arrive in order.
        if (meta()) {
            sendMeta()
            consumeMeta()
        }
        // `false` hands the code point back to `TerminalView`, which encodes it through [KeyHandler]
        // and writes it to the session.
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


/**
 * A machine window as the attach-a-browser-window menu section sees it.
 *
 * A screen-local shape rather than the wire's `MachineWindow`, because the decision the menu draws -
 * which window this session holds, which it just let go of, which are pages this phone is showing -
 * is the browser lane's `SessionWindowPicker` logic to make, not this screen's to re-derive. The
 * integrator maps the machine's roster to these; this screen only draws them.
 */
data class TerminalBrowserWindow(
    val id: String,
    /** What the row reads - already resolved against the list, so two same-named windows differ. */
    val label: String,
    val kind: TerminalWindowKind,
)

/**
 * Three states, three glyphs, no words - a check on the one this session holds, a come-back arrow on
 * the one it just let go of, a phone on a page this phone is showing, and a window frame on every
 * other. The same three iOS draws.
 */
enum class TerminalWindowKind { Held, Returning, PhonePage, Other }
