package dev.terminaldeck.android.ui

import dev.terminaldeck.android.protocol.RecordedStep
import kotlin.math.floor

/**
 * The click-flow recorder, for a page **this phone** is holding open.
 *
 *   > *"you are giving record flow button in the windows side the server side it and you are not
 *   > giving that into the if they are browsing locally in this machine. So there are so many
 *   > differences if they both are capable for a feature why don't they both have."*
 *
 * A port of `ios/TerminalDeck/Ports/PhoneClickFlow.swift` + the selector engine of
 * `ios/TerminalDeck/Inspect/ElementCapture.swift`, both themselves transcriptions of
 * `src/main/browser-steps.ts` and `selector.ts`. The machine's own recorder exists because the
 * machine's browser is watched through **pixels** — a tap goes over and a picture comes back, so there
 * is no DOM on this side to listen to. This screen is the opposite: the web view *is* here, so
 * recording clicks is a page-side script ([PhoneRecordScript]) and a list, which is what this file is.
 *
 * ## One vocabulary, two recorders
 *
 * The rows drawn are [RecordedStep], the **same type** the machine's steps arrive in, so the two lists
 * say the same thing about the same click. `kind` is one of the seven words `browser-steps.ts` names —
 * navigate, click, type, select, check, press, submit — plus `truncated` for the cut row. `detail` is
 * the sentence; `value` is dropped outright when the step was redacted, because *a field that carries
 * a one-time-code in clear is not made safe by being short.*
 *
 * ## A password's value is never recorded, on both sides of the check
 *
 * The page-side script refuses to send it, and this side refuses to keep it even if a payload arrives
 * with the flag stripped — the element's own `type` is checked here, independently. `file` counts with
 * `password`: its value is a path on somebody's own device and it names them before anything else.
 *
 * ## The engine runs on parsed values, not JSON
 *
 * [PhoneInspect.parseCapture] takes an already-parsed payload (a `Map`/`List` tree, the way iOS takes
 * `[String: Any]`) rather than a JSON string, so it is a pure function a plain JVM test can drive —
 * the bridge in [PhoneRecordScript] does the JSON→map step. A payload that arrived from the page is
 * treated as hostile: nothing about a selector is decided in JavaScript, and every field is
 * re-validated here.
 *
 * **In memory only**, the way the machine's recorder is: a flow belongs to the sitting it was recorded
 * in, and one found on disk a week later — half of it about a page since rewritten — is worse than
 * none, because it looks current.
 */
class PhoneClickFlow(
    /** Epoch milliseconds, as a seam: the coalescing window is the one behaviour here with a duration
     *  in it, and a test proving it has to move time rather than sleep through it. */
    private val now: () -> Long = { System.currentTimeMillis() },
) {

    /** One tab's recording. [address] is where the page is, kept whether or not anything is recording,
     *  so a recording started later can still say where it began. */
    private data class Reel(
        val recording: Boolean = false,
        val steps: List<PhoneStep> = emptyList(),
        val address: String = "",
    )

    private val reels = mutableMapOf<String, Reel>()

    /** Whether this tab is recording right now. */
    fun isRecording(tab: String): Boolean = reels[tab]?.recording ?: false

    /**
     * The rows, in order, ready to draw. Built on read rather than held, so the redaction happens in
     * one place. The last row is the cut, when there is one — a silent stop at the cap reads as *that
     * is all of them*.
     */
    fun steps(tab: String): List<RecordedStep> {
        val reel = reels[tab] ?: return emptyList()
        val rows = reel.steps.map { row(it) }.toMutableList()
        if (reel.steps.size >= MAX_STEPS) {
            rows.add(
                RecordedStep(
                    at = reel.steps.lastOrNull()?.at ?: 0.0,
                    kind = TRUNCATED_KIND,
                    detail = "Recording stopped at $MAX_STEPS steps.",
                    selector = null,
                    value = null,
                )
            )
        }
        return rows
    }

    /**
     * Start recording this tab. The first step is written here rather than waiting for one to happen —
     * *"a flow that does not say where it starts cannot be replayed."* Starting an already-running
     * recording is a no-op, not a restart: throwing away a flow for a double-press is unrecoverable.
     */
    fun start(tab: String) {
        if (tab.isEmpty()) return
        val reel = reels[tab] ?: Reel()
        if (reel.recording) return
        val steps = if (reel.address.isNotEmpty()) {
            append(reel.steps, navigate(reel.address, now()))
        } else {
            reel.steps
        }
        reels[tab] = reel.copy(recording = true, steps = steps)
    }

    /** Stop. The steps stay — stopping is *finish this flow*; [clear] is the verb that ends one. */
    fun stop(tab: String) {
        val reel = reels[tab] ?: return
        if (!reel.recording) return
        reels[tab] = reel.copy(recording = false)
    }

    /** Throw the flow away, leaving the recorder running if it was: clearing is *start again from
     *  here*, which is what somebody does after a false start. */
    fun clear(tab: String) {
        val reel = reels[tab] ?: return
        val reseeded = if (reel.recording && reel.address.isNotEmpty()) {
            append(emptyList(), navigate(reel.address, now()))
        } else {
            emptyList()
        }
        reels[tab] = reel.copy(steps = reseeded)
    }

    /**
     * Where this tab's page is, as **this app** knows it — called on every navigation whether or not
     * anything is recording. Never the page's own claim. While recording this is also a step: a
     * single-page app rewrites its URL on every route change, and the repeat-URL fold in [append] keeps
     * a redirect chain that ends where it started from becoming two rows.
     */
    fun at(tab: String, url: String) {
        if (tab.isEmpty()) return
        val line = PhoneInspect.sanitizeLine(url, MAX_URL)
        if (line.isEmpty()) return
        val reel = reels[tab] ?: Reel()
        val changed = reel.address != line
        val steps = if (reel.recording && changed) append(reel.steps, navigate(line, now())) else reel.steps
        reels[tab] = reel.copy(address = line, steps = steps)
    }

    /**
     * One message from the page-side recorder, already parsed into a map. Dropped in silence when it is
     * malformed, when nothing is recording, or when [PhoneInspect.parseCapture] refuses the element — a
     * complaint written by the page is not a complaint worth showing. [url] is the web view's own,
     * handed in by the bridge.
     */
    fun note(payload: Map<String, Any?>?, url: String, tab: String) {
        if (tab.isEmpty() || !isRecording(tab)) return
        val step = parse(payload, url, now()) ?: return
        val reel = reels[tab] ?: return
        val next = append(reel.steps, step)
        // `append` hands back the same list when a step folded in or the cap was hit — nothing changed.
        if (next.size == reel.steps.size && next.lastOrNull() == reel.steps.lastOrNull()) return
        reels[tab] = reel.copy(steps = next)
    }

    /**
     * The whole flow on **one line**, for handing to an agent. Single line by construction, the way
     * every string this app types into a PTY is: a newline submits, so a multi-line flow would send the
     * first line as the whole instruction.
     */
    fun line(tab: String): String {
        val steps = reels[tab]?.steps ?: emptyList()
        if (steps.isEmpty()) return ""
        val body = steps.mapIndexed { i, step -> "${i + 1}) ${describe(step)}" }.joinToString("; ")
        return PhoneInspect.sanitizeLine("[browser flow: $body]", MAX_FLOW_LINE)
    }

    /** The tab is gone — a page closed. Called so a phone used all day is not holding flows for windows
     *  nobody can see. */
    fun forget(tab: String) {
        reels.remove(tab)
    }

    /* ------------------------------------------------------------------ parsing -- */

    private fun parse(payload: Map<String, Any?>?, url: String, at: Long): PhoneStep? {
        if (payload == null) return null
        if (PhoneInspect.wholeNumber(payload["v"]) != 1) return null
        val word = payload["kind"] as? String ?: return null
        val kind = PhoneStep.Kind.from(word) ?: return null
        if (kind == PhoneStep.Kind.Navigate) return null
        val capture = PhoneInspect.parseCapture(payload["target"], url) ?: return null

        var step = PhoneStep(kind = kind, at = at.toDouble(), selector = capture.selector, tag = capture.tag, url = capture.url)
        // A button is named by what is written on it; a field by what names it. `fieldLabel` never
        // reaches for the element's own text or value — both fallbacks label the email box with the
        // email address, and a <select>'s text is the run-together list of its options.
        step = step.copy(
            label = if (kind == PhoneStep.Kind.Click || kind == PhoneStep.Kind.Submit) {
                capture.label
            } else {
                fieldLabel(capture.attributes)
            }
        )

        return when (kind) {
            PhoneStep.Kind.Press -> {
                val key = payload["key"] as? String ?: ""
                if (key !in NOTABLE_KEYS) null else step.copy(key = key)
            }
            PhoneStep.Kind.Check -> step.copy(checked = payload["checked"] == true)
            PhoneStep.Kind.Type, PhoneStep.Kind.Select -> {
                // Two independent reasons to withhold, both checked: the script's own flag, and the
                // capture's `type` attribute for a payload where that flag was stripped on the way here.
                if (payload["secret"] == true || isSecret(capture.attributes)) {
                    step.copy(redacted = true)
                } else {
                    step.copy(value = PhoneInspect.sanitizeLine(payload["value"], MAX_VALUE))
                }
            }
            else -> step
        }
    }

    private fun navigate(url: String, at: Long): PhoneStep =
        PhoneStep(kind = PhoneStep.Kind.Navigate, url = PhoneInspect.sanitizeLine(url, MAX_URL), at = at.toDouble())

    /** The best name for a **field** — only the naming attributes, never the element's own text or
     *  value. An unnamed field is left unnamed; the selector alone reads better than a confident wrong
     *  label. */
    private fun fieldLabel(attributes: Map<String, String>): String {
        for (key in listOf("aria-label", "placeholder", "title", "name")) {
            val value = attributes[key]
            if (!value.isNullOrEmpty()) return PhoneInspect.sanitizeLine(value, MAX_LABEL)
        }
        return ""
    }

    private fun isSecret(attributes: Map<String, String>): Boolean {
        val type = (attributes["type"] ?: "").lowercase()
        return type == "password" || type == "file"
    }

    /* ---------------------------------------------------------------- appending -- */

    /**
     * Add a step, folding it into the previous one where they are really the same action:
     *  - repeated typing in one field replaces itself (change fires every time the field is left);
     *  - a repeat navigation to the same URL is dropped;
     *  - two fast clicks on one element merge — a double-click is not two steps.
     *
     * Once the cap is reached the list stops growing rather than dropping its oldest steps: a flow
     * missing its beginning cannot be replayed, where one missing its end is still a shorter true flow.
     */
    private fun append(steps: List<PhoneStep>, next: PhoneStep): List<PhoneStep> {
        val last = steps.lastOrNull()
        if (last != null) {
            if ((next.kind == PhoneStep.Kind.Type || next.kind == PhoneStep.Kind.Select) &&
                last.kind == next.kind && sameTarget(last, next)
            ) {
                return steps.dropLast(1) + next
            }
            if (next.kind == PhoneStep.Kind.Navigate && last.kind == PhoneStep.Kind.Navigate && last.url == next.url) {
                return steps
            }
            if (next.kind == PhoneStep.Kind.Click && last.kind == PhoneStep.Kind.Click &&
                sameTarget(last, next) && next.at - last.at < CLICK_MERGE_MS
            ) {
                return steps
            }
        }
        if (steps.size >= MAX_STEPS) return steps
        return steps + next
    }

    private fun sameTarget(a: PhoneStep, b: PhoneStep): Boolean =
        a.selector.isNotEmpty() && a.selector == b.selector

    /* ----------------------------------------------------------------- printing -- */

    /** One step in a sentence a person can follow and a machine can replay — `describeStep`, word for
     *  word, so a step described one way here reads the same as the machine's own list. */
    private fun describe(step: PhoneStep): String = when (step.kind) {
        PhoneStep.Kind.Navigate -> "Go to ${step.url}"
        PhoneStep.Kind.Click -> "Click ${target(step)}"
        PhoneStep.Kind.Type ->
            if (step.redacted) "Type the password into ${target(step)}" else "Type \"${step.value}\" into ${target(step)}"
        PhoneStep.Kind.Select ->
            if (step.redacted) "Choose a value in ${target(step)}" else "Choose \"${step.value}\" in ${target(step)}"
        PhoneStep.Kind.Check -> "${if (step.checked) "Check" else "Uncheck"} ${target(step)}"
        PhoneStep.Kind.Press -> "Press ${step.key} in ${target(step)}"
        PhoneStep.Kind.Submit -> "Submit ${target(step)}"
    }

    private fun target(step: PhoneStep): String {
        val named = if (step.label.isEmpty()) "" else "\"${step.label}\""
        val where = when {
            step.selector.isNotEmpty() -> "`${step.selector}`"
            step.tag.isNotEmpty() -> "<${step.tag}>"
            else -> "the page"
        }
        return if (named.isEmpty()) where else "$named ($where)"
    }

    /** One step as the list draws it — the value dropped outright when the step was redacted. */
    private fun row(step: PhoneStep): RecordedStep {
        val detail = PhoneInspect.sanitizeLine(describe(step), MAX_STEP_TEXT)
        val selector = PhoneInspect.sanitizeLine(step.selector, MAX_STEP_TEXT)
        val value = if (step.redacted) "" else PhoneInspect.sanitizeLine(step.value, MAX_STEP_TEXT)
        return RecordedStep(
            at = step.at,
            kind = step.kind.wire,
            detail = detail.ifEmpty { null },
            selector = selector.ifEmpty { null },
            value = value.ifEmpty { null },
        )
    }

    companion object {
        /** Where a recording stops growing — `MAX_STEPS`. Stops rather than dropping its oldest. */
        const val MAX_STEPS = 200

        /** Two clicks closer than this on the same element are one gesture — `CLICK_MERGE_MS`, a little
         *  under the double-click threshold so deliberate repeat clicks stay separate. */
        private const val CLICK_MERGE_MS = 400.0

        private const val MAX_VALUE = 200
        private const val MAX_LABEL = 120
        private const val MAX_URL = 400
        private const val MAX_STEP_TEXT = 160
        private const val MAX_FLOW_LINE = 1200
        private const val TRUNCATED_KIND = "truncated"

        /** Keys the recorder is allowed to report — `NOTABLE_KEYS`. Everything else a person types
         *  arrives as the field's value on `change`; Escape and Tab are how a form is left or moved. */
        val NOTABLE_KEYS = listOf("Enter", "Escape", "Tab")
    }
}

/**
 * One step, before it is rendered into a row. Flat with every field present rather than an enum with
 * payloads — the shape crosses a JavaScript-payload boundary and a flat record survives that.
 */
data class PhoneStep(
    val kind: Kind,
    val selector: String = "",
    /** Human handle — the element's text, or the field's name. May be empty. */
    val label: String = "",
    val tag: String = "",
    /** What was typed or chosen. Empty when redacted or not applicable. */
    val value: String = "",
    /** The value was deliberately withheld: a password or a file path. */
    val redacted: Boolean = false,
    /** For `press`. One of [PhoneClickFlow.NOTABLE_KEYS]. */
    val key: String = "",
    /** For `check`. */
    val checked: Boolean = false,
    /** The page this happened on, as **this app** knows it. */
    val url: String = "",
    /** Epoch milliseconds, stamped on this side. The page never stamps its own steps. */
    val at: Double = 0.0,
) {
    /** The seven words `StepKind` names, and no eighth. */
    enum class Kind(val wire: String) {
        Navigate("navigate"),
        Click("click"),
        Type("type"),
        Select("select"),
        Check("check"),
        Press("press"),
        Submit("submit");

        companion object {
            fun from(word: String): Kind? = entries.firstOrNull { it.wire == word }
        }
    }
}
