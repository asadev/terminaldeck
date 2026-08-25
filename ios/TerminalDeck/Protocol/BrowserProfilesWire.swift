/**
 * The **machine's** browser profiles, as this phone reads them.
 *
 * A port of `BrowserProfile` and `ProfileState` from
 * `src/main/browser-profiles.ts`, and of the two pure functions the desktop
 * draws a row from — `cleanAvatar` and `profileInitial` in
 * `src/renderer/browser/profile-badge.ts`. Nothing here invents a model: the
 * desktop has had one since it grew the flyout, and this is the narrowing that
 * turns its answer into something a phone can draw.
 *
 * ## Why it crosses the wire at all
 *
 * Asad, on the phone's browser against the desktop's:
 *
 * > *"we have a lot of things in the browser on the desktop side — we have
 * > profile, password, cookies, everything and a lot of other features. So it
 * > should be all same, because it is just linking this to the server side.
 * > Whatever cannot be linked, it can be only here also."*
 *
 * That sentence is a split, and this file is the half that **can** be linked. A
 * profile is not a preference somebody set on a phone: it is a
 * `persist:` **session partition** on the machine — a directory under that
 * machine's `<userData>/Partitions/`, holding its own cookie jar,
 * `localStorage`, IndexedDB, cache and service workers. It exists on one
 * computer, it survives that computer's restarts, and no phone can hold a copy
 * of it. So the phone does not store profiles; it asks, and it acts.
 *
 * The other half — what this phone saves for itself — is native and per
 * machine, keyed the way `PortBook` and `BrowserHistory` key theirs. Nothing in
 * this file touches it.
 *
 * ## What the wire carries, and what it deliberately does not
 *
 * Three verbs and one answer:
 *
 * ```
 * client→host  { t: 'browser.profiles' }
 * client→host  { t: 'browser.profile.use',   id }
 * client→host  { t: 'browser.profile.clear', id }
 * host→client  { t: 'browser.profile.rows',  current, profiles: [...] }
 * ```
 *
 * **Read, switch, clear.** There is no create, no rename, no avatar and no
 * delete, and that is a decision rather than a first instalment. The desktop
 * offers all four from `ProfileSettings.tsx`, and every one of them either needs
 * a field and a grid on a screen a thumb is holding, or destroys a whole cookie
 * jar with every login in it on a machine the person cannot see. Switching and
 * clearing are the two acts that are worth doing from a sofa, and both are
 * answerable in a tap.
 *
 * `browser.profile.use` and `browser.profile.clear` both answer with a fresh
 * `browser.profile.rows` rather than with an outcome of their own. That is what
 * makes the screen the confirmation: a switched profile physically moves to the
 * top of the list, and a cleared one comes back with its counts gone. There is
 * nothing for a client to reconcile and nothing for it to get wrong.
 *
 * ## Owner devices only
 *
 * The capability is advertised to one of the owner's own devices and withheld
 * from a guest at the source — the same call `web`, `watch` and `devices` make,
 * and for the stronger of their two reasons: a profile *is* somebody's signed-in
 * cookie jar, and clearing one signs their machine out of everything in it.
 * A client that sees `browser.profiles` in the welcome is both able to switch
 * and entitled to.
 *
 * ## What a switch actually does, over there
 *
 * A `WebContents`' session is fixed when it is constructed and cannot be
 * swapped afterwards — the physics `browser-tab.ts` writes down for its Isolated
 * toggle, and profiles inherit it rather than inventing a second story. So a
 * switch decides which jar the **next** page opens into. On the phone that is
 * not an abstraction: `web.open` is routed through `openAppLink` into the
 * desktop's own tabs (see `openUrl` in `src/main/index.ts` — *"a browser started
 * from the phone must run on the machine you are inside"*), and every new tab
 * takes `activeProfileSession()`. The profile chosen here is the jar the next
 * page this phone opens over there lands in.
 *
 * It is **not** the jar a tunnelled page lands in. `LocalhostBrowser` is a
 * `WKWebView` on this phone over a `PortTunnel`; its cookies are this phone's,
 * on `WKWebsiteDataStore.default()`, and `BrowserDataView` is where they are
 * cleared. Two machines, two jars, and a screen that blurred them would offer to
 * sign somebody out of the wrong one.
 *
 * Kept free of SwiftUI so the whole wire layer stays testable without a
 * simulator, like every other file in this folder.
 */

import Foundation

/// The constants this family is bounded by, and the two the desktop already
/// owns. Repeated rather than trusted, for the reason every other bound in
/// `Wire` is repeated: a cap enforced only by the other end is not a cap.
enum MachineProfilesWire {

    /**
     * The capability name, spelled once.
     *
     * `WireCapability.browserProfiles` is an alias of this, the same way
     * `WireCapability.copilot` aliases `Copilot.capability`: every capability in
     * the product stays readable off one type, while the name lives beside the
     * family it names so the two cannot drift apart.
     */
    static let capability = "browser.profiles"

    /// The id of the profile whose partition predates the feature. Never minted
    /// by the machine, and the fallback this client resolves a dangling
    /// `current` back to — `DEFAULT_PROFILE_ID` in `browser-profiles.ts`.
    static let defaultProfileID = "default"

    /// The partition every tab in every build before profiles existed used, and
    /// therefore the one holding the logins somebody already has. Carried for
    /// what it says; nothing on the phone opens a partition.
    static let defaultPartition = "persist:terminaldeck-browser"

    /// Every other profile's partition is this plus its id.
    static let partitionPrefix = "persist:terminaldeck-browser-"

    /// The most profiles this client will draw off one frame. The desktop caps
    /// nothing — a person makes three of these, not three hundred — so this is
    /// the backstop that keeps a malformed or hostile frame from becoming a list
    /// a phone cannot scroll out of.
    static let maxProfiles = 100

    /// The longest id this client will send back. A UUID is 36; the slack is for
    /// a machine that mints them another way. An id is not display text, so it
    /// is bounded rather than cleaned — see `machineProfile`.
    static let maxIDLength = 128
}

/**
 * One profile on the machine.
 *
 * Identified by its **id**, which is what `browser.profile.use` and
 * `browser.profile.clear` name. Never by its name: two profiles can be called
 * the same thing, and the desktop does not stop somebody doing it.
 *
 * ## `partition` is carried and drawn nowhere
 *
 * It is the string the machine hands `session.fromPartition` — a directory name
 * on somebody else's computer, meaningless on a phone, and the desktop itself
 * says *"shown nowhere; used by every other module"*. It is carried because it
 * is the whole substance of the claim this screen makes — that two profiles are
 * two separate cookie jars rather than two labels — and a value type that
 * dropped it would have to grow it back the first time anything wanted to tell
 * one jar from another. `GitNotRepo.canInit` is carried on the same terms: for
 * what it says, not for a control.
 *
 * ## `sites` and `cookies` are optional and stay optional
 *
 * The frame shipping today carries neither. A machine that counts its own jars
 * may send them, and a row then says what it holds; a machine that does not
 * sends a row that is a name, exactly as it is now. **Neither is ever drawn as a
 * zero** — the rule `ProfileMenu.tsx` states out loud, *"no count is ever
 * printed as a zero … a number that exists to stop a row looking empty"* — so
 * absent and none read the same on screen, which is the honest pair.
 */
struct MachineBrowserProfile: Equatable, Identifiable, Hashable {

    /// The value sent back, kept byte-for-byte. Bounded and refused for control
    /// characters, never cleaned — see `WireCodec.machineProfile`.
    let id: String

    /// Display text somebody typed on the machine, cleaned and bounded on the
    /// way in like every other string from another computer.
    let name: String

    /// The one character the badge draws, or `""` for the name's initial. Empty
    /// is not *unset waiting to be filled in*: it is the badge the desktop has
    /// always drawn, and it stays the default so a profile nobody customised
    /// looks here exactly as it looks there.
    let avatar: String

    /// The Electron partition string, or nil for a machine that did not say.
    /// Drawn nowhere — see the type's own note.
    let partition: String?

    /// Whether the machine's browser is using this one. Filled in from the
    /// frame's `current`, which sits beside the list rather than on the rows —
    /// see `marking(current:)`.
    let isCurrent: Bool

    /// How many sites have data in this profile's jar, where the machine counts
    /// them. Nil is *not counted*, and reads the same as none.
    let sites: Int?

    /// How many cookies are in it, on the same terms.
    let cookies: Int?

    /// The one profile that cannot be deleted on the machine, and the one
    /// holding every login from before profiles existed. It can still be
    /// cleared, which is why this is a fact a confirmation reads rather than a
    /// control that is hidden.
    var isDefault: Bool { id == MachineProfilesWire.defaultProfileID }

    /// The character the badge draws for this profile. Here rather than in a
    /// view so a list and a card cannot disagree about one profile's badge.
    var badge: String { MachineProfileText.initial(name: name, avatar: avatar) }

    /**
     * The same profile with the tick set.
     *
     * The frame carries `current` beside the list rather than on each row, so
     * the flag can only be filled in once the rows are decoded *and* the id has
     * been resolved against them. Rebuilding the value is how it stays a `let`:
     * there is no path here that can flip a row's tick after the fact, which is
     * the property that stops two rows claiming to be current at once.
     */
    func marking(current: Bool) -> MachineBrowserProfile {
        MachineBrowserProfile(id: id, name: name, avatar: avatar, partition: partition,
                              isCurrent: current, sites: sites, cookies: cookies)
    }
}

/**
 * A whole `browser.profile.rows` — the machine's profiles and which one it is
 * using.
 *
 * `current` is **resolved** rather than echoed: the decoder pulls it back to a
 * profile that is actually in the list, which is the same repair
 * `readProfileState` performs on the machine when it reads its own file. A
 * dangling id would draw a screen where nothing is in use and nothing explains
 * why, and it is the one state a person cannot act their way out of.
 */
struct MachineProfileList: Equatable, Hashable {
    let current: String
    let profiles: [MachineBrowserProfile]

    /// The profile the machine's browser is using, or nil for an empty list.
    var currentProfile: MachineBrowserProfile? { profiles.first { $0.id == current } }

    /// Everything else, in the machine's own order — which is creation order,
    /// with the default first. Not sorted here: the list a person made is the
    /// list they remember.
    var others: [MachineBrowserProfile] { profiles.filter { $0.id != current } }

    var isEmpty: Bool { profiles.isEmpty }
}

// MARK: - The sentences a row is drawn from

/**
 * The pure text, here rather than in a view — the split `DeviceRosterText`
 * makes, and for the same reason: these are the lines the screen is judged on
 * and they are testable without a simulator.
 */
enum MachineProfileText {

    /**
     * The character a profile is badged with: its own if it has one, otherwise
     * the first character of its name, uppercased — or nothing.
     *
     * A port of `profileInitial`. Nothing, and not a `?`, for the empty name:
     * the list arrives asynchronously and a badge that fills in is a circle that
     * settles rather than a question mark that flickers into a letter.
     *
     * A chosen avatar is **not** uppercased. It was picked deliberately, and
     * `'ß'.uppercased()` is `"SS"` — two characters in a circle sized for one.
     *
     * Split by `Character` rather than by unicode scalar, which is where this
     * improves on the original: Swift's `Character` is a grapheme cluster, so a
     * flag, a skin-toned hand or a family emoji comes back whole instead of as
     * its first scalar. JavaScript's `[...string][0]` splits those apart. The
     * uppercasing then takes the first character *of its result*, so a name
     * beginning with `ß` badges as `S` rather than widening the circle.
     */
    static func initial(name: String, avatar: String = "") -> String {
        let chosen = avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        if let glyph = chosen.first { return String(glyph) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        let upper = String(first).uppercased()
        return String(upper.first ?? first)
    }

    /**
     * What a profile holds, where the machine counted it — `12 sites · 340
     * cookies`, or one half of that, or nothing at all.
     *
     * Nothing at all covers both *not counted* and *none*, and collapsing them
     * is the point rather than a shortcut: *"no count is ever printed as a
     * zero"*. A row with nothing to say is a name, which is what every row on
     * the desktop's own menu is until its jar has something in it.
     */
    static func holds(_ profile: MachineBrowserProfile) -> String? {
        var parts: [String] = []
        if let sites = profile.sites, sites > 0 {
            parts.append("\(sites) \(sites == 1 ? "site" : "sites")")
        }
        if let cookies = profile.cookies, cookies > 0 {
            parts.append("\(cookies) \(cookies == 1 ? "cookie" : "cookies")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /**
     * What clearing this profile will do, named in consequences.
     *
     * The one place in this family allowed to be a sentence, for the reason
     * `BrowserDataView` states about its own: a confirmation is the last thing
     * between a person and losing a session, and it is read. *"Signs it out"* is
     * what happens; *"clears cookies and storage"* is what the code does.
     *
     * Three cases, because they are three different losses. The profile in use
     * is the one whose pages are open right now. The default profile holds every
     * login from before the machine had profiles at all — the desktop refuses to
     * *delete* it for exactly that reason, and clearing it empties it just the
     * same. Anything else is an ordinary jar.
     */
    static func clearing(_ profile: MachineBrowserProfile, machine: String) -> String {
        if profile.isCurrent {
            return "Signs \(machine)’s browser out of everything in \(profile.name) — "
                + "the profile it is using right now."
        }
        if profile.isDefault {
            return "Signs \(machine)’s browser out of everything in \(profile.name), "
                + "including logins from before it had profiles."
        }
        return "Signs \(machine)’s browser out of everything in \(profile.name)."
    }
}

// MARK: - Narrowing

extension WireCodec {

    /**
     * One profile row, or nil.
     *
     * `id` is the only required field and it is taken **verbatim**: it is not
     * display text, it is the value `browser.profile.use` sends back, and
     * stripping a byte out of it would turn one profile into a different
     * legal-looking one. So it is *refused* for a control character rather than
     * cleaned — the rule `fileRow` keeps about a path, for the same reason.
     *
     * It is deliberately **not** checked against the shape of a UUID, even
     * though `partitionFor` on the machine accepts only that or the literal
     * `default`. The shape belongs to whichever machine minted it, that machine
     * checks it again on the way back in, and refusing an unfamiliar one here
     * would hide a profile a newer desktop could switch to perfectly well —
     * hiding a row is the failure a person cannot see, while a refused `use` is
     * one the machine says out loud.
     *
     * The name falls back the way `readProfileState` falls back — `Default` for
     * the default id, `Profile` for anything else — rather than dropping the
     * row. Unlike a panel row, this one *does* something: a jar that can be
     * switched to and cleared is worth drawing under a placeholder name, and it
     * is what the machine would have called it anyway.
     *
     * `isCurrent` is false here always. It cannot be known from a row — the
     * frame carries `current` beside the list — and it is filled in by
     * `machineProfileList` once the id has been resolved against the rows that
     * survived.
     */
    static func machineProfile(_ value: Any?) -> MachineBrowserProfile? {
        guard let row = value as? [String: Any],
              let id = string(row["id"]), !id.isEmpty,
              id.count <= MachineProfilesWire.maxIDLength,
              !id.unicodeScalars.contains(where: { $0.value <= 0x1f || $0.value == 0x7f })
        else { return nil }
        let fallback = id == MachineProfilesWire.defaultProfileID ? "Default" : "Profile"
        return MachineBrowserProfile(
            id: id,
            name: displayLine(row["name"]) ?? fallback,
            avatar: profileAvatar(row["avatar"]),
            // Bounded, not cleaned, and nil rather than empty: it is an
            // identifier on another machine's disk, and an empty one says
            // nothing that a missing one does not.
            partition: string(row["partition"]).flatMap {
                $0.isEmpty ? nil : String($0.prefix(MachineProfilesWire.maxIDLength))
            },
            isCurrent: false,
            sites: profileCount(row["sites"]),
            cookies: profileCount(row["cookies"]))
    }

    /**
     * A whole `browser.profile.rows` frame.
     *
     * Never nil, and that is the shape this one wants: a machine with no
     * profiles is not a malformed frame, and every field on it has an honest
     * absence. One malformed row is dropped rather than discarding the answer —
     * the rule `WireCodec` already follows for a session list, and it matters
     * more here, because the row most likely to be malformed is not the row
     * somebody is looking for.
     *
     * `current` is resolved in three steps, which is `readProfileState`'s own
     * repair: the id the machine named if a row still carries it, else the
     * default profile if it is in the list, else the first row. The last step is
     * this client's and not the machine's — a list whose default row was dropped
     * by the line above would otherwise draw with nothing in use, and one row
     * ticked wrongly is a smaller lie than a screen that says the machine's
     * browser is using no profile at all.
     */
    static func machineProfileList(_ object: [String: Any]) -> MachineProfileList {
        let rows = (object["profiles"] as? [Any] ?? [])
            .prefix(MachineProfilesWire.maxProfiles)
            .compactMap { machineProfile($0) }

        let wanted = string(object["current"]) ?? MachineProfilesWire.defaultProfileID
        let current: String
        if rows.contains(where: { $0.id == wanted }) {
            current = wanted
        } else if rows.contains(where: { $0.isDefault }) {
            current = MachineProfilesWire.defaultProfileID
        } else {
            current = rows.first?.id ?? ""
        }

        return MachineProfileList(current: current,
                                  profiles: rows.map { $0.marking(current: $0.id == current) })
    }

    /**
     * One character for a badge, or `""`. A port of `cleanAvatar`.
     *
     * Control characters and whitespace collapse to `""`, which is the same
     * answer as *no avatar* and lands the badge back on the name's initial
     * rather than on an empty circle. One `Character` and not a string: the
     * badge is a 24-point circle, and the second character of a two-character
     * "avatar" would be drawn outside it or not at all.
     */
    static func profileAvatar(_ value: Any?) -> String {
        guard let raw = string(value) else { return "" }
        let stripped = String(raw.unicodeScalars.filter { scalar in
            !(scalar.value <= 0x1f || (scalar.value >= 0x7f && scalar.value <= 0x9f))
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let glyph = stripped.first else { return "" }
        return String(glyph)
    }

    /// A count off a profile row: a whole number that is not negative, or nil.
    /// Nil and zero mean the same thing to every reader of this — see
    /// `MachineProfileText.holds` — so a negative is folded into nil rather than
    /// clamped to zero, which would be a count this client invented.
    static func profileCount(_ value: Any?) -> Int? {
        whole(value).flatMap { $0 >= 0 ? $0 : nil }
    }
}
