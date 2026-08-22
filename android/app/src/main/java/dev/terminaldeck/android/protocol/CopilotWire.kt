package dev.terminaldeck.android.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * The machine's own agent, as a phone sees it.
 *
 * Asad, holding the iOS release for this: *"We need to build a copilot in the phone app too, because
 * we need to connect the copilot also and we should be able to control the copilot from the phone
 * also."* And, settling the shape of it: *"Phones will have full control over copilot, same as the
 * actual machine app."*
 *
 * A transcription of `src/main/remote/protocol.ts`'s copilot section by way of
 * `ios/TerminalDeck/Protocol/CopilotWire.swift`. Every type here is a shape the desktop already
 * sends; nothing in this file is new protocol.
 *
 * ## The capability is not the permission
 *
 * A host advertises `copilot` to say *"I have one"*. Whether **this device** may drive it is a
 * separate reading — the grant on [CopilotLinkWire] — decided at the machine by whether this phone
 * was paired as one of the owner's own devices rather than as a guest. A client that treated the
 * capability as the permission would draw a tab whose every button answered "not allowed", which is
 * why [CopilotAccess] is a second reading rather than a boolean derived from the capability string.
 */

/**
 * The three tiers, as the machine grants them.
 *
 * They are not a ladder this end may reason about: the desktop decides what each one covers, and a
 * client that inferred "act implies read" would be inventing a rule the machine does not promise.
 * Every one is read as sent.
 */
@Serializable
data class CopilotGrantWire(
    /** Watch: the conversation, the log, what it is doing. Spends nothing. */
    val read: Boolean = false,
    /** Talk to it, start it, stop it. Talking to an agent *is* acting, and it costs money. */
    val act: Boolean = false,
    /** Answer its confirmations — the tier that lets a device approve an irreversible thing. */
    val alter: Boolean = false,
) {
    /** Nothing at all. The state a guest is in, and the reason a guest gets no tab. */
    val none: Boolean get() = !read && !act && !alter
}

/** Whether this connection's copilot is open, and what it may do. */
@Serializable
data class CopilotLinkWire(
    val linked: Boolean = false,
    val open: Boolean = false,
    val grant: CopilotGrantWire = CopilotGrantWire(),
)

/**
 * What the copilot is doing, as one record.
 *
 * [desk] is the machine's own agent process; [run] is **this device's** run, and the two are
 * different things on purpose — a phone that folded them would show "running" because somebody at
 * the desk was working, over a tab with nothing in it.
 *
 * [available] is the machine saying whether a copilot can be started at all, with [reason] its own
 * sentence when it cannot. Carried verbatim rather than mapped: *"no API key configured"* is not a
 * thing this end can rephrase without guessing at a setup it cannot see.
 */
@Serializable
data class CopilotStateReport(
    /**
     * Defaulted to [CopilotDesk.Unknown] rather than to `Stopped`, and the difference is a lie.
     *
     * `coerceInputValues` folds an enum value this build has never heard of onto the **property's
     * default**, not onto a case named Unknown — so a desktop that grew a fourth word would have had
     * this client draw *"Stopped"* over an agent that was running. Found by a test that sent one.
     */
    val desk: CopilotDesk = CopilotDesk.Unknown,
    /** This device's run id, or null when it has none. Names the conversation frames that belong. */
    val run: String? = null,
    val profile: String? = null,
    /** Whether the agent has a login. Null is "the machine could not say", which draws nothing. */
    val signedIn: Boolean? = null,
    /** How many tools the copilot is holding. A count, drawn only when it is not zero. */
    val tools: Int = 0,
    /** Tokens spent on the turn in flight. Zero between turns rather than a stale total. */
    val turnTokens: Int = 0,
    /** Confirmations waiting, anywhere — including ones this device may not answer. */
    val pending: Int = 0,
    val grant: CopilotGrantWire = CopilotGrantWire(),
    val available: Boolean = false,
    val reason: String? = null,
) {
    /** This device has a run of its own. What decides whether the composer is drawn. */
    val hasRun: Boolean get() = !run.isNullOrEmpty()
}

/**
 * The three words a machine's own agent process can be in.
 *
 * [Unknown] is not on the wire. It is where `coerceInputValues` folds a word a newer desktop grew,
 * for the reason [ProtocolErrorCode.Unknown] exists: a client that refused to parse a `copilot.state`
 * carrying a fourth word would turn a future desktop's honest answer into a dropped frame.
 */
@Serializable
enum class CopilotDesk {
    @SerialName("stopped")
    Stopped,

    @SerialName("starting")
    Starting,

    @SerialName("running")
    Running,

    @SerialName("unknown")
    Unknown,
}

/**
 * One bubble of the copilot's conversation.
 *
 * Deliberately its own type rather than a reuse of [ChatMessageWire], which is the *session* chat.
 * They have the same shape today and are two different frames from two different producers; folding
 * them would mean a field added to one arriving in the other by accident.
 *
 * [truncated] is the desktop saying *there is more of this, go and look on the machine*. Carried
 * through rather than recomputed: a reader that decided for itself would be saying it about
 * something else.
 */
@Serializable
data class CopilotChatMessage(
    val id: String,
    val role: ChatRole,
    val text: String = "",
    /** Epoch ms. Zero when the line carried no date, which draws no time rather than 1970. */
    val at: Long = 0,
    val truncated: Boolean = false,
)

/** A session the copilot started, linked back to the turn that made it. */
@Serializable
data class CopilotSessionRow(
    val id: String,
    val title: String = "",
    val cwd: String = "",
    val provider: String = "",
    val status: String = "",
    val startedAt: Long = 0,
    /** The run whose turn started it, or null for one the machine started itself. */
    val originRunId: String? = null,
)

/**
 * One tool call as it happened, already scrubbed on the far side.
 *
 * This is *"see what it is doing"*, and it is the row that makes a refusal visible: a call this
 * device's grant did not cover arrives with [outcome] `Refused` and a [refusal] in the copilot's own
 * words rather than as silence. A gate that denies invisibly is indistinguishable from a gate that
 * was never reached.
 */
@Serializable
data class CopilotActionRow(
    val id: String,
    /** The machine's own timestamp, as it wrote it. A string, because that is what is on the wire. */
    val at: String = "",
    val tool: String = "",
    val tier: String = "",
    val outcome: CopilotOutcome = CopilotOutcome.Unknown,
    /** Untrusted display text: it is a summary a tool produced. Drawn as text, never parsed. */
    val detail: String = "",
    val refusal: String? = null,
    val deviceId: String? = null,
)

@Serializable
enum class CopilotOutcome {
    @SerialName("ok")
    Ok,

    @SerialName("refused")
    Refused,

    @SerialName("error")
    Error,

    /** Not on the wire. Where a word a newer desktop grew is folded. */
    @SerialName("unknown")
    Unknown,
}

/**
 * A confirmation waiting somewhere.
 *
 * [mine] is the whole of what a client does differently with one: a row that is not this device's is
 * a **notification**, not a decision, and drawing buttons on it would be drawing a control whose
 * only outcome is a refusal from the far side.
 */
@Serializable
data class CopilotPendingRow(
    val id: String,
    val tool: String = "",
    val summary: String = "",
    val requestedAt: Long = 0,
    val expiresAt: Long = 0,
    val mine: Boolean = false,
)

/**
 * A confirmation **this connection may answer**.
 *
 * Only ever sent to the surface that owns the run that raised it. Everybody else who is watching
 * sees it as a [CopilotPendingRow] with `mine = false`.
 *
 * [args] is the tool's own record and is deliberately left as a [JsonElement]: the shape belongs to
 * whichever tool raised it, and mirroring one here would mean a new tool's arguments arriving as an
 * empty object. [CopilotArguments] reads what it can out of it and says nothing about the rest.
 */
@Serializable
data class CopilotConsentQuestion(
    val id: String,
    val tool: String = "",
    val tier: String = "",
    val summary: String = "",
    val args: JsonElement? = null,
    val origin: String = "",
    val requestedAt: Long = 0,
    val expiresAt: Long = 0,
)

/**
 * A confirmation closed, and where it was answered.
 *
 * [by] is the device that answered, so a dialog that disappears says where the answer came from. A
 * dialog that vanished without saying would be the app doing something behind a person's back.
 */
@Serializable
data class CopilotSettledRow(
    val id: String,
    val granted: Boolean = false,
    val by: String? = null,
    val reason: String? = null,
)

/**
 * Where this phone stands with a machine's copilot.
 *
 * Five cases, and the screen draws five different things. Not one boolean, because the five are
 * genuinely different facts and three of them are worth a different sentence.
 */
enum class CopilotAccess {
    /**
     * There is no copilot here **for this phone**.
     *
     * One case covering two situations this end cannot tell apart, by design: that machine may be
     * running a build with no copilot in it, or this phone may be paired with it as a guest. The
     * screen says both in one sentence rather than picking one and being wrong half the time.
     */
    NotOffered,

    /** The machine has one and this connection has not been told about it yet. */
    Connecting,

    /**
     * Open, and given nothing.
     *
     * It should not happen — one of the owner's own devices is granted every tier — so it is drawn
     * as what it is: a machine saying something this build did not expect, stated rather than hidden
     * behind a blank screen that would read as a bug here.
     */
    NotGranted,

    /** Read only. The conversation and the log, and nothing that spends anything. */
    Watch,

    /** Full control: talk to it, start it, stop it, answer its confirmations. */
    Direct,
    ;

    /** Whether the tab is drawn at all. */
    val isConnected: Boolean
        get() = when (this) {
            NotOffered -> false
            Connecting, NotGranted, Watch, Direct -> true
        }

    /** Whether this device may spend anything: say, start, cancel, stop. */
    val canAct: Boolean get() = this == Direct

    companion object {
        /**
         * Read from what the machine said, and from nothing else.
         *
         * The capability is the first gate and the grant is the second, and they answer different
         * questions — see the file header. A machine that advertises `copilot` and hands this device
         * a grant of nothing lands on [NotGranted], which is a sentence rather than an empty screen.
         */
        fun read(offered: Boolean, link: CopilotLinkWire?): CopilotAccess = when {
            !offered -> NotOffered
            link == null -> Connecting
            !link.linked || !link.open -> Connecting
            link.grant.none -> NotGranted
            link.grant.act || link.grant.alter -> Direct
            else -> Watch
        }
    }
}

/**
 * One thing on the copilot's timeline: something it said, or something it did.
 *
 * The timeline is chat bubbles and tool rows **in arrival order**, not a chat pane with an activity
 * pane behind a segment. Asad, on why: *"exactly like you are working now for me — but now you are
 * working in folders and files, I don't know which files where and all that stuff. Here I can
 * actually see it."* Two panes would put the answer in one and the machinery in the other and leave
 * a person correlating them by timestamp on a four-inch screen.
 */
sealed interface CopilotEntry {
    val id: String

    data class Said(val message: CopilotChatMessage) : CopilotEntry {
        override val id: String get() = "say:${message.id}"
    }

    data class Did(val row: CopilotActionRow) : CopilotEntry {
        override val id: String get() = "tool:${row.id}"
    }

    /**
     * Something **this phone** just said, drawn before the machine has echoed it back.
     *
     * Asad, on this screen: *"it should be a very smooth and clean process."* It was not. A message
     * left this phone, the draft cleared, and the timeline stayed exactly as it was — because the
     * only bubble a person's own words ever get is the one the far machine sends back, and that is a
     * full round trip through a pty, an agent CLI and a transcript reader. Measured on 2026-08-22
     * against `scripts/remote-host.sh`: **three seconds against a shell on this same Mac**, and a
     * real agent CLI is slower. What a person saw in that window was a message that had vanished.
     *
     * So the bubble is drawn here, immediately, and the machine's own version **replaces** it when
     * it arrives — see [CopilotTimeline.settle]. It is not a second message and it must never read
     * as one: it is the same sentence, drawn early, and it carries [state] so it never claims more
     * than is known.
     *
     * A row is added **only when the frame went onto the socket**. A send this end refused — too
     * long, a control character, a dead socket — keeps the draft in the box and says why under the
     * composer instead, because a bubble plus a full text field is one message shown twice.
     */
    data class Mine(
        /** This phone's own id for the row. Never sent anywhere. */
        val localId: String,
        val text: String,
        val at: Long,
        /** What is known about it, and nothing more. */
        val state: CopilotSendState = CopilotSendState.Sending,
    ) : CopilotEntry {
        override val id: String get() = "mine:$localId"
    }
}

/**
 * What is known about a message this phone sent.
 *
 * Two states and no third, because there is no third fact. The machine acknowledges a `copilot.say`
 * by echoing the person's own words back in a `copilot.chat`; until that arrives this end knows the
 * frame left the socket and nothing else, and after a wait long enough to cover a cold agent CLI it
 * knows the echo has not come. Neither is "failed" — the desktop may still be typing it into a
 * prompt — so the second one says what it can defend.
 */
enum class CopilotSendState {
    /** On the wire. The machine has not echoed it back yet. */
    Sending,

    /** Long enough that something is wrong, and this end cannot say what. */
    Unacknowledged,
}

/**
 * Folding the copilot's frames into one timeline.
 *
 * Separate from the controller for the reason [PortCatalogLikeSplit] would be: every rule about
 * merging can be pinned by a test with no socket, and the screen makes one call rather than holding
 * three predicates that could drift.
 */
object CopilotTimeline {

    /**
     * Merge a `copilot.chat` into what is held.
     *
     * **Merge by id: replace a match, append otherwise.** [reset] means drop everything held and take
     * this frame as the whole conversation — which is what arrives on a fresh attach and when a run
     * is replaced.
     *
     * The tool rows are kept across a merge and dropped on a reset, because they belong to the same
     * run the conversation does: a reset is a different run, and a log line from the previous one
     * spliced into the new timeline is a person reading about work that was done for somebody else's
     * question.
     */
    fun mergeChat(
        held: List<CopilotEntry>,
        messages: List<CopilotChatMessage>,
        reset: Boolean,
    ): List<CopilotEntry> {
        /*
         * A reset replaces the conversation — and **keeps a message this phone has just sent**.
         *
         * The two are not the same kind of thing. A reset is the machine saying *this is the whole
         * conversation now*; an unechoed [CopilotEntry.Mine] is a sentence that left this device
         * seconds ago and that the machine has not spoken about yet. Dropping it on a reset would
         * be the exact defect this row exists to fix, arriving one frame later — a `copilot.state`
         * lands, a reset comes with it, and a person watches their own message disappear.
         */
        val pending = held.filterIsInstance<CopilotEntry.Mine>()
        if (reset) return settle(messages.map { CopilotEntry.Said(it) } + pending, messages)
        val out = held.toMutableList()
        for (message in messages) {
            val at = out.indexOfFirst { it is CopilotEntry.Said && it.message.id == message.id }
            if (at >= 0) out[at] = CopilotEntry.Said(message) else out += CopilotEntry.Said(message)
        }
        return settle(out, messages)
    }

    /**
     * Take away the rows the machine has now said itself.
     *
     * A [CopilotEntry.Mine] is this phone drawing its own sentence early. The moment the same
     * sentence comes back as a `you` message it is **the machine's row**, in the machine's order,
     * with the machine's id — so the early one goes, rather than sitting above it as a duplicate.
     *
     * Matched on the text rather than on an id, because there is no shared id to match on: a
     * `copilot.say` carries no request id and the desktop mints the message id from its own
     * transcript. Compared after [CopilotText.display] and a trim, so an echo that arrived with a
     * shell's escape sequences around it still cancels the row it belongs to.
     *
     * Only ever removes; it never edits a row it did not match. A sentence somebody genuinely sent
     * twice cancels one pending row per echo, which is the right count.
     */
    fun settle(held: List<CopilotEntry>, messages: List<CopilotChatMessage>): List<CopilotEntry> {
        val echoes = messages
            .filter { it.role == ChatRole.You }
            .map { CopilotText.display(it.text).trim() }
            .filter { it.isNotEmpty() }
            .toMutableList()
        if (echoes.isEmpty()) return held
        val out = mutableListOf<CopilotEntry>()
        for (entry in held) {
            val mine = entry as? CopilotEntry.Mine
            if (mine != null) {
                val at = echoes.indexOf(mine.text.trim())
                if (at >= 0) {
                    echoes.removeAt(at)
                    continue
                }
            }
            out += entry
        }
        return out
    }

    /** Put a message this phone just sent at the end, where a person is looking. */
    fun appendMine(held: List<CopilotEntry>, entry: CopilotEntry.Mine): List<CopilotEntry> =
        held + entry

    /** Say that one of this phone's own messages has gone unanswered for too long. */
    fun mark(
        held: List<CopilotEntry>,
        localId: String,
        state: CopilotSendState,
    ): List<CopilotEntry> = held.map { entry ->
        if (entry is CopilotEntry.Mine && entry.localId == localId) entry.copy(state = state) else entry
    }

    /**
     * Merge one `copilot.tool`.
     *
     * Replaced by id rather than appended blindly: a call arrives once when it starts and again when
     * it settles, and a timeline that appended both would show every action twice — once as running
     * and once as done.
     */
    fun mergeTool(held: List<CopilotEntry>, row: CopilotActionRow): List<CopilotEntry> {
        val out = held.toMutableList()
        val at = out.indexOfFirst { it is CopilotEntry.Did && it.row.id == row.id }
        if (at >= 0) out[at] = CopilotEntry.Did(row) else out += CopilotEntry.Did(row)
        return out
    }

    /**
     * Merge a page of `copilot.log`.
     *
     * The log is the same rows the live `copilot.tool` push carries, so a row already on screen is
     * **replaced in place** rather than duplicated. A row that is not held is put at the **front**,
     * in the page's own order — because a log page reaches backwards, and appending older rows to
     * the end would draw work that happened this morning underneath a reply from a minute ago.
     */
    fun mergeLog(held: List<CopilotEntry>, rows: List<CopilotActionRow>): List<CopilotEntry> {
        val out = held.toMutableList()
        val older = mutableListOf<CopilotEntry>()
        for (row in rows) {
            val at = out.indexOfFirst { it is CopilotEntry.Did && it.row.id == row.id }
            if (at >= 0) out[at] = CopilotEntry.Did(row) else older += CopilotEntry.Did(row)
        }
        return older + out
    }
}

/** A marker for the doc reference above; the timeline has no split of its own. */
private typealias PortCatalogLikeSplit = Unit

/**
 * Bubble text, as a phone may safely draw it.
 *
 * A chat message is **bytes an agent wrote**, and on this wire that can include what a shell echoed
 * into its own transcript: a restored-session banner, an OSC 7 working-directory sequence, a colour
 * run. Drawn raw, those arrive as a replacement glyph followed by `]7;file:///Users/...` — which is
 * not merely ugly, it is this client rendering an escape sequence as content.
 *
 * Measured, not imagined: the first bubble of a real run against `scripts/remote-host.sh` on
 * 2026-08-22 was exactly that string.
 *
 * Stripped rather than refused, which is the opposite of the rule for `copilot.say` going the other
 * way — and the asymmetry is the point. **Outbound**, a control character is refused because
 * stripping would turn a hostile value into a different legal-looking message that somebody pays
 * for. **Inbound**, there is nothing to protect but the reader's eyes: the text is never executed,
 * only drawn, and a bubble with the escapes taken out says exactly what the agent said.
 *
 * Newlines and tabs survive. They are layout the agent meant.
 */
object CopilotText {

    /** The two bytes, written as escapes so this file holds no control character of its own. */
    private const val ESC = "\u001B"
    private const val BEL = "\u0007"

    /** `ESC [ … final` — a CSI sequence, which is what a colour run or a cursor move is. */
    private val CSI = Regex(ESC + "\\[[0-?]*[ -/]*[@-~]")

    /**
     * `ESC ] … BEL` or `ESC ] … ESC \\` — an OSC sequence, which is what OSC 7 is.
     *
     * Deliberately not a general "ANSI" pattern: these two families are the ones that appear in a
     * transcript, and a wider expression risks eating a `[` somebody typed.
     */
    private val OSC = Regex(ESC + "\\][^" + BEL + ESC + "]*(?:" + BEL + "|" + ESC + "\\\\)?")

    fun display(raw: String): String {
        if (raw.isEmpty()) return raw
        val withoutSequences = OSC.replace(CSI.replace(raw, ""), "")
        // Anything left that is a control character, except the two that are layout. A lone ESC that
        // began a sequence this build does not recognise goes here rather than onto the screen.
        return buildString(withoutSequences.length) {
            for (ch in withoutSequences) {
                if (!ch.isISOControl() || ch == '\n' || ch == '\t') append(ch)
            }
        }
    }
}

/**
 * What a confirmation is actually asking for, out of a record this app does not own.
 *
 * [CopilotConsentQuestion.args] is the tool's own shape and a new tool will have one this build has
 * never seen. What this does is lift the two or three fields that are worth putting under a question
 * — a path, a command, a url — and say nothing at all about anything else. A field this build does
 * not understand is a line that is **not drawn**, never a line drawn with a guess.
 */
object CopilotArguments {

    /** The keys worth showing, in the order they read best under a summary. */
    private val INTERESTING = listOf("path", "file", "command", "cmd", "url", "folder", "cwd", "pattern")

    /**
     * The lines to draw under the summary, in order, bounded.
     *
     * Values are cut to something a phone row can hold. They are text a *tool* produced — which on
     * this wire means text that may have come from a file on the machine — so they are drawn as text
     * and never parsed, and the cut is what stops one pushing the buttons off the screen.
     */
    fun lines(args: JsonElement?, limit: Int = 4): List<Pair<String, String>> {
        val record = args as? JsonObject ?: return emptyList()
        val out = mutableListOf<Pair<String, String>>()
        for (key in INTERESTING) {
            if (out.size >= limit) break
            val value = text(record[key]) ?: continue
            if (value.isEmpty()) continue
            out += key to value.take(MAX_VALUE_CHARS)
        }
        return out
    }

    private fun text(value: JsonElement?): String? {
        val primitive = value as? JsonPrimitive ?: return null
        return if (primitive.isString) primitive.content else null
    }

    private const val MAX_VALUE_CHARS = 240
}
