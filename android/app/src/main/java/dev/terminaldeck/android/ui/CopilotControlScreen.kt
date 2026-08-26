package dev.terminaldeck.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.terminaldeck.android.ActionNotice
import dev.terminaldeck.android.CopilotSetupBook
import dev.terminaldeck.android.CopilotView
import dev.terminaldeck.android.ServerSettingsView
import dev.terminaldeck.android.protocol.CopilotAccess
import dev.terminaldeck.android.protocol.CopilotDesk
import dev.terminaldeck.android.protocol.CopilotGrantWire
import dev.terminaldeck.android.protocol.CopilotStateReport
import dev.terminaldeck.android.protocol.RemoteSessionView
import dev.terminaldeck.android.protocol.ServerSettingKey
import dev.terminaldeck.android.protocol.ServerSettingWire
import dev.terminaldeck.android.protocol.ServerSettingsLabels
import dev.terminaldeck.android.ui.kit.DeckChip
import dev.terminaldeck.android.ui.kit.DeckDivider
import dev.terminaldeck.android.ui.kit.DeckFootnote
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.DeckPrimaryButton
import dev.terminaldeck.android.ui.kit.DeckRow
import dev.terminaldeck.android.ui.kit.DeckTopBar
import dev.terminaldeck.android.ui.kit.InfoDot
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Radius
import dev.terminaldeck.android.ui.theme.Space

/**
 * The copilot's controls, on the phone — every setting and switch about the copilot on one machine,
 * reached from the gear in the conversation's top bar. A transcription of
 * `ios/TerminalDeck/Screens/CopilotControlView.swift`.
 *
 * Asad, on what the gear opens: *"all the control about copilot, all the settings of the copilot,
 * and everything related to copilot that we need to have as options and control and settings."*
 *
 * ## The panels are chosen, not always drawn
 *
 * [CopilotControl.panels] decides which sections a machine gets, from three questions in order: can
 * this section's controls act on this machine at all, has the machine offered the capability, and is
 * there anything in it. A desktop's grant card over a server, a Start on a phone that may only watch,
 * an agent chooser over a copilot the setting has no bearing on — none of those crash, none look
 * like a fault, and each is a control that refuses on every press. So each is gated away.
 *
 * The files and routines cards are **nav rows** here, each pushing to its own screen — the list is a
 * screen's worth on a phone and a card's worth on the Mac.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CopilotControlScreen(
    view: CopilotView,
    hostId: String,
    machineLabel: String,
    hostKind: String?,
    serverSettings: ServerSettingsView?,
    sessions: List<RemoteSessionView>,
    settingsOffered: Boolean,
    devicesOffered: Boolean,
    filesOffered: Boolean,
    routinesOffered: Boolean,
    canPickFolders: Boolean,
    canCreateSessions: Boolean,
    canCloseSessions: Boolean,
    onBack: () -> Unit,
    onPickFolder: () -> Unit,
    onFiles: () -> Unit,
    onRoutines: () -> Unit,
    onDevices: () -> Unit,
    onAbout: () -> Unit,
    onOpenSession: (String) -> Unit,
    onEndSession: (String) -> Unit,
    onStartSession: (String?) -> Unit,
    onStart: () -> Unit,
    onCancel: () -> Unit,
    onStopRun: () -> Unit,
    onApplyProvider: (String) -> Unit,
    onEnsureServerSettings: () -> Unit,
    onEnsureDevices: () -> Unit,
    onLoadFiles: () -> Unit,
    onLoadRoutines: () -> Unit,
) {
    val colors = DeckTheme.colors
    val context = LocalContext.current

    // Primed in MainActivity.onCreate, like AppearanceStore, so these already have their value on
    // the frame this draws. Each read subscribes the screen to a later write — flipping the switch
    // repaints the row that was flipped and nothing else.
    val folder = CopilotSetupBook.folder(hostId)
    val armed = CopilotSetupBook.isArmed(hostId)
    val setUp = CopilotSetupBook.isSetUp(hostId)

    val onAServer = hostKind == "headless"
    val noun = if (onAServer) "server" else "machine"
    val copilotSession = sessions.firstOrNull { CopilotSetupBook.sameFolder(it.cwd, folder) }

    val reading = CopilotControl.Reading(
        onAServer = onAServer,
        access = view.access,
        grant = view.grant,
        setUp = setUp,
        canPickFolders = canPickFolders,
        settingsOffered = settingsOffered,
        devicesOffered = devicesOffered,
        filesOffered = filesOffered,
        routinesOffered = routinesOffered,
        hasCopilotSession = copilotSession != null,
        hasRun = view.state?.hasRun == true,
        waiting = view.waitingCount,
    )

    // The reads this screen is the only one that needs. Idempotent — each controller refuses a
    // second read on the same connection — and asked again when a capability turns up, because a
    // cold start can arrive before the welcome names it.
    LaunchedEffect(settingsOffered) { if (settingsOffered) onEnsureServerSettings() }
    LaunchedEffect(devicesOffered) { if (devicesOffered) onEnsureDevices() }
    LaunchedEffect(filesOffered) { if (filesOffered) onLoadFiles() }
    LaunchedEffect(routinesOffered) { if (routinesOffered) onLoadRoutines() }

    Scaffold(
        containerColor = colors.background,
        topBar = { DeckTopBar(title = "Copilot", subtitle = machineLabel, onBack = onBack) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding())
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .padding(bottom = Space.x8),
        ) {
            for (panel in CopilotControl.panels(reading)) {
                when (panel) {
                    CopilotControl.Panel.WhenYouOpen -> WhenYouOpenPanel(
                        onAServer = onAServer,
                        noun = noun,
                        folder = folder,
                        armed = armed,
                        setUp = setUp,
                        canPickFolders = canPickFolders,
                        canStartSession = onAServer && copilotSession == null && canCreateSessions,
                        onPickFolder = onPickFolder,
                        onToggleArmed = { CopilotSetupBook.setStartOnOpen(context, !armed, hostId) },
                        onForget = { CopilotSetupBook.forget(context, hostId) },
                        onStartSession = { onStartSession(folder) },
                    )

                    CopilotControl.Panel.Agent -> AgentPanel(
                        row = serverSettings?.rows?.firstOrNull { it.known == ServerSettingKey.DefaultProvider },
                        busy = serverSettings?.busy == ServerSettingKey.DefaultProvider,
                        notice = serverSettings?.notice,
                        onApply = onApplyProvider,
                    )

                    CopilotControl.Panel.Session -> copilotSession?.let { running ->
                        SessionPanel(
                            session = running,
                            canClose = canCloseSessions,
                            noun = noun,
                            onOpen = { onOpenSession(running.id) },
                            onEnd = { onEndSession(running.id) },
                        )
                    }

                    CopilotControl.Panel.Permissions -> PermissionsPanel(grant = reading.grant, waiting = reading.waiting)

                    CopilotControl.Panel.Run -> RunPanel(
                        view = view,
                        noun = noun,
                        onStart = onStart,
                        onCancel = onCancel,
                        onStopRun = onStopRun,
                    )

                    CopilotControl.Panel.Files -> NavRowPanel(
                        caption = "Its files",
                        about = "the copilot's files",
                        says = "Everything the copilot reads before it answers — read off the " +
                            "machine's disk each time. Two the app writes itself; the rest are " +
                            "yours, its instructions, the folder's own, and everything it remembers.",
                        title = "Its files",
                        detail = "Its instructions, its memory, the folder's own.",
                        icon = Icons.AutoMirrored.Filled.InsertDriveFile,
                        onClick = onFiles,
                    )

                    CopilotControl.Panel.Routines -> NavRowPanel(
                        caption = "Routines",
                        about = "the copilot's routines",
                        says = "Saved instructions this machine runs on its own — a trigger, a " +
                            "folder and a prompt each. Run one now, hold it, let it run again, read " +
                            "it, or delete it. They are made and edited on the machine itself.",
                        title = "Routines",
                        detail = "What it runs on its own — overnight, on a schedule.",
                        icon = Icons.Filled.Notifications,
                        onClick = onRoutines,
                    )

                    CopilotControl.Panel.Devices -> NavRowPanel(
                        caption = "Who else reaches it",
                        about = null,
                        says = null,
                        title = "Devices",
                        detail = "Every device signed in to this $noun.",
                        icon = Icons.Filled.PhoneAndroid,
                        onClick = onDevices,
                    )

                    CopilotControl.Panel.About -> NavRowPanel(
                        caption = "Reference",
                        about = null,
                        says = null,
                        title = "What a copilot is",
                        detail = "What it reaches, and what it may do without asking.",
                        icon = Icons.Filled.Info,
                        onClick = onAbout,
                    )
                }
            }
        }
    }
}

/* ------------------------------------------------------------------------ panels -- */

/**
 * What the tab does when it opens — the setup, and on a server it is the whole of it.
 *
 * Asad: *"We will first of all do the setup of a copilot just like we do on desktop application, and
 * then it will be always opening in the same folder."* It is **not** a flow and not a toll on the
 * way in: *"directly land into some session, not to a selection and something on the page."* The tab
 * starts, records the folder it landed in, and this is where that folder is shown and changed.
 */
@Composable
private fun WhenYouOpenPanel(
    onAServer: Boolean,
    noun: String,
    folder: String?,
    armed: Boolean,
    setUp: Boolean,
    canPickFolders: Boolean,
    canStartSession: Boolean,
    onPickFolder: () -> Unit,
    onToggleArmed: () -> Unit,
    onForget: () -> Unit,
    onStartSession: () -> Unit,
) {
    val colors = DeckTheme.colors
    CopilotCaption(
        "When you open this tab",
        about = "the copilot's setup",
        says = "Where the copilot works, and whether this tab starts one for you. Both are this " +
            "phone's, kept for this machine only. The folder is filled in from the first session " +
            "this tab starts, and can be changed here. Its instructions are under Its files.",
    )
    DeckGroup {
        if (onAServer) {
            // A server's copilot is a session, so its folder is one this phone genuinely chooses.
            ValueRow(
                title = "Working folder",
                value = when {
                    folder != null -> folder
                    canPickFolders -> "Set from the first session it starts"
                    else -> "This $noun is not sharing its folders"
                },
                mono = folder != null,
                chevron = canPickFolders,
                onClick = if (canPickFolders) onPickFolder else null,
            )
            DeckDivider(startIndent = Space.card)
        }
        // On until somebody moves it — an absent record means yes — so this is the off-ramp, the one
        // place to say *do not spend money on this machine when I open this tab*.
        StartOnOpenRow(on = armed, what = if (onAServer) "a session" else "a run", noun = noun, onToggle = onToggleArmed)
        if (setUp) {
            DeckDivider(startIndent = Space.card)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().clickable(onClick = onForget).padding(horizontal = Space.card, vertical = Space.x3),
            ) {
                Text("Forget this setup", style = DeckType.body, color = colors.critical)
            }
        }
    }
    if (canStartSession) {
        Spacer(Modifier.height(Space.x3))
        DeckPrimaryButton(label = "Start a session", onClick = onStartSession)
        DeckFootnote("Runs on the $noun · spends money. The folder is filled in from where it lands.")
    }
}

/** The gate on the one behaviour Asad overruled an earlier decision to get: once a folder is chosen,
 *  starting a session there is what he asked the tab to do. A filled check for on. */
@Composable
private fun StartOnOpenRow(on: Boolean, what: String, noun: String, onToggle: () -> Unit) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(horizontal = Space.card, vertical = Space.x3),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text("Start $what if none is running", style = DeckType.body, color = colors.primary)
            Text("Spends money on this $noun", style = DeckType.caption, color = colors.faint)
        }
        Spacer(Modifier.width(Space.x2))
        Icon(
            imageVector = if (on) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
            contentDescription = if (on) "On" else "Off",
            tint = if (on) colors.accent else colors.faint,
            modifier = Modifier.size(22.dp),
        )
    }
}

/**
 * Which agent the copilot is, on a server — `agents.defaultProvider`, the same value Settings calls
 * the default coding tool but asked here as *which agent your copilot is*, because on a server the
 * copilot **is** a session started with this setting.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AgentPanel(row: ServerSettingWire?, busy: Boolean, notice: ActionNotice?, onApply: (String) -> Unit) {
    if (row == null) return
    val colors = DeckTheme.colors
    CopilotCaption(
        "The agent",
        about = "the copilot's agent",
        says = "This server owns this one, not this phone — every device that reaches it sees the " +
            "same choice, and it is the value Settings calls the default coding tool. It decides " +
            "what a session started from here has in it.",
    )
    DeckGroup {
        Column(modifier = Modifier.padding(horizontal = Space.card, vertical = Space.x3)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text("What a new session runs", style = DeckType.body, color = colors.primary)
                Spacer(Modifier.weight(1f))
                if (busy) Text("Working…", style = DeckType.value, color = colors.faint)
            }
            Spacer(Modifier.height(Space.x2))
            val ids = row.options?.takeIf { it.isNotEmpty() } ?: listOf(row.value)
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(Space.x2),
                verticalArrangement = Arrangement.spacedBy(Space.x2),
            ) {
                for (id in ids) {
                    val on = id == row.value
                    DeckChip(
                        label = ServerSettingsLabels.provider(id),
                        selected = on,
                        // The current value and any press while busy are inert; only a different id
                        // is a real choice.
                        enabled = !busy && !on,
                        onClick = { onApply(id) },
                    )
                }
            }
        }
    }
    notice?.let {
        Text(
            text = it.text,
            style = DeckType.caption,
            color = if (it.ok) colors.secondary else colors.critical,
            modifier = Modifier.fillMaxWidth().padding(start = Space.captionIndent, end = Space.captionIndent, top = Space.x2),
        )
    }
}

/** What can be done to the copilot's own session on a server: open it, and end it. Both verbs the
 *  app already sends. */
@Composable
private fun SessionPanel(session: RemoteSessionView, canClose: Boolean, noun: String, onOpen: () -> Unit, onEnd: () -> Unit) {
    CopilotCaption("The conversation", about = null, says = null)
    DeckGroup {
        DeckRow(
            title = "Open it",
            subtitle = "${ServerSettingsLabels.provider(session.provider)} in ${folderName(session.cwd)}.",
            icon = Icons.Filled.Terminal,
            onClick = onOpen,
        )
        if (canClose) {
            DeckDivider(startIndent = Space.card)
            DeckRow(
                title = "End it",
                subtitle = "The next visit starts a new one.",
                icon = Icons.Filled.Close,
                titleColor = DeckTheme.colors.critical,
                onClick = onEnd,
            )
        }
    }
}

/**
 * What this phone may do with this machine's copilot. The three tiers are **readings, not switches**:
 * pairing as one of his own *is* the copilot's authorisation, so nothing on this phone can widen its
 * own grant, and a toggle here would be a control that only ever refuses.
 */
@Composable
private fun PermissionsPanel(grant: CopilotGrantWire, waiting: Int) {
    CopilotCaption(
        "What this phone may do",
        about = "the copilot's grant",
        says = "Set by how this phone was paired, at the machine — one of your own devices gets all " +
            "three, a guest is never offered the copilot at all. Nothing here can widen it.",
    )
    DeckGroup {
        TierRow("Watch it work", on = grant.read || grant.act || grant.alter)
        DeckDivider(startIndent = Space.card)
        TierRow("Ask it to work", on = grant.act)
        DeckDivider(startIndent = Space.card)
        TierRow("Answer its confirmations", on = grant.alter)
    }
    if (waiting > 0) {
        DeckFootnote(
            if (waiting == 1) "1 confirmation is waiting. Answer it from the conversation."
            else "$waiting confirmations are waiting. Answer them from the conversation.",
        )
    }
}

@Composable
private fun TierRow(title: String, on: Boolean) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = Space.card, vertical = Space.x3),
    ) {
        Text(title, style = DeckType.body, color = colors.primary, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(Space.x2))
        Icon(
            imageVector = if (on) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
            contentDescription = if (on) "Allowed" else "Not allowed",
            tint = if (on) colors.positive else colors.faint,
            modifier = Modifier.size(20.dp),
        )
    }
}

/**
 * The run itself: what the machine says about it, and the three verbs that reach it. The desk and
 * this phone's run are named separately and always have to be — they move independently, and folding
 * them reads as a contradiction. Start is drawn only when the machine has said a run *can* start.
 */
@Composable
private fun RunPanel(view: CopilotView, noun: String, onStart: () -> Unit, onCancel: () -> Unit, onStopRun: () -> Unit) {
    val colors = DeckTheme.colors
    CopilotCaption("This phone's run", about = null, says = null)
    DeckGroup {
        val state = view.state
        if (state == null) {
            ValueRow(title = "State", value = "That $noun has not said yet", mono = false, chevron = false, onClick = null)
        } else {
            Column(modifier = Modifier.padding(horizontal = Space.card, vertical = Space.x3), verticalArrangement = Arrangement.spacedBy(Space.x2)) {
                Row(horizontalArrangement = Arrangement.spacedBy(Space.x2), verticalAlignment = Alignment.CenterVertically) {
                    RunStateChip(
                        subject = noun.replaceFirstChar { it.uppercase() },
                        word = CopilotControl.deskWord(state),
                        tone = when (state.desk) {
                            CopilotDesk.Running -> colors.positive
                            CopilotDesk.Starting -> colors.accent
                            else -> colors.faint
                        },
                    )
                    RunStateChip(
                        subject = "This phone",
                        word = if (state.hasRun) "running" else "none",
                        tone = if (state.hasRun) colors.positive else colors.faint,
                    )
                }
                CopilotControl.accountLine(state)?.let {
                    Text(it, style = DeckType.mono, color = colors.faint)
                }
                CopilotControl.catalogueLine(state)?.let {
                    Text(it, style = DeckType.caption, color = colors.faint)
                }
                if (!state.available) {
                    state.reason?.takeIf { it.isNotEmpty() }?.let {
                        Text(it, style = DeckType.caption, color = colors.warning)
                    }
                }
            }
        }

        if (view.access == CopilotAccess.Direct) {
            if (view.state?.hasRun == true) {
                DeckDivider(startIndent = Space.card)
                DeckRow(title = "Interrupt this turn", subtitle = "Stops what it is doing now.", icon = Icons.Filled.Close, onClick = onCancel)
                DeckDivider(startIndent = Space.card)
                DeckRow(
                    title = "Stop this phone's copilot",
                    subtitle = "Ends this phone's run. The one at the $noun keeps going.",
                    icon = Icons.Filled.Close,
                    titleColor = colors.critical,
                    onClick = onStopRun,
                )
            } else if (view.state?.available == true) {
                DeckDivider(startIndent = Space.card)
                DeckRow(title = "Start it", subtitle = "Runs on the $noun · spends money", icon = Icons.Filled.PlayArrow, onClick = onStart)
            }
        }
    }
}

/** A chip naming its subject before its state, so the desk and this phone's run cannot read as a
 *  contradiction. */
@Composable
private fun RunStateChip(subject: String, word: String, tone: Color) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(Radius.sm))
            .background(colors.surfaceHigh)
            .padding(horizontal = Space.x2, vertical = Space.x1),
    ) {
        Text(subject, style = DeckType.caption, color = colors.faint)
        Spacer(Modifier.width(Space.x15))
        Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(tone))
        Spacer(Modifier.width(Space.x15))
        Text(word, style = DeckType.caption, color = colors.primary)
    }
}

/* ------------------------------------------------------------------------ chrome -- */

/** A nav row in its own captioned card — the shape the files, routines, devices and about entries
 *  share. */
@Composable
private fun NavRowPanel(
    caption: String,
    about: String?,
    says: String?,
    title: String,
    detail: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onClick: () -> Unit,
) {
    CopilotCaption(caption, about = about, says = says)
    DeckGroup {
        DeckRow(title = title, subtitle = detail, icon = icon, onClick = onClick)
    }
}

/** The caption over a card, with the one place a longer explanation is allowed to live beside it. */
@Composable
private fun CopilotCaption(text: String, about: String?, says: String?) {
    if (about != null && says != null) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            SectionCaption(text, modifier = Modifier.weight(1f, fill = false))
            InfoDot(about = about, text = says)
        }
    } else {
        SectionCaption(text)
    }
}

/** A name and what it currently is, not pressable unless it leads somewhere. */
@Composable
private fun ValueRow(title: String, value: String, mono: Boolean, chevron: Boolean, onClick: (() -> Unit)?) {
    val colors = DeckTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = Space.card, vertical = Space.x3),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = DeckType.body, color = colors.primary)
            Text(
                text = value,
                style = if (mono) DeckType.mono else DeckType.caption,
                color = colors.faint,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (chevron) {
            Spacer(Modifier.width(Space.x2))
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.faint,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

/**
 * Which panels a machine gets, and the sentences that are chosen rather than printed. Pure for the
 * reason iOS's `CopilotControl` is: every way this can be wrong is silent, and most need a machine
 * of a particular kind to be visible at all. A transcription of that enum's `panels`, `deskWord`,
 * `accountLine` and `catalogueLine`.
 */
object CopilotControl {

    enum class Panel { WhenYouOpen, Agent, Session, Permissions, Run, Files, Routines, Devices, About }

    /** Everything the sections are chosen from — a pure value, not a link, so every decision can be
     *  walked without a socket, a paired machine and a running agent. */
    data class Reading(
        val onAServer: Boolean,
        val access: CopilotAccess,
        val grant: CopilotGrantWire,
        val setUp: Boolean,
        val canPickFolders: Boolean,
        val settingsOffered: Boolean,
        val devicesOffered: Boolean,
        val filesOffered: Boolean,
        val routinesOffered: Boolean,
        val hasCopilotSession: Boolean,
        val hasRun: Boolean,
        val waiting: Int,
    )

    /**
     * Which sections this machine gets. Faithful to iOS's gating, with one deliberate difference:
     * **history is not here.** The Mac's card has *Everything it did* and *Sessions it started*, and
     * on Android both already live in the conversation's own top bar — a second copy on the control
     * screen would be two doors to one room.
     */
    fun panels(r: Reading): List<Panel> {
        val out = mutableListOf<Panel>()
        if (r.onAServer || r.access == CopilotAccess.Direct) out += Panel.WhenYouOpen
        if (r.onAServer && r.settingsOffered) out += Panel.Agent
        if (r.onAServer && r.hasCopilotSession) out += Panel.Session
        if (!r.onAServer && r.access != CopilotAccess.NotOffered) out += Panel.Permissions
        if (!r.onAServer && (r.access == CopilotAccess.Watch || r.access == CopilotAccess.Direct)) {
            out += Panel.Run
        }
        // Neither card asks about the machine's kind: a headless server that grows a copilot layer
        // serves `copilot.files` on the same terms a Mac does, and `routines` is a capability of its
        // own precisely because a machine can run routines without serving a conversation.
        if (r.filesOffered) out += Panel.Files
        if (r.routinesOffered) out += Panel.Routines
        if (r.devicesOffered) out += Panel.Devices
        out += Panel.About
        return out
    }

    /** The copilot at the machine, in one word. Prints an unrecognised word from a newer desktop
     *  rather than calling it stopped, which is more honest. */
    fun deskWord(state: CopilotStateReport): String = when (state.desk) {
        CopilotDesk.Running -> "running"
        CopilotDesk.Starting -> "starting"
        CopilotDesk.Stopped -> "stopped"
        CopilotDesk.Unknown -> "unknown"
    }

    /** The account, and whether it is signed in — three answers, because null is *not asked* and
     *  drawing that as signed out would send somebody to fix an account that is fine. */
    fun accountLine(state: CopilotStateReport): String? {
        val profile = state.profile?.takeIf { it.isNotEmpty() }
            ?: return if (state.signedIn == false) "Signed out" else null
        return when (state.signedIn) {
            true -> profile
            false -> "$profile — signed out"
            null -> profile
        }
    }

    /** What a turn costs it before anybody says anything — the machine's own two numbers and nothing
     *  derived. The tool *list* is never copied into this app: it moves too fast to be right in a
     *  lane that is not the desktop's. */
    fun catalogueLine(state: CopilotStateReport): String? {
        if (state.tools <= 0 && state.turnTokens <= 0) return null
        val tools = if (state.tools == 1) "1 tool" else "${state.tools} tools"
        if (state.turnTokens <= 0) return tools
        return "$tools · ${state.turnTokens} tokens a turn"
    }
}
