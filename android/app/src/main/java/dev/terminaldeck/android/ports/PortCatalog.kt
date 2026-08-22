package dev.terminaldeck.android.ports

import dev.terminaldeck.android.protocol.DevServerReport
import dev.terminaldeck.android.protocol.DevServerStatus
import dev.terminaldeck.android.protocol.LocalPort

/**
 * Turning a wall of ports into a few groups, from facts rather than from guesses.
 *
 * Asad, on the list as it was: *"I can already see a big list of local hosts. So it should not be
 * like that… I think they are different categories also. So maybe we can categorize and we can keep
 * some in the list and we can keep some folded… so we don't see a lot of jargon, unnecessary ones."*
 *
 * A transcription of `ios/TerminalDeck/Ports/PortCatalog.swift`.
 *
 * ## Every group is derived from something the wire actually carries
 *
 * There are exactly three inputs, and no fourth is invented:
 *
 *  1. **[LocalPort]** — a port number, the name of the process holding it, and `guessed`, which says
 *     the port answers but nothing could name its owner. `dev-ports.ts` is deliberate about this: it
 *     *refuses* to guess which framework is behind a port, and this file does not do the guessing on
 *     its behalf. A process name is a fact about a process, not a claim about a page.
 *  2. **[DevServerReport]** — a project folder this machine granted this phone, and the port its dev
 *     server is proven to be accepting on. This is the only input that can say *what a port is
 *     serving*, because the desktop started it.
 *  3. **This product's own binary name.** How a port that belongs to the desktop app itself is
 *     recognised instead of being offered as somebody's dev server.
 *
 * What is **not** here: no table of "3000 means Next, 5173 means Vite", no inference from a port
 * number to a framework, no list of ports somebody else's machine is expected to have. A port number
 * is a number a person chose.
 *
 * ## One row per server, never two
 *
 * A dev server this phone started shows up twice if nothing joins them: once as `myproject` from
 * `dev.state`, and once as `localhost:5173 node` from `ports`. They are the same server, and the
 * join is a fact rather than a heuristic — [DevServerReport.port] is a port the desktop **dialled and
 * got an answer on**. So a `ready` report claims its port, the port row is dropped, and the merged
 * row carries both the project's name and the address.
 */
object PortCatalog {

    /**
     * Runtimes that usually *are* serving a page.
     *
     * `LIKELY_DEV` from `dev-ports.ts`, mirrored — the same list the desktop already uses to decide
     * which ports to print first, so the phone's grouping and the desktop's ordering agree about
     * what looks like a web server.
     *
     * Matched as a prefix rather than exactly, because the same runtime is spelled several ways by
     * the two scanners: `python` and `python3`, and on Windows `node` comes back from `tasklist`
     * with the `.exe` already taken off but a version suffix sometimes still attached.
     */
    val webRuntimes = listOf(
        "node", "bun", "deno", "python", "ruby", "php", "java", "dotnet", "caddy", "nginx",
    )

    fun isWebRuntime(process: String): Boolean {
        val name = process.lowercase()
        return webRuntimes.any { name.startsWith(it) }
    }

    /**
     * Whether the desktop half of *this product* is what is holding the port.
     *
     * Two spellings, because two operating systems name the same binary differently and neither is a
     * guess: Windows' `tasklist` reports the executable with `.exe` stripped, which is the product
     * name with its space — and a slug build has no space.
     *
     * On macOS this almost never fires, and that is a known gap rather than a bug here: `parseLsof`
     * splits its columns on whitespace, so a command name containing a space shifts the columns and
     * the row is dropped before it reaches the wire. The app's own listener therefore does not appear
     * in the list on a Mac at all — a *quieter* wrong answer than the one this exists to prevent, and
     * it is fixed on the desktop or not at all.
     */
    fun isOwnProcess(process: String): Boolean {
        val name = process.lowercase().replace(" ", "")
        return name == BRAND_NAME.lowercase().replace(" ", "") || name == BRAND_ID
    }

    /**
     * The whole screen's content, grouped and ordered.
     *
     * Pure, and takes its inputs rather than reading a view model, so every rule in the table above
     * is pinned by a test that needs no device and no host.
     *
     * [names] is a snapshot keyed by port rather than the store itself, so this file never learns
     * which machine it is describing.
     *
     * Order within a section is the order the two lists arrived in: the desktop ranks its ports
     * most-likely-to-be-a-dev-server first and offers its folders most-relevant-first, and re-sorting
     * here would throw away the only ordering anybody has an opinion about.
     */
    fun sections(
        ports: List<LocalPort>,
        devServers: List<DevServerReport>,
        appPorts: Set<Int> = emptySet(),
        names: Map<Int, String> = emptyMap(),
    ): List<LocalhostSection> {
        val rows = mutableListOf<LocalhostRow>()
        /** Ports a dev server has claimed. See "One row per server, never two". */
        val claimed = HashSet<Int>()

        for (report in devServers) {
            // `no-dev-script` is never a row. It means "there is nothing to press, and there never
            // will be for this folder", and a row with no verb on it is a row that only explains
            // itself.
            if (report.status == DevServerStatus.NoDevScript) continue
            // Only a `ready` report has a proven port. A `starting` one has no port field at all and
            // a `failed` one must never carry the address of the server that died.
            val port = if (report.status == DevServerStatus.Ready) report.port else null
            if (port != null) claimed += port
            val entry = port?.let { candidate -> ports.firstOrNull { it.port == candidate } }
            val label = port?.let { names[it] }
            rows += LocalhostRow(
                entry = entry,
                dev = report,
                name = label,
                category = if (label == null) PortCategory.DevServer else PortCategory.Named,
            )
        }

        for (entry in ports) {
            if (entry.port in claimed) continue
            val label = names[entry.port]
            rows += LocalhostRow(
                entry = entry,
                dev = null,
                name = label,
                category = categoryFor(entry, named = label != null, appPorts = appPorts),
            )
        }

        return PortCategory.entries.mapNotNull { category ->
            val inside = rows.filter { it.category == category }
            if (inside.isEmpty()) null else LocalhostSection(category, inside)
        }
    }

    /** What the row's second control offers. The table is on [PortRowAction]; this decides it. */
    fun secondAction(row: LocalhostRow): PortRowAction {
        val dev = row.dev
        if (dev != null) {
            return when (dev.status) {
                DevServerStatus.Idle -> PortRowAction.Start(dev.folder)
                DevServerStatus.Failed -> PortRowAction.Retry(dev.folder)
                DevServerStatus.Starting, DevServerStatus.Ready ->
                    dev.sessionId?.let { PortRowAction.OpenSession(it) } ?: PortRowAction.None
                DevServerStatus.NoDevScript, DevServerStatus.Unknown -> PortRowAction.None
            }
        }
        val entry = row.entry ?: return PortRowAction.None
        return PortRowAction.CopyAddress(entry.port)
    }

    /**
     * Which pile one listening port lands in.
     *
     * The order of the tests is the order of the claims' strength, and two of them are load-bearing:
     *
     *  - **The app's own port is checked before the runtime name.** A desktop running headless is a
     *    `node` process, so a machine reached over a direct endpoint would otherwise offer this phone
     *    its own control socket under "Web servers" — a row that opens the thing that drew it.
     *  - **`guessed` is checked before the runtime name** only for tidiness; a port with no owner
     *    reports its process as `unknown`, which matches no runtime either way. It is its own group
     *    rather than part of "Other" because "we could not name this" and "this is named and dull"
     *    are different facts, and only one of them might be worth a second look.
     */
    private fun categoryFor(entry: LocalPort, named: Boolean, appPorts: Set<Int>): PortCategory = when {
        named -> PortCategory.Named
        entry.port in appPorts || isOwnProcess(entry.process) -> PortCategory.App
        entry.guessed -> PortCategory.Unnamed
        isWebRuntime(entry.process) -> PortCategory.Web
        else -> PortCategory.Other
    }

    /**
     * The product's name and slug.
     *
     * Held here rather than read from a brand module, because Android has none: the desktop keeps
     * the single source of truth in `src/shared/brand.ts` and the two strings below are the two
     * spellings that file produces. `PortCatalogTest` pins them, so a rename that reached this client
     * without reaching this file fails the suite rather than quietly stopping the app's own port from
     * being recognised.
     */
    internal const val BRAND_NAME = "Terminal Deck"
    internal const val BRAND_ID = "terminaldeck"
}

/**
 * Which pile a row lands in.
 *
 * The declaration order is the order the sections are drawn in, so it goes from "this is why you
 * opened the screen" to "this is the noise".
 */
enum class PortCategory {
    /** The phone has a name for this port. See [PortBook]. */
    Named,

    /** A project's dev server, from `dev.state`. */
    DevServer,

    /** The process is one of the runtimes that usually is serving a page. */
    Web,

    /** The desktop application itself is holding it. */
    App,

    /** A named process that is none of the above. */
    Other,

    /** The port answers and nothing could name its owner. */
    Unnamed,
    ;

    /** What the section header says. Uppercased by the header itself. */
    val title: String
        get() = when (this) {
            Named -> "Named by you"
            DevServer -> "Dev servers"
            Web -> "Web servers"
            // The product's own name rather than "this app", because on a phone paired with three
            // machines the question being answered is *which* program on that machine holds the port.
            App -> PortCatalog.BRAND_NAME
            Other -> "Other services"
            Unnamed -> "Unidentified"
        }

    /**
     * Whether the group starts closed.
     *
     * The three that start closed are the three whose rows are, on a normal machine, things nobody
     * opened the screen to look at. It is a *starting* position and not a rule: [PortBook] remembers
     * the first time somebody disagrees, per machine, because a WSL box where `wslrelay` is the whole
     * point is a real machine.
     */
    val foldedByDefault: Boolean
        get() = when (this) {
            Named, DevServer, Web -> false
            App, Other, Unnamed -> true
        }
}

/**
 * One row on the localhost screen.
 *
 * Either a listening port, or a project's dev server, or — when the two are the same server — both.
 * [dev] and [entry] are never both null.
 */
data class LocalhostRow(
    /** What is listening, when something is. Null for a dev server that is not up. */
    val entry: LocalPort?,
    /** The project behind it, when this machine has told us about one. */
    val dev: DevServerReport?,
    /** The user's name for this port, or null. */
    val name: String?,
    val category: PortCategory,
) {
    /**
     * The port, from whichever half of the row knows it.
     *
     * Null only for a dev server that has not come up — which is exactly the row whose whole point is
     * that there is no port yet.
     */
    val port: Int? get() = entry?.port ?: dev?.port

    /**
     * Stable across a refresh, which is what keeps the list from re-animating every row each time the
     * machine answers. Keyed on the folder for a dev server, because its port changes when Vite takes
     * 5174 instead of 5173.
     */
    val id: String get() = dev?.let { "dev:${it.folder}" } ?: "port:${entry?.port ?: "?"}"
}

data class LocalhostSection(val category: PortCategory, val rows: List<LocalhostRow>)

/**
 * The row's second control.
 *
 * A value rather than a `when` inside the view, because this is the answer to *"what do start and
 * stop do in each of the five states"* and that answer has to be checkable without a device, a paired
 * machine and a project on it.
 *
 * | row | second action | why |
 * |---|---|---|
 * | dev server, `idle` | **Start** | `dev.start`, and the tap is the consent |
 * | dev server, `starting` | **Session** | watch it come up; a second start would be a second start |
 * | dev server, `ready` | **Session** | where it is running — and where Ctrl-C stops it |
 * | dev server, `failed` | **Try again** | `dev.start` re-reads the folder, so a fixed `package.json` is picked up |
 * | dev server, `no-dev-script` | *nothing* | there is no row at all |
 * | a plain listening port | **Copy** | nothing on the wire can start or stop "whatever is on 2019" |
 *
 * `starting` and `ready` fall back to [None] when the report carries no session, which the protocol
 * says cannot happen — both states are defined to have one. Drawing a control that would have
 * nowhere to go is worse than drawing none, so the impossible case is handled rather than forced.
 *
 * **There is no Stop, and it is not an oversight.** A dev server runs in an ordinary session — the
 * desktop opens a shell in the project folder and types the command into it — so stopping one is
 * Ctrl-C in that session, which is why the wire has no stop verb to send. What this screen will not
 * do is type the interrupt blindly: the desktop decides a folder is `ready` and only stops saying so
 * when the *session* exits, which a Ctrl-C into a shell does not do. The row would go on offering an
 * address for a server that had gone — the one thing [DevServerReport] says a client must never
 * display. So the action opens the session, with the interrupt one key away on the key bar.
 */
sealed interface PortRowAction {
    /** `dev.start` for a project that is not running. */
    data class Start(val folder: String) : PortRowAction

    /** `dev.start` again for one that failed. A different word on the button: the row leads to the
     *  reason, and this is the deliberate second press. */
    data class Retry(val folder: String) : PortRowAction

    /** Open the ordinary session the dev server runs in. **This is also how one is stopped.** */
    data class OpenSession(val id: String) : PortRowAction

    /** Put `http://localhost:<port>` on the clipboard. */
    data class CopyAddress(val port: Int) : PortRowAction

    /** Nothing to offer. */
    data object None : PortRowAction
}
