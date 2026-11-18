import Foundation
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Reach by account on this Mac (Devices seat, R2): joins the in-app session host and the signed-in Cloud account
/// into ONE `BackendReachAccountCoordinator`. Built only when both exist. The switch ("Let my signed-in devices open this
/// Mac", on the Devices window only) is ON by default (owner, 13 Nov: sign in once and everything follows): a Mac that never
/// chose is switched on once, here; a choice the person made is kept, and a damaged settings file still reads as OFF.
@MainActor @Observable
final class NativeReachAccount {
    static let shared = NativeReachAccount()
    private(set) var status: BackendReachStatus?
    private(set) var busy = false
    private(set) var problem: String?
    /// The last notice, also shown on the page (banners may be switched off).
    private(set) var notice: String?
    @ObservationIgnored private(set) var coordinator: BackendReachAccountCoordinator?
    @ObservationIgnored private var host: (endpoint: BackendRemoteHost, card: @Sendable () async -> BackendReachPresence.HostCard?)?
    @ObservationIgnored private var account: BackendCloudAccount?
    @ObservationIgnored private let notices = BackendReachNoticeRelay()

    /// Remote access: the one way in for every device, the account's included (A1, MAC-NEXT-13). The switch must never
    /// read ON while this is closed, so whenever the switch is on (signed in, account has the feature) and it is not
    /// running, the app starts it by itself. Bound by the production composition; nil in tests and the boot helper.
    struct Door: Sendable {
        let status: @Sendable () async -> BackendRemoteHostStatus
        /// The same start as the old "Let approved devices in" press (`remote:start`): starts, and remembers it.
        let start: @Sendable () async throws -> Void
    }
    @ObservationIgnored private var door: Door?
    /// The app's own launch start of remote access has had its turn (afterSeal); nothing starts it before that.
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var startFailed = false
    @ObservationIgnored private var connectingSince: Double?
    @ObservationIgnored private var followUp: Task<Void, Never>?
    /// A failed start waits for its 30 s retry instead of starting again at once.
    @ObservationIgnored private var retryDue = false
    struct Remote: Equatable { let running: Bool; let relayConnected: Bool? }
    private(set) var remote: Remote?

    /// The switch as the Devices window shows it, with the door's real state under it.
    var devicesReach: DevicesPage.Reach {
        guard coordinator != nil, let status else { return .unknown }
        return .init(available: true, on: status.enabled, entitled: status.entitled, door: doorState(status),
                     connections: status.recent.map { .init(name: $0.label, atMs: $0.atMs, opened: $0.refused == nil) })
    }

    private func doorState(_ status: BackendReachStatus) -> DevicesPage.Door? {
        guard status.enabled, status.entitled == true, let remote else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        return DevicesPage.door(running: remote.running, startFailed: startFailed, published: status.presence == .published,
                                publishFailed: status.presence == .failed, relayConnected: remote.relayConnected,
                                connectingForMs: connectingSince.map { now - $0 } ?? 0)
    }

    init() {
        notices.listen { notice in Task { @MainActor in NativeReachAccount.shared.show(notice) } }
    }

    /// The in-app session host is up (production composition).
    func bindHost(_ endpoint: BackendRemoteHost, card: @escaping @Sendable () async -> BackendReachPresence.HostCard?, door: Door? = nil) {
        host = (endpoint, card)
        self.door = door
        assemble()
    }
    /// The launch start of remote access has run (or was skipped): from now on the switch keeps the door open.
    func launchSettled() {
        launched = true
        Task { await reload() }
    }
    /// Signed in (the Cloud composition exists).
    func bindAccount(_ account: BackendCloudAccount) {
        self.account = account
        assemble()
    }
    /// Signed out: nothing of reach stays reachable.
    func unbindAccount() {
        let oldAccount = account
        account = nil
        let old = coordinator; coordinator = nil; status = nil
        NativeReachLive.shared.signedOut()
        followUp?.cancel(); followUp = nil; connectingSince = nil; startFailed = false
        Task { await oldAccount?.setReachLink(nil) }
        if let old { Task { await old.setTrustLink(nil); await old.signedOut(); await old.stop() } }
    }

    private func assemble() {
        guard coordinator == nil, let host, let account else { return }
        let notices = self.notices
        Task {
            let identity = await account.identity
            let directory = await host.endpoint.trust.directory
            let service = BackendReachAccountHTTPService(base: identity.configuration.baseURL, http: BackendCloudAccountURLSession(),
                                                         account: .live(identity))
            let made = BackendReachAccountCoordinator(directory: directory, service: service, notices: notices,
                                                      host: host.endpoint, card: host.card)
            // Signed out or rebuilt while this was made: drop it.
            guard self.coordinator == nil, self.account === account else { return }
            coordinator = made
            // Live use from another Mac (15 Nov): this Mac reaches his other machines by the same sign-in, as a phone.
            NativeReachLive.shared.signedIn(BackendReachGuest(service: service, directory: directory,
                                                              relayURL: BackendRelayAddress.resolve() ?? BackendRelayPacketCodec.defaultRelayURL))
            // One Remove means one thing (item 4): Reach's Remove also stops trusting the device here, and the Cloud
            // page's Remove also takes its reach away while reach is on. Each side calls the other's plain step only.
            await made.setTrustLink { [weak account] id in try await account?.stopTrustingForReachRemoval(deviceId: id) }
            await account.setReachLink { [weak made] id in _ = try await made?.removeIfOn(deviceId: id) }
            // On by default: only a Mac that never chose (no settings file yet) is switched on, once, without a press.
            await made.gate.switchOnByDefaultIfNeverChosen()
            await made.start(); await reload()
        }
    }

    func reload() async {
        guard let coordinator else { status = nil; remote = nil; return }
        status = await coordinator.status()
        if let door { let now = await door.status(); remote = .init(running: now.running, relayConnected: now.relay?.connected) }
        keepDoorOpen()
    }

    /// A1: the switch is on and the way in is closed: start it, then publish this Mac at once. A failed start is tried
    /// again every 30 s while the switch stays on; while it connects, the state is read again every 5 s until ready.
    private func keepDoorOpen() {
        guard let status, let door, launched else { return }
        let state = doorState(status)
        if state == .ready || state == nil { connectingSince = nil; startFailed = state == .ready ? false : startFailed }
        else if connectingSince == nil { connectingSince = Date().timeIntervalSince1970 * 1000 }
        if !starting, followUp == nil, !startFailed || retryDue,
           DevicesPage.startsDoor(on: status.enabled, signedIn: status.signedIn, entitled: status.entitled, running: remote?.running) {
            starting = true; retryDue = false
            Task {
                do { try await door.start(); startFailed = false } catch { startFailed = true }
                starting = false
                await coordinator?.sync()
                await reload()
            }
            return
        }
        guard state == .connecting || state == .notReachable, followUp == nil, !starting else { return }
        followUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(state == .connecting ? 5 : 30))
            guard !Task.isCancelled, let self else { return }
            self.followUp = nil; self.retryDue = true
            await self.coordinator?.sync()
            await self.reload()
        }
    }

    /// The switch. Turning it on is a guarded trust press (refused within 2 s of remote input).
    func setEnabled(_ on: Bool) {
        guard let coordinator, !busy else { return }
        busy = true; problem = nil
        let pressedAt = BackendRemoteInputMark.now()
        Task {
            do { try await coordinator.setEnabled(on, pressedAt: pressedAt) }
            catch BackendReachFailure.remoteInput { problem = "Turn this on at the Mac itself, not from a connected device." }
            catch { problem = "This could not be changed. Try again." }
            await reload(); busy = false
        }
    }

    func remove(_ deviceId: String) {
        guard let coordinator, !busy else { return }
        busy = true; problem = nil
        Task {
            do { try await coordinator.remove(deviceId: deviceId) }
            catch is BackendCloudTrustRefusal { problem = "It can no longer reach this Mac, but this Mac could not stop taking its changes yet. Choose \(NativeDevicesSettings.signOutTitle) again in a moment." }
            catch { problem = "It can no longer reach this Mac, but your account could not be told yet. It will be told next time." }
            await reload(); busy = false
        }
    }

    /// "Sign out this device" (14 Nov): reach's removal, so its live connections to this Mac end at once, it stays out
    /// of reach under this id here (in memory when the file cannot be written), and the Cloud is told. Throws when
    /// reach is not set up on this Mac or the Cloud was not told (DEVICE-SIGNOUT-2): for a browser this IS the sign-out.
    func cutSignedOut(_ deviceId: String) async throws {
        guard let coordinator else { throw BackendDeviceSignOutRefusal.notSignedIn }
        do { try await coordinator.signOut(deviceId: deviceId) } catch { await reload(); throw error }
        await reload()
    }

    private func show(_ notice: BackendReachNotice) {
        let text = notice.sentence
        self.notice = text
        Task { _ = await NativeCompositionBanners.shared.post(title: "Reach", body: text); await reload() }
    }

    /// From the account's event socket (any thread).
    nonisolated static func event(_ event: CloudEvent) {
        guard ["devices", "gate", "hello"].contains(event.type) else { return }
        let type = event.type, payload = event.payload.raw
        Task { @MainActor in
            guard let coordinator = NativeReachAccount.shared.coordinator else { return }
            await coordinator.event(type: type, payload: payload)
            await NativeReachAccount.shared.reload()
        }
    }

    func toolEntries() throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        guard NativeCloudOffers.shows(.phoneAndWebReach) else { return [] }
        return try BackendReachAccountTools.registrations(status: {
            guard await MainActor.run(body: { NativeCloudOffers.shows(.phoneAndWebReach) }) else { return nil }
            guard let coordinator = await MainActor.run(body: { NativeReachAccount.shared.coordinator }) else { return nil }
            return await coordinator.status()
        })
    }
}
