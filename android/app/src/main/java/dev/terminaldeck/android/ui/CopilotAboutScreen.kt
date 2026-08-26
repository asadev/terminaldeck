package dev.terminaldeck.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import dev.terminaldeck.android.CopilotView
import dev.terminaldeck.android.protocol.CopilotAccess
import dev.terminaldeck.android.protocol.CopilotGrantWire
import dev.terminaldeck.android.ui.kit.DeckGroup
import dev.terminaldeck.android.ui.kit.SectionCaption
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.DeckType
import dev.terminaldeck.android.ui.theme.Space

/**
 * What a copilot is — the reference page, at the foot of the copilot's controls. A transcription of
 * `ios/TerminalDeck/Screens/AboutCopilotView.swift`.
 *
 * Asad drew the line between this and the control screen: *"When I said add a button which will be
 * all about copilot… it doesn't mean information about copilot. I meant all the control about
 * copilot, all the settings."* So the controls are the gear, and this is the last row on them, under
 * *Reference*. Nothing here was rewritten — every passage mirrors the desktop's own source. A person
 * who wants to know what a copilot is finds it where a person would look; nobody operating one meets
 * it first.
 *
 * ## A screen, not a bigger ⓘ
 *
 * A popover is the right size for one question and four sentences. It is the wrong size for *what is
 * a copilot at all*, which is a screen's worth — what it is, what it reaches, what it may do without
 * asking, who it is shared with, and the two questions that only have an answer once you know which
 * kind of machine you are pointed at.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CopilotAboutScreen(
    view: CopilotView,
    machineLabel: String,
    machineNoun: String,
    hostKind: String?,
    onBack: () -> Unit,
) {
    val colors = DeckTheme.colors
    val reading = CopilotAbout.Reading(
        isServer = hostKind == "headless",
        noun = if (hostKind == "headless") "server" else machineNoun,
        access = view.access,
        grant = view.grant,
        tools = view.state?.tools?.takeIf { it > 0 },
        turnTokens = view.state?.turnTokens?.takeIf { it > 0 },
    )

    Scaffold(
        containerColor = colors.background,
        topBar = { dev.terminaldeck.android.ui.kit.DeckTopBar(title = "What a copilot is", subtitle = machineLabel, onBack = onBack) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding())
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.screen)
                .padding(bottom = Space.x8),
        ) {
            for (passage in CopilotAbout.passages(reading)) {
                SectionCaption(passage.caption)
                DeckGroup {
                    Text(
                        text = passage.body,
                        style = DeckType.footnote,
                        color = colors.secondary,
                        modifier = Modifier.padding(Space.card),
                    )
                }
                Spacer(Modifier.height(Space.x2))
            }
        }
    }
}

/**
 * The passages, chosen from a machine's kind and a phone's grant. Pure for the reason iOS's
 * `AboutCopilot` is: the decisions are about a machine's kind and a phone's grant, and a pure value
 * is what lets each be walked without a socket, a paired machine and a running agent.
 */
object CopilotAbout {

    private const val BRAND = "Terminal Deck"

    data class Reading(
        val isServer: Boolean,
        val noun: String,
        val access: CopilotAccess,
        val grant: CopilotGrantWire,
        val tools: Int?,
        val turnTokens: Int?,
    )

    data class Passage(val caption: String, val body: String)

    /**
     * The screen, in order. Four passages are common to both kinds of machine and two are not, and
     * the split is the point: *what it is*, *what it reaches*, *what it may do* and *who it is shared
     * with* are facts about the product; what differs is *why there is none here* / *what this one
     * has instead* on a server, and *where it runs* / *what this phone may do* on a desktop.
     */
    fun passages(r: Reading): List<Passage> {
        val out = mutableListOf(whatItIs, whatItReaches(r), whatItMayDo)
        if (r.isServer) {
            out += whyNoneHere
            out += whatThisServerHasInstead(r)
        } else {
            out += whereItRuns(r)
            out += whatThisPhoneMayDo(r)
        }
        out += neverShared
        return out
    }

    private val whatItIs = Passage(
        "What it is",
        "An agent holding this app's own controls, rather than a chat about the app. It runs as a " +
            "Claude CLI session with $BRAND's own interface handed to it, so it answers \"how is " +
            "that other session doing\" by reading the list the sidebar draws, and \"start one in " +
            "that project\" by calling the thing the New Session button calls. There is no second " +
            "copy of the app behind it, which is also the limit of what it can do: only what this " +
            "app can already do to itself.",
    )

    private fun whatItReaches(r: Reading): Passage {
        var body = "The app, not the machine. Its tools are things $BRAND already does: the " +
            "sessions and what is inside them, the projects that are open, a folder's git status " +
            "and its diff, the alerts, the settings — and, on a machine that drives a browser, the " +
            "pages it has open. Nothing reaches a file or spawns a process except through a verb " +
            "this app already had."
        catalogueSentence(r)?.let { body += "\n\n$it" }
        return Passage("What it can reach", body)
    }

    private fun catalogueSentence(r: Reading): String? {
        val tools = r.tools?.takeIf { it > 0 } ?: return null
        val count = if (tools == 1) "1 tool" else "$tools tools"
        val tokens = r.turnTokens?.takeIf { it > 0 }
            ?: return "That ${r.noun}'s copilot carries $count."
        return "That ${r.noun}'s copilot carries $count, and they cost it about $tokens tokens of " +
            "every turn before anybody has said anything."
    }

    private val whatItMayDo = Passage(
        "What it may do without asking",
        "Every call it makes is written to the action log, whatever tier it is, whether it worked " +
            "or not. Above that there are three tiers. Read — the lists, a transcript, a git status " +
            "— always allowed. Act — start a session, talk to the one it started, stop that one — " +
            "allowed, and never silent. Alter — write a setting, or reach into work it did not " +
            "start — put to a person in a window first, and refused if nobody answers.\n\n" +
            "Act is not the safe tier. Starting a session spends money and runs a process as you. " +
            "It sits below Alter because it is visible and undoable — the session appears and can " +
            "be killed — where an Alter call changes something nothing on screen would announce. A " +
            "gate that fires on everything is a gate nobody reads.",
    )

    private val whyNoneHere = Passage(
        "Why there is none on this server",
        "The copilot's tools are the desktop app's own — its session list, its transcripts, its " +
            "projects, its browser. A server has no window and none of those, so there is no " +
            "copilot to hand this app's interface to. What it has instead is below.",
    )

    private fun whatThisServerHasInstead(r: Reading) = Passage(
        "What this ${r.noun} has instead",
        "A session with an agent in it — the same work at a different surface. The Copilot tab " +
            "starts one in the folder you set, and continues the one already there. It spends money " +
            "and runs as you, the same as a session started anywhere else.",
    )

    private fun whereItRuns(r: Reading) = Passage(
        "Where it runs",
        "At the ${r.noun}, in its own window, on that machine's own account. The conversation you " +
            "see at the machine is that agent's; this phone watches it and, with the grant, starts " +
            "a run of its own beside it.",
    )

    /**
     * What this phone may do, in the vocabulary the rest of the tab uses. Every case of
     * [CopilotAccess], because a state added later and not thought about is a paragraph that
     * silently describes the wrong one.
     */
    private fun whatThisPhoneMayDo(r: Reading): Passage {
        val body = when (r.access) {
            CopilotAccess.NotOffered ->
                "Nothing: there is no copilot on this ${r.noun} for this phone. Either it is " +
                    "running a version of $BRAND without one, or this phone is paired with it as a " +
                    "guest. Which of the two was decided at the machine when this phone was " +
                    "approved, and cannot be told apart from here."
            CopilotAccess.Connecting ->
                "The hello is on its way, or the socket is down and it cannot be. There is nothing " +
                    "to press while that is true. The pill follows the pairing rather than the " +
                    "wire, so it stays where it is while a phone goes through a tunnel."
            CopilotAccess.NotGranted ->
                "Open, and granted nothing. One of your own devices is given every tier, so this " +
                    "is that machine saying something this build does not expect rather than a " +
                    "switch to go and find. It is shown rather than hidden because a blank screen " +
                    "would be indistinguishable from a fault in this app."
            CopilotAccess.Watch ->
                "Watch it: what it is doing, what it started, and what it was refused. No composer " +
                    "and no Start — talking to a copilot is an Act, because it spends money and " +
                    "causes tool calls, and this phone has been given Read and not that."
            CopilotAccess.Direct -> {
                val answering = if (r.grant.alter) {
                    "Confirmations for your own run are answered here, on this phone."
                } else {
                    "Confirmations for your own run are answered at the machine; this phone is " +
                        "shown the question and not the buttons."
                }
                "Watch it, start a run of your own, and talk to that run. $answering The " +
                    "conversation at the machine stays read-only either way — it is somebody else's."
            }
        }
        return Passage("What this phone may do", body)
    }

    private val neverShared = Passage(
        "Only your own devices",
        "The copilot is never shared. A device approved as My device reaches it on the first " +
            "connection, with nothing to press in between; a device approved as a guest is never " +
            "offered it at all — not a refused button and not an empty screen, the capability is " +
            "simply absent from what that device is told the machine can do.\n\n" +
            "What a device is cannot be changed afterwards by a tap. It is written once when the " +
            "device is approved, and changing it means pairing again — the same two acts, by the " +
            "same two people.",
    )
}
