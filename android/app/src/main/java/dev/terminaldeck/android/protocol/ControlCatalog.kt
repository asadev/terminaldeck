package dev.terminaldeck.android.protocol

/**
 * What each control is allowed to offer, and how to describe it — the phone's copy of the desktop's
 * control catalogue.
 *
 * A transcription of `src/renderer/chat/controls/catalog.ts` and the fallback rows of
 * `src/shared/model-catalog.ts`, kept byte-compatible with the same copy iOS carries in
 * `ios/TerminalDeck/Protocol/ControlCatalog.swift`. The desktop's own cluster and the PWA both read
 * that one TypeScript file so the surfaces offer identical options; Kotlin cannot import it, so this
 * is the copy, and it changes only when that file changes, with the same ids and labels. The values
 * here are what get typed at the real `claude` binary, which is why the ids are frozen rather than
 * free text.
 *
 * Only the fallback model list is carried — the phone never scrapes a live picker — so there is no
 * default row to fold and the rows pass through unchanged.
 */

/**
 * One row of a control's sheet.
 *
 * [hint] is a short tag under the label for a fact about *this* account a reader cannot get from the
 * row itself; [group] is a caption starting a run of a different kind of claim (the "Earlier models"
 * heading). A description that would be true of any reader belongs to neither.
 */
data class ControlOption(
    val id: String,
    val label: String,
    val hint: String? = null,
    val group: String? = null,
)

object ControlCatalog {

    /**
     * The five permission modes, in the order shift+tab visits them. `dontAsk` is deliberately
     * absent — the CLI accepts it but never cycles into it.
     */
    val permission: List<ControlOption> = listOf(
        ControlOption("plan", "Plan", "Research and propose; change nothing"),
        ControlOption("manual", "Manual", "Ask before every action that needs permission"),
        ControlOption("acceptEdits", "Accept edits", "File edits go through without asking"),
        ControlOption("auto", "Auto", "Claude judges each call and blocks risky ones"),
        ControlOption("bypass", "Bypass", "No permission checks at all"),
    )

    /**
     * Effort levels. Extra high is first because it is what this app sets when nothing is set, and
     * the first row of a menu reads as the default.
     */
    val effort: List<ControlOption> = listOf(
        ControlOption("xhigh", "Extra high", "the default here"),
        ControlOption("ultracode", "Ultracode", "this session only"),
        ControlOption("max", "Max"),
        ControlOption("high", "High"),
        ControlOption("medium", "Medium"),
        ControlOption("low", "Low"),
        ControlOption("auto", "Auto"),
    )

    /** Fast mode's two positions. A switch at the end of the model sheet, not a menu of its own. */
    val fast: List<ControlOption> = listOf(
        ControlOption("off", "Off"),
        ControlOption("on", "On"),
    )

    /**
     * The models the CLI's picker lists, folded the way the desktop folds them. `recommended`
     * becomes the "your account's default" tag; everything else carries no hint.
     */
    val models: List<ControlOption> = FALLBACK_MODELS.map { row ->
        ControlOption(
            id = row.alias,
            label = row.model,
            hint = if (row.recommended) "your account’s default" else null,
        )
    }

    /**
     * The models `/model` still accepts but the picker no longer lists — run together with the
     * picker's rows they read as one list where half are guaranteed and half are not, which is what
     * the caption exists to end.
     */
    val previousModels: List<ControlOption> = PREVIOUS_MODELS.mapIndexed { index, row ->
        ControlOption(
            id = row.alias,
            label = row.model,
            group = if (index == 0) "Earlier models" else null,
        )
    }

    /** The rows of one chip's sheet. */
    fun rows(control: ControlName): List<ControlOption> = when (control) {
        ControlName.Model -> models + previousModels
        ControlName.Effort -> effort
        ControlName.Permission -> permission
        ControlName.Fast -> fast
    }

    fun name(control: ControlName): String = when (control) {
        ControlName.Model -> "Model"
        ControlName.Effort -> "Effort"
        ControlName.Fast -> "Fast mode"
        ControlName.Permission -> "Permission"
    }

    /**
     * The unread word for a control: `Not reported` for permission (the CLI prints it only when it
     * changes), `Unknown` for the rest.
     */
    fun unreadLabel(control: ControlName): String =
        if (control == ControlName.Permission) "Not reported" else "Unknown"

    /**
     * What a chip prints. A reading with no label shows the unread word; a model label is shortened
     * the way the desktop's chip shortens it.
     */
    fun displayValue(reading: ControlReadingWire, control: ControlName): String {
        val label = reading.label ?: return unreadLabel(control)
        return if (control == ControlName.Model) shortModelLabel(label) else label
    }

    /**
     * Whether an option is the one in force.
     *
     * Exact id first; then a normalised name-and-1M comparison, so a screen that printed
     * "Opus 5 (recommended)" still ticks the `opus` row. A transcription of `isCurrent`.
     */
    fun isCurrent(reading: ControlReadingWire, option: ControlOption): Boolean {
        val value = reading.value ?: return false
        if (value == option.id) return true
        val shown = reading.label ?: ""
        if (shown.isBlank()) return false
        val read = modelKey(shown)
        val offered = modelKey(option.label)
        return read.first.isNotEmpty() && read == offered
    }

    /** The short label a model chip shows: the name, `Plan` folded in, `1M` kept. */
    fun shortModelLabel(label: String): String {
        val text = label.trim()
        PLAN_MODE.find(text)?.groupValues?.getOrNull(1)?.let { return "$it Plan" }
        val long = text.contains("1m", ignoreCase = true)
        val name = text
            .replace(DECORATION, "")
            .replace(LONG_CONTEXT, "")
            .replace(RUNS, " ")
            .trim()
        return if (long) "$name 1M" else name
    }

    /**
     * The normalised key two labels are compared on: lowercased, decorations stripped, and whether
     * it carries a 1M context. A transcription of `modelKey`.
     */
    private fun modelKey(text: String): Pair<String, Boolean> {
        val lower = text.lowercase()
        val long = lower.contains("1m")
        val name = lower
            .replace(DECORATION, "")
            .replace(LONG_CONTEXT, "")
            .replace(NON_KEY, " ")
            .replace(RUNS, " ")
            .trim()
        return name to long
    }

    private val PLAN_MODE = Regex("^(\\S+) in plan mode", RegexOption.IGNORE_CASE)
    private val DECORATION = Regex("\\((?:default|recommended)\\)", RegexOption.IGNORE_CASE)
    private val LONG_CONTEXT =
        Regex("\\(1m context\\)|with 1m context|·\\s*1m", RegexOption.IGNORE_CASE)
    private val NON_KEY = Regex("[^a-z0-9. ]+")
    private val RUNS = Regex("\\s+")
}

/** One row of the fallback model list. Private shape; only [ControlCatalog] folds these. */
private data class ModelRow(val alias: String, val model: String, val recommended: Boolean)

private val FALLBACK_MODELS: List<ModelRow> = listOf(
    ModelRow("opus[1m]", "Opus 5 with 1M context", true),
    ModelRow("opus", "Opus 5", false),
    ModelRow("fable", "Fable 5", false),
    ModelRow("sonnet", "Sonnet 5", false),
    ModelRow("haiku", "Haiku 4.5", false),
    ModelRow("opusplan", "Opus in plan mode, else Sonnet", false),
)

private val PREVIOUS_MODELS: List<ModelRow> = listOf(
    ModelRow("claude-opus-4-8", "Opus 4.8", false),
    ModelRow("claude-opus-4-5", "Opus 4.5", false),
    ModelRow("claude-sonnet-4-6", "Sonnet 4.6", false),
)
