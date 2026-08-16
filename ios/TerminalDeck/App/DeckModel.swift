/**
 * Every machine this phone is paired with, which one is on screen, and the
 * pairing flow that adds another.
 *
 * The per-machine half of this used to live here and is now `HostLink` — one per
 * paired Mac or Windows PC, each with its own socket, its own sealed channel and
 * its own sessions. What is left is the collection, the switcher, and the small
 * set of things that are genuinely about the phone rather than about a machine:
 * the device key, the navigation stack, and pairing.
 *
 * ## Pairing ADDS a host. It never replaces one.
 *
 * This is the single most important line in the file. The failure mode to design
 * against is not "multi-host does not work" — it is a phone that pairs with a
 * second machine and silently drops the first, which to the person holding it
 * looks exactly like *my phone forgot my Mac*. So `pair` writes one new record
 * into a collection keyed by host id, and the only things that remove a record
 * are the user asking and the host refusing the credential outright.
 *
 * ## Everything stays connected
 *
 * Not connect-on-switch. Every paired machine holds its socket from launch, which
 * buys two things worth the cost: the switcher shows *live* status for machines
 * that are not on screen — the point of having more than one is knowing which of
 * them is busy — and switching is instant rather than a handshake. The cost is
 * one keepalive per socket, folded into a single app-wide tick so that N machines
 * cost one radio wake-up rather than N. See `Heartbeat` and
 * `docs/multi-host-battery.md`.
 *
 * ## The facade
 *
 * Most properties here forward to `current`. That is deliberate rather than lazy:
 * the screens were written against a single host and none of them should have to
 * learn about the collection to draw a session list. What a screen must never do
 * is hold a `HostLink` across a switch, so the forwarding reads `current` every
 * time rather than handing one out.
 */

import Foundation
import Observation

@MainActor
@Observable
final class DeckModel {

    /// Every paired machine, in the order they were paired. Never reordered:
    /// a switcher that reshuffles itself is one people tap the wrong row in.
    private(set) var hosts: [HostLink] = []
    /// Which machine the screens are showing. Nil only when nothing is paired.
    private(set) var currentHostId: String?

    /// The navigation stack. `RootView` binds to it, and a deep link pushes onto it.
    var route: [Route] = []

    /**
     * Which tab is on screen.
     *
     * On the model rather than in `@State` on the tab view, because two things
     * that are not the tab bar have to be able to change it: a deep link, and a
     * notification tap, both of which arrive as a session to open and must land
     * on the tab that can show a session. A `@State` selection would leave the
     * app on Settings with a terminal pushed onto a stack nobody is looking at.
     */
    var tab: Tab = .sessions

    /**
     * The three surfaces this phone genuinely has.
     *
     * Deliberately three, and the omissions are the design. The desktop's
     * sidebar has ten entries; most of them are a file tree, a diff view or a
     * search box, and a tab leading to any of those on a phone would be a tab
     * leading to a placeholder — which is worse than not having the tab, because
     * it is a promise the app cannot keep. What is here is what is written and
     * proved: the sessions on a machine, the machines themselves, and the two
     * app-wide settings that already exist behind a menu nobody finds.
     */
    enum Tab: Hashable {
        case sessions
        case machines
        case settings
    }

    /// Whether the "pair another machine" sheet is up. A flag rather than a
    /// route, because it can be raised from the switcher on any screen.
    var addingHost = false

    /**
     * Whether the rename alert is up, and what is typed in it.
     *
     * Two plain properties rather than one optional, and both on the model rather
     * than in `SessionListView`, because of how this failed. An `@State` optional
     * behind a *computed* `Binding` — `get: { value != nil }` — was dismissed
     * within a second of appearing: every paired machine holds a socket, so this
     * model publishes constantly, and each rebuild ran that binding's setter and
     * nilled the value out from under the presentation. The symptom read as
     * Rename simply not working.
     *
     * `addingHost` next door never had the problem because it is a `Bool` behind
     * a real `@Bindable` projection. This is the same shape, for the same reason,
     * and the alert is presented from `RootView` — which does not get rebuilt —
     * rather than from the list.
     */
    var renamingHost = false
    var renameText = ""

    /**
     * Which machine the rename alert is about.
     *
     * Named rather than assumed to be `current`, because the Machines tab renames
     * a row — and a row is very often not the machine on screen. Renaming the
     * wrong computer is the sort of thing that is only noticed a week later, when
     * somebody taps the machine labelled "Work PC" and gets their Mac.
     */
    private(set) var renamingHostId: String?

    /// Raise the rename alert for the machine on screen.
    func beginRename() {
        guard let current else { return }
        beginRename(current.id)
    }

    /// Raise the rename alert for one named machine.
    func beginRename(_ hostId: String) {
        guard let host = host(hostId) else { return }
        renamingHostId = hostId
        renameText = host.label
        renamingHost = true
    }

    /// Commit whatever is in `renameText` to the machine the alert was raised for.
    func commitRename() {
        if let id = renamingHostId ?? current?.id { rename(id, to: renameText) }
        renamingHostId = nil
        renamingHost = false
    }

    /// Take the alert down without writing anything. The id goes with it, so a
    /// later Save cannot land on a machine somebody cancelled out of.
    func cancelRename() {
        renamingHostId = nil
        renamingHost = false
    }

    /// Why the app is at the pairing screen, when it did not start there.
    private(set) var pairingNotice: String?
    /// Set while a pairing code is being redeemed, so the button can say so.
    private(set) var isPairing = false
    /**
     * Set only while the *lookup* is in flight, and it is not the same thing as
     * `isPairing`.
     *
     * `isPairing` covers the whole ceremony and is cleared by the transport when
     * the connection settles, which is right for a spinner and wrong for a
     * re-entrancy guard: a machine that never settles would leave `isPairing`
     * true forever and refuse every later attempt to pair anything. This one is
     * cleared the moment the rendezvous answers, so double-tapping Pair cannot
     * start two lookups and typing a second code after a failure always works.
     */
    private var lookingUp = false
    /// A sentence about the collection rather than about one machine — a pairing
    /// that was refused, a record that could not be read.
    private(set) var collectionError: String?

    private let credentials: CredentialStore
    private let device: DeviceDescriptor
    private let makeTransport: ((String, CredentialStore, DeviceDescriptor) -> Transport)?

    /**
     * Where six typed digits turn into an address.
     *
     * A closure rather than a `RendezvousLookup` so that a test — and the live
     * harness — can answer from a fixture instead of opening a WebSocket to the
     * public relay from whatever machine the suite runs on. It is the only seam
     * this model has for the network, and it is worth being a plain function
     * type: a protocol for one method would be three declarations for the same
     * substitution.
     */
    private let lookup: @MainActor (String) async -> MachineOffer?

    /* ------------------------------------------------------------------ */
    /* Alerts                                                             */
    /* ------------------------------------------------------------------ */

    /// What each machine's sessions were doing last time anything looked. The
    /// transitions out of it are the alerts.
    private let watcher = SessionAlerts()
    private let alerts: AlertPresenting

    /// Whether the app is on screen. Set by the scene, and read for exactly two
    /// decisions: whether the session being *looked at* should also interrupt
    /// with a banner, and whether a reconnect's catch-up is news or a summary.
    var isForeground = true

    /// What iOS says about notifications. Nil until it has been asked, which is
    /// a real state — the alerts screen must not claim "off" while it is still
    /// finding out.
    private(set) var alertPermission: AlertPermission?

    /**
     * The one line the list shows after the app has been away, or nil.
     *
     * This is the honest half of a feature that cannot promise delivery. A phone
     * that was suspended for an hour missed every transition in it; the next
     * connection brings the current state, and rather than firing four banners
     * about things that are already over — or saying nothing at all, which is
     * how people conclude the app is not watching — the list says what changed
     * while nobody was listening.
     */
    private(set) var awayReport: String?

    func dismissAwayReport() {
        awayReport = nil
    }

    /// Ask iOS what it thinks. Called when the app comes forward, because
    /// permission can be changed in Settings while this app is not running.
    func refreshAlertPermission() async {
        alertPermission = await alerts.permission()
    }

    /// The system prompt, from the one screen that asks for it.
    @discardableResult
    func requestAlertPermission() async -> AlertPermission {
        let answer = await alerts.request()
        alertPermission = answer
        return answer
    }

    /**
     * A machine's sessions changed. Decide what a person is told.
     *
     * Three rules, and each one exists because of a way this could be annoying
     * enough to be turned off:
     *
     *  1. **Not the session on screen.** Somebody watching a terminal does not
     *     need a banner over it saying the thing they are watching has
     *     happened. Only while the app is in front of them — the same session
     *     with the phone in a pocket is exactly what they want to be told about.
     *  2. **A catch-up while the app is open is a sentence, not four banners.**
     *     See `awayReport`.
     *  3. **The switches are honoured here** rather than at the point of
     *     posting, so there is one place that decides what is worth saying.
     */
    private func alertsChanged(_ host: HostLink, _ sessions: [RemoteSession], _ reason: AlertReason) {
        let raised = watcher.observe(hostId: host.id, hostName: host.label, sessions: sessions)
        let wanted = raised.filter { AlertSettings.wants($0.kind) && !isOnScreen($0) }
        guard !wanted.isEmpty else { return }

        if reason == .catchUp && isForeground {
            awayReport = AwayReport.sentence(for: wanted)
            return
        }
        for alert in wanted { alerts.present(alert) }
    }

    /// Whether this alert is about the session the person is already looking at.
    private func isOnScreen(_ alert: SessionAlert) -> Bool {
        guard isForeground, case let .session(host, id)? = route.last else { return false }
        return host == alert.hostId && id == alert.sessionId
    }

    /**
     * The GitHub account this phone holds, and the thing that answers with it.
     *
     * App-wide rather than per machine, and that is the shape of the feature
     * rather than a convenience: it is *one person's* GitHub, and the whole
     * point is that it stays here while they work on several other people's
     * computers. A per-machine account would be a token per machine, which is
     * the thing this exists to avoid.
     */
    private let gitHubAccounts: GitHubAccountStore
    let credentialResponder: CredentialResponder

    /// Whether something is covering the session list — today the localhost
    /// browser, which is a `fullScreenCover`. Read by `RootView` so its copy of
    /// the credential prompt stands down while the browser's copy is the one
    /// that can actually present. See `CredentialPromptHost`.
    var covered = false

    /// Whether the GitHub account sheet is up. A flag rather than a route,
    /// because it is raised from a menu that exists on every screen.
    var showingGitHub = false

    /// Whether the alerts sheet is up. Same shape and for the same reason.
    var showingAlerts = false

    /**
     * A route names the machine as well as the session.
     *
     * Session ids are unique per host and nothing guarantees they are unique
     * *across* hosts — they come from each machine's own session layer. A route
     * carrying only an id would attach to whichever machine happened to be
     * current when it was popped, which with two machines paired is a coin flip.
     */
    enum Route: Hashable {
        case session(host: String, id: String)
    }

    /// `makeTransport` is a seam for the tests, which drive this model against a
    /// scripted transport rather than a socket.
    init(credentials: CredentialStore,
         device: DeviceDescriptor,
         gitHubAccounts: GitHubAccountStore? = nil,
         alerts: AlertPresenting? = nil,
         lookup: (@MainActor (String) async -> MachineOffer?)? = nil,
         makeTransport: ((String, CredentialStore, DeviceDescriptor) -> Transport)? = nil) {
        self.credentials = credentials
        self.device = device
        // Defaulted here rather than in the signature for the same reason
        // `alerts` is: the real one dials a relay, and a default argument would
        // put that in every test that only wanted to construct a model.
        //
        // A fresh `RendezvousLookup` per call, deliberately. It holds one
        // socket's worth of state and nothing that outlives a lookup, so keeping
        // one around would only be a way for a cancelled attempt's carrier to
        // still be attached when the next one starts.
        self.lookup = lookup ?? { code in await RendezvousLookup().find(code: code) }
        // Defaulted here rather than in the signature so a test can hand in a
        // recorder and never touch `UNUserNotificationCenter` — which in a
        // simulator would put a permission prompt in front of a test run.
        self.alerts = alerts ?? NotificationAlerts()
        let accounts = gitHubAccounts ?? KeychainGitHubStore()
        self.gitHubAccounts = accounts
        self.credentialResponder = CredentialResponder(accounts: accounts)
        self.makeTransport = makeTransport
        // Wired after the stored properties, in the same shape `HostLink`'s
        // callbacks use: the two are mutually recursive and neither can name the
        // other in its initialiser.
        credentialResponder.route = { [weak self] hostId, answer in
            self?.host(hostId)?.answer(answer)
        }
        for record in credentials.all() { adopt(record) }
        currentHostId = restoredSelection ?? hosts.first?.id
    }

    // MARK: - The collection

    /// The machine the screens are showing, or nil when nothing is paired.
    var current: HostLink? {
        guard let currentHostId else { return hosts.first }
        return hosts.first { $0.id == currentHostId } ?? hosts.first
    }

    var isPaired: Bool { !hosts.isEmpty }

    /// Whether the switcher is worth drawing at all. One machine does not need a
    /// picker, and a picker with one row in it is furniture.
    var hasSeveralHosts: Bool { hosts.count > 1 }

    /**
     * Show a different machine.
     *
     * Nothing is connected or disconnected here: every host is already holding
     * its socket, which is the whole reason switching is instant. What does
     * change is the navigation stack — a terminal open on the machine being
     * switched away from is popped, because leaving it up would show one
     * machine's session under another machine's name.
     */
    func select(_ hostId: String) {
        guard hosts.contains(where: { $0.id == hostId }), hostId != currentHostId else { return }
        currentHostId = hostId
        UserDefaults.standard.set(hostId, forKey: Self.selectionKey)
        route.removeAll { route in
            if case let .session(host, _) = route { return host != hostId }
            return false
        }
    }

    func host(_ id: String) -> HostLink? {
        hosts.first { $0.id == id }
    }

    private static let selectionKey = "terminaldeck.currentHost.v1"

    private var restoredSelection: String? {
        guard let saved = UserDefaults.standard.string(forKey: Self.selectionKey),
              hosts.contains(where: { $0.id == saved }) else { return nil }
        return saved
    }

    /// Wire one stored record up as a live host. Idempotent by host id, which is
    /// what makes re-pairing with a machine already in the list an update rather
    /// than a duplicate row.
    @discardableResult
    private func adopt(_ record: StoredCredential) -> HostLink {
        if let existing = hosts.first(where: { $0.id == record.hostId }) { return existing }

        let link = HostLink(credential: record,
                            credentials: credentials,
                            device: device,
                            makeTransport: makeTransport)
        link.onCredential = { [weak self] stored in
            // One writer to the drawer. A link that saved for itself would be N
            // writers, and the bug that must not exist is a write for one host
            // landing on another.
            self?.credentials.save(stored)
        }
        link.onNeedsPairing = { [weak self] reason in
            self?.forget(record.hostId, because: reason)
        }
        link.onConnectionChange = { [weak self] state in
            // The redemption is over the moment the machine answers in any way at
            // all — connected, waiting, pending approval, refused. `.connecting`
            // is the one state that means it is still in flight.
            if state.phase != .connecting && state.phase != .offline { self?.isPairing = false }
            // A machine that has gone cannot be answered, so its question comes
            // off the screen rather than staying up as buttons that reach
            // nothing. The desktop has already settled it for the same reason.
            if !state.isLive { self?.credentialResponder.machineLost(record.hostId) }
        }
        link.onCredentialRequest = { [weak self] request in
            self?.credentialResponder.receive(request)
        }
        link.onCreated = { [weak self] sessionId in
            self?.open(session: sessionId, on: record.hostId)
        }
        link.onSessionsChanged = { [weak self, weak link] sessions, reason in
            guard let self, let link else { return }
            alertsChanged(link, sessions, reason)
        }
        hosts.append(link)
        return link
    }

    // MARK: - Lifecycle

    /**
     * Bring every paired machine up.
     *
     * All of them, not just the one on screen. A switcher that shows "offline"
     * for every machine except the current one would be showing the *app's*
     * state rather than the machines', which is the opposite of why anybody
     * would want more than one.
     */
    func start() {
        for host in hosts { host.start() }
    }

    /// The app came back to the foreground, or the network changed. The pending
    /// backoff on every machine is describing a condition that has already ended.
    func resume() {
        // Realigned first, so the reconnects that follow settle onto one shared
        // tick instead of each machine keeping whatever phase it had.
        Heartbeat.shared.realign()
        for host in hosts { host.resume() }
    }

    func refresh() {
        current?.refresh()
    }

    /// Refresh everything — pulled to refresh on the switcher, where the list
    /// being looked at is the list of machines.
    func refreshAll() {
        for host in hosts { host.refresh() }
    }

    // MARK: - Pairing

    /// This phone's own fingerprint, for the approval prompt on the machine.
    /// One key for every host: see `CredentialStore`.
    var deviceFingerprint: String {
        sealedFingerprint(credentials.deviceKeys().publicKey)
    }

    var deviceName: String { device.name }

    /**
     * Redeem a pairing code, **adding** a machine.
     *
     * ## Two steps, because six digits carry no address
     *
     *  1. **The rendezvous.** `Rendezvous.swift` explains it at length: the code
     *     names a slot at the relay, the machine showing the code is sitting in
     *     it, and the channel is Noise IK against a responder key both ends
     *     derive from the code. What comes back is an *address* and nothing else.
     *  2. **The pairing itself.** With the address in hand this is the path this
     *     app has always taken: dial the machine, run IK against its real key,
     *     and say `hello` with the code as the token. The far end redeems it,
     *     mints a credential, sends it back inside `welcome`, and then refuses
     *     the connection because a human still has to approve the device.
     *
     * The code's own text is stored as the credential straight away, marked
     * `.pairing`. That looks odd — it is a secret that is about to be spent — and
     * it is what makes the flow survive the app being killed halfway through: the
     * reconnect uses it, the host answers with the durable credential, and
     * `LiveTransport` swaps it in place. A token held only in memory would leave a
     * device that is paired on the machine and unpaired here.
     *
     * Pairing with a machine already in the list replaces *that machine's* record
     * and nothing else — a re-pair after a revoke is a normal thing to do, and it
     * must not cost the user their other machines.
     *
     * ## Why this is `async` and why `isPairing` is set before the first await
     *
     * The lookup is a memory-hard derivation and a round trip to a relay: about a
     * second between them, and every millisecond of it is a second where the only
     * thing on screen is a button. `isPairing` drives the spinner on that button,
     * so it goes up before the first suspension point rather than after it.
     */
    func pair(with rawCode: String) {
        Task { await pairAsync(with: rawCode) }
    }

    func pairAsync(with rawCode: String) async {
        pairingNotice = nil
        collectionError = nil
        // The *lookup*, not the pairing. See `lookingUp` for why the two are not
        // the same flag.
        guard !lookingUp else { return }

        let code: String
        switch PairingCodeParser.parse(rawCode) {
        case let .failure(error):
            pairingNotice = error.detail
            return
        case let .success(parsed):
            code = parsed
        }

        lookingUp = true
        isPairing = true
        /*
         * The sheet closes here, not at the call site.
         *
         * Every way in ends up on this line, and only this line knows the code
         * parsed. Closing from the caller left the sheet up forever after a
         * failure, with the button stuck on "Pairing…" over an app that had in
         * fact paired: the machine was added, connected and invisible, because a
         * modal was covering the list it had been added to.
         */
        addingHost = false

        let found = await lookup(code)
        lookingUp = false
        guard let offer = found else {
            isPairing = false
            pairingNotice =
                "No machine is showing that code. Check the digits, and that the code on the other " +
                "machine has not run out — they last a minute."
            return
        }

        let endpoint = offer.endpoint
        let hostId = endpoint.hostId
        let existing = credentials.load(hostId)
        let stored = StoredCredential(endpoint: endpoint,
                                      token: code,
                                      kind: .pairing,
                                      deviceId: "",
                                      deviceName: device.name,
                                      pairedAt: existing?.pairedAt ?? Date(),
                                      // A machine the user has already named
                                      // keeps its name through a re-pair.
                                      nickname: existing?.nickname)
        credentials.save(stored)

        if let link = hosts.first(where: { $0.id == hostId }) {
            // Same machine, new token. Torn down and brought back up so the
            // transport reads the credential that was just written rather than
            // retrying with the one that was refused.
            link.stop()
            link.start()
            select(hostId)
        } else {
            let link = adopt(stored)
            link.start()
            // The machine that was just paired is the one the user is looking
            // at. Anything else would be a pairing that appears to do nothing.
            currentHostId = hostId
            UserDefaults.standard.set(hostId, forKey: Self.selectionKey)
        }
    }

    /**
     * Forget one machine.
     *
     * Deliberately not "log out": the device key survives, so pairing with the
     * same machine again does not create a second entry in its device list for
     * one physical phone. Every *other* machine is untouched — that is the whole
     * point, and it is why this takes an id rather than being a global reset.
     */
    func unpair(_ hostId: String) {
        forget(hostId, because: nil)
    }

    /// The one the screens are showing. What the overflow menu calls.
    func unpairCurrent() {
        guard let id = current?.id else { return }
        unpair(id)
    }

    private func forget(_ hostId: String, because reason: String?) {
        guard let index = hosts.firstIndex(where: { $0.id == hostId }) else { return }
        let link = hosts[index]
        let name = link.label
        link.stop()
        hosts.remove(at: index)
        credentials.remove(hostId)
        // Its sessions are not going to change again. Keeping them would make a
        // later re-pair look like a machine where everything happened at once.
        watcher.forget(hostId: hostId)
        route.removeAll { route in
            if case let .session(host, _) = route { return host == hostId }
            return false
        }
        if currentHostId == hostId {
            currentHostId = hosts.first?.id
            if let next = currentHostId {
                UserDefaults.standard.set(next, forKey: Self.selectionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectionKey)
            }
        }
        isPairing = false
        if let reason {
            // Named, because with several machines paired "the desktop refused
            // this device" does not say *which* desktop — and the user is about
            // to be asked to scan a code on one of them.
            let sentence = "\(name): \(reason)"
            if hosts.isEmpty { pairingNotice = sentence } else { collectionError = sentence }
        }
    }

    /// Give a machine a name a person can pick out of a list.
    func rename(_ hostId: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        host(hostId)?.rename(trimmed?.isEmpty == true ? nil : trimmed)
    }

    func dismissCollectionError() {
        collectionError = nil
    }

    // MARK: - GitHub, and the questions machines ask about it

    /// The account the approval prompt names, or nil. Never the token — nothing
    /// on screen holds that.
    var gitHubAccount: GitHubAccount? { credentialResponder.account }

    /// The question on screen, if a machine is waiting on an answer.
    var credentialPrompt: CredentialRequest? { credentialResponder.asking }

    func approveCredential(remember: Bool) { credentialResponder.approve(remember: remember) }
    func denyCredential() { credentialResponder.deny() }

    /**
     * Forget the GitHub account.
     *
     * The revocation that works from this end, and it is total by design: with
     * no token here, nothing on this phone can answer a credential request from
     * any machine. Approvals a machine is holding are a *scope* rather than a
     * secret — every push still comes back here — so removing the secret removes
     * what they were scoping.
     */
    func disconnectGitHub() {
        gitHubAccounts.disconnect()
    }

    /// A sign-in flow for the account screen. Made here so the screen never
    /// builds its own store and cannot end up writing to a second drawer.
    func makeGitHubSignIn() -> GitHubSignIn {
        GitHubSignIn(accounts: gitHubAccounts)
    }

    // MARK: - Navigation

    func open(session id: String, on hostId: String? = nil) {
        guard SessionID.isValid(id) else { return }
        let host = hostId ?? currentHostId
        guard let host, hosts.contains(where: { $0.id == host }) else { return }
        if host != currentHostId { select(host) }
        // The stack this route is pushed onto belongs to one tab. A session
        // opened from a notification tap, a deep link or the Machines tab while
        // another tab is showing would otherwise be pushed somewhere nobody is
        // looking, which reads as the tap having done nothing.
        tab = .sessions
        let next = Route.session(host: host, id: id)
        if route.last != next { route.append(next) }
    }

    /**
     * `terminaldeck://session/<id>`.
     *
     * A session link carries no machine, because the desktop that writes one has
     * no idea the phone is paired with anything else. So the machine is worked
     * out from the id: whichever paired host is currently listing that session.
     * Falling back to "the current one" would open the wrong machine's session
     * list and attach to an id it has never heard of.
     *
     * `terminaldeck://pair?…` used to arrive here too, from a QR code the camera
     * had just read. It is gone: a link is a live pairing token in a string that
     * any app registered for the scheme could be handed, and pairing is now six
     * digits somebody types. The scheme itself stays, because a session link is a
     * different feature and carries no secret — an id the desktop already knows
     * the phone can see.
     */
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == Brand.id else { return }
        let parts = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
        guard let first = parts.first?.lowercased() else { return }

        guard first == "session", parts.count >= 2 else { return }
        let id = parts[1]
        let owner = hosts.first { $0.session(id) != nil }?.id
        open(session: id, on: owner)
    }

    // MARK: - Facade over the current machine

    var connection: ConnectionState { current?.connection ?? .offline }
    /// Whether the connection is worth drawing at all. See `ConnectionGrace`:
    /// connected says nothing, and a drop says nothing for its first five
    /// seconds. Every screen that draws a pill or a warning bar reads this
    /// rather than `connection.isLive`.
    var showsConnectionNotice: Bool { current?.notice.isShowing ?? false }
    var sessions: [RemoteSession] { current?.sessions ?? [] }
    var lastActivity: [String: Double] { current?.lastActivity ?? [:] }
    var ports: [LocalPort] { current?.ports ?? [] }
    var upload: FileUpload? { current?.upload }
    /// The Resume row, and only while the list is what is on screen — offering
    /// to resume the session already open under it would be a row that does
    /// nothing.
    var resumable: RemoteSession? { route.isEmpty ? current?.resumable : nil }
    var canCreateSessions: Bool { current?.canCreateSessions ?? false }
    /// Whether there is anywhere to start one. See `HostLink.canStartSomewhere`:
    /// a machine can be perfectly able to start a session and still have granted
    /// this phone no folder to start it in.
    var canStartSomewhere: Bool { current?.canStartSomewhere ?? false }
    /// True only when the machine explicitly granted this device nothing —
    /// which is the one case worth a sentence on screen, because it is the only
    /// one a person can fix, and they fix it on the desktop.
    var hasNoGrantedFolders: Bool { current?.granted?.isEmpty == true }
    var canBrowseLocalhost: Bool { current?.canBrowseLocalhost ?? false }
    /// Whether this machine will discuss its projects' dev servers. A separate
    /// question from `canBrowseLocalhost` — see `HostLink.canUseDevServers`.
    var canUseDevServers: Bool { current?.canUseDevServers ?? false }
    /// The dev-server rows worth drawing, in the order the machine offered its
    /// folders. Folders with no dev script are already out; see
    /// `HostLink.devServerRows`.
    var devServers: [DevServerReport] { current?.devServerRows ?? [] }
    /// The machine currently selected, for screens that name it. `.unknown`
    /// with no host selected, which reads as a neutral noun rather than a guess.
    var hostPlatform: HostPlatform { current?.hostPlatform ?? .unknown }
    var canSendFiles: Bool { current?.canSendFiles ?? false }
    var startableFolders: [String] { current?.startableFolders ?? [] }
    var endpointSummary: String? { current?.endpointSummary }
    var agentTargets: [RemoteSession] { current?.agentTargets ?? [] }

    /// The one-line error under the banner: whichever of the two is set. The
    /// machine's own comes first, because it is the one about what just happened.
    var lastError: String? { current?.lastError ?? collectionError }

    var agentTarget: String? {
        get { current?.agentTarget }
        set { current?.agentTarget = newValue }
    }

    func session(_ id: String) -> RemoteSession? { current?.session(id) }
    func bridge(for id: String) -> TerminalBridge {
        current?.bridge(for: id) ?? TerminalBridge()
    }

    func attach(_ id: String) { current?.attach(id) }
    func detach(_ id: String) { current?.detach(id) }
    func reattach(_ id: String) { current?.reattach(id) }
    func createSession(in folder: String?) { current?.createSession(in: folder) }
    func openLocalhost(port: Int) -> PortTunnel? { current?.openLocalhost(port: port) }
    func closeLocalhost() { current?.closeLocalhost() }
    /// One project's dev server on the machine on screen, or nil when it has not
    /// been asked about — a folder past the subscription cap, or a machine that
    /// does not offer the capability at all.
    func devServer(for folder: String) -> DevServerReport? { current?.devServer(for: folder) }
    /// **The tap is the consent.** Nothing runs on the machine because of this
    /// feature until this is called. See `HostLink.startDevServer`.
    func startDevServer(in folder: String) { current?.startDevServer(in: folder) }
    func paste(into id: String) { current?.paste(into: id) }

    @discardableResult
    func copy(from id: String) -> String { current?.copy(from: id) ?? "Nothing to copy." }

    @discardableResult
    func copyScreen(from id: String) -> String { current?.copyScreen(from: id) ?? "Nothing to copy." }

    func send(_ file: PickedFile, into sessionID: String) { current?.send(file, into: sessionID) }
    func clearUpload() { current?.clearUpload() }

    @discardableResult
    func sendToAgent(_ line: String, into id: String) -> String {
        current?.sendToAgent(line, into: id) ?? "No machine is selected."
    }

    func dismissError() {
        current?.dismissError()
        collectionError = nil
    }
}
