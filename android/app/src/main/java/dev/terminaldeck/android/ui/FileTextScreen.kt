package dev.terminaldeck.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.FilesGitController
import dev.terminaldeck.android.protocol.FileText
import dev.terminaldeck.android.protocol.Protocol
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

/**
 * One file off the machine, read on the phone — a port of `ios/TerminalDeck/Screens/FileTextView.swift`.
 *
 * The other half of [FilesScreen]: that screen answers *what is in this folder*, this one *what is in
 * this file*. It is honest about the three answers `files.read` gives — text, truncated, binary —
 * because a screen that drew all three the same way would be lying about two of them: a truncated read
 * says how much is in hand and reads the next window from the offset the host returned; a binary file
 * says what it is rather than drawing an empty screen; and text is laid out at its natural width and
 * scrolled sideways, because code has columns and a folded line is soup.
 *
 * Not an editor: `files` is a read capability, and selection and copy are the whole of what leaves.
 */
private const val READ_CEILING = 1_000_000

@Composable
fun FileTextScreen(
    controller: FilesGitController,
    path: String,
    size: Long?,
    onBack: () -> Unit,
) {
    val colors = DeckTheme.colors
    val clipboard = LocalClipboardManager.current

    // The windows read so far, in order. Kept as pieces because that is what arrives; a window that
    // does not continue exactly where the last ended is dropped rather than spliced into the middle.
    var windows by remember(path) { mutableStateOf(listOf<String>()) }
    var readTo by remember(path) { mutableIntStateOf(0) }
    var truncated by remember(path) { mutableStateOf(false) }
    var binary by remember(path) { mutableStateOf(false) }
    var answered by remember(path) { mutableStateOf(false) }
    var waiting by remember(path) { mutableStateOf(false) }
    var silent by remember(path) { mutableStateOf(false) }
    var attempt by remember(path) { mutableIntStateOf(0) }

    val body = windows.joinToString("")

    fun start() {
        windows = emptyList()
        readTo = 0
        truncated = false
        binary = false
        answered = false
        waiting = true
        silent = false
        attempt += 1
        controller.readFile(path, 0)
    }

    fun more() {
        if (!truncated || readTo >= READ_CEILING || waiting) return
        waiting = true
        attempt += 1
        controller.readFile(path, readTo)
    }

    // Take an answer, or refuse it: the path (a late answer for a file behind must not draw as this
    // one), the offset (only a window beginning where the last ended is a continuation), and binary,
    // which ends the read.
    fun absorb(answer: FileText?) {
        if (answer == null || answer.path != path) return
        waiting = false
        if (answer.binary) {
            windows = emptyList()
            readTo = 0
            truncated = false
            binary = true
            answered = true
            return
        }
        when (answer.at) {
            0 -> {
                windows = listOf(answer.text)
                readTo = Protocol.utf8Length(answer.text)
            }
            readTo -> {
                windows = windows + answer.text
                readTo += Protocol.utf8Length(answer.text)
            }
            else -> return
        }
        binary = false
        truncated = answer.truncated
        answered = true
    }

    // A matching answer may already be in hand — the same file opened a moment ago — which is the
    // difference between an instant screen and a round trip somebody watches.
    LaunchedEffect(path) {
        val already = controller.fileText
        if (already != null && already.path == path && already.at == 0) absorb(already) else start()
    }
    LaunchedEffect(controller.fileText) { absorb(controller.fileText) }
    LaunchedEffect(attempt) {
        silent = false
        if (answered) return@LaunchedEffect
        delay(8_000)
        silent = !answered
    }

    BackHandler(onBack = onBack)

    Scaffold(
        containerColor = colors.background,
        topBar = {
            DeckTopBar(
                title = path.substringAfterLast('/').ifEmpty { path },
                onBack = onBack,
                actions = {
                    var menu by remember { mutableStateOf(false) }
                    IconButton(onClick = { menu = true }) {
                        Icon(Icons.Filled.MoreVert, contentDescription = "More", tint = colors.primary)
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(
                            text = { Text("Copy path") },
                            onClick = { clipboard.setText(AnnotatedString(path)); menu = false },
                        )
                        if (body.isNotEmpty()) {
                            DropdownMenuItem(
                                text = { Text("Copy what is shown") },
                                onClick = { clipboard.setText(AnnotatedString(body)); menu = false },
                            )
                        }
                        DropdownMenuItem(
                            text = { Text("Read again") },
                            onClick = { start(); menu = false },
                        )
                    }
                },
            )
        },
        bottomBar = {
            if (truncated && !binary) {
                MoreBar(readTo = readTo, size = size, waiting = waiting, onMore = { more() })
            }
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            PathHeader(path)
            Box(modifier = Modifier.fillMaxSize()) {
                when {
                    binary -> NotText(path = path, size = size)
                    answered && body.isEmpty() -> Empty()
                    windows.isNotEmpty() -> FileBody(body)
                    silent -> NoAnswer(onRetry = { start() })
                    else -> CircularProgressIndicator(
                        color = colors.accent,
                        modifier = Modifier.align(Alignment.Center),
                    )
                }
            }
        }
    }
}

/** The path in full, above the file, so it stays put while the file scrolls under it in both axes. */
@Composable
private fun PathHeader(path: String) {
    val colors = DeckTheme.colors
    Column {
        Text(
            text = path,
            style = DeckType.mono,
            color = colors.faint,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Space.x5, vertical = Space.x3),
        )
        Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(colors.hairline))
    }
}

/**
 * The file itself, laid out at its natural width and scrolled both ways.
 *
 * The two-axis scroll is what makes it a file viewer rather than a paragraph: a 400-column line stays
 * one line. `SelectionContainer` because copying an error out of a log on a server is most of the
 * reason anybody opens this on a phone.
 */
@Composable
private fun FileBody(text: String) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Row(modifier = Modifier.horizontalScroll(rememberScrollState())) {
            SelectionContainer {
                Text(
                    text = text,
                    style = DeckType.mono,
                    color = colors.primary,
                    softWrap = false,
                    modifier = Modifier.padding(horizontal = Space.x4, vertical = Space.x3),
                )
            }
        }
    }
}

@Composable
private fun MoreBar(readTo: Int, size: Long?, waiting: Boolean, onMore: () -> Unit) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxWidth().background(colors.surface).navigationBarsPadding()) {
        Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(colors.hairline))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x4, vertical = Space.x3),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(readSoFar(readTo, size), style = DeckType.footnote, color = colors.secondary)
                if (readTo >= READ_CEILING) {
                    Text(
                        text = "This screen stops here. Use a session and `tail` for the rest.",
                        style = DeckType.caption,
                        color = colors.faint,
                    )
                }
            }
            if (readTo < READ_CEILING) {
                Spacer(Modifier.width(Space.x2))
                if (waiting) {
                    CircularProgressIndicator(color = colors.accent, modifier = Modifier.size(20.dp))
                } else {
                    DeckQuietButton(label = "Read more", onClick = onMore, modifier = Modifier.width(140.dp))
                }
            }
        }
    }
}

private fun readSoFar(readTo: Int, size: Long?): String =
    if (size != null && size > 0) "First ${byteSize(readTo.toLong())} of ${byteSize(size)}"
    else "First ${byteSize(readTo.toLong())} — there is more"

/** Not text, said in as much detail as this side honestly has: the machine's word for what it is not,
 *  this side's guess from the name labelled as the extension, and the size, which is real. */
@Composable
private fun NotText(path: String, size: Long?) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxWidth().padding(Space.x4)) {
        DeckGroup {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(Space.card),
            ) {
                Icon(
                    Icons.Filled.Description,
                    contentDescription = null,
                    tint = colors.secondary,
                    modifier = Modifier.size(22.dp),
                )
                Spacer(Modifier.width(Space.x3))
                Text("This is not a text file", style = DeckType.body, color = colors.primary, modifier = Modifier.weight(1f))
                InfoDot(
                    about = "Binary files",
                    text = "The machine decided this from the bytes themselves — a zero byte in the block it " +
                        "read — rather than from the file's name. That is the test every editor uses, and the " +
                        "only one that is right about a .log that is really a crash dump. It sent no text at all " +
                        "rather than sending nonsense.",
                )
            }
            Text(
                text = binaryKind(path, size),
                style = DeckType.monoFootnote,
                color = colors.faint,
                modifier = Modifier.padding(start = Space.card, end = Space.card, bottom = Space.x3),
            )
        }
    }
}

private fun binaryKind(path: String, size: Long?): String {
    val parts = mutableListOf<String>()
    val ext = path.substringAfterLast('/').substringAfterLast('.', "")
    if (ext.isNotEmpty() && ext != path.substringAfterLast('/')) parts.add(".$ext file")
    if (size != null) parts.add(byteSize(size))
    return if (parts.isEmpty()) "Nothing more is known about it from here." else parts.joinToString("  ·  ")
}

@Composable
private fun Empty() {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxWidth().padding(Space.x4)) {
        DeckGroup {
            Text(
                text = "This file is empty.",
                style = DeckType.footnote,
                color = colors.faint,
                modifier = Modifier.fillMaxWidth().padding(Space.card),
            )
        }
    }
}

@Composable
private fun NoAnswer(onRetry: () -> Unit) {
    val colors = DeckTheme.colors
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier.fillMaxSize().padding(Space.x8),
    ) {
        Text("No answer from the machine", style = DeckType.rowTitle, color = colors.primary)
        Spacer(Modifier.height(Space.x2))
        Text(
            text = "It did not send anything back for this file. It may not have been able to read it.",
            style = DeckType.footnote,
            color = colors.secondary,
        )
        Spacer(Modifier.height(Space.x5))
        DeckQuietButton(label = "Try again", onClick = onRetry, modifier = Modifier.width(200.dp))
    }
}
