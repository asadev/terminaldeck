package dev.terminaldeck.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.DataObject
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.DriveFolderUpload
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.FilesGitController
import dev.terminaldeck.android.protocol.FileRow
import dev.terminaldeck.android.transfer.byteSize
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.InfoDot
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * The machine's disk, on the phone — a port of `ios/TerminalDeck/Screens/FilesView.swift`.
 *
 * On a rented Linux box with nobody in front of it this is the only way to see the disk at all. It is
 * a **reader**, not a chooser: files are the point, dot-entries are kept, and there is no bottom
 * button because arriving somewhere is the outcome. Unreadable rows are drawn dimmed with a lock and
 * do not respond — a row that is offered and then refused is worse than one that never pretended — and
 * a directory descends in place while a file opens [FileTextScreen].
 */
@Composable
fun FilesScreen(
    controller: FilesGitController,
    start: String,
    onOpenFile: (path: String, size: Long?) -> Unit,
    onBack: () -> Unit,
) {
    val colors = DeckTheme.colors

    // The folder last *asked* for — not the same as the one on screen, and the gap between them is the
    // load. Re-adopted from every answer, because the host resolves what it was sent and may spell a
    // path back differently.
    var asked by remember { mutableStateOf("") }
    var silent by remember { mutableStateOf(false) }
    var attempt by remember { mutableIntStateOf(0) }

    val listing = controller.listing

    fun ask(path: String) {
        if (path.isEmpty()) return
        asked = path
        attempt += 1
        controller.listFiles(path)
    }

    // Resumed rather than reset: a listing already in hand is the folder walked to a moment ago.
    LaunchedEffect(Unit) {
        val here = controller.listing?.path
        if (here != null) asked = here else ask(start)
    }
    // The machine's spelling of a path wins over this phone's.
    LaunchedEffect(controller.listing) { controller.listing?.let { asked = it.path } }
    LaunchedEffect(attempt) {
        silent = false
        if (asked.isEmpty()) return@LaunchedEffect
        delay(6_000)
        silent = controller.listing?.path != asked
    }

    BackHandler(onBack = onBack)

    Scaffold(
        containerColor = colors.background,
        topBar = {
            val title = (listing?.path ?: asked).substringAfterLast('/').ifEmpty { "Files" }
            DeckTopBar(
                title = title,
                onBack = onBack,
                actions = {
                    IconButton(onClick = { ask(listing?.path ?: asked) }) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Read this folder again", tint = colors.primary)
                    }
                },
            )
        },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                listing != null && listing.path == asked -> Rows(
                    listing = listing,
                    onDescend = { ask(it) },
                    onOpenFile = onOpenFile,
                )
                silent -> NoAnswer(asked = asked, start = start, onRetry = { ask(asked) }, onRestart = { ask(start) })
                else -> CircularProgressIndicator(color = colors.accent, modifier = Modifier.align(Alignment.Center))
            }
        }
    }
}

@Composable
private fun Rows(
    listing: dev.terminaldeck.android.protocol.FileListing,
    onDescend: (String) -> Unit,
    onOpenFile: (String, Long?) -> Unit,
) {
    val colors = DeckTheme.colors
    val sorted = remember(listing) {
        listing.entries.sortedWith(compareByDescending<FileRow> { it.directory }.thenBy { it.name.lowercase() })
    }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(top = Space.x3, bottom = Space.x5),
    ) {
        // Where you are, in full, and the one explanation on the screen.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x5, vertical = Space.x2),
        ) {
            Text(
                text = listing.path,
                style = DeckType.mono,
                color = colors.faint,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            InfoDot(
                about = "Files",
                text = "This is the machine's own disk, read over the connection. Rows this account cannot " +
                    "open are dimmed and do not respond — they are drawn so that something you know is there " +
                    "is not simply missing.",
            )
        }

        DeckGroup(modifier = Modifier.padding(horizontal = Space.x4)) {
            if (listing.parent != null) {
                EntryRow(icon = Icons.Filled.DriveFolderUpload, name = "..", detail = null, dimmed = false, chevron = true) {
                    onDescend(listing.parent)
                }
                if (sorted.isNotEmpty()) DeckDivider(startIndent = 46.dp)
            }
            if (sorted.isEmpty() && listing.parent == null) {
                Text(
                    text = "Nothing in here.",
                    style = DeckType.footnote,
                    color = colors.faint,
                    modifier = Modifier.fillMaxWidth().padding(Space.card),
                )
            }
            sorted.forEachIndexed { index, entry ->
                when {
                    !entry.readable -> EntryRow(
                        icon = Icons.Filled.Lock,
                        name = entry.name,
                        detail = if (entry.directory) "Cannot be opened by this account" else fileDetail(entry),
                        dimmed = true,
                        chevron = false,
                        onClick = null,
                    )
                    entry.directory -> EntryRow(
                        icon = Icons.Filled.Folder,
                        name = entry.name,
                        detail = null,
                        dimmed = false,
                        chevron = true,
                    ) { onDescend(entry.path) }
                    else -> EntryRow(
                        icon = fileIcon(entry.name),
                        name = entry.name,
                        detail = fileDetail(entry),
                        dimmed = false,
                        chevron = true,
                    ) { onOpenFile(entry.path, entry.size) }
                }
                if (index < sorted.lastIndex) DeckDivider(startIndent = 46.dp)
            }
        }
    }
}

@Composable
private fun EntryRow(
    icon: ImageVector,
    name: String,
    detail: String?,
    dimmed: Boolean,
    chevron: Boolean,
    onClick: (() -> Unit)? = null,
) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = Space.x4, vertical = Space.x3),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (dimmed) colors.faint else colors.secondary,
            modifier = Modifier.size(24.dp),
        )
        Spacer(Modifier.width(Space.x3))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = name,
                style = DeckType.body,
                color = if (dimmed) colors.faint else colors.primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (detail != null) {
                Text(text = detail, style = DeckType.caption, color = colors.faint, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (chevron) {
            Spacer(Modifier.width(Space.x2))
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.faint,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

private fun fileDetail(entry: FileRow): String? {
    val parts = mutableListOf<String>()
    entry.size?.let { parts.add(byteSize(it)) }
    entry.at?.let { parts.add(whenModified(it)) }
    return if (parts.isEmpty()) null else parts.joinToString("  ·  ")
}

/** A modified time as short as it can be and still be unambiguous: a clock today, a day and month this
 *  year, a year as well for anything older. */
private fun whenModified(epochMillis: Long): String {
    val date = Date(epochMillis)
    val now = Calendar.getInstance()
    val then = Calendar.getInstance().apply { time = date }
    val sameDay = now.get(Calendar.YEAR) == then.get(Calendar.YEAR) &&
        now.get(Calendar.DAY_OF_YEAR) == then.get(Calendar.DAY_OF_YEAR)
    val pattern = when {
        sameDay -> "HH:mm"
        now.get(Calendar.YEAR) == then.get(Calendar.YEAR) -> "d MMM"
        else -> "d MMM yyyy"
    }
    return SimpleDateFormat(pattern, Locale.getDefault()).format(date)
}

/** An icon from the name — a hint, never a claim. The host decided text from binary by looking at the
 *  bytes; an extension picks a glyph and never a behaviour. */
private fun fileIcon(name: String): ImageVector {
    val ext = name.substringAfterLast('.', "").lowercase()
    return when (ext) {
        "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "ico" -> Icons.Filled.Image
        "mp4", "mov", "m4v", "webm", "mkv" -> Icons.Filled.Movie
        "mp3", "wav", "m4a", "aac", "flac" -> Icons.Filled.GraphicEq
        "zip", "gz", "tar", "tgz", "bz2", "xz", "7z", "rar" -> Icons.Filled.Inventory2
        "pdf" -> Icons.Filled.PictureAsPdf
        "json", "yml", "yaml", "toml", "xml", "plist" -> Icons.Filled.DataObject
        "ts", "tsx", "js", "jsx", "swift", "py", "rb", "go", "rs", "c", "h", "cpp", "java", "kt" -> Icons.Filled.Code
        "sh", "bash", "zsh", "fish" -> Icons.Filled.Terminal
        "md", "txt", "log", "csv" -> Icons.Filled.Description
        else -> if (name.substringAfterLast('.', "").isEmpty()) Icons.Filled.Description else Icons.AutoMirrored.Filled.InsertDriveFile
    }
}

@Composable
private fun NoAnswer(asked: String, start: String, onRetry: () -> Unit, onRestart: () -> Unit) {
    val colors = DeckTheme.colors
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier.fillMaxSize().padding(Space.x8),
    ) {
        Text("No answer from the machine", style = DeckType.rowTitle, color = colors.primary)
        Spacer(Modifier.height(Space.x2))
        Text(
            text = "It did not send anything back for $asked. It may not have been able to read that folder.",
            style = DeckType.footnote,
            color = colors.secondary,
        )
        Spacer(Modifier.height(Space.x5))
        DeckQuietButton(label = "Try again", onClick = onRetry, modifier = Modifier.width(220.dp))
        Spacer(Modifier.height(Space.x2))
        DeckQuietButton(label = "Back to ${start.substringAfterLast('/')}", onClick = onRestart, modifier = Modifier.width(220.dp))
    }
}
