package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.AccountTree
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import dev.terminaldeck.android.DeckUiState
import dev.terminaldeck.android.FilesGitController
import dev.terminaldeck.android.PanelsController
import dev.terminaldeck.android.protocol.GitFileChange
import dev.terminaldeck.android.protocol.PanelKind
import dev.terminaldeck.android.tunnel.TunnelView
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.kit.InfoDot
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * The "look inside" doors into a machine — a port of `ios/TerminalDeck/Screens/MachineToolsSection.swift`.
 *
 * The six rows the desktop has always had and the phone did not — **Files, Source control, Artifacts,
 * Store, AI readiness, MCP servers** — in the order he asked for them. `files`, `git` and `panels` are
 * all owner-device only on the host, so a phone that is not the owner's gets a shorter list, and a row
 * is **not drawn** rather than drawn and refused: a button whose only outcome is a refusal is not a
 * button. Everything behind these six is read-only.
 *
 * ## A section that is also its own nav hub
 *
 * On iOS these are `NavigationLink`s onto the app's own stack. Here the machine screen this drops into
 * must not be edited, so the section owns navigation itself: tapping a row pushes onto an internal
 * stack, and the pushed screen is drawn full-screen in a [Popup] above everything — Files opening the
 * file viewer, Source control opening a diff, the artifacts panel opening [ArtifactView], and the
 * artifact opening back into Files. The system back gesture pops that stack while it is non-empty and
 * leaves the machine screen only once it is empty.
 *
 * @param state the selected machine's ui state — the three capability gates, [DeckUiState.machineNoun],
 *   [DeckUiState.startableFolders], the tunnel and whether ports may be served here.
 * @param files the selected machine's files/git controller (`DeckViewModel.filesGit()`), or null.
 * @param panels the selected machine's panels controller (`DeckViewModel.panels()`), or null.
 */
@Composable
fun MachineToolsSection(
    state: DeckUiState,
    files: FilesGitController?,
    panels: PanelsController?,
    onServePort: (Int) -> Unit,
    onCloseServedPort: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (!state.canReadFiles && !state.canReadGit && !state.canReadPanels) return

    val colors = DeckTheme.colors
    val stack = remember { mutableStateListOf<ToolRoute>() }
    val start = state.startableFolders.firstOrNull().orEmpty()

    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(start = Space.x1, top = Space.x6, bottom = Space.x2),
        ) {
            Text("LOOK INSIDE", style = DeckType.overline, color = colors.faint)
            InfoDot(
                about = "Look inside",
                text = "Everything here is read-only. These six read the machine — its folders, what git says, " +
                    "and its four panels — and none of them change anything on it.",
            )
        }
        DeckGroup {
            var drawnAny = false
            if (state.canReadFiles) {
                ToolRow("Files", Icons.Filled.Folder) { stack.add(ToolRoute.Files(start)) }
                drawnAny = true
            }
            if (state.canReadGit) {
                if (drawnAny) DeckDivider(startIndent = 52.dp)
                ToolRow("Source control", Icons.Filled.AccountTree) { stack.add(ToolRoute.Source) }
                drawnAny = true
            }
            if (state.canReadPanels) {
                if (drawnAny) DeckDivider(startIndent = 52.dp)
                ToolRow("Artifacts", Icons.Filled.Inventory2) { stack.add(ToolRoute.Panel(PanelKind.Artifacts, "Artifacts")) }
                DeckDivider(startIndent = 52.dp)
                ToolRow("Store", Icons.Filled.GridView) { stack.add(ToolRoute.Panel(PanelKind.Store, "Store")) }
                DeckDivider(startIndent = 52.dp)
                ToolRow("AI readiness", Icons.Filled.Verified) { stack.add(ToolRoute.Panel(PanelKind.Readiness, "AI readiness")) }
                DeckDivider(startIndent = 52.dp)
                ToolRow("MCP servers", Icons.Filled.Hub) { stack.add(ToolRoute.Panel(PanelKind.Mcp, "MCP servers")) }
            }
        }
    }

    if (stack.isNotEmpty()) {
        Popup(properties = PopupProperties(focusable = true)) {
            Box(modifier = Modifier.fillMaxSize().background(colors.background)) {
                val pop: () -> Unit = { if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
                when (val route = stack.last()) {
                    is ToolRoute.Files ->
                        if (files != null) FilesScreen(files, route.start, onOpenFile = { p, s -> stack.add(ToolRoute.FileText(p, s)) }, onBack = pop)
                        else Disconnected(pop)

                    is ToolRoute.FileText ->
                        if (files != null) FileTextScreen(files, route.path, route.size, onBack = pop) else Disconnected(pop)

                    ToolRoute.Source ->
                        if (files != null) SourceControlScreen(files, start, onOpenDiff = { change, staged -> stack.add(ToolRoute.Diff(start, change, staged)) }, onBack = pop)
                        else Disconnected(pop)

                    is ToolRoute.Diff ->
                        if (files != null) DiffScreen(files, route.repoPath, route.change, route.staged, onBack = pop) else Disconnected(pop)

                    is ToolRoute.Panel ->
                        if (panels != null) PanelScreen(
                            controller = panels,
                            panel = route.kind,
                            title = route.title,
                            path = state.startableFolders.firstOrNull(),
                            canReadPanels = state.canReadPanels,
                            onOpenArtifact = { ref, title, project -> stack.add(ToolRoute.Artifact(ref, title, project)) },
                            onBack = pop,
                        ) else Disconnected(pop)

                    is ToolRoute.Artifact ->
                        if (files != null && panels != null) ArtifactView(
                            ref = route.ref,
                            title = route.title,
                            project = route.project,
                            files = files,
                            panels = panels,
                            machineNoun = state.machineNoun,
                            canReadFiles = state.canReadFiles,
                            canReadPanels = state.canReadPanels,
                            canBrowseLocalhost = state.localhostOffered,
                            tunnel = state.tunnel,
                            onServePort = onServePort,
                            onCloseServedPort = onCloseServedPort,
                            onOpenFolder = { folder -> stack.add(ToolRoute.Files(folder)) },
                            onBack = pop,
                        ) else Disconnected(pop)
                }
            }
        }
    }
}

/** Where the six doors lead. Internal to the section, which is the only thing that pushes them. */
private sealed interface ToolRoute {
    data class Files(val start: String) : ToolRoute
    data class FileText(val path: String, val size: Long?) : ToolRoute
    object Source : ToolRoute
    data class Diff(val repoPath: String, val change: GitFileChange, val staged: Boolean) : ToolRoute
    data class Panel(val kind: PanelKind, val title: String) : ToolRoute
    data class Artifact(val ref: ArtifactRef, val title: String, val project: String?) : ToolRoute
}

@Composable
private fun ToolRow(title: String, icon: ImageVector, onClick: () -> Unit) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = Space.x4, vertical = Space.x3),
    ) {
        Icon(icon, contentDescription = null, tint = colors.secondary, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(Space.x3))
        Text(title, style = DeckType.body, color = colors.primary, modifier = Modifier.weight(1f))
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = colors.faint, modifier = Modifier.size(18.dp))
    }
}

/** A pushed screen whose machine went away underneath it — a re-pair or a disconnect mid-navigation. */
@Composable
private fun Disconnected(onBack: () -> Unit) {
    val colors = DeckTheme.colors
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxSize().padding(Space.x8),
    ) {
        Spacer(Modifier.size(Space.x16))
        Text("Not connected to this machine any more.", style = DeckType.body, color = colors.secondary)
        Spacer(Modifier.size(Space.x5))
        DeckQuietButton(label = "Back", onClick = onBack, modifier = Modifier.width(200.dp))
    }
}
