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
            return "It was not set up to start on its own, so it will not come back after this "
                + "server reboots. Installing it again from here sets that up."
        }
        if !host.linger {
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
             * Measured rather than guessed, and the advice is narrower than it
             * wants to be.
             *
             * The address block is a 0.10.0 thing, and the newest `terminaldeck`
             * on the npm registry — which is what an install from this phone
             * fetches — was **0.6.1** when this was written. So "install it
             * again from here" is not reliably a fix: it installs whatever the
             * registry has, and if that is still older than the address, this
             * sentence would send somebody round a loop. The desktop's install
             * carries the app's own build and does not have that problem, so
             * that is what is named.
             */
            return "This host is running a build older than the one that prints a server address, "
                + "which is the only thing a phone can dial. Installing it from a desktop "
                + "\(Brand.name) puts that build on, because the desktop carries its own copy of "
                + "the host rather than fetching the published one."
        }
    }
}
