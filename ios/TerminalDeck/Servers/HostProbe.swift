/**
 * What the headless host probe found on one server — the phone's half of
 * `src/main/servers/host.ts`.
 *
 * The script is not copied: `ProbeScripts.host` is generated from the desktop's
 * `HOST_PROBE` and a test on that side fails if the two drift. What is ported
 * here is the *reader* and the sentences, because those are what a screen shows
 * and both sides have to say the same thing about the same server. Every
 * sentence below is the desktop's sentence, and where one is different it is
 * because the phone's situation is different — never because it was rewritten.
 *
 * Three states, never two, for the one question that matters: **is it running.**
 * `unknown` is a real answer — a half-installed host prints nothing at all — and
 * collapsing it into "no" would put a claim on screen that nobody measured. That
 * is `facts.ts`'s rule, and it applies here for the same reason.
 */

import Foundation

/// Whether the host on that server is up, as far as its own `status` will say.
enum HostRunning: String, Equatable {
    case yes, no, unknown
}

/// What one probe found out about the headless host on one server.
struct HostOnServer: Equatable {
    /// The absolute path of the `terminaldeck` command, or `""` when there is none.
    var command = ""
    /// What it answers to `--version`, or `""` when it will not start.
    var version = ""
    var running: HostRunning = .unknown
    /// The host's own `status` output, verbatim. Empty when there is nothing to ask.
    var status = ""
    /// The pasteable **server address** that host printed, or `""`.
    var address = ""
    /// `active`, `inactive`, `failed`, or `""` when there is no unit of ours.
    var unit = ""
    /// True when the account's own systemd will keep it running after the last login ends.
    var linger = false
    /// True when the host's state folder is on that server.
    var data = false
    /// Where that folder is, so the sentence about it can name it.
    var dataDir = ""

    var isInstalled: Bool { command != "" }
}

/**
 * Whether a session on that server could be held inside the folder it was
 * granted — three states, and the third is why this is not a `Bool`.
 *
 * `unknown` is what a probe that never asked answers, and it is not "no": this
 * app is talking to a script that is generated from the desktop's, and a server
 * surveyed by a build that predates the question would otherwise be refused an
 * install for a fact nobody measured. Same rule as ``HostRunning``, same
 * reason.
 */
enum HostConfinement: String, Equatable {
    case yes, no, unknown
}

/// What it would take to put one here. Every refusal is decided from this.
struct HostRoom: Equatable {
    var os = ""
    var arch = ""
    /// `gnu` or `musl`. Node publishes no musl build; see ``whyNotHost``.
    var libc = "gnu"
    var node = ""
    var npm = ""
    var missingTools: [String] = []
    var downloader = ""
    var canHash = false
    var canUnpack = false
    var homeFreeKb: Int?
    var systemdUser = false
    /// Whether that box can confine a session. See ``HostConfinement``.
    var confinement: HostConfinement = .unknown
    /// The machine's own reason when it cannot, as half a sentence: *"it has no
    /// unshare, which is the util-linux package"*. Empty otherwise.
    var confineWhy = ""
}

struct HostLook: Equatable {
    var host = HostOnServer()
    var room = HostRoom()
}

/// What that host says about its relay, which decides whether anything can reach it.
enum HostRelay: String, Equatable {
    case connected, notConnected, off, unknown
}

enum HostProbe {

    /// The line that separates the tab-separated facts from the host's own words.
    private static let statusMark = "--- status ---"

    /**
     * The one sentence `renderNotRunning` prints, which is the only reliable way
     * to tell the two states apart.
     *
     * `cli.ts` has exactly two shapes for `status` and both exit 0 — a non-zero
     * exit would make a health check report a failure for a machine that is
     * simply switched off — so the exit status says nothing and the first line
     * says everything. Matched on the part that carries no product name.
     */
    private static let notRunning = "host: not running"

    static func read(_ out: String) -> HostLook {
        let marked = out.range(of: statusMark + "\n")
        let head = marked.map { String(out[out.startIndex..<$0.lowerBound]) } ?? out
        let status = marked
            .map { String(out[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? ""

        var said: [String: String] = [:]
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let tab = line.firstIndex(of: "\t"), tab != line.startIndex else { continue }
            said[String(line[line.startIndex..<tab])] =
                String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespaces)
        }
        func value(_ key: String) -> String { said[key] ?? "" }

        let command = value("command")
        let running: HostRunning
        if command.isEmpty || status.isEmpty {
            running = .unknown
        } else {
            running = status.lowercased().contains(notRunning) ? .no : .yes
        }

        var host = HostOnServer()
        host.command = command
        host.version = value("version")
        host.running = running
        host.status = status
        host.address = serverAddress(in: status)
        host.unit = value("unit")
        host.linger = value("linger") == "yes"
        host.data = value("state") == "yes"
        host.dataDir = value("state_dir")

        var room = HostRoom()
        room.os = value("os").lowercased()
        room.arch = value("arch")
        room.libc = value("libc") == "musl" ? "musl" : "gnu"
        room.node = value("node")
        room.npm = value("npm")
        room.missingTools = value("tools").split(separator: " ").map(String.init)
        room.downloader = value("fetch")
        room.canHash = !value("hash").isEmpty
        room.canUnpack = value("tar") == "yes"
        room.homeFreeKb = Int(value("home_free_kb"))
        room.systemdUser = value("systemd_user") == "yes"
        // Only the two answers the script can actually give are read as
        // answers. Anything else — an empty field, no field at all — is the
        // question not having been asked, which `whyNot` treats as silence
        // rather than as a refusal.
        room.confineWhy = value("confine_why")
        if value("confine") == "yes" {
            room.confinement = .yes
        } else if !room.confineWhy.isEmpty {
            room.confinement = .no
        }

        return HostLook(host: host, room: room)
    }

    /* --------------------------------------------- reading its own status -- */

    /// Anchored on the block `renderStatus` writes, not scanned for anywhere.
    static func relay(in status: String) -> HostRelay {
        let lines = status.split(separator: "\n", omittingEmptySubsequences: false)
        guard let at = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Relay" })
        else { return .unknown }
        let next = at + 1 < lines.count
            ? lines[at + 1].trimmingCharacters(in: .whitespaces) : ""
        if next.hasPrefix("connected") { return .connected }
        if next.hasPrefix("not connected") { return .notConnected }
        if next.hasPrefix("off") { return .off }
        return .unknown
    }

    /**
     * The pasteable server address out of that host's own `status`, or `""`.
     *
     * Validated with the real parser before it is returned, so what reaches a
     * screen either works when it is spent or is empty. A host running a build
     * older than the address prints no such block and answers `""`, which the
     * screen draws as the sentence about upgrading rather than as a dead button.
     */
    static func serverAddress(in status: String) -> String {
        let lines = status.split(separator: "\n", omittingEmptySubsequences: false)
        guard let at = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "Server address"
        }) else { return "" }
        let said = at + 1 < lines.count ? lines[at + 1].trimmingCharacters(in: .whitespaces) : ""
        guard !said.isEmpty, case .success = ServerAddress.parse(said) else { return "" }
        return said
    }

    /// That host's public name at the relay, which is the join between the two sides.
    static func hostId(in status: String) -> String {
        field("host id", in: status)
    }

    /**
     * How many clients that host has open on the relay right now, or nil when it
     * will not say.
     *
     * Nil rather than zero when the line is missing, and the difference matters:
     * a host whose relay is off prints no channel count at all, and reading that
     * absence as "nothing is connected" would turn a host that is deliberately
     * not dialling out into a broken link.
     */
    static func channels(in status: String) -> Int? {
        let said = field("channels", in: status)
        return said.isEmpty ? nil : Int(said)
    }

    private static func field(_ name: String, in status: String) -> String {
        for line in status.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix(name) else { continue }
            let rest = trimmed.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            if let first = rest.split(whereSeparator: { $0.isWhitespace }).first {
                return String(first)
            }
        }
        return ""
    }

    /* -------------------------------------------- what a person is told -- */

    /// Measured on the desktop: package, dependencies and a private Node runtime.
    private static let roomNeededKb = 400 * 1024

    /// Node 22 or newer **with npm**, which is one question rather than two.
    static func usableNode(_ room: HostRoom) -> Bool {
        guard !room.npm.isEmpty else { return false }
        let digits = room.node.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        guard let major = Int(digits) else { return false }
        return major >= 22
    }

    /**
     * Why there is no Install button, in the server's own terms — or nil when
     * nothing is in the way.
     *
     * The same checks `install-headless.sh` makes on the machine itself. That
     * script is the authority; this copy exists to decide whether to *offer* the
     * button at all, because §4.1 says a control that cannot act is removed or
     * disabled with a stated reason, never drawn hopefully.
     *
     * ## Why these particular sentences still hand somebody a command
     *
     * Nothing else in this flow does. The phone holds an open SSH session and
     * anything it can run, it runs — *"I don't want that command."* Every
     * command left in the sentences below is one that needs **root**: a package
     * manager, or a kernel setting. This app signs in as an ordinary account on
     * purpose (*"needs no administrator access"* is the promise on the install
     * card), it has no password to feed a `sudo` prompt for a key-based login,
     * and quietly making a system-wide change to somebody's server is not
     * something a phone should do behind one tap. So these are named for a
     * person who has that access, and the app does not pretend it does.
     */
    static func whyNot(_ room: HostRoom) -> String? {
        if room.os != "linux" && room.os != "darwin" {
            return "The headless host runs on Linux and macOS, and this server answered "
                + "“\(room.os.isEmpty ? "nothing" : room.os)”. On Windows people install the "
                + "desktop app instead."
        }
        if room.libc == "musl" {
            return "This server uses musl (Alpine or similar), and the Node project publishes no "
                + "musl build — so there is no runtime to fetch for it. Install Node 22 or newer "
                + "from the distribution (apk add --no-cache nodejs npm) and this becomes available."
        }
        if room.os == "linux" && !room.missingTools.isEmpty {
            let names = room.missingTools.joined(separator: ", ")
            return "This server is missing the build tools a session’s pseudo terminal needs: "
                + "\(names). node-pty ships no Linux binary, so it compiles during the install, and "
                + "without a compiler that fails a minute in. Someone will need to add them first: "
                + "sudo apt-get install -y \(room.missingTools.joined(separator: " "))"
        }
        if !usableNode(room) {
            if room.downloader.isEmpty {
                return "This server has no Node 22 or newer, and no curl or wget to fetch one with. "
                    + "Someone will need to add one of those first."
            }
            if !room.canHash {
                return "This server has no sha256 tool (sha256sum, shasum or openssl), and a Node "
                    + "runtime will not be unpacked here unverified. Install coreutils, or install "
                    + "Node 22 or newer yourself."
            }
            if !room.canUnpack {
                return "This server has no tar, so a Node runtime could not be unpacked here."
            }
        }
        if let free = room.homeFreeKb, free < roomNeededKb {
            return "There is \(free / 1024) MB free in your home folder on this server and this "
                + "needs about \(roomNeededKb / 1024) MB."
        }
        /*
         * Last, and last on purpose: everything above is about whether the
         * install can *finish*, and this is about whether what it installs can
         * do its job. Both are refusals before the press rather than after it,
         * and this is the one that used to be missing — a box with no
         * `unshare`, or a kernel that refuses an unprivileged user namespace,
         * installs cleanly, starts, connects, and then refuses **every**
         * session, because `confineSpawn` throws rather than hand a phone a
         * boundary it could not build. Five green steps and a machine nobody
         * can open a shell on.
         *
         * `.unknown` is not refused. A server surveyed by a build that never
         * asked this question is a server nobody measured, and §4.1 is about
         * not drawing a hopeful control — not about refusing on a fact this app
         * does not have.
         */
        if room.confinement == .no {
            let said = room.confineWhy.isEmpty
                ? "this account cannot open one on it"
                : room.confineWhy
            return "Sessions on that server are held inside the folder they are given, and this "
                + "server cannot hold them: \(said). It would install, start and connect, and then "
                + "refuse every session — so the refusal is here instead. A missing unshare or "
                + "setpriv is the util-linux package (sudo apt-get install -y util-linux on Debian "
                + "and Ubuntu); a kernel that switches unprivileged user namespaces off is a "
                + "decision for whoever runs that server."
        }
        return nil
    }

    /**
     * The one standing line for the section. Four states and no fifth, and the
     * fourth is the one that matters — a host that would not say whether it is
     * running is reported as not having said, never as running.
     */
    static func line(_ host: HostOnServer) -> String {
        if host.command.isEmpty {
            return "Sessions here run over SSH. This server is not a machine of its own yet."
        }
        if host.version.isEmpty { return "The host is on this server and will not start." }
        switch host.running {
        case .no: return "The host \(host.version) is here and is not running."
        case .unknown:
            return "The host \(host.version) is here. It would not say whether it is running."
        case .yes: return "The host \(host.version) is here and running."
        }
    }

    /**
     * Whether it will still be there tomorrow, which is a different question
     * from whether it is running now — and the one nobody thinks to ask until a
     * phone in another country finds nothing.
     */
    static func reachLine(_ host: HostOnServer) -> String? {
        if host.command.isEmpty { return nil }
        if host.unit.isEmpty {
            // The desktop's sentence, which this could not say until there was
            // a Remove on this card: `service` is written by the install, so
            // the route back to a unit is off and on again. Naming a route that
            // did not exist on a phone is what this whole pass is about.
            return "It was not set up to start on its own, so it will not come back after this "
                + "server reboots. Removing it and installing it again from here sets that up."
        }
        if !host.linger {
            // `ServerScripts.service` already ran this without `sudo`, which is
            // where it succeeds on a box whose policy allows it. Reaching this
            // sentence means the unprivileged attempt was refused, and the only
            // thing left is root — see the note on ``whyNot``.
            return "It starts with this server, and stops when your last login on this server ends "
                + "— running `sudo loginctl enable-linger $(id -un)` once on that server is what "
                + "stops that."
        }
        return "It starts with this server and keeps running when you log out."
    }

    /**
     * What connecting from *this phone* would mean, or why it cannot happen yet.
     *
     * The desktop never needs this: it is holding the SSH connection, so it can
     * link itself with a code it reads out of a terminal it owns. A phone has no
     * such terminal, and the thing it can spend is the **server address** the
     * host prints — see `ServerSignIn.swift`. So the honest answers are three,
     * and only one of them is a button.
     */
    static func connectRefusal(_ host: HostOnServer) -> String? {
        if host.command.isEmpty { return nil }
        if host.running != .yes {
            return "It has to be running before this phone can connect to it. Start it first."
        }
        if !host.address.isEmpty { return nil }
        switch relay(in: host.status) {
        case .off:
            return "This host has its relay switched off, so nothing outside that server can reach "
                + "it. A phone reaches a server through the relay; there is no other route."
        case .notConnected:
            return "This host is not connected to its relay right now, so it has no address to "
                + "give out. It usually connects within a few seconds of starting."
        case .connected, .unknown:
            /*
             * This sentence has been wrong twice, in opposite directions, and
             * the second time is the one worth writing down.
             *
             * It began as *"install it again from here"*, which was a loop: an
             * install from this phone fetched `terminaldeck@latest`, and the
             * registry was **0.6.1** while the address block is a 0.10.0 thing.
             * So it was rewritten to name a desktop — correct on the day, and
             * dead the moment `ServerScripts.hostPackage` stopped using the
             * registry. It now fetches this app's *own* release tarball at
             * `Brand.version`, which by construction is a build that prints an
             * address. So the phone can do the upgrade it was sending somebody
             * across the room for, and the premise this release is built on —
             * *"say no MacBook or Windows exists at all"* — no longer has a
             * hole in it here.
             *
             * The button that acts on this is `HostStepCard`'s, drawn from
             * ``needsNewerBuild``, which asks these same three questions.
             */
            return "This host is running a build older than the one that prints a server address, "
                + "which is the only thing a phone can dial. Installing it again from here puts "
                + "\(Brand.version) on that server — this app carries the release its own build "
                + "was cut from, so what goes on is a host this phone can reach."
        }
    }

    /**
     * Whether the only thing between this phone and a connection is the **build
     * on that server** — the one refusal an install actually repairs.
     *
     * The three questions ``connectRefusal`` asks to reach its last branch,
     * asked again as an answer a card can act on rather than print. They sit
     * next to each other deliberately: a condition added to one has to be added
     * to the other, and an Install button offered for a relay that is switched
     * off would be exactly the control §4.1 forbids — one that cannot do what
     * pressing it claims.
     */
    static func needsNewerBuild(_ host: HostOnServer) -> Bool {
        guard host.isInstalled, host.running == .yes, host.address.isEmpty else { return false }
        switch relay(in: host.status) {
        case .connected, .unknown: return true
        case .off, .notConnected: return false
        }
    }

    /* ------------------------------------------------------ the way back -- */

    /// The button that takes it off again, named the way a person would say it.
    /// `REMOVE_HOST_LABEL` on the desktop, the same words on purpose.
    static let removeLabel = "Remove it from this server"

    /**
     * What removing it leaves behind, said before the press rather than
     * discovered after it.
     *
     * The desktop's sentence, with one difference that is the phone's situation
     * and not a rewrite: there is no tick box here. A confirmation sheet on a
     * phone is a list of verbs, so the choice between keeping and not keeping
     * what the host stored is **two buttons**, and this names the other one
     * instead of a control that does not exist.
     *
     * The data folder is the interesting half and it is deliberately not the
     * default: it holds the devices paired to this host and the folders each of
     * them may use, and somebody removing the program to put a newer one on
     * does not expect to pair this phone again afterwards.
     */
    static func removeConsequence(_ host: HostOnServer, alsoData: Bool) -> String {
        let service = host.unit.isEmpty ? "" : " Its service is stopped and its unit file removed."
        let data = alsoData
            ? " Everything it stored on that server goes too — \(host.dataDir), which is the devices "
                + "paired to it and the folders each of them may use. This phone would need "
                + "connecting again."
            : " What it stored stays: \(host.dataDir) holds the devices paired to it and the folders "
                + "each of them may use, so a later install finds them again — the other button "
                + "takes that too."
        return "This removes the host program and, if this app fetched one, the private Node runtime "
            + "beside it.\(service)\(data) This app’s own record of the machine is separate — "
            + "forget it under Machines if you want that gone too."
    }
}
