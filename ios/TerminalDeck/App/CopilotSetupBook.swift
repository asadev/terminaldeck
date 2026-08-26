/**
 * The copilot's standing setup, per machine, held on this phone.
 *
 * ## What was asked for
 *
 * Asad, 2026-08-23, looking at the Copilot tab landing on a two-row chooser:
 *
 * > *"when we land on the copilot page there should be directly a new session
 * > started if there is no previous session. No thing, no options to choose
 * > between… Whatever we set in the settings, that copilot will be always on
 * > this folder. We will first of all do the setup of a copilot just like we do
 * > on desktop application, and then it will be always opening in the same
 * > folder. So if there is no session it will start a new session, and if there
 * > is already a previous session going on it will just continue from there."*
 *
 * So there are two facts, and they are the whole of this file: **which folder**
 * the copilot works in, and **whether the tab may start one by itself**. Nothing
 * else. The tab reads them on every visit, and — after the second correction
 * below — it never waits for either of them to be filled in.
 *
 * ## Why this is on the phone and not on the machine
 *
 * The instruction was to prefer `settings.write` — a setting the machine holds
 * is one the desktop and the phone agree about — and that door is shut, twice,
 * on purpose:
 *
 *  - **`SERVER_SETTINGS` is a closed allowlist of two keys.** `protocol.ts`:
 *    `['agents.defaultProvider', 'general.restoreSessions']`, and its own note
 *    says *"a key not in here is unrepresentable on the wire — refused at the
 *    parser, not carried inward."* `ServerSettingKey` is the same two, mirrored.
 *    There is no third key to write and no frame that carries an arbitrary one.
 *  - **The desktop's own copilot folder is `copilot.home`, and it is protected.**
 *    `copilot-folder.ts` puts it under the `copilot.` prefix precisely so that
 *    `PROTECTED_SETTING_PREFIXES` in `deck-control/catalogue.ts` refuses it —
 *    *"an agent that can point itself at a folder is an agent that can choose
 *    its own instructions."* A phone reaching it would be the same hole with a
 *    different caller.
 *
 * That is not a gap to be plugged from this end. The desktop's copilot folder is
 * a fact about the desktop, chosen in its own setup flow, and this phone has no
 * frame for reading it and no business writing it. What this phone *does* decide
 * is what its own Copilot tab does when it opens — which folder to start a
 * session in on a server, and whether to start one at all — and that is a phone
 * fact in the same way `PortBook`'s names are.
 *
 * ## Keyed by host, for `PortBook`'s reason
 *
 * A copilot folder on his rented Linux box is not a copilot folder on his Mac,
 * and a store keyed on nothing would point one machine's copilot at a path that
 * does not exist on the other. The host id is the same stable string everything
 * else in this app keys machines by — see `DeckEndpoint.hostId` — so a machine
 * re-paired after a revoke keeps its setup, in the same way it keeps its
 * nickname and its port names.
 *
 * Not dropped when a machine is forgotten, for the same reason `PortBook` keeps
 * names and `StoredCredential` keeps nicknames: a few dozen bytes of dead text
 * against somebody who unpaired by accident having to walk the folder tree
 * again.
 *
 * ## The folder is **discovered**, not demanded — and that is the second
 * correction
 *
 * There were two rounds of this and the second one deleted a screen. The first
 * put the `.start` case behind a record a finger had made, so a machine nobody
 * had set up drew a two-row chooser instead of starting. Asad, looking at that:
 *
 * > *"the copilot page will directly land into some session — not to a selection
 * > and something on the page… When we go to copilot it should just start the
 * > session; if there is already an existing session it should start from there
 * > where we left, and if not then it should create itself and start from the
 * > beginning. I told the exact same also before."*
 *
 * So **the tab never asks**. A machine with nothing stored here starts one in
 * whatever folder the machine itself would use — a plain `create` with no folder,
 * which `host-core.ts` resolves against the account's own default — and the very
 * next thing that happens is that the folder it landed in is written down here.
 * From then on it is *the* folder, and it is changeable on the control screen.
 *
 * That is what makes an absent record safe to treat as *yes*. The objection to
 * starting without being asked was never the spend on its own; it was a folder
 * **guessed and then silently kept**, so that a machine came to have a copilot
 * somewhere nobody had chosen and nobody could see. Recording what was actually
 * used, immediately, and drawing it on a row with a picker beside it, is the
 * answer to that objection rather than a way around it.
 *
 * So {@link isArmed} reads an absent record as armed, and turning the switch off
 * **writes** — because *off* is no longer the state a machine starts in, and a
 * decision to quieten a tab has to survive being made.
 */

import Foundation
import Observation

/**
 * Deliberately **not** `@MainActor`, for the reason `PortBook` states about
 * itself: nothing here touches UIKit or a socket, every caller is a view already
 * on the main thread, and screens hold it as `var setup: CopilotSetupBook =
 * .shared` — a default argument on a memberwise initialiser, which is evaluated
 * in a non-isolated context and cannot name a main-actor `shared` at all.
 */
@Observable
final class CopilotSetupBook {

    /**
     * The one the screens read.
     *
     * A singleton rather than something threaded through `DeckModel`, because it
     * is a property of *this phone* rather than of a machine — the same shape
     * `PortBook` has, and observable for the same reason: flipping the switch on
     * the control screen has to repaint the row that was flipped and nothing
     * else.
     */
    static let shared = CopilotSetupBook()

    /**
     * The longest path this store will keep.
     *
     * A path comes off the machine through `folders.list` rather than off a
     * keyboard, so this is not input validation — it is a ceiling on what a
     * record written by a hostile or broken far end can cost. `PATH_MAX` is 4096
     * on Linux and 1024 on Darwin; the larger of the two is the honest bound for
     * a store that holds paths from both.
     */
    static let maxFolderLength = 4096

    /**
     * What has been decided about one machine's copilot.
     *
     * Two fields rather than one, because they answer two different questions:
     *
     *  - **folder set, start on** — the ordinary state, and the one every
     *    machine reaches within a second of the tab being opened, whether the
     *    folder was picked or discovered.
     *  - **no folder, start on** — a desktop, whose copilot's folder is chosen at
     *    the desk and is not on this wire; and a server in the moment between the
     *    tab being opened for the first time and the session it started reporting
     *    where it is.
     *  - **start off** — somebody who has quietened the tab, with or without a
     *    folder to come back to. This is the combination that must be *written*
     *    rather than inferred: off is no longer the default, so an unwritten off
     *    would be undone on the next visit.
     *
     * `forget` removes the key rather than writing an empty struct, so the record
     * means *this is what was decided* and its absence means *nothing has been,
     * decide it by doing it* — which is now an instruction rather than a refusal.
     */
    struct Setup: Equatable, Codable {
        /// Where the copilot works on this machine, or nil when this phone has
        /// no say in it. Nil on a desktop is not "unset" — see the type note.
        var folder: String?
        /// Whether the Copilot tab may start one when there is none running.
        var startOnOpen: Bool
        init(folder: String? = nil, startOnOpen: Bool = false) {
            self.folder = folder
            self.startOnOpen = startOnOpen
        }

        /**
         * Written by hand for one key, and it is not ceremony.
         *
         * `load()` decodes the **whole book** in a single `try?`, so one record
         * that will not decode is not one machine lost — it is every machine's
         * folder and switch gone at once, silently, on the launch after an
         * update. Swift's synthesised decoder calls `decode` rather than
         * `decodeIfPresent` for a non-optional property and does not consult its
         * default value, so adding this field without this initialiser would
         * throw on every record written by an earlier build. Measured on the
         * simulator this lane tests against, whose stored book is
         * `{"…":{"folder":"/home/asad","startOnOpen":true}}`.
         */
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            folder = try box.decodeIfPresent(String.self, forKey: .folder)
            startOnOpen = try box.decodeIfPresent(Bool.self, forKey: .startOnOpen) ?? false
        }
    }

    private let defaults: UserDefaults
    private static let storageKey = "terminaldeck.copilotSetup.v1"

    /// host id → what was decided about it. A machine with no key has not been
    /// set up, which is the state every machine starts in.
    private var records: [String: Setup] = [:]

    /// `defaults` is a seam for the tests, which run against their own suite so
    /// a test run cannot re-point the copilot on the machine it runs from.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Reading

    /// What was decided about this machine, or nil if nothing was. Nil is the
    /// only answer that stops the tab starting anything.
    func setup(host: String) -> Setup? {
        records[host]
    }

    /// Whether anything has ever been decided about this machine's copilot.
    ///
    /// No longer a gate on anything the tab does — it starts either way now —
    /// and it is only read by the control screen, to decide whether there is a
    /// setup for *Forget this setup* to undo.
    func isSetUp(host: String) -> Bool {
        records[host] != nil
    }

    /**
     * **Whether the Copilot tab may start one by itself. An absent record means
     * yes.**
     *
     * The default that flipped, and the one line where the second correction
     * actually lives:
     *
     * > *"When we go to copilot it should just start the session… if not then it
     * > should create itself and start from the beginning."*
     *
     * A machine this phone has never opened the Copilot tab on is a machine with
     * no record, and a tab that waited for a finger there would be exactly the
     * *"selection and something on the page"* he is objecting to. The two things
     * that made this safe to default on are both elsewhere and both real: the
     * folder is written down the instant it is known rather than guessed and
     * kept, and the start is one per visit — `CopilotOnServerView.attemptedStart`
     * — so a refusal is a sentence rather than a machine being hammered.
     *
     * Off is therefore a **written** state. See `setStartOnOpen`.
     */
    func isArmed(host: String) -> Bool {
        records[host]?.startOnOpen ?? true
    }

    /// The copilot's folder on this machine, or nil. Nil over a machine that
    /// *has* a record means the folder is not this phone's to choose.
    func folder(host: String) -> String? {
        records[host]?.folder
    }


    // MARK: - Writing

    /**
     * Point this machine's copilot at a folder.
     *
     * Two callers and they mean the same thing by it. The picker on the control
     * screen is somebody choosing; `CopilotOnServerView.adopt()` is the tab
     * writing down the folder the session it just landed in is actually running
     * in. Both are *this is where the copilot works*, and neither is a guess —
     * which is what allows the tab to start before it has been told anything.
     *
     * A machine with no record gets one that is armed, because that is what an
     * absent record already meant. A machine that has been **quietened keeps its
     * quiet**: changing where the copilot works must not silently re-arm a tab
     * somebody switched off, and that asymmetry is the one direction of this
     * that would be the app overruling a decision rather than making one.
     */
    func setFolder(_ raw: String?, host: String) {
        guard !host.isEmpty else { return }
        guard let path = Self.cleanFolder(raw) else { return }
        if var existing = records[host] {
            existing.folder = path
            records[host] = existing
        } else {
            records[host] = Setup(folder: path, startOnOpen: true)
        }
        save()
    }

    /**
     * Arm or disarm the tab for this machine.
     *
     * **Both directions write**, which is the change the flipped default forced.
     * While off was the state a machine began in, writing it would have made
     * *quietened* and *never opened* indistinguishable, so `false` on an absent
     * record was correctly a no-op. Now off is the departure from the default and
     * an unwritten one would be undone by the next visit — which is a switch that
     * springs back, on the one control whose whole job is to stop the tab
     * spending money.
     */
    func setStartOnOpen(_ on: Bool, host: String) {
        guard !host.isEmpty else { return }
        if var existing = records[host] {
            existing.startOnOpen = on
            records[host] = existing
        } else {
            records[host] = Setup(folder: nil, startOnOpen: on)
        }
        save()
    }

    /**
     * Undo everything decided about this machine, so the folder is discovered
     * again on the next visit.
     *
     * It is no longer *"ask me again"* — nothing asks — it is *"work it out
     * again."* Which is a real thing to want: a copilot pinned to a folder that
     * has since been deleted or renamed would start there and fail every time,
     * and one press puts the machine back to letting its own default decide.
     *
     * It also clears the switch, so a forgotten machine is an armed one. That is
     * the honest reading of a row labelled *Forget this setup*: the switch is
     * part of the setup, and a Forget that left a machine quietened would leave
     * a decision behind under a word that promises none.
     */
    func forget(host: String) {
        guard records.removeValue(forKey: host) != nil else { return }
        save()
    }

    /**
     * A folder path as it will be stored, or nil when there is nothing usable.
     *
     * Static and separate from `setFolder` so the rules can be pinned without a
     * store. Three things happen and each removes a way the record can be wrong:
     *
     *  - **Control characters go.** A path is drawn on a row; a newline in one
     *    pushes a card to three lines and shoves the card under it off screen.
     *  - **A relative path is refused.** `create` carries the path to a `spawn`
     *    on the far machine, where a relative one resolves against whatever that
     *    process's cwd happens to be — which is not a folder anybody chose. The
     *    picker only ever produces absolute paths; a record that is not one came
     *    from an older build or from a hand-edited simulator store.
     *  - **A trailing separator goes**, except on the root itself, so that
     *    `/srv/api` and `/srv/api/` are one folder rather than two records that
     *    never match the same session's `cwd`.
     */
    static func cleanFolder(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let stripped = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        let trimmed = String(stripped.trimmingCharacters(in: .whitespaces).prefix(maxFolderLength))
        guard trimmed.first == "/" else { return nil }
        return normalise(trimmed)
    }

    /**
     * One folder path, in the shape two of them can be compared in.
     *
     * Trailing separators only. Not case, and not symlink resolution: the far
     * end is Linux as often as it is macOS, `cwd` comes back from the machine's
     * own `spawn` rather than from this phone, and a comparison that lower-cased
     * would call `/srv/API` and `/srv/api` the same folder on a filesystem where
     * they are two. The one difference that genuinely is cosmetic is the slash
     * the picker leaves on the root of a walk, and that is the one taken out.
     */
    static func normalise(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// Whether two paths name the same folder. One reading of it, so the screen
    /// that draws *the copilot's session* and the rule that decides whether to
    /// start one cannot come to disagree about which folder a session is in.
    static func sameFolder(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return normalise(a) == normalise(b)
    }

    // MARK: - Storage

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode([String: Setup].self, from: data) else { return }
        // Cleaned on the way back out as well as on the way in, for `PortBook`'s
        // reason: the bounds are properties of what a row can draw and what a
        // `create` can carry, and a record written by an older build must not be
        // able to get around them. A record whose folder no longer survives the
        // clean keeps its switch and loses its path, which reads as a desktop —
        // honest, and one press from being right again.
        records = stored.mapValues { Setup(folder: Self.cleanFolder($0.folder),
                                           startOnOpen: $0.startOnOpen) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
