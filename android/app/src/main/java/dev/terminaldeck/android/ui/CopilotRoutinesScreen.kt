package dev.terminaldeck.android.ui

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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.CopilotRoutinesView
import dev.terminaldeck.android.protocol.RoutineOutcome
import dev.terminaldeck.android.protocol.RoutineRow
import dev.terminaldeck.android.protocol.RoutineStates
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckSheetChrome
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * The routines, on the phone — the rows the control screen pushes into, and the file behind one. A
 * transcription of `ios/TerminalDeck/Screens/CopilotRoutinesView.swift`.
 *
 * Asad, naming what these are: *"'check the work before it counts as done', 'what happened
 * overnight' … Mac has a lot of things about copilot by the way."* Each name is one file in the
 * machine's routines folder, with a trigger, a folder and a prompt, and this is the half of the
 * Mac's Routines card a phone can honestly carry.
 *
 * ## Nothing here is derived
 *
 * Whether the switch reads as on, whether Run now can be pressed, and the sentence saying why when
 * it cannot, all arrive already decided — `armed`, `canRun`, `runBecause`, `canArm`, `armBecause`.
 * The short version of the argument is the failure it prevents: *a routine that looks armed on a
 * phone and is not*. The one thing this file composes is sentences from facts the machine sent.
 *
 * ## There is no Save, and that is the feature
 *
 * A routine's file is read-only from a phone by design — writing chosen bytes into the routines
 * folder is wider than the alter tier. [RoutineFile.readOnlyBecause] is the machine's own sentence
 * saying so, printed where the Mac draws its Save. **Delete, not Close**, because it removes a file
 * from somebody's disk.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CopilotRoutinesScreen(
    view: CopilotRoutinesView,
    machineLabel: String,
    live: Boolean,
    onBack: () -> Unit,
    onLoad: () -> Unit,
    onRun: (String) -> Unit,
    onHold: (String) -> Unit,
    onArm: (String) -> Unit,
    onDelete: (String) -> Unit,
    onRead: (RoutineRow) -> Unit,
    onDismissNotice: () -> Unit,
) {
    val colors = DeckTheme.colors
    var sheetFor by remember { mutableStateOf<RoutineRow?>(null) }
    var deleting by remember { mutableStateOf<RoutineRow?>(null) }

    LaunchedEffect(Unit) { onLoad() }

    // The graced reading: a control that dies the instant a socket blinks is the *"consistent
    // connection"* complaint, and one still lit five seconds into a real outage cannot act.
    val dead = !live

    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = "Routines", subtitle = machineLabel, onBack = onBack) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding())
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .padding(top = Space.x2, bottom = Space.x8),
        ) {
            DeckGroup {
                if (view.routines.isEmpty()) {
                    Column(modifier = Modifier.padding(Space.card)) {
                        Text(
                            text = if (view.answered) "There are none" else "Reading…",
                            style = DeckType.body,
                            color = colors.primary,
                        )
                        Spacer(Modifier.height(Space.half))
                        Text(
                            text = if (view.answered) {
                                "A routine is one file on the machine: a trigger, a prompt and a folder."
                            } else {
                                "Asking $machineLabel what it runs on its own."
                            },
                            style = DeckType.caption,
                            color = colors.faint,
                        )
                    }
                } else {
                    view.routines.forEachIndexed { index, routine ->
                        if (index > 0) DeckDivider(startIndent = Space.card)
                        RoutineRowBody(routine = routine, dead = dead, onMore = { sheetFor = routine })
                    }
                }
            }
            DeckFootnote(
                "Saved instructions this machine runs on its own — one file each, with a trigger, a " +
                    "folder and a prompt. Kept where the copilot may read them and cannot write " +
                    "them, so one is only made or edited on the machine itself."
            )
            view.notice?.let { sentence ->
                Row(
                    verticalAlignment = Alignment.Top,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = Space.captionIndent, end = Space.captionIndent, top = Space.x2),
                ) {
                    Text(
                        text = sentence,
                        style = DeckType.caption,
                        color = colors.secondary,
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.width(Space.x2))
                    IconButton(onClick = onDismissNotice, modifier = Modifier.size(24.dp)) {
                        Icon(
                            Icons.Filled.Close,
                            contentDescription = "Dismiss",
                            tint = colors.faint,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                }
            }
        }
    }

    sheetFor?.let { routine ->
        RoutineActionSheet(
            routine = routine,
            onDismiss = { sheetFor = null },
            onRun = { sheetFor = null; onRun(routine.id) },
            onHold = { sheetFor = null; onHold(routine.id) },
            onArm = { sheetFor = null; onArm(routine.id) },
            onRead = { sheetFor = null; onRead(routine) },
            onDelete = { sheetFor = null; deleting = routine },
        )
    }

    deleting?.let { routine ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            containerColor = colors.surface,
            titleContentColor = colors.primary,
            textContentColor = colors.secondary,
            title = { Text("Delete ${routine.name}?", style = DeckType.title) },
            text = {
                // Says what is actually destroyed. A routine is a file on somebody's machine and this
                // is the only control that unlinks one, so it names the disk rather than "cannot be
                // undone", which is true of half the screen.
                Text(
                    "Its file is removed from the machine. The machine stops running it.",
                    style = DeckType.footnote,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    deleting = null
                    onDelete(routine.id)
                }) { Text("Delete", style = DeckType.control, color = colors.critical) }
            },
            dismissButton = {
                TextButton(onClick = { deleting = null }) {
                    Text("Keep it", style = DeckType.control, color = colors.accent)
                }
            },
        )
    }
}

/**
 * One routine: what it is, what it is doing, and the `…` that acts on it.
 *
 * The body is not tappable and carries no chevron. There is nothing a whole-row tap could honestly
 * mean — the four verbs are four different acts and one deletes a file — so the row is a reading with
 * its controls gathered behind the one glyph this app uses for *more about this row*.
 */
@Composable
private fun RoutineRowBody(routine: RoutineRow, dead: Boolean, onMore: () -> Unit) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Space.card, vertical = Space.x3),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Space.half)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = routine.name.ifEmpty { routine.id },
                    style = DeckType.body,
                    color = colors.primary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Spacer(Modifier.width(Space.x15))
                RoutineBadge(routine.state)
            }
            if (routine.purpose.isNotEmpty()) {
                Text(
                    text = routine.purpose,
                    style = DeckType.caption,
                    color = colors.faint,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(RoutineLines.schedule(routine), style = DeckType.caption, color = colors.faint)
            Text(RoutineLines.history(routine), style = DeckType.caption, color = colors.faint)
            for (sentence in RoutineLines.alerts(routine)) {
                Text(sentence, style = DeckType.caption, color = colors.warning)
            }
            for (sentence in RoutineLines.notes(routine)) {
                Text(sentence, style = DeckType.caption, color = colors.secondary)
            }
        }
        Spacer(Modifier.width(Space.x2))
        IconButton(onClick = onMore, enabled = !dead, modifier = Modifier.size(32.dp)) {
            Icon(
                Icons.Filled.MoreVert,
                contentDescription = "More about ${routine.name}",
                tint = if (dead) colors.faint else colors.secondary,
            )
        }
    }
}

/** The state as one word, tinted by what it means — the same seven phrases the Mac uses, so one
 *  routine reads the same in both places. The tint is on the badge, not a rule down the side. */
@Composable
private fun RoutineBadge(state: String) {
    val tone = RoutineLines.tone(state)
    Text(
        text = RoutineStates.badge(state),
        style = DeckType.caption.copy(fontWeight = FontWeight.SemiBold),
        color = tone,
        maxLines = 1,
        modifier = Modifier
            .clip(RoundedCornerShape(Radius.sm))
            .background(tone.copy(alpha = 0.12f))
            .padding(horizontal = Space.x15, vertical = Space.half),
    )
}

/**
 * The four verbs. Run now and the switch are disabled from the machine's own booleans, and the
 * sentence saying why is on the row (see [RoutineLines.notes]) rather than in here — a menu row
 * cannot explain itself, and a control that refuses with no reason anywhere is the defect this whole
 * screen is written against.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RoutineActionSheet(
    routine: RoutineRow,
    onDismiss: () -> Unit,
    onRun: () -> Unit,
    onHold: () -> Unit,
    onArm: () -> Unit,
    onRead: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = DeckTheme.colors
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
                .padding(horizontal = Space.screen)
                .padding(top = Space.x5, bottom = Space.x8),
        ) {
            Text(
                text = routine.name.ifEmpty { routine.id },
                style = DeckType.title,
                color = colors.primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(Space.x4))

            SheetAction(
                icon = Icons.Filled.PlayArrow,
                title = "Run now",
                enabled = routine.canRun,
                onClick = onRun,
            )
            if (routine.armed) {
                SheetAction(icon = Icons.Filled.Pause, title = "Hold", enabled = routine.canArm, onClick = onHold)
            } else {
                SheetAction(icon = Icons.Filled.Notifications, title = "Let it run", enabled = routine.canArm, onClick = onArm)
            }
            SheetAction(icon = Icons.Filled.Visibility, title = "Read", enabled = true, onClick = onRead)
            SheetAction(icon = Icons.Filled.Delete, title = "Delete", enabled = true, destructive = true, onClick = onDelete)
        }
    }
}

@Composable
private fun SheetAction(
    icon: ImageVector,
    title: String,
    enabled: Boolean,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = DeckTheme.colors
    val ink = when {
        !enabled -> colors.faint
        destructive -> colors.critical
        else -> colors.primary
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(vertical = Space.x3),
    ) {
        Icon(icon, contentDescription = null, tint = ink, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(Space.x3))
        Text(title, style = DeckType.control, color = ink)
    }
}

/**
 * One routine's file, as it stands on the machine. Pushed rather than sheeted, for the reason the
 * copilot's file editor is: a routine file is a trigger, a folder and up to eight kilobytes of
 * prompt, a screen's worth of text and not a card's. It scrolls in both directions and wraps
 * nothing — a routine's front matter is indented YAML and its prompt is Markdown with columns, and
 * folding a long line into eight phone-width rows destroys the structure rather than presenting it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CopilotRoutineFileScreen(
    view: CopilotRoutinesView,
    routineId: String,
    routineName: String,
    machineLabel: String,
    onBack: () -> Unit,
    onOpen: (String) -> Unit,
    onClose: () -> Unit,
) {
    val colors = DeckTheme.colors
    // Only when it is **this** routine's — a file that arrives for one navigated away from would
    // otherwise be drawn under this heading, which is why the id travels on the frame.
    val file = view.routineFile?.takeIf { it.id == routineId }

    DisposableEffect(routineId) {
        onOpen(routineId)
        onDispose { onClose() }
    }

    val title = file?.file?.takeIf { it.isNotEmpty() } ?: routineName

    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = title, subtitle = machineLabel, onBack = onBack) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding()),
        ) {
            when {
                file == null -> {
                    Box(modifier = Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Text("Reading…", style = DeckType.footnote, color = colors.faint)
                    }
                }

                file.problem != null -> {
                    // The file was in the list and is not on the disk, or the disk refused it. The
                    // frame arrives either way, so this says what happened instead of spinning.
                    Text(
                        text = file.problem!!,
                        style = DeckType.body,
                        color = colors.critical,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = Space.x5, vertical = Space.x4),
                    )
                    Spacer(Modifier.weight(1f))
                }

                else -> {
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxWidth()
                            .verticalScroll(rememberScrollState())
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = Space.screen, vertical = Space.x4),
                    ) {
                        Text(text = file.text, style = DeckType.mono, color = colors.primary)
                    }
                }
            }

            if (file != null && file.problem == null) {
                RoutineFileFoot(truncated = file.truncated, readOnlyBecause = file.readOnlyBecause)
            }
        }
    }
}

/** What the machine said about the file, under it. `readOnlyBecause` is not optional on the wire
 *  precisely so this line is always there — the absence of a Save is the thing somebody asks about. */
@Composable
private fun RoutineFileFoot(truncated: Boolean, readOnlyBecause: String) {
    val colors = DeckTheme.colors
    Column {
        DeckDivider(startIndent = Space.card)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Space.x5)
                .padding(top = Space.x3, bottom = Space.x4),
            verticalArrangement = Arrangement.spacedBy(Space.x15),
        ) {
            if (truncated) {
                Text(
                    "This is the front of the file — the rest was more than one message carries. " +
                        "Open it on the machine to see all of it.",
                    style = DeckType.caption,
                    color = colors.warning,
                )
            }
            Text(readOnlyBecause, style = DeckType.caption, color = colors.secondary)
        }
    }
}

/**
 * What a routine's row says, composed from what the machine sent and nothing else. Pure, because
 * every way one of these can be wrong is silent and most need a machine with a routine engine, a
 * failed run and a clock in the right place to be visible. A transcription of iOS's `RoutineLines`.
 */
object RoutineLines {

    /** The trigger words and the folder it watches. *"no trigger"* is the Mac's own phrase for a
     *  routine with none — a real and worrying state, a prompt nothing will ever fire. */
    fun schedule(routine: RoutineRow): String {
        val whenText = routine.schedule.ifEmpty { "no trigger" }
        val folder = routine.folder
        return if (folder.isNullOrEmpty()) whenText else "$whenText — in $folder"
    }

    /**
     * When it last ran, how that ended, and when it is next due. The outcome belongs to the run that
     * **finished** — a run still in flight is `running`, which the badge already says — so a routine
     * with no `lastRunAt` reads *it has never run* rather than borrowing a time from anywhere.
     */
    fun history(routine: RoutineRow, now: Long = System.currentTimeMillis()): String {
        var sentence = if (routine.lastRunAt != null) {
            val ago = deckActivityLine(routine.lastRunAt, now) ?: "some time ago"
            "Last run $ago — ${outcome(routine)}."
        } else {
            "It has never run."
        }
        routine.nextDueAt?.let { sentence += " Next due ${until(it, now)}." }
        if (routine.missedWhileClosed > 0) {
            sentence += " ${routine.missedWhileClosed} due while the app was closed."
        }
        return sentence
    }

    /** How the last run ended — three answers, because *failed*, *finished* and *the machine could
     *  not say* are three different things and only one is somebody's problem. */
    private fun outcome(routine: RoutineRow): String = when (routine.lastOutcome) {
        RoutineOutcome.Ok -> "finished"
        RoutineOutcome.Failed -> {
            val error = routine.lastError
            if (error.isNullOrEmpty()) "failed" else "failed: $error"
        }
        null -> "outcome unknown"
    }

    /**
     * The lines worth alarm: a routine the engine stopped, a file that did not parse, and whatever
     * the parser could not read. The first is the one the Mac's card calls out above everything —
     * a routine switched off by its own failures and one simply not triggered lately look identical
     * in any list showing a name and a time, and only the first is something to act on.
     */
    fun alerts(routine: RoutineRow, now: Long = System.currentTimeMillis()): List<String> {
        val lines = mutableListOf<String>()
        if (routine.stoppedByFailures) {
            val why = routine.reason ?: "Stopped after ${routine.consecutiveFailures} failures in a row."
            val next = routine.pausedUntil?.let { "It comes back on its own ${until(it, now)}." }
                ?: "It will not run again until you let it run."
            lines.add("$why $next")
        } else if (routine.state == "broken" && routine.reason != null) {
            lines.add(routine.reason!!)
        }
        lines.addAll(routine.problems)
        return lines
    }

    /**
     * The lines worth saying and not worth alarm — including the two that explain a control the
     * machine has switched off. Drawn beside the still-usable `…` rather than inside it, because a
     * disabled menu row cannot carry a reason and *"a blocked control that opens onto a paragraph is
     * a description."* A switch that cannot move and a Run that cannot start have different causes.
     */
    fun notes(routine: RoutineRow): List<String> {
        val lines = mutableListOf<String>()
        // The reason, once. `disabled` and `broken` are excluded because their sentence is already
        // on screen: the first is repeated by armBecause with what to do, the second is an alert.
        if (!routine.stoppedByFailures &&
            routine.state != "disabled" &&
            routine.state != "broken" &&
            routine.reason != null
        ) {
            lines.add(routine.reason!!)
        }
        if (routine.refusedCalls > 0) {
            val calls = if (routine.refusedCalls == 1) "1 call was" else "${routine.refusedCalls} calls were"
            lines.add(
                "$calls refused during its runs — a decision is waiting for you rather than the " +
                    "routine being broken.",
            )
        }
        if (!routine.canArm) routine.armBecause?.let { lines.add(it) }
        if (!routine.canRun) routine.runBecause?.let { lines.add("Run now: $it") }
        return lines
    }

    /**
     * The badge's colour. Seven states and no honest default among them, so an unrecognised word
     * lands on the same neutral as *nothing is listening* rather than borrowing a colour that would
     * make a word this build has never heard of look healthy or broken on a guess.
     */
    @Composable
    fun tone(state: String): Color {
        val colors = DeckTheme.colors
        return when (state) {
            "armed" -> colors.positive
            "running" -> colors.accent
            "paused", "stale" -> colors.warning
            "broken" -> colors.critical
            else -> colors.faint
        }
    }

    /**
     * A moment in the future, said the way a person says it. The sibling of [deckActivityLine],
     * which only looks backwards: a schedule that came due while nothing was listening is genuinely
     * in the past, and *"in -3m"* is worse than the vaguest true answer.
     */
    fun until(atMs: Long, now: Long = System.currentTimeMillis()): String {
        val seconds = (atMs - now) / 1000
        return when {
            seconds <= 0 -> "any moment now"
            seconds < 60 -> "in under a minute"
            seconds < 3600 -> "in ${seconds / 60}m"
            seconds < 86_400 -> "in ${seconds / 3600}h"
            else -> "in ${seconds / 86_400}d"
        }
    }
}
