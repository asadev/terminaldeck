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

    /// Whether the "pair another machine" sheet is up. A flag rather than a
    /// route, because it can be raised from the switcher on any screen.
    var addingHost = false

    /**
     * The name being typed into the rename alert, or nil when it is not up.
     *
     * Here rather than in `SessionListView`'s `@State`, and that is a fix rather
     * than a preference. Every paired machine holds a socket, so this model
     * publishes on any of them changing — a reconnect, a session list, a port
     * scan — and a `@State` on a view SwiftUI rebuilds goes back to nil, taking
     * the alert with it. The symptom was not a reset field: the alert appeared
     * and vanished inside the same second, which reads as Rename not working at
     * all. It survives here because the model does.
     */
    var renamingTo: String?

    /// Why the app is at the pairing screen, when it did not start there.
    private(set) var pairingNotice: String?
    /// Set while a pairing code is being redeemed, so the button can say so.
    private(set) var isPairing = false
    /// A sentence about the collection rather than about one machine — a pairing
    /// that was refused, a record that could not be read.
    private(set) var collectionError: String?

    private let credentials: CredentialStore
    private let device: DeviceDescriptor
    private let makeTransport: ((String, CredentialStore, DeviceDescriptor) -> Transport)?

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
         makeTransport: ((String, CredentialStore, DeviceDescriptor) -> Transport)? = nil) {
        self.credentials = credentials
        self.device = device
        self.makeTransport = makeTransport
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
        }
        link.onCreated = { [weak self] sessionId in
            self?.open(session: sessionId, on: record.hostId)
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
     * The code's token is stored as the credential straight away, marked
     * `.pairing`. That looks odd — it is a secret that is about to be spent — and
     * it is what makes the flow survive the app being killed halfway through: the
     * reconnect uses it, the host answers with the durable credential, and
     * `LiveTransport` swaps it in place. A token held only in memory would leave a
     * device that is paired on the machine and unpaired here.
     *
     * Pairing with a machine already in the list replaces *that machine's* record
     * and nothing else — a re-pair after a revoke is a normal thing to do, and it
     * must not cost the user their other machines.
     */
    func pair(with rawCode: String) {
        pairingNotice = nil
        collectionError = nil
        switch PairingCodeParser.parse(rawCode) {
        case let .failure(error):
            pairingNotice = error.detail
        case let .success(code):
            isPairing = true
            /*
             * The sheet closes here, not at the call site.
             *
             * Both ways in — the camera and the pasted link — end up on this
             * line, and only this line knows the code actually parsed. Closing
             * from the QR callback alone left the sheet up forever after a
             * paste, with the button stuck on "Pairing…" over an app that had in
             * fact paired: the machine was added, connected and invisible,
             * because a modal was covering the list it had been added to.
             */
            addingHost = false
            let hostId = code.endpoint.hostId
            let existing = credentials.load(hostId)
            let stored = StoredCredential(endpoint: code.endpoint,
                                          token: code.token,
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
                // transport reads the credential that was just written rather
                // than retrying with the one that was refused.
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

    // MARK: - Navigation

    func open(session id: String, on hostId: String? = nil) {
        guard SessionID.isValid(id) else { return }
        let host = hostId ?? currentHostId
        guard let host, hosts.contains(where: { $0.id == host }) else { return }
        if host != currentHostId { select(host) }
        let next = Route.session(host: host, id: id)
        if route.last != next { route.append(next) }
    }

    /**
     * `terminaldeck://session/<id>` and `terminaldeck://pair?…`.
     *
     * A session link carries no machine, because the desktop that writes one has
     * no idea the phone is paired with anything else. So the machine is worked
     * out from the id: whichever paired host is currently listing that session.
     * Falling back to "the current one" would open the wrong machine's session
     * list and attach to an id it has never heard of.
     */
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == Brand.id else { return }
        let parts = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
        guard let first = parts.first?.lowercased() else { return }

        if first == "pair" {
            pair(with: url.absoluteString)
            return
        }
        guard first == "session", parts.count >= 2 else { return }
        let id = parts[1]
        let owner = hosts.first { $0.session(id) != nil }?.id
        open(session: id, on: owner)
    }

    // MARK: - Facade over the current machine

    var connection: ConnectionState { current?.connection ?? .offline }
    var sessions: [RemoteSession] { current?.sessions ?? [] }
    var lastActivity: [String: Double] { current?.lastActivity ?? [:] }
    var ports: [LocalPort] { current?.ports ?? [] }
    var upload: FileUpload? { current?.upload }
    /// The Resume row, and only while the list is what is on screen — offering
    /// to resume the session already open under it would be a row that does
    /// nothing.
    var resumable: RemoteSession? { route.isEmpty ? current?.resumable : nil }
    var canCreateSessions: Bool { current?.canCreateSessions ?? false }
    var canBrowseLocalhost: Bool { current?.canBrowseLocalhost ?? false }
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
