/**
 * What this phone calls the ports on a machine, and which groups it has folded.
 *
 * Asad, walking the localhost list on his phone: *"if we see the full list also,
 * we will not be able to know which one holds what stuff, what is inside any of
 * them… we should be able to maybe rename them or something under there… agent
 * service, WSL relay thing. Maybe we can rename them somehow."* The list he was
 * looking at read `localhost:2019 wslrelay`, `localhost:2222 wslrelay`,
 * `localhost:3100 wslrelay`, `localhost:6666 AgentService` — four process names
 * that say nothing about what is being served, and no way to write down what he
 * had worked out.
 *
 * ## Why the name lives here and not on the desktop
 *
 * Because the desktop does not know it either. `dev-ports.ts` deliberately
 * refuses to guess which framework is behind a port; all it can honestly report
 * is the number and the process holding it. The missing knowledge is a person's,
 * so this is where it is kept — on the phone, in `UserDefaults`, against the
 * machine and the port.
 *
 * A name is also the only *promotion* control this screen has. Naming a port is
 * a statement that it matters, so a named port is lifted out of whatever pile it
 * was derived into and shown first. That is one control doing the job of two —
 * see `PortCatalog` for the grouping that reads it.
 *
 * ## Keyed by host **and** port, because 3000 is not one thing
 *
 * A phone paired with a Mac and a Windows PC is holding two completely
 * unrelated port 3000s, and a store keyed on the number alone would show the
 * Mac's name over the PC's server. The host id is the same stable string
 * everything else in this app keys machines by — see `DeckEndpoint.hostId` — so
 * a machine that is re-paired after a revoke keeps the names it was given, in
 * the same way it keeps its nickname.
 *
 * Names are **not** dropped when a machine is forgotten. That matches
 * `StoredCredential.nickname`, which also survives a re-pair, and it is the
 * kinder failure: a few dozen bytes of dead text is nothing, and somebody who
 * unpairs a machine by accident does not also lose the work of naming its ports.
 *
 * ## The text is bounded on the way in
 *
 * It is the user's own text rather than something a machine sent, so it is not
 * untrusted in the way `DevServerReport.note` is — but it still lands on a phone
 * row, and a pasted paragraph with a newline in it would push a card to three
 * lines and shove everything below it off the screen. `clean` trims it, folds
 * out anything that is not printable, and cuts it to a length that fits.
 */

import Foundation
import Observation

/**
 * Deliberately **not** `@MainActor`, unlike most of the observable objects in
 * this app.
 *
 * Two reasons, and the second is the one that decided it. Nothing here touches
 * UIKit or a socket — it is a dictionary and a `UserDefaults` write, and every
 * caller is already a view running on the main thread. And a screen holds it as
 * `var book: PortBook = .shared`, which is a default argument on a memberwise
 * initialiser: those are evaluated in a non-isolated context, so a main-actor
 * `shared` cannot be named there at all.
 */
@Observable
final class PortBook {

    /**
     * The one the screens read.
     *
     * A singleton rather than something threaded through `DeckModel`, because it
     * is a property of *this phone* rather than of a machine — the same shape
     * `TextSize` and `AlertSettings` have. Those two are static façades with no
     * observation on them, which `DeckSettingsView` has to work around by
     * bumping a counter to force a redraw; this is an `@Observable` object
     * instead, so a rename repaints the row that was renamed and nothing else.
     */
    static let shared = PortBook()

    /**
     * The longest name a row will keep.
     *
     * Forty, because the title line of a port card at 15pt runs out somewhere
     * around there on the narrowest supported iPhone and everything past it is
     * an ellipsis. Cutting on the way in rather than truncating on the way out
     * means the name in the rename field is the name on the row.
     */
    static let maxNameLength = 40

    private let defaults: UserDefaults
    private static let storageKey = "terminaldeck.portBook.v1"

    /// host id → port, as a string → the name. Nested rather than flat because
    /// a flat `"host/port"` key cannot be searched by host without parsing, and
    /// the one operation that will eventually be wanted is "forget this machine".
    private var names: [String: [String: String]] = [:]

    /// host id → category → whether the user folded it. Only the categories a
    /// person has actually touched are in here; everything else falls through to
    /// `PortCategory.foldedByDefault`, which is what makes a machine nobody has
    /// configured open on the interesting groups and closed on the noise.
    private var folds: [String: [String: Bool]] = [:]

    /// `defaults` is a seam for the tests, which run against their own suite so
    /// a test run cannot rename the ports on the machine it is running from.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Names

    /// The user's name for one port, or nil. Nil is the normal state.
    func name(host: String, port: Int) -> String? {
        names[host]?[String(port)]
    }

    /**
     * Give a port a name, or take its name away.
     *
     * Nil, empty and whitespace all clear it, deliberately: the rename field
     * starts populated with whatever is already there, so selecting it all and
     * deleting is the obvious way somebody undoes a name, and it must not leave
     * an empty string behind that reads as a nameless row with a name.
     */
    func setName(_ raw: String?, host: String, port: Int) {
        guard !host.isEmpty else { return }
        let key = String(port)
        if let cleaned = Self.clean(raw) {
            names[host, default: [:]][key] = cleaned
        } else {
            names[host]?.removeValue(forKey: key)
            if names[host]?.isEmpty == true { names.removeValue(forKey: host) }
        }
        save()
    }

    /**
     * The text as it will be stored, or nil when there is nothing left of it.
     *
     * Static and separate from `setName` so the rules can be pinned by a test
     * without a store, and so the rename field can show the same limit it will
     * be held to.
     *
     * Newlines go with the other control characters rather than being turned
     * into spaces. A name with a line break in it is a paste accident, not an
     * intention, and joining the halves with a space guesses at what was meant.
     */
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let stripped = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxNameLength else { return trimmed }
        // Trimmed again after the cut: a name that runs out mid-word leaves a
        // trailing space that would come back as a different string than the one
        // the field shows.
        return String(trimmed.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Folding

    /// Whether a group is closed on this machine. The user's choice where they
    /// have made one, the category's own default where they have not.
    func isFolded(host: String, category: PortCategory) -> Bool {
        folds[host]?[category.rawValue] ?? category.foldedByDefault
    }

    /**
     * Remember that a group was opened or closed.
     *
     * The choice is written even when it matches the default, rather than being
     * cleared back to "unset". A default that later changes — because a category
     * turns out to be noisier than it looked — must not silently re-fold a group
     * somebody deliberately opened.
     */
    func setFolded(_ folded: Bool, host: String, category: PortCategory) {
        guard !host.isEmpty else { return }
        folds[host, default: [:]][category.rawValue] = folded
        save()
    }

    // MARK: - Storage

    private struct Stored: Codable {
        var names: [String: [String: String]]
        var folds: [String: [String: Bool]]
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        // Cleaned on the way back out as well as on the way in. The bound is a
        // property of what a row can draw, and a record written by an older
        // build — or edited by hand in a simulator — must not be able to get
        // around it.
        names = stored.names.mapValues { ports in
            ports.compactMapValues { Self.clean($0) }
        }
        folds = stored.folds
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(names: names, folds: folds)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
