package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.HighlightAlt
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import dev.terminaldeck.android.LocalhostAddress
import dev.terminaldeck.android.MachineBrowserController
import dev.terminaldeck.android.MachineBrowserView
import dev.terminaldeck.android.WatchController
import dev.terminaldeck.android.protocol.BrowserWindowAction
import dev.terminaldeck.android.protocol.InspectedElement
import dev.terminaldeck.android.protocol.MachineWindow
import dev.terminaldeck.android.protocol.RecordedStep
import dev.terminaldeck.android.protocol.WindowSession
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckDestructiveText
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckTextField
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.FieldLabel
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.kit.DeckSheetChrome
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * One window on the machine, driven from the phone: the live picture, the address it is on, and the
 * verbs that move it.
 *
 * A port of `ios/TerminalDeck/Screens/MachineWindowView.swift` + `MachineWindowSettingsView.swift`.
 * The window is held by [windowId], never by a captured [MachineWindow] — every verb answers with the
 * whole list, so the row is looked up on each redraw and a value held from an earlier answer would
 * name a closed window. `""` is a real id: the machine's own front tab.
 *
 * The picture is the same [WatchSurfaceView] the browser tab casts through — a tap on it drives the
 * page and raises the keyboard, and every keystroke becomes a `browser.input`, so there is no separate
 * *type into the page* control. What this screen adds around it is the chrome a browser has: the
 * address, the four page verbs, and — behind the `…` — the per-window settings.
 *
 *   > *"this page should be purely for only browser, not for terminal too."*
 *
 * So nothing here reaches a session except the two acts that hand something *to* one: a screenshot,
 * and attaching the window. The address bar is **seeded, not bound** — a field bound to the page would
 * rewrite itself under a thumb every time the agent navigated, which on an agent-driven page is
 * constant.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MachineWindowScreen(
    view: MachineBrowserView,
    controller: MachineBrowserController,
    watch: WatchController,
    windowId: String,
    machineLabel: String,
    live: Boolean,
    onBack: () -> Unit,
) {
    val window = view.window(windowId)
    val colors = DeckTheme.colors

    var address by remember { mutableStateOf("") }
    var seeded by remember(windowId) { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var refused by remember { mutableStateOf<String?>(null) }
    var settings by remember { mutableStateOf(false) }

    // Inspect mode: a tap on the picture names what is under it instead of pressing it, exactly as the
    // page on this phone does — *"all of them should be identical."* The last point is kept so Wider
    // and Narrower can re-ask about it with a different `up`; there is nothing in the answer to
    // re-derive a fingertip's position from.
    var inspecting by remember { mutableStateOf(false) }
    var lastPick by remember(windowId) { mutableStateOf<Pair<Double, Double>?>(null) }
    val picked = view.picked[windowId]
    val asking = view.pickingWindow == windowId

    // The device the machine lays this window's page out at, via `browser.window.size`. This phone's
    // own size is the default and the way back; a real device is a rectangle in CSS pixels.
    var device by remember(windowId) { mutableStateOf(PageDevice.ThisPhone) }
    var sizeMenu by remember { mutableStateOf(false) }
    val configuration = LocalConfiguration.current

    fun chooseSize(chosen: PageDevice) {
        device = chosen
        val width = chosen.width
        val height = chosen.height
        if (width != null && height != null) {
            controller.size(windowId, width, height)
        } else {
            // This phone: the window laid out at the phone's own size — the state it started in and the
            // one *"it should always open to the normal size"* is about.
            controller.size(windowId, configuration.screenWidthDp, configuration.screenHeightDp)
        }
    }

    // Seed the field from the page, and follow the page — but never while a thumb is in the field, or
    // a redirect would land its url on top of what is being typed.
    LaunchedEffect(window?.url, editing) {
        val url = window?.url.orEmpty()
        if (!editing && url.isNotEmpty() && (!seeded || url != address)) {
            address = url
            seeded = true
        }
    }

    // The window closing on the machine takes it out of the list; there is nothing left to drive, so
    // the screen leaves rather than showing a picture of a page that is gone.
    LaunchedEffect(window == null, view.loaded) {
        if (window == null && view.loaded) onBack()
    }

    fun send(typed: String) {
        val trimmed = typed.trim()
        if (trimmed.isEmpty()) return
        when (val classified = LocalhostAddress.classify(trimmed)) {
            is LocalhostAddress.Typed.Tunnel ->
                controller.go(windowId, "http://localhost:${classified.port}${classified.path}")
            is LocalhostAddress.Typed.Page -> controller.go(windowId, classified.url)
            is LocalhostAddress.Typed.Search -> controller.go(windowId, classified.url)
            is LocalhostAddress.Typed.Refused -> refused = classified.why
        }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            DeckTopBar(
                title = pageTitle(window),
                subtitle = machineLabel,
                onBack = onBack,
                actions = {
                    IconButton(onClick = { settings = true }) {
                        Icon(Icons.Filled.Tune, contentDescription = "Window settings", tint = colors.secondary)
                    }
                },
            )
        },
        bottomBar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(colors.background)
                    .imePadding()
                    .navigationBarsPadding()
                    .padding(horizontal = Space.x3, vertical = Space.x2),
            ) {
                // The address, typed into directly — no Go button, because Enter is Go, which is what
                // every phone browser does.
                DeckTextField(
                    value = address,
                    onValueChange = { address = it; refused = null },
                    placeholder = "Address or search",
                    mono = true,
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { editing = false; send(address) }),
                )
                refused?.let { DeckFootnote(it, color = colors.warning) }
                Spacer(Modifier.padding(top = Space.x1))
                // Back · Forward · Reload · Close, over the picture — the four a browser window carries.
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    PageVerb(Icons.AutoMirrored.Filled.ArrowBack, "Back", colors.secondary) {
                        controller.act(windowId, BrowserWindowAction.Back)
                    }
                    PageVerb(Icons.AutoMirrored.Filled.ArrowForward, "Forward", colors.secondary) {
                        controller.act(windowId, BrowserWindowAction.Forward)
                    }
                    PageVerb(Icons.Filled.Refresh, "Reload", colors.secondary) {
                        controller.act(windowId, BrowserWindowAction.Reload)
                    }
                    // Inspect — a tap names what is under it instead of pressing it. Accent while it is
                    // on, so the mode is visible; turning it off forgets the last element.
                    PageVerb(
                        Icons.Filled.HighlightAlt,
                        if (inspecting) "Stop inspecting" else "Inspect an element",
                        if (inspecting) colors.accent else colors.secondary,
                    ) {
                        inspecting = !inspecting
                        if (!inspecting) controller.clearPicked(windowId)
                    }
                    // Size — the device the machine lays the page out at. A menu of real ones, the same
                    // set the phone's own browser offers, sent as `browser.window.size`.
                    Box {
                        PageVerb(Icons.Filled.AspectRatio, "Page size", colors.secondary) { sizeMenu = true }
                        DropdownMenu(expanded = sizeMenu, onDismissRequest = { sizeMenu = false }) {
                            PageDevice.entries.forEach { option ->
                                DropdownMenuItem(
                                    leadingIcon = {
                                        Icon(
                                            if (option == device) Icons.Filled.Check else Icons.Filled.AspectRatio,
                                            contentDescription = null,
                                            tint = if (option == device) colors.accent else colors.faint,
                                            modifier = Modifier.size(18.dp),
                                        )
                                    },
                                    text = {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            Text(
                                                option.label,
                                                style = DeckType.body,
                                                color = if (option == device) colors.accent else colors.primary,
                                            )
                                            option.measure?.let {
                                                Spacer(Modifier.width(Space.x2))
                                                Text(it, style = DeckType.monoSmall, color = colors.faint)
                                            }
                                        }
                                    },
                                    onClick = { sizeMenu = false; chooseSize(option) },
                                )
                            }
                        }
                    }
                    // Red, and it closes everywhere: *"Direct close is better, which will also close it
                    // from server side too, not just here."*
                    PageVerb(Icons.Filled.Cancel, "Close window", colors.critical) {
                        controller.act(windowId, BrowserWindowAction.Close)
                    }
                }
            }
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            // The machine's own word on the last answer — a refusal from over there, or a note.
            view.notice?.let { line ->
                DeckGroup(modifier = Modifier.padding(horizontal = Space.screen, vertical = Space.x2)) {
                    Text(line, style = DeckType.footnote, color = colors.secondary, modifier = Modifier.padding(Space.card))
                }
            }
            if (window?.loading == true) {
                LinearProgressIndicator(
                    color = colors.accent,
                    trackColor = colors.surfaceHigh,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            // What inspect mode is waiting for, said once, at the top of the page — the same row and
            // the same place the page on this phone puts it. The verb differs by one word and it has
            // to: on a machine window a tap is a question for the machine, and the answer can be *the
            // page has moved since that picture*, so it says *ask about it* rather than promising one.
            if (inspecting) {
                InspectHint(asking)
            }
            // The live picture — the same canvas the browser tab casts through. A tap drives the page
            // and raises the keyboard; every keystroke is a `browser.input`. Pinch magnifies it; while
            // inspecting a tap names what is under it instead.
            Box(modifier = Modifier.fillMaxSize().background(colors.sunken)) {
                if (live) {
                    var canvas by remember(windowId) { mutableStateOf<WatchSurfaceView?>(null) }
                    val outline = colors.accent.toArgb()
                    AndroidView(
                        factory = { ctx ->
                            WatchSurfaceView(ctx, watch, windowId, outline).also { canvas = it }
                        },
                        modifier = Modifier.fillMaxSize(),
                        update = { surface ->
                            surface.inspecting = inspecting
                            surface.onPick = { x, y ->
                                lastPick = x to y
                                controller.pick(windowId, x, y)
                            }
                            // The element to outline, or nothing when inspect is off — drawn over the
                            // frame in the page's own coordinates, so it follows the page as it scrolls.
                            surface.setPicked(if (inspecting) picked?.rect else null)
                        },
                        onRelease = { it.tearDown() },
                    )
                    DisposableEffect(windowId) { onDispose { canvas?.tearDown() } }
                } else {
                    Text(
                        text = "Not connected to $machineLabel.",
                        style = DeckType.footnote,
                        color = colors.faint,
                        modifier = Modifier.align(Alignment.Center).padding(Space.x8),
                    )
                }
            }
        }
    }

    if (settings && window != null) {
        WindowSettingsSheet(
            window = window,
            sessions = view.sessions,
            steps = view.steps[windowId].orEmpty(),
            controller = controller,
            windowId = windowId,
            machineLabel = machineLabel,
            onDismiss = { settings = false },
        )
    }

    // The element the machine described — drawn in the same sheet the page on this phone would use.
    // Presented off the value: Wider and Narrower change the element on every press, and the list of
    // windows redrawing under it must not tear the sheet down. Dismissing it forgets the element,
    // which is what closes it.
    if (inspecting && picked != null) {
        InspectedElementSheet(
            element = picked,
            asking = asking,
            onWider = {
                lastPick?.let { (x, y) ->
                    // One more ancestor towards the document. Enabled only below the top, so `depth + 1`
                    // is in range; the controller clamps to the host's ceiling regardless.
                    if (picked.depth < picked.maxUp) controller.pick(windowId, x, y, picked.depth + 1)
                }
            },
            onNarrower = {
                lastPick?.let { (x, y) ->
                    if (picked.depth > 0) controller.pick(windowId, x, y, picked.depth - 1)
                }
            },
            onDismiss = { controller.clearPicked(windowId) },
        )
    }
}

/**
 * What inspect mode is waiting for, said once above the page.
 *
 * The verb differs from the phone's own page by one word and it has to: there a tap is answered in the
 * same runloop turn, here it is a frame over a wire to a machine and back. A row that went on saying
 * *tap anything* through that would invite a second tap while the first was still in flight.
 */
@Composable
private fun InspectHint(asking: Boolean) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.surface)
            .padding(horizontal = Space.x3, vertical = Space.x15),
    ) {
        Icon(
            if (asking) Icons.Filled.HourglassEmpty else Icons.Filled.TouchApp,
            contentDescription = null,
            tint = colors.accent,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(Space.x2))
        Text(
            text = if (asking) {
                "Asking the machine what that is…"
            } else {
                "Tap anything on the page to ask what it is."
            },
            style = DeckType.footnote,
            color = colors.accent,
        )
    }
}

/**
 * What was pointed at, and the two words that correct it.
 *
 * The same facts the phone's own inspector shows — tag, selector, label, address — because *"all of
 * them should be identical"* is a sentence about the screen rather than the mechanism. Handing an
 * element to an agent as one line is `InspectScript` plus the session-send plumbing on the phone's own
 * page and is not reached from here yet; what this draws is the element itself, copyable, and the walk
 * up its ancestors that a fingertip with no hover otherwise cannot make.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InspectedElementSheet(
    element: InspectedElement,
    asking: Boolean,
    onWider: () -> Unit,
    onNarrower: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = DeckTheme.colors
    val clipboard = LocalClipboardManager.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.background,
        shape = Radius.sheetShape,
        dragHandle = null,
    ) {
        DeckSheetChrome()
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .padding(top = Space.x5, bottom = Space.x8),
        ) {
            Text("Change this", style = DeckType.title, color = colors.primary)

            // The tag.
            Spacer(Modifier.padding(top = Space.x3))
            Text(
                text = if (element.tag.isEmpty()) "element" else "<${element.tag}>",
                style = DeckType.monoSmall,
                color = colors.accent,
                modifier = Modifier
                    .clip(Radius.small)
                    .background(colors.accent.copy(alpha = 0.14f))
                    .padding(horizontal = Space.x15, vertical = Space.half),
            )

            // The selector — copyable, because the most useful thing to do with one that is nearly
            // right is to copy it and fix it by hand.
            Spacer(Modifier.padding(top = Space.x3))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = element.selector,
                    style = DeckType.mono,
                    color = colors.primary,
                    modifier = Modifier
                        .weight(1f)
                        .clip(Radius.fieldShape)
                        .background(colors.surfaceHigh)
                        .padding(Space.x3),
                )
                IconButton(onClick = { clipboard.setText(AnnotatedString(element.selector)) }) {
                    Icon(Icons.Filled.ContentCopy, contentDescription = "Copy selector", tint = colors.secondary)
                }
            }

            if (element.label.isNotEmpty()) {
                Spacer(Modifier.padding(top = Space.x2))
                Text(
                    element.label,
                    style = DeckType.body,
                    color = colors.secondary,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            if (element.url.isNotEmpty()) {
                Spacer(Modifier.padding(top = Space.x1))
                Text(
                    element.url,
                    style = DeckType.mono,
                    color = colors.faint,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            // The correction — a tap lands on the topmost element, which on a modern site is routinely
            // a wrapper rather than the button somebody meant. Both ends are read off the element:
            // `maxUp` is how many ancestors are left above this one, `depth` how far up it already is.
            Spacer(Modifier.padding(top = Space.x4))
            Row(verticalAlignment = Alignment.CenterVertically) {
                InspectStep("Wider", enabled = element.depth < element.maxUp && !asking, onClick = onWider)
                Spacer(Modifier.width(Space.x2))
                InspectStep("Narrower", enabled = element.depth > 0 && !asking, onClick = onNarrower)
                Spacer(Modifier.weight(1f))
                if (asking) {
                    Text("Asking the machine…", style = DeckType.caption, color = colors.faint)
                }
            }
        }
    }
}

@Composable
private fun InspectStep(label: String, enabled: Boolean, onClick: () -> Unit) {
    val colors = DeckTheme.colors
    Text(
        text = label,
        style = DeckType.value,
        color = if (enabled) colors.accent else colors.faint,
        modifier = Modifier
            .clip(Radius.fieldShape)
            .background(colors.surfaceHigh)
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = Space.x3, vertical = Space.x2),
    )
}

/** The name a window is drawn under: its own title, then its address, then a fallback that is never
 *  `about:blank` — *"lets make only one name as browser and window identical to normal standards."* */
private fun pageTitle(window: MachineWindow?): String {
    if (window == null) return "Window"
    val title = window.title.ifEmpty { window.url }
    return title.ifEmpty { if (window.id.isEmpty()) "Front tab" else "Untitled" }
}

@Composable
private fun PageVerb(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    tint: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit,
) {
    IconButton(onClick = onClick) {
        Icon(icon, contentDescription = label, tint = tint)
    }
}

/**
 * The per-window settings — everything that is not the picture and its four verbs.
 *
 *   > *"When we click on three dots then we can see the settings — per window also, inside the window:
 *   > settings of per window, how to connect to it, how to make it shared or isolated, all of these
 *   > things should be inside of the window."*
 *
 * Privacy, the session it is bound to, a screenshot handed to the phone or to a session, the click
 * flow the recorder collects, and delete. Each is drawn whether or not it can act right now — a
 * control that comes and goes is a control somebody learns not to trust.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WindowSettingsSheet(
    window: MachineWindow,
    sessions: List<WindowSession>,
    steps: List<RecordedStep>,
    controller: MachineBrowserController,
    windowId: String,
    machineLabel: String,
    onDismiss: () -> Unit,
) {
    val colors = DeckTheme.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var note by remember { mutableStateOf("") }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.background,
        shape = Radius.sheetShape,
        dragHandle = null,
    ) {
        DeckSheetChrome()
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .padding(top = Space.x5, bottom = Space.x8),
        ) {
            Text("Window settings", style = DeckType.title, color = colors.primary)

            // Privacy — the label is the current state, the button is the destination.
            SectionCaption("Privacy")
            DeckGroup {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = Space.card),
                ) {
                    Text(
                        text = if (window.isolated) "Private" else "Shared",
                        style = DeckType.body,
                        color = colors.primary,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = if (window.isolated) "Make shared" else "Make private",
                        style = DeckType.value,
                        color = colors.accent,
                        modifier = Modifier
                            .padding(vertical = Space.x2)
                            .clickable {
                                controller.act(
                                    windowId,
                                    if (window.isolated) BrowserWindowAction.Share else BrowserWindowAction.Isolate,
                                )
                            },
                    )
                }
            }

            // Session — the binding, and the way to change it.
            SectionCaption("Session")
            DeckGroup {
                if (window.isBound) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = Space.card),
                    ) {
                        Text(
                            text = window.sessionTitle?.takeIf { it.isNotEmpty() } ?: window.session.orEmpty(),
                            style = DeckType.body,
                            color = colors.primary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        DeckDestructiveText(label = "Detach", onClick = { controller.bind(windowId, null) })
                    }
                    if (sessions.isNotEmpty()) DeckDivider(startIndent = Space.card)
                }
                if (sessions.isEmpty()) {
                    DeckFootnote("No session on $machineLabel to attach this window to.")
                } else {
                    AttachMenu(sessions = sessions, current = window.session) { controller.bind(windowId, it) }
                }
            }

            // Screenshot — to the phone, to look; or to a session, to hand it to the agent. Two acts,
            // deliberately not one control, because they end in different places.
            SectionCaption("Screenshot")
            DeckGroup {
                Column(modifier = Modifier.padding(Space.card)) {
                    if (sessions.isNotEmpty()) {
                        DeckTextField(
                            value = note,
                            onValueChange = { note = it },
                            placeholder = "Note (optional)",
                            singleLine = true,
                        )
                        Spacer(Modifier.padding(top = Space.x2))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.x3)) {
                        LabelledAction(
                            icon = Icons.Filled.CameraAlt,
                            label = "Screenshot",
                            onClick = { controller.shot(windowId) },
                            modifier = Modifier.weight(1f),
                        )
                        SendToSession(
                            sessions = sessions,
                            onSend = { controller.shot(windowId, session = it, note = note); note = "" },
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
            DeckFootnote(
                "The machine photographs the whole window. Sent to a session instead, the file lands " +
                    "on $machineLabel and its name is typed into that session with your note."
            )

            // Click flow — record the steps the recorder collects, and read them back. There is no
            // push for steps, so the refresh re-asks.
            SectionCaption("Click flow")
            DeckGroup {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = Space.card),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .weight(1f)
                            .clickable {
                                controller.act(
                                    windowId,
                                    if (window.recording) BrowserWindowAction.RecordOff else BrowserWindowAction.RecordOn,
                                )
                            }
                            .padding(vertical = Space.x2),
                    ) {
                        Icon(
                            if (window.recording) Icons.Filled.StopCircle else Icons.Filled.FiberManualRecord,
                            contentDescription = null,
                            tint = if (window.recording) colors.critical else colors.accent,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(Space.x2))
                        Text(
                            text = if (window.recording) "Stop recording" else "Record the click flow",
                            style = DeckType.body,
                            color = colors.primary,
                        )
                    }
                    IconButton(onClick = { controller.readSteps(windowId) }) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Re-read steps", tint = colors.faint)
                    }
                }
                if (steps.isNotEmpty()) {
                    DeckDivider(startIndent = Space.card)
                    StepList(steps)
                } else if (window.recording) {
                    DeckFootnote("Nothing yet.")
                }
            }

            // Delete — the window on the machine, closed everywhere.
            SectionCaption("Delete")
            DeckGroup {
                Box(modifier = Modifier.padding(horizontal = Space.card, vertical = Space.x2)) {
                    DeckDestructiveText(
                        label = "Delete window",
                        onClick = { controller.act(windowId, BrowserWindowAction.Close) },
                    )
                }
            }
        }
    }
}

/** The list of sessions this window can be attached to, each sending a bind. A check on the current. */
@Composable
private fun AttachMenu(sessions: List<WindowSession>, current: String?, onBind: (String) -> Unit) {
    Column {
        sessions.forEachIndexed { index, session ->
            if (index > 0) DeckDivider(startIndent = Space.card)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .clickable { onBind(session.id) }
                    .padding(horizontal = Space.card, vertical = Space.x2),
            ) {
                Text(
                    text = sessionLabel(session),
                    style = DeckType.body,
                    color = if (session.id == current) DeckTheme.colors.accent else DeckTheme.colors.primary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (session.id == current) {
                    Text("Attached", style = DeckType.caption, color = DeckTheme.colors.faint)
                }
            }
        }
    }
}

@Composable
private fun LabelledAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
        modifier = modifier
            .heightIn(min = 44.dp)
            .clip(Radius.fieldShape)
            .background(DeckTheme.colors.surfaceHigh)
            .clickable(onClick = onClick)
            .padding(horizontal = Space.x3),
    ) {
        Icon(icon, contentDescription = null, tint = DeckTheme.colors.secondary, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(Space.x2))
        Text(label, style = DeckType.value, color = DeckTheme.colors.primary, maxLines = 1)
    }
}

@Composable
private fun SendToSession(
    sessions: List<WindowSession>,
    onSend: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var open by remember { mutableStateOf(false) }
    Box(modifier = modifier) {
        LabelledAction(
            icon = Icons.AutoMirrored.Filled.Send,
            label = "Send to a session",
            onClick = { if (sessions.isNotEmpty()) open = true },
            modifier = Modifier.fillMaxWidth(),
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            sessions.forEach { session ->
                DropdownMenuItem(
                    text = { Text(sessionLabel(session)) },
                    onClick = { open = false; onSend(session.id) },
                )
            }
        }
    }
}

@Composable
private fun StepList(steps: List<RecordedStep>) {
    val first = steps.firstOrNull()?.at ?: 0.0
    Column(modifier = Modifier.padding(Space.card)) {
        steps.forEachIndexed { index, step ->
            if (index > 0) Spacer(Modifier.padding(top = Space.x2))
            Row(verticalAlignment = Alignment.Top) {
                Text(
                    text = offsetLabel(step.at, first),
                    style = DeckType.monoSmall,
                    color = DeckTheme.colors.faint,
                    modifier = Modifier.width(44.dp),
                )
                Spacer(Modifier.width(Space.x2))
                Column(modifier = Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = step.kind,
                            style = DeckType.monoSmall,
                            color = DeckTheme.colors.secondary,
                            modifier = Modifier
                                .clip(Radius.small)
                                .background(DeckTheme.colors.surfaceHigh)
                                .padding(horizontal = Space.x15, vertical = Space.half),
                        )
                        step.detail?.takeIf { it.isNotEmpty() }?.let {
                            Spacer(Modifier.width(Space.x2))
                            Text(it, style = DeckType.caption, color = DeckTheme.colors.primary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    step.value?.takeIf { it.isNotEmpty() }?.let {
                        Text(it, style = DeckType.caption, color = DeckTheme.colors.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    step.selector?.takeIf { it.isNotEmpty() }?.let {
                        Text(it, style = DeckType.mono, color = DeckTheme.colors.faint, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

/** A step's offset from the first — `+1.2s`, `+12s` above ten seconds, and blank rather than `+0.0s`
 *  when the stamps are missing. */
private fun offsetLabel(at: Double, first: Double): String {
    if (at <= 0.0 || first <= 0.0) return ""
    val seconds = (at - first) / 1000.0
    if (seconds <= 0.0) return ""
    return if (seconds >= 10) "+${seconds.toInt()}s" else "+${(Math.round(seconds * 10) / 10.0)}s"
}

private fun sessionLabel(session: WindowSession): String {
    val name = session.title.ifEmpty { session.id }
    return when (session.windows) {
        0 -> name
        1 -> "$name · 1 window"
        else -> "$name · ${session.windows} windows"
    }
}
