package dev.terminaldeck.android.ui

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.FormatListNumbered
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import dev.terminaldeck.android.protocol.RecordedStep
import dev.terminaldeck.android.tunnel.TunnelView
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckQuietButton
import dev.terminaldeck.android.ui.kit.DeckSheetChrome
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * A page from the machine, on the phone.
 *
 * A `WebView` pointed at `http://127.0.0.1:<port>/`, where [dev.terminaldeck.android.tunnel.PortTunnel]
 * is listening. Not a custom URL scheme and not a string of HTML handed to `loadData`, and the
 * difference is the feature: on a real loopback origin the page gets same-origin `fetch`, real
 * cookies, service workers and — critically — **WebSockets**, which is what a dev server's hot reload
 * runs on. A scheme handler gets none of that, and a site served through one is a screenshot that
 * stops updating the moment you save a file.
 *
 * Transcribed from `ios/TerminalDeck/Screens/LocalhostBrowser.swift`.
 *
 * ## What this screen owes the user
 *
 * That the page on screen is live, or that it plainly is not. A tunnel can end for three reasons —
 * this phone closed it, the machine closed it, the connection dropped — and all three leave a
 * rendered page sitting there looking fine. So when a tunnel ends the page is **replaced** rather
 * than left up with a warning over it.
 *
 * ## The system back gesture belongs to this screen, not to the page
 *
 * The web view's own history is a button in the bottom bar. Handing the back gesture to page history
 * — which is what `WebView` does by default if you route the system back into `goBack()` — means the
 * single gesture everybody reaches for to leave a pushed screen quietly does something else. This is
 * the same mistake iOS made with `allowsBackForwardNavigationGestures` and fixed the same way: the
 * gesture leaves the screen, and going back a page is a control at the opposite end of it.
 *
 * ## The click-flow recorder, brought across
 *
 *   > *"you are giving record flow button in the windows side the server side it and you are not
 *   > giving that into the if they are browsing locally in this machine… if they both are capable for
 *   > a feature why don't they both have."*
 *
 * It records now, the same seven kinds of step the machine's recorder collects, into the same
 * [RecordedStep] rows. [PhoneRecordScript] is the page-side listener, [PhoneRecordBridge] carries its
 * facts back over an Android JS interface, and [PhoneClickFlow] validates every payload and builds the
 * flow — a **list of sentences about the site's own DOM**, which is the machine's whether the finger
 * was in this web view or over there. See those files for why a flow recorded here is a real one.
 *
 * ## What it still deliberately does not have
 *
 * **Inspect mode** — *tap an element to point at it and hand a sentence to an agent.* The recorder
 * observes; the inspector would have to *swallow* a tap and describe what was under it, which needs the
 * overlay and the sheet on top of the shared selector engine. It is **not built here**, and there is no
 * half of it: no button, no toggle. A control that entered a mode which did nothing would be worse than
 * its absence.
 */
// The recorder's bridge is exposed to the page by design — see PhoneRecordScript for why that is
// safe (every payload is re-validated on the Kotlin side and the URL is this app's, never the page's).
@SuppressLint("JavascriptInterface")
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LocalhostBrowser(view: TunnelView, onClose: () -> Unit) {
    val colors = DeckTheme.colors
    var web by remember { mutableStateOf<WebView?>(null) }
    var canGoBack by remember { mutableStateOf(false) }
    var address by remember { mutableStateOf(view.url.orEmpty()) }

    // The click-flow recorder, for this phone's own browsing — the same steps the machine's recorder
    // collects. The store is per-screen: a flow belongs to the sitting it was recorded in. A payload
    // arrives on a WebView binder thread, so the bridge marshals to this handler before touching the
    // store or the Compose state it drives.
    val tab = view.port.toString()
    val flow = remember { PhoneClickFlow() }
    val mainHandler = remember { Handler(Looper.getMainLooper()) }
    var recording by remember { mutableStateOf(false) }
    var steps by remember { mutableStateOf<List<RecordedStep>>(emptyList()) }
    var showSteps by remember { mutableStateOf(false) }
    val bridge = remember { PhoneRecordBridge(mainHandler, flow, tab) { steps = flow.steps(tab) } }

    // The gesture leaves the screen. See the header.
    BackHandler(onBack = onClose)

    /*
     * The tunnel is closed when this screen leaves, whichever way it leaves.
     *
     * Not on the Close button alone: a back gesture, a process the system decides to trim, and a
     * machine being switched underneath all take this composable out without pressing anything — and
     * every one of them would otherwise leave a socket open on somebody's computer for a page nobody
     * is looking at.
     */
    DisposableEffect(Unit) {
        onDispose {
            web?.let {
                it.stopLoading()
                it.destroy()
            }
        }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            DeckTopBar(
                title = "localhost:${view.port}",
                subtitle = if (view.streams == 1) "1 connection" else "${view.streams} connections",
                onBack = onClose,
            )
        },
        bottomBar = {
            if (view.live) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(horizontal = Space.x2, vertical = Space.x1),
                ) {
                    IconButton(enabled = canGoBack, onClick = { web?.goBack() }) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back a page",
                            tint = if (canGoBack) colors.secondary else colors.faint,
                        )
                    }
                    Text(
                        text = address,
                        style = DeckType.mono,
                        color = colors.faint,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f).padding(horizontal = Space.x2),
                    )
                    // Record the click flow — the same recorder the machine window has. Red while it
                    // runs; the page shows its own RECORDING badge so the mode is never hidden.
                    IconButton(onClick = {
                        recording = !recording
                        if (recording) {
                            flow.start(tab)
                            web?.evaluateJavascript(PhoneRecordScript.ENABLE, null)
                        } else {
                            flow.stop(tab)
                            web?.evaluateJavascript(PhoneRecordScript.DISABLE, null)
                        }
                        steps = flow.steps(tab)
                    }) {
                        Icon(
                            if (recording) Icons.Filled.StopCircle else Icons.Filled.FiberManualRecord,
                            contentDescription = if (recording) "Stop recording" else "Record the click flow",
                            tint = if (recording) colors.critical else colors.secondary,
                        )
                    }
                    // The recorded flow, once there is one to read.
                    if (steps.isNotEmpty()) {
                        IconButton(onClick = { showSteps = true }) {
                            Icon(
                                Icons.Filled.FormatListNumbered,
                                contentDescription = "Recorded steps",
                                tint = colors.secondary,
                            )
                        }
                    }
                    IconButton(onClick = { web?.reload() }) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Reload", tint = colors.secondary)
                    }
                }
            }
        },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                view.detail != null -> Ended(view.detail, onClose)
                view.url == null -> Opening(view.port)
                else -> AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { context ->
                        makeWebView(context).also { created ->
                            // The recorder's bridge, and the page-side script injected on every load —
                            // the guard at the top of the script makes a re-injection a no-op. The
                            // interface is visible to the page, which is safe: every payload is
                            // re-validated on the Kotlin side and the URL is this app's, never the page's.
                            created.addJavascriptInterface(bridge, PhoneRecordScript.BRIDGE)
                            created.webViewClient = object : WebViewClient() {
                                override fun onPageStarted(page: WebView?, url: String?, favicon: Bitmap?) {
                                    page?.evaluateJavascript(PhoneRecordScript.source, null)
                                }

                                override fun onPageFinished(page: WebView?, url: String?) {
                                    page?.evaluateJavascript(PhoneRecordScript.source, null)
                                    canGoBack = page?.canGoBack() == true
                                    url?.let {
                                        address = it
                                        // The recorder's URL is this app's own view of the page, never
                                        // the page's claim — a navigation is a step, and one it cannot forge.
                                        bridge.pageUrl = it
                                        flow.at(tab, it)
                                    }
                                    // A recording carries across navigations: re-arm the fresh document.
                                    if (recording) page?.evaluateJavascript(PhoneRecordScript.ENABLE, null)
                                    steps = flow.steps(tab)
                                }
                            }
                            web = created
                            created.loadUrl(view.url)
                        }
                    },
                )
            }
        }
    }

    // The recorded flow — the same rows the machine window draws, from the same RecordedStep.
    if (showSteps) {
        RecordedFlowSheet(
            steps = steps,
            onClear = {
                flow.clear(tab)
                steps = flow.steps(tab)
                showSteps = false
            },
            onDismiss = { showSteps = false },
        )
    }
}

/**
 * The recorded click flow, in the same rows the machine window's recorder draws. `Clear` throws the
 * flow away and leaves the recorder running if it was — *start again from here*, what somebody does
 * after a false start.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RecordedFlowSheet(
    steps: List<RecordedStep>,
    onClear: () -> Unit,
    onDismiss: () -> Unit,
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
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .padding(top = Space.x5, bottom = Space.x8),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text("Click flow", style = DeckType.title, color = colors.primary, modifier = Modifier.weight(1f))
                IconButton(onClick = onClear) {
                    Icon(Icons.Filled.DeleteOutline, contentDescription = "Clear the flow", tint = colors.critical)
                }
            }
            DeckFootnote("The steps recorded on this page — the same list the machine's recorder builds.")
            Spacer(Modifier.height(Space.x2))
            DeckGroup {
                steps.forEachIndexed { index, step ->
                    if (index > 0) DeckDivider(startIndent = Space.card)
                    FlowStepRow(step)
                }
            }
        }
    }
}

@Composable
private fun FlowStepRow(step: RecordedStep) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier.fillMaxWidth().padding(Space.card),
    ) {
        Text(
            text = step.kind,
            style = DeckType.monoSmall,
            color = colors.secondary,
            modifier = Modifier
                .clip(Radius.small)
                .background(colors.surfaceHigh)
                .padding(horizontal = Space.x15, vertical = Space.half),
        )
        Spacer(Modifier.width(Space.x2))
        Column(modifier = Modifier.weight(1f)) {
            step.detail?.let { Text(it, style = DeckType.body, color = colors.primary) }
            step.value?.let {
                Text(it, style = DeckType.caption, color = colors.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            step.selector?.let {
                Text(it, style = DeckType.mono, color = colors.faint, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/**
 * The web view, configured for a real dev server rather than for a document.
 *
 * Every one of these is load-bearing for the page being *usable* rather than merely rendered, and
 * none of them widens what the page can reach: it is served from this phone's own loopback by a
 * tunnel that exists only while this screen is up.
 */
@SuppressLint("SetJavaScriptEnabled")
private fun makeWebView(context: android.content.Context): WebView = WebView(context).apply {
    layoutParams = ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
    )
    settings.apply {
        // A dev server's page is an application. Without this the whole feature is a screenshot.
        javaScriptEnabled = true
        domStorageEnabled = true
        // The page is served over plain http from 127.0.0.1 and its own assets are the same origin;
        // this is the default on modern Android and is stated so a future default cannot quietly
        // break a page that was working.
        mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
        // A dev server writes a viewport meta tag and means it. Without these two the page is
        // rendered at desktop width and scaled down, which is the "it looks wrong on the phone"
        // complaint this screen exists to answer.
        useWideViewPort = true
        loadWithOverviewMode = true
        builtInZoomControls = true
        displayZoomControls = false
        // Deliberately **not** `allowFileAccess` or `allowContentAccess`: nothing this page loads
        // should ever come off this phone's disk, and a dev server has no reason to ask.
        allowFileAccess = false
        allowContentAccess = false
    }
}

@Composable
private fun Opening(port: Int) {
    val colors = DeckTheme.colors
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxSize().padding(Space.x8),
    ) {
        Spacer(Modifier.height(Space.x16))
        CircularProgressIndicator(color = colors.accent, modifier = Modifier.size(28.dp))
        Spacer(Modifier.height(Space.x4))
        Text(
            text = "Opening port $port on the machine…",
            style = DeckType.body,
            color = colors.secondary,
        )
    }
}

/**
 * The tunnel ended, and the page is gone with it.
 *
 * The machine's own sentence, verbatim: the same frame answers a refusal, a teardown this phone
 * asked for and a Stop pressed at the desk, because to this side they are one event — the page it
 * was showing has nothing behind it any more.
 */
@Composable
private fun Ended(detail: String, onClose: () -> Unit) {
    val colors = DeckTheme.colors
    Column(modifier = Modifier.fillMaxSize().padding(Space.screen)) {
        Spacer(Modifier.height(Space.x12))
        DeckGroup {
            Text(
                text = detail,
                style = DeckType.body,
                color = colors.secondary,
                modifier = Modifier.padding(Space.card),
            )
        }
        Spacer(Modifier.height(Space.x5))
        DeckQuietButton(label = "Close", onClick = onClose)
    }
}
