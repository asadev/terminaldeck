package dev.terminaldeck.android.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.CopilotView
import dev.terminaldeck.android.protocol.ChatRole
import dev.terminaldeck.android.protocol.CopilotAccess
import dev.terminaldeck.android.protocol.CopilotActionRow
import dev.terminaldeck.android.protocol.CopilotChatMessage
import dev.terminaldeck.android.protocol.CopilotDesk
import dev.terminaldeck.android.protocol.CopilotEntry
import dev.terminaldeck.android.protocol.CopilotOutcome
import dev.terminaldeck.android.protocol.CopilotSendState
import dev.terminaldeck.android.protocol.CopilotText
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.kit.DeckTag
import dev.terminaldeck.android.ui.kit.DeckTextField
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space
import kotlinx.coroutines.flow.filter

/**
 * The copilot, on a phone.
 *
 * Asad, holding the iOS release for this: *"We need to build a copilot in the phone app too, because
 * we need to connect the copilot also and we should be able to control the copilot from the phone
 * also."* And: *"Phones will have full control over copilot, same as the actual machine app."*
 *
 * A transcription of `ios/TerminalDeck/Screens/CopilotView.swift`.
 *
 * ## One list: what it said and what it did, interleaved
 *
 * The timeline is chat bubbles and tool rows in arrival order, not a chat pane with an activity pane
 * behind a segment. *"exactly like you are working now for me — but now you are working in folders
 * and files, I don't know which files where and all that stuff. Here I can actually see it."* Two
 * panes would put the answer in one and the machinery in the other and leave a person correlating
 * them by timestamp on a four-inch screen.
 *
 * ## Five states, and none of them is a lie
 *
 * [CopilotAccess] has five cases and this screen draws five different things.
 *
 * `NotOffered` — there is no copilot here **for this phone** — is nearly unreachable, because the
 * pill only exists when the copilot does. It is drawn anyway, and it says two things in one sentence
 * on purpose: that machine may be running a build with no copilot in it, or this phone may be paired
 * with it as a guest. This end genuinely cannot tell, by design.
 *
 * `NotGranted` is *open, and given nothing*. It should not happen — one of the owner's own devices is
 * granted every tier — so it is drawn as what it is: a machine saying something this build did not
 * expect, stated rather than hidden behind a blank screen that would read as a bug here.
 *
 * ## No tab bar over the composer
 *
 * *"If we are on copilot on mobile version, now if we want to type here, the pill is still there. Why
 * is the pill there if we can type here? Either we will type or we will use the pill."* The bar is
 * withdrawn from this screen in `MainActivity`, which is where every other rule about the app's own
 * chrome is stated — a screen that hid the bar for itself would be one screen deciding something
 * about the whole app.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CopilotScreen(
    view: CopilotView,
    machineLabel: String,
    /**
     * The way off this screen, and it is load bearing in a way an ordinary back button is not.
     *
     * The tab bar is withdrawn here — *"if we are on copilot on mobile version, now if we want to
     * type here, the pill is still there. Why is the pill there if we can type here? Either we will
     * type or we will use the pill."* — and a tab that hides its own bar has no way out: there is no
     * chevron over a tab's root and no gesture that pops one. Anything that removes or conditions
     * this strands somebody here.
     */
    onLeave: () -> Unit,
    onStart: () -> Unit,
    onCancel: () -> Unit,
    onStopRun: () -> Unit,
    /**
     * Restart — end this run and start a fresh one in the same folder, one tap.
     *
     * The copilot has no session list, no +, and no per-row Delete (those belong to ordinary
     * sessions), so this is the *only* way to a clean conversation — Asad's *"keep restart for copilot
     * only."* It sits beside End the run, and the controller sequences the stop and the start so the
     * idempotent `copilot.start` cannot hand the old run straight back. Mirrors iOS's `restartCopilot`.
     */
    onRestart: () -> Unit,
    onSay: (String) -> Boolean,
    onCopy: (String) -> Unit,
    onOpened: () -> Unit,
    onClosed: () -> Unit,
    onSessions: () -> Unit,
    onLog: () -> Unit,
    /**
     * The copilot's controls — the gear in this bar opens them. Asad: *"all the control about
     * copilot, all the settings of the copilot… three dots, maybe your settings button."* Every
     * setting and switch about the copilot on this machine lives one push away, so the conversation's
     * own bar keeps only what somebody uses while talking.
     */
    onControls: () -> Unit,
    onDismissNotice: () -> Unit,
) {
    val colors = DeckTheme.colors
    var draft by remember { mutableStateOf("") }
    val listState = rememberLazyListState()

    /*
     * Whether to keep following the conversation down.
     *
     * The whole of *"do not fight the reader"*. A timeline that jumps to the end on every frame is
     * unusable while an agent is writing and somebody is scrolled up reading what it said a minute
     * ago — which is exactly when a copilot is worth reading.
     *
     * Settled **when a scroll finishes**, not read live, and that ordering is the difference
     * between working and not. Read live it answers about the layout the *new* frame has already
     * produced: the row that just arrived pushes the foot of the list off the screen, so "is the
     * bottom visible" is false at the exact instant the decision is being made, and the view never
     * follows anything. Measured on an emulator — a reply arrived, went under the composer, and
     * stayed there. Deciding at the end of each scroll instead means growth alone cannot change the
     * answer; only a finger can, which is the property that was wanted.
     */
    var following by remember { mutableStateOf(true) }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }
            .filter { !it }
            .collect {
                val info = listState.layoutInfo
                val last = info.visibleItemsInfo.lastOrNull()
                following = last == null || last.index >= info.totalItemsCount - 1
            }
    }

    /*
     * Attach while the screen is up and detach on the way out.
     *
     * The attach is `read` and spends nothing, so it is safe to do on every visit; the detach is what
     * stops the far side streaming a conversation to a screen that is no longer drawn. Neither ends
     * the run — that is `stop`, which is a button.
     */
    DisposableEffect(Unit) {
        onOpened()
        onDispose { onClosed() }
    }

    /*
     * Follow the conversation down as it **grows**, not only as it lengthens.
     *
     * This was keyed on `entries.size`, and the shape of a streaming answer is the one case that
     * key cannot see: the same message id arriving again with more text in it. So a reply longer
     * than the screen was written entirely below the fold, and the view sat still through all of
     * it. Photographed on an emulator on 2026-08-22 — the answer to a message ran off the bottom
     * of the list and under the composer, and nothing moved.
     *
     * The key is a digest that changes on both: how many rows there are, and **what the last one
     * says**. Length alone was the first attempt and it has a hole big enough to reproduce the
     * original bug: a bounded tail — `chat-serve.ts` truncates a bubble, and the harness sends the
     * last 4000 characters of a session — stops growing while its *content* keeps changing, so the
     * digest freezes at the cap and the view stops following at exactly the point a long answer
     * needs it most. A hash of the text costs one pass over the last row and has no such ceiling.
     *
     * Scrolling to [BOTTOM] rather than to the last row, and the difference matters for exactly the
     * same case: `animateScrollToItem` puts an item's **top** at the top of the viewport, so a tall
     * streaming answer would be scrolled to its first line. A one-pixel row after it means the
     * bottom of the content lands at the bottom of the screen.
     */
    val tail = view.entries.lastOrNull()?.let { entry ->
        val length = when (entry) {
            is CopilotEntry.Said -> entry.message.text.hashCode()
            is CopilotEntry.Did -> entry.row.detail.hashCode()
            is CopilotEntry.Mine -> entry.text.hashCode()
        }
        "${view.entries.size}:${entry.id}:$length"
    }
    /*
     * `scrollToItem`, not `animateScrollToItem`, and this is the third thing that had to be right
     * before a streaming answer would follow.
     *
     * An animated scroll takes a few hundred milliseconds. A `LaunchedEffect` keyed on the digest
     * is **cancelled and restarted** every time the digest moves, and while an agent is writing
     * that is many times a second — so every animation was killed a few milliseconds in, the next
     * one started from where the last one gave up, and the net movement over a whole reply was
     * close to nothing. That is what the emulator kept showing: a reply growing steadily off the
     * bottom of a list that never moved.
     *
     * An instant scroll finishes inside one frame, so there is nothing for the next frame to
     * interrupt. It does not read as a jump either, because [following] already guarantees the
     * bottom is where the reader is: staying pinned to the end of text that is growing looks like
     * text growing, which is the thing it actually is.
     */
    LaunchedEffect(tail) {
        if (view.entries.isEmpty() || !following) return@LaunchedEffect
        listState.scrollToItem(view.entries.size)
        /*
         * And again on the next frame, because the first one scrolled a layout that did not yet
         * contain the row this effect was woken by.
         *
         * `LaunchedEffect` runs as the composition is applied, before the new row has been measured,
         * so the clamp at the end of the list is computed against the old height and lands short —
         * on an emulator, just far enough short to hide a message that had *just* been sent, which
         * is the one row a person is looking for. One extra frame is imperceptible and costs a
         * single suspension.
         */
        withFrameNanos {}
        listState.scrollToItem(view.entries.size)
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            DeckTopBar(
                title = "Copilot",
                subtitle = machineLabel,
                onBack = onLeave,
                actions = {
                    if (view.access != CopilotAccess.NotOffered && view.access != CopilotAccess.Connecting) {
                        IconButton(onClick = onSessions) {
                            Icon(
                                Icons.Filled.Terminal,
                                contentDescription = "Sessions the copilot started",
                                tint = colors.secondary,
                            )
                        }
                        IconButton(onClick = onLog) {
                            Icon(
                                Icons.Filled.History,
                                contentDescription = "What the copilot has been doing",
                                tint = colors.secondary,
                            )
                        }
                    }
                    // The gear, at the trailing edge, over every state that has a copilot behind it
                    // — its controls do not need a live run, so it is not gated on one. A gear
                    // collides with nothing in this app and says what it does.
                    if (view.access != CopilotAccess.NotOffered) {
                        IconButton(onClick = onControls) {
                            Icon(
                                Icons.Filled.Settings,
                                contentDescription = "Copilot controls",
                                tint = colors.secondary,
                            )
                        }
                    }
                },
            )
        },
    ) { padding ->
        /*
         * The top inset here, the bottom one on the composer — never both.
         *
         * `Scaffold` hands back a padding that already reserves the navigation
         * bar, and the composer reserved it a second time, so the bar sat a
         * navigation bar's height above the bottom of the screen with a band of
         * empty surface underneath it. Taking only the top means one owner for
         * the bottom edge, which is also the only way the composer can swap that
         * inset for the keyboard's when one appears.
         */
        Column(modifier = Modifier.fillMaxSize().padding(top = padding.calculateTopPadding())) {
            when (view.access) {
                CopilotAccess.NotOffered -> Explanation(
                    title = "No copilot here",
                    detail = "Either $machineLabel is running a build without one, or this phone is " +
                        "paired with it as a guest. This end cannot tell which, and that is by " +
                        "design — a guest is not told what it is not allowed to see.",
                )

                CopilotAccess.Connecting -> Explanation(
                    title = "Opening the copilot…",
                    detail = "$machineLabel has one. This is the moment between asking for it and " +
                        "being told what this phone may do with it.",
                )

                CopilotAccess.NotGranted -> Explanation(
                    title = "Open, and given nothing",
                    detail = "$machineLabel opened its copilot to this phone and then granted it " +
                        "nothing at all. That should not happen — one of your own devices is " +
                        "granted every tier — so it is stated rather than drawn as an empty screen.",
                )

                CopilotAccess.Watch, CopilotAccess.Direct -> {
                    StateStrip(view = view, machineLabel = machineLabel)

                    Box(modifier = Modifier.weight(1f)) {
                        if (view.entries.isEmpty()) {
                            /*
                             * Three empties, and they are not the same empty.
                             *
                             * A run that has said nothing yet is waiting for a question; a machine
                             * with no run is waiting for a tap; a device that may only watch is
                             * waiting for somebody else. Keying this on `canStart` alone drew
                             * *"Watching"* over a live run with a composer under it — which is the
                             * screen telling somebody they cannot do the thing they are about to do.
                             */
                            Explanation(
                                title = when {
                                    view.state == null -> "Asking $machineLabel"
                                    view.state?.hasRun == true -> "Nothing said yet"
                                    view.canStart -> "No conversation on this machine yet"
                                    view.access == CopilotAccess.Watch -> "Watching"
                                    else -> "Nothing to talk to yet"
                                },
                                detail = when {
                                    /*
                                     * A fourth empty, and it is the one that was a lie.
                                     *
                                     * With no `copilot.state` in hand this screen used to fall
                                     * through to *"Watching"* — telling a phone that had been
                                     * granted every tier that it was a spectator, over a composer
                                     * that was not drawn. It is not watching; it has not been
                                     * answered yet, and those are different facts.
                                     */
                                    view.state == null ->
                                        "This phone has asked $machineLabel what its copilot is " +
                                            "doing and has not been answered yet."
                                    view.state?.hasRun == true ->
                                        "Ask it something and what it says and what it does both " +
                                            "land here, in the order they happen."
                                    view.canStart ->
                                        "Start a run and what it says and what it does both land " +
                                            "here, in the order they happen."
                                    view.access == CopilotAccess.Watch ->
                                        "What the copilot says and what it does will land here, in " +
                                            "the order they happen. This phone may watch it and " +
                                            "nothing else."
                                    else ->
                                        "What the copilot says and what it does will land here, in " +
                                            "the order they happen."
                                },
                            )
                        } else {
                            LazyColumn(
                                state = listState,
                                contentPadding = PaddingValues(
                                    start = Space.screen,
                                    end = Space.screen,
                                    top = Space.x2,
                                    bottom = Space.x4,
                                ),
                                verticalArrangement = Arrangement.spacedBy(Space.x2),
                                modifier = Modifier.fillMaxSize(),
                            ) {
                                items(view.entries, key = { it.id }) { entry ->
                                    when (entry) {
                                        is CopilotEntry.Said -> Bubble(
                                            message = entry.message,
                                            onCopy = onCopy,
                                            // Run is Say under the hood — the copilot on the far end
                                            // is a Claude CLI, and running a command means handing it
                                            // to that agent, exactly as typing it would. See the iOS
                                            // CopilotLink.run note.
                                            onRun = { onSay(it) },
                                            canRun = view.canSay,
                                        )
                                        is CopilotEntry.Did -> ToolRow(entry.row)
                                        is CopilotEntry.Mine -> MineBubble(entry, onCopy)
                                    }
                                }
                                // The three-dot typing pulse, where the reply will land. Asad: "a
                                // typing/waiting animation while awaiting a reply… so it's obvious
                                // something is happening." On when the newest thing said was ours.
                                if (copilotAwaitingReply(view.entries)) {
                                    item(key = "copilot.typing") { TypingIndicator() }
                                }
                                // The foot of the conversation, one pixel tall and stably keyed.
                                // Everything above about following a *growing* answer down depends
                                // on this row existing; see the scroll effect at the top of the file.
                                item(key = BOTTOM) { Spacer(Modifier.height(Dp.Hairline)) }
                            }
                        }
                    }

                    view.notice?.let { notice ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable(onClick = onDismissNotice)
                                .padding(horizontal = Space.screen, vertical = Space.x2),
                        ) {
                            Text(
                                text = notice.text,
                                style = DeckType.caption,
                                color = if (notice.ok) colors.secondary else colors.critical,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }

                    Composer(
                        view = view,
                        draft = draft,
                        onDraft = { draft = it },
                        // Takes the fully composed message (words plus any attachment names) and
                        // says whether it went, so the field and the chips clear only on success.
                        onSend = { text -> onSay(text).also { if (it) draft = "" } },
                        onStart = onStart,
                        onCancel = onCancel,
                        onStopRun = onStopRun,
                        onRestart = onRestart,
                    )
                }
            }
        }
    }
}

/**
 * What the copilot is, in one line.
 *
 * Every figure here is one the machine sent and each is drawn only when it says something: a token
 * count of zero between turns is not news, and a profile the machine did not name is not a blank
 * chip. **The desk and this device's run are separate**, and folding them would show "running"
 * because somebody at the desk was working, over a tab with nothing in it.
 */
@Composable
private fun StateStrip(view: CopilotView, machineLabel: String) {
    val colors = DeckTheme.colors
    /*
     * No state is a state, and it needs a line of its own.
     *
     * `dropped()` clears the state when the socket goes, which is right — a reading is a claim
     * about now — but the screen then drew nothing at all: a conversation with no strip above it
     * and, since the composer has nothing to offer either, no chrome whatsoever. A person watching
     * that happen sees the app quietly lose half its screen and is told nothing. Reproduced by
     * turning airplane mode on and off on an emulator.
     *
     * So the absence is said out loud, in the place the state would have been.
     */
    val state = view.state ?: run {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Space.screen, vertical = Space.x2),
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(androidx.compose.foundation.shape.CircleShape)
                    .background(colors.faint)
            )
            Spacer(Modifier.width(Space.x2))
            Text(
                text = "Waiting for $machineLabel to say what its copilot is doing",
                style = DeckType.caption,
                color = colors.faint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        return
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = Space.screen, vertical = Space.x2),
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(androidx.compose.foundation.shape.CircleShape)
                .background(
                    when {
                        state.hasRun -> colors.working
                        state.desk == CopilotDesk.Running -> colors.positive
                        state.desk == CopilotDesk.Starting -> colors.warning
                        else -> colors.faint
                    }
                )
        )
        Spacer(Modifier.width(Space.x2))
        Text(
            text = buildString {
                append(
                    when {
                        state.hasRun -> "Your run"
                        state.desk == CopilotDesk.Running -> "Running at the desk"
                        state.desk == CopilotDesk.Starting -> "Starting"
                        state.desk == CopilotDesk.Stopped -> "Stopped"
                        else -> "Unknown"
                    }
                )
                state.profile?.takeIf { it.isNotEmpty() }?.let { append(" · $it") }
                if (state.turnTokens > 0) append(" · ${state.turnTokens} tokens this turn")
                if (state.tools > 0) append(" · ${state.tools} tools")
            },
            style = DeckType.caption,
            color = colors.faint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        // Watching, said out loud. Somebody on a read-only grant needs to know why there is no
        // composer, and a screen that simply lacked one would read as a bug.
        if (view.access == CopilotAccess.Watch) {
            Spacer(Modifier.width(Space.x2))
            DeckTag("watching")
        }
        // Confirmations waiting elsewhere. Not this device's — those are a sheet — so this is a
        // count and nothing more.
        val elsewhere = view.pending.count { !it.mine }
        if (elsewhere > 0) {
            Spacer(Modifier.width(Space.x2))
            Text(
                text = if (elsewhere == 1) "1 waiting on $machineLabel" else "$elsewhere waiting on $machineLabel",
                style = DeckType.caption,
                color = colors.warning,
                maxLines = 1,
            )
        }
    }
}

/**
 * The composer, or the one button that comes before it.
 *
 * Three states and they are not interchangeable: no run yet (Start, and it is the only thing on the
 * bar because it is the only thing that can happen), a run with a turn in flight (Stop the turn), and
 * a run waiting for you (the field). A screen that drew the field over a run that does not exist
 * would be a control whose only outcome is a refusal.
 */
@Composable
private fun Composer(
    view: CopilotView,
    draft: String,
    onDraft: (String) -> Unit,
    onSend: (String) -> Boolean,
    onStart: () -> Unit,
    onCancel: () -> Unit,
    onStopRun: () -> Unit,
    onRestart: () -> Unit,
) {
    val colors = DeckTheme.colors

    /*
     * Files pinned to the next message.
     *
     * Asad, bringing the composer up to standard: *"The input box must match a modern AI chat: a
     * plus button and attach files, and the usual essentials. The current copilot input is bare —
     * bring it up to Claude-chat standard."* So the plus opens the file and photo pickers and what
     * they return sits here as chips over the field, cleared when the message goes.
     *
     * The bytes do not cross this wire — a `copilot.say` is one line of text into a pty, there is no
     * attach frame, and the copilot's own run is hidden from this phone — so a picked file cannot be
     * uploaded to the copilot. What *can* reach it is the message, so the names ride in the text
     * (see `composed`), and the copilot, which is on the machine with a filesystem of its own, is
     * told what it is being pointed at. Delivering the bytes needs a frame the desktop does not yet
     * speak; that is the one part of this the phone cannot finish alone.
     */
    var attachments by remember { mutableStateOf(listOf<String>()) }
    var menuOpen by remember { mutableStateOf(false) }

    val pickFiles = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        attachments = attachments + uris.map { it.lastPathSegment?.substringAfterLast('/') ?: "file" }
    }
    val pickPhotos = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia()
    ) { uris ->
        attachments = attachments + uris.map { "Photo" }
    }

    fun composed(): String {
        val base = draft.trim()
        if (attachments.isEmpty()) return base
        val names = attachments.joinToString(", ")
        return if (base.isEmpty()) "Attached: $names" else "$base (attached: $names)"
    }
    /*
     * Nothing at all, rather than an empty bar.
     *
     * A `Column` with a surface colour and two paddings is a **visible block** even when every
     * branch below draws nothing, and that is what a phone met on this screen: a dead grey strip
     * across the bottom, the height of a control, with no control in it. Asked for on the same
     * pass as the rest of this file — *"never a dead control"* — and the honest version of a bar
     * with nothing to put on it is no bar.
     */
    val hasReason = view.unavailable != null
    val hasControls = view.access.canAct && (view.canStart || view.state?.hasRun == true)
    if (!hasReason && !hasControls) return

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.surface)
            /*
             * One inset, not two stacked.
             *
             * `navigationBarsPadding().imePadding()` adds both, and while the keyboard is up the
             * IME inset **already covers** the navigation bar — so the composer floated a
             * navigation bar's height above the keyboard with a band of empty surface under it.
             * `union` takes the larger of the two, which is the whole of what is wanted here.
             */
            .windowInsetsPadding(
                WindowInsets.navigationBars
                    .union(WindowInsets.ime)
                    .only(WindowInsetsSides.Bottom)
            )
            .padding(horizontal = Space.screen, vertical = Space.x2),
    ) {
        view.unavailable?.let { reason ->
            // The machine's own sentence for why there is nothing to start — *"no API key
            // configured"* is not a thing this end can rephrase without guessing at a setup it
            // cannot see.
            DeckFootnote(reason, color = colors.warning)
        }

        when {
            !view.access.canAct -> Unit

            view.canStart -> DeckPrimaryButton(label = "Start a run", onClick = onStart)

            view.state?.hasRun == true -> {
                if (attachments.isNotEmpty()) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(Space.x2),
                        modifier = Modifier
                            .horizontalScroll(rememberScrollState())
                            .padding(bottom = Space.x2),
                    ) {
                        attachments.forEach { name ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(Space.x1),
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(colors.surfaceHigh)
                                    .clickable { attachments = attachments - name }
                                    .padding(horizontal = Space.x3, vertical = Space.x1),
                            ) {
                                Text(name, style = DeckType.caption, color = colors.secondary)
                                Text("×", style = DeckType.caption, color = colors.faint)
                            }
                        }
                    }
                }

                val canSend = draft.isNotBlank() || attachments.isNotEmpty()
                Row(verticalAlignment = Alignment.Bottom) {
                    Box {
                        // The plus — a modern chat's leading control, and the door to everything
                        // that is not typing.
                        IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(48.dp)) {
                            Icon(Icons.Filled.Add, contentDescription = "Add", tint = colors.secondary)
                        }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            DropdownMenuItem(
                                text = { Text("Attach files") },
                                onClick = {
                                    menuOpen = false
                                    pickFiles.launch(arrayOf("*/*"))
                                },
                            )
                            DropdownMenuItem(
                                text = { Text("Photos") },
                                onClick = {
                                    menuOpen = false
                                    pickPhotos.launch(
                                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                                    )
                                },
                            )
                        }
                    }
                    DeckTextField(
                        value = draft,
                        onValueChange = onDraft,
                        placeholder = "Ask the copilot",
                        singleLine = false,
                        maxLines = 5,
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.width(Space.x2))
                    IconButton(
                        onClick = { if (onSend(composed())) attachments = emptyList() },
                        enabled = canSend,
                        modifier = Modifier.size(48.dp),
                    ) {
                        Icon(
                            Icons.AutoMirrored.Filled.Send,
                            contentDescription = "Send",
                            tint = if (canSend) colors.accent else colors.faint,
                        )
                    }
                }
                Spacer(Modifier.height(Space.x2))
                Row(horizontalArrangement = Arrangement.spacedBy(Space.x2)) {
                    // Interrupt the turn, and end the run. Two different acts, and the second is the
                    // one that cannot be taken back — which is why they are not one button whose
                    // meaning depends on what the agent happens to be doing.
                    DeckQuietButton(label = "Stop the turn", onClick = onCancel, modifier = Modifier.weight(1f))
                    DeckQuietButton(label = "End the run", onClick = onStopRun, modifier = Modifier.weight(1f))
                }
                Spacer(Modifier.height(Space.x2))
                // Restart — the copilot's *"keep restart for copilot only"*. End the run and start a
                // fresh one in the same folder, one tap: with no session list, no +, and no Delete
                // here, this is the only clean slate. Full width because it is the whole-conversation
                // act, set apart from the two turn/run controls above it. See [onRestart].
                DeckQuietButton(
                    label = "Restart",
                    onClick = onRestart,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            else -> Unit
        }
    }
}

/**
 * One turn of the conversation, in **Claude's chat layout**.
 *
 * Asad, turning this into a proper AI chat: *"My messages sit in a light-gray/white rounded box; the
 * copilot's replies sit on the base background with NO box around them — exactly Claude's chat
 * layout."* So the two roles are two different shapes, and the difference is a box: the person's
 * words are a light-grey card pushed to the right, the copilot's are plain text the width of the
 * screen with the commands it suggested pulled into their own cards (`CommandCard`). This replaced a
 * design where both sides were coloured cards.
 *
 * Under either, `MessageMeta` draws the time it was said and — on a long-press, hidden otherwise —
 * a copy button, which is Asad's *"a copy button on both my messages and its replies, appearing on
 * hover/long-press, hidden otherwise; a timestamp under each message."*
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Bubble(
    message: CopilotChatMessage,
    onCopy: (String) -> Unit,
    onRun: (String) -> Unit,
    canRun: Boolean,
) {
    val colors = DeckTheme.colors
    val mine = message.role == ChatRole.You
    val display = CopilotText.display(message.text)
    var revealed by remember(message.id) { mutableStateOf(false) }

    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start,
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = { revealed = !revealed },
                    onLongClick = { revealed = true },
                ),
        ) {
            if (mine) {
                // Boxed, right — the person's own words. `surfaceHigh` is the app's grey-on-ground,
                // a distinct light-grey box on the chat's background in both appearances.
                Column(
                    modifier = Modifier
                        .fillMaxWidth(0.88f)
                        .clip(Radius.large)
                        .background(colors.surfaceHigh)
                        .padding(horizontal = Space.x3, vertical = Space.x2),
                ) {
                    Text(display, style = DeckType.control, color = colors.primary)
                    if (message.truncated) {
                        Spacer(Modifier.height(Space.half))
                        Text("…truncated on the machine", style = DeckType.caption, color = colors.faint)
                    }
                }
            } else {
                // No box. Plain text on the base ground, full width, with any suggested command
                // pulled out of the prose into its own card — see [copilotSegments].
                Column(modifier = Modifier.fillMaxWidth()) {
                    CopilotReply(display, onCopy = onCopy, onRun = onRun, canRun = canRun)
                    if (message.truncated) {
                        Spacer(Modifier.height(Space.half))
                        Text("…truncated on the machine", style = DeckType.caption, color = colors.faint)
                    }
                }
            }
        }
        MessageMeta(text = display, at = message.at, revealed = revealed, mine = mine, onCopy = onCopy)
    }
}

/** The copilot's own reply: its prose, and the commands inside it drawn with a Run button. */
@Composable
private fun CopilotReply(
    text: String,
    onCopy: (String) -> Unit,
    onRun: (String) -> Unit,
    canRun: Boolean,
) {
    val colors = DeckTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(Space.x2)) {
        copilotSegments(text).forEach { segment ->
            when (segment) {
                is CopilotSegment.Prose ->
                    Text(segment.text, style = DeckType.control, color = colors.primary)
                is CopilotSegment.Command ->
                    CommandCard(segment.command, segment.language, onCopy = onCopy, onRun = onRun, canRun = canRun)
            }
        }
    }
}

/**
 * A command the copilot suggested, with a **Run** button — the way Claude Code shows a command with
 * a run affordance.
 *
 * Asad: *"When the copilot suggests a command to run, show it with a Run button — tapping it runs
 * the command inside the chat and the output AND full errors appear IN the chat."* Run hands the
 * command to the copilot to execute; the run, the tool row and the reply come back down the same
 * conversation, which is where the output and any error land — in the copilot's own words, as a tool
 * row and a reply.
 *
 * Copy is always here; Run only when the phone may drive the copilot and the command is one line —
 * `copilot.say` is one utterance, so a multi-line block would be run as one wrong line.
 */
@Composable
private fun CommandCard(
    command: String,
    language: String?,
    onCopy: (String) -> Unit,
    onRun: (String) -> Unit,
    canRun: Boolean,
) {
    val colors = DeckTheme.colors
    var ran by remember(command) { mutableStateOf(false) }
    val runnable = canRun && !command.contains("\n")

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(Radius.large)
            .background(colors.surface)
            .border(0.5.dp, colors.hairline, Radius.large),
    ) {
        Row(modifier = Modifier.horizontalScroll(rememberScrollState())) {
            Text(
                command,
                style = DeckType.mono,
                color = colors.primary,
                modifier = Modifier.padding(horizontal = Space.x3, vertical = Space.x2),
            )
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .background(colors.surfaceHigh)
                .padding(horizontal = Space.x3, vertical = Space.x15),
        ) {
            if (!language.isNullOrEmpty()) {
                Text(language, style = DeckType.monoFootnote, color = colors.faint)
            }
            Spacer(Modifier.weight(1f))
            Text(
                "Copy",
                style = DeckType.caption,
                color = colors.secondary,
                modifier = Modifier.clickable { onCopy(command) },
            )
            if (runnable) {
                Spacer(Modifier.width(Space.x3))
                Text(
                    text = if (ran) "Ran" else "Run",
                    style = DeckType.caption,
                    color = colors.onAccent,
                    modifier = Modifier
                        .clip(Radius.fieldShape)
                        .background(if (ran) colors.faint else colors.accent)
                        .clickable(enabled = !ran) { onRun(command); ran = true }
                        .padding(horizontal = Space.x3, vertical = Space.x1),
                )
            }
        }
    }
}

/**
 * The line under a message: when it was said, and a copy button.
 *
 * The time is always here; the button is not — it appears when the row is long-pressed (the reveal
 * flag the bubble owns), and Copy puts the raw text on the pasteboard.
 */
@Composable
private fun MessageMeta(
    text: String,
    at: Long,
    revealed: Boolean,
    mine: Boolean,
    onCopy: (String) -> Unit,
) {
    val colors = DeckTheme.colors
    val stamp = copilotClock(at)
    if (stamp == null && !revealed) return
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = Space.half),
        horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (stamp != null) {
            Text(stamp, style = DeckType.caption, color = colors.faint)
        }
        if (revealed) {
            Spacer(Modifier.width(Space.x2))
            Text(
                "Copy",
                style = DeckType.caption,
                color = colors.secondary,
                modifier = Modifier.clickable { onCopy(text) },
            )
        }
    }
}

/**
 * The three-dot typing pulse, shown while the copilot owes a reply.
 *
 * Asad: *"a typing/waiting animation while awaiting a reply — a three-dot typing pulse… so it's
 * obvious something is happening."* Three dots, each pulsing on the same loop a fifth of a second
 * behind the last, in the copilot's own place on the left, so the pulse turns into the answer where
 * the answer will be. [copilotAwaitingReply] decides when it is on.
 */
@Composable
private fun TypingIndicator() {
    val colors = DeckTheme.colors
    val transition = rememberInfiniteTransition(label = "typing")
    Row(
        horizontalArrangement = Arrangement.spacedBy(Space.x1),
        modifier = Modifier.padding(vertical = Space.x1),
    ) {
        repeat(3) { index ->
            val alpha by transition.animateFloat(
                initialValue = 0.3f,
                targetValue = 1f,
                animationSpec = infiniteRepeatable(
                    animation = tween(durationMillis = 600, delayMillis = index * 200),
                    repeatMode = RepeatMode.Reverse,
                ),
                label = "dot$index",
            )
            Box(
                modifier = Modifier
                    .size(7.dp)
                    .clip(CircleShape)
                    .background(colors.faint.copy(alpha = alpha)),
            )
        }
    }
}

/**
 * Something this phone said, before the machine has said it back.
 *
 * The **same bubble** as [Bubble] on the same side in the same colour, plus one quiet line of
 * status — because it is not a different message, it is this message drawn early. Anything that
 * made it look like a separate kind of row would trade one confusion for another: a person would
 * see their sentence twice, once faint and once solid, and have to work out which one counted.
 *
 * [CopilotSendState.Sending] draws *"sending"*; the wait running out draws the machine's silence
 * rather than a failure, because a message that has not been echoed has not necessarily been lost
 * — the desktop may still be typing it into a prompt. What it definitely is, is unaccounted for,
 * and the row says exactly that with the text still on screen to copy or retype.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MineBubble(entry: CopilotEntry.Mine, onCopy: (String) -> Unit) {
    val colors = DeckTheme.colors
    var revealed by remember(entry.id) { mutableStateOf(false) }

    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            horizontalArrangement = Arrangement.End,
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = { revealed = !revealed },
                    onLongClick = { revealed = true },
                ),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth(0.88f)
                    .clip(Radius.large)
                    .background(colors.surfaceHigh)
                    .padding(horizontal = Space.x3, vertical = Space.x2),
            ) {
                Text(entry.text, style = DeckType.control, color = colors.primary)
                Spacer(Modifier.height(Space.half))
                Text(
                    text = when (entry.state) {
                        CopilotSendState.Sending -> "sending\u2026"
                        CopilotSendState.Unacknowledged -> "The machine has not echoed this back."
                    },
                    style = DeckType.caption,
                    color = when (entry.state) {
                        CopilotSendState.Sending -> colors.faint
                        CopilotSendState.Unacknowledged -> colors.warning
                    },
                )
            }
        }
        MessageMeta(text = entry.text, at = entry.at, revealed = revealed, mine = true, onCopy = onCopy)
    }
}

/**
 * Whether the copilot still owes a reply \u2014 drives the typing pulse.
 *
 * Walk the conversation from the newest end, skipping tool rows (machinery is not a reply), and stop
 * at the first thing said. If the agent said it, the reply has landed. If this phone said it, the
 * reply is still owed \u2014 unless the wait ran out, at which point the outgoing row already says the
 * machine has not echoed it and a pulse would be a second claim of the same thing.
 */
private fun copilotAwaitingReply(entries: List<CopilotEntry>): Boolean {
    for (entry in entries.asReversed()) {
        when (entry) {
            is CopilotEntry.Did -> continue
            is CopilotEntry.Said -> return entry.message.role == ChatRole.You
            is CopilotEntry.Mine -> return entry.state == CopilotSendState.Sending
        }
    }
    return false
}

/** One piece of a copilot reply: prose, or a command it suggested. */
private sealed interface CopilotSegment {
    data class Prose(val text: String) : CopilotSegment
    data class Command(val command: String, val language: String?) : CopilotSegment
}

/**
 * Split a reply into its prose and the fenced commands inside it. Only a **closed** ``` fence
 * becomes a command \u2014 a streaming answer routinely has a half-open fence for a second, and a Run
 * button over a command that is still arriving would run half of it.
 */
private fun copilotSegments(text: String): List<CopilotSegment> {
    val lines = text.split("\n")
    val segments = mutableListOf<CopilotSegment>()
    val prose = mutableListOf<String>()

    fun flushProse() {
        val joined = prose.joinToString("\n").trim()
        if (joined.isNotEmpty()) segments.add(CopilotSegment.Prose(joined))
        prose.clear()
    }

    var i = 0
    while (i < lines.size) {
        val trimmed = lines[i].trim()
        if (trimmed.startsWith("```")) {
            val language = trimmed.removePrefix("```").trim()
            val body = mutableListOf<String>()
            var j = i + 1
            var closed = false
            while (j < lines.size) {
                if (lines[j].trim().startsWith("```")) {
                    closed = true
                    break
                }
                body.add(lines[j])
                j++
            }
            if (closed) {
                flushProse()
                val command = body.joinToString("\n").trim()
                if (command.isNotEmpty()) {
                    segments.add(CopilotSegment.Command(command, language.ifEmpty { null }))
                }
                i = j + 1
            } else {
                for (k in i until lines.size) prose.add(lines[k])
                i = lines.size
            }
        } else {
            prose.add(lines[i])
            i++
        }
    }
    flushProse()
    return if (segments.isEmpty()) listOf(CopilotSegment.Prose(text)) else segments
}

/** A short clock time under a message \u2014 the locale's own short time, or null for an undated line. */
private val copilotTimeFormat: java.text.DateFormat =
    java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT)

private fun copilotClock(epochMillis: Long): String? {
    if (epochMillis <= 0) return null
    return copilotTimeFormat.format(java.util.Date(epochMillis))
}

/**
 * One thing the copilot did.
 *
 * A refused call is drawn as a refusal **in the copilot's own words**: a gate that denies invisibly
 * is indistinguishable from a gate that was never reached.
 */
@Composable
private fun ToolRow(row: CopilotActionRow) {
    val colors = DeckTheme.colors
    val tint = when (row.outcome) {
        CopilotOutcome.Ok -> colors.faint
        CopilotOutcome.Refused -> colors.warning
        CopilotOutcome.Error -> colors.critical
        CopilotOutcome.Unknown -> colors.faint
    }
    DeckGroup {
        Column(modifier = Modifier.padding(horizontal = Space.x3, vertical = Space.x2)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = row.tool.ifEmpty { "tool" },
                    style = DeckType.monoFootnote,
                    color = colors.secondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (row.tier.isNotEmpty()) {
                    Spacer(Modifier.width(Space.x2))
                    DeckTag(row.tier)
                }
                Spacer(Modifier.weight(1f))
                Text(
                    text = when (row.outcome) {
                        CopilotOutcome.Ok -> "ok"
                        CopilotOutcome.Refused -> "refused"
                        CopilotOutcome.Error -> "error"
                        CopilotOutcome.Unknown -> ""
                    },
                    style = DeckType.caption,
                    color = tint,
                )
            }
            // Untrusted display text: it is a summary a tool produced. Drawn as text, never parsed.
            row.detail.takeIf { it.isNotEmpty() }?.let {
                Spacer(Modifier.height(Space.half))
                Text(
                    text = CopilotText.display(it),
                    style = DeckType.mono,
                    color = colors.faint,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            row.refusal?.takeIf { it.isNotEmpty() }?.let {
                Spacer(Modifier.height(Space.half))
                Text(it, style = DeckType.caption, color = colors.warning)
            }
        }
    }
}

/** The key of the one-pixel row at the foot of the timeline. See the scroll effect. */
private const val BOTTOM = "copilot.bottom"

/** A title and its paragraph, for the states that are a sentence rather than a list. */
@Composable
private fun Explanation(title: String, detail: String) {
    val colors = DeckTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Space.screen)
            .padding(top = Space.x10),
    ) {
        Text(title, style = DeckType.title, color = colors.primary)
        Spacer(Modifier.height(Space.x2))
        Text(detail, style = DeckType.control, color = colors.secondary)
    }
}
