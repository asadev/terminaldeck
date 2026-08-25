/**
 * Turning a wall of ports into a few groups, from facts rather than from guesses.
 *
 * Asad, on the list as it was: *"I can already see a big list of local hosts. So
 * it should not be like that… I think they are different categories also. So
 * maybe we can categorize and we can keep some in the list and we can keep some
 * folded… so we don't see a lot of jargon, unnecessary ones."*
 *
 * ## Every group is derived from something the wire actually carries
 *
 * There are exactly three inputs, and no fourth is invented:
 *
 *  1. **`LocalPort`** — a port number, the name of the process holding it, and
 *     `guessed`, which says the port answers but nothing could name its owner.
 *     `dev-ports.ts` is deliberate about this: it *refuses* to guess which
 *     framework is behind a port, and this file does not do the guessing on its
 *     behalf. A process name is a fact about a process, not a claim about a page.
 *  2. **`DevServerReport`** — a project folder this machine granted this phone,
 *     and the port its dev server is proven to be accepting on. This is the only
 *     input that can say *what a port is serving*, because the desktop started it.
 *  3. **The endpoint this phone is connected on**, plus this product's own
 *     binary name. Those two are how a port that belongs to the desktop app
 *     itself is recognised instead of being offered as somebody's dev server.
 *
 * What is **not** here: no table of "3000 means Next, 5173 means Vite", no
 * inference from a port number to a framework, no list of ports somebody else's
 * machine is expected to have. A port number is a number a person chose.
 *
 * ## The six groups
 *
 * | Group | Derived from | Open by default |
 * |---|---|---|
 * | **Named by you** | the phone's own `PortBook` has a name for it | yes |
 * | **Dev servers** | a `DevServerReport` for a granted folder | yes |
 * | **Web servers** | the process is one of the runtimes `dev-ports.ts` ranks first | yes |
 * | ***the product itself*** | the port this phone dialled, or the app's own binary | no |
 * | **Other services** | a named process that is none of the above | no |
 * | **Unidentified** | `guessed` — it answers, nothing could name it | no |
 *
 * The last three are the pile he was complaining about, and they are closed
 * rather than hidden: `wslrelay` on three ports is genuinely uninteresting until
 * the day it is the thing you are looking for.
 *
 * ## Naming a port promotes it, and that is the whole "keep some in the list"
 *
 * *"we can keep some in the list and we can keep some folded"*. Rather than a
 * second pin/hide control alongside the rename, the name **is** the pin: a port
 * with a name is lifted to the top group whatever it was derived into. It is one
 * gesture with one meaning — *this one matters and here is why* — and it cannot
 * get out of step with itself the way a pinned-but-unnamed row could.
 *
 * ## One row per server, never two
 *
 * A dev server this phone started shows up twice if nothing joins them: once as
 * `myproject` from `dev.state`, and once as `localhost:5173 node` from `ports`.
 * They are the same server, and the join is a fact rather than a heuristic —
 * `DevServerReport.port` is a port the desktop **dialled and got an answer on**.
 * So a `ready` report claims its port, the port row is dropped, and the merged
 * row carries both the project's name and the address.
 */

import Foundation

/**
 * Which pile a row lands in.
 *
 * The declaration order is the order the sections are drawn in, so it goes from
 * "this is why you opened the screen" to "this is the noise".
 */
enum PortCategory: String, CaseIterable, Hashable {
    /// The phone has a name for this port. See `PortBook`.
    case named
    /// A project's dev server, from `dev.state`.
    case devServer
    /// The process is one of the runtimes that usually is serving a page.
    case web
    /// The desktop application itself is holding it.
    case app
    /// A named process that is none of the above.
    case other
    /// The port answers and nothing could name its owner.
    case unnamed

    /// What the section header says. Uppercased by the header itself, in the
    /// same shape the rest of the app's section headers use.
    var title: String {
        switch self {
        case .named: return "Named by you"
        case .devServer: return "Dev servers"
        case .web: return "Web servers"
        // The product's own name rather than "this app", because on a phone
        // paired with three machines the question being answered is *which*
        // program on that machine is holding the port.
        case .app: return Brand.name
        case .other: return "Other services"
        case .unnamed: return "Unidentified"
        }
    }

    var glyph: String {
        switch self {
        case .named: return "tag"
        case .devServer: return "hammer"
        case .web: return "globe"
        case .app: return "square.stack.3d.up"
        case .other: return "gearshape.2"
        case .unnamed: return "questionmark.circle"
        }
    }

    /**
     * Whether the group starts closed.
     *
     * The three that start closed are the three whose rows are, on a normal
     * machine, things nobody opened the screen to look at. It is a *starting*
     * position and not a rule: `PortBook` remembers the first time somebody
     * disagrees, per machine, because a WSL box where `wslrelay` is the whole
     * point is a real machine.
     */
    var foldedByDefault: Bool {
        switch self {
        case .named, .devServer, .web: return false
        case .app, .other, .unnamed: return true
        }
    }
}

/**
 * One row on the localhost screen.
 *
 * Either a listening port, or a project's dev server, or — when the two are the
 * same server — both. `dev` and `entry` are never both nil.
 */
struct LocalhostRow: Identifiable, Hashable {
    /// What is listening, when something is. Nil for a dev server that is not up.
    let entry: LocalPort?
    /// The project behind it, when this machine has told us about one.
    let dev: DevServerReport?
    /// The user's name for this port, or nil.
    let name: String?
    let category: PortCategory

    /// The port, from whichever half of the row knows it. Nil only for a dev
    /// server that has not come up — which is exactly the row whose whole point
    /// is that there is no port yet.
    var port: Int? { entry?.port ?? dev?.port }

    /// Stable across a refresh, which is what keeps a `List` from re-animating
    /// every row each time the desktop answers. Keyed on the folder for a dev
    /// server, because its port changes when Vite takes 5174 instead of 5173.
    var id: String {
        if let dev { return "dev:\(dev.folder)" }
        return "port:\(entry.map { String($0.port) } ?? "?")"
    }
}

struct LocalhostSection: Identifiable, Hashable {
    let category: PortCategory
    let rows: [LocalhostRow]

    var id: String { category.rawValue }
}

/**
 * The row's second action — what a swipe from the trailing edge offers.
 *
 * A value rather than a `switch` inside the view, because this is the answer to
 * *"what do start and stop do in each of the five states"* and that answer has
 * to be checkable without a simulator, a paired machine and a project on it. The
 * view turns each case into a button; this decides which case it is.
 *
 * | row | second action | why |
 * |---|---|---|
 * | dev server, `idle` | **Start** | `dev.start`, and the tap is the consent |
 * | dev server, `starting` | **Session** | watch it come up; a second start would be a second start |
 * | dev server, `ready` | **Session** | where it is running — and where Ctrl-C stops it |
 * | dev server, `failed` | **Try again** | `dev.start` re-reads the folder, so a fixed `package.json` is picked up |
 * | dev server, `no-dev-script` | *nothing* | there is no row at all; see `PortCatalog.sections` |
 * | a plain listening port | **Copy** | nothing on the wire can start or stop "whatever is on 2019" |
 *
 * `starting` and `ready` fall back to `.none` when the report carries no
 * session, which the protocol says cannot happen — both states are defined to
 * have one. Drawing a control that would have nowhere to go is worse than
 * drawing none, so the impossible case is handled rather than forced.
 */
enum PortRowAction: Equatable {
    /// `dev.start` for a project that is not running.
    case start(folder: String)
    /// `dev.start` again for one that failed. A different word on the button:
    /// the row leads to the reason, and this is the deliberate second press.
    case retry(folder: String)
    /// Open the ordinary session the dev server runs in. **This is also how one
    /// is stopped** — see `LocalhostPortsView`'s header for why the phone will
    /// not type the interrupt on somebody's behalf.
    case openSession(id: String)
    /// Put `http://localhost:<port>` on the clipboard.
    case copyAddress(port: Int)
    /// Nothing to offer.
    case none
}

enum PortCatalog {

    /**
     * Runtimes that usually *are* serving a page.
     *
     * `LIKELY_DEV` from `dev-ports.ts`, mirrored — the same list the desktop
     * already uses to decide which ports to print first, so the phone's grouping
     * and the desktop's ordering agree about what looks like a web server. It
     * changes when that list changes.
     *
     * Matched as a prefix rather than exactly, because the same runtime is
     * spelled several ways by the two scanners: `python` and `python3`, and on
     * Windows `node` comes back from `tasklist` with the `.exe` already taken
     * off but a version suffix sometimes still attached.
     */
    static let webRuntimes = [
        "node", "bun", "deno", "python", "ruby", "php", "java", "dotnet", "caddy", "nginx",
    ]

    static func isWebRuntime(_ process: String) -> Bool {
        let name = process.lowercased()
        return webRuntimes.contains { name.hasPrefix($0) }
    }

    /**
     * Whether the desktop half of *this product* is what is holding the port.
     *
     * Two spellings, because two operating systems name the same binary
     * differently and neither is a guess: Windows' `tasklist` reports the
     * executable with `.exe` stripped, which is the product name with its space
     * — and a slug build has no space. Both are read off `Brand`, which is the
     * only place the name lives.
     *
     * On macOS this almost never fires, and that is a known gap rather than a
     * bug here: `parseLsof` splits its columns on whitespace, so a command name
     * containing a space shifts the columns and the row is dropped before it
     * reaches the wire. The app's own listener therefore does not appear in the
     * list on a Mac at all — which is a *quieter* wrong answer than the one this
     * function exists to prevent, and it is fixed on the desktop or not at all.
     */
    static func isOwnProcess(_ process: String) -> Bool {
        let name = process.lowercased().replacingOccurrences(of: " ", with: "")
        return name == Brand.name.lowercased().replacingOccurrences(of: " ", with: "")
            || name == Brand.id.lowercased()
    }

    /**
     * The port this phone is talking to the machine on, when it can know it.
     *
     * A direct endpoint carries the desktop's own listener in its URL, so that
     * port is this product's by definition — it is the socket the frame asking
     * the question arrived on. A relay endpoint carries no such thing: the phone
     * dials the relay and the desktop dials out to meet it, so nothing on this
     * side knows which local port the desktop bound. That case returns nothing
     * rather than falling back to the product's default port number, because a
     * default is a guess about somebody's configuration and this whole file is
     * built on not making those.
     */
    static func appPorts(for endpoint: DeckEndpoint?) -> Set<Int> {
        guard case let .direct(url)? = endpoint else { return [] }
        if let port = url.port { return [port] }
        // A URL with no explicit port is on its scheme's default, which is a
        // fact about the URL rather than an assumption about the machine.
        switch url.scheme?.lowercased() {
        case "https", "wss": return [443]
        case "http", "ws": return [80]
        default: return []
        }
    }

    /**
     * The whole screen's content, grouped and ordered.
     *
     * Pure, and takes its inputs rather than reading a model, so every rule in
     * the table above is pinned by a test that needs no simulator and no host.
     *
     * `names` is a snapshot keyed by port rather than the store itself, so this
     * file never learns which machine it is describing and never has to be on an
     * actor to read one.
     *
     * Order within a section is the order the two lists arrived in: the desktop
     * ranks its ports most-likely-to-be-a-dev-server first and offers its
     * folders most-relevant-first, and re-sorting here would throw away the only
     * ordering anybody has an opinion about.
     */
    static func sections(ports: [LocalPort],
                         devServers: [DevServerReport],
                         appPorts: Set<Int> = [],
                         names: [Int: String] = [:]) -> [LocalhostSection] {
        var rows: [LocalhostRow] = []
        /// Ports a dev server has claimed. See "One row per server, never two".
        var claimed = Set<Int>()

        for report in devServers {
            // `no-dev-script` is never a row. `HostLink.devServerRows` already
            // drops it and this drops it again, because the rule belongs to the
            // protocol rather than to one caller: it means "there is nothing to
            // press, and there never will be for this folder".
            guard report.status != .noDevScript else { continue }
            // Only a `ready` report has a proven port. A `starting` one has no
            // port field at all and a `failed` one must never carry the address
            // of the server that died — see `DevServerReport`.
            let port = report.status == .ready ? report.port : nil
            if let port { claimed.insert(port) }
            let entry = port.flatMap { candidate in ports.first { $0.port == candidate } }
            let label = port.flatMap { names[$0] }
            rows.append(LocalhostRow(entry: entry,
                                     dev: report,
                                     name: label,
                                     category: label == nil ? .devServer : .named))
        }

        for entry in ports where !claimed.contains(entry.port) {
            let label = names[entry.port]
            rows.append(LocalhostRow(entry: entry,
                                     dev: nil,
                                     name: label,
                                     category: category(for: entry, named: label != nil, appPorts: appPorts)))
        }

        return PortCategory.allCases.compactMap { category in
            let inside = rows.filter { $0.category == category }
            return inside.isEmpty ? nil : LocalhostSection(category: category, rows: inside)
        }
    }

    /// What a swipe from the trailing edge offers on one row. The table is on
    /// `PortRowAction`; this is the only place that decides it.
    static func secondAction(for row: LocalhostRow) -> PortRowAction {
        if let dev = row.dev {
            switch dev.status {
            case .idle:
                return .start(folder: dev.folder)
            case .failed:
                return .retry(folder: dev.folder)
            case .starting, .ready:
                return dev.sessionId.map { PortRowAction.openSession(id: $0) } ?? .none
            case .noDevScript:
                return .none
            }
        }
        guard let entry = row.entry else { return .none }
        return .copyAddress(port: entry.port)
    }

    /**
     * Which pile one listening port lands in.
     *
     * The order of the tests is the order of the claims' strength, and two of
     * them are load-bearing:
     *
     *  - **The app's own port is checked before the runtime name.** A desktop
     *    running headless is a `node` process, so a machine reached over a
     *    direct endpoint would otherwise offer this phone its own control socket
     *    under "Web servers" — a row that opens the thing that drew it.
     *  - **`guessed` is checked before the runtime name** only for tidiness;
     *    a port with no owner reports its process as `unknown`, which matches no
     *    runtime either way. It is its own group rather than part of "Other"
     *    because "we could not name this" and "this is named and dull" are
     *    different facts, and only one of them might be worth a second look.
     */
    private static func category(for entry: LocalPort, named: Bool, appPorts: Set<Int>) -> PortCategory {
        if named { return .named }
        if appPorts.contains(entry.port) || isOwnProcess(entry.process) { return .app }
        if entry.guessed { return .unnamed }
        if isWebRuntime(entry.process) { return .web }
        return .other
    }
}
