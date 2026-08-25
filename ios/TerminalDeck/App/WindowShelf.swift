/**
 * Which of the machine's browser windows this phone keeps off its list.
 *
 * Asad, on the Browser tab after it had been rebuilt into a screen carrying
 * ports, tunnels, an address bar and a windows row all at once:
 *
 * > *"from the outside we can just make it archive, close, or connect to any
 * > session, or things from three dots and all the relevant stuff. And the home
 * > page is not for the multiple kinds of stuff — it should be smooth, simple."*
 *
 * Three verbs, and two of them already existed. **Close** is `browser.window.act`
 * with `close`; **connect to a session** is `browser.window.bind`. There is no
 * third verb on the wire and there was no notion of archiving a window anywhere
 * in this product — not in `MachineBrowserWire.Act`, whose list is closed and
 * mirrors `WINDOW_ACTIONS` in `src/main/remote/protocol.ts`, and not on the
 * desktop, whose binding store knows only bound and unbound.
 *
 * So it is built here, on the phone, exactly as `SessionShelf` builds the same
 * word for the session list — because it is the same complaint about the same
 * kind of list, and because the alternative was a control that does nothing.
 *
 * ## Archive means what it means everywhere else on this phone
 *
 * The row leaves the list, the window carries on. It is still open in the
 * machine's Chromium, still on whatever page it was on, still bound to whatever
 * session held it, still recording if it was recording. One tap puts it back,
 * and `ArchivedWindowsView` says all of that in a sentence at its foot — the
 * same sentence `ArchivedSessionsView` carries and for the same reason: the
 * danger of this feature is not that a row is hard to find, it is somebody
 * believing they closed four windows and leaving an agent driving one of them.
 *
 * The other reading — archive meaning *close it and remember it so it can be
 * reopened* — would be a genuinely different feature and this phone cannot
 * honestly do it. Reopening needs the address, the profile, the isolation and
 * the binding restored on the far side, and nothing on this wire re-creates a
 * window with those four intact. Half of it would be a Close wearing a gentler
 * word, which is the one outcome worse than not having the verb.
 *
 * ## Windows only, never surfaces
 *
 * The home list has a second kind of row: a **surface** the machine will cast
 * but no window claims — on a server, the drive's own front tab, which
 * `openTab` mints no shell id for at all. Its id is the empty string, this store
 * refuses empty ids the way `SessionShelf` does, and there would be nothing to
 * key it by. It is also the machine's own front page rather than something a
 * person opened, so there is nothing there to curate. A machine that offers only
 * `watch` therefore has no archive at all on its list, which is honest: a phone
 * that cannot drive that browser is not keeping a list of its own about it.
 *
 * ## Keyed by host **and** window, and both parts matter
 *
 * A window id is a **shell tab id** minted by one machine's browser, and nothing
 * makes it unique across machines — the same reason `PortBook` keys a name by
 * host and port rather than by the number alone. A phone paired with a Mac and a
 * server would otherwise hide a window on one because of a swipe on the other.
 *
 * ## Nothing is ever forgotten on its own, and the store is bounded instead
 *
 * There is no moment at which this learns that a window has gone: a window
 * closes, the machine stops listing its id, and a store that read "not in the
 * last list" as "delete the record" would forget an archive every time the
 * socket dropped mid-refresh. Ids also churn far faster than session ids do —
 * every browser restart mints new ones — so what keeps this from growing is the
 * bound below rather than a cleanup rule. `split` already hides the dead ones
 * from every screen by intersecting with the live list.
 */

import Foundation
import Observation

/**
 * Deliberately **not** `@MainActor`, for the two reasons `PortBook` and
 * `SessionShelf` both give, and in particular the second: a screen holds it as
 * `var shelf: WindowShelf = .shared`, which is a default argument on a
 * memberwise initialiser, and those are evaluated in a non-isolated context
 * where a main-actor `shared` cannot be named at all.
 */
@Observable
final class WindowShelf {

    /// The one the screens read. A property of this phone rather than of a
    /// machine, so it is a singleton beside `PortBook` and `SessionShelf` rather
    /// than something threaded through `DeckModel`.
    static let shared = WindowShelf()

    /**
     * How many ids are kept per machine.
     *
     * The same two hundred `SessionShelf` keeps and for the same reason — a
     * bound rather than a workflow — but the churn here is higher: a browser
     * restart re-mints every shell tab id on the machine, so the dead entries
     * accumulate faster than a session list's do. Two hundred short strings is
     * still nothing on disk, and `split` never draws one that the machine is not
     * currently listing.
     */
    static let maxPerHost = 200

    private let defaults: UserDefaults
    private static let storageKey = "terminaldeck.windowShelf.v1"

    /// host id → the window ids that machine's list should not draw, in the
    /// order they were archived. An array rather than a `Set` for the reason
    /// `SessionShelf` gives: dropping the oldest needs an oldest, and a set has
    /// none.
    private var archived: [String: [String]] = [:]

    /// `defaults` is a seam for the tests, which run against a suite of their
    /// own so a test cannot hide a window on the machine it is running from.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Archive

    func isArchived(host: String, window: String) -> Bool {
        archived[host]?.contains(window) == true
    }

    /// Put a row away, or bring it back. There is no pin here to contradict, so
    /// unlike `SessionShelf.setArchived` this is the whole of the verb: a
    /// windows list is short by nature — `MachineBrowserWire.maxWindows` is the
    /// point past which it stops being scannable — and a phone that offered to
    /// reorder a list of six would be inventing work.
    func setArchived(_ on: Bool, host: String, window: String) {
        guard !host.isEmpty, !window.isEmpty else { return }
        if on {
            var ids = archived[host] ?? []
            guard !ids.contains(window) else { return }
            ids.append(window)
            archived[host] = Self.trim(ids)
        } else {
            archived[host]?.removeAll { $0 == window }
            if archived[host]?.isEmpty == true { archived.removeValue(forKey: host) }
        }
        save()
    }

    // MARK: - What the list draws

    /**
     * Split one machine's windows into what the home draws and what it hides.
     *
     * A pure function over values, and separate from the store's own state for
     * the reason `PortCatalog` is separate from `PortBook`: the rule can then be
     * pinned by a test with no simulator, no host and no `UserDefaults`, and the
     * two screens that need it — the home and the archive — make one call each
     * rather than keeping two predicates that could drift apart.
     *
     * The machine's own order is kept exactly, in both halves. That order is
     * `HostLink`'s and this has no business having an opinion about it.
     */
    func split(_ windows: [MachineWindow], host: String) -> (listed: [MachineWindow], archived: [MachineWindow]) {
        guard !host.isEmpty, let hidden = archived[host], !hidden.isEmpty else { return (windows, []) }
        var listed: [MachineWindow] = []
        var away: [MachineWindow] = []
        for window in windows {
            if hidden.contains(window.id) { away.append(window) } else { listed.append(window) }
        }
        return (listed, away)
    }

    /// How many of one machine's **current** windows are archived. Measured
    /// against the live list rather than against the store, because the number
    /// on the menu item has to be the number of rows the screen behind it will
    /// draw — a browser that has been restarted has archived ids for windows
    /// that no longer exist, and a count of those opens onto nothing.
    func archivedCount(_ windows: [MachineWindow], host: String) -> Int {
        split(windows, host: host).archived.count
    }

    // MARK: - Storage

    /// Oldest first, so the drop is of the thing archived longest ago. See
    /// `maxPerHost` for why there is a bound at all.
    private static func trim(_ ids: [String]) -> [String] {
        ids.count <= maxPerHost ? ids : Array(ids.suffix(maxPerHost))
    }

    private struct Stored: Codable {
        var archived: [String: [String]]
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        // Bounded on the way back out as well as on the way in, exactly as
        // `PortBook` cleans its names on load: a record written by another build
        // — or edited by hand in a simulator — must not be able to get around
        // the limit this store promises to hold.
        archived = stored.archived.mapValues { Self.trim($0) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(archived: archived)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
