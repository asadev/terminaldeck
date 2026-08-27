package dev.terminaldeck.android.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Minimize
import androidx.compose.material.icons.filled.WebAsset
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import dev.terminaldeck.android.LocalhostAddress
import dev.terminaldeck.android.MachineBrowserController
import dev.terminaldeck.android.MachineBrowserView
import dev.terminaldeck.android.WatchController
import dev.terminaldeck.android.protocol.BrowserWindowAction
import dev.terminaldeck.android.ui.kit.DeckTextField
import dev.terminaldeck.android.ui.theme.DeckTheme
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The browser window a session is holding, brought to the session — floating **over** the terminal,
 * foldable out of the way, draggable, and never letting go of the page while it is put away.
 *
 * A port of `ios/TerminalDeck/Screens/SessionPageView.swift`. Delivered as a **self-contained**
 * composable another lane mounts over the terminal — it is handed the machine-browser state, the two
 * controllers, and who this session is; it owns everything about the floating window and nothing about
 * the terminal underneath.
 *
 *   > *"whenever we are talking to terminal, terminal will directly open it up in there inside the
 *   > session… and the person can just minimize it from some button and it will go back to the browser
 *   > page… it can just quickly pop up this browser window inside the terminal and the other person can
 *   > just put his details, log in and stuff, and then it will fold back and then it can keep going."*
 *
 * ## It floats; it does not push the terminal down
 *
 *   > *"it should not move chat down to come in front or rerminal it should just expand over it."*
 *
 * The mount is a full-size [Box] whose empty area consumes no touches, so the terminal underneath is
 * live everywhere the window is not. When this session holds no window, nothing at all is drawn — no
 * strip, no height, no touch target — which is nearly every session nearly all of the time:
 *
 *   > *"If it is not connected to anyone, so it should stay clean. Even if I go to Copilot… it is also
 *   > showing something attached… which doesn't make any sense."*
 *
 * ## What it is, in two states
 *
 *  - **Open** — a white pill of an address bar (a red Delete and a fold control beside it) with the
 *    live picture hanging under it, one window over the terminal. The address is typed into directly
 *    and Enter is Go: *"let's remove Go button because on Enter it will be already go."*
 *  - **Folded** — one round button with a window glyph, standing where the fold control stood:
 *    *"when it is folded, instead of pill it can be a round button under three dots."* The window stays
 *    open on the machine, the binding stays, the agent carries on. Folding is about his screen and
 *    nothing else.
 *
 * ## The page is a desktop, not a phone
 *
 *   > *"the inner window page will be exactly like a desktop size 100%… like a Windows, like a desktop
 *   > window dimension — not like a 100% on phone side."*
 *
 * So the machine is asked to lay the page out at [DESKTOP_W]×[DESKTOP_H] via `browser.window.size`, and
 * the picture is fitted to the pane — landscape, short, nothing hanging off the side. Sent once when
 * the window arrives and again only when the pane really changes width, never per frame, because it
 * re-lays-out a document on another machine.
 *
 * ## The handover bar is a follow-up
 *
 * iOS draws a *take / hand-back / refusal* bar here off `browser.handover.state`/`.take`/`.done`. Those
 * frames are **not in this branch's protocol** (only the masked-frame curtain is), so this overlay
 * draws the address, the Delete and the fold, and the handover is left for the lane that lands the
 * wire. The curtain itself is already honoured by [WatchSurfaceView], which draws a lock card and takes
 * no taps on a masked frame.
 */
@Composable
fun SessionBrowserOverlay(
    view: MachineBrowserView,
    controller: MachineBrowserController,
    /** The cast, or null when this machine drives its browser but does not offer it for watching — the
     *  strip still draws, because knowing which page the agent is on is worth saying with no picture. */
    watch: WatchController?,
    hostId: String,
    sessionId: String,
    /** Whether the session screen holding this is the one being looked at — gates the cast, not the
     *  strip, so two canvases on two tabs never fight over the one frame sink. */
    frontmost: Boolean,
    /** Whether the machine's socket is up. No picture and no verb over a dead one. */
    live: Boolean,
    modifier: Modifier = Modifier,
) {
    val window = view.windowFor(sessionId)
    Box(modifier = modifier.fillMaxSize()) {
        // Nothing at all when this session holds no window — and the view stays in the tree so a window
        // becoming this session's is noticed. An empty Box consumes no touches, so the terminal is live.
        if (window != null) {
            OverlayWindow(
                window = window,
                controller = controller,
                watch = watch,
                hostId = hostId,
                sessionId = sessionId,
                frontmost = frontmost,
                live = live,
            )
        }
    }
}

@Composable
private fun OverlayWindow(
    window: dev.terminaldeck.android.protocol.MachineWindow,
    controller: MachineBrowserController,
    watch: WatchController?,
    hostId: String,
    sessionId: String,
    frontmost: Boolean,
    live: Boolean,
) {
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()

    // The three decisions a person makes, kept outside the composition so they survive a walk to the
    // list and back — *"coming back it refreshing the page every time… it should stay as it is."*
    var folded by remember(hostId, sessionId) {
        mutableStateOf(SessionPaneMemory.remembered(hostId, sessionId)?.folded ?: false)
    }
    var shown by remember(hostId, sessionId) {
        mutableStateOf(SessionPaneMemory.remembered(hostId, sessionId)?.shown)
    }

    var address by remember(window.id) { mutableStateOf("") }
    var seeded by remember(window.id) { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var refused by remember { mutableStateOf<String?>(null) }

    // A window becoming this session's opens the pane, once — a page reopening itself over a
    // conversation somebody is reading is the interruption this feature must not be. A window it has
    // already offered is left exactly as the person put it.
    LaunchedEffect(window.id) {
        if (window.id != shown) {
            folded = false
            shown = window.id
        }
    }
    // Written on every change of the two kept decisions, keyed by machine and session.
    LaunchedEffect(folded, shown) {
        SessionPaneMemory.remember(hostId, sessionId, folded, shown)
    }

    // The address follows the page, but never while a thumb is in the field — a redirect would land its
    // url on top of what is being typed, which on an agent-driven page is constant.
    LaunchedEffect(window.url, editing) {
        if (!editing && window.url.isNotEmpty() && (!seeded || window.url != address)) {
            address = window.url
            seeded = true
        }
    }

    fun go() {
        val typed = address.trim()
        if (typed.isEmpty()) return
        when (val classified = LocalhostAddress.classify(typed)) {
            is LocalhostAddress.Typed.Tunnel ->
                controller.go(window.id, "http://localhost:${classified.port}${classified.path}")
            is LocalhostAddress.Typed.Page -> controller.go(window.id, classified.url)
            is LocalhostAddress.Typed.Search -> controller.go(window.id, classified.url)
            is LocalhostAddress.Typed.Refused -> refused = classified.why
        }
    }

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val paneWidthPx = constraints.maxWidth
        val paneHeightPx = constraints.maxHeight
        // Captured here, in the constraints scope, because the picture is emitted inside a Column whose
        // own scope hides it.
        val paneWidthDp = maxWidth

        // Ask the machine for a desktop layout — once when the window arrives, and again only when the
        // pane really changes width. The pane moving is the event even though its width is not the
        // payload: a rotation changes how much of the desktop page is on screen and is worth one frame.
        LaunchedEffect(window.id, paneWidthPx) {
            if (paneWidthPx > 0) controller.size(window.id, DESKTOP_W, DESKTOP_H)
        }

        // Where the window sits, and where a finger has it right now. Held in Animatables read only by
        // the placement lambda, so a drag re-places one rectangle rather than recomposing the live
        // picture sixty times a second — *"movement is not smooth when dragging."*
        val offsetX = remember { Animatable(0f) }
        val offsetY = remember { Animatable(0f) }

        val stripTallPx = with(density) { 56.dp.toPx() }
        val foldTallPx = with(density) { 48.dp.toPx() }
        val marginPx = with(density) { 8.dp.toPx() }
        // Folded, the button rides an edge: far enough left to sit against it with the margin it keeps
        // on the right, and no further. Zero is the right edge; this is the left one.
        val leftEdgePx = min(-(paneWidthPx - with(density) { 74.dp.toPx() }), 0f)

        fun clampX(x: Float): Float = if (folded) x.coerceIn(leftEdgePx, 0f) else 0f
        fun clampY(y: Float): Float {
            val down = (paneHeightPx - (if (folded) foldTallPx else stripTallPx) - marginPx).coerceAtLeast(0f)
            return y.coerceIn(0f, down)
        }

        // Folding changes the shape, so the hold changes with it: pinned sideways when open, snapped to
        // an edge when folded. Reset x on the switch and re-clamp y into the new shape's room.
        LaunchedEffect(folded) {
            offsetX.snapTo(clampX(0f))
            offsetY.snapTo(clampY(offsetY.value))
        }

        val dragModifier = Modifier.pointerInput(folded, editing, paneWidthPx, paneHeightPx) {
            // A focused field is being typed into; a window that slid away under that finger could not
            // be. The moment the keyboard goes the bar is a handle again.
            if (editing) return@pointerInput
            detectDragGestures(
                onDrag = { change, delta ->
                    change.consume()
                    scope.launch {
                        offsetX.snapTo(clampX(offsetX.value + delta.x))
                        offsetY.snapTo(clampY(offsetY.value + delta.y))
                    }
                },
                onDragEnd = {
                    if (folded) {
                        val target = if (abs(offsetX.value - leftEdgePx) < abs(offsetX.value)) leftEdgePx else 0f
                        scope.launch { offsetX.animateTo(target) }
                    }
                },
            )
        }

        // Folded rides the right edge; open takes the full width from the leading edge.
        Column(
            modifier = Modifier
                .align(if (folded) Alignment.TopEnd else Alignment.TopStart)
                .offset { IntOffset(offsetX.value.roundToInt(), offsetY.value.roundToInt()) },
        ) {
            if (folded) {
                FoldedButton(dragModifier) { folded = false }
            } else {
                Strip(
                    address = address,
                    onAddress = { address = it; refused = null },
                    onEditing = { editing = it },
                    onGo = { editing = false; go() },
                    onDelete = { controller.act(window.id, BrowserWindowAction.Close) },
                    onFold = { folded = true },
                    dragModifier = dragModifier,
                )
                FloatingPicture(
                    watch = watch,
                    windowId = window.id,
                    mounted = frontmost && live && watch != null,
                    paneWidth = paneWidthDp,
                )
            }
        }
    }
}

/** The open bar: a white pill of an address, a red Delete, and the fold control. Only the link, one bar
 *  — *"let's keep use only the header bar, only one bar."* */
@Composable
private fun Strip(
    address: String,
    onAddress: (String) -> Unit,
    onEditing: (Boolean) -> Unit,
    onGo: () -> Unit,
    onDelete: () -> Unit,
    onFold: () -> Unit,
    dragModifier: Modifier,
) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = dragModifier
            .fillMaxWidth()
            .padding(start = PANE_INSET, end = PANE_INSET, top = 4.dp)
            .clip(RoundedCornerShape(topStart = PANE_CORNER, topEnd = PANE_CORNER))
            .background(colors.surface)
            .border(
                0.5.dp,
                colors.hairlineStrong,
                RoundedCornerShape(topStart = PANE_CORNER, topEnd = PANE_CORNER),
            )
            .padding(horizontal = 14.dp, vertical = 6.dp),
    ) {
        // The address, editing tracked so a navigation cannot overwrite a half-typed line and so the
        // drag lets go while the keyboard is up.
        Box(modifier = Modifier.weight(1f)) {
            DeckTextField(
                value = address,
                onValueChange = onAddress,
                placeholder = "Address or search",
                mono = true,
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { onGo() }),
                modifier = Modifier.onFocusEditing(onEditing),
            )
        }
        Spacer(Modifier.width(6.dp))
        // Red, and it closes on the machine too — one close, everywhere: *"Direct close is better,
        // which will also close it from server side too, not just here."*
        IconButton(onClick = onDelete, modifier = Modifier.size(34.dp)) {
            Icon(Icons.Filled.Cancel, contentDescription = "Delete this window on the machine", tint = colors.critical)
        }
        // Put it away. A minimize glyph, its window twin on the folded button — *"instead we can have
        // something representing a window… both are windows instead of arrow."*
        IconButton(onClick = onFold, modifier = Modifier.size(34.dp)) {
            Icon(Icons.Filled.Minimize, contentDescription = "Fold the window away", tint = colors.secondary)
        }
    }
}

/** Folded: one round button with a window glyph, standing where the fold control stood. */
@Composable
private fun FoldedButton(dragModifier: Modifier, onShow: () -> Unit) {
    val colors = DeckTheme.colors
    Box(
        contentAlignment = Alignment.Center,
        modifier = dragModifier
            .padding(top = 4.dp, end = 17.dp)
            .size(40.dp)
            .clip(CircleShape)
            .background(colors.surface)
            .border(0.5.dp, colors.hairlineStrong, CircleShape),
    ) {
        IconButton(onClick = onShow, modifier = Modifier.size(40.dp)) {
            Icon(Icons.Filled.WebAsset, contentDescription = "Show the page", tint = colors.accent)
        }
    }
}

/**
 * The live picture, hanging under the strip. Fitted to a desktop shape — height is the pane's width
 * times 800÷1280, capped so a tall page covers the terminal rather than squeezing it. Mounted only
 * while this is the frontmost session on a live socket; unmounting stops the cast, and unfolding mounts
 * a fresh canvas that renegotiates it — the shipped iOS behaviour, a beat of nothing then the page.
 */
@Composable
private fun FloatingPicture(
    watch: WatchController?,
    windowId: String,
    mounted: Boolean,
    paneWidth: androidx.compose.ui.unit.Dp,
) {
    val colors = DeckTheme.colors
    val pictureWidth = (paneWidth - PANE_INSET * 2)
    val pictureHeight = (pictureWidth.value * DESKTOP_H / DESKTOP_W).coerceAtMost(SPLIT_CAP).dp
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(pictureHeight)
            .padding(horizontal = PANE_INSET)
            .clip(RoundedCornerShape(bottomStart = PANE_CORNER, bottomEnd = PANE_CORNER))
            .background(colors.sunken)
            .border(
                0.5.dp,
                colors.hairlineStrong,
                RoundedCornerShape(bottomStart = PANE_CORNER, bottomEnd = PANE_CORNER),
            ),
    ) {
        if (mounted && watch != null) {
            val cast = watch
            AndroidView(
                factory = { ctx -> WatchSurfaceView(ctx, cast, windowId) },
                modifier = Modifier.fillMaxSize(),
                onRelease = { it.tearDown() },
            )
        }
    }
}

/** A [Modifier] that reports focus in and out — the field's own way of saying "somebody is typing",
 *  which stops both the re-seed and the drag. */
private fun Modifier.onFocusEditing(onEditing: (Boolean) -> Unit): Modifier =
    this.onFocusChanged { onEditing(it.isFocused) }

/**
 * **What the pane was doing when its screen was last left, by session.**
 *
 * A static store rather than something handed down the tree: the screen being destroyed and the screen
 * being built again a second later never exist at the same time, so they have nothing to pass between
 * them. Keyed by machine **and** session, because session ids are not unique across machines. Not
 * persisted — a window id does not survive the machine's browser — and everything read out of it is
 * checked against the live window before it is drawn from.
 */
private object SessionPaneMemory {
    data class Pane(val folded: Boolean, val shown: String?)

    private val bySession = mutableMapOf<String, Pane>()

    private fun key(host: String, session: String) = "$host/$session"

    fun remembered(host: String, session: String): Pane? = bySession[key(host, session)]

    fun remember(host: String, session: String, folded: Boolean, shown: String?) {
        bySession[key(host, session)] = Pane(folded, shown)
    }
}

/** 1280×800 — the ordinary laptop viewport every responsive site is designed against, and landscape,
 *  which is the other half of *"just make it landscape, not like the phone size."* */
private const val DESKTOP_W = 1280
private const val DESKTOP_H = 800

/** The most of the terminal a split page covers — a page tall enough to read a form on that still
 *  leaves rows of terminal visible on the shortest phone. */
private const val SPLIT_CAP = 440f

private val PANE_INSET = 6.dp
private val PANE_CORNER = 14.dp
