package dev.terminaldeck.android.ui

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.DriveFileRenameOutline
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.FolderOff
import androidx.compose.material.icons.filled.QuestionMark
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.FilesGitController
import dev.terminaldeck.android.protocol.GitBranchState
import dev.terminaldeck.android.protocol.GitChangeKind
import dev.terminaldeck.android.protocol.GitFileChange
import dev.terminaldeck.android.protocol.GitNotRepo
import dev.terminaldeck.android.protocol.GitRepoStatus
import dev.terminaldeck.android.protocol.GitState
import dev.terminaldeck.android.protocol.GitUnavailable
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.InfoDot
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * What git says about a folder on the machine — a port of `ios/TerminalDeck/Screens/SourceControlView.swift`.
 *
 * Draws exactly what the host answers and nothing else: the branch and where it stands against its
 * upstream, then the four lists git itself keeps — staged, unstaged, untracked, conflicted — each row
 * carrying the change git named it with. Nothing here writes: no stage, no discard, no commit, and no
 * Init either — the wire carries no such verb, so `canInit` is read only to say the true sentence. A
 * folder with no repository is an answer, not a failure, and gets its own quiet card.
 */
@Composable
fun SourceControlScreen(
    controller: FilesGitController,
    path: String,
    onOpenDiff: (change: GitFileChange, staged: Boolean) -> Unit,
    onBack: () -> Unit,
) {
    val colors = DeckTheme.colors
    val state = controller.gitState

    // Keyed on path, so a screen shown for a second folder asks again instead of showing the first.
    LaunchedEffect(path) { controller.gitStatus(path) }

    BackHandler(onBack = onBack)

    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = "Source control", onBack = onBack) },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when (state) {
                is GitState.Repo -> RepoBody(state.status, onOpenDiff)
                is GitState.NotRepo -> Column(
                    modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                        .padding(horizontal = Space.x4, vertical = Space.x3),
                ) { NoRepo(state.status) }
                null -> CircularProgressIndicator(color = colors.accent, modifier = Modifier.align(Alignment.Center))
            }
        }
    }
}

@Composable
private fun RepoBody(repo: GitRepoStatus, onOpenDiff: (GitFileChange, Boolean) -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())
            .padding(horizontal = Space.x4).padding(top = Space.x3, bottom = Space.x8),
    ) {
        BranchCard(repo)
        if (repo.clean) {
            Clean()
        } else {
            Group("Conflicted", repo.conflicted, staged = false, onOpenDiff)
            Group("Staged", repo.staged, staged = true, onOpenDiff)
            Group("Unstaged", repo.unstaged, staged = false, onOpenDiff)
            Group("Untracked", repo.untracked, staged = false, onOpenDiff)
        }
    }
}

@Composable
private fun BranchCard(repo: GitRepoStatus) {
    Caption(
        "Branch",
        about = "the branch",
        info = "Ahead is commits you have that the upstream does not; behind is commits it has that you " +
            "do not. Both are counted against the upstream branch git is tracking, and neither appears " +
            "when there is no upstream to count against.",
    )
    DeckGroup {
        Plain("On", branchTitle(repo.branch))
        DeckDivider(startIndent = Space.x4)
        Plain("Commit", repo.branch.oid?.take(7) ?: "No commits yet")
        if (repo.branch.upstream != null) {
            DeckDivider(startIndent = Space.x4)
            Plain("Upstream", repo.branch.upstream!!)
            DeckDivider(startIndent = Space.x4)
            Standing(repo.branch)
        }
        if (repo.root != repo.cwd) {
            DeckDivider(startIndent = Space.x4)
            Plain("Repository", repo.root)
        }
    }
}

private fun branchTitle(branch: GitBranchState): String {
    val name = branch.name
    if (!name.isNullOrEmpty()) return name
    return if (branch.detached) "Detached HEAD" else "Unborn branch"
}

@Composable
private fun Standing(branch: GitBranchState) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x4, vertical = Space.x3),
    ) {
        Text("Standing", style = DeckType.body, color = colors.primary, modifier = Modifier.weight(1f))
        when {
            branch.ahead == 0 && branch.behind == 0 ->
                Text("Up to date", style = DeckType.value, color = colors.faint)
            else -> Row {
                if (branch.ahead > 0) Text("${branch.ahead} ahead", style = DeckType.value, color = colors.positive)
                if (branch.ahead > 0 && branch.behind > 0) Spacer(Modifier.width(Space.x2))
                if (branch.behind > 0) Text("${branch.behind} behind", style = DeckType.value, color = colors.warning)
            }
        }
    }
}

/** One of git's four lists, drawn only when it has something in it — an empty heading over an empty
 *  card on every clean-ish repository would be four captions of furniture. */
@Composable
private fun Group(title: String, files: List<GitFileChange>, staged: Boolean, onOpenDiff: (GitFileChange, Boolean) -> Unit) {
    if (files.isEmpty()) return
    Caption("$title · ${files.size}")
    DeckGroup {
        files.forEachIndexed { index, file ->
            if (index > 0) DeckDivider(startIndent = Space.x4)
            FileRow(file, staged) { onOpenDiff(file, staged) }
        }
    }
}

@Composable
private fun FileRow(file: GitFileChange, staged: Boolean, onClick: () -> Unit) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = Space.x4, vertical = Space.x3),
    ) {
        Icon(
            imageVector = kindIcon(file.kind),
            contentDescription = null,
            tint = kindTint(file.kind, colors),
            modifier = Modifier.size(24.dp),
        )
        Spacer(Modifier.width(Space.x3))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = file.name.ifEmpty { file.path },
                style = DeckType.body,
                color = colors.primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(text = subtitle(file), style = DeckType.footnote, color = colors.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(Space.x2))
        Stat(file)
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.faint,
            modifier = Modifier.size(18.dp),
        )
    }
}

/** The second line: what git called the change and where the file is. A rename says where it came
 *  from instead — the fact the path alone cannot carry. */
private fun subtitle(file: GitFileChange): String {
    val kind = file.kind.name.replaceFirstChar { it.uppercase() }
    val origin = file.origPath
    if (!origin.isNullOrEmpty()) {
        val similarity = file.score?.let { " · $it%" } ?: ""
        return "$kind from $origin$similarity"
    }
    val folder = file.path.substringBeforeLast('/', "")
    return if (folder.isEmpty()) kind else "$kind · $folder"
}

/** `+n −n`, or Binary, or nothing at all — nothing at all is the honest answer for an untracked file,
 *  whose insertions and deletions stay null. */
@Composable
private fun Stat(file: GitFileChange) {
    val colors = DeckTheme.colors
    when {
        file.binary -> Text("Binary", style = DeckType.caption, color = colors.faint)
        file.insertions != null || file.deletions != null -> Row {
            val added = file.insertions ?: 0
            val removed = file.deletions ?: 0
            if (added > 0) Text("+$added", style = DeckType.mono, color = colors.positive)
            if (added > 0 && removed > 0) Spacer(Modifier.width(Space.x15))
            if (removed > 0) Text("−$removed", style = DeckType.mono, color = colors.critical)
        }
    }
    Spacer(Modifier.width(Space.x2))
}

private fun kindIcon(kind: GitChangeKind): ImageVector = when (kind) {
    GitChangeKind.Added -> Icons.Filled.Add
    GitChangeKind.Modified -> Icons.Filled.Edit
    GitChangeKind.Deleted -> Icons.Filled.Remove
    GitChangeKind.Renamed -> Icons.Filled.DriveFileRenameOutline
    GitChangeKind.Copied -> Icons.Filled.ContentCopy
    GitChangeKind.Typechange -> Icons.Filled.SwapHoriz
    GitChangeKind.Untracked -> Icons.Filled.QuestionMark
    GitChangeKind.Conflicted -> Icons.Filled.Warning
    GitChangeKind.Unknown -> Icons.Outlined.Circle
}

private fun kindTint(kind: GitChangeKind, colors: dev.terminaldeck.android.ui.theme.DeckColors): Color = when (kind) {
    GitChangeKind.Added -> colors.positive
    GitChangeKind.Deleted -> colors.critical
    GitChangeKind.Conflicted -> colors.critical
    GitChangeKind.Untracked -> colors.warning
    else -> colors.secondary
}

@Composable
private fun Clean() {
    val colors = DeckTheme.colors
    Caption("Changes")
    DeckGroup {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x4, vertical = Space.x3),
        ) {
            Icon(Icons.Filled.Check, contentDescription = null, tint = colors.positive, modifier = Modifier.size(24.dp))
            Spacer(Modifier.width(Space.x3))
            Text("Nothing has changed.", style = DeckType.body, color = colors.primary)
        }
    }
}

/** The folder has no readable repository, and this says which of the four reasons it was. `message` is
 *  always printed here, unlike on the desktop, because this screen has no button carrying git's words. */
@Composable
private fun NoRepo(missing: GitNotRepo) {
    val colors = DeckTheme.colors
    Caption("Source control")
    DeckGroup {
        Column(modifier = Modifier.padding(horizontal = Space.x4, vertical = Space.x4)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(reasonGlyph(missing.reason), contentDescription = null, tint = colors.secondary, modifier = Modifier.size(24.dp))
                Spacer(Modifier.width(Space.x3))
                Text(headline(missing), style = DeckType.body, color = colors.primary)
            }
            if (missing.message.isNotEmpty()) {
                Spacer(Modifier.padding(top = Space.x2))
                Text(
                    text = missing.message,
                    style = DeckType.footnote,
                    color = colors.secondary,
                    modifier = Modifier.padding(start = 36.dp),
                )
            }
        }
    }
}

private fun headline(missing: GitNotRepo): String = when (missing.reason) {
    GitUnavailable.NotARepo ->
        if (missing.canInit) "There is no git repository in this folder." else "git will not read the repository here."
    GitUnavailable.GitMissing -> "git is not installed on this machine."
    GitUnavailable.NoSuchFolder -> "That folder is not on this machine any more."
    GitUnavailable.Error -> "git could not read this folder."
}

private fun reasonGlyph(reason: GitUnavailable): ImageVector = when (reason) {
    GitUnavailable.NotARepo -> Icons.Filled.Folder
    GitUnavailable.GitMissing -> Icons.Filled.Build
    GitUnavailable.NoSuchFolder -> Icons.Filled.FolderOff
    GitUnavailable.Error -> Icons.Filled.Warning
}

@Composable
private fun Plain(title: String, value: String) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x4, vertical = Space.x3),
    ) {
        Text(title, style = DeckType.body, color = colors.primary, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(Space.x2))
        Text(value, style = DeckType.value, color = colors.faint, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun Caption(text: String, about: String? = null, info: String? = null) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(start = Space.x1, top = Space.x6, bottom = Space.x2),
    ) {
        Text(text = text.uppercase(), style = DeckType.overline, color = colors.faint)
        if (about != null && info != null) InfoDot(about = about, text = info)
    }
}
