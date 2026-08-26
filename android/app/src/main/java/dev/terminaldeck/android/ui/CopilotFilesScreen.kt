package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.CopilotFilesView
import dev.terminaldeck.android.protocol.CopilotFileOwner
import dev.terminaldeck.android.protocol.CopilotFileRow
import dev.terminaldeck.android.transfer.byteSize
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckTextField
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * The copilot's own files, on the phone — the card the control screen pushes into, and the editor
 * behind each row. A transcription of `ios/TerminalDeck/Screens/CopilotFilesView.swift`.
 *
 * Asad, looking at the Mac's Copilot pane beside the phone's: *"it reads and writes two kinds of
 * prompts and only one is ours … its memory folder which is actually here, the folder's own
 * instruction, what it was handed, its tool list, its instructions, its folder…"* The pane's answer
 * is this card: the four fixed files and one row per memory file, each with the verb the app can
 * honestly offer for it.
 *
 * ## Nothing here decides what may be written
 *
 * Every one of those questions is answered twice, by somebody who is not this screen:
 * [CopilotFileRow.writable] is the machine's answer about the file, and the controller's `canEdit`
 * is the answer about this phone. This screen draws a Save when both say yes and says which one said
 * no when either does. The one thing it owns is asking twice — Restore and Forget are each behind a
 * confirm, because *"whether to ask twice is the screen's decision and it has the sentence for it."*
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CopilotFilesScreen(
    view: CopilotFilesView,
    machineLabel: String,
    onBack: () -> Unit,
    onLoad: () -> Unit,
    onOpenFile: (String) -> Unit,
) {
    val colors = DeckTheme.colors

    // Asked here as well as on the control screen, because a cold start can arrive before the
    // welcome names the capability — the guard inside the controller refuses silently then, and
    // without this the card would sit empty over a machine that had been ready for seconds.
    LaunchedEffect(Unit) { onLoad() }

    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = "Its files", subtitle = machineLabel, onBack = onBack) },
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
                if (view.files.isEmpty()) {
                    // Two different silences, and they send a person to two different places: one is
                    // a round trip in flight, the other a machine that has answered nothing.
                    Column(modifier = Modifier.padding(Space.card)) {
                        Text(
                            text = if (view.loadingFiles) "Reading…" else "Nothing has come back",
                            style = DeckType.body,
                            color = colors.primary,
                        )
                        Spacer(Modifier.height(Space.half))
                        Text(
                            text = if (view.loadingFiles) {
                                "Asking $machineLabel what its copilot reads."
                            } else {
                                "That machine has not sent its list."
                            },
                            style = DeckType.caption,
                            color = colors.faint,
                        )
                    }
                } else {
                    view.files.forEachIndexed { index, file ->
                        if (index > 0) DeckDivider(startIndent = Space.card)
                        CopilotFileRowBody(file = file, onClick = { onOpenFile(file.id) })
                    }
                }
            }
            DeckFootnote(
                "Everything the copilot reads before it answers, read off the machine's disk each " +
                    "time this opens. Two the app writes itself on every start and there is nothing " +
                    "to save over; the rest are yours — its instructions, the folder's own, and " +
                    "everything it has remembered."
            )
        }
    }
}

/** One file, as a row: what it is, whose it is, and what state it is in. */
@Composable
private fun CopilotFileRowBody(file: CopilotFileRow, onClick: () -> Unit) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = Space.card, vertical = Space.x3),
    ) {
        Icon(
            imageVector = CopilotFileText.icon(file),
            contentDescription = null,
            tint = if (file.exists) colors.secondary else colors.faint,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(Space.x3))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = file.name,
                style = DeckType.monoBody,
                color = colors.primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (file.purpose.isNotEmpty()) {
                Text(
                    text = file.purpose,
                    style = DeckType.caption,
                    color = colors.faint,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(text = CopilotFileText.facts(file), style = DeckType.caption, color = colors.faint)
        }
        Spacer(Modifier.width(Space.x2))
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.faint,
            modifier = Modifier.size(18.dp),
        )
    }
}

/**
 * One file, open.
 *
 * Addressed by **id** rather than handed a row, because a listing can arrive while somebody is
 * typing — after a save, after a restore, after the copilot writes a memory of its own — and the row
 * this screen is about has to follow that. The box is seeded once and owned by the person after
 * that; a second seeding would take back somebody's typing on the strength of a listing arriving.
 *
 * A save is confirmed by the **listing**, not by the button: the desktop reads the folder again
 * after every write and sends the whole list back, so the row's `modifiedAt` moving is the machine's
 * own confirmation and the only thing this screen will call *Saved*.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CopilotFileEditorScreen(
    view: CopilotFilesView,
    machineLabel: String,
    fileId: String,
    onBack: () -> Unit,
    onOpen: (String) -> Unit,
    onClose: () -> Unit,
    onSave: (String, String) -> Boolean,
    onRestore: () -> Boolean,
    onForget: (String) -> Boolean,
) {
    val colors = DeckTheme.colors
    val file = view.openRow

    var draft by remember(fileId) { mutableStateOf("") }
    var seeded by remember(fileId) { mutableStateOf(false) }
    var pending by remember(fileId) { mutableStateOf<Act?>(null) }
    var note by remember(fileId) { mutableStateOf<Note?>(null) }
    var confirmingRestore by remember { mutableStateOf(false) }
    var confirmingForget by remember { mutableStateOf(false) }

    // Read on appear, close on the way out. The read clears the box on the controller side, so a
    // stale file is never seen under a new title.
    DisposableEffect(fileId) {
        onOpen(fileId)
        onDispose { onClose() }
    }

    // Take the machine's answer into the box, once, when the read finishes.
    LaunchedEffect(view.loadingText, view.openText, seeded) {
        if (!view.loadingText && !seeded) {
            draft = view.openText
            seeded = true
        }
    }

    // The machine's confirmation: the folder was read again and this file's stamp moved. Nothing
    // else on this screen is allowed to say *Saved*. On the first pass pending is null, so it is
    // the write, not the arrival, that this reacts to.
    LaunchedEffect(file?.modifiedAt) {
        val act = pending ?: return@LaunchedEffect
        pending = null
        note = Note(
            text = if (act == Act.Saving) "Saved." else "The instructions this build ships are back.",
            ok = true,
        )
    }

    val canSave = view.canEdit && file?.writable == true
    val readOnlyBecause = readOnlyBecause(view, file, canSave)

    Scaffold(
        containerColor = colors.background,
        topBar = {
            DeckTopBar(
                title = file?.name ?: "File",
                subtitle = machineLabel,
                onBack = onBack,
                actions = {
                    if (canSave) {
                        val changed = draft != view.openText
                        TextButton(
                            onClick = {
                                note = null
                                pending = if (onSave(fileId, draft)) Act.Saving else null
                                if (pending == null) note = Note(view.localError ?: "That was not saved.", false)
                            },
                            enabled = pending == null && changed,
                        ) {
                            Text(
                                "Save",
                                style = DeckType.control.copy(fontWeight = FontWeight.SemiBold),
                                color = if (pending == null && changed) colors.accent else colors.faint,
                            )
                        }
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding()),
        ) {
            if (file != null && file.purpose.isNotEmpty()) {
                Text(
                    text = file.purpose,
                    style = DeckType.caption,
                    color = colors.faint,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = Space.x5, vertical = Space.x2),
                )
                DeckDivider(startIndent = Space.card)
            }

            // The box, or the same text read-only. Monospaced for the reason everything that is
            // *data* in this app is: an instruction file has indentation and fenced blocks, and a
            // proportional font hides both. A read-only file is selectable text, never a greyed box.
            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = Space.screen)
                    .padding(top = Space.x3),
            ) {
                if (canSave) {
                    DeckTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        mono = true,
                        singleLine = false,
                        minLines = 8,
                        maxLines = 200,
                        modifier = Modifier.fillMaxWidth(),
                    )
                } else {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(Radius.large)
                            .background(colors.surface)
                            .padding(horizontal = Space.x3, vertical = Space.x3),
                    ) {
                        Text(text = draft, style = DeckType.mono, color = colors.primary)
                    }
                }
            }

            // The foot: what the machine said, why there is no Save when there is none, and the one
            // or two acts this file allows. Absent entirely when there is nothing to put in it.
            EditorFoot(
                view = view,
                file = file,
                readOnlyBecause = readOnlyBecause,
                note = note,
                pending = pending,
                onRestore = { confirmingRestore = true },
                onForget = { confirmingForget = true },
            )
        }
    }

    if (confirmingRestore) {
        AlertDialog(
            onDismissRequest = { confirmingRestore = false },
            containerColor = colors.surface,
            titleContentColor = colors.primary,
            textContentColor = colors.secondary,
            title = { Text("Restore the default instructions?", style = DeckType.title) },
            text = {
                Text(
                    "What is there now is copied to a file beside it on the machine first, so " +
                        "nothing is lost. The copilot follows the new text from its next start.",
                    style = DeckType.footnote,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmingRestore = false
                    note = null
                    pending = if (onRestore()) Act.Restoring else null
                    if (pending == null) {
                        note = Note(view.localError ?: "The instructions were not restored.", false)
                    } else {
                        // Read it back, so the box holds the default rather than the words just
                        // replaced. The two frames go down one channel in order.
                        seeded = false
                        onOpen(fileId)
                    }
                }) { Text("Restore", style = DeckType.control, color = colors.critical) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingRestore = false }) {
                    Text("Keep mine", style = DeckType.control, color = colors.accent)
                }
            },
        )
    }

    if (confirmingForget) {
        AlertDialog(
            onDismissRequest = { confirmingForget = false },
            containerColor = colors.surface,
            titleContentColor = colors.primary,
            textContentColor = colors.secondary,
            title = { Text("Forget ${file?.name ?: "this memory"}?", style = DeckType.title) },
            text = {
                Text(
                    "The file is deleted on the machine. The copilot stops knowing what is in it.",
                    style = DeckType.footnote,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmingForget = false
                    val name = file?.memoryName
                    note = null
                    if (name != null && onForget(name)) {
                        // The file is gone and the listing that proves it is on its way. Standing on
                        // an editor for it would be a Save pointed at nothing.
                        onBack()
                    } else {
                        note = Note(view.localError ?: "That memory was not deleted.", false)
                    }
                }) { Text("Forget it", style = DeckType.control, color = colors.critical) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingForget = false }) {
                    Text("Keep it", style = DeckType.control, color = colors.accent)
                }
            },
        )
    }
}

private enum class Act { Saving, Restoring }
private data class Note(val text: String, val ok: Boolean)

@Composable
private fun EditorFoot(
    view: CopilotFilesView,
    file: CopilotFileRow?,
    readOnlyBecause: String?,
    note: Note?,
    pending: Act?,
    onRestore: () -> Unit,
    onForget: () -> Unit,
) {
    val colors = DeckTheme.colors
    val canAct = view.canEdit && file != null && (file.isOwnInstructions || file.isMemory)
    val hasFoot = view.openError != null || readOnlyBecause != null || note != null || pending != null || canAct
    if (!hasFoot) return

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Space.x5)
            .padding(top = Space.x3, bottom = Space.x4),
        verticalArrangement = Arrangement.spacedBy(Space.x2),
    ) {
        view.openError?.let {
            Text(it, style = DeckType.caption, color = colors.warning)
        }
        readOnlyBecause?.let {
            Text(it, style = DeckType.caption, color = colors.secondary)
        }
        note?.let {
            Text(it.text, style = DeckType.caption, color = if (it.ok) colors.positive else colors.critical)
        }
        if (pending != null) {
            Text("Working…", style = DeckType.caption, color = colors.faint)
        }
        if (canAct && file != null) {
            if (file.isOwnInstructions) {
                ActRow(icon = Icons.Filled.Refresh, title = "Restore the default", enabled = pending == null, onClick = onRestore)
            }
            if (file.isMemory) {
                ActRow(icon = Icons.Filled.Delete, title = "Forget this", enabled = pending == null, onClick = onForget)
            }
        }
    }
}

/** A destructive act on the file: an icon, a word, in the critical ink. */
@Composable
private fun ActRow(icon: ImageVector, title: String, enabled: Boolean, onClick: () -> Unit) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(vertical = Space.x2),
    ) {
        Icon(icon, contentDescription = null, tint = if (enabled) colors.critical else colors.faint, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(Space.x3))
        Text(title, style = DeckType.body, color = if (enabled) colors.critical else colors.faint)
    }
}

/**
 * Why there is no Save, when there is none — and which of the two ends said so.
 *
 * The machine's own sentence first when it sent one (a file too large comes back with an
 * explanation, better than anything composed here). Otherwise the two structural answers, kept apart
 * because they send a person to two different places: the file is one the app rewrites, or this
 * phone was not paired with the tier that changes things.
 */
private fun readOnlyBecause(view: CopilotFilesView, file: CopilotFileRow?, canSave: Boolean): String? {
    if (canSave || file == null) return null
    if (!view.canEdit) {
        return "This phone can read the copilot's files. Changing them is part of answering its " +
            "confirmations, which this phone was not given."
    }
    // A machine sentence is already on screen as the problem line; a second saying the same thing in
    // this app's words would be two paragraphs where one is the truth.
    if (view.openError != null) return null
    return if (file.owner == CopilotFileOwner.App) {
        "The app writes this one every time the copilot starts, so there is nothing to save."
    } else {
        "The machine is not offering to save this one."
    }
}

/**
 * What a row says about a file, decided once — pure, because every way these can be wrong is silent.
 * A file drawn as *yours* that the app rewrites, or a size beside a file that is not there, is a row
 * that reads perfectly and lies about somebody's copilot.
 */
object CopilotFileText {

    /**
     * The glyph, by id rather than by owner — the owner is already a word on the row, and drawing
     * the same icons over the five fixed files would make the two the app generates
     * indistinguishable, which is the pair he asked to be able to tell apart. Material icons in place
     * of iOS's SF Symbols, since those names do not apply here.
     */
    fun icon(file: CopilotFileRow): ImageVector {
        if (file.isMemory) return Icons.Filled.AutoAwesome
        return when (file.id) {
            "yours" -> Icons.Filled.TextFields
            "contract" -> Icons.Filled.Tune
            "composed" -> Icons.AutoMirrored.Filled.InsertDriveFile
            "folder" -> Icons.Filled.Folder
            else -> Icons.Filled.Folder
        }
    }

    /** Whose file it is, in the words the badge on the Mac's row uses. Never derived from the id —
     *  the desktop decides ownership and sends it. */
    fun owner(owner: CopilotFileOwner): String = when (owner) {
        CopilotFileOwner.Yours -> "yours"
        CopilotFileOwner.App -> "the app's"
        CopilotFileOwner.Folder -> "in the folder"
        // A word a newer host grows folds here rather than off the screen — see [CopilotFileOwner].
        CopilotFileOwner.Unknown -> "on the machine"
    }

    /**
     * The third line: whose it is, how big, how long ago. `exists: false` ends the line, and that is
     * the case worth the care — the folder's own `CLAUDE.md` is normally exactly that, and its
     * absence is the most reassuring row on the screen. A size beside it would contradict it.
     */
    fun facts(file: CopilotFileRow, now: Long = System.currentTimeMillis()): String {
        val parts = mutableListOf(owner(file.owner))
        if (!file.exists) {
            parts.add("not there")
            return parts.joinToString(" · ")
        }
        file.size?.let { parts.add(byteSize(it)) }
        deckActivityLine(file.modifiedAt, now)?.let { parts.add(it) }
        return parts.joinToString(" · ")
    }
}

/**
 * How long ago, said the way a person says it — the sibling of iOS's `SessionDetails.activityLine`.
 *
 * Null for a moment that is absent or in 1970. A machine whose clock is ahead of this phone's
 * produces a negative interval, and *"-3m ago"* is worse than the vaguest true answer, so it folds
 * to *just now*. Shared by the files' facts line and the routines' history line, so the two cannot
 * come to phrase the same interval two ways.
 */
internal fun deckActivityLine(epochMs: Long?, now: Long = System.currentTimeMillis()): String? {
    if (epochMs == null || epochMs <= 0) return null
    val seconds = (now - epochMs) / 1000
    if (seconds < 0) return "just now"
    return when {
        seconds < 60 -> "just now"
        seconds < 3600 -> "${seconds / 60}m ago"
        seconds < 86_400 -> "${seconds / 3600}h ago"
        else -> "${seconds / 86_400}d ago"
    }
}
