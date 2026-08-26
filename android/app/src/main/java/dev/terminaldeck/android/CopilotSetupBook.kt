package dev.terminaldeck.android

import android.content.Context
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/**
 * The copilot's standing setup, per machine, held on this phone. A port of
 * `ios/TerminalDeck/App/CopilotSetupBook.swift`.
 *
 * Asad, looking at the Copilot tab landing on a two-row chooser: *"Whatever we set in the settings,
 * that copilot will be always on this folder. We will first of all do the setup of a copilot just
 * like we do on desktop application, and then it will be always opening in the same folder."*
 *
 * Two facts, and they are the whole of this file: **which folder** the copilot works in, and
 * **whether the tab may start one by itself**. Nothing else.
 *
 * ## Why this is on the phone and not on the machine
 *
 * `SERVER_SETTINGS` is a closed allowlist of two keys — there is no third key to write — and the
 * desktop's own copilot folder is under the `copilot.` prefix precisely so the settings surface
 * refuses it: *"an agent that can point itself at a folder is an agent that can choose its own
 * instructions."* What this phone decides is what its **own** Copilot tab does when it opens, which
 * is a phone fact, kept per host id — his rented Linux box and his Mac do not share a folder.
 *
 * ## The folder is discovered, not demanded — so an absent record reads as *armed*
 *
 * Asad overruled an earlier decision that gated starting on a record a finger had made: *"the
 * copilot page will directly land into some session — not to a selection and something on the
 * page… if not then it should create itself and start from the beginning."* So a machine with
 * nothing stored here is treated as armed, the tab starts, and the folder it landed in is written
 * down immediately. That is what makes an absent record safe to treat as *yes*, and it is why
 * turning the switch **off** writes — off is now the departure from the default, and an unwritten
 * off would be undone by the next visit.
 *
 * ## Persisted like [dev.terminaldeck.android.ui.theme.AppearanceStore]
 *
 * `SharedPreferences`, not the vault: it is a preference, not a secret, and it must survive a
 * relaunch. One live [MutableState] for the whole process, seeded from disk on first touch and
 * written back on every change — so the tap on the control screen and the save are one gesture,
 * with no Apply, and the row that was flipped repaints and nothing else.
 */
object CopilotSetupBook {

    /**
     * What has been decided about one machine's copilot.
     *
     *  - **folder set, start on** — the ordinary state, reached within a second of the tab opening.
     *  - **no folder, start on** — a desktop (whose folder is chosen at the desk, not on this wire),
     *    and a server in the moment before its first session reports where it is.
     *  - **start off** — somebody who has quietened the tab. The one combination that must be
     *    *written* rather than inferred, because off is no longer the default.
     */
    @Serializable
    data class Setup(val folder: String? = null, val startOnOpen: Boolean = false)

    /** The longest path this store will keep. A path comes off the machine through `folders.list`
     *  rather than a keyboard, so this is a ceiling on what a hostile far end can cost, not input
     *  validation. `PATH_MAX` is 4096 on Linux and 1024 on Darwin; the larger is the honest bound. */
    const val MAX_FOLDER_LENGTH = 4096

    private const val FILE = "terminaldeck.preferences"

    /** `.v1` because a stored preference outlives the build that wrote it. Spelled the same as the
     *  iOS defaults key — the two stores are on different devices and will never meet, and one
     *  spelling is still one fewer thing that can drift. */
    private const val KEY = "terminaldeck.copilotSetup.v1"

    /** Lenient so one record a newer build wrote does not throw away every machine's folder at once
     *  on the launch after an update — the whole-book-in-one-`try` hazard the iOS type note names. */
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /** The whole book: host id to what was decided. Named explicitly rather than left to the reified
     *  overloads so encode and decode cannot resolve to different shapes. */
    private val bookSerializer = MapSerializer(String.serializer(), Setup.serializer())

    /**
     * The one live copy for the whole process. Null before [prime]; reading it in a composable
     * subscribes to it, so flipping the switch repaints the row that was flipped.
     */
    private val state: MutableState<Map<String, Setup>?> = mutableStateOf(null)

    /**
     * Read off disk, once. Idempotent: a second call returns what is already held rather than
     * re-reading, so a screen can prime it from `remember { }` without a second read on every
     * recomposition.
     */
    fun prime(context: Context): Map<String, Setup> {
        state.value?.let { return it }
        val loaded = read(context)
        state.value = loaded
        return loaded
    }

    /* ------------------------------------------------------------------- reading -- */

    /** What was decided about this machine, or null if nothing was. Null is the only answer that
     *  stops the tab starting anything. Read from [state] so a composable follows a write. */
    fun setup(host: String): Setup? = state.value?.get(host)

    /** Whether anything has ever been decided — read only to know if there is a setup to forget. */
    fun isSetUp(host: String): Boolean = state.value?.containsKey(host) == true

    /** **Whether the tab may start one by itself. An absent record means yes.** The default that
     *  flipped: *"if not then it should create itself and start from the beginning."* Off is a
     *  written state — see [setStartOnOpen]. */
    fun isArmed(host: String): Boolean = state.value?.get(host)?.startOnOpen ?: true

    /** The copilot's folder on this machine, or null. Null over a machine that *has* a record means
     *  the folder is not this phone's to choose (a desktop). */
    fun folder(host: String): String? = state.value?.get(host)?.folder

    /* ------------------------------------------------------------------- writing -- */

    /**
     * Point this machine's copilot at a folder.
     *
     * A machine with no record gets one that is armed, because that is what an absent record already
     * meant. A machine that has been **quietened keeps its quiet**: changing where the copilot works
     * must not silently re-arm a tab somebody switched off.
     */
    fun setFolder(context: Context, raw: String?, host: String) {
        if (host.isEmpty()) return
        val path = cleanFolder(raw) ?: return
        val current = ensure(context)
        val existing = current[host]
        val next = if (existing != null) existing.copy(folder = path) else Setup(folder = path, startOnOpen = true)
        write(context, current + (host to next))
    }

    /**
     * Arm or disarm the tab for this machine. **Both directions write** — while off was the state a
     * machine began in, writing it would have made *quietened* and *never opened* indistinguishable;
     * now off is the departure from the default and an unwritten one would spring back on the next
     * visit, on the one control whose whole job is to stop the tab spending money.
     */
    fun setStartOnOpen(context: Context, on: Boolean, host: String) {
        if (host.isEmpty()) return
        val current = ensure(context)
        val existing = current[host]
        val next = if (existing != null) existing.copy(startOnOpen = on) else Setup(folder = null, startOnOpen = on)
        write(context, current + (host to next))
    }

    /**
     * Undo everything decided, so the folder is discovered again next visit. Not *"ask me again"* —
     * nothing asks — but *"work it out again"*: a copilot pinned to a folder since deleted would
     * start there and fail every time. It clears the switch too, so a forgotten machine is an armed
     * one — the honest reading of a row labelled *Forget this setup*.
     */
    fun forget(context: Context, host: String) {
        val current = ensure(context)
        if (!current.containsKey(host)) return
        write(context, current - host)
    }

    /* ------------------------------------------------------------------- static -- */

    /**
     * A folder path as it will be stored, or null when there is nothing usable.
     *
     * Static and separate from [setFolder] so the rules can be pinned without a store. Control
     * characters go (a newline on a row shoves the card under it off screen); a relative path is
     * refused (`create` carries it to a `spawn` on the far machine, where a relative one resolves
     * against whatever that process's cwd is); a trailing separator goes except on the root, so
     * `/srv/api` and `/srv/api/` are one folder rather than two records that never match a `cwd`.
     */
    fun cleanFolder(raw: String?): String? {
        if (raw == null) return null
        val stripped = buildString(raw.length) {
            for (ch in raw) if (!ch.isISOControl()) append(ch)
        }
        val trimmed = stripped.trim().take(MAX_FOLDER_LENGTH)
        if (trimmed.firstOrNull() != '/') return null
        return normalise(trimmed)
    }

    /**
     * One folder path, in the shape two of them can be compared in. Trailing separators only — not
     * case and not symlink resolution: the far end is Linux as often as macOS, and lower-casing
     * would call `/srv/API` and `/srv/api` one folder on a filesystem where they are two.
     */
    fun normalise(path: String): String {
        if (path.length <= 1) return path
        var trimmed = path
        while (trimmed.length > 1 && trimmed.endsWith("/")) trimmed = trimmed.dropLast(1)
        return trimmed
    }

    /** Whether two paths name the same folder. One reading of it, so the screen that draws *the
     *  copilot's session* and the rule that decides whether to start one cannot disagree. */
    fun sameFolder(a: String?, b: String?): Boolean {
        if (a.isNullOrEmpty() || b.isNullOrEmpty()) return false
        return normalise(a) == normalise(b)
    }

    /* ------------------------------------------------------------------ storage -- */

    private fun ensure(context: Context): Map<String, Setup> = state.value ?: prime(context)

    private fun read(context: Context): Map<String, Setup> {
        val raw = context.applicationContext
            .getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .getString(KEY, null) ?: return emptyMap()
        val stored = try {
            json.decodeFromString(bookSerializer, raw)
        } catch (_: Exception) {
            // A book written by a build this one cannot read is a book, not a crash. Cleaned on the
            // way back out as well as in, for the reason iOS's `load` gives: a record whose folder no
            // longer survives the clean keeps its switch and loses its path, which reads as a desktop.
            return emptyMap()
        }
        return stored.mapValues { (_, setup) -> setup.copy(folder = cleanFolder(setup.folder)) }
    }

    private fun write(context: Context, records: Map<String, Setup>) {
        state.value = records
        val encoded = try {
            json.encodeToString(bookSerializer, records)
        } catch (_: Exception) {
            return
        }
        context.applicationContext
            .getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, encoded)
            .apply()
    }
}
