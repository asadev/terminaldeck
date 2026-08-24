package dev.terminaldeck.android.ui.theme

import android.content.Context
import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.UUID

/**
 * Which terminal scheme is in use, and the ones somebody made.
 *
 * The same shape as [AppearanceStore], for the same reason it gives: the control that changes this
 * is a row deep inside a settings sheet, and the thing that has to repaint is a terminal on another
 * screen entirely. One piece of observable state is the way that arrives; a value threaded through
 * four screens is not.
 *
 * ## `SharedPreferences`, not the vault
 *
 * A colour scheme is not a secret, and it has to be readable on the frame that installs the palette
 * — before the first session can be attached. `DeviceVault` is an encrypted file behind the
 * Keystore; putting a list of hex codes in it would put a keystore round-trip on the path that
 * builds the terminal, for nothing.
 *
 * ## What happens when the stored list is broken
 *
 * It is skipped, and the app comes up on the built-ins. A preference read off disk is input: it can
 * have been written by a build whose model was different, or truncated by a phone that died
 * mid-write. The alternative — throwing — is an app that will not start because a colour is
 * malformed, which is a far worse failure than a lost custom scheme. It is logged, so it is not
 * *silent*, and the built-ins are always there to fall back to.
 */
object TerminalSchemeStore {

    private const val FILE = "terminaldeck.display"

    /**
     * `.v1` on both keys, for the reason [Appearance.Companion.KEY] gives: a stored preference
     * outlives the build that wrote it, so if these ever change meaning the key changes with them
     * rather than a new build inheriting a value that means something else.
     */
    private const val KEY_SELECTED = "terminal.scheme.v1"
    private const val KEY_CUSTOM = "terminal.customSchemes.v1"

    /**
     * Lenient on the way in, so one unknown field written by a newer build does not throw away
     * every scheme beside it, and `encodeDefaults` off so the file stays the twenty-one colours it
     * looks like.
     */
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    /** Named once, so the read and the write cannot disagree about what is on disk. */
    private val schemeList = ListSerializer(TerminalScheme.serializer())

    private val selected: MutableState<String?> = mutableStateOf(null)
    private val customs: MutableState<List<TerminalScheme>?> = mutableStateOf(null)

    /**
     * Read both off disk before the first frame.
     *
     * Called from `MainActivity.onCreate` *before* `setContent`, beside [AppearanceStore.prime],
     * because the emulator's palette is installed from this and a session constructed before it has
     * been read would copy the wrong table and keep it.
     */
    fun prime(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        if (selected.value == null) {
            selected.value = prefs.getString(KEY_SELECTED, null) ?: TerminalSchemes.MATCH_APPEARANCE
        }
        if (customs.value == null) {
            customs.value = decode(prefs.getString(KEY_CUSTOM, null))
        }
    }

    /**
     * What is on disk, as schemes — and `emptyList()` for anything that is not.
     *
     * Pure and internal so the fallback can be *tested* rather than asserted about in a comment:
     * this is the path a phone takes after a bad write or a downgrade, and it is the one path here
     * where getting it wrong means the app will not start. `SharedPreferences` needs a `Context`
     * that a unit test on this module does not have, so the decision is separated from the read.
     */
    internal fun decode(raw: String?): List<TerminalScheme> {
        if (raw.isNullOrBlank()) return emptyList()
        return try {
            json.decodeFromString(schemeList, raw)
                // A stored scheme may not claim a shipped id: the built-in would become
                // unreachable and the two would disagree about what "Nord" is.
                .filter { it.id !in TerminalSchemes.builtInIds }
        } catch (error: Exception) {
            Log.w("TerminalSchemeStore", "stored schemes unreadable, falling back to built-ins", error)
            emptyList()
        }
    }

    /** The chosen id, as observable state. [TerminalSchemes.MATCH_APPEARANCE] until somebody picks. */
    val selectedId: State<String?> get() = selected

    /** The schemes somebody made, as observable state. */
    val customSchemes: State<List<TerminalScheme>?> get() = customs

    /** Everything that can be chosen: what ships, then what was made here. */
    fun all(): List<TerminalScheme> = TerminalSchemes.builtIns + (customs.value ?: emptyList())

    fun scheme(id: String): TerminalScheme? = all().firstOrNull { it.id == id }

    /**
     * The scheme to draw with, given what the app's appearance currently resolves to.
     *
     * Two fallbacks, and both are real cases rather than defensive noise: [TerminalSchemes.MATCH_APPEARANCE]
     * is the default and has no colours of its own, and a stored id can name a custom scheme that
     * has since been deleted — by this phone, or by a restore from a backup that predates it.
     * Either way the answer is the appearance-matched scheme, which is the one nobody can be
     * surprised by.
     */
    fun resolve(dark: Boolean): TerminalScheme =
        resolve(selected.value, customs.value ?: emptyList(), dark)

    /** The same decision, without the process-wide state, so both fallbacks can be tested. */
    internal fun resolve(id: String?, custom: List<TerminalScheme>, dark: Boolean): TerminalScheme {
        val chosen = id ?: TerminalSchemes.MATCH_APPEARANCE
        if (chosen == TerminalSchemes.MATCH_APPEARANCE) return TerminalSchemes.forAppearance(dark)
        return (TerminalSchemes.builtIns + custom).firstOrNull { it.id == chosen }
            ?: TerminalSchemes.forAppearance(dark)
    }

    fun select(context: Context, id: String) {
        selected.value = id
        context.applicationContext
            .getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_SELECTED, id)
            .apply()
    }

    /**
     * Write a custom scheme, creating or replacing.
     *
     * Replacing in place rather than appending, so that dragging a colour slider does not leave
     * forty copies of the same scheme behind it.
     */
    fun save(context: Context, scheme: TerminalScheme) {
        require(scheme.id !in TerminalSchemes.builtInIds) { "cannot overwrite the built-in ${scheme.id}" }
        val next = (customs.value ?: emptyList()).toMutableList()
        val at = next.indexOfFirst { it.id == scheme.id }
        if (at >= 0) next[at] = scheme else next += scheme
        write(context, next)
    }

    /**
     * Forget one.
     *
     * If it was the one in use, the choice goes back to matching the appearance rather than to some
     * other scheme — deleting a scheme should not silently pick a different one on somebody's
     * behalf, and there is no "previous" to go back to.
     */
    fun delete(context: Context, id: String) {
        write(context, (customs.value ?: emptyList()).filterNot { it.id == id })
        if (selected.value == id) select(context, TerminalSchemes.MATCH_APPEARANCE)
    }

    private fun write(context: Context, schemes: List<TerminalScheme>) {
        customs.value = schemes
        context.applicationContext
            .getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_CUSTOM, json.encodeToString(schemeList, schemes))
            .apply()
    }

    /** An id no scheme on this phone has. Random, so two phones making a copy cannot collide. */
    fun newId(): String = "custom-" + UUID.randomUUID().toString().take(8)

    /**
     * What a copy of [base] is called.
     *
     * *"Nord copy"*, then *"Nord copy 2"*. Numbered only from the second, because *"Nord copy 1"*
     * implies a set of them that does not exist yet.
     */
    fun copyName(base: String): String = copyName(base, all().map { it.name }.toSet())

    /** The same naming, against a stated set of names, so the numbering can be tested. */
    internal fun copyName(base: String, taken: Set<String>): String {
        val first = "$base copy"
        if (first !in taken) return first
        var n = 2
        while ("$first $n" in taken) n++
        return "$first $n"
    }
}

/**
 * The scheme to draw with, resolved and observable, for a composable.
 *
 * Reads both pieces of state, so a screen that calls this repaints when the choice changes *and*
 * when the scheme it points at is edited — which is what makes an edit land on a live session
 * without anything having to be told about it.
 */
@Composable
fun currentTerminalScheme(dark: Boolean): TerminalScheme {
    // Both reads are subscriptions; neither result is used directly, and removing either would
    // break live editing in a way no test that only calls resolve() would notice.
    TerminalSchemeStore.selectedId.value
    TerminalSchemeStore.customSchemes.value
    return TerminalSchemeStore.resolve(dark)
}
