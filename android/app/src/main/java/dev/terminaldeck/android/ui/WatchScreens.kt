package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import dev.terminaldeck.android.WatchController
import dev.terminaldeck.android.WatchView
import dev.terminaldeck.android.protocol.BrowserSurfaceWire

/**
 * The tab strip: the browser windows this machine says can be watched.
 *
 * Reached from Settings — *Watch browser* — exactly as on iOS, and drawn only when the machine
 * advertised `watch`, which a host offers to one of the owner's own devices and never to a guest.
 * Each row opens [WatchViewerScreen], which casts that one surface full screen.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WatchSurfacesScreen(
    view: WatchView,
    machineLabel: String,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onOpen: (BrowserSurfaceWire) -> Unit,
) {
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                    titleContentColor = MaterialTheme.colorScheme.onBackground,
                ),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back to settings",
                            tint = MaterialTheme.colorScheme.onBackground,
                        )
                    }
                },
                title = { Text("Watch browser", style = MaterialTheme.typography.titleMedium) },
                actions = { TextButton(onClick = onRefresh) { Text("Refresh") } },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
        ) {
            if (view.surfaces.isEmpty()) {
                Text(
                    text = if (view.asked) {
                        "No windows to watch on $machineLabel. Open a browser window there, or " +
                            "attach one to a session, and it will appear here."
                    } else {
                        // Not the same sentence: nothing has been asked yet, so "no windows" would
                        // be a claim about a machine that has not answered.
                        "Asking $machineLabel which windows it can show…"
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(20.dp),
                )
            } else {
                Column(
                    modifier = Modifier
                        .padding(16.dp)
                        .fillMaxWidth()
                        .background(
                            MaterialTheme.colorScheme.surface,
                            RoundedCornerShape(12.dp),
                        ),
                ) {
                    view.surfaces.forEachIndexed { index, surface ->
                        if (index > 0) {
                            HorizontalDivider(
                                color = MaterialTheme.colorScheme.outline,
                                modifier = Modifier.padding(start = 16.dp),
                            )
                        }
                        SurfaceRow(surface = surface, onClick = { onOpen(surface) })
                    }
                }
            }
        }
    }
}

@Composable
private fun SurfaceRow(surface: BrowserSurfaceWire, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 60.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Icon(
            if (surface.live) Icons.Filled.Sensors else Icons.Filled.Language,
            contentDescription = null,
            // Green only while that surface is genuinely being cast — the same rule the machine dots
            // on the switcher follow.
            tint = if (surface.live) {
                MaterialTheme.colorScheme.primary
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant
            },
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = surface.displayTitle,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (surface.url.isNotEmpty()) {
                Text(
                    text = surface.url,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
    }
}

/**
 * One surface, cast full screen, and the field that types into it.
 *
 * The canvas is [WatchSurfaceView] — a plain Android view, for the reasons its own header gives.
 * What this composable owns is the chrome around it: a title, a way back, and the one thing a phone
 * with no hardware keyboard needs to be able to do to a web page, which is put text in a field and
 * press Return.
 *
 * The cast starts when the canvas is measured and stops when this leaves, in a `DisposableEffect` —
 * a viewer that forgot the second half would leave a machine rendering JPEGs at a phone that has
 * navigated away, which costs the far end real work and this end real battery.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WatchViewerScreen(
    watch: WatchController,
    surface: BrowserSurfaceWire,
    onBack: () -> Unit,
) {
    var typing by remember { mutableStateOf("") }
    var canvas by remember { mutableStateOf<WatchSurfaceView?>(null) }

    Scaffold(
        containerColor = Color.Black,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                    titleContentColor = MaterialTheme.colorScheme.onBackground,
                ),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Stop watching",
                            tint = MaterialTheme.colorScheme.onBackground,
                        )
                    }
                },
                title = {
                    Text(
                        text = surface.displayTitle,
                        style = MaterialTheme.typography.titleMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
            )
        },
        bottomBar = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .background(MaterialTheme.colorScheme.background)
                    .imePadding()
                    .navigationBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                OutlinedTextField(
                    value = typing,
                    onValueChange = { typing = it },
                    singleLine = true,
                    placeholder = { Text("Type into the page") },
                    modifier = Modifier.weight(1f),
                )
                IconButton(
                    // Absent of a frame there is nothing to aim at, so the button is genuinely
                    // disabled rather than sending a gesture against a `seq` that names nothing.
                    enabled = typing.isNotEmpty() && canvas?.currentSeq() != null,
                    onClick = {
                        val seq = canvas?.currentSeq() ?: return@IconButton
                        watch.type(surface.window, seq, typing)
                        typing = ""
                    },
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.Send,
                        contentDescription = "Send into the page, then Return",
                        tint = MaterialTheme.colorScheme.primary,
                    )
                }
            }
        },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            AndroidView(
                factory = { context ->
                    WatchSurfaceView(context, watch, surface.window).also { canvas = it }
                },
                modifier = Modifier.fillMaxSize(),
                onRelease = { it.tearDown() },
            )
        }
    }

    // Belt and braces over `onRelease`: a process that tears the composition down without releasing
    // the view would otherwise leave the cast running on the machine.
    DisposableEffect(surface.window) {
        onDispose { canvas?.tearDown() }
    }
}
