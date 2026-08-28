/**
 * One machine, and everything this phone knows about it.
 *
 * This is the object that used to *be* `DeckModel`. Splitting it out is the whole
 * of multi-host: the relay has always been a map of host ids and the protocol has
 * never had an opinion about what a host is — a phone genuinely cannot tell a Mac
 * from a Windows PC, because nothing on the wire says — so the only thing that
 * was ever single was the phone's own storage and the phone's own state. There is
 * now one of these per paired machine, and `DeckModel` holds the collection.
 *
 * ## What is *not* shared between hosts, and why that is free
 *
 * Everything below the transport. Each link owns its own `LiveTransport`, which
 * owns its own `Carrier`, which for a relay endpoint runs its own Noise IK
 * handshake against that host's static key. Two machines therefore cannot read
 * each other's sessions even though the same phone is talking to both: the keys
 * were never in the same place to begin with. That isolation costs nothing to
 * keep and would have to be deliberately dismantled to lose, which is why this
 * type has no notion of a "shared" anything.
 *
 * What *is* shared is the phone's static identity — one key, so a machine that
 * has approved this phone once has approved this phone — and the heartbeat tick,
 * so N sockets cost one radio wake-up rather than N. See `Heartbeat`.
 *
 * ## Wanted, and attached
 *
 * Two different things, and conflating them is why the first version of this app
 * came back from a dropped connection showing a dead terminal. `wanted` is what
 * the user has open. `attached` is what the host has confirmed. A reconnect
 * clears the second and not the first, and the gap between them is exactly the
 * set of `attach` frames to send when the socket comes back.
 */

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class HostLink: Identifiable {

    /// Which machine this is. Stable across re-pairings, and the key everything
    /// above this object uses to name it.
    let id: String

    /// What this phone holds about the machine. Replaced in place when the host
    /// mints a durable credential or the user renames it.
    private(set) var credential: StoredCredential

    private(set) var connection: ConnectionState = .offline

    /**
     * Whether this machine's connection is worth putting on screen, which is not
     * the same question as what its connection *is*.
     *
     * `ConnectionGrace` holds the whole rule and says why. What matters here is
     * that it lives on the machine rather than on a screen: a link that has been
     * down for a minute must not get a fresh five seconds of silence every time
     * somebody navigates back to the list, and the pill, the list's banner and a
     * terminal's banner must not each have their own opinion about whether now
     * is the moment to say something.
     */
    let notice: ConnectionNotice

    private(set) var sessions: [RemoteSession] = []

    /// A restart waiting on a close: the session being replaced, and the folder
    /// its replacement starts in. Set by `restartSession`, spent when the
    /// machine confirms the old one is gone — see the `.closed` handler. A
    /// timer-based restart could let the new session appear while the old one is
    /// still dying, and the copilot tab picks the first agent session in the
    /// folder, so it could land on the corpse. Waiting for the close removes the
    /// window entirely.
    private var restartAfterClose: (id: String, folder: String)?
    /// Epoch-millisecond stamps, only for the sessions the host timestamped.
    private(set) var lastActivity: [String: Double] = [:]
    /// What is listening on this machine. Empty against a host that does not
    /// offer the `localhost` capability.
    private(set) var ports: [LocalPort] = []
    /// The one port being browsed on this machine, if any.
    /**
     * The tunnels this phone is holding on this machine, **by port**.
     *
     * One became many when the Browser grew tabs: *"it should have all those
     * options — to start a new windows thing should be there."* A tab is a
     * (port, path) pair, and the port is what a tunnel is — `PortTunnel` binds
     * the *same* number on this phone's loopback and refuses if it is already
     * answering, so two tabs on `3000` at different paths are one tunnel and a
     * second one on `3000` cannot exist. Keyed by port for exactly that reason.
     */
    private(set) var tunnels: [Int: PortTunnel] = [:]

    /// The most recently opened one, for the callers that predate tabs and mean
    /// "the page on screen". A single-tab phone behaves exactly as it did.
    var tunnel: PortTunnel? { lastTunnelPort.flatMap { tunnels[$0] } }
    private var lastTunnelPort: Int?
    /// The file on its way to this machine, if any.
    private(set) var upload: FileUpload?
    /// The last thing that went wrong here. Cleared on the next success.
    private(set) var lastError: String?
    /// What kind of machine this is, as the host itself said in its `welcome`.
    ///
    /// Per host and not global: one phone holds several machines at once, and a
    /// Mac and a Windows PC are routinely both in that list. A single app-wide
    /// value would be right for whichever was greeted last and wrong for the
    /// other — which is a subtler version of the constant string it replaces.
    private(set) var hostPlatform: HostPlatform = .unknown

    /// What build the machine at the other end is running, e.g. `0.10.0`, or nil
    /// when it never said — every host before 0.10.0. Display text and nothing
    /// to act on: there is no update verb on this wire, so what it buys is the
    /// one honest sentence a client can say when its own build is ahead. See
    /// `hostVersionNote`. Per host for the reason `hostPlatform` is.
    private(set) var hostAppVersion: String?

    /// Which shell serves this machine — desktop or headless. `.unknown` for a
    /// host older than the field, which names the box neutrally. Read so the
    /// version sentence can say *server* where it would otherwise say *desktop*.
    private(set) var hostKind: HostKind = .unknown

    /// This phone's own device id, as this machine knows it — the `deviceId` the
    /// welcome carries. Read by the device roster to mark and name this phone's
    /// own row (its Remove is sign-out, not the same word as any other).
    private(set) var thisDeviceId: String?

    /// What the switcher shows. The user's name for the machine, or its address.
    var label: String { credential.label }

    /**
     * Told about a credential the host minted, so the collection on disk can be
     * updated without this object reaching into the store itself.
     *
     * A link that wrote to the Keychain directly would be N writers to one
     * drawer, and the one bug that must not exist here is a write for one host
     * that lands on another.
     */
    var onCredential: ((StoredCredential) -> Void)?
    /// This machine refused the credential for good. The link is about to be torn
    /// down; the sentence says why.
    var onNeedsPairing: ((String) -> Void)?
    /**
     * The connection changed.
     *
     * The collection needs this for one thing: knowing when a redemption is over,
     * whichever way it went. Without it `isPairing` is set by `pair` and cleared
     * by nobody — the Pair button then reads "Pairing…" and stays *disabled*
     * forever, so the next machine cannot be added at all. That is not a
     * hypothetical: it is what the two-host UI test found, and the symptom was a
     * sheet that would not close rather than a button that would not press.
     */
    var onConnectionChange: ((ConnectionState) -> Void)?
    /// A session was started on this machine at this phone's request.
    var onCreated: ((String) -> Void)?

    /**
     * The session list on this machine changed.
     *
     * Every path that can change a status goes through here — the whole list,
     * one `status` frame, an `exit`, a session this phone asked for — because
     * the thing above is watching for *transitions* and a transition missed is
     * an alert that never fires. See `SessionAlerts`.
     *
     * The reason distinguishes a change that happened while this phone was
     * listening from the first list after a connection came back, which is a
     * catch-up: what is in it happened while nothing here was running.
     */
    var onSessionsChanged: (([RemoteSession], AlertReason) -> Void)?

    private let credentials: CredentialStore
    private let device: DeviceDescriptor
    private var transport: Transport?
    private let makeTransport: (String, CredentialStore, DeviceDescriptor) -> Transport

    /// How a `PortTunnel` reaches the socket without reaching this object's API.
    /// One indirection buys back the rule that a view never builds a wire message.
    @ObservationIgnored
    private lazy var wire: TunnelWire = WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    }
    @ObservationIgnored
    private lazy var uploadWire: UploadWire = WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    }

    /**
     * This machine's copilot.
     *
     * Built eagerly rather than on first use, unlike the tunnel and the upload,
     * and the difference is what each of the three *is*. Those two are a live
     * transfer that exists only while something is happening; this is a
     * standing fact about the machine — whether it has a copilot, and what this
     * device may do with it — that has to be answerable the moment the session
     * list draws its first row. A lazily built one would report "not offered"
     * on the frame before anybody asked it, which is the wrong answer for a
     * machine that offers it.
     */
    @ObservationIgnored
    private(set) lazy var copilot: CopilotLink = {
        // A wire and nothing else. It used to be handed a `CopilotVaultProxy`
        // as well — two closures onto the copilot credential kept in this
        // machine's Keychain record — and there is no second credential any
        // more: pairing this device as one of his *is* the copilot's
        // authorisation. See `CopilotLink`.
        let link = CopilotLink(wire: WireProxy { [weak self] message in
            self?.transport?.send(message) ?? false
        })
        // One error surface per machine. A second `lastError` on the copilot
        // would be a second banner that can disagree with this one about which
        // of them is showing.
        link.onError = { [weak self] sentence in
            self?.lastError = sentence
        }
        return link
    }()

    /**
     * The bar over whichever session is on screen, and the conversation behind
     * it.
     *
     * Lazily built, unlike `copilot` above, and the difference is what each one
     * is: the copilot's access is a standing fact about the machine that the
     * session list needs before it draws a row, while this is state about one
     * session that does not exist until a terminal is opened. See
     * `SessionBarLink`, which also says why it holds one session rather than a
     * table.
     */
    @ObservationIgnored
    private(set) lazy var bar: SessionBarLink = SessionBarLink(wire: WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    })

    /**
     * The 0.10.0 clients, each the phone half of a capability the desktop has
     * answered since before this app asked. Lazily built for the reason `bar` is:
     * they are state about a machine or a session that does not exist until a
     * screen wants it. Each gates itself on what the welcome advertised — see
     * `welcomed(capabilities:)` — so an older desktop or a guest gets exactly the
     * screens it had before, never a control explaining what it lacks.
     */
    @ObservationIgnored
    private(set) lazy var controls: SessionControlsLink = SessionControlsLink(wire: WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    })
    @ObservationIgnored
    private(set) lazy var serverSettings: ServerSettingsLink = ServerSettingsLink(wire: WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    })
    @ObservationIgnored
    private(set) lazy var devices: DeviceRosterLink = DeviceRosterLink(wire: WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    })
    @ObservationIgnored
    private(set) lazy var watch: WatchLink = WatchLink(wire: WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    })
    @ObservationIgnored
    private(set) lazy var github: GitHubLink = GitHubLink(wire: WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    })
    /// The host's own lifecycle over the relay — status, restart, stop. "The
    /// relay is the network": when a server is a connected machine, its server
    /// page reaches the host here rather than over an SSH address that can drop.
    @ObservationIgnored
    private(set) lazy var hostControl: HostControlLink = HostControlLink(wire: WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    })

    private var bridges: [String: TerminalBridge] = [:]
    /// Confirmed by the host.
    private var attached: Set<String> = []
    /// Wanted by the user — a terminal screen is on the stack for it.
    private var wanted: Set<String> = []
    /// Set between asking this machine for a session and being told about it.
    private var openWhenCreated = false
    /// Lines from inspect mode waiting for their session to finish attaching.
    private var pendingAgentLines: [String: [String]] = [:]

    /// `notice` is a seam for the tests in the same way `makeTransport` is: the
    /// real one holds a clock and a timer, and a test hands in one whose clock it
    /// controls so five seconds can pass without five seconds passing.
    init(credential: StoredCredential,
         credentials: CredentialStore,
         device: DeviceDescriptor,
         makeTransport: ((String, CredentialStore, DeviceDescriptor) -> Transport)? = nil,
         notice: ConnectionNotice? = nil) {
        self.id = credential.hostId
        self.credential = credential
        self.credentials = credentials
        self.device = device
        self.notice = notice ?? ConnectionNotice()
        // Defaulted inside the body rather than in the signature: a default
        // argument is evaluated outside the actor, and `LiveTransport` is
        // main-actor isolated.
        self.makeTransport = makeTransport ?? { hostId, store, device in
            LiveTransport(hostId: hostId, device: device, credentials: store)
        }
    }

    // MARK: - Capabilities

    /// Only true when this machine said it can. See `WireCapability`.
    var canCreateSessions: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.create) ?? false)
    }

    /**
     * Whether this machine will let this phone end a session.
     *
     * Its own capability rather than being read off `canCreateSessions`, and
     * the two genuinely come apart — the public demo box hands a stranger a
     * shell and withholds this one. It gates a swipe action, which is the one
     * place in this app where an ungated control would be worst: closing is not
     * undoable, so a Close drawn against a machine that would refuse it is a
     * control whose outcome a person cannot predict until after they have
     * pressed it.
     */
    var canCloseSessions: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.close) ?? false)
    }

    /// Whether this machine will take a name for one of its sessions. Read the
    /// same way `canCloseSessions` is and separately from it — see
    /// `WireCapability.rename` for why the two are not one answer.
    var canRenameSessions: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.rename) ?? false)
    }

    var canBrowseLocalhost: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.localhost) ?? false)
    }

    /**
     * Whether this machine will open a page **on its own screen** for this phone.
     *
     * A different question from `canBrowseLocalhost`, which is why it is a
     * different property. A tunnel brings the page here; this puts it there, and
     * it is the half he asked for by name — *"a browser started from the phone
     * must run on the machine you are inside."*
     *
     * Two hosts withhold it: one with no window to open a page in, and a device
     * that is a **guest** rather than one of the owner's own. Both arrive
     * identically, as a name the welcome did not carry, and the button is simply
     * not drawn — which is the whole of *"the copilot is never shared"* applied
     * to a second verb that drives somebody's machine rather than reaching a
     * folder.
     */
    var canOpenPagesThere: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.web) ?? false)
    }

    var canSendFiles: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.upload) ?? false)
    }

    /**
     * Whether this machine will discuss its projects' dev servers.
     *
     * Its own capability rather than part of `canBrowseLocalhost`, and the two
     * genuinely come apart: every desktop can tunnel a port, while starting a
     * dev server needs a session layer that can start a session *and* a folder
     * this device was granted. A host can offer either without the other, and
     * the public demo box offers neither.
     */
    var canUseDevServers: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.devserver) ?? false)
    }

    /**
     * What this phone may do with this machine's copilot.
     *
     * **Not** gated on `connection.isLive`, which is the one capability here
     * that is not, and the asymmetry is deliberate. The others gate a *button*:
     * New Session over a dead socket is a tap that cannot work, so it goes. This
     * gates a whole screen, and a screen that vanished for the three seconds of
     * a reconnect — inside the five-second window where `ConnectionGrace`
     * deliberately says nothing — would be a feature disappearing with no
     * explanation anywhere on the phone.
     *
     * Nothing is lost by leaving it up, because the controls on it cannot lie:
     * `Transport.send` refuses rather than queues when the socket is down, so
     * every act on that screen answers *"Not connected — that was not sent"*
     * rather than appearing to work. The conversation underneath is history and
     * stays true; the state and the countdowns are cleared by
     * `CopilotLink.connectionLost`.
     */
    var copilotAccess: CopilotAccess { copilot.access }

    var endpointSummary: String { credential.endpoint.summary }

    /**
     * Folders this phone may ask for a session in **on this machine**.
     *
     * Two sources, and which one is in use is decided by the desktop rather than
     * by this app:
     *
     *  - **What the machine granted this device.** `welcome.folders`, kept
     *    current by the pushed `folders` frame. It is the same array the desktop
     *    enforces against — one function answers both questions over there — so
     *    a folder on this list is a folder that will actually start, subject
     *    only to it still existing.
     *  - **The working directories already on screen**, for a desktop old enough
     *    not to have said. That was the only source before grants existed, and
     *    the two were never the same set: the picker offered one folder while
     *    the Mac would have accepted several, and nothing on either screen
     *    explained why.
     *
     * Per host by construction: offering a Mac's folder to a Windows PC would be
     * a picker full of choices that fail.
     */
    var startableFolders: [String] {
        if let granted { return granted }
        var seen = Set<String>()
        return sessions.compactMap { seen.insert($0.cwd).inserted ? $0.cwd : nil }
    }

    /**
     * What this machine says this device may use, or nil if it has never said.
     *
     * Nil is a desktop that predates the field. **Empty is a person choosing
     * none**, which is why this is not flattened to `[]` on arrival: the two
     * lead to different screens, and collapsing them would put the older
     * desktop's phone in front of the newer desktop's "no folders" message.
     */
    private(set) var granted: [String]?

    /// Whether a session can be started at all right now. The capability says
    /// the machine *can*; an empty grant says this device *may not*, and a
    /// button that is only ever refused is not a button.
    var canStartSomewhere: Bool {
        canCreateSessions && (canPickFolders || granted?.isEmpty != true)
    }

    /**
     * Whether this phone may walk the machine's folders to find one.
     *
     * Advertised only to one of the owner's own devices, so its absence means
     * either a guest or a host older than the capability — two facts this phone
     * cannot tell apart and does not need to. Both draw the picker without the
     * *Choose a folder* row, which is what the app looked like before this
     * existed.
     */
    var canPickFolders: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.folderPick) ?? false)
    }

    /* ---- the six panels ---------------------------------------------------- */

    /// Whether this phone may read the machine's files. Owner devices only, so
    /// its absence means either a guest or a host older than the capability —
    /// two facts a phone cannot tell apart and does not need to.
    var canReadFiles: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.files) ?? false)
    }
    var canReadGit: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.git) ?? false)
    }
    var canReadPanels: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.panels) ?? false)
    }

    /// Whether this machine will discuss its browser's profiles. Withheld from a
    /// guest at the source — a profile is somebody's signed-in cookie jar, and
    /// clearing one signs their machine out of everything in it.
    var canUseMachineProfiles: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.browserProfiles) ?? false)
    }

    /// The machine's profiles, or nil until a `browser.profile.rows` has landed.
    /// Nil is *not asked yet* and draws a spinner; an empty list is an answer.
    private(set) var machineProfiles: MachineProfileList?

    /**
     * Ask for them, on every visit rather than once.
     *
     * This family has no push, and what it answers moves for reasons this phone
     * never hears about — somebody switching profile at the machine, a jar
     * growing while a page was open. The held list is deliberately **not**
     * cleared first, so a re-read redraws under the rows already on screen
     * instead of blanking a list somebody is looking at.
     */
    func readMachineProfiles() {
        guard canUseMachineProfiles else { return }
        transport?.send(.browserProfiles)
    }

    /// Switch the machine's browser. The answer is the whole list coming back
    /// with the tick moved, which is what lets the screen confirm itself.
    func useMachineProfile(_ id: String) {
        guard canUseMachineProfiles else { return }
        transport?.send(.browserProfileUse(id: id))
    }

    /// Empty one profile's jar on the machine. Nothing this phone holds moves.
    func clearMachineProfile(_ id: String) {
        guard canUseMachineProfiles else { return }
        transport?.send(.browserProfileClear(id: id))
    }

    /// What the machine last said about a folder, a file, git, and each panel.
    /// Keyed by nothing: one screen is open at a time, and a stale answer for a
    /// screen nobody is looking at is cleared when the next ask goes out.
    private(set) var fileListing: FileListing?
    private(set) var fileText: FileText?
    private(set) var gitState: GitState?
    private(set) var gitPatch: GitPatch?
    private(set) var panels: [PanelKind: PanelData] = [:]
    /// Why the last read could not be shown, if it could not.
    private(set) var readError: String?

    func listFiles(_ path: String) {
        guard canReadFiles else { return }
        fileListing = nil
        readError = nil
        transport?.send(.filesList(path: path))
    }

    /**
     * Read a file, or the next window of one.
     *
     * The window is deliberately smaller than the 256KB the host will serve: a
     * frame that big fails this client's own socket, because `Carrier` hands
     * `Wire.maxFrameMessageBytes` to `URLSessionWebSocketTask.maximumMessageSize`
     * and an oversize message ends the connection rather than being dropped. The
     * next screen is a second read from where this one stopped.
     */
    func readFile(_ path: String, at: Int = 0) {
        guard canReadFiles else { return }
        if at == 0 { fileText = nil }
        readError = nil
        transport?.send(.filesRead(path: path, at: at, max: 64 * 1024))
    }

    func gitStatus(_ path: String) {
        guard canReadGit else { return }
        gitState = nil
        readError = nil
        transport?.send(.gitStatus(path: path))
    }

    func gitDiff(_ path: String, file: String, staged: Bool) {
        guard canReadGit else { return }
        gitPatch = nil
        readError = nil
        transport?.send(.gitDiff(path: path, file: file, staged: staged))
    }

    /**
     * Read one panel, optionally filtered.
     *
     * The held answer is cleared first so the screen draws a spinner rather than
     * last visit's rows under this visit's caption — the opposite of the rule
     * `readMachineProfiles` follows, and the difference is that a panel's filter
     * can change what it is *about*, so showing the old rows while the new scope
     * loads would be showing an answer to a different question.
     */
    func readPanel(_ panel: PanelKind, path: String? = nil, scope: String? = nil, query: String? = nil) {
        guard canReadPanels else { return }
        panels[panel] = nil
        readError = nil
        transport?.send(.panelRead(panel: panel.rawValue, path: path, scope: scope, query: query))
    }

    /**
     * Do the thing a panel offered, and redraw with whatever comes back.
     *
     * The held answer is **not** cleared here, unlike a read. An action is a
     * change to a list somebody is looking at — removing a server, installing a
     * tool — and blanking the screen for the round trip loses their place in it
     * for no gain. The answer replaces the rows when it lands, carrying its own
     * `notice` about what happened.
     */
    func actOnPanel(_ panel: PanelKind, action: String, path: String? = nil,
                    id: String? = nil, fields: [String: String] = [:]) {
        guard canReadPanels else { return }
        readError = nil
        transport?.send(.panelAct(panel: panel.rawValue, action: action,
                                  path: path, id: id, fields: fields))
    }

    // MARK: - The machine's own browser

    /// Whether this machine will let this phone drive its browser. Withheld from
    /// a guest at the source: a bound window can be told to navigate anywhere and
    /// photographed, and its output is handed to a session running commands.
    var canDriveBrowser: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.browserControl) ?? false)
    }

    /// What the machine's browser has open, or nil until a `browser.window.rows`
    /// has landed. Nil is *not asked yet*; an empty list is an answer.
    private(set) var machineBrowser: MachineBrowserState?

    /// The last picture a window was photographed into, when it was not handed
    /// to a session instead. One at a time — a screen showing two is a screen
    /// nobody asked for, and holding every shot of a long session is megabytes.
    private(set) var machineShot: MachineShot?

    /// The recorded flow, by window. Kept per window rather than as one, because
    /// two windows can be recording at once and their steps are unrelated.
    private(set) var machineSteps: [String: [RecordedStep]] = [:]

    /**
     * **The window each session last let go of, by session id.**
     *
     * > *"One [close button] which will just remove this from this page but
     * > window will not die. Window will stay there in the window side here… As
     * > soon as we talk about it and want to bring it back we can bring it from
     * > here back to the page from the three dots."*
     *
     * The strip's Disconnect is the first half of that sentence and it already
     * works: the window is unbound, it stays open on the machine with whatever
     * is on it, and it comes straight back into *Attach a browser window* in the
     * `…` because that section lists every window the machine has, bound or not.
     * What was missing is the second half — **finding it there.** He said *"we
     * can bring it back"* about a specific window, the one he had just been
     * looking at, and in that list it is one name among however many the machine
     * happens to have open, in the machine's own order, with nothing marking it.
     * On a laptop with eight tabs that is a search rather than a return.
     *
     * So the one fact the list cannot work out for itself is remembered here:
     * which window this session was holding a moment ago. `SessionWindowPicker`
     * sorts it to the top of the section and draws it with a *come back* arrow
     * instead of a window frame, and both menus read the same answer so they
     * cannot disagree about which window a session is missing.
     *
     * **Held here rather than in a screen's `@State`**, and that is the whole
     * reason it is on this object: the strip you press Disconnect on is inside a
     * session screen, and the menu you press to get it back is on that screen
     * *and* on the session row two screens away. A memory that lived in either
     * view would be gone by the time the other one was drawn — the session
     * screen is destroyed on the way back to the list.
     *
     * Nothing here can go stale into a wrong answer. It is a window **id**, and
     * every reader matches it against the machine's live list: a window that has
     * since been closed, or handed to another session, is simply not found, or
     * is found and already says whose it is. Nothing is drawn from this on its
     * own.
     */
    private(set) var releasedWindows: [String: String] = [:]

    /// Which window this session was holding until it let go, if the machine
    /// still has it open. Nil is the ordinary answer — most sessions have never
    /// held a window at all.
    func releasedWindow(for session: String) -> String? { releasedWindows[session] }

    /// Ask what is open. Re-read on every visit: this family has no push, and
    /// what it answers moves for reasons this phone never hears about — somebody
    /// at the machine opening a tab, a session binding a window of its own.
    func readMachineWindows() {
        guard canDriveBrowser else { return }
        transport?.send(.machineWindows)
    }

    /**
     * Open a window on the machine, and — when a session is named — hand it to
     * that session in the same act.
     *
     * The two halves cannot be two calls, and that is a fact about the wire
     * rather than a preference. `browser.window.bind` names a window by its id,
     * and until the host's own `open` returns nobody outside the machine knows
     * which window was just made: an open answers with the window *list*, so a
     * client wanting to bind what it just opened would have to pick the new row
     * out by comparing the list before with the list after. That is a race two
     * taps apart, and `browser-control.ts` records the same hack being removed
     * one layer down because **two opens in flight each find both rows**.
     *
     * So the session rides on the open. The host checks it is really running
     * *before* it touches the browser — a window opened for a session that turns
     * out not to exist is a page on somebody's screen that nobody asked for and
     * nobody is there to close — and the answer is the window list carrying the
     * bind notice, because what happened is a bind.
     */
    func openMachineWindow(url: String? = nil, profile: String? = nil,
                           isolated: Bool = false, session: String? = nil) {
        guard canDriveBrowser else { return }
        transport?.send(.machineWindowOpen(url: url, profile: profile,
                                           isolated: isolated, session: session))
    }

    func goMachineWindow(_ id: String, to url: String) {
        guard canDriveBrowser else { return }
        transport?.send(.machineWindowGo(id: id, url: url))
    }

    func actOnMachineWindow(_ id: String, _ act: MachineBrowserWire.Act) {
        guard canDriveBrowser else { return }
        transport?.send(.machineWindowAct(id: id, action: act))
    }

    /**
     * Lay a window's page out in a rectangle of this size, in CSS pixels.
     *
     * > *"it opens a very big page then it compares to the normal size… it should
     * > always open to the normal size."*
     *
     * The size is the **pane the picture is going to be drawn into**, in points,
     * so one CSS pixel lands on one point and the page arrives at 100% instead of
     * at whatever ratio `WatchMath.fit` happened to compute. See
     * `WireProtocol.machineWindowSize` for why both numbers are needed and why
     * this is not a per-frame negotiation.
     *
     * Nothing is remembered here. Which window has been told what, and therefore
     * whether telling it again is worth a frame, is the **screen's** business —
     * it is the thing that knows its own pane moved. A cache in this object would
     * be a second opinion about a pane it cannot see, and the failure it produces
     * is a page that stays the wrong size after a rotation because something in
     * here decided the message was a duplicate.
     */
    func sizeMachineWindow(_ id: String, width: Int, height: Int) {
        guard canDriveBrowser else { return }
        transport?.send(.machineWindowSize(id: id, width: width, height: height))
    }

    /**
     * Bind a window to a session, or unbind it by passing nil.
     *
     * The two lines under the guard are the memory behind *"we can bring it back
     * from the three dots"* — see `releasedWindows`. They are written **here**
     * rather than at the four places that press this verb, because the strip's
     * Disconnect, the Browser tab's row, the window's own settings screen and
     * the desktop-style unbind are all the same act and a memory written at one
     * of them would be a menu that only remembers windows let go one particular
     * way.
     *
     * Who was holding it is read off the list this phone already has rather than
     * passed in, for the same reason: the callers know the window, and only one
     * of them knows the session. `machineBrowser` is the answer the machine gave
     * to the last `browser.window.rows`, which is what every one of those screens
     * is drawing from at the moment the finger lands, so it is the same fact they
     * are looking at.
     */
    func bindMachineWindow(_ id: String, to session: String?) {
        guard canDriveBrowser else { return }
        if let session {
            // It is holding a window again, so there is nothing to come back to.
            // Left in place, the section would go on offering a *return* to a
            // window this session has already replaced.
            releasedWindows.removeValue(forKey: session)
        } else if let letGo = machineBrowser?.windows.first(where: { $0.id == id })?.session {
            releasedWindows[letGo] = id
        }
        transport?.send(.machineWindowBind(id: id, session: session))
    }

    /**
     * Photograph a window.
     *
     * With a session, the picture goes **there** and this phone gets the window
     * list back with a notice — which is the shape *"take a screenshot and send
     * it to the session"* actually wants: the point is that the agent receives
     * it, not that a phone displays it. The held shot is cleared either way, so
     * a picture sent to a session never leaves last time's on screen.
     */
    func shotMachineWindow(_ id: String, to session: String? = nil, note: String? = nil) {
        guard canDriveBrowser else { return }
        machineShot = nil
        transport?.send(.machineWindowShot(id: id, session: session, note: note))
    }

    func readMachineSteps(_ id: String) {
        guard canDriveBrowser else { return }
        transport?.send(.machineWindowSteps(id: id))
    }

    /**
     * The element the machine last described, and the window it is on.
     *
     * Nil is *nothing has been pointed at* — the ordinary state, and what
     * putting the sheet away goes back to. The window is carried with it because
     * two windows can be open on this phone's stack and an answer about the one
     * that is no longer on screen is not an answer to draw.
     */
    private(set) var machinePicked: MachinePickResult?

    /**
     * The window a pick is in flight for, or nil.
     *
     * The screen draws a line off this while it waits. It matters more than the
     * usual spinner does, because **every way a pick can fail comes back as the
     * window list with one sentence on it** rather than as a refusal of the ask:
     * nothing at that spot, a page that has scrolled since the picture, a machine
     * whose browser cannot be reached into at all. So this is cleared by the
     * list as well as by an answer — a phone that only cleared it on success
     * would sit there looking like a hang while the sentence explaining it was
     * already on the screen above.
     */
    private(set) var pickingIn: String?

    /**
     * Ask what is at one point on a machine window's page.
     *
     * `x` and `y` are **document** coordinates — see `MachinePick.documentPoint`,
     * which is the one place a tap on the picture becomes them. `up` is how many
     * ancestors to climb and it is clamped again in the codec, on the last line
     * before the wire, because an out-of-range one closes the socket rather than
     * drawing a refusal.
     */
    func pickInMachineWindow(_ id: String, x: Double, y: Double, up: Int = 0) {
        guard canDriveBrowser, !id.isEmpty else { return }
        pickingIn = id
        transport?.send(.machineWindowPick(id: id, x: x, y: y, up: up))
    }

    /// The sheet was put away, or inspecting was turned off. The held element
    /// goes with it — an element still on this phone after the screen that asked
    /// about it has moved on is one Wider would walk up from a page nobody is
    /// looking at.
    func clearMachinePick() {
        machinePicked = nil
        pickingIn = nil
    }

    /// What the picker last asked for, so a stale answer can be told from the
    /// current one. Nil when nothing is browsing.
    private(set) var browsing: String?

    /// The folder the picker is showing, once the machine has answered.
    private(set) var browsed: FolderListing?

    /// Why the last browse could not be shown, if it could not.
    private(set) var browseError: String?

    /**
     * Ask the machine what is inside a folder.
     *
     * `nil` opens the picker wherever the machine thinks is sensible — the
     * folder this device already works in. The phone deliberately does not guess:
     * it does not know whether this machine's home is `/Users/apple`, `/root` or
     * `C:\\Users\\asad`, and a guess that is wrong opens the picker on an error.
     */
    func browseFolders(_ path: String?) {
        guard canPickFolders else { return }
        // Cleared rather than left standing: the rows on screen belong to the
        // folder being left, and holding them through the round trip shows the
        // old folder's contents under the new folder's heading.
        browsed = nil
        browseError = nil
        browsing = path ?? ""
        transport?.send(.browseFolders(path: path))
    }

    /// Leave the picker, so a late answer for a folder nobody is looking at is
    /// dropped rather than drawn.
    func endBrowsing() {
        browsing = nil
        browsed = nil
        browseError = nil
    }

    // MARK: - Lifecycle

    func start() {
        // The grace period starts here rather than at the first state event, so
        // that the five seconds cover the dial itself. A transport that is slow
        // to say anything at all is exactly the case the rule is written for.
        notice.observe(connection)
        if transport == nil { build() }
        transport?.start()
    }

    /// The app came back to the foreground, or the network changed.
    func resume() {
        // A suspended app runs no timers, so the notice may be holding a
        // deadline that passed while the phone was in a pocket. See
        // `ConnectionNotice.refresh`.
        notice.refresh()
        transport?.resume()
    }

    func refresh() {
        transport?.send(.list)
        // Asked for alongside the sessions rather than on a timer of its own.
        // The host's scan spawns `lsof`; polling it from a phone in a pocket
        // would run that on somebody's laptop every few seconds forever.
        if canBrowseLocalhost { transport?.send(.ports) }
        // Pull-to-refresh, and nothing else, asks these again. A dev server's
        // changes are *pushed* — see `askDevServers` — so a timer here would be
        // this app polling a question the desktop is already answering, which is
        // the one thing the frame's own documentation asks clients not to do.
        // What a pull genuinely fixes is a folder whose reply was lost with a
        // socket the app has since replaced.
        askDevServers()
        // The same argument one feature over. The copilot's state, its sessions
        // and its pending questions are all pushed while the socket is up, so
        // this is for the answer that was lost with a socket rather than for a
        // timer that would be polling something already being answered.
        copilot.refresh()
    }

    /**
     * Take this machine down and forget what it turned out to be — the app is
     * closing, or the user is unpairing and the store is about to be written by
     * someone else.
     *
     * The teardown and the forgetting are two things, and {@link restart} is the
     * one that wants only the first. See the note on `copilot.forget()` below.
     */
    func stop() {
        drop()
        // And what this machine turned out to be, for a sharper version of the
        // reason `granted` is cleared in `drop()`: a permission remembered across
        // a teardown is a permission this phone would draw controls for against a
        // machine it has not been readmitted to. An unpair and a re-pair both run
        // this, and a re-pair mints a **new** device id, so nothing about the old
        // one may be carried across.
        copilot.forget()
        // And its routines with it, on exactly the argument above: a re-pair
        // mints a new device id, and nothing about the old one may be carried
        // across.
        copilot.forgetRoutines()
    }

    /**
     * Put the socket down and bring it straight back up, keeping what this
     * machine *is*.
     *
     * **A re-sign-in is not an unpair**, and treating it as one is what took the
     * Copilot pill off the bar in front of him. `DeckModel.adoptSignedIn` ran
     * `stop()` then `start()` on a machine that was already in the list — the
     * right idea, because the transport has to pick up the credential that was
     * just written rather than retry with the old one — but `stop()` also runs
     * `copilot.forget()`, which clears `isOffered`, `isImplemented` and `linked`.
     * The pill is drawn from exactly those three. So the bar went from four pills
     * to three the moment he signed in again, and back to four a second or two
     * later when the reconnect's `welcome` landed: *"at 3:25 the bar carries
     * Copilot · Sessions · Localhost · Settings. Seconds later, on the same
     * screen, Copilot is gone."*
     *
     * Nothing about the machine changed across that sign-in. It is the same
     * host, the same relay slot and — since the trust store stopped minting a
     * second row for a key it already knows — the same device id, so there was
     * never anything for the phone to re-learn. What the socket held goes;
     * what the machine is stays, and the tab bar does not restructure under a
     * thumb.
     */
    func restart() {
        drop()
        start()
    }

    /// Everything a teardown drops: the socket, and every claim that belonged to
    /// it. Shared by `stop()` and `restart()` so the two cannot drift about what
    /// a dropped connection means on screen.
    private func drop() {
        closeLocalhost()
        clearUpload()
        transport?.stop()
        transport = nil
        sessions = []
        ports = []
        // The subscription these rows were kept alive by belonged to the socket
        // that is being dropped. Keeping them would leave a `starting` spinner
        // over a folder nothing is going to report on again.
        devServers = [:]
        lastActivity = [:]
        // Back to "this machine has not said", not to "this machine granted
        // nothing". The grant belongs to a live connection, and remembering an
        // empty one across a stop would leave a phone refusing to offer New
        // Session on a machine that has simply not been asked yet.
        granted = nil
        // The copilot's *connection* goes here with everything else the socket
        // held; what the machine **is** is `stop()`'s to forget and `restart()`'s
        // to keep. Splitting the two is the whole of the tab-bar fix — see
        // `restart()`.
        copilot.connectionLost()
        // The routines' own half of the same split. The rows stay — a routine
        // is a file that exists whether or not this socket does — and what
        // goes is the claim that they are current. See `CopilotLink.routines`.
        copilot.routinesConnectionLost()
        attached = []
        wanted = []
        bridges = [:]
        pendingAgentLines = [:]
        connection = .offline
        // Told rather than reset. A machine that is being torn down and brought
        // straight back up — which is what re-pairing does — is one continuous
        // outage from the person's point of view, so the clock that was already
        // running keeps running.
        notice.observe(connection)
        lastError = nil
    }

    func rename(_ name: String?) {
        credential = credential.renamed(name)
        onCredential?(credential)
    }

    private func build() {
        let transport = makeTransport(id, credentials, device)
        transport.onEvent = { [weak self] event in
            self?.handle(event)
        }
        self.transport = transport
    }

    // MARK: - Sessions

    func session(_ id: String) -> RemoteSession? {
        sessions.first { $0.id == id }
    }

    /// The terminal for a session, created on first use.
    func bridge(for id: String) -> TerminalBridge {
        if let existing = bridges[id] { return existing }
        let bridge = TerminalBridge()
        bridge.onInput = { [weak self] text in
            self?.sendInput(id, text)
        }
        bridge.onResize = { [weak self] cols, rows in
            self?.sendResize(id, cols: cols, rows: rows)
        }
        bridges[id] = bridge
        return bridge
    }

    /// Called when a terminal screen appears. Records the intent first, so a
    /// reconnect knows to re-attach even if the socket is down right now.
    func attach(_ id: String) {
        // Back inside the grace, which is the whole of *"if I go back, if I come
        // back, it should stay"*. Cancelling here means the `detach` never left,
        // so there is no `attach` to answer, no `attached` frame, no reset and no
        // replay — the guard below returns on the very next line. See
        // `leaveSession`.
        leaving.removeValue(forKey: id)?.cancel()
        wanted.insert(id)
        rememberLastOpened(id)
        guard !attached.contains(id) else { return }
        if transport?.send(.attach(id: id, size: bridge(for: id).size)) != true {
            bridge(for: id).note(connection.detail)
        }
    }

    /**
     * **The screen went away. Do not tell the machine yet.**
     *
     * > *"coming back it refreshing the page every time I am coming, it should
     * > stay as it is. If I go back, if I come back, it should not do this
     * > refresh thing, it should stay. The visuals, the UI is refreshing kind of
     * > thing."*
     *
     * That refresh is a real, whole repaint and this method is where it started.
     * The old sequence, every single time somebody went back to the session list
     * and returned:
     *
     *   1. `onDisappear` → `detach` → the machine stops fanning output here.
     *   2. `onAppear` → `attach` → the machine answers `attached`.
     *   3. `attached` → `bridge.clear()`, which is **RIS** — a full terminal
     *      reset, the whole screen wiped — followed by `holdForBacklog()`, which
     *      takes the emulator's alpha to zero.
     *   4. The machine replays the entire scrollback in `output` frames, the
     *      terminal repaints from nothing and scrolls to the bottom.
     *
     * Every one of those four steps is correct for what it was written for:
     * arriving at a session for the first time, or after a reconnect, where the
     * screen genuinely is out of date and the reset is what stops the replay
     * being appended under a stale copy of itself. None of them is correct for a
     * screen that was on this exact session four seconds ago and has not missed
     * a byte.
     *
     * So the detach is **deferred rather than removed**. The reason it exists is
     * unchanged and is still honoured — *"the desktop fans output out to every
     * attached client, and a phone that never says it has gone keeps a session
     * pushing bytes at a socket nobody is reading"* — it simply waits long enough
     * to find out whether the person actually left. Come back inside the window
     * and nothing ever happened: no frame left this phone, the emulator was never
     * touched, and the screen he returns to is the screen he left, scrolled where
     * he left it. Stay away and the machine is told, exactly as before.
     *
     * `endBacklogHold` is **not** deferred with it. A hold in flight belongs to a
     * terminal that is on screen; deferring it would leave an invisible terminal
     * behind for as long as the grace lasts, and the person who came straight
     * back would find a blank one.
     */
    func leaveSession(_ id: String) {
        bridges[id]?.endBacklogHold()
        leaving[id]?.cancel()
        leaving[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.leaveGrace))
            guard !Task.isCancelled, let self else { return }
            leaving.removeValue(forKey: id)
            detach(id)
        }
    }

    /**
     * How long a session stays attached after its screen has gone.
     *
     * Half a minute, which is the same number `BackgroundGrace` is built around
     * and for the same reason: it is the length of an ordinary glance away. Going
     * to the list to check on another session, reading a notification, answering
     * somebody — those are seconds, and all of them used to cost a full wipe and
     * replay on the way back.
     *
     * The other end of the trade is what it costs to be wrong: one session's
     * output fanned to a phone that is looking at a list, for up to thirty
     * seconds. That is a handful of frames on a relay, and it stops the moment
     * the grace expires. A wipe-and-replay of a full scrollback is a bigger
     * transfer than thirty seconds of live output on almost any session, so the
     * cheap case is also the correct one.
     */
    static let leaveGrace: TimeInterval = 30

    /// Sessions whose screen has gone but whose attach is being kept warm, by
    /// session id. Cancelled by `attach`, which is what makes coming straight
    /// back cost nothing at all.
    private var leaving: [String: Task<Void, Never>] = [:]

    /**
     * Tell the machine now.
     *
     * The wire verb, and after `leaveSession` it is no longer what a screen
     * calls: a screen says it has *gone*, and how long this phone keeps
     * listening afterwards is this object's decision rather than a view's. It is
     * still called directly when the whole machine is being let go — see the
     * teardown below — because there is nothing left to come back to.
     */
    func detach(_ id: String) {
        leaving.removeValue(forKey: id)?.cancel()
        wanted.remove(id)
        // Before the guard: the screen is being left whether or not this phone
        // was attached, and a hold left in flight belongs to a terminal nobody
        // is looking at.
        bridges[id]?.endBacklogHold()
        guard attached.contains(id) else { return }
        attached.remove(id)
        transport?.send(.detach(id: id))
    }

    func reattach(_ id: String) {
        attached.remove(id)
        bridges[id]?.clear()
        attach(id)
    }

    func createSession(in folder: String?) {
        guard canCreateSessions else {
            lastError = "\(label) cannot start sessions from the phone."
            return
        }
        openWhenCreated = true
        transport?.send(.create(folder: folder, size: pendingSize))
    }

    /**
     * End a session on the machine.
     *
     * No optimistic removal, and that is the whole of the method's design. The
     * row stays until `closed` arrives, because the machine is entitled to
     * refuse — a folder taken back a second ago, a session that had already
     * exited — and a list that had already dropped the row would leave somebody
     * looking for a live session that is not on their screen and cannot be got
     * back without a reconnect.
     *
     * The guard is not decoration either. `canCloseSessions` is false when the
     * socket is down as well as when the machine never offered the verb, and
     * `Transport.send` would refuse it in both cases — but a refusal there is
     * silent, and this is the one action in the app where silence after a
     * confirmed press is indistinguishable from having destroyed something.
     */
    func closeSession(_ id: String) {
        guard canCloseSessions else {
            lastError = "\(label) cannot close sessions from the phone."
            return
        }
        transport?.send(.close(id: id))
    }

    /**
     * End a session and start a fresh one in the same folder, in that order and
     * with the second waiting on the first.
     *
     * This is the copilot's Restart. The create is **not** on a timer: it is
     * held in `restartAfterClose` and fired when the machine's `closed` frame
     * for this id lands, so there is never a moment when the old conversation
     * and its replacement are both live agent sessions in the one folder — which
     * is the moment the copilot tab could resolve onto the one that is ending.
     * If the close is refused the create never fires, which is correct: nothing
     * was ended, so there is nothing to replace.
     */
    func restartSession(_ id: String, in folder: String) {
        guard canCloseSessions, canCreateSessions else {
            lastError = "\(label) cannot restart sessions from the phone."
            return
        }
        restartAfterClose = (id: id, folder: folder)
        transport?.send(.close(id: id))
    }

    /**
     * Give a session a name.
     *
     * No optimistic rename, for the reason `closeSession` does not optimistically
     * remove a row: the machine is entitled to refuse — a folder taken back, a
     * session that has already exited — and a list that had already changed would
     * leave somebody reading a name the machine does not have. The answer is a
     * fresh `sessions` frame, so the row changes when the machine says so.
     *
     * An empty name is passed through rather than treated as a cancel: it is how
     * the machine is told to go back to its own name for the session.
     */
    func renameSession(_ id: String, to title: String) {
        guard canRenameSessions else {
            lastError = "\(label) cannot rename sessions from the phone."
            return
        }
        transport?.send(.rename(id: id, title: title))
    }

    /**
     * Open a page in the browser **on the machine**.
     *
     * The URL is composed from a row that is on screen — `http://localhost:<port>/`
     * for a port this machine itself listed — so this app never has an arbitrary
     * address to send. The machine checks it anyway, through the same gate an
     * untrusted link goes through, because a client is not something a machine
     * gets to trust about what it opens.
     */
    func openOnMachine(_ url: String) {
        guard canOpenPagesThere else {
            lastError = "\(label) cannot open pages from the phone."
            return
        }
        transport?.send(.webOpen(url: url))
    }

    private var pendingSize: TerminalSize? {
        bridges.values.compactMap(\.size).first
    }

    /**
     * Where this phone was last, on this machine.
     *
     * There was a `resumable` here and a card at the top of the session list
     * drawn from it; both are gone — see the note in `SessionListView.list`. The
     * *key* stays, and the reason is `agentTarget` below: inspect mode has to
     * decide which session an element description is sent to, and the session
     * this phone last opened here is the honest default. That is a use nobody
     * has to look at.
     *
     * Per host, which is the difference between remembering something and
     * remembering the wrong machine's work: with two machines paired, a single
     * id would follow the user across the switcher and name a session the host
     * in front of them has never heard of.
     */
    private var lastOpenedKey: String { "terminaldeck.lastSession.v2.\(id)" }

    private func rememberLastOpened(_ sessionId: String) {
        // Not a secret: a session id is meaningless without a credential, and
        // the credential is in the Keychain.
        UserDefaults.standard.set(sessionId, forKey: lastOpenedKey)
    }

    // MARK: - Localhost

    /**
     * Put a port on this machine onto the phone, and hand back the tunnel.
     *
     * **The tap is the consent.** Nothing on the machine is reachable until this
     * runs, it only runs because a person touched a row, and `closeLocalhost` —
     * which the browser view calls when it goes away — ends it.
     */
    func openLocalhost(port: Int) -> PortTunnel? {
        guard canBrowseLocalhost else {
            lastError = "\(label) cannot show its local servers on a phone."
            return nil
        }
        closeLocalhost()
        // Shared rather than replaced: a second tab on a port already tunnelled
        // is the same socket, and opening a second would be refused by the bind.
        if let held = tunnels[port] {
            lastTunnelPort = port
            return held
        }
        let tunnel = PortTunnel(port: port, wire: wire)
        tunnels[port] = tunnel
        lastTunnelPort = port
        tunnel.start()
        return tunnel
    }

    /// Close one port's tunnel — the tab store's verb, called when the **last**
    /// tab on that port goes. Closing one of two tabs on a port must not, which
    /// is the whole of why the counting lives in `BrowserTabs`.
    func closeLocalhost(port: Int) {
        tunnels.removeValue(forKey: port)?.stop()
        if lastTunnelPort == port { lastTunnelPort = tunnels.keys.first }
    }

    func closeLocalhost() {
        for held in tunnels.values { held.stop() }
        tunnels.removeAll()
        lastTunnelPort = nil
    }

    // MARK: - Dev servers

    /**
     * One row per project folder, **keyed by the folder the desktop named**.
     *
     * A dictionary rather than an array because of the one rule this feature
     * cannot get wrong: a `dev.state` **replaces** the row for its folder and
     * never merges into it. The fields on a report are not independent — `port`
     * and `url` exist only on `ready`, `message` only on `failed` — so a merge
     * leaves a dead address sitting under a live row, which the protocol calls
     * the one genuinely wrong thing a client of this frame can display. A
     * subscript assignment cannot do anything else, which is why it is a
     * dictionary of whole values rather than a mutable row somebody updates.
     *
     * The key is the desktop's spelling of the folder, taken off the frame,
     * never the string this phone sent: the two can differ by a trailing
     * separator or by case on Windows and still be the same directory. That
     * matches, because every folder this app can name came out of
     * `welcome.folders` — the desktop's own list — so the string it sends and
     * the string that comes back are the same string.
     *
     * Cleared with the connection, deliberately: pushes stop when the socket
     * does, so a `starting` row kept across a drop would spin forever
     * describing a moment that has passed.
     */
    private(set) var devServers: [String: DevServerReport] = [:]

    /**
     * How many folders this connection will ask about.
     *
     * The desktop's `MAX_DEV_FOLDERS`, mirrored. It is not a display limit: the
     * desktop *answers* a `dev.status` for any granted folder but only
     * **subscribes** the first eight, so a ninth would get one reply and then go
     * quiet — a row that says `starting` and never changes again, which is worse
     * than a row that is not there. Asking for what will be pushed keeps every
     * row on screen live.
     */
    static let maxDevFolders = 8

    /**
     * The folders this phone will ask about, in the order the desktop offered
     * them — most relevant first, which is what makes the cap land on the ones
     * least likely to be looked at.
     *
     * Read from `granted` rather than from `startableFolders`, and the
     * difference matters only in the case that should never happen. Those two
     * are the same list whenever a machine has said anything about folders;
     * where they differ is the fallback, which invents a list out of the working
     * directories of sessions this phone can see. That fallback is right for the
     * New Session picker — it is what a desktop older than per-device grants
     * would have accepted — and it is wrong here, because this capability is
     * authorised against the list this device was **sent**. Nil means "I have
     * not been told", and the honest thing to do with that is ask nothing.
     *
     * ## This is why a bare server has no Start on it, and the fix is not here
     *
     * On a headless box the whole feature is invisible, which is the machine it
     * is most useful on: `welcome.folders` for one of the owner's own devices is
     * the machine's open projects plus the folders its sessions are running in,
     * and a rented Linux box has neither — so `device-reach.ts` falls back to
     * `[home()]`, one row, and a home directory has no dev script, so there is
     * no row and no Start anywhere on the screen.
     *
     * `folders.pick` looks like the answer and is not. It reads directory names;
     * *"it grants nothing, changes nothing, and writes nothing"*, and the folder
     * a person picks goes to the ordinary `create`, which for one of the owner's
     * own devices accepts any absolute path because that device is
     * `unrestricted`. **`dev.status` has no such clause.** It is checked against
     * `sessions.folders(deviceId)` and nothing else, and `dev.status`'s own
     * protocol comment is unambiguous about it: *"the desktop accepts only a
     * folder it is already offering this device in `welcome.folders`"*. So the
     * phone can start a session in a folder it may not ask a single question
     * about.
     *
     * Widening this list from here — adding the folders the visible sessions are
     * running in, which the *desktop's* own reach list does include — was
     * written and then reverted, and what it costs is worth writing down. A
     * refusal comes back as a plain `error` carrying no request id, so a
     * speculative ask cannot be told apart from a real failure and each one
     * lands as a yellow banner about somebody's own machine refusing them. And
     * the contract is what a conforming host is entitled to enforce, not what
     * this build's desktop happens to allow: `ios/Harness/host-standin.ts`
     * checks a `dev.status` against its granted list alone and starts two of its
     * own sessions outside it, which is exactly the shape that would answer
     * every such ask with a banner.
     *
     * Both ends of the fix are on the desktop. Either `devServe` gains the
     * `unrestricted` clause `create` has — the same device, the same machine,
     * and it is already trusted with the stronger verb — or the offered list is
     * pushed when it *changes* rather than only when somebody edits a grant in a
     * settings panel, which is what would make a session started in a picked
     * folder appear here on its own. Today the phone learns about it on the next
     * reconnect, and only then.
     */
    var devFolders: [String] {
        guard canUseDevServers, let granted else { return [] }
        return Array(granted.prefix(Self.maxDevFolders))
    }

    /**
     * The rows worth drawing, in the desktop's own order.
     *
     * `noDevScript` folders are filtered out here rather than in the view, and
     * that is the protocol's rule rather than a layout choice: it means "there is
     * nothing to press, and there never will be for this folder". A row for one
     * could only ever carry a button whose single possible outcome is a refusal.
     * A folder that has not answered yet has no row either — there is nothing
     * true to say about it until it does.
     */
    var devServerRows: [DevServerReport] {
        devFolders.compactMap { devServers[$0] }.filter { $0.status != .noDevScript }
    }

    func devServer(for folder: String) -> DevServerReport? {
        devServers[folder]
    }

    /**
     * Ask about every folder, which is also what subscribes to them.
     *
     * Called on each `welcome` rather than once, because the subscription lives
     * on the desktop's *connection*: a reconnect is a new connection and knows
     * nothing about what the last one was watching. Called again when the grant
     * list changes, because a folder added on the desktop has never been asked
     * about at all.
     */
    func askDevServers() {
        guard canUseDevServers else { return }
        for folder in devFolders { transport?.send(.devStatus(folder: folder)) }
    }

    /**
     * Start one project's dev server. **The tap is the consent.**
     *
     * Nothing runs on the far machine because of this feature until this is
     * sent. There is no queue and no retry: the desktop answers immediately with
     * `starting` and then pushes every change, so a press that does not reach
     * the socket is a press that did nothing, and saying so is better than a row
     * that spins over a message that was never sent.
     */
    func startDevServer(in folder: String) {
        guard canUseDevServers else {
            lastError = "\(label) cannot start dev servers from the phone."
            return
        }
        guard transport?.send(.devStart(folder: folder)) == true else {
            lastError = "Not connected — \(label) was not asked to start that."
            return
        }
    }

    // MARK: - Clipboard

    func paste(into id: String) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            lastError = "There is nothing on the clipboard."
            return
        }
        let bytes = text.utf8.count
        guard bytes <= Wire.maxPasteBytes else {
            lastError = "That paste is \(byteSize(bytes)). The most this can send at once is \(byteSize(Wire.maxPasteBytes))."
            return
        }
        guard let bridge = bridges[id] else {
            lastError = "That session is not open on this phone."
            return
        }
        bridge.paste(text)
    }

    @discardableResult
    func copy(from id: String) -> String {
        guard let bridge = bridges[id] else { return "Nothing to copy." }
        if let selection = bridge.selectedText(), !selection.isEmpty {
            UIPasteboard.general.string = selection
            bridge.clearSelection()
            return "Copied \(lineCount(selection)) from the selection."
        }
        let screen = bridge.visibleText()
        guard !screen.isEmpty else { return "Nothing to copy." }
        UIPasteboard.general.string = screen
        return "Copied \(lineCount(screen)) from the screen."
    }

    @discardableResult
    func copyScreen(from id: String) -> String {
        guard let bridge = bridges[id] else { return "Nothing to copy." }
        let screen = bridge.visibleText()
        guard !screen.isEmpty else { return "Nothing to copy." }
        UIPasteboard.general.string = screen
        return "Copied \(lineCount(screen)) from the screen."
    }

    private func lineCount(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return lines == 1 ? "1 line" : "\(lines) lines"
    }

    // MARK: - Sending a file

    func send(_ file: PickedFile, into sessionID: String) {
        guard canSendFiles else {
            lastError = "\(label) cannot receive files from a phone."
            return
        }
        guard upload == nil else {
            lastError = "One file at a time. Wait for the current one, or cancel it."
            return
        }
        guard file.size <= Wire.maxUploadBytes else {
            lastError = "That file is \(byteSize(file.size)). The most this can send is \(byteSize(Wire.maxUploadBytes))."
            if file.temporary { try? FileManager.default.removeItem(at: file.url) }
            return
        }

        let transfer = FileUpload(file: file, wire: uploadWire) { [weak self] path in
            self?.sendPath(path, into: sessionID)
        }
        upload = transfer
        transfer.start()
    }

    func clearUpload() {
        upload?.cancel()
        upload = nil
    }

    /**
     * Put a landed file's path into the prompt.
     *
     * Quoted, so a name with a space or an apostrophe is one word to the shell,
     * and followed by a space so the user can keep typing. **No newline** — the
     * same rule `Inspect.composeSend` enforces, and for the same reason.
     */
    private func sendPath(_ path: String, into sessionID: String) {
        guard let bridge = bridges[sessionID] else { return }
        bridge.paste("\(shellQuoted(path)) ")
    }

    // MARK: - Inspect mode

    /// Sessions on this machine an inspected element can be described to.
    var agentTargets: [RemoteSession] {
        sessions.filter { $0.status != "exited" }
    }

    /**
     * Where the next inspected element goes **on this machine**.
     *
     * The desktop has a focused session and sends there. The browser screen was
     * opened from a list, so the answer has to be worked out — and the honest
     * default is the session this phone was last looking at here, which is nine
     * times out of ten the agent building the page being inspected.
     */
    var agentTarget: String? {
        get {
            let running = agentTargets
            if let chosen = chosenAgentTarget, running.contains(where: { $0.id == chosen }) { return chosen }
            if let remembered = UserDefaults.standard.string(forKey: lastOpenedKey),
               running.contains(where: { $0.id == remembered }) { return remembered }
            return running.first?.id
        }
        set { chosenAgentTarget = newValue }
    }

    private var chosenAgentTarget: String?

    /**
     * Type one line describing an element into a session on this machine.
     *
     * **No newline, ever.** `Inspect.composeSend` has already flattened the whole
     * thing to a single line for exactly this reason: a newline into a coding CLI
     * submits the prompt, and submitting on somebody's behalf because they
     * described a button is the app taking an action nobody asked for.
     *
     * Sent raw rather than through `paste`, deliberately: `paste` wraps text in
     * bracketed-paste markers, and this line has to be byte-identical to the one
     * the desktop hands the same agent.
     */
    @discardableResult
    func sendToAgent(_ line: String, into id: String) -> String {
        guard !line.isEmpty else { return "There was nothing to send." }
        guard let session = session(id) else { return "That session is not on \(label) any more." }
        guard connection.isLive else { return "Not connected — that did not reach \(label)." }

        if attached.contains(id) {
            sendInput(id, line)
            return "Sent to \(session.title)."
        }

        /*
         * The host refuses `input` for a session this device has not attached to
         * — `server.ts` answers it with `unauthorized` — so the attach comes
         * first and the line waits for the confirmation.
         *
         * The session stays attached afterwards rather than being detached
         * again. It is not a leak: the user just told an agent to change
         * something, and the next thing they will want is to watch it do that.
         */
        pendingAgentLines[id, default: []].append(line)
        attach(id)
        expireAgentLine(id)
        return "Opening \(session.title) to send it…"
    }

    /// Anything held for a session the host never confirmed. Twelve seconds is
    /// far longer than an attach takes and short enough that nobody is still
    /// waiting; the alternative is a line that silently never arrives.
    private func expireAgentLine(_ id: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.pendingAgentLines[id] != nil else { return }
            self.pendingAgentLines[id] = nil
            self.lastError = "That session did not open, so the change was not sent."
        }
    }

    private func flushAgentLines(_ id: String) {
        guard let lines = pendingAgentLines.removeValue(forKey: id) else { return }
        for line in lines { sendInput(id, line) }
    }

    // MARK: - Outbound

    private func sendInput(_ id: String, _ text: String) {
        guard !text.isEmpty else { return }
        for chunk in WireCodec.chunkInput(text) {
            guard transport?.send(.input(id: id, data: chunk)) == true else {
                bridges[id]?.note("not sent — \(connection.detail)")
                return
            }
        }
    }

    /**
     * A message typed in chat mode, written into the session's own pty.
     *
     * Chat mode is a different *view* of one session, not a second channel, so
     * this is the same door the keyboard uses and an answer typed here shows up
     * in the terminal view as well. There is no second transport to keep in
     * step and no message this app holds that the machine does not.
     *
     * ## Why it is two writes and not `text + "\r"`
     *
     * The CLI classifies each stdin chunk *before* it looks at the keys in it,
     * and a chunk of 64 bytes or more is **pasted text**, where a carriage
     * return is a newline rather than submit. Measured through a real pty
     * against 2.1.228 by the desktop's own composer: 57 bytes in one write
     * submits, 64 does not. A single write is therefore a send button that
     * silently does nothing for every message longer than about half a line —
     * the words appear in the agent's input box and sit there. So the return
     * travels as its own write, after a gap; 30 ms was the measured floor and
     * 50 leaves room for a slower machine while staying below anything a person
     * notices. `src/renderer/chat/attach/mentions.ts` holds the measurement.
     *
     * ## And why a trailing space when there is an `@` in it
     *
     * A mention at the end of the line leaves the CLI's completion popup open,
     * and the Enter that follows is swallowed by it — the popup accepts the
     * highlighted suggestion and replaces the whole line with a bare path.
     * Watched happen; the message was never sent. One trailing space closes it,
     * and it is free, because the CLI trims the line before it stores it.
     */
    func sendChatMessage(_ text: String, into id: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, connection.isLive else { return }
        sendInput(id, message.contains("@") ? message + " " : message)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.sendInput(id, "\r")
        }
    }

    private func sendResize(_ id: String, cols: Int, rows: Int) {
        guard attached.contains(id), TerminalSize(cols: cols, rows: rows) != nil else { return }
        transport?.send(.resize(id: id, cols: cols, rows: rows))
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Inbound

    private func handle(_ event: TransportEvent) {
        switch event {
        case let .state(state):
            let wasLive = connection.isLive
            connection = state
            // Every state, including the ones that change nothing on screen.
            // The rule is a function of the whole sequence, not of the
            // interesting parts of it — see `ConnectionGrace.unsettledSince`.
            notice.observe(state)
            onConnectionChange?(state)
            if !state.isLive && wasLive {
                attached.removeAll()
                // Nothing is attached any more, so there is nothing left to be
                // politely let go of. A timer left running would fire a `detach`
                // across the *next* connection for a session this phone might by
                // then be sitting in. See `leaveSession`.
                for (_, task) in leaving { task.cancel() }
                leaving.removeAll()
                for id in bridges.keys { bridges[id]?.note(state.detail) }
                for held in tunnels.values { held.connectionLost(state.detail) }
                tunnels.removeAll()
                lastTunnelPort = nil
                ports = []
                // Same reason the ports go: these rows are only true while
                // something is pushing them, and a spinner nobody is going to
                // update is a screen that lies about what the machine is doing.
                // They come back on the next `welcome`, which re-subscribes.
                devServers = [:]
                upload?.connectionLost(state.detail)
                // Its state and its pending questions, and nothing else. See
                // the header of `CopilotLink`: what was said and done survives a
                // drop because it happened; a countdown over a dead channel is a
                // lie with a clock on it.
                copilot.connectionLost()
                copilot.routinesConnectionLost()
                /*
                 * The figures go, the conversation stays.
                 *
                 * A ring and a context bar are claims about *now* and nothing
                 * over a dead socket will correct them; the bubbles are things
                 * that were said, which a dropped connection does not unsay.
                 * `dropped()` is that split — the same one `CopilotLink` makes
                 * between a countdown and a transcript.
                 */
                bar.dropped()
                // The reading is a claim about now too, and no dead socket will
                // correct it. The notice and the sheet the controls client holds
                // are this-connection state, so they go with it.
                controls.dropped()
            }
            if state.isLive && !wasLive {
                for id in wanted {
                    bridges[id]?.note("reconnected — replaying")
                    attach(id)
                }
                // Whatever the bar was showing was measured before the drop.
                // The re-attach above replays the terminal; this re-asks the
                // three questions behind the row over it.
                if let id = bar.sessionID { bar.follow(id) }
                // And the control cluster over the same session, for the same
                // reason: its subscription belonged to the connection that died.
                if let id = controls.sessionID { controls.follow(id) }
            }

        case let .credential(stored):
            credential = stored
            onCredential?(stored)

        case let .needsPairing(reason):
            transport = nil
            sessions = []
            attached = []
            onNeedsPairing?(reason)

        case let .message(message, activity):
            apply(message, activity: activity)
        }
    }

    private func apply(_ message: ServerMessage, activity: [String: Double]) {
        // A live tunnel gets first refusal. Byte frames are by far the chattiest
        // thing on this socket and they belong to one object.
        // Offered to every tunnel: a frame names its own channel and only the
        // tunnel holding it answers true, so this is a lookup rather than a
        // broadcast — and with one tab open it is the same single call it was.
        for held in tunnels.values where held.receive(message) { return }
        if upload?.receive(message) == true { return }

        switch message {
        case let .welcome(_, deviceId, _, _, list, capabilities, platform, name, folders, copilotConnection, appVersion, kind):
            sessions = list
            lastActivity = activity
            lastError = nil
            hostPlatform = platform
            thisDeviceId = deviceId
            // Recorded on every welcome, like the platform: a machine can be
            // updated between connections, and a stale version chip would name a
            // build that is no longer there.
            hostAppVersion = appVersion
            hostKind = kind
            /*
             * The machine's own name, recorded on every connection.
             *
             * Not only at pairing: a phone that learned the name once, off the
             * pairing link, has none for a machine paired before that field
             * existed — and the chip then reads a relay slot code, which names
             * nothing anybody owns. A nickname the person typed still wins over
             * it; see `StoredCredential.label`.
             *
             * Written through `onCredential`, which is the one writer to the
             * drawer, and through **this object's own** `credential` as well —
             * that second half is what makes the row redraw. It was left out of
             * the first version of this and the name only appeared after a
             * relaunch, because `label` reads the copy held here.
             *
             * Re-read from the drawer rather than composed from the copy held
             * here, for the reason `DeckModel` gives about its captured record:
             * the drawer has been written since this link was built — a
             * redemption mints a device credential over the pairing token — and
             * composing from a stale copy would put a spent pairing token back.
             */
            if let name {
                let held = credentials.load(id) ?? credential
                if held.hostName != name {
                    credential = held.hostNamed(name)
                    onCredential?(credential)
                }
            }
            granted = folders
            if capabilities.contains(WireCapability.localhost) { transport?.send(.ports) }
            /*
             * The copilot connection is **re-opened** on every welcome, for a
             * sharper version of the reason `askDevServers` is called on every
             * welcome: the desktop's subscription belongs to the connection this
             * frame arrived on, and its copilot access belongs to this *socket*.
             * `welcome.copilot.open` is always false, so what goes out of here
             * is a `copilot.hello` — not an `attach`, which would be refused.
             * The hello carries nothing: the device behind this socket proved
             * who it is at pairing time, and whether it is one of *his* devices
             * is what the desktop checks.
             *
             * The whole field goes in, not just the grant, because the thing
             * that matters most about it is whether it was there at all — the
             * desktop writes it only for a machine with a copilot and a device
             * approved as his, so its presence is the authorisation and its
             * absence is a guest. That is a different question from what the
             * capability list claims. See `CopilotConnection`.
             */
            copilot.welcomed(capabilities: capabilities, connection: copilotConnection)
            // And whether this machine offers its routines to this phone. Its
            // own call rather than a field on the one above, because they are
            // two capabilities and a machine can serve one without the other —
            // which is the whole reason `routines` has a name of its own.
            copilot.welcomed(routines: capabilities)
            // The same list, to the one other object that gates itself on it.
            // Replaced rather than merged on every welcome, because a device
            // that reconnects as a guest is handed a shorter one and a bar that
            // kept yesterday's names would ask questions this socket will not
            // answer.
            bar.welcomed(capabilities: capabilities)
            // The 0.10.0 clients, each replaced with the fresh list for the same
            // reason: a device that reconnects as a guest is handed a shorter one
            // and a screen that kept yesterday's names would offer controls this
            // socket will not answer. The settings, devices and watch clients
            // re-read on their next visit; the controls client re-follows below.
            controls.welcomed(capabilities: capabilities)
            serverSettings.welcomed(capabilities: capabilities)
            devices.welcomed(capabilities: capabilities)
            watch.welcomed(capabilities: capabilities)
            github.welcomed(capabilities: capabilities)
            hostControl.welcomed(capabilities: capabilities)
            // After `granted` is set, because the folders this asks about are
            // read from it — and on every welcome, because the desktop's
            // subscription belongs to the connection this welcome arrived on.
            askDevServers()
            // A welcome is by definition the first list on a new connection, so
            // whatever changed in it changed while this phone was not attached.
            onSessionsChanged?(sessions, .catchUp)

        case let .sessions(list):
            sessions = list
            if !activity.isEmpty { lastActivity = activity }
            onSessionsChanged?(sessions, .live)

        case let .folders(list):
            // Whole list, not a delta. A folder removed on the desktop stops
            // being offered here without a reconnect, which is the only way the
            // picker and the rule the Mac enforces can stay the same thing.
            granted = list
            /*
             * A folder that has just been taken away must lose its row, and it
             * must lose it here rather than by being filtered out at the point
             * of drawing.
             *
             * `devServerRows` does read through `devFolders`, so a dropped
             * folder does disappear from the screen either way — but the state
             * would still be sitting in this dictionary, and a folder that is
             * granted again a minute later would come back showing whatever it
             * was doing before it was revoked, with no `dev.status` yet sent to
             * say whether that is still true.
             */
            let keep = Set(list)
            devServers = devServers.filter { keep.contains($0.key) }
            // And a folder that has just been *added* has never been asked
            // about. Asking again for the ones already known costs one frame
            // each and re-subscribes them, which is harmless — the answer is
            // the state they are already showing.
            askDevServers()

        case let .fileRows(listing):
            fileListing = listing
            readError = nil

        case let .fileText(text):
            /*
             * Appended when this is a continuation, replaced when it is a fresh
             * read. `at` says which: a non-zero offset is the second screen of a
             * file somebody is already reading, and replacing there would send
             * them back to the top of a log they had scrolled into.
             */
            if text.at > 0, let held = fileText, held.path == text.path {
                fileText = FileText(path: text.path,
                                    text: held.text + text.text,
                                    at: text.at,
                                    truncated: text.truncated,
                                    binary: text.binary)
            } else {
                fileText = text
            }
            readError = nil

        case let .gitState(_, status):
            gitState = status
            readError = nil

        case let .gitPatch(path, file, staged, patch):
            gitPatch = GitPatch(path: path, file: file, staged: staged, patch: patch)
            readError = nil

        case let .browserProfileRows(list):
            machineProfiles = list

        case let .machineWindowRows(state):
            machineBrowser = state
            /*
             * And a pick that was in flight is over.
             *
             * This is the whole of *do not look like a hang*. Every refusal in
             * the pick family arrives here rather than as an error frame — *"This
             * machine's browser cannot point at one thing on a page."*, *"…has
             * scrolled since that picture — tap the same thing again."*, *"There
             * is nothing at that spot…"* — each of them as a `notice` on this
             * list, which the window screen already draws in its banner. What was
             * missing was ending the wait: without this the sentence appears at
             * the top of the screen while a *Reading the page…* line sits under
             * it for ever, and the person reads the second one.
             *
             * The element already on screen is deliberately **not** cleared. A
             * list arrives for reasons that have nothing to do with inspecting —
             * somebody at the machine opening a tab, a session binding a window —
             * and taking the sheet away under a thumb because an unrelated row
             * moved would be worse than leaving it.
             */
            pickingIn = nil

        case let .machineWindowPicked(id, element):
            machinePicked = MachinePickResult(window: id, element: element)
            pickingIn = nil

        case let .machineShot(shot):
            machineShot = shot

        case let .machineRecordRows(id, steps):
            machineSteps[id] = steps

        case let .panelRows(data):
            panels[data.panel] = data
            readError = nil

        case let .folderEntries(path, parent, entries):
            /*
             * One folder's contents, for the picker that is open on it.
             *
             * Dropped when nothing is browsing, and dropped when the answer is
             * for a folder the picker has already left. Somebody who taps two
             * rows quickly has two asks in flight, and without this the slower
             * first answer lands last and the screen walks backwards under the
             * thumb. `browsing` is what the picker asked for most recently, so
             * comparing against it is comparing against what is on screen.
             */
            // Empty means the picker asked for the machine's own choice and has
            // no path to compare against, so whatever came back is the answer.
            guard let wanted = browsing, wanted.isEmpty || wanted == path else { break }
            browsing = path
            browsed = FolderListing(path: path, parent: parent, entries: entries)
            browseError = nil

        case let .created(session):
            if !sessions.contains(where: { $0.id == session.id }) { sessions.append(session) }
            if !activity.isEmpty { lastActivity.merge(activity) { _, new in new } }
            lastError = nil
            if openWhenCreated {
                openWhenCreated = false
                onCreated?(session.id)
            }
            onSessionsChanged?(sessions, .live)

        case let .closed(id):
            /*
             * The machine has ended the session this phone asked it to end.
             *
             * Removed here, on the answer, and never on the tap — see
             * `closeSession`. Everything this phone was holding *about* that
             * session goes with the row: the subscription, so a stale attach
             * cannot be re-sent on the next reconnect, and the terminal bridge,
             * so its last paint is not sitting under a keyboard on the next
             * screen that asks for it.
             */
            sessions.removeAll { $0.id == id }
            lastActivity.removeValue(forKey: id)
            attached.remove(id)
            wanted.remove(id)
            bridges.removeValue(forKey: id)
            lastError = nil
            onSessionsChanged?(sessions, .live)
            // A restart that was waiting on exactly this close now has its folder
            // to itself — see `restartSession`. Cleared before the create so a
            // second `closed` cannot start a second session.
            if let pending = restartAfterClose, pending.id == id {
                restartAfterClose = nil
                createSession(in: pending.folder)
            }

        case .webOpened:
            /*
             * The page is open over there, and there is nothing on this screen
             * to change.
             *
             * Deliberately not a banner. The confirmation is the *machine* — a
             * tab appearing on the screen the person is looking at, or about to
             * walk over to — and a phone announcing what a desktop just did is
             * the app narrating itself. A failure is a plain `error` and does
             * get said, in the line below, which is the asymmetry that matters:
             * silence means it worked.
             */
            break

        case let .attached(id):
            attached.insert(id)
            wanted.insert(id)
            bridges[id]?.clear()
            // Everything after this frame is the session's history arriving in
            // pieces, so the screen is held until it has all landed and shown
            // once, at the bottom. `TerminalBackfill` carries the argument.
            bridges[id]?.holdForBacklog()
            if let size = bridges[id]?.size {
                transport?.send(.resize(id: id, cols: size.cols, rows: size.rows))
            }
            // A line from inspect mode that was waiting for exactly this. Sent
            // after the resize so the agent's prompt box is already the right
            // width when the text lands in it.
            flushAgentLines(id)

        case let .detached(id):
            attached.remove(id)

        case let .output(id, data, replay):
            bridges[id]?.feed(data, replay: replay)
            /*
             * The session is printing, so its context window is moving and its
             * transcript is growing.
             *
             * Not the replay: a backlog is history arriving, not the agent
             * writing, and asking after every frame of it would be one round
             * trip per screenful of scrollback for a figure that was already
             * true when the attach went out.
             */
            if !replay, id == bar.sessionID { bar.noteOutput() }
            // The same event drives the control cluster: the model line, the
            // effort confirmation and the permission footer are all read from
            // what the far pty writes, and from nothing else.
            if !replay, id == controls.sessionID { controls.noteOutput() }

        case let .status(id, status):
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            let old = sessions[index]
            sessions[index] = RemoteSession(id: old.id, title: old.title, cwd: old.cwd,
                                            provider: old.provider, status: status, exitCode: old.exitCode)
            // The frame that carries most of the alerts: `working` → `waiting`
            // is a desktop saying an agent has stopped and wants somebody.
            onSessionsChanged?(sessions, .live)

        case let .exit(id, code):
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                let old = sessions[index]
                sessions[index] = RemoteSession(id: old.id, title: old.title, cwd: old.cwd,
                                                provider: old.provider, status: "exited", exitCode: code)
                onSessionsChanged?(sessions, .live)
            }
            bridges[id]?.note("session exited with code \(code)")

        case let .error(code, text):
            lastError = text.isEmpty ? code.rawValue : text
            openWhenCreated = false
            // A refused `copilot.hello` comes back as a plain `error` — the
            // sentence is the desktop's and it is already on screen in the
            // banner above, so all this does is stop the copilot screen saying
            // *opening…* over it. The wire's error frame carries no correlation
            // id, so this cannot be narrowed to copilot errors without inventing
            // one; see `CopilotLink.wireErrored`.
            copilot.wireErrored()
            // And a picker waiting on an answer stops waiting. The wire carries
            // no correlation id, so an error that arrived while a browse was in
            // flight is treated as that browse's — the same assumption the
            // copilot line above makes, and the cost of being wrong is one
            // sentence on a screen that is already showing the banner.
            if browsing != nil {
                browseError = text.isEmpty ? code.rawValue : text
                browsed = nil
            }
            // And the same for a handover answer in flight. `WatchLink` is the
            // one that knows whether there was one, and it does nothing at all
            // when there was not — so this is not a third guess piled on the two
            // above, it is the same guess made only in the window where it is
            // the likeliest reading: a claim on a page the agent is blocked on,
            // and an error arriving in the same breath.
            watch.wireErrored(text)

        case let .ports(list):
            ports = list

        case let .devState(report):
            /*
             * Replace. Never merge.
             *
             * A subscript assignment of a whole value is the entire enforcement
             * of the rule, and it is written as one line on purpose: anything
             * that reached in to update a field would be the merge the protocol
             * warns about, and would leave a `ready` row's `url` under a
             * `starting` or a `failed` that has no address at all.
             *
             * Idempotent by construction, which the wire requires: a `dev.start`
             * is answered directly *and* pushed, so the same state arrives
             * twice. Writing it twice costs nothing.
             */
            devServers[report.folder] = report

        case .githubState, .githubChanged:
            // The host's GitHub login, read and driven by `GitHubLink`. It checks
            // the rid on a state and takes a changed push as-is, so an answer to a
            // question it did not ask is dropped and an unsolicited change lands.
            github.receive(message)

        case .hostState:
            // The host's own lifecycle over the relay, driven by `HostControlLink`.
            // It matches the rid, so an answer to a question it did not ask is
            // dropped. "The relay is the network" — this is the status a server
            // page shows when its SSH address is offline, and the answer to a
            // restart/stop it sent over the relay.
            hostControl.receive(message)

        case .tunnelOpened, .tunnelClosed, .netData, .netAck, .netClose:
            break

        case .uploadReady, .uploadAck, .uploadDone, .uploadFailed:
            break

        /*
         * The copilot frames, forwarded one for one.
         *
         * Forwarded here rather than given first refusal above the switch, the
         * way the tunnel and the upload are. Those two get first refusal because
         * they are the chattiest thing on this socket by an order of magnitude
         * and every byte frame belongs to one object; these are seven frames
         * that arrive at human speed, and routing them through the switch means
         * the compiler still checks that every message this app can receive has
         * somewhere to go.
         */
        case let .copilotState(state):
            copilot.apply(state: state)

        case let .copilotChat(run, messages, reset):
            copilot.apply(chat: run, messages: messages, reset: reset)

        case let .copilotTool(row):
            copilot.apply(tool: row)

        case let .copilotSessions(rows):
            copilot.apply(sessions: rows)

        case let .copilotLog(rows, more):
            copilot.apply(log: rows, more: more)

        case let .copilotPending(questions):
            copilot.apply(pending: questions)

        case let .copilotGrant(connection):
            // Chiefly the answer to `copilot.hello` — the frame carrying
            // `open: true`. It is also how this end learns, without waiting for
            // a reconnect, that the device has stopped being one of his: the
            // frame carries `linked: false`, and the tab goes. The *rule* is
            // already live either way, because the desktop re-reads the store on
            // every call; all this does is stop the phone offering a control
            // whose only outcome is a refusal.
            //
            // `pushed` rather than the plain `apply`, because a connection that
            // arrives as a frame is also proof this machine has a copilot, and
            // the same object arriving inside a `welcome` is not.
            copilot.apply(pushed: connection)
            // The same push takes the routines away, because the machine asks
            // one question about this device's kind for both. Only ever takes:
            // whether it *has* routines is the capability list's answer.
            copilot.routinesGrantChanged(linked: connection.linked)

        case let .copilotAsk(question):
            copilot.apply(ask: question)

        case let .copilotSettled(settled):
            copilot.apply(settled: settled)

        /*
         * The routines, forwarded the same way and to the same object.
         *
         * Two frames at human speed, so they go through the switch like the
         * copilot's own — which is what keeps the compiler checking that every
         * message this app can receive has somewhere to go.
         */
        case let .routineRows(rows, notice):
            copilot.apply(routines: rows, notice: notice)

        case let .routineFile(file):
            copilot.apply(routineFile: file)

        case let .copilotFiles(rows):
            copilot.apply(files: rows)

        case let .copilotFileText(id, text, error):
            // The id is carried through rather than dropped here: `CopilotLink`
            // uses it to throw away a read for a file that is no longer the one
            // open, which is the case where a person would otherwise be editing
            // one file believing they were editing another.
            copilot.apply(fileText: id, text: text, error: error)

        case .usageReading, .accountState, .accountSwitched:
            // Everything about which answer belongs to which question is the
            // bar's, because `rid` is minted there. It drops an answer to a
            // question it did not ask, and an answer about a session that is no
            // longer on screen.
            bar.receive(message)

        case .controlsReading, .controlsApplied:
            // The control cluster over whichever session is on screen. It checks
            // the rid and the session id, so an answer to a question it did not
            // ask, or one about another session, is dropped.
            controls.receive(message)

        case .settingsState, .settingsApplied, .settingsChanged:
            serverSettings.receive(message)

        case .devicesRows, .devicesRevoked, .devicesChanged:
            devices.receive(message)

        case .browserFrame, .browserSurfaces, .browserHandover:
            watch.receive(message)

        case .enrolled:
            // A pre-authentication frame that only belongs to a sign-in in
            // flight, driven by `SignIn` over the connecting socket — never on an
            // established connection. Ignored here rather than acted on.
            break

        case .pong:
            break
        }
    }
}

/// See `HostLink.wire`. One class for all three protocols, because they ask for
/// the same single method and a second identical proxy would be a second thing
/// to keep in step. The protocols stay separate types even so: what a tunnel may
/// send and what a copilot may send are different sets, and one protocol shared
/// by all of them would be the general "send this frame" seam a view could
/// reach — which is the thing `HostLink.answer` is written not to be.
@MainActor
final class WireProxy: TunnelWire, UploadWire, CopilotWire {
    private let deliver: (ClientMessage) -> Bool

    init(_ deliver: @escaping (ClientMessage) -> Bool) {
        self.deliver = deliver
    }

    func send(_ message: ClientMessage) -> Bool {
        deliver(message)
    }
}
