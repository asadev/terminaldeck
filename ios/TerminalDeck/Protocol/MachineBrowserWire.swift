/**
 * **The machine's own browser**, as this phone drives it.
 *
 * ## The distinction this whole file exists to hold
 *
 * The Browser tab already has an address bar, and it is not this. That bar opens
 * a **tunnel**: a port on the machine is bound on this phone's loopback and the
 * page loads in this phone's own `WKWebView`, with this phone's cookies, on this
 * phone's screen. It is the right shape for *looking at what my dev server is
 * serving*, and it is the wrong shape for everything Asad asked for next:
 *
 * > *"in the browser side there are no options like the MacBook or Windows
 * > desktop application to have browser features — like recording the clicks
 * > flow, creating a screenshot and sending it to the session, whatever session
 * > we want to send. And making a browsing session into an isolated or shared
 * > one, and the rest of the things that a browser has in the Mac or desktop
 * > application. And this should be directly synced to the headless one — here
 * > we are just controlling all of these things. We don't have profiles like we
 * > have in the Mac desktop application. We don't have an option to connect any
 * > browsing window to any session, so the session knows which browsing window
 * > it is working on."*
 *
 * Every one of those is about a browser **an agent can also see**. A click flow
 * recorded in this phone's web view is a recording of a page nothing on the
 * machine ever loaded; a screenshot of it is a picture of a phone. Binding one
 * to a session is meaningless, because the session cannot reach it.
 *
 * So this family drives the *machine's* Chromium. The page is on the machine's
 * disk, in the machine's profile, with the machine's cookies — and the phone
 * sends verbs and receives pictures. *"Here we are just controlling all of these
 * things"* is exactly right, and it is the sentence this file is built from.
 *
 * ## It is the same on a server, which was the point
 *
 * A headless host has had a real Chromium since wave 2 —
 * `src/main/browser-headless-host.ts` launches it and
 * `browser-headless-control.ts` drives it — and
 * `src/headless/session-drives-server-browser.test.ts` proves a session running
 * *on the server* reaches it. So nothing here is desktop-only, which is what
 * *"directly synced to the headless one"* asks for. The capability is negotiated
 * per host in the ordinary way and the screen is the same on both.
 *
 * ## The binding is the headline, and it is not new
 *
 * *"We don't have an option to connect any browsing window to any session, so
 * the session knows which browsing window it is working on."* The desktop has
 * had this since `src/main/browser-binding.ts`: a window bound to a session gets
 * a slot name — `B1`, `B2` — and the session's tools address it by that name.
 * Nothing about it was invented for the phone; what the phone lacked was a way
 * to press it. `slot` on `MachineWindow` is that name, and it is nil for a
 * window no session owns.
 *
 * ## Every verb answers with the list
 *
 * The same rule the panels follow, and for the same reason: the screen
 * redrawing is the confirmation. Bind a window and it comes back carrying `B1`;
 * close one and it is gone from the list. There is no outcome to reconcile and
 * no second state for a client to get wrong.
 *
 * Two exceptions, both because they carry a payload of their own:
 * `browser.shot` returns a picture, and `browser.record.rows` returns the steps.
 * A screenshot sent **to a session** is not one of them — it answers with the
 * list and a notice, because the picture went somewhere else.
 */

import Foundation

enum MachineBrowserWire {
    /// `CAPABILITY.browserControl` on the host. Owner devices only — a bound
    /// window can be told to navigate anywhere and photographed, and its output
    /// is handed to a session that is running commands.
    static let capability = "browser.control"

    /**
     * The most windows this client will draw.
     *
     * Not a limit on the machine: Chromium will hold far more, and the binding
     * store has its own idea of how many slots a session may own. This is the
     * point past which a strip of windows on a phone stops being something you
     * scan. The host sends what it has; anything past this is not drawn and the
     * screen says how many it left out, because a silent cut reads as *that is
     * all of them*.
     */
    static let maxWindows = 40

    /**
     * The most recorded steps this client will draw at once.
     *
     * A click flow on a busy page collects a step per interaction and the host
     * caps its own side; this is the second bound, and it exists because the
     * decode happens on the main actor. Truncation is reported by the host in
     * the frame, not inferred from hitting this number.
     */
    static let maxSteps = 500

    /**
     * How many ancestors one `browser.window.pick` may ask to walk up.
     *
     * `MAX_PICK_UP` in `src/main/remote/protocol.ts`, and the reason it is
     * mirrored here rather than left to the host is that the host's answer to an
     * out-of-range one is **not a refusal, it is a closed socket**: that check
     * lives in the *parser*, and `server.ts` answers a parse failure by dropping
     * the connection. So Wider clamps on this side and never sends past it. A
     * phone that walked past 64 would take somebody's whole session down —
     * terminals, cast and all — because they pressed one button once too often.
     *
     * The page-side walk has its own ceiling at the same number
     * (`MAX_PICK_ANCESTORS` in `browser-drive-script.ts`), which is what stops a
     * hostile document lengthening the loop; `browser-driver.test.ts` asserts the
     * two agree over there. This is the third copy and it is the one that keeps
     * the socket open.
     */
    static let maxPickUp = 64

    /// The host's own caps on a `browser.window.picked`, mirrored so this end
    /// clamps to the same lengths rather than to numbers of its own — an element
    /// described one way on the desktop and another on the phone is the defect
    /// item V9 is about. `MAX_PICK_SELECTOR`, `MAX_PICK_WORD`, `MAX_ROW_TEXT`
    /// and `MAX_ROW_URL` in `src/main/remote/browser-control.ts`.
    static let maxPickSelector = 400
    static let maxPickWord = 64
    static let maxPickLabel = 160
    static let maxPickURL = 512

    /**
     * The words `browser.window.picked` uses for where a label came from.
     *
     * `PICK_LABEL_SOURCES` in `src/main/remote/protocol.ts`. Held here as a list
     * rather than as an enum **on purpose**, and this file is the wrong place to
     * turn it into one: the client's instruction is to draw an unfamiliar word as
     * it stands rather than refuse the frame, and an enum with no default case is
     * exactly the shape that cannot. It is kept at all so a test can say out loud
     * which words this build has seen — not so anything can reject the others.
     */
    static let labelSources = [
        "text", "label", "aria-label", "placeholder", "title", "name", "alt", "value", "none",
    ]

    /// The verbs `browser.window.act` accepts. Mirrors `WINDOW_ACTIONS` in
    /// `src/main/remote/protocol.ts`, which is a **closed** list there — unlike
    /// a panel's actions, these are not declared by the host per answer, so a
    /// word this build sends that that one does not know is a refused frame.
    enum Act: String, CaseIterable {
        case back
        case forward
        case reload
        case close
        case recordOn = "record.on"
        case recordOff = "record.off"
        case share
        case isolate
    }
}

/**
 * One window open in the machine's browser.
 *
 * A port of `MachineWindow` in `src/main/remote/protocol.ts`. Every optional
 * here is a real absence rather than a default waiting to be filled in: a window
 * with no `slot` is one no session owns, a window with no `profile` is one on
 * the machine's default partition, and `isolated` false is the ordinary shared
 * case rather than an unknown.
 */
struct MachineWindow: Equatable, Hashable, Identifiable {
    let id: String
    let title: String
    let url: String
    /// `B1`, `B2` — the name the binding store gave it. Nil when unbound.
    let slot: String?
    /// The session that owns it, when one does.
    let session: String?
    let sessionTitle: String?
    let profile: String?
    /// A partition of its own, thrown away when the window closes.
    let isolated: Bool
    /// Whether the click flow is being recorded on this window right now.
    let recording: Bool
    let loading: Bool

    init(id: String, title: String, url: String, slot: String? = nil,
         session: String? = nil, sessionTitle: String? = nil, profile: String? = nil,
         isolated: Bool = false, recording: Bool = false, loading: Bool = false) {
        self.id = id
        self.title = title
        self.url = url
        self.slot = slot
        self.session = session
        self.sessionTitle = sessionTitle
        self.profile = profile
        self.isolated = isolated
        self.recording = recording
        self.loading = loading
    }

    /**
     * What the row calls it.
     *
     * The page's own title once it has one, and the address until then — the
     * same rule `LocalhostBrowser` follows for its navigation title, and for the
     * same reason: *"Untitled"* tells nobody which of their windows they are
     * looking at, and a machine with four of them open is exactly when it
     * matters.
     */
    var label: String { title.isEmpty ? url : title }

    /// Whether a session owns it. Reads better than `slot != nil` at the call
    /// sites, all of which are asking the question rather than using the name.
    var isBound: Bool { slot != nil }
}

/**
 * A session a window could be bound to.
 *
 * `windows` is how many that session already holds, and it is on the row for a
 * specific reason: the binding store hands a session's tools its windows **by
 * slot name**, so a session that already owns three is one where the next
 * binding becomes `B4` rather than `B1`. Somebody choosing where to attach a
 * window is choosing what that agent will call it.
 */
struct WindowSession: Equatable, Hashable, Identifiable {
    let id: String
    let title: String
    let windows: Int
}

/// One step the recorder collected. A flat shape on purpose: the desktop's
/// recorder produces a richer structure, and everything past these five fields
/// is either a selector nobody reads on a phone or a payload that belongs in the
/// session the flow is being written for.
struct RecordedStep: Equatable, Hashable, Identifiable {
    let at: Double
    let kind: String
    let detail: String?
    let selector: String?
    let value: String?
    let index: Int

    var id: Int { index }
}

/// Everything `browser.window.rows` carries.
struct MachineBrowserState: Equatable, Hashable {
    let windows: [MachineWindow]
    let sessions: [WindowSession]
    /// What just happened. Set by a verb, cleared by the next plain list.
    let notice: String?
    /**
     * How many the machine sent, before this client's own cap.
     *
     * Kept because the two caps are independent and only one of them is on the
     * wire: the host trims to its own ceiling and says so in the notice, and
     * `maxWindows` trims again here. Without this number the screen could only
     * infer truncation from *landing exactly on the cap*, which over-reports by
     * one frame at exactly forty and says "the first 40" about a list that is
     * all of them. A count is one integer and removes the guess.
     */
    let sent: Int

    init(windows: [MachineWindow] = [], sessions: [WindowSession] = [],
         notice: String? = nil, sent: Int? = nil) {
        self.windows = windows
        self.sessions = sessions
        self.notice = notice
        self.sent = sent ?? windows.count
    }

    /// How many the machine had that this screen is not drawing. Zero is the
    /// ordinary case and the screen says nothing about it.
    var notDrawn: Int { max(0, sent - windows.count) }
}

/**
 * Where a picked element sits, in the page's **own** coordinates.
 *
 * A port of `PickedRect` in `src/main/remote/protocol.ts`, down to the short
 * field names: `w`/`h` rather than `width`/`height`, to match the geometry
 * `browser.frame` already carries.
 *
 * Document coordinates, not viewport ones, and that is the whole usefulness of
 * it: a viewer draws this over the **next** frame it receives by subtracting
 * that frame's scroll, so an outline stays on the thing it names while the page
 * moves under it. A viewport rectangle would slide off the element the moment
 * anybody scrolled.
 */
struct PickedRect: Equatable, Hashable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

/// A picture of one window, and when it was taken. `png` is the raw bytes,
/// already decoded from the base64 the wire carries — a screen that held the
/// string would decode it again on every redraw.
struct MachineShot: Equatable, Hashable {
    let id: String
    let png: Data
    let at: Double
}

// MARK: - Decoding

extension WireCodec {
    /// `browser.window.rows`.
    static func machineWindows(_ object: [String: Any]) -> MachineBrowserState {
        let windows = (object["windows"] as? [Any] ?? [])
            .prefix(MachineBrowserWire.maxWindows)
            .compactMap { raw -> MachineWindow? in
                guard let e = raw as? [String: Any], let id = string(e["id"]) else { return nil }
                return MachineWindow(id: id,
                                     title: string(e["title"]) ?? "",
                                     url: string(e["url"]) ?? "",
                                     slot: string(e["slot"]),
                                     session: string(e["session"]),
                                     sessionTitle: string(e["sessionTitle"]),
                                     profile: string(e["profile"]),
                                     isolated: e["isolated"] as? Bool ?? false,
                                     // `recording` is the red dot on the row and
                                     // the one flag here that is a safety state
                                     // rather than a description, so it is read
                                     // the way `masked` is: on unless the host
                                     // said, in a real boolean, that it is off.
                                     // Absent stays off — most windows are not
                                     // being recorded and a host without the
                                     // feature says nothing — but anything
                                     // present that is not literally `false`
                                     // shows the dot. Saying "not recording"
                                     // over a window that is, is the one mistake
                                     // on this row that costs somebody
                                     // something. `isolated` and `loading`
                                     // describe a window and stay lenient.
                                     recording: e["recording"] != nil
                                         && !literalFalse(e["recording"]),
                                     loading: e["loading"] as? Bool ?? false)
            }
        let sessions = (object["sessions"] as? [Any] ?? []).compactMap { raw -> WindowSession? in
            guard let e = raw as? [String: Any], let id = string(e["id"]) else { return nil }
            return WindowSession(id: id,
                                 title: string(e["title"]) ?? id,
                                 windows: e["windows"] as? Int ?? 0)
        }
        return MachineBrowserState(windows: Array(windows),
                                   sessions: sessions,
                                   notice: string(object["notice"]),
                                   sent: (object["windows"] as? [Any])?.count)
    }

    /**
     * `browser.window.picked` — one element on a machine window's page.
     *
     * Nil when the frame names no window or describes no element: an answer with
     * no `id` cannot be matched to the screen that asked, and one with no
     * `selector` is not something anything can be told to change. Both are
     * dropped rather than drawn as a sheet with blanks in it.
     *
     * ## Everything here is sanitised again on this side
     *
     * The host trims these to its own lengths already, and that is **not** the
     * same job. This line is about to be typed into a PTY running a coding agent
     * — one newline in it submits the prompt early and an ESC repaints the
     * terminal it lands in — and `Inspect.sanitizeLine` is the function that
     * makes a string safe for that, on both clients, by the same rules. A host
     * that trims to 400 characters has said nothing about control characters.
     *
     * It is also the boundary where a page's own words stop being the page's.
     * `label` comes from a document the machine loaded; bidi overrides in it
     * would render text as something other than what it says, on a screen
     * somebody is reading to decide what to tell an agent to do.
     *
     * ## `labelSource` is not narrowed
     *
     * Passed through as the word it is. See `MachineBrowserWire.labelSources`:
     * the wire's rule is that a client draws an unfamiliar source as it stands,
     * and the two words this phone's own inspector can never produce (`name`,
     * `label`) are ordinary answers from a form field.
     */
    static func pickedElement(_ object: [String: Any]) -> (id: String, element: InspectedElement)? {
        guard let id = string(object["id"]), !id.isEmpty else { return nil }
        let selector = Inspect.sanitizeLine(object["selector"], max: MachineBrowserWire.maxPickSelector)
        guard !selector.isEmpty else { return nil }

        let element = InspectedElement(
            tag: Inspect.sanitizeLine(object["tag"], max: MachineBrowserWire.maxPickWord),
            selector: selector,
            label: Inspect.sanitizeLine(object["label"], max: MachineBrowserWire.maxPickLabel),
            labelSource: Inspect.sanitizeLine(object["labelSource"], max: MachineBrowserWire.maxPickWord),
            url: Inspect.sanitizeLine(object["url"], max: MachineBrowserWire.maxPickURL),
            // Negative or missing reads as zero rather than as a refusal. `depth`
            // greys Narrower and `maxUp` greys Wider, and the safe direction for
            // both is the one that offers less: a control that is dead when it
            // could have worked is a nuisance, and one that is live over nothing
            // sends a frame the host answers with a sentence.
            depth: max(0, whole(object["depth"]) ?? 0),
            maxUp: max(0, whole(object["maxUp"]) ?? 0),
            rect: pickedRect(object["rect"]))
        return (id, element)
    }

    /// The element's box, or nil where the host sent none. Every field has to be
    /// a real finite number: a rectangle with a `NaN` in it is not a rectangle,
    /// and a half-read one would put an outline in the wrong place rather than
    /// nowhere.
    private static func pickedRect(_ raw: Any?) -> PickedRect? {
        guard let object = raw as? [String: Any],
              let x = number(object["x"]), let y = number(object["y"]),
              let w = number(object["w"]), let h = number(object["h"]) else { return nil }
        return PickedRect(x: x, y: y, w: w, h: h)
    }

    /**
     * `browser.record.rows`.
     *
     * A step with no `kind` is dropped rather than drawn as a blank line: the
     * kind is the only field that is always meaningful — *click*, *type*,
     * *navigate* — and a row without it is a row that says nothing.
     */
    static func recordedSteps(_ object: [String: Any]) -> [RecordedStep] {
        (object["steps"] as? [Any] ?? [])
            .prefix(MachineBrowserWire.maxSteps)
            .enumerated()
            .compactMap { pair -> RecordedStep? in
                guard let e = pair.element as? [String: Any], let kind = string(e["kind"]) else { return nil }
                return RecordedStep(at: e["at"] as? Double ?? 0,
                                    kind: kind,
                                    detail: string(e["detail"]),
                                    selector: string(e["selector"]),
                                    value: string(e["value"]),
                                    index: pair.offset)
            }
    }
}
