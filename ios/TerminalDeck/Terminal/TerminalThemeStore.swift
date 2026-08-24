/**
 * Which colours this phone draws a terminal in, and the ones somebody made.
 *
 * ## Per person, on this phone — not per session and not per machine
 *
 * The same rule `TextSize` and `Appearance` already keep, and the same argument:
 * a colour scheme is about the screen being looked at and the room it is being
 * looked at in, and neither changes when the session on the other end does. The
 * two alternatives are worse in ways that can be described rather than argued
 * about:
 *
 *  - **Per session** would mean one phone showing two colours depending on which
 *    row was tapped, and would have to be carried in a store belonging to
 *    somebody else's machine for sessions that live there.
 *  - **Per machine** would mean the terminal changing colour when he switched
 *    from the Mac to the Windows PC — same phone, same room, same time of night.
 *    He asked for the choice *"phone also, for Windows, for MacBook, all of
 *    them"*, which is one choice available on each surface, not one choice
 *    shared between them.
 *
 * So this is the phone's own, it stands alone, and **the screen says so** rather
 * than leaving somebody to discover it by changing the Mac and watching the
 * phone not change.
 *
 * ## What is stored is an id, not a palette
 *
 * Which is what lets a shipped scheme be *corrected* by a later build: a wrong
 * hex in Nord is fixed for everybody who chose it, instead of only for people
 * who had not chosen it yet. The default id is `follow-app`, which is not a
 * scheme but a refusal to pin one — see `TerminalScheme.followAppID`.
 *
 * ## Custom schemes live beside the built-ins
 *
 * Editing a built-in is not an edit, it is a copy: the built-in table is a set
 * of published palettes and a *Dracula* that is not Dracula is worse than no
 * Dracula. `copying` makes the duplicate — id `custom-1`, name *"Dracula
 * (yours)"*, both spelt by the shared file — and from then on it is an ordinary
 * scheme that can be renamed, edited in place and deleted.
 *
 * ## What makes an open session change colour
 *
 * `Notification.Name.terminalSchemeChanged`, posted by every mutation here.
 * SwiftUI screens observe the object and redraw; `TerminalBridge` is a UIKit
 * object SwiftUI does not own, and SwiftTerm has already resolved and frozen
 * every colour it was given, so nothing repaints a session on screen but that
 * notification. See `TerminalBridge.applyColors`.
 */

import Foundation
import Observation

/**
 * Not `@MainActor`, for the reason `PortBook` is not: a screen holds it as
 * `var themes: TerminalThemeStore = .shared`, which is a default argument on a
 * memberwise initialiser, and those are evaluated in a non-isolated context
 * where a main-actor `shared` cannot be named at all. Nothing here touches
 * UIKit — it is an array, a `UserDefaults` write and a notification.
 */
@Observable
final class TerminalThemeStore {

    static let shared = TerminalThemeStore()

    private static let selectionKey = "terminaldeck.terminalScheme.v1"
    private static let customKey = "terminaldeck.terminalSchemes.custom.v1"

    private let defaults: UserDefaults
    /// A seam for the tests, so driving a store cannot repaint the terminal of
    /// the app the test is running inside.
    private let center: NotificationCenter

    private(set) var customs: [TerminalScheme] = []

    /// The chosen id. `follow-app` until somebody picks something.
    private(set) var selectedID: String = TerminalScheme.followAppID

    init(defaults: UserDefaults = .standard, center: NotificationCenter = .default) {
        self.defaults = defaults
        self.center = center
        load()
    }

    // MARK: - Reading

    /// Everything offerable, built-ins first and then this phone's own, each
    /// group in the order it was declared or made. `follow-app` is *not* in
    /// here — it is not a scheme, and the picker draws it as its own row.
    var schemes: [TerminalScheme] { TerminalScheme.builtIns + customs }

    /**
     * The chosen scheme, or nil when nothing is pinned.
     *
     * Nil is the default and the normal state, not an error: it means
     * `follow-app`, and every reader turns it into a real scheme through
     * `TerminalPalette.resolved`, which needs the appearance to do so and is
     * therefore the only place that can.
     *
     * A stored id naming nothing — a custom deleted on this phone, a built-in a
     * later build removed — also lands here, which is the kind failure: the
     * terminal goes back to following the app rather than painting half a
     * scheme.
     */
    var selected: TerminalScheme? {
        selectedID == TerminalScheme.followAppID ? nil : scheme(id: selectedID)
    }

    /// Whether the terminal is following the phone's light/dark rather than a
    /// pinned scheme. What the picker ticks, and what the note under it says.
    var isFollowingApp: Bool { selected == nil }

    /**
     * The scheme an id names, searching this phone's own copies first.
     *
     * Customs win a collision on purpose — `schemeById`. An id can only collide
     * by being hand-edited to match a built-in, and in that case the one
     * somebody made is the one they meant; a built-in they cannot see past would
     * be a scheme they cannot delete either.
     */
    func scheme(id: String) -> TerminalScheme? {
        customs.first { $0.id == id } ?? TerminalScheme.builtIns.first { $0.id == id }
    }

    /// What a row and the Settings summary call the current choice.
    var selectedName: String { selected?.name ?? "Follow the app" }

    // MARK: - Choosing

    func select(_ id: String) {
        guard id == TerminalScheme.followAppID || scheme(id: id) != nil else { return }
        guard id != selectedID else { return }
        selectedID = id
        defaults.set(id, forKey: Self.selectionKey)
        announce()
    }

    /// Go back to taking the terminal's colours from the phone's light/dark.
    func followApp() { select(TerminalScheme.followAppID) }

    // MARK: - Custom schemes

    /**
     * A copy of `scheme`, saved and returned.
     *
     * This is what "editing a built-in" does, and the copy is made *before* the
     * editor opens rather than sprung as a "this made a duplicate" at the end.
     *
     * Returns nil at the ceiling. Forty of somebody's own schemes is not a
     * limit anybody reaches by using this app; it is there so a stuck finger or
     * a loop cannot fill the defaults file, and the screen says why rather than
     * appearing to do nothing.
     */
    func copying(_ scheme: TerminalScheme) -> TerminalScheme? {
        guard customs.count < TerminalScheme.maxCustomSchemes else { return nil }
        let copy = scheme.copy(taken: schemes.map(\.id))
        customs.append(copy)
        save()
        announce()
        return copy
    }

    /**
     * Write a custom scheme back.
     *
     * Refuses a built-in id outright: a caller that reaches here with one has a
     * bug, and the failure to design for is a picker with two rows called Nord.
     */
    func update(_ scheme: TerminalScheme) {
        guard let index = customs.firstIndex(where: { $0.id == scheme.id }) else { return }
        customs[index] = scheme
        save()
        announce()
    }

    /**
     * Rename one.
     *
     * An empty name is refused rather than stored — `cleanName` returning ""
     * means there was nothing but whitespace — because a nameless row in a
     * picker cannot be told from a bug. The field keeps what was typed; the
     * store keeps the last real name.
     */
    func rename(_ id: String, to name: String) {
        guard var scheme = customs.first(where: { $0.id == id }) else { return }
        let cleaned = TerminalScheme.cleanName(name)
        guard !cleaned.isEmpty, cleaned != scheme.name else { return }
        scheme.name = cleaned
        update(scheme)
    }

    /**
     * Forget a custom scheme.
     *
     * Deleting the one in use goes back to following the app, here rather than
     * in the view so it cannot be reached from a screen that forgot to. Falling
     * through to `selected`'s own nil would paint the right thing but leave a
     * dangling id in the defaults file, which the picker would draw as nothing
     * ticked at all.
     */
    func delete(_ id: String) {
        guard customs.contains(where: { $0.id == id }) else { return }
        customs.removeAll { $0.id == id }
        save()
        if selectedID == id {
            selectedID = TerminalScheme.followAppID
            defaults.set(selectedID, forKey: Self.selectionKey)
        }
        announce()
    }

    // MARK: - Storage

    private func load() {
        if let id = defaults.string(forKey: Self.selectionKey) { selectedID = id }
        guard let data = defaults.data(forKey: Self.customKey),
              let stored = try? JSONDecoder().decode([TerminalScheme].self, from: data) else { return }
        /*
         * Cleaned on the way back out as well as on the way in.
         *
         * A record here was written by this app, but not necessarily by this
         * *build* of it, and on a simulator it can be edited by hand. So: no
         * custom may shadow a shipped id, no name may be empty or longer than a
         * row can draw, and every colour has to be a colour — a scheme with
         * `"red"` in a slot is dropped rather than painted, which is the same
         * cut `isTerminalScheme` makes on the desktop.
         */
        let builtInIDs = Set(TerminalScheme.builtIns.map(\.id))
        customs = stored
            .filter { !builtInIDs.contains($0.id) && $0.id != TerminalScheme.followAppID }
            .filter { scheme in ColourSlot.allCases.allSatisfy { TerminalPalette.isColor(scheme[$0]) } }
            .map { scheme in
                var cleaned = scheme
                let name = TerminalScheme.cleanName(scheme.name)
                cleaned.name = name.isEmpty ? "Untitled" : name
                return cleaned
            }
            .prefix(TerminalScheme.maxCustomSchemes)
            .map { $0 }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(customs) else { return }
        defaults.set(data, forKey: Self.customKey)
    }

    private func announce() {
        center.post(name: .terminalSchemeChanged, object: nil)
    }
}

extension Notification.Name {
    /// The colours changed. Read by `TerminalBridge`, which SwiftUI does not own
    /// and therefore cannot redraw — see this file's header.
    static let terminalSchemeChanged = Notification.Name("terminaldeck.terminalSchemeChanged")
}
