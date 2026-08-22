package dev.terminaldeck.android.ports

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * What this phone calls the ports on a machine, and which groups it has folded.
 *
 * Asad, walking the localhost list on his phone: *"if we see the full list also, we will not be able
 * to know which one holds what stuff, what is inside any of them… we should be able to maybe rename
 * them or something under there… agent service, WSL relay thing. Maybe we can rename them somehow."*
 * The list he was looking at read `localhost:2019 wslrelay`, `localhost:2222 wslrelay`,
 * `localhost:3100 wslrelay`, `localhost:6666 AgentService` — four process names that say nothing
 * about what is being served, and no way to write down what he had worked out.
 *
 * A transcription of `ios/TerminalDeck/Ports/PortBook.swift`.
 *
 * ## Why the name lives here and not on the desktop
 *
 * Because the desktop does not know it either. `dev-ports.ts` deliberately refuses to guess which
 * framework is behind a port; all it can honestly report is the number and the process holding it.
 * The missing knowledge is a person's, so this is where it is kept — on the phone, against the
 * machine and the port.
 *
 * A name is also the only *promotion* control this screen has. Naming a port is a statement that it
 * matters, so a named port is lifted out of whatever pile it was derived into and shown first. That
 * is one control doing the job of two — see [PortCatalog] for the grouping that reads it.
 *
 * ## Keyed by host **and** port, because 3000 is not one thing
 *
 * A phone paired with a Mac and a Windows PC is holding two completely unrelated port 3000s, and a
 * store keyed on the number alone would show the Mac's name over the PC's server.
 *
 * Names are **not** dropped when a machine is forgotten. That matches the machine's nickname, which
 * also survives a re-pair, and it is the kinder failure: a few dozen bytes of dead text is nothing,
 * and somebody who unpairs a machine by accident does not also lose the work of naming its ports.
 *
 * ## The text is bounded on the way in
 *
 * It is the user's own text rather than something a machine sent, so it is not untrusted in the way
 * `DevServerReport.note` is — but it still lands on a phone row, and a pasted paragraph with a
 * newline in it would push a card to three lines and shove everything below it off the screen.
 * [clean] trims it, folds out anything that is not printable, and cuts it to a length that fits.
 */
class PortBook(private val store: Store) {

    /** Where the book is kept. A seam so a test can drive one that is not a device's disk. */
    interface Store {
        fun read(): String?
        fun write(value: String)
    }

    /** host id → port number (as text, because a JSON object's keys are strings) → the name. */
    private val names = HashMap<String, MutableMap<String, String>>()

    /** host id → category name → whether that group is closed on this machine. */
    private val folds = HashMap<String, MutableMap<String, Boolean>>()

    init {
        load()
    }

    fun name(host: String, port: Int): String? = names[host]?.get(port.toString())

    /** Every name this phone holds for one machine, keyed by port, for [PortCatalog.sections]. */
    fun names(host: String): Map<Int, String> =
        names[host].orEmpty().mapNotNull { (key, value) -> key.toIntOrNull()?.let { it to value } }.toMap()

    /**
     * Give a port a name, or take its name away.
     *
     * A blank name is a removal rather than an empty string, because those are the same intention and
     * storing one of them would leave a row promoted to "Named by you" with nothing written on it.
     */
    fun setName(raw: String?, host: String, port: Int) {
        if (host.isEmpty()) return
        val cleaned = clean(raw)
        val forHost = names.getOrPut(host) { HashMap() }
        if (cleaned == null) forHost.remove(port.toString()) else forHost[port.toString()] = cleaned
        if (forHost.isEmpty()) names.remove(host)
        save()
    }

    /** Whether a group is closed on this machine: the user's choice where they have made one, the
     *  category's own default where they have not. */
    fun isFolded(host: String, category: PortCategory): Boolean =
        folds[host]?.get(category.name) ?: category.foldedByDefault

    /**
     * Remember that a group was opened or closed.
     *
     * Per machine, because a WSL box where `wslrelay` is the whole point is a real machine and the
     * default that is right for a Mac is wrong for it.
     */
    fun setFolded(folded: Boolean, host: String, category: PortCategory) {
        if (host.isEmpty()) return
        folds.getOrPut(host) { HashMap() }[category.name] = folded
        save()
    }

    /* ------------------------------------------------------------------- storage -- */

    @Serializable
    internal data class Stored(
        val names: Map<String, Map<String, String>> = emptyMap(),
        val folds: Map<String, Map<String, Boolean>> = emptyMap(),
    )

    private fun load() {
        val raw = store.read() ?: return
        val stored = try {
            JSON.decodeFromString(Stored.serializer(), raw)
        } catch (_: Exception) {
            return
        }
        names.clear()
        folds.clear()
        // Cleaned on the way back out as well as on the way in: a record written by another build
        // must not be able to get around the bound this store promises to hold.
        for ((host, ports) in stored.names) {
            val cleaned = ports.mapNotNull { (key, value) -> clean(value)?.let { key to it } }.toMap()
            if (cleaned.isNotEmpty()) names[host] = HashMap(cleaned)
        }
        for ((host, byCategory) in stored.folds) {
            val known = byCategory.filterKeys { key -> PortCategory.entries.any { it.name == key } }
            if (known.isNotEmpty()) folds[host] = HashMap(known)
        }
    }

    private fun save() {
        store.write(
            JSON.encodeToString(
                Stored.serializer(),
                Stored(names.mapValues { it.value.toMap() }, folds.mapValues { it.value.toMap() }),
            )
        )
    }

    companion object {
        /**
         * The most a name may be.
         *
         * Long enough for *"the API the agent keeps talking about"* and short enough that a row stays
         * one line on the narrowest phone this app supports.
         */
        const val MAX_NAME_LENGTH = 40

        private val JSON = Json { ignoreUnknownKeys = true }

        private const val FILE = "terminaldeck.preferences"
        private const val KEY = "terminaldeck.portBook.v1"

        /**
         * One name, as it will be stored.
         *
         * Static so a field can show the same limit it will be held to, and so the rule can be
         * checked without a store.
         *
         * Newlines go with the other control characters rather than being turned into spaces. A name
         * with a line break in it is a paste accident, not an intention, and joining the halves with
         * a space guesses at what was meant.
         */
        fun clean(raw: String?): String? {
            if (raw == null) return null
            val stripped = raw.filterNot { it.isISOControl() }
            val trimmed = stripped.trim()
            if (trimmed.isEmpty()) return null
            if (trimmed.length <= MAX_NAME_LENGTH) return trimmed
            // Trimmed again after the cut: a name that runs out mid-word leaves a trailing space that
            // would come back as a different string than the one the field showed.
            return trimmed.take(MAX_NAME_LENGTH).trimEnd()
        }

        /** The real store: the same preferences file the appearance and the shelf use. */
        fun on(context: Context): PortBook = PortBook(object : Store {
            private val prefs =
                context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

            override fun read(): String? = prefs.getString(KEY, null)

            override fun write(value: String) {
                prefs.edit().putString(KEY, value).apply()
            }
        })
    }
}
