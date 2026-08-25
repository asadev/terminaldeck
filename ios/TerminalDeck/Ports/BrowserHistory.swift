/**
 * Every page this phone has opened through a tunnel, and when.
 *
 * Asad, listing what the browser on the phone was missing: *"search history and
 * cookies and all of this. Everything that Mac side had."* The cookies were
 * already there — `BrowserBridge` builds its web view on
 * `WKWebsiteDataStore.default()` precisely so a dev server that logs you in
 * keeps you logged in between taps. The history was not: `LocalhostBrowser` is
 * pushed, and the moment it is popped the tunnel closes, the web view is torn
 * down and everything it had been showing is gone. A browser that cannot tell
 * you where you were ten minutes ago is a window, not a browser.
 *
 * ## Why this is a file on the phone and not a frame on the wire
 *
 * Asad, drawing the line between the two halves of this app: *"any of the
 * feature which is not something that we can wire or it should be sitting in the
 * device whichever the device we are using at the moment and it is not related
 * to the folder sided or server sided then build also but keep it on the phone
 * side or app side."*
 *
 * A visit is a fact about **this phone**. The machine already knows what it
 * served — it has its own logs and its own browser history — and what it has no
 * business holding is a record of which of its pages somebody looked at from the
 * sofa. So nothing here reaches the desktop: no capability, no frame, no host
 * code. It is `UserDefaults`, the same as `PortBook` next door, and it behaves
 * the way Safari's own history behaves — it belongs to the device it was made
 * on.
 *
 * ## Keyed by machine, because a port number is not an address
 *
 * `localhost:3000` on his Mac and `localhost:3000` on a Hetzner box are two
 * unrelated pages that happen to share a number, and a history keyed on the
 * number alone would offer one machine's rows while the other is connected — and
 * then open something else entirely when one was tapped. `PortBook` keys on
 * `host:` for exactly this reason and this does the same, against the same
 * stable `DeckEndpoint.hostId`.
 *
 * ## What a visit is, and why it is a port and a path rather than a URL string
 *
 * The URL the web view reports is `http://127.0.0.1:3000/admin` — or
 * `http://[::1]:3000/admin`, because `PortTunnel` binds whichever loopback
 * family won the race, and in the Simulator that is routinely the v6 one. Two
 * spellings of one page. Storing the raw string would put the same page on the
 * list twice, once per literal, and neither row would be wrong.
 *
 * So a visit holds the **port on the machine** and the **path**, which is the
 * pair that identifies the page and — not by coincidence — the pair
 * `MachineBrowserView.openHere(_:_:)` needs to open it again. The address a row
 * draws is derived from them: `localhost:3000/admin`, which is what somebody
 * would have typed into the address bar to get there. The tunnel binds the
 * machine's own port number on this phone's loopback, so the number in the URL
 * *is* the number on the machine — see `PortTunnel.bind`.
 *
 * ## The title arrives second, so recording is two calls and not one
 *
 * A document has no title until it has loaded. `WKWebView` publishes the new
 * `url` at the start of a navigation and the new `title` some time after it —
 * and in between, the title property still holds the **previous page's** title.
 * A single `record(url, title)` called from both signals would therefore write
 * the last page's name onto this page's row, and the row somebody scrolls back
 * to a week later would be a lie with a plausible name on it.
 *
 * Hence two entry points with two different claims. `record(address:host:)` says
 * *this page was opened* and makes no claim about its name; `retitle` says *the
 * document that is on screen calls itself this*. An empty title never overwrites
 * a real one, which is what makes the clearing-then-setting `WKWebView` does on
 * every navigation harmless.
 *
 * ## The title is the page's text, not the user's
 *
 * This is the one place this store differs from `PortBook` in kind rather than
 * in shape. A port's name is typed by the person holding the phone; a page title
 * is `document.title` on a site that came down a tunnel, and a page can set that
 * to ten thousand characters of anything it likes. So it is bounded and stripped
 * of control characters on the way in *and* on the way back off disk, for the
 * same reason `DevServerReport.note` is treated as untrusted: it lands on a row
 * in this app's own chrome.
 */

import Foundation
import Observation

/**
 * Deliberately **not** `@MainActor`, for the reason written out at length in
 * `PortBook`: a screen holds one of these as `var history: BrowserHistory =
 * .shared`, that is a default argument on a memberwise initialiser, and default
 * arguments are evaluated in a non-isolated context — so a main-actor `shared`
 * could not be named there at all. Nothing in here touches UIKit or a socket;
 * it is a dictionary and a `UserDefaults` write, and every caller is a view or a
 * bridge already on the main thread.
 */
@Observable
final class BrowserHistory {

    /**
     * The one the screens read.
     *
     * A singleton beside `PortBook.shared` rather than something hung off
     * `DeckModel`, and for the same reason: this is a property of *this phone*
     * rather than of a machine. A phone that is paired with nothing still has a
     * history of the machines it used to be paired with, and a model rebuilt on
     * a reconnect must not take it with it.
     */
    static let shared = BrowserHistory()

    /**
     * The longest history one machine keeps.
     *
     * Two hundred **distinct pages** — the list is deduplicated, so this is not
     * two hundred navigations, it is two hundred different addresses, which on a
     * dev machine is weeks of work rather than an afternoon.
     *
     * The number is bounded by where it lives rather than by what anybody wants
     * to scroll. `UserDefaults` is read into memory whole at launch and this
     * store is written whole on every visit; at roughly 120 bytes of JSON per
     * row that is 24KB per machine, which is nothing to load and nothing to
     * write. Ten thousand rows would be neither, and the screen that reads them
     * is searched rather than scrolled to the end — nobody is going to find the
     * four-thousandth row by dragging.
     */
    static let maxVisits = 200

    /**
     * The longest page title a row will keep.
     *
     * A row draws one line and a phone runs out somewhere past forty characters,
     * so this is not about drawing — it is about what a **search** should still
     * be able to find. A title cut at forty would drop the end of *"Orders ·
     * Admin · Storefront (staging)"*, which is the half somebody searches for.
     * A hundred and twenty keeps every real title and refuses the pathological
     * one a page could hand over.
     */
    static let maxTitleLength = 120

    /**
     * The longest path this will remember, and it **refuses** rather than cuts.
     *
     * Truncating a path produces an address that is not the page — a row that
     * would open something else when it was tapped, which is worse than not
     * having the row. So an absurd URL is simply not recorded. A kilobyte is far
     * past any real dev-server route, including the query strings a dashboard
     * puts its filters in.
     */
    static let maxPathLength = 1024

    /**
     * How long a repeat visit to the page already at the top is folded into the
     * one before it without touching the disk.
     *
     * The case this exists for is the one this whole feature is aimed at: a
     * dev server with hot reload navigates the same URL dozens of times a minute
     * while somebody saves a file. Deduplication already means those are one
     * row — but each of them would still re-encode the whole store and write it,
     * for a timestamp moving by a second and a half. Two seconds of drift
     * between the time in memory and the time on disk costs a row that says
     * *2 minutes ago* when it could have said *2 minutes ago*.
     */
    static let coalesce: TimeInterval = 2

    /**
     * One page, once.
     *
     * `port` and `path` are the identity and the answer both: they are what
     * makes two spellings of a loopback address one row, and they are exactly
     * what `MachineBrowserView.openHere(_:_:)` takes.
     */
    struct Visit: Identifiable, Equatable, Codable {
        /// The port **on the machine**. The tunnel binds the same number on this
        /// phone, so it is also the number in the URL the web view reported.
        let port: Int
        /// Always begins with `/`, and carries the query and the fragment when
        /// there were any — the same string `LocalhostAddress` produces and the
        /// same one `LocalhostBrowser` resolves against the tunnel's origin.
        let path: String
        /// What the document called itself, or empty until it said. Empty is a
        /// normal state, not a missing one — see the type header.
        var title: String
        var at: Date

        /// Unique within one machine's list, because that is what deduplication
        /// means here.
        var id: String { "\(port)\(path)" }

        /**
         * What the row draws, and what somebody would have typed to get here.
         *
         * The trailing slash goes for a root path so that this reads the same as
         * the port rows one screen over — `PortRow` draws `localhost:3000` — and
         * so the two screens do not appear to be talking about different things.
         * `LocalhostAddress.parse` accepts both spellings, so nothing downstream
         * cares which one is shown.
         */
        var address: String {
            path == "/" ? "localhost:\(port)" : "localhost:\(port)\(path)"
        }
    }

    private let defaults: UserDefaults
    /// The clock, as a seam. The coalescing window above is the only piece of
    /// behaviour here with a duration in it, and a test proving it must be able
    /// to move time rather than sleep through it.
    private let now: () -> Date
    private static let storageKey = "terminaldeck.browserHistory.v1"

    /// host id → visits, newest first. Held in order rather than sorted on read
    /// because every read is a screen drawing and every write is one insertion.
    private var byHost: [String: [Visit]] = [:]

    /// `defaults` is a seam for the tests, which run against their own suite so
    /// a test run cannot write history onto the machine it is running from —
    /// the same arrangement `PortBook` uses.
    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        load()
    }

    // MARK: - Reading

    /// One machine's history, newest first.
    func visits(host: String) -> [Visit] {
        byHost[host] ?? []
    }

    /**
     * One machine's history, filtered by what somebody typed.
     *
     * **Every whitespace-separated word has to appear somewhere**, in the
     * address or in the title, rather than the whole query having to appear as
     * one substring. Somebody looking for the settings page on port 3000 types
     * `3000 settings`, and no single string on that row contains that — the
     * number is in the address and the word is in the title. A plain
     * `contains(query)` would find nothing and the screen would look empty and
     * broken while the row it was being asked for sat one line below the field.
     *
     * `localizedStandardContains` rather than `lowercased().contains`, so the
     * search is case- **and** diacritic-insensitive and behaves the way search
     * behaves everywhere else on the phone.
     */
    func visits(host: String, matching query: String) -> [Visit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return visits(host: host) }
        return visits(host: host).filter { visit in
            terms.allSatisfy { term in
                visit.address.localizedStandardContains(term)
                    || visit.title.localizedStandardContains(term)
            }
        }
    }

    // MARK: - Writing

    /**
     * A page was opened. Nothing is claimed about its name.
     *
     * `address` is whatever the web view currently reports — a full
     * `http://127.0.0.1:3000/admin`. It is put through `LocalhostAddress`, which
     * is the one place in this app that decides what a loopback address is, and
     * anything it refuses is dropped without a sound: `about:blank`, a `data:`
     * URL and the error page a failed load leaves behind are all things that
     * happen on this screen and none of them is a page somebody visited.
     *
     * A page already in the list keeps **its own** title and moves to the top
     * with a new time. That is not the stale-title problem the header describes
     * — it is the opposite, and it is what makes a page you have been to before
     * come back with its name already on it instead of blank until it reloads.
     */
    func record(address: String, host: String) {
        guard !host.isEmpty else { return }
        guard case let .address(port, path) = LocalhostAddress.parse(address) else { return }
        guard path.count <= Self.maxPathLength else { return }

        var list = byHost[host] ?? []
        let stamp = now()
        let id = "\(port)\(path)"

        if let first = list.first, first.id == id {
            // The hot-reload case. Same page, still on top, seen a moment ago:
            // move the clock in memory and leave the disk alone.
            guard stamp.timeIntervalSince(first.at) >= Self.coalesce else {
                list[0].at = stamp
                byHost[host] = list
                return
            }
            list[0].at = stamp
            byHost[host] = list
            save()
            return
        }

        var title = ""
        if let existing = list.firstIndex(where: { $0.id == id }) {
            title = list[existing].title
            list.remove(at: existing)
        }
        list.insert(Visit(port: port, path: path, title: title, at: stamp), at: 0)
        byHost[host] = Self.bounded(list)
        save()
    }

    /**
     * The document on screen says what it is called.
     *
     * Addressed by the page rather than by an index, because the caller is a
     * KVO notification about a web view and has no idea which row it belongs to
     * — it knows the address the view is showing, and that is enough.
     *
     * An empty or whitespace-only title is **ignored**, never written. WebKit
     * blanks `title` on every navigation before the new document sets its own,
     * and a store that took that literally would wipe the name off a row a
     * fraction of a second after writing it.
     *
     * A title for a page that is not in the list yet records the visit as well.
     * It should not be reachable — the address changes before the title does —
     * but the alternative is silently dropping the only name a page will ever
     * give, and the visit it implies is real either way.
     */
    func retitle(address: String, title: String, host: String) {
        guard !host.isEmpty, let cleaned = Self.clean(title) else { return }
        guard case let .address(port, path) = LocalhostAddress.parse(address) else { return }
        guard path.count <= Self.maxPathLength else { return }

        var list = byHost[host] ?? []
        let id = "\(port)\(path)"
        if let index = list.firstIndex(where: { $0.id == id }) {
            guard list[index].title != cleaned else { return }
            list[index].title = cleaned
        } else {
            list.insert(Visit(port: port, path: path, title: cleaned, at: now()), at: 0)
        }
        byHost[host] = Self.bounded(list)
        save()
    }

    // MARK: - Forgetting

    /// Drop one page from one machine's history. The swipe on the row.
    func forget(_ visit: Visit, host: String) {
        guard var list = byHost[host] else { return }
        list.removeAll { $0.id == visit.id }
        if list.isEmpty { byHost.removeValue(forKey: host) } else { byHost[host] = list }
        save()
    }

    /**
     * Drop everything this phone remembers about one machine.
     *
     * **One machine, not all of them**, and the screen names which one on the
     * button that does it. The screen is a single machine's history — its rows,
     * its search, its swipes — and a Clear on it that silently also wiped the
     * history of a laptop that is not even connected would be the app doing
     * something nobody could see it do. Somebody who wants both clears both,
     * from the two screens that show them.
     */
    func clear(host: String) {
        guard byHost[host] != nil else { return }
        byHost.removeValue(forKey: host)
        save()
    }

    // MARK: - Bounds

    /**
     * Newest first, no duplicates, and no longer than the cap — oldest dropped.
     *
     * Applied on the way in and again on the way back off disk. The sort is not
     * redundant with insertion order: `retitle` can create a row for a page
     * whose time is older than the one above it, and a file written by an older
     * build has whatever order it has.
     *
     * **Ties keep the order they came in**, which is the position in the array,
     * which is newest first. Swift's sort does not promise to be stable, and two
     * visits carrying the identical instant is not a theoretical case: it is
     * every test that injects a fixed clock, and a screen whose rows shuffled
     * between two runs would make one of those tests fail once a fortnight for
     * no reason anybody could reproduce.
     */
    private static func bounded(_ visits: [Visit]) -> [Visit] {
        var seen = Set<String>()
        let unique = visits
            .enumerated()
            .sorted { left, right in
                left.element.at == right.element.at
                    ? left.offset < right.offset
                    : left.element.at > right.element.at
            }
            .map(\.element)
            .filter { seen.insert($0.id).inserted }
        guard unique.count > maxVisits else { return unique }
        return Array(unique.prefix(maxVisits))
    }

    /**
     * A page title as it will be stored, or nil when there is nothing left.
     *
     * The same shape as `PortBook.clean` and deliberately **not** the same
     * function: that one enforces a forty-character bound on a name somebody
     * typed, this one enforces a much longer bound on text a web page handed
     * over, and sharing the code would mean a change to what fits on a port row
     * silently truncating everybody's browsing history.
     *
     * Control characters go rather than being folded to spaces — a title with a
     * newline in it is a page being odd, and joining the halves would invent a
     * string the page never had.
     */
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let stripped = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxTitleLength else { return trimmed }
        return String(trimmed.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Storage

    private struct Stored: Codable {
        var visits: [String: [Visit]]
    }

    /**
     * Read back, and treated as untrusted on the way out.
     *
     * Every bound is re-applied. Half of what is in this file arrived from a web
     * page, the file itself is editable by hand in a Simulator, and a record
     * written by a build with a different cap must not be able to get around
     * this one's. A row that does not survive the checks is dropped rather than
     * repaired: a port outside the legal range or a path that does not start at
     * the root is not a page this app could open, so a row offering to open it
     * would be a button that cannot work.
     */
    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        byHost = stored.visits.compactMapValues { list -> [Visit]? in
            let usable = list.compactMap { visit -> Visit? in
                guard visit.port > 0, visit.port <= 65_535 else { return nil }
                guard visit.path.hasPrefix("/"), visit.path.count <= Self.maxPathLength else {
                    return nil
                }
                var row = visit
                row.title = Self.clean(visit.title) ?? ""
                return row
            }
            return usable.isEmpty ? nil : Self.bounded(usable)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(visits: byHost)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
