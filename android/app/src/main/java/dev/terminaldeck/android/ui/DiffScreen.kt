package dev.terminaldeck.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.FilesGitController
import dev.terminaldeck.android.protocol.GitChangeKind
import dev.terminaldeck.android.protocol.GitFileChange
import dev.terminaldeck.android.protocol.GitFileGroup
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * One file's diff, exactly as git printed it — a port of `ios/TerminalDeck/Screens/DiffView.swift`.
 *
 * The screen's whole job is to render the unified patch without becoming a second opinion about it: no
 * side-by-side reconstruction, no re-wrapping, no word-level highlighting. A diff is column-significant,
 * so the text is laid out at its true width in a monospaced face and the screen scrolls both ways —
 * which is also why every line is drawn at the **same** width: a tint that stopped at the end of each
 * line's own text would turn a horizontal scroll into a ragged green-and-red coastline. Read-only,
 * like everything behind `git`: status and a diff, never a commit.
 */
@Composable
fun DiffScreen(
    controller: FilesGitController,
    repoPath: String,
    change: GitFileChange,
    staged: Boolean,
    onBack: () -> Unit,
) {
    val colors = DeckTheme.colors

    // All four fields are checked, not just the name: the staged and unstaged patches for one file are
    // two different answers and only one of them belongs on screen.
    val latest = controller.gitPatch
    val patch: String? = if (latest != null && latest.path == repoPath && latest.file == change.path && latest.staged == staged) {
        latest.patch
    } else {
        null
    }

    LaunchedEffect(change.path, staged) { controller.gitDiff(repoPath, change.path, staged) }

    BackHandler(onBack = onBack)

    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = change.name.ifEmpty { change.path }, onBack = onBack) },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                patch == null -> CircularProgressIndicator(color = colors.accent, modifier = Modifier.align(Alignment.Center))
                patch.isEmpty() -> EmptyPatch(change = change, staged = staged)
                else -> PatchBody(patch = patch, staged = staged)
            }
        }
    }
}

@Composable
private fun PatchBody(patch: String, staged: Boolean) {
    val colors = DeckTheme.colors
    val doc = remember(patch) { DiffDoc.parse(patch) }

    // One measurement of one monospace character, multiplied — correct because the face is monospaced,
    // which is exactly what lets the tints line up without walking every line. Matches DiffView's own
    // `measure(columns:)`.
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val rowWidth = remember(doc, density) {
        val advancePx = measurer.measure(AnnotatedString("0"), style = DeckType.mono).size.width
        with(density) { (advancePx * doc.columns).toDp() + Space.x6 }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        // What the patch adds up to, counted from the patch itself rather than from the status row.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x5, vertical = Space.x3),
        ) {
            Text(
                text = (if (staged) "Staged" else "Working tree").uppercase(),
                style = DeckType.overline,
                color = colors.faint,
                modifier = Modifier.weight(1f),
            )
            if (doc.added > 0) {
                Text("+${doc.added}", style = DeckType.monoFootnote, color = colors.positive)
                Spacer(Modifier.width(Space.x2))
            }
            if (doc.removed > 0) {
                Text("−${doc.removed}", style = DeckType.monoFootnote, color = colors.critical)
            }
        }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = Space.x4)
                .padding(bottom = Space.x3)
                .clip(dev.terminaldeck.android.ui.theme.Radius.groupShape)
                .background(colors.surface)
                .verticalScroll(rememberScrollState()),
        ) {
            Column(modifier = Modifier.horizontalScroll(rememberScrollState()).padding(vertical = Space.x2)) {
                doc.lines.forEach { line ->
                    Text(
                        text = line.text.ifEmpty { " " },
                        style = DeckType.mono,
                        color = ink(line.kind, colors),
                        maxLines = 1,
                        softWrap = false,
                        modifier = Modifier
                            .width(rowWidth)
                            .background(wash(line.kind, colors))
                            .padding(horizontal = Space.x3, vertical = 1.dp),
                    )
                }
                if (doc.truncated) {
                    Text(
                        text = "This patch is longer than ${DiffDoc.MAX_LINES} lines and is shown to there.",
                        style = DeckType.caption,
                        color = colors.faint,
                        modifier = Modifier.padding(horizontal = Space.x3, vertical = Space.x3),
                    )
                }
            }
        }
    }
}

private fun ink(kind: DiffDoc.Kind, colors: dev.terminaldeck.android.ui.theme.DeckColors): Color = when (kind) {
    DiffDoc.Kind.Added -> colors.positive
    DiffDoc.Kind.Removed -> colors.critical
    DiffDoc.Kind.Hunk -> colors.faint
    DiffDoc.Kind.Meta -> colors.faint
    DiffDoc.Kind.Context -> colors.primary
}

/** A wash under the changed lines at a tenth strength — the palette carries no green or red surface,
 *  so this is the ink's own colour at a strength that stays under the text in both appearances. */
private fun wash(kind: DiffDoc.Kind, colors: dev.terminaldeck.android.ui.theme.DeckColors): Color = when (kind) {
    DiffDoc.Kind.Added -> colors.positive.copy(alpha = 0.1f)
    DiffDoc.Kind.Removed -> colors.critical.copy(alpha = 0.1f)
    else -> Color.Transparent
}

@Composable
private fun EmptyPatch(change: GitFileChange, staged: Boolean) {
    val colors = DeckTheme.colors
    val reason = when {
        change.binary -> "This is a binary file. git has no text to show for it."
        change.kind == GitChangeKind.Untracked || change.group == GitFileGroup.Untracked ->
            "This file is not tracked yet, so there is nothing to compare it against."
        change.kind == GitChangeKind.Deleted && staged -> "This file was deleted, and the deletion is staged."
        else -> "git has no diff for this file."
    }
    Column(modifier = Modifier.fillMaxWidth().padding(Space.x4)) {
        DeckGroup {
            Text(
                text = reason,
                style = DeckType.footnote,
                color = colors.primary,
                modifier = Modifier.fillMaxWidth().padding(Space.x5),
            )
        }
    }
}

/**
 * A unified patch, split into lines that know what they are.
 *
 * A holder computed once per patch rather than work in a composition that runs whenever anything on
 * the controller moves. Classification order is the whole of it: the file headers `--- a/x` and
 * `+++ b/x` begin with the same characters a removed and an added line do, so they are recognised first
 * or every diff opens with one red line and one green one that are not changes at all.
 */
internal class DiffDoc private constructor(
    val lines: List<Line>,
    val columns: Int,
    val added: Int,
    val removed: Int,
    val truncated: Boolean,
) {
    enum class Kind { Meta, Hunk, Added, Removed, Context }

    class Line(val kind: Kind, val text: String)

    companion object {
        /** A cap, because a patch has no upper bound and a phone does: `git diff` on a lockfile is
         *  routinely six figures of lines. Cut here and say so on screen. */
        const val MAX_LINES = 4000

        private val metaPrefixes = listOf(
            "diff --git", "index ", "new file mode", "deleted file mode", "old mode", "new mode",
            "similarity index", "dissimilarity index", "rename from", "rename to", "copy from",
            "copy to", "Binary files", "GIT binary patch",
        )

        fun parse(patch: String): DiffDoc {
            val kept = mutableListOf<Line>()
            var added = 0
            var removed = 0
            var longest = 0
            var truncated = false

            // Keeping empty subsequences matters: a blank context line in the middle of a hunk is a
            // real line of the file, and dropping it would shift every line after it against the
            // hunk header's own count.
            for (raw in patch.split("\n")) {
                if (kept.size >= MAX_LINES) {
                    truncated = true
                    break
                }
                // A patch git produced on Windows arrives with the carriage return still attached.
                val text = if (raw.endsWith("\r")) raw.dropLast(1) else raw
                val kind = classify(text)
                if (kind == Kind.Added) added += 1
                if (kind == Kind.Removed) removed += 1
                if (text.length > longest) longest = text.length
                kept.add(Line(kind, text))
            }

            // A trailing newline is a property of the text, not a line of the patch.
            if (kept.isNotEmpty() && kept.last().text.isEmpty()) kept.removeAt(kept.lastIndex)

            return DiffDoc(kept, longest, added, removed, truncated)
        }

        private fun classify(text: String): Kind = when {
            text.startsWith("@@") -> Kind.Hunk
            text.startsWith("---") || text.startsWith("+++") -> Kind.Meta
            metaPrefixes.any { text.startsWith(it) } -> Kind.Meta
            text.startsWith("+") -> Kind.Added
            text.startsWith("-") -> Kind.Removed
            // "\ No newline at end of file" belongs to the hunk above it.
            text.startsWith("\\") -> Kind.Meta
            else -> Kind.Context
        }
    }
}
