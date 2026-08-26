package dev.terminaldeck.android.ui

import android.annotation.SuppressLint
import android.graphics.BitmapFactory
import android.net.Uri
import android.view.ViewGroup
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.FolderOff
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import dev.terminaldeck.android.FilesGitController
import dev.terminaldeck.android.PanelsController
import dev.terminaldeck.android.protocol.FileText
import dev.terminaldeck.android.protocol.PanelData
import dev.terminaldeck.android.protocol.PanelKind
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.transfer.byteSize
import dev.terminaldeck.android.tunnel.TunnelView
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.InfoDot
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

private const val READ_CEILING = 1_000_000
private const val FETCH_WITHOUT_ASKING = 4 * 1024 * 1024

/** The verb the artifacts panel answers and deliberately does not advertise on a row: a generic button
 *  would start a server and have nowhere to show it. */
private const val PREVIEW_ACTION = "preview"

/**
 * An artifact, opened — a port of `ios/TerminalDeck/Screens/ArtifactView.swift`.
 *
 * The point of the screen is the verb — **review** and **use**, not audit a path list. Which of four
 * things happens is decided by the host, which puts the kind in the row's id grammar so this knows
 * what it is opening before it opens anything: a prototype (`page`) is served on the machine and opened
 * as a real page in a WebView, so its stylesheet and every relative link resolve as they do over
 * there; a photograph (`image`) is fetched as real bytes and drawn; media go to the same page view;
 * text is read a window at a time; and anything else is named, measured and left alone. Nothing here
 * runs unless the machine opens its ports to a device — never a control that cannot act, never a
 * preview that cannot load.
 *
 * ## One faithful adaptation from iOS
 *
 * The prototype runs over the same [dev.terminaldeck.android.tunnel.PortTunnel] the Browser tab uses,
 * reached here through [onServePort]/[tunnel] rather than iOS's `PortTunnel` object; the page opens in
 * an embedded [WebView] at the tunnel's own loopback address resolved against the row's preview path.
 * The file body is drawn in the app's own surface/ink rather than the terminal palette — a deliberate
 * simplification that keeps the theme source-scan green — and markdown prose is rendered by a small
 * block renderer here rather than Foundation's parser.
 */
@Composable
fun ArtifactView(
    ref: ArtifactRef,
    title: String,
    project: String?,
    files: FilesGitController,
    panels: PanelsController,
    machineNoun: String,
    canReadFiles: Boolean,
    canReadPanels: Boolean,
    canBrowseLocalhost: Boolean,
    tunnel: TunnelView?,
    onServePort: (Int) -> Unit,
    onCloseServedPort: () -> Unit,
    onOpenFolder: (String) -> Unit,
    onBack: () -> Unit,
) {
    val colors = DeckTheme.colors
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()

    // Reading a text file — the same windows/paging/binary shape [FileTextScreen] uses.
    var windows by remember(ref) { mutableStateOf(listOf<String>()) }
    var readTo by remember(ref) { mutableIntStateOf(0) }
    var truncated by remember(ref) { mutableStateOf(false) }
    var binary by remember(ref) { mutableStateOf(false) }
    var answered by remember(ref) { mutableStateOf(false) }
    var waiting by remember(ref) { mutableStateOf(false) }
    var silent by remember(ref) { mutableStateOf(false) }
    var attempt by remember(ref) { mutableIntStateOf(0) }
    var sourceShown by remember(ref) { mutableStateOf(false) }
    var asProse by remember(ref) { mutableStateOf(true) }

    // Serving.
    var address by remember(ref) { mutableStateOf(ref.preview) }
    var asking by remember(ref) { mutableStateOf(false) }
    var problem by remember(ref) { mutableStateOf<String?>(null) }
    var pending by remember(ref) { mutableStateOf<Errand?>(null) }
    var weOpened by remember(ref) { mutableStateOf(false) }
    var pageUrl by remember(ref) { mutableStateOf<String?>(null) }

    // Drawing a picture.
    var picture by remember(ref) { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    var fetching by remember(ref) { mutableStateOf(false) }
    var actualSize by remember(ref) { mutableStateOf(false) }

    val body = windows.joinToString("")
    val isMarkdown = ref.kind == ArtifactKind.Text && (ref.suffix == "md" || ref.suffix == "markdown")
    val readsAFile = ref.kind == ArtifactKind.Text || (ref.kind == ArtifactKind.Page && sourceShown)

    fun startReading() {
        windows = emptyList(); readTo = 0; truncated = false; binary = false
        answered = false; waiting = true; silent = false; attempt += 1
        files.readFile(ref.path, 0)
    }

    fun readMore() {
        if (!truncated || readTo >= READ_CEILING || waiting) return
        waiting = true; attempt += 1; files.readFile(ref.path, readTo)
    }

    fun absorb(answer: FileText?) {
        if (answer == null || answer.path != ref.path) return
        waiting = false
        if (answer.binary) {
            windows = emptyList(); readTo = 0; truncated = false; binary = true; answered = true; return
        }
        when (answer.at) {
            0 -> { windows = listOf(answer.text); readTo = Protocol.utf8Length(answer.text) }
            readTo -> { windows = windows + answer.text; readTo += Protocol.utf8Length(answer.text) }
            else -> return
        }
        binary = false; truncated = answer.truncated; answered = true
    }

    fun fetchImage(url: String) {
        fetching = true; problem = null
        scope.launch {
            val outcome = withContext(Dispatchers.IO) { fetchBitmap(url) }
            fetching = false
            when (outcome) {
                is Fetched.Ok -> picture = outcome.bitmap.asImageBitmap()
                is Fetched.Bad -> problem = outcome.why
            }
        }
    }

    // Do the thing the press was for, once the tunnel is actually serving. The tunnel binds nothing
    // until the machine has answered, so a live url is the first moment a path means anything.
    fun spend(live: TunnelView) {
        val errand = pending ?: return
        val addr = address ?: return
        val base = live.url ?: return
        pending = null
        val resolved = joinUrl(base, ref.previewPath(addr))
        when (errand) {
            Errand.OpenPage -> pageUrl = resolved
            Errand.FetchImage -> fetchImage(resolved)
        }
    }

    fun openTunnel(addr: PreviewAddress) {
        val held = tunnel
        if (held != null && held.port == addr.port && held.live) {
            spend(held)
            return
        }
        weOpened = true
        onServePort(addr.port)
    }

    fun begin(errand: Errand) {
        problem = null
        if (ref.kind == ArtifactKind.Gone) return
        if (!canBrowseLocalhost) {
            problem = "The $machineNoun does not open its ports to a device, so it cannot show this here."
            return
        }
        pending = errand
        val addr = address
        if (addr != null) {
            openTunnel(addr)
            return
        }
        if (!canReadPanels) {
            problem = "The $machineNoun is not answering panels, so it cannot be asked to serve this."
            return
        }
        asking = true
        panels.act(PanelKind.Artifacts, PREVIEW_ACTION, path = project, id = ref.token)
    }

    // The panel answered. Find this file's row by token — the host rescans on every act, so a file
    // written in between would move the list under a remembered index.
    fun tookPreview(answer: PanelData?) {
        if (answer == null) return
        val mine = answer.rows.mapNotNull { ArtifactRef.parse(it.id) }.firstOrNull { it.token == ref.token }
        val found = mine?.preview
        if (found != null) {
            address = found
            if (asking) { asking = false; openTunnel(found) }
            return
        }
        if (!asking) return
        asking = false
        problem = answer.notice ?: "The machine did not start a server for this project."
    }

    // Arriving.
    LaunchedEffectKeyed(ref) {
        when (ref.kind) {
            ArtifactKind.Text -> {
                val already = files.fileText
                if (already != null && already.path == ref.path && already.at == 0) absorb(already) else startReading()
            }
            ArtifactKind.Image -> if (canBrowseLocalhost && (ref.bytes ?: 0) <= FETCH_WITHOUT_ASKING) begin(Errand.FetchImage)
            else -> {}
        }
    }
    LaunchedEffectKeyed(files.fileText) { absorb(files.fileText) }
    LaunchedEffectKeyed(panels.data(PanelKind.Artifacts)) { tookPreview(panels.data(PanelKind.Artifacts)) }
    LaunchedEffectKeyed(tunnel) {
        val t = tunnel ?: return@LaunchedEffectKeyed
        val addr = address
        when {
            t.detail != null -> { problem = t.detail; pending = null }
            t.live && addr != null && t.port == addr.port -> spend(t)
        }
    }
    LaunchedEffectKeyed(attempt) {
        silent = false
        if (ref.kind != ArtifactKind.Text || answered) return@LaunchedEffectKeyed
        kotlinx.coroutines.delay(8_000)
        silent = !answered
    }

    // Everything this screen holds on the machine, given back when it leaves. A tunnel left open is a
    // listener on the phone and a stream on the host for a page nobody is looking at.
    DisposableEffect(ref) {
        onDispose { if (weOpened) onCloseServedPort() }
    }

    BackHandler(onBack = onBack)

    Scaffold(
        containerColor = colors.background,
        topBar = {
            DeckTopBar(
                title = ref.name,
                onBack = onBack,
                actions = {
                    var menu by remember { mutableStateOf(false) }
                    IconButton(onClick = { menu = true }) {
                        Icon(Icons.Filled.MoreVert, contentDescription = "More", tint = colors.primary)
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Copy path") }, onClick = { clipboard.setText(AnnotatedString(ref.path)); menu = false })
                        if (readsAFile && body.isNotEmpty()) {
                            DropdownMenuItem(text = { Text("Copy what is shown") }, onClick = { clipboard.setText(AnnotatedString(body)); menu = false })
                        }
                        if (isMarkdown) {
                            DropdownMenuItem(text = { Text(if (asProse) "Show the source" else "Read it as prose") }, onClick = { asProse = !asProse; menu = false })
                        }
                        if (canReadFiles) {
                            DropdownMenuItem(text = { Text("Show the folder") }, onClick = { onOpenFolder(ref.folder); menu = false })
                        }
                        if (ref.kind == ArtifactKind.Page) {
                            DropdownMenuItem(
                                text = { Text(if (sourceShown) "Back to the page" else "Show the source") },
                                onClick = { if (!sourceShown) startReading(); sourceShown = !sourceShown; menu = false },
                            )
                        }
                        if (readsAFile) {
                            DropdownMenuItem(text = { Text("Read again") }, onClick = { startReading(); menu = false })
                        }
                    }
                },
            )
        },
        bottomBar = {
            when {
                readsAFile && truncated && !binary ->
                    MoreBar(readTo = readTo, bytes = ref.bytes, waiting = waiting, onMore = { readMore() })
                ref.kind == ArtifactKind.Image && picture != null && canBrowseLocalhost ->
                    ImageBar(actualSize = actualSize, onOpenPage = { begin(Errand.OpenPage) }, disabled = pending != null)
            }
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            PathHeaderLine(ref.path)
            Box(modifier = Modifier.fillMaxSize()) {
                when (ref.kind) {
                    ArtifactKind.Gone -> Absent(ref.path, machineNoun)
                    ArtifactKind.Other -> Opaque(ref, machineNoun)
                    ArtifactKind.Page -> if (sourceShown) Reading(body, windows.isNotEmpty(), binary, answered, silent, isMarkdown, asProse, ref, ::startReading)
                    else Prototype(ref, machineNoun, canBrowseLocalhost, asking, pending, problem) { begin(Errand.OpenPage) }
                    ArtifactKind.Media -> Prototype(ref, machineNoun, canBrowseLocalhost, asking, pending, problem) { begin(Errand.OpenPage) }
                    ArtifactKind.Image -> Photograph(
                        picture = picture, ref = ref, machineNoun = machineNoun, canBrowseLocalhost = canBrowseLocalhost,
                        fetching = fetching, asking = asking, pending = pending, problem = problem,
                        actualSize = actualSize, onToggleSize = { actualSize = !actualSize }, onShow = { begin(Errand.FetchImage) },
                    )
                    ArtifactKind.Text -> Reading(body, windows.isNotEmpty(), binary, answered, silent, isMarkdown, asProse, ref, ::startReading)
                }
            }
        }
    }

    // The prototype's page, in an embedded WebView on the tunnel's own loopback. Backing out keeps the
    // tunnel: a second Run it must not have to open it again.
    pageUrl?.let { url ->
        PageOverlay(url = url, onClose = { pageUrl = null })
    }
}

private enum class Errand { OpenPage, FetchImage }

/* -------------------------------------------------------------------- the states -- */

@Composable
private fun Prototype(
    ref: ArtifactRef,
    machineNoun: String,
    canBrowseLocalhost: Boolean,
    asking: Boolean,
    pending: Errand?,
    problem: String?,
    onRun: () -> Unit,
) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = Space.x4)) {
        InfoCard(
            icon = if (ref.kind == ArtifactKind.Page) Icons.Filled.Public else Icons.Filled.PlayArrow,
            title = if (ref.kind == ArtifactKind.Page) "A page" else "A ${mediaWord(ref)}",
            detail = facts(ref),
            note = if (ref.kind == ArtifactKind.Page)
                "Run it and the $machineNoun serves this project on a port of its own. The page opens here " +
                    "on that port, so its stylesheet, its script and every relative link work exactly as they do over there."
            else
                "The $machineNoun serves it and the browser view plays it. Seeking works: the server answers byte ranges.",
        )
        if (problem != null) Failure(problem)
        Spacer(Modifier.height(Space.x4))
        if (canBrowseLocalhost) {
            val working = asking || pending != null
            DeckPrimaryButton(
                label = when {
                    asking -> "Asking the $machineNoun…"
                    pending != null -> "Opening the tunnel…"
                    ref.kind == ArtifactKind.Page -> "Run it"
                    else -> "Play it"
                },
                onClick = onRun,
                enabled = !working,
                modifier = Modifier.padding(horizontal = Space.x4),
                leading = if (working) {
                    { CircularProgressIndicator(color = colors.onAccent, modifier = Modifier.size(18.dp)) }
                } else {
                    { Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = colors.onAccent, modifier = Modifier.size(18.dp)) }
                },
            )
        } else {
            Column(modifier = Modifier.padding(horizontal = Space.x4)) {
                DeckGroup {
                    NoteRow("The $machineNoun does not open its ports to a device, so a page from it cannot be opened here.")
                }
            }
        }
        Spacer(Modifier.height(Space.x6))
    }
}

@Composable
private fun Photograph(
    picture: androidx.compose.ui.graphics.ImageBitmap?,
    ref: ArtifactRef,
    machineNoun: String,
    canBrowseLocalhost: Boolean,
    fetching: Boolean,
    asking: Boolean,
    pending: Errand?,
    problem: String?,
    actualSize: Boolean,
    onToggleSize: () -> Unit,
    onShow: () -> Unit,
) {
    val colors = DeckTheme.colors
    if (picture != null) {
        // Two axes, and a double tap between fit-to-width and one-to-one — what every photo viewer on
        // this platform does, and one piece of state rather than a transform to maintain.
        Box(
            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState())
                .pointerInput(Unit) { detectTapGestures(onDoubleTap = { onToggleSize() }) },
        ) {
            Image(
                bitmap = picture,
                contentDescription = ref.name,
                contentScale = if (actualSize) ContentScale.None else ContentScale.Fit,
                modifier = if (actualSize) Modifier else Modifier.fillMaxWidth(),
            )
        }
    } else {
        Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = Space.x4)) {
            InfoCard(
                icon = Icons.Filled.Image,
                title = "A picture",
                detail = facts(ref),
                note = "It comes over the connection from the $machineNoun as real bytes. The frame that carries a " +
                    "file to this phone carries text, so this is the only honest way to look at one.",
            )
            if (problem != null) Failure(problem)
            Spacer(Modifier.height(Space.x4))
            if (canBrowseLocalhost) {
                val working = fetching || asking || pending != null
                DeckPrimaryButton(
                    label = if (working) "Fetching…" else (ref.bytes?.let { "Show it · ${byteSize(it.toLong())}" } ?: "Show it"),
                    onClick = onShow,
                    enabled = !working,
                    modifier = Modifier.padding(horizontal = Space.x4),
                    leading = if (working) {
                        { CircularProgressIndicator(color = colors.onAccent, modifier = Modifier.size(18.dp)) }
                    } else {
                        { Icon(Icons.Filled.ArrowDownward, contentDescription = null, tint = colors.onAccent, modifier = Modifier.size(18.dp)) }
                    },
                )
            } else {
                Column(modifier = Modifier.padding(horizontal = Space.x4)) {
                    DeckGroup { NoteRow("The $machineNoun does not open its ports to a device, so its pictures cannot be fetched here.") }
                }
            }
            Spacer(Modifier.height(Space.x6))
        }
    }
}

@Composable
private fun Reading(
    body: String,
    hasWindows: Boolean,
    binary: Boolean,
    answered: Boolean,
    silent: Boolean,
    isMarkdown: Boolean,
    asProse: Boolean,
    ref: ArtifactRef,
    onRetry: () -> Unit,
) {
    val colors = DeckTheme.colors
    when {
        binary -> Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = Space.x4)) {
            InfoCard(
                icon = Icons.Filled.Description,
                title = "This is not a text file",
                detail = facts(ref),
                note = "The machine decided that from the bytes themselves — a zero byte in the block it read — " +
                    "rather than from the file's name. It sent no text at all rather than sending nonsense.",
            )
        }
        answered && body.isEmpty() -> Column(modifier = Modifier.fillMaxWidth().padding(Space.x4)) {
            DeckGroup { NoteRow("This file is empty.") }
        }
        hasWindows -> if (isMarkdown && asProse) {
            Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Space.x4, vertical = Space.x3)) {
                MarkdownProse(body)
            }
        } else {
            Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                Row(modifier = Modifier.horizontalScroll(rememberScrollState())) {
                    SelectionContainer {
                        Text(text = body, style = DeckType.mono, color = colors.primary, softWrap = false, modifier = Modifier.padding(horizontal = Space.x4, vertical = Space.x3))
                    }
                }
            }
        }
        silent -> Column(
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
            modifier = Modifier.fillMaxSize().padding(Space.x8),
        ) {
            Text("No answer from the machine", style = DeckType.rowTitle, color = colors.primary)
            Spacer(Modifier.height(Space.x2))
            Text("It did not send anything back for this file. It may not have been able to read it.", style = DeckType.footnote, color = colors.secondary)
            Spacer(Modifier.height(Space.x5))
            dev.terminaldeck.android.ui.kit.DeckQuietButton(label = "Try again", onClick = onRetry, modifier = Modifier.width(200.dp))
        }
        else -> Box(modifier = Modifier.fillMaxSize()) {
            CircularProgressIndicator(color = colors.accent, modifier = Modifier.align(Alignment.Center))
        }
    }
}

@Composable
private fun Opaque(ref: ArtifactRef, machineNoun: String) {
    Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = Space.x4)) {
        InfoCard(
            icon = Icons.Filled.Inventory2,
            title = "Nothing here can open this",
            detail = facts(ref),
            note = "It is not a page, a picture or text. Its path is on the menu above, which is what a session on " +
                "the $machineNoun needs to do something with it.",
        )
    }
}

@Composable
private fun Absent(path: String, machineNoun: String) {
    Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = Space.x4)) {
        InfoCard(
            icon = Icons.Filled.FolderOff,
            title = "Not on disk any more",
            detail = path,
            note = "An agent made this and it has since been deleted or moved. Nothing can be opened, and the record " +
                "of what was written to it is still on the Artifacts list.",
        )
    }
}

/* ---------------------------------------------------------------------- pieces -- */

@Composable
private fun PathHeaderLine(path: String) {
    val colors = DeckTheme.colors
    Column {
        Text(
            text = path, style = DeckType.mono, color = colors.faint, maxLines = 2, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x5, vertical = Space.x3),
        )
        Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(colors.hairline))
    }
}

@Composable
private fun InfoCard(icon: ImageVector, title: String, detail: String, note: String) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x4)) {
        DeckGroup {
            Column(modifier = Modifier.padding(Space.x4)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(icon, contentDescription = null, tint = colors.secondary, modifier = Modifier.size(24.dp))
                    Spacer(Modifier.width(Space.x3))
                    Text(title, style = DeckType.body, color = colors.primary, modifier = Modifier.weight(1f))
                    InfoDot(about = title, text = note)
                }
                Spacer(Modifier.height(Space.x2))
                Text(detail, style = DeckType.monoFootnote, color = colors.faint, modifier = Modifier.padding(start = 36.dp))
            }
        }
    }
}

@Composable
private fun NoteRow(text: String) {
    Text(
        text = text, style = DeckType.value, color = DeckTheme.colors.secondary,
        modifier = Modifier.fillMaxWidth().padding(Space.x4),
    )
}

@Composable
private fun Failure(reason: String) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x4, vertical = Space.x3)) {
        DeckGroup {
            Column(modifier = Modifier.padding(horizontal = Space.x4, vertical = Space.x4)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Warning, contentDescription = null, tint = colors.critical, modifier = Modifier.size(24.dp))
                    Spacer(Modifier.width(Space.x3))
                    Text("That did not work.", style = DeckType.body, color = colors.primary)
                }
                Spacer(Modifier.height(Space.x2))
                Text(reason, style = DeckType.footnote, color = colors.secondary, modifier = Modifier.padding(start = 36.dp))
            }
        }
    }
}

@Composable
private fun MoreBar(readTo: Int, bytes: Int?, waiting: Boolean, onMore: () -> Unit) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxWidth().background(colors.surface).navigationBarsPadding()) {
        Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(colors.hairline))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x4, vertical = Space.x3),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = if (bytes != null && bytes > 0) "First ${byteSize(readTo.toLong())} of ${byteSize(bytes.toLong())}"
                    else "First ${byteSize(readTo.toLong())} — there is more",
                    style = DeckType.footnote, color = colors.secondary,
                )
                if (readTo >= READ_CEILING) {
                    Text("This screen stops here. Use a session and `tail` for the rest.", style = DeckType.caption, color = colors.faint)
                }
            }
            if (readTo < READ_CEILING) {
                Spacer(Modifier.width(Space.x2))
                if (waiting) CircularProgressIndicator(color = colors.accent, modifier = Modifier.size(20.dp))
                else dev.terminaldeck.android.ui.kit.DeckQuietButton(label = "Read more", onClick = onMore, modifier = Modifier.width(140.dp))
            }
        }
    }
}

@Composable
private fun ImageBar(actualSize: Boolean, onOpenPage: () -> Unit, disabled: Boolean) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxWidth().background(colors.surface).navigationBarsPadding()) {
        Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(colors.hairline))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Space.x4, vertical = Space.x3),
        ) {
            Text(if (actualSize) "Actual size" else "Fit to width", style = DeckType.footnote, color = colors.secondary, modifier = Modifier.weight(1f))
            dev.terminaldeck.android.ui.kit.DeckQuietButton(label = "Open in the browser view", onClick = onOpenPage, enabled = !disabled, modifier = Modifier.wrapContentWidth().width(220.dp))
        }
    }
}

/** The prototype's page, full-screen over the artifact, in a real loopback WebView. */
@Composable
private fun PageOverlay(url: String, onClose: () -> Unit) {
    val colors = DeckTheme.colors
    var web by remember { mutableStateOf<WebView?>(null) }
    BackHandler(onBack = onClose)
    DisposableEffect(Unit) { onDispose { web?.let { it.stopLoading(); it.destroy() } } }
    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = "Preview", subtitle = displayHost(url), onBack = onClose, actions = {
            IconButton(onClick = { web?.reload() }) { Icon(Icons.Filled.Refresh, contentDescription = "Reload", tint = colors.secondary) }
        }) },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { context ->
                    makeArtifactWebView(context).also { created ->
                        created.webViewClient = WebViewClient()
                        web = created
                        created.loadUrl(url)
                    }
                },
            )
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
private fun makeArtifactWebView(context: android.content.Context): WebView = WebView(context).apply {
    layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    settings.apply {
        javaScriptEnabled = true
        domStorageEnabled = true
        mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
        useWideViewPort = true
        loadWithOverviewMode = true
        builtInZoomControls = true
        displayZoomControls = false
        allowFileAccess = false
        allowContentAccess = false
    }
}

/* --------------------------------------------------------- markdown, as prose -- */

/**
 * A note an agent wrote, read as a note — a block renderer, not a Markdown implementation. Headings,
 * bullets, numbered items, fenced code, rules and paragraphs, which is the six shapes an agent writes.
 * Inline emphasis (`**bold**`, `*italic*`, `` `code` ``) is handled by a small scanner; anything else
 * is drawn as its own text, never dropped and never guessed at.
 */
@Composable
private fun MarkdownProse(text: String) {
    val colors = DeckTheme.colors
    val blocks = remember(text) { parseMarkdown(text) }
    Column(verticalArrangement = Arrangement.spacedBy(Space.x2)) {
        blocks.take(2_000).forEach { block ->
            when (block) {
                is MdBlock.Heading -> Text(
                    inlineMarkdown(block.text),
                    style = when (block.level) { 1 -> DeckType.title; 2 -> DeckType.rowTitle; else -> DeckType.body }.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.primary,
                )
                is MdBlock.Paragraph -> Text(inlineMarkdown(block.text), style = DeckType.control, color = colors.primary)
                is MdBlock.Bullet -> Row(modifier = Modifier.padding(start = Space.x15)) {
                    Text(block.marker, style = DeckType.control, color = colors.accent)
                    Spacer(Modifier.width(Space.x2))
                    Text(inlineMarkdown(block.text), style = DeckType.control, color = colors.primary)
                }
                is MdBlock.Code -> Text(
                    block.text, style = DeckType.mono, color = colors.primary,
                    modifier = Modifier.fillMaxWidth().padding(Space.x2).background(colors.surfaceHigh).padding(Space.x2),
                )
                is MdBlock.Rule -> Box(modifier = Modifier.fillMaxWidth().padding(vertical = Space.x1).height(0.5.dp).background(colors.hairlineStrong))
            }
        }
        if (blocks.size > 2_000) {
            Text("${blocks.size - 2_000} more blocks are not drawn. Show the source to read them.", style = DeckType.caption, color = colors.faint)
        }
    }
}

private fun inlineMarkdown(text: String): AnnotatedString = buildAnnotatedString {
    var i = 0
    while (i < text.length) {
        when {
            text.startsWith("**", i) -> {
                val end = text.indexOf("**", i + 2)
                if (end > 0) { withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(text.substring(i + 2, end)) }; i = end + 2 }
                else { append(text[i]); i++ }
            }
            text[i] == '`' -> {
                val end = text.indexOf('`', i + 1)
                if (end > 0) { withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) { append(text.substring(i + 1, end)) }; i = end + 1 }
                else { append(text[i]); i++ }
            }
            text[i] == '*' -> {
                val end = text.indexOf('*', i + 1)
                if (end > 0) { withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(text.substring(i + 1, end)) }; i = end + 1 }
                else { append(text[i]); i++ }
            }
            else -> { append(text[i]); i++ }
        }
    }
}

private sealed interface MdBlock {
    class Heading(val level: Int, val text: String) : MdBlock
    class Paragraph(val text: String) : MdBlock
    class Bullet(val marker: String, val text: String) : MdBlock
    class Code(val text: String) : MdBlock
    object Rule : MdBlock
}

/** Split a document into blocks in one pass. A fence swallows everything to the next fence — the one
 *  rule that has to be applied first, or a `# heading` inside a code block is drawn as a heading. */
private fun parseMarkdown(text: String): List<MdBlock> {
    val blocks = mutableListOf<MdBlock>()
    val paragraph = mutableListOf<String>()
    val fence = mutableListOf<String>()
    var fenced = false

    fun flush() {
        if (paragraph.isEmpty()) return
        blocks.add(MdBlock.Paragraph(paragraph.joinToString(" ")))
        paragraph.clear()
    }

    for (raw in text.split("\n")) {
        val trimmed = raw.trim()
        if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
            if (fenced) { blocks.add(MdBlock.Code(fence.joinToString("\n"))); fence.clear(); fenced = false }
            else { flush(); fenced = true }
            continue
        }
        if (fenced) { fence.add(raw); continue }
        if (trimmed.isEmpty()) { flush(); continue }
        if (trimmed == "---" || trimmed == "***" || trimmed == "___") { flush(); blocks.add(MdBlock.Rule); continue }
        if (trimmed.startsWith("#")) {
            val hashes = trimmed.takeWhile { it == '#' }.length
            val rest = trimmed.drop(hashes).trim()
            if (hashes <= 6 && rest.isNotEmpty()) { flush(); blocks.add(MdBlock.Heading(hashes, rest)); continue }
        }
        if (trimmed.startsWith("- ") || trimmed.startsWith("* ") || trimmed.startsWith("+ ")) {
            flush(); blocks.add(MdBlock.Bullet("•", trimmed.drop(2))); continue
        }
        val dot = trimmed.indexOf('.')
        if (dot > 0 && trimmed.substring(0, dot).all { it.isDigit() } && dot + 1 < trimmed.length && trimmed[dot + 1] == ' ') {
            flush(); blocks.add(MdBlock.Bullet(trimmed.substring(0, dot + 1), trimmed.substring(dot + 2))); continue
        }
        paragraph.add(trimmed)
    }
    if (fenced && fence.isNotEmpty()) blocks.add(MdBlock.Code(fence.joinToString("\n")))
    flush()
    return blocks
}

/* ------------------------------------------------------------- the row grammar -- */

/** The six words the panel sorts a file into. A port of `ArtifactKindName`. */
enum class ArtifactKind { Page, Image, Media, Text, Other, Gone }

/**
 * Where a project is being served — `<port>.<secret>`, or absent for `-`. The secret is half of it and
 * is not optional: the port is guessable by anything else on that machine and the secret is not.
 */
class PreviewAddress private constructor(val port: Int, val secret: String) {
    companion object {
        fun parse(field: String): PreviewAddress? {
            if (field == "-") return null
            val dot = field.indexOf('.')
            if (dot <= 0) return null
            val port = field.substring(0, dot).toIntOrNull() ?: return null
            if (port !in 1..65535) return null
            val rest = field.substring(dot + 1)
            if (rest.isEmpty() || !rest.all { it.isLetterOrDigit() || it == '-' || it == '_' }) return null
            return PreviewAddress(port, rest)
        }
    }
}

/**
 * A row's machine-readable half: `<token> <kind> <bytes> <preview> <absolute path>`, path last and the
 * only field allowed to contain a space. A failable parse on purpose: a row this build cannot read is
 * from a host older or newer than this app, and the honest thing is for it not to be tappable at all —
 * [MachineToolsSection] / [PanelScreen] asks for one of these before it draws a chevron.
 */
class ArtifactRef private constructor(
    val token: String,
    val kind: ArtifactKind,
    val bytes: Int?,
    val preview: PreviewAddress?,
    val path: String,
) {
    val name: String get() = path.split('/', '\\').last()

    /** The folder it sits in, on the machine — both separators, because the machine may be Windows. */
    val folder: String
        get() {
            val cut = path.lastIndexOfAny(charArrayOf('/', '\\'))
            if (cut < 0) return path
            val up = path.substring(0, cut)
            return up.ifEmpty { path.substring(0, cut + 1) }
        }

    val suffix: String
        get() {
            val n = name
            val dot = n.lastIndexOf('.')
            return if (dot <= 0) "" else n.substring(dot + 1).lowercase()
        }

    /** `/<secret>/~/<token>` — the host answers 302 to the file's real path, so the page that loads is
     *  at its own address and every relative url in it resolves from there. */
    fun previewPath(address: PreviewAddress): String {
        val escaped = Uri.encode(token, "-._~")
        return "/${address.secret}/~/$escaped"
    }

    companion object {
        fun parse(id: String?): ArtifactRef? {
            if (id.isNullOrEmpty()) return null
            val parts = id.split(" ", limit = 5)
            if (parts.size != 5) return null
            val kind = when (parts[1]) {
                "page" -> ArtifactKind.Page
                "image" -> ArtifactKind.Image
                "media" -> ArtifactKind.Media
                "text" -> ArtifactKind.Text
                "other" -> ArtifactKind.Other
                "gone" -> ArtifactKind.Gone
                else -> return null
            }
            val size = parts[2].toIntOrNull() ?: return null
            val where = parts[4]
            if (where.isEmpty()) return null
            // -1 is the host saying it could not stat the file, a different fact from a zero-byte file.
            return ArtifactRef(parts[0], kind, if (size < 0) null else size, PreviewAddress.parse(parts[3]), where)
        }
    }
}

/* ---------------------------------------------------------------------- helpers -- */

private fun facts(ref: ArtifactRef): String {
    val parts = mutableListOf<String>()
    if (ref.suffix.isNotEmpty()) parts.add(".${ref.suffix} file")
    ref.bytes?.let { parts.add(byteSize(it.toLong())) }
    return if (parts.isEmpty()) "Nothing more is known about it from here." else parts.joinToString("  ·  ")
}

private fun mediaWord(ref: ArtifactRef): String = when (ref.suffix) {
    "pdf" -> "PDF"
    "mp3", "m4a", "wav", "aac", "flac", "ogg" -> "recording"
    else -> "video"
}

private fun joinUrl(base: String, path: String): String {
    val b = base.trimEnd('/')
    val p = if (path.startsWith("/")) path else "/$path"
    return b + p
}

private fun displayHost(url: String): String = runCatching { URL(url).let { "localhost:${it.port}" } }.getOrDefault(url)

private sealed interface Fetched {
    class Ok(val bitmap: android.graphics.Bitmap) : Fetched
    class Bad(val why: String) : Fetched
}

/** The bytes, over the tunnel, as an ordinary HTTP response. Ephemeral, no cache: a prototype is being
 *  iterated on, and a cached image is somebody pressing Read again and seeing the version from before. */
private fun fetchBitmap(url: String): Fetched {
    return try {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 15_000
            useCaches = false
            setRequestProperty("Cache-Control", "no-store")
        }
        try {
            val code = connection.responseCode
            if (code != 200) return Fetched.Bad("The machine answered $code for this file.")
            val bitmap = connection.inputStream.use { BitmapFactory.decodeStream(it) }
                ?: return Fetched.Bad("This phone cannot draw that image. Open it in the browser view.")
            Fetched.Ok(bitmap)
        } finally {
            connection.disconnect()
        }
    } catch (t: Throwable) {
        Fetched.Bad(t.message ?: "That file could not be fetched.")
    }
}

/** `LaunchedEffect`, aliased so this file's many one-shot reactions read cleanly next to one another. */
@Composable
private fun LaunchedEffectKeyed(key: Any?, block: suspend () -> Unit) {
    androidx.compose.runtime.LaunchedEffect(key) { block() }
}

