package dev.terminaldeck.android.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

/**
 * The three things a session's bar says on a desktop, on the phone — and the conversation behind it.
 *
 * A transcription of `pwa/src/session-bar.ts` and `pwa/src/chat-view.ts` by way of
 * `ios/TerminalDeck/Protocol/SessionWire.swift`. Nothing here is new protocol: `usage`, `account`
 * and `chat` have been in `src/main/remote/protocol.ts` and answered by every desktop since
 * 2026-08-18. Two clients were asking; this one was not, which is why the phone showed a session
 * list and a terminal and nothing else.
 *
 * ## Why the usage reading is narrowed here rather than carried
 *
 * `usage.reading` carries the far machine's **own** record — an open `Record<string, unknown>` —
 * because the client that shape was designed for is another copy of the desktop, whose readers are
 * already total over it. This app is not that client, so the two figures it draws are lifted field
 * by field out of a [JsonElement] and anything unreadable answers null. A figure this build does not
 * understand is a chip that is **not drawn**, never a chip drawn with a guess.
 */

/**
 * Which reading is being asked for.
 *
 * The three are not interchangeable and the cost is why they are three: `context` is a transcript
 * read on the far side (milliseconds, so it may ride the same events the terminal does), `plan` is
 * memory the desktop already holds, and `refresh` boots a whole Claude Code over there — which is
 * why it is only ever sent because a finger pressed the ring.
 */
@Serializable
enum class UsageWant {
    @SerialName("plan")
    Plan,

    @SerialName("refresh")
    Refresh,

    @SerialName("context")
    Context,
}

/**
 * One usage answer, or the far end's sentence for why there is none.
 *
 * [reading] is deliberately the far machine's own record rather than a shape mirrored here — see the
 * file header. Null is "there is no reading", never an empty one: a caller handed a blank report
 * could not tell "that account has nothing to report" from "nobody answered", and those want
 * opposite things said about them.
 */
@Serializable
data class UsageAnswerWire(
    val reading: JsonElement? = null,
    val unavailableReason: String? = null,
)

/**
 * The two fractions a bar draws, lifted out of whatever the far end sent.
 *
 * Both optional and both meaning the same thing when absent: *there is no figure*, which draws
 * nothing. `emptyUsageReading` on the desktop composes a report whose every window is
 * `not-reported` precisely so that "nothing to report" cannot be mistaken for zero, and this keeps
 * that distinction: a report with no readable window answers null, not 0.
 */
data class UsageFigures(
    /** The **highest** plan window in the report, 0…1. */
    val plan: Double? = null,
    /** How full this session's context window is, 0…1. */
    val context: Double? = null,
) {
    companion object {
        val NONE = UsageFigures()
    }
}

/**
 * One login on the far machine, as the chip draws it.
 *
 * [provider] is a bare agent id — `claude`, `codex`, `gemini` — and is deliberately not an enum:
 * this app is shipped against desktops that may have grown an agent it has never heard of, and a
 * closed set would turn a new agent into a dropped account rather than into a row it cannot switch
 * to.
 *
 * [color] is a **custom property name** (`--accent`), never a colour value, so the palette stays in
 * one place and a machine on the other end of a socket cannot paint anything on this screen. It is
 * checked into shape by [AccountWire.tint] rather than carried as free text.
 */
@Serializable
data class AccountWire(
    val id: String,
    val name: String,
    val provider: String? = null,
    val color: String? = null,
    /** The machine's own install — the login every fallback ends on. */
    val system: Boolean = false,
) {
    /**
     * The custom-property name this row asked to be tinted with, or null.
     *
     * `--accent`, and nothing that is not one. Checked against the shape a custom property has
     * rather than trusted, because this string arrives from another machine and its only use is to
     * pick a colour out of a table on this side.
     */
    val tint: String?
        get() {
            val raw = color ?: return null
            if (!raw.startsWith("--") || raw.length > 42) return null
            val body = raw.drop(2)
            if (body.isEmpty()) return null
            return if (body.all { it.isLetterOrDigit() || it == '-' }) raw else null
        }
}

/**
 * Is this a login of a *different* agent than the session is running?
 *
 * A transcription of `foreignAccount` in `pwa/src/session-bar.ts`, and it exists because the far
 * side already refuses the switch: `session-switch.ts` answers with a sentence and stops, and
 * nothing on this bar draws sentences. A row that could be pressed and could only ever do nothing is
 * worse than a row that cannot.
 *
 * Both providers have to be *known* before two of them can be said to differ. A row whose own
 * provider is null stays pressable rather than being dimmed because an older machine did not name
 * its agent.
 */
fun foreignAccount(current: AccountWire?, account: AccountWire): Boolean {
    val mine = current?.provider ?: return false
    val theirs = account.provider ?: return false
    return mine != theirs
}

@Serializable
enum class ChatRole {
    @SerialName("you")
    You,

    @SerialName("agent")
    Agent,
}

/**
 * Lifting the two figures out of a record this app does not own.
 *
 * Every shape below was taken from a real frame off a running desktop rather than from the
 * desktop's types, since the types are the half that is allowed to grow.
 */
object UsageReadings {

    /**
     * A fraction in 0…1, or null.
     *
     * Bounded rather than trusted: a bar drawn from 3.4 is a bar that leaves its own frame. A JSON
     * boolean must not read as 1.0 — a full ring drawn out of a flag — so the primitive is checked
     * for being a number before its double is taken.
     */
    fun fraction(value: JsonElement?): Double? {
        val raw = finite(value) ?: return null
        return raw.coerceIn(0.0, 1.0)
    }

    /**
     * The highest plan window a report carries, as a fraction.
     *
     * The highest rather than a chosen one: a person is limited by whichever window they are nearest
     * the end of, and picking "the five-hour one" would draw a calm ring while the weekly window is
     * what actually stops them working. A ring is one number, so it is the worst one.
     *
     * `used` is a union on the wire — `{state:'reported', fraction}` or `{state:'not-reported'}` —
     * precisely so nothing can `?? 0` its way past the difference, and that is kept: a report whose
     * every window is unreported answers null, which draws no ring rather than an empty one that
     * reads as *"you have used nothing"*.
     */
    fun planFraction(reading: JsonElement?): Double? {
        val rows = (reading as? JsonObject)?.get("readings") as? JsonArray ?: return null
        var worst: Double? = null
        for (row in rows) {
            val used = (row as? JsonObject)?.get("used") as? JsonObject ?: continue
            if (text(used["state"]) != "reported") continue
            val value = fraction(used["fraction"]) ?: continue
            val held = worst
            if (held != null && value <= held) continue
            worst = value
        }
        return worst
    }

    /**
     * How full the context window is, as a fraction.
     *
     * `percent` on the far end's record is 0…100 — `readContextWindow` writes a percentage — so it
     * is divided here and nowhere else. `state` is what says whether there is a figure at all:
     * anything but a live reading answers null and the bar is not drawn.
     */
    fun contextFraction(reading: JsonElement?): Double? {
        val record = reading as? JsonObject ?: return null
        if (text(record["state"]) == "not-reported") return null
        val percent = finite(record["percent"]) ?: return null
        return (percent / 100).coerceIn(0.0, 1.0)
    }

    /**
     * The figures in one answer, whichever question was asked.
     *
     * A `refresh` answers with the outcome *and* the report; a `plan` answers with the report alone.
     * One reader, because the figure lives in the same place in both and inventing a second path is
     * how the two come apart.
     */
    fun figures(want: UsageWant, reading: JsonElement?): UsageFigures = when (want) {
        UsageWant.Context -> UsageFigures(context = contextFraction(reading))
        UsageWant.Plan -> UsageFigures(plan = planFraction(reading))
        UsageWant.Refresh -> {
            val report = (reading as? JsonObject)?.get("report") ?: reading
            UsageFigures(plan = planFraction(report))
        }
    }

    /** A finite JSON number, or null. A boolean is not a number, and neither is a numeric string. */
    private fun finite(value: JsonElement?): Double? {
        val primitive = value as? JsonPrimitive ?: return null
        if (primitive.isString) return null
        if (primitive.booleanOrNull != null) return null
        val raw = primitive.doubleOrNull ?: return null
        return if (raw.isFinite()) raw else null
    }

    private fun text(value: JsonElement?): String? {
        val primitive = value as? JsonPrimitive ?: return null
        return if (primitive.isString) primitive.content else null
    }
}

