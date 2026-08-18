/**
 * Which sessions this phone keeps out of the way, and which it keeps at the top.
 *
 * Asad, on the phone's session list: *"swipe left/right on a session row should
 * reveal buttons, WhatsApp-style — close the session (with a confirmation),
 * archive, move. When we will have a lot of sessions we will not like to have
 * all of them over here."* And, about what the gesture does today: *"swipe
 * currently just opens the session, which tapping already does. It's nonsense to
 * keep this feature. We need to use it for something important."*
 *
 * The sentence that decides what this module is, is the second half of the
 * first quote. The problem being described is **a list that is too long to read**,
 * not a machine with too many processes on it — so the fix is a property of this
 * phone's list rather than a command sent to the machine, and both verbs here
 * change what is drawn and nothing else.
 *
 * ## Archive means archive, in the sense the word already has
 *
 * Every phone this app is used from already has this word on it, and it means one
 * thing on all of them: the row leaves the list, the thing itself carries on, and
 * it is one tap to get back. That is exactly what this does. A session that is
 * archived is still running on the machine, still listed by the desktop, still
 * producing output, still able to raise an alert — and none of that is hidden,
 * because the screen that lists archived rows says so in a sentence.
 *
 * The alternative reading — archive meaning *stop it and put it away* — is a
 * thing this app cannot do at all today, and doing half of it would be worse
 * than doing none. See `SessionListView`'s note on Close.
 *
 * ## Pin is the "move"
 *
 * He asked for a third action called move, in a list where the two others were
 * close and archive. On a phone there is nowhere for a session to move *to*: it
 * lives in a folder on a machine, chosen when it was started, and neither of
 * those can change afterwards. What a person moving a row in a list of forty
 * actually wants is the row **at the top**, which is what every list on this
 * phone calls pinning, and it is the other half of the same complaint — archive
 * pushes the noise down, pinning pulls the two that matter up.
 *
 * So the word on the button is `Pin`, because that is what it does and what the
 * platform calls it. Naming it `Move` and having it do this would be a control
 * whose label describes something else, which is the single most repeated
 * complaint in the whole review.
 *
 * ## Both are per machine, and both live on the phone
 *
 * A phone paired with a Mac and a Windows PC holds two unrelated lists, and a
 * store keyed on the session id alone would hide a row on one machine because of
 * a swipe on the other. Ids are minted by each machine's own session layer and
 * nothing makes them unique across machines — the same reason `DeckModel.Route`
 * carries a host — so every entry here is keyed by host **and** session.
 *
 * They live on the phone rather than on the desktop because they are about this
 * screen. Somebody who archives forty finished sessions from the sofa has not
 * asked for their Mac's sidebar to change, and a phone that could reorder the
 * desktop's list would be a surprising thing to hand to a guest.
 *
 * ## Nothing is ever forgotten on its own
 *
 * Not on unpairing, and not when a session exits. Both are deliberate and both
 * are the same argument `PortBook` makes about names: a few dozen bytes of dead
 * text costs nothing, and somebody who unpairs a machine by accident should not
 * also lose an afternoon of tidying. What *is* bounded is how much of it can
 * accumulate — see `trim`.
 */

import Foundation
import Observation

/**
 * Deliberately **not** `@MainActor`, for the two reasons `PortBook` gives and in
 * particular the second: a screen holds it as `var shelf: SessionShelf = .shared`,
 * which is a default argument on a memberwise initialiser, and those are
 * evaluated in a non-isolated context where a main-actor `shared` cannot be
 * named at all.
 */
@Observable
final class SessionShelf {

    /// The one the screens read. A property of this phone rather than of a
    /// machine, so it is a singleton beside `PortBook` and `TextSize` rather
    /// than something threaded through `DeckModel`.
    static let shared = SessionShelf()

    /**
     * How many ids are kept per machine, per list.
     *
     * A bound rather than a cleanup rule, because there is no moment at which
     * this store learns that a session is gone for good: the desktop stops
     * listing an id when its pty is reaped, and a phone that treated "not in the
     * last list" as "delete the record" would forget an archive every time the
     * socket dropped mid-refresh. So the record survives and the *store* is
     * bounded instead, oldest first.
     *
     * Two hundred is far past what a person will ever archive by hand on a phone
     * and still nothing on disk — an id is 26 characters. The number exists so
     * that a machine which churns through sessions for a year cannot grow this
     * without limit, not to enforce a workflow.
     */
    static let maxPerHost = 200

    private let defaults: UserDefaults
    private static let storageKey = "terminaldeck.sessionShelf.v1"

    /**
     * host id → the session ids that machine's list should not draw, in the
     * order they were archived.
     *
     * An array rather than a `Set`, and the order is what makes {@link trim}
     * possible: dropping the oldest needs an oldest, and a set has none. Lookup
     * is a linear scan over at most `maxPerHost` short strings, which is nothing
     * next to the work of drawing the row it decides about.
     */
    private var archived: [String: [String]] = [:]

    /// host id → the session ids pinned to the top, most recently pinned first.
    /// Same shape and same bound as the list above; the order is the display
    /// order rather than only a trimming order.
    private var pinned: [String: [String]] = [:]

    /// `defaults` is a seam for the tests, which run against a suite of their own
    /// so a test cannot archive a session on the machine it is running from.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Archive

    func isArchived(host: String, session: String) -> Bool {
        archived[host]?.contains(session) == true
    }

    /// Every archived id on one machine, for the screen that lists them.
    func archived(host: String) -> [String] {
        archived[host] ?? []
    }

    /**
     * Put a row away, or bring it back.
     *
     * Archiving also **unpins**, because the two states contradict each other:
     * a row cannot be both at the top of the list and absent from it, and
     * leaving a stale pin behind would make an unarchive jump the row to the top
     * for reasons nobody could see. Unarchiving does not re-pin — a row that
     * comes back comes back where it belongs.
     */
    func setArchived(_ on: Bool, host: String, session: String) {
        guard !host.isEmpty, !session.isEmpty else { return }
        if on {
            setPinned(false, host: host, session: session, save: false)
            var ids = archived[host] ?? []
            guard !ids.contains(session) else { return }
            ids.append(session)
            archived[host] = Self.trim(ids)
        } else {
            archived[host]?.removeAll { $0 == session }
            if archived[host]?.isEmpty == true { archived.removeValue(forKey: host) }
        }
        save()
    }

    // MARK: - Pin

    func isPinned(host: String, session: String) -> Bool {
        pinned[host]?.contains(session) == true
    }

    func setPinned(_ on: Bool, host: String, session: String) {
        setPinned(on, host: host, session: session, save: true)
    }

    /**
     * Pinning also **unarchives**, the mirror of the rule above and for the same
     * reason: pinning something is a statement that it matters, and the only
     * honest response to that is to put it back on the screen.
     *
     * The private `save` flag exists so that the two verbs can call each other
     * without writing the store twice for one gesture. It is not an optimisation
     * — a double write is cheap — it is so that a reader of `setArchived` sees
     * one save at the end of it and knows there is exactly one commit point.
     */
    private func setPinned(_ on: Bool, host: String, session: String, save shouldSave: Bool) {
        guard !host.isEmpty, !session.isEmpty else { return }
        if on {
            archived[host]?.removeAll { $0 == session }
            if archived[host]?.isEmpty == true { archived.removeValue(forKey: host) }
            var ids = pinned[host] ?? []
            ids.removeAll { $0 == session }
            // Newest first: the row somebody just pinned goes to the very top,
            // which is where they are looking when they let go of the swipe.
            ids.insert(session, at: 0)
            pinned[host] = Array(ids.prefix(Self.maxPerHost))
        } else {
            pinned[host]?.removeAll { $0 == session }
            if pinned[host]?.isEmpty == true { pinned.removeValue(forKey: host) }
        }
        if shouldSave { save() }
    }

    // MARK: - The order a list is drawn in

    /**
     * Split one machine's sessions into what the list draws and what it hides.
     *
     * A pure function over values, and separate from the store's own state for
     * the reason `PortCatalog` is separate from `PortBook`: every rule about
     * ordering can then be pinned by a test with no simulator, no host and no
     * `UserDefaults`, and the view has one call rather than three predicates it
     * could get subtly out of step.
     *
     * The pinned rows keep **the order they were pinned in**, not the order the
     * machine sent. That is the whole point of the gesture: a person who pins two
     * sessions is stating which one they want first, and re-sorting them by
     * whatever the desktop's list order happens to be would throw that away. The
     * rest keep the machine's order exactly, because that order is `HostLink`'s
     * and this has no business having an opinion about it.
     */
    func split(_ sessions: [RemoteSession], host: String) -> (listed: [RemoteSession], archived: [RemoteSession]) {
        guard !host.isEmpty else { return (sessions, []) }
        let hidden = archived[host] ?? []
        let order = pinned[host] ?? []
        guard !hidden.isEmpty || !order.isEmpty else { return (sessions, []) }

        var listed: [RemoteSession] = []
        var away: [RemoteSession] = []
        var top: [RemoteSession] = []
        for session in sessions {
            if hidden.contains(session.id) {
                away.append(session)
            } else if order.contains(session.id) {
                top.append(session)
            } else {
                listed.append(session)
            }
        }
        // Sorted by where the id sits in the pin list rather than by the
        // machine's order. `firstIndex` cannot be nil here — every member of
        // `top` was put there by the `contains` above — and the fallback keeps
        // this total rather than trapping if that ever stops being true.
        top.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        return (top + listed, away)
    }

    /// How many of one machine's *current* sessions are archived. The count on
    /// screen has to be the number of rows the screen behind it will draw, so it
    /// is measured against the live list rather than against the store — a
    /// machine that has been rebooted has archived ids for sessions that no
    /// longer exist, and a badge counting those is a badge that opens onto
    /// nothing.
    func archivedCount(_ sessions: [RemoteSession], host: String) -> Int {
        split(sessions, host: host).archived.count
    }

    // MARK: - Storage

    /// Oldest first, so the drop is of the thing archived longest ago. See
    /// `maxPerHost` for why there is a bound at all.
    private static func trim(_ ids: [String]) -> [String] {
        ids.count <= maxPerHost ? ids : Array(ids.suffix(maxPerHost))
    }

    private struct Stored: Codable {
        var archived: [String: [String]]
        var pinned: [String: [String]]
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        // Bounded on the way back out as well as on the way in, exactly as
        // `PortBook` cleans its names on load: a record written by another build
        // — or edited by hand in a simulator — must not be able to get around
        // the limit this store promises to hold.
        archived = stored.archived.mapValues { Self.trim($0) }
        pinned = stored.pinned.mapValues { Array($0.prefix(Self.maxPerHost)) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(archived: archived, pinned: pinned)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
