package dev.terminaldeck.android.servers

import dev.terminaldeck.android.signin.ServerAddress

/** Whether the host on that server is up, as far as its own `status` will say. */
enum class HostRunning { YES, NO, UNKNOWN }

/** What one probe found out about the headless host on one server. */
data class HostOnServer(
    /** The absolute path of the `terminaldeck` command, or `""` when there is none. */
    val command: String = "",
    /** What it answers to `--version`, or `""` when it will not start. */
    val version: String = "",
    val running: HostRunning = HostRunning.UNKNOWN,
    /** The host's own `status` output, verbatim. Empty when there is nothing to ask. */
    val status: String = "",
    /** The pasteable **server address** that host printed, or `""`. */
    val address: String = "",
    /** `active`, `inactive`, `failed`, or `""` when there is no unit of ours. */
    val unit: String = "",
    /** True when the account's own systemd will keep it running after the last login ends. */
    val linger: Boolean = false,
    /** True when the host's state folder is on that server. */
    val data: Boolean = false,
    /** Where that folder is, so the sentence about it can name it. */
    val dataDir: String = "",
) {
    val isInstalled: Boolean get() = command.isNotEmpty()
}

/** What it would take to put one here. Every refusal is decided from this. */
data class HostRoom(
    val os: String = "",
    val arch: String = "",
    /** `gnu` or `musl`. Node publishes no musl build; see [HostProbe.whyNot]. */
    val libc: String = "gnu",
    val node: String = "",
    val npm: String = "",
    val missingTools: List<String> = emptyList(),
    val downloader: String = "",
    val canHash: Boolean = false,
    val canUnpack: Boolean = false,
    val homeFreeKb: Int? = null,
    val systemdUser: Boolean = false,
)

data class HostLook(
    val host: HostOnServer = HostOnServer(),
    val room: HostRoom = HostRoom(),
)

/** What that host says about its relay, which decides whether anything can reach it. */
enum class HostRelay { CONNECTED, NOT_CONNECTED, OFF, UNKNOWN }

/**
 * What the headless host probe found on one server — the phone's half of
 * `src/main/servers/host.ts`, and a port of `ios/TerminalDeck/Servers/HostProbe.swift`.
 *
 * The script is not copied: `assets/probe-host.sh` is generated from the desktop's `HOST_PROBE`
 * and a test on that side fails if the two drift. What is ported here is the *reader* and the
 * sentences, because those are what a screen shows and all three clients have to say the same
 * thing about the same server. Every sentence below is the desktop's sentence, and where one is
 * different it is because the phone's situation is different — never because it was rewritten.
 *
 * Three states, never two, for the one question that matters: **is it running.** [HostRunning
 * .UNKNOWN] is a real answer — a half-installed host prints nothing at all — and collapsing it
 * into "no" would put a claim on screen that nobody measured. That is `facts.ts`'s rule, and it
 * applies here for the same reason.
 */
object HostProbe {

    /** The line that separates the tab-separated facts from the host's own words. */
    private const val STATUS_MARK = "--- status ---"

    /**
     * The one sentence `renderNotRunning` prints, which is the only reliable way to tell the two
     * states apart.
     *
     * `cli.ts` has exactly two shapes for `status` and both exit 0 — a non-zero exit would make a
     * health check report a failure for a machine that is simply switched off — so the exit status
     * says nothing and the first line says everything. Matched on the part that carries no product
     * name.
     */
    private const val NOT_RUNNING = "host: not running"

    /** Measured on the desktop: package, dependencies and a private Node runtime. */
    private const val ROOM_NEEDED_KB = 400 * 1024

    fun read(out: String): HostLook {
        val marked = out.indexOf("$STATUS_MARK\n")
        val head = if (marked >= 0) out.substring(0, marked) else out
        val status = if (marked >= 0) {
            out.substring(marked + STATUS_MARK.length + 1).trim()
        } else {
            ""
        }

        val said = mutableMapOf<String, String>()
        for (line in head.split("\n")) {
            val tab = line.indexOf('\t')
            if (tab <= 0) continue
            said[line.substring(0, tab)] = line.substring(tab + 1).trim()
        }
        fun value(key: String): String = said[key].orEmpty()

        val command = value("command")
        val running = when {
            command.isEmpty() || status.isEmpty() -> HostRunning.UNKNOWN
            status.lowercase().contains(NOT_RUNNING) -> HostRunning.NO
            else -> HostRunning.YES
        }

        val host = HostOnServer(
            command = command,
            version = value("version"),
            running = running,
            status = status,
            address = serverAddress(status),
            unit = value("unit"),
            linger = value("linger") == "yes",
            data = value("state") == "yes",
            dataDir = value("state_dir"),
        )

        val room = HostRoom(
            os = value("os").lowercase(),
            arch = value("arch"),
            libc = if (value("libc") == "musl") "musl" else "gnu",
            node = value("node"),
            npm = value("npm"),
            missingTools = value("tools").split(" ").filter { it.isNotEmpty() },
            downloader = value("fetch"),
            canHash = value("hash").isNotEmpty(),
            canUnpack = value("tar") == "yes",
            homeFreeKb = value("home_free_kb").toIntOrNull(),
            systemdUser = value("systemd_user") == "yes",
        )

        return HostLook(host = host, room = room)
    }

    /* ----------------------------------------------- reading its own status -- */

    /** Anchored on the block `renderStatus` writes, not scanned for anywhere. */
    fun relay(status: String): HostRelay {
        val lines = status.split("\n")
        val at = lines.indexOfFirst { it.trim() == "Relay" }
        if (at < 0) return HostRelay.UNKNOWN
        val next = if (at + 1 < lines.size) lines[at + 1].trim() else ""
        return when {
            next.startsWith("connected") -> HostRelay.CONNECTED
            next.startsWith("not connected") -> HostRelay.NOT_CONNECTED
            next.startsWith("off") -> HostRelay.OFF
            else -> HostRelay.UNKNOWN
        }
    }

    /**
     * The pasteable server address out of that host's own `status`, or `""`.
     *
     * Validated with the real parser before it is returned, so what reaches a screen either works
     * when it is spent or is empty. A host running a build older than the address prints no such
     * block and answers `""`, which the screen draws as the sentence about upgrading rather than
     * as a dead button.
     */
    fun serverAddress(status: String): String {
        val lines = status.split("\n")
        val at = lines.indexOfFirst { it.trim() == "Server address" }
        if (at < 0) return ""
        val said = if (at + 1 < lines.size) lines[at + 1].trim() else ""
        if (said.isEmpty()) return ""
        return when (ServerAddress.parse(said)) {
            is ServerAddress.Companion.Result.Ok -> said
            is ServerAddress.Companion.Result.Bad -> ""
        }
    }

    /** That host's public name at the relay, which is the join between the two sides. */
    fun hostId(status: String): String = field("host id", status)

    /**
     * How many clients that host has open on the relay right now, or null when it will not say.
     *
     * Null rather than zero when the line is missing, and the difference matters: a host whose
     * relay is off prints no channel count at all, and reading that absence as "nothing is
     * connected" would turn a host that is deliberately not dialling out into a broken link.
     */
    fun channels(status: String): Int? = field("channels", status).takeIf { it.isNotEmpty() }?.toIntOrNull()

    private fun field(name: String, status: String): String {
        for (line in status.split("\n")) {
            val trimmed = line.trim()
            if (!trimmed.lowercase().startsWith(name)) continue
            val rest = trimmed.drop(name.length).trim()
            val first = rest.split(Regex("\\s+")).firstOrNull { it.isNotEmpty() }
            if (first != null) return first
        }
        return ""
    }

    /* --------------------------------------------- what a person is told -- */

    /** Node 22 or newer **with npm**, which is one question rather than two. */
    fun usableNode(room: HostRoom): Boolean {
        if (room.npm.isEmpty()) return false
        val digits = room.node.dropWhile { !it.isDigit() }.takeWhile { it.isDigit() }
        val major = digits.toIntOrNull() ?: return false
        return major >= 22
    }

    /**
     * Why there is no Install button, in the server's own terms — or null when nothing is in the
     * way.
     *
     * The same checks `install-headless.sh` makes on the machine itself. That script is the
     * authority; this copy exists to decide whether to *offer* the button at all, because §4.1 of
     * `SERVERS-DESIGN.md` says a control that cannot act is removed or disabled with a stated
     * reason, never drawn hopefully.
     */
    fun whyNot(room: HostRoom): String? {
        if (room.os != "linux" && room.os != "darwin") {
            val said = room.os.ifEmpty { "nothing" }
            return "The headless host runs on Linux and macOS, and this server answered “$said”. " +
                "On Windows people install the desktop app instead."
        }
        if (room.libc == "musl") {
            return "This server uses musl (Alpine or similar), and the Node project publishes no " +
                "musl build — so there is no runtime to fetch for it. Install Node 22 or newer " +
                "from the distribution (apk add --no-cache nodejs npm) and this becomes available."
        }
        if (room.os == "linux" && room.missingTools.isNotEmpty()) {
            val names = room.missingTools.joinToString(", ")
            return "This server is missing the build tools a session’s pseudo terminal needs: " +
                "$names. node-pty ships no Linux binary, so it compiles during the install, and " +
                "without a compiler that fails a minute in. Someone will need to add them first: " +
                "sudo apt-get install -y ${room.missingTools.joinToString(" ")}"
        }
        if (!usableNode(room)) {
            if (room.downloader.isEmpty()) {
                return "This server has no Node 22 or newer, and no curl or wget to fetch one " +
                    "with. Someone will need to add one of those first."
            }
            if (!room.canHash) {
                return "This server has no sha256 tool (sha256sum, shasum or openssl), and a Node " +
                    "runtime will not be unpacked here unverified. Install coreutils, or install " +
                    "Node 22 or newer yourself."
            }
            if (!room.canUnpack) {
                return "This server has no tar, so a Node runtime could not be unpacked here."
            }
        }
        val free = room.homeFreeKb
        if (free != null && free < ROOM_NEEDED_KB) {
            return "There is ${free / 1024} MB free in your home folder on this server and this " +
                "needs about ${ROOM_NEEDED_KB / 1024} MB."
        }
        return null
    }

    /**
     * The one standing line for the section. Four states and no fifth, and the fourth is the one
     * that matters — a host that would not say whether it is running is reported as not having
     * said, never as running.
     */
    fun line(host: HostOnServer): String {
        if (host.command.isEmpty()) {
            return "Sessions here run over SSH. This server is not a machine of its own yet."
        }
        if (host.version.isEmpty()) return "The host is on this server and will not start."
        return when (host.running) {
            HostRunning.NO -> "The host ${host.version} is here and is not running."
            HostRunning.UNKNOWN ->
                "The host ${host.version} is here. It would not say whether it is running."
            HostRunning.YES -> "The host ${host.version} is here and running."
        }
    }

    /**
     * Whether it will still be there tomorrow, which is a different question from whether it is
     * running now — and the one nobody thinks to ask until a phone in another country finds
     * nothing.
     */
    fun reachLine(host: HostOnServer): String? {
        if (host.command.isEmpty()) return null
        if (host.unit.isEmpty()) {
            return "It was not set up to start on its own, so it will not come back after this " +
                "server reboots. Installing it again from here sets that up."
        }
        if (!host.linger) {
            return "It starts with this server, and stops when your last login on this server ends " +
                "— running `sudo loginctl enable-linger \$(id -un)` once on that server is what " +
                "stops that."
        }
        return "It starts with this server and keeps running when you log out."
    }

    /**
     * What connecting from *this phone* would mean, or why it cannot happen yet.
     *
     * The desktop never needs this: it is holding the SSH connection, so it can link itself with a
     * code it reads out of a terminal it owns. A phone has no such terminal, and the thing it can
     * spend is the **server address** the host prints — see `signin/ServerSignIn.kt`. So the
     * honest answers are three, and only one of them is a button.
     */
    fun connectRefusal(host: HostOnServer): String? {
        if (host.command.isEmpty()) return null
        if (host.running != HostRunning.YES) {
            return "It has to be running before this phone can connect to it. Start it first."
        }
        if (host.address.isNotEmpty()) return null
        return when (relay(host.status)) {
            HostRelay.OFF ->
                "This host has its relay switched off, so nothing outside that server can reach " +
                    "it. A phone reaches a server through the relay; there is no other route."
            HostRelay.NOT_CONNECTED ->
                "This host is not connected to its relay right now, so it has no address to give " +
                    "out. It usually connects within a few seconds of starting."
            /*
             * Measured rather than guessed, and the advice is narrower than it wants to be.
             *
             * The address block is a 0.10.0 thing, and the newest `terminaldeck` on the npm
             * registry — which is what a registry install would fetch — was **0.6.1** when this
             * was written. So "install it again from here" is only a fix because
             * `ServerScripts.hostPackage` names the **release asset for this app's own version**
             * rather than `terminaldeck@latest`. It is, and that is why this sentence can offer it.
             */
            HostRelay.CONNECTED, HostRelay.UNKNOWN ->
                "This host is running a build older than the one that prints a server address, " +
                    "which is the only thing a phone can dial. Installing it again from here puts " +
                    "this app's own build on, which does print one."
        }
    }
}
