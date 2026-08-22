package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Terminal
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.CopilotView
import dev.terminaldeck.android.protocol.ChatRole
import dev.terminaldeck.android.protocol.CopilotAccess
import dev.terminaldeck.android.protocol.CopilotActionRow
import dev.terminaldeck.android.protocol.CopilotChatMessage
import dev.terminaldeck.android.protocol.CopilotDesk
import dev.terminaldeck.android.protocol.CopilotEntry
import dev.terminaldeck.android.protocol.CopilotOutcome
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
    onStart: () -> Unit,
    onCancel: () -> Unit,
    onStopRun: () -> Unit,
    onSay: (String) -> Boolean,
    onCopy: (String) -> Unit,
    onOpened: () -> Unit,
    onClosed: () -> Unit,
    onSessions: () -> Unit,
    onLog: () -> Unit,
    onDismissNotice: () -> Unit,
) {
    val colors = DeckTheme.colors
    var draft by remember { mutableStateOf("") }
    val listState = rememberLazyListState()

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

    // The newest bubble, whenever one arrives. `animateScrollToItem` rather than a jump: a
    // conversation that teleported on every token would be unreadable while the agent is writing.
    LaunchedEffect(view.entries.size) {
        if (view.entries.isNotEmpty()) listState.animateScrollToItem(view.entries.lastIndex)
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            DeckTopBar(
                title = "Copilot",
                subtitle = machineLabel,
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
                },
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
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
                            Explanation(
                                title = if (view.canStart) "Nothing yet" else "Watching",
                                detail = if (view.canStart) {
                                    "Start a run and what it says and what it does both land here, " +
                                        "in the order they happen."
                                } else {
                                    "What the copilot says and what it does will land here, in the " +
                                        "order they happen."
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
                                        is CopilotEntry.Said -> Bubble(entry.message, onCopy)
                                        is CopilotEntry.Did -> ToolRow(entry.row)
                                    }
                                }
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
                        onSend = { if (onSay(draft)) draft = "" },
                        onStart = onStart,
                        onCancel = onCancel,
                        onStopRun = onStopRun,
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
    val state = view.state ?: return
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
    onSend: () -> Unit,
    onStart: () -> Unit,
    onCancel: () -> Unit,
    onStopRun: () -> Unit,
) {
    val colors = DeckTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.surface)
            .navigationBarsPadding()
            .imePadding()
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
                Row(verticalAlignment = Alignment.Bottom) {
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
                        onClick = onSend,
                        enabled = draft.isNotBlank(),
                        modifier = Modifier.size(48.dp),
                    ) {
                        Icon(
                            Icons.AutoMirrored.Filled.Send,
                            contentDescription = "Send",
                            tint = if (draft.isNotBlank()) colors.accent else colors.faint,
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
            }

            else -> Unit
        }
    }
}

/** One thing the copilot said, or one thing that was said to it. */
@Composable
private fun Bubble(message: CopilotChatMessage, onCopy: (String) -> Unit) {
    val colors = DeckTheme.colors
    val mine = message.role == ChatRole.You
    Row(
        horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier
                // Bounded, so a long answer does not run edge to edge and lose the shape that says
                // which side said it. 88% is the same fraction iOS's bubble keeps.
                .fillMaxWidth(0.88f)
                .clip(Radius.large)
                .background(if (mine) colors.accentSoft else colors.surface)
                .clickable { onCopy(message.text) }
                .padding(horizontal = Space.x3, vertical = Space.x2),
        ) {
            Text(message.text, style = DeckType.control, color = colors.primary)
            if (message.truncated) {
                Spacer(Modifier.height(Space.half))
                // The desktop saying *there is more of this, go and look on the machine*. Carried
                // through rather than recomputed.
                Text("…truncated on the machine", style = DeckType.caption, color = colors.faint)
            }
        }
    }
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
                Text(it, style = DeckType.mono, color = colors.faint, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            row.refusal?.takeIf { it.isNotEmpty() }?.let {
                Spacer(Modifier.height(Space.half))
                Text(it, style = DeckType.caption, color = colors.warning)
            }
        }
    }
}

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
