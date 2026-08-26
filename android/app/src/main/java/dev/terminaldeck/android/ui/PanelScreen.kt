package dev.terminaldeck.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.PanelsController
import dev.terminaldeck.android.protocol.PanelAction
import dev.terminaldeck.android.protocol.PanelData
import dev.terminaldeck.android.protocol.PanelKind
import dev.terminaldeck.android.protocol.PanelRow
import dev.terminaldeck.android.protocol.PanelScope
import dev.terminaldeck.android.protocol.PanelStatus
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckTextField
import dev.terminaldeck.android.ui.kit.InfoDot
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space
import kotlinx.coroutines.delay

/**
 * The shared shell all four panels render from — a port of `ios/TerminalDeck/Screens/PanelView.swift`.
 *
 * `panel.rows` carries rows, filters and buttons in one answer, so the panel id and the title come in
 * as parameters and **everything else is declared by the machine**: which filters exist, what the
 * buttons say, what each asks for before it fires, and which are dangerous. An act answers with the
 * same payload a read would have, so this never re-reads after acting — the rows arriving are the
 * confirmation. `note` is an answer (nothing configured), not a failure; the row that navigates is the
 * artifacts row, and only when its id parses into an [ArtifactRef].
 */
private val SEARCHING = setOf(PanelKind.Artifacts, PanelKind.Store, PanelKind.Mcp)
private const val DETAIL_CHARACTERS = 150

private class PanelTarget(val action: PanelAction, val rowId: String?, val subject: String?)

@Composable
fun PanelScreen(
    controller: PanelsController,
    panel: PanelKind,
    title: String,
    path: String?,
    canReadPanels: Boolean,
    onOpenArtifact: (ref: ArtifactRef, title: String, project: String?) -> Unit,
    onBack: () -> Unit,
) {
    val colors = DeckTheme.colors
    val data = controller.data(panel)

    var scope by remember(panel) { mutableStateOf<String?>(null) }
    var query by remember(panel) { mutableStateOf("") }
    // The filters and the panel's own buttons, kept across a read so the control just pressed does not
    // vanish under a thumb for the length of a round trip.
    var pills by remember(panel) { mutableStateOf<List<PanelScope>>(emptyList()) }
    var offered by remember(panel) { mutableStateOf<List<PanelAction>>(emptyList()) }
    var forming by remember(panel) { mutableStateOf<PanelTarget?>(null) }
    var confirming by remember(panel) { mutableStateOf<PanelTarget?>(null) }
    // The action in flight. Held here because this wire has no correlation id and needs none: an act
    // answers with the whole panel, so *the panel changed* is the completion.
    var working by remember(panel) { mutableStateOf<String?>(null) }

    fun read() {
        controller.read(panel, path = path, scope = scope, query = query.ifEmpty { null })
    }

    fun send(target: PanelTarget, fields: Map<String, String>) {
        working = target.action.id
        controller.act(panel, target.action.id, path = path, id = target.rowId, fields = fields)
    }

    fun raise(action: PanelAction, row: PanelRow?) {
        val target = PanelTarget(action, row?.id, row?.title)
        when {
            action.fields.isNotEmpty() -> forming = target
            action.destructive -> confirming = target
            else -> send(target, emptyMap())
        }
    }

    LaunchedEffect(panel) { read() }
    // The debounce: every keystroke restarts the wait, so a word typed at speed costs one read.
    LaunchedEffect(query) {
        if (query.isEmpty()) return@LaunchedEffect
        delay(350)
        read()
    }
    // The answer landed: take the chrome and the chosen scope, and clear the in-flight marker. The
    // rows themselves are read straight off the controller.
    LaunchedEffect(data) {
        working = null
        if (data == null) return@LaunchedEffect
        pills = data.scopes
        offered = data.actions
        data.scopes.firstOrNull { it.on }?.let { scope = it.id }
    }
    // A 30-second backstop for an act whose answer is identical to what was already on screen, where
    // nothing else would clear the spinner.
    LaunchedEffect(working) {
        if (working == null) return@LaunchedEffect
        delay(30_000)
        working = null
    }

    BackHandler(onBack = onBack)

    Scaffold(
        containerColor = colors.background,
        topBar = {
            DeckTopBar(
                title = title,
                onBack = onBack,
                actions = {
                    if (canReadPanels && offered.isNotEmpty()) PanelActions(offered, working != null) { raise(it, null) }
                    if (working != null) {
                        CircularProgressIndicator(color = colors.accent, modifier = Modifier.size(22.dp).padding(end = Space.x2))
                    } else {
                        IconButton(onClick = { read() }) {
                            Icon(Icons.Filled.Refresh, contentDescription = "Refresh", tint = colors.primary)
                        }
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = Space.x4).padding(top = Space.x3, bottom = Space.x8),
        ) {
            if (!path.isNullOrEmpty()) {
                Text(
                    text = path, style = DeckType.mono, color = colors.faint, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(start = Space.x1, bottom = Space.x3),
                )
            }
            if (panel in SEARCHING) {
                DeckTextField(value = query, onValueChange = { query = it }, placeholder = "Search", modifier = Modifier.padding(bottom = Space.x3))
            }
            if (pills.isNotEmpty()) {
                Row(modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(bottom = Space.x3)) {
                    pills.forEach { pill ->
                        val chosen = pill.id == (scope ?: pills.firstOrNull { it.on }?.id)
                        ScopePill(pill.label, chosen, enabled = !chosen && working == null) { scope = pill.id; read() }
                        Spacer(Modifier.width(Space.x2))
                    }
                }
            }
            if (!data?.notice.isNullOrEmpty()) {
                Text(
                    text = data!!.notice!!,
                    style = DeckType.footnote,
                    color = colors.primary,
                    modifier = Modifier.fillMaxWidth().padding(bottom = Space.x3)
                        .then(Modifier),
                )
            }

            when {
                data == null -> Waiting()
                data.rows.isEmpty() -> DeckGroup { NoteRow(data.note ?: "This machine has nothing to show here.") }
                else -> {
                    DeckGroup {
                        data.rows.forEachIndexed { index, row ->
                            if (index > 0) DeckDivider(startIndent = Space.x4)
                            PanelRowView(
                                row = row,
                                panel = panel,
                                canReadPanels = canReadPanels,
                                working = working != null,
                                project = data.path.ifEmpty { path },
                                onRaise = { action -> raise(action, row) },
                                onOpenArtifact = onOpenArtifact,
                            )
                        }
                    }
                    if (!data.note.isNullOrEmpty()) {
                        Text(data.note!!, style = DeckType.caption, color = colors.faint, modifier = Modifier.padding(start = Space.x1, top = Space.x2))
                    }
                }
            }
        }
    }

    confirming?.let { target ->
        AlertDialog(
            onDismissRequest = { confirming = null },
            containerColor = colors.surface,
            title = { Text("${target.action.label}?", style = DeckType.rowTitle, color = colors.primary) },
            text = { target.action.confirm?.takeIf { it.isNotEmpty() }?.let { Text(it, style = DeckType.footnote, color = colors.secondary) } },
            confirmButton = { TextButton(onClick = { confirming = null; send(target, emptyMap()) }) { Text(target.action.label, style = DeckType.control, color = colors.critical) } },
            dismissButton = { TextButton(onClick = { confirming = null }) { Text("Keep", style = DeckType.control, color = colors.secondary) } },
        )
    }

    // A form over everything, when an action needs one. Full-screen, matching the iOS sheet.
    forming?.let { target ->
        Box(modifier = Modifier.fillMaxSize()) {
            PanelActionForm(
                title = target.subject ?: title,
                action = target.action,
                onCancel = { forming = null },
                onSubmit = { fields -> send(target, fields); forming = null },
            )
        }
    }
}

@Composable
private fun PanelActions(offered: List<PanelAction>, working: Boolean, onRaise: (PanelAction) -> Unit) {
    val colors = DeckTheme.colors
    if (offered.size == 1) {
        val only = offered.first()
        TextButton(onClick = { onRaise(only) }, enabled = !working) {
            Text(only.label, style = DeckType.control, color = if (only.destructive) colors.warning else colors.accent)
        }
    } else {
        var menu by remember { mutableStateOf(false) }
        IconButton(onClick = { menu = true }, enabled = !working) {
            Icon(Icons.Filled.MoreVert, contentDescription = "What this panel can do", tint = colors.primary)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            offered.forEach { action ->
                DropdownMenuItem(
                    text = { Text(action.label, color = if (action.destructive) colors.critical else colors.primary) },
                    onClick = { menu = false; onRaise(action) },
                )
            }
        }
    }
}

@Composable
private fun ScopePill(label: String, chosen: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = DeckTheme.colors
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .background(colors.surface, Radius.sheetShape)
            .padding(horizontal = Space.x4, vertical = Space.x15),
    ) {
        Text(
            text = label,
            style = DeckType.footnote.copy(fontWeight = if (chosen) androidx.compose.ui.text.font.FontWeight.SemiBold else androidx.compose.ui.text.font.FontWeight.Normal),
            color = if (chosen) colors.primary else colors.secondary,
            maxLines = 1,
        )
    }
}

@Composable
private fun PanelRowView(
    row: PanelRow,
    panel: PanelKind,
    canReadPanels: Boolean,
    working: Boolean,
    project: String?,
    onRaise: (PanelAction) -> Unit,
    onOpenArtifact: (ArtifactRef, String, String?) -> Unit,
) {
    val colors = DeckTheme.colors
    // The one panel where a row navigates: an artifacts row is a file, and opening it is the point. The
    // second half keeps the rule honest — the id must parse, or a host older than this build draws a
    // list, not a chevron onto a screen with nothing on it.
    val artifact = if (panel == PanelKind.Artifacts) ArtifactRef.parse(row.id) else null

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .then(if (artifact != null) Modifier.clickable { onOpenArtifact(artifact, row.title, project) } else Modifier)
            .padding(horizontal = Space.x4, vertical = Space.x3),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(row.title, style = DeckType.body, color = colors.primary)
            val detail = row.detail
            if (!detail.isNullOrEmpty()) {
                Row(verticalAlignment = Alignment.Top) {
                    Text(detail, style = DeckType.footnote, color = colors.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    if (detail.length > DETAIL_CHARACTERS) InfoDot(about = row.title, text = detail)
                }
            }
        }
        Spacer(Modifier.width(Space.x2))
        Trailing(row)
        if (canReadPanels) RowActions(row, working, onRaise)
        if (artifact != null) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = colors.faint, modifier = Modifier.size(18.dp))
        }
    }
}

/** A value takes the tint; a status with no value becomes a dot in the same colour rather than nothing. */
@Composable
private fun Trailing(row: PanelRow) {
    val colors = DeckTheme.colors
    val value = row.value
    when {
        !value.isNullOrEmpty() -> Text(value, style = DeckType.value, color = tint(row.status, colors), maxLines = 2)
        row.status != null -> Box(modifier = Modifier.size(8.dp).background(tint(row.status, colors), androidx.compose.foundation.shape.CircleShape))
    }
}

@Composable
private fun RowActions(row: PanelRow, working: Boolean, onRaise: (PanelAction) -> Unit) {
    val colors = DeckTheme.colors
    when {
        row.actions.size == 1 -> {
            val only = row.actions.first()
            TextButton(onClick = { onRaise(only) }, enabled = !working) {
                Text(only.label, style = DeckType.value.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Medium), color = if (only.destructive) colors.warning else colors.accent, maxLines = 1)
            }
        }
        row.actions.size > 1 -> {
            var menu by remember { mutableStateOf(false) }
            IconButton(onClick = { menu = true }, enabled = !working, modifier = Modifier.size(32.dp)) {
                Icon(Icons.Filled.MoreVert, contentDescription = "What can be done to ${row.title}", tint = colors.secondary, modifier = Modifier.size(20.dp))
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                row.actions.forEach { action ->
                    DropdownMenuItem(
                        text = { Text(action.label, color = if (action.destructive) colors.critical else colors.primary) },
                        onClick = { menu = false; onRaise(action) },
                    )
                }
            }
        }
    }
}

private fun tint(status: PanelStatus?, colors: dev.terminaldeck.android.ui.theme.DeckColors): Color = when (status) {
    PanelStatus.Ok -> colors.positive
    PanelStatus.Warn -> colors.warning
    PanelStatus.Bad -> colors.critical
    null -> colors.faint
}

@Composable
private fun Waiting() {
    val colors = DeckTheme.colors
    DeckGroup {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(Space.x4)) {
            CircularProgressIndicator(color = colors.accent, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(Space.x3))
            Text("Asking the machine…", style = DeckType.value, color = colors.secondary)
        }
    }
}

@Composable
private fun NoteRow(text: String) {
    Text(text = text, style = DeckType.value, color = DeckTheme.colors.secondary, modifier = Modifier.fillMaxWidth().padding(Space.x4))
}
