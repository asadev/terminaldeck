import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// The old way devices reached this Mac (before accounts): the model the Devices window reads its
/// "Connected before accounts" group from. Nothing here offers a way to add one (owner, 13 Nov).

// MARK: - Model

@MainActor
@Observable
final class RemoteSectionModel {
    private(set) var state: RemoteState?
    private(set) var problem: String?
    private(set) var notice: (ok: Bool, text: String)?
    private(set) var pairing: RemotePairing?
    private(set) var pairingURL: String?
    private(set) var highlightedDeviceID: String?
    /// `toggle`, `pair`, `device:<id>`, `connection:<id>`, `tunnel:<id>`, `approval:folder`.
    private(set) var busy: String?
    private(set) var kinds: [String: RemoteDeviceKind]?
    /// Every device's access level, read once for all rows (#404); nil until read.
    private(set) var access: [String: String]?
    private(set) var accessProblem: String?
    @ObservationIgnored private var accessFixture = false
    var approving: RemoteApproval?
    /// Milliseconds since 1970; moved on exactly when a label on screen changes.
    private(set) var now = Date().timeIntervalSince1970 * 1000

    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var readSeq = 0
    @ObservationIgnored private var alive = false

    var secondsLeft: Int? { pairing?.expiresAt.map { RemoteRules.codeSecondsLeft(expiresAt: $0, now: now) } }

    func start() async {
        alive = true
        if subscription == nil {
            subscription = EngineBridge.shared.on("remote:connections") { [weak self] _ in Task { await self?.refresh() } }
        }
        await refresh()
    }

    func stop() {
        alive = false
        subscription?.cancel()
        subscription = nil
        clock?.cancel()
        clock = nil
        // A code left on screen is withdrawn when the page goes, as the page does.
        if pairing != nil { Task { _ = try? await RemoteCall.invoke("remote:pair:cancel") } }
    }

    // MARK: Reading

    func refresh() async {
        readSeq += 1
        let seq = readSeq
        do {
            // All three reads share one budget; a slow optional kind read cannot
            // keep first-load skeletons up for three separate deadlines.
            let deadline = Date().addingTimeInterval(RemoteRules.readDeadlineSeconds)
            func remaining() throws -> Double {
                let seconds = deadline.timeIntervalSinceNow
                guard seconds > 0 else { throw EngineDeadline.Overdue(message: "Could not read devices in time. Try again.") }
                return seconds
            }
            let status = try await EngineDeadline.invoke("remote:status", what: "The remote access state", seconds: remaining())
            let devices = try await EngineDeadline.invoke("remote:devices", what: "The remote access state", seconds: remaining())
            let deviceKinds = (try? await EngineDeadline.invoke("remote:kinds", what: "The remote access state", seconds: remaining())) ?? []
            guard seq == readSeq else { return }
            kinds = RemoteRead.kinds(deviceKinds)
            if let parsed = RemoteRead.state(status: status, devices: devices) {
                state = parsed
                problem = nil
                now = Date().timeIntervalSince1970 * 1000
            } else {
                problem = "The main process answered with something this panel could not read."
            }
        } catch {
            guard seq == readSeq else { return }
            problem = RemoteCall.text(error, "Could not read the remote access state.")
        }
        reschedule()
    }

    /// One access read for every approved row; screens call it when the approved devices change.
    func readAccess() async {
        guard !accessFixture else { return }
        do { access = try await NativeINT2PhoneAccessControl.read(); accessProblem = nil }
        catch { accessProblem = deckMessage(error) }
    }

    func setAccess(_ device: String, to level: String) async throws {
        if accessFixture { access?[device] = level; return }
        access = try await NativeINT2PhoneAccessControl.write(device, level)
    }

    /// The row's level from the one read: "" when the list has no level for it.
    func accessLevel(_ device: String) -> String? { access.map { $0[device] ?? "" } }

    /// Wake for the next label change, a second while a code is up or the relay is settling,
    /// and just after the relay's retry — never on a fixed poll.
    private func reschedule() {
        clock?.cancel()
        guard alive else { return }
        let nowMs = Date().timeIntervalSince1970 * 1000
        var wake = RemoteRules.nextClockChange(state, pairing, now: nowMs)
        let settling = RemoteRules.unsettled(state, pairing)
        if settling { wake = min(wake ?? .infinity, nowMs + RemoteRules.unsettledSeconds * 1000) }
        var retryRead = false
        if let retryAt = state?.relay?.retryAt, retryAt + RemoteRules.retryGraceSeconds * 1000 > nowMs {
            let at = retryAt + RemoteRules.retryGraceSeconds * 1000
            if at <= (wake ?? .infinity) { wake = at; retryRead = true }
        }
        guard let wake, wake.isFinite else { return }
        clock = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(max(0, Int(wake - nowMs))))
            guard !Task.isCancelled, let self else { return }
            self.now = Date().timeIntervalSince1970 * 1000
            if settling || retryRead { await self.refresh() } else { self.reschedule() }
        }
    }

    // MARK: Acting

    private func run(_ key: String, done: String?, _ work: @escaping () async throws -> Void) {
        busy = key
        notice = nil
        Task {
            do {
                try await work()
                if let done { notice = (true, done) }
            } catch {
                notice = (false, RemoteCall.text(error, "That did not go through."))
            }
            busy = nil
            await refresh()
        }
    }

    func enable(_ on: Bool) {
        if on {
            run("toggle", done: "Remote access is on.") {
                if let answer = RemoteRead.state(status: try await RemoteCall.invoke("remote:start"), devices: []), !answer.running {
                    throw RemoteError(answer.reason ?? "It did not start, and did not say why.")
                }
            }
            return
        }
        let live = pairing
        pairing = nil
        run("toggle", done: "Remote access is off.") {
            if live != nil { _ = try? await RemoteCall.invoke("remote:pair:cancel") }
            _ = try await RemoteCall.invoke("remote:stop")
        }
    }

    func openWebVersion() {
        run("web", done: "The web version opened in your browser.") {
            let raw = try await RemoteCall.invoke("remote:web:open")
            guard let address = (raw as? [String: Any])?["url"] as? String,
                  let url = URL(string: address), url.scheme == "http", url.host == "localhost",
                  NSWorkspace.shared.open(url) else {
                throw RemoteError("Could not open the web version. Try again.")
            }
        }
    }

    func pair() {
        run("pair", done: nil) { [weak self] in
            self?.pairing = nil
            self?.pairingURL = nil
            if self?.state?.running != true {
                let started = try await RemoteCall.invoke("remote:start")
                guard RemoteRead.state(status: started, devices: [])?.running == true else {
                    throw RemoteError("Could not start device access. Open Device access and try again.")
                }
            }
            let raw = try await RemoteCall.invoke("remote:pair")
            guard let minted = RemoteRead.pairing(raw) else {
                throw RemoteError("The main process did not return a pairing code.")
            }
            self?.pairing = minted
            self?.pairingURL = (raw as? [String: Any])?["pairingURL"] as? String
        }
    }

    func closePairing() {
        pairingURL = nil
        pairing = nil
        run("pair", done: nil) { _ = try await RemoteCall.invoke("remote:pair:cancel") }
    }

    /// Approve, deny or revoke, then check the device is now listed as wanted.
    private func settle(_ device: RemoteDevice, channel: String, args: [Any?], want: RemoteDeviceState, done: String, after: (() -> Void)? = nil) {
        run("device:\(device.id)", done: done) {
            if let state = RemoteRead.stateAfter(try await RemoteCall.invoke(channel, args), id: device.id), state != want {
                throw RemoteError(RemoteRules.didNotTake(device, after: state))
            }
            after?()
        }
    }

    func beginApproval(_ device: RemoteDevice) {
        approving = RemoteApproval(device: device)
        NativeCodingAIStore.shared.reloadAccounts()
    }

    func addApprovalFolder() {
        run("approval:folder", done: nil) { [weak self] in
            if let picked = try await RemoteApprovalCall.pickFolder() { self?.approving?.addFolder(picked) }
        }
    }

    func approve() {
        guard let approval = approving else { return }
        let kind = approval.kind ?? .guest
        run("device:\(approval.device.id)",
            done: RemoteRules.approvedNotice(approval.device.name, kind: kind, folders: approval.folders.count,
                                             accountMode: approval.accountMode, accounts: approval.accounts.count)) { [weak self] in
            if let failure = try await RemoteApprovalCall.approve(approval) { throw RemoteError(failure) }
            self?.approving = nil
        }
    }

    /// One sheet approves the held device and its host-enforced access together.
    func letIn(_ device: RemoteDevice, access: String,
               invoke: (@MainActor (String, [Any?]) async throws -> Any)? = nil,
               refreshAfter: Bool = true) async -> Bool {
        // Every level the sheet's picker offers (BackendINT2PhoneAccessLevel.offered); Work was offered but refused
        // here without a word, so "Let it in" did nothing (#27).
        guard busy == nil, ["full", "work", "hoot", "look"].contains(access) else { return false }
        busy = "device:\(device.id)"
        notice = nil
        defer { busy = nil }
        do {
            let transport = invoke ?? RemoteCall.invoke
            let raw = try await transport("remote:device:approve-access", [device.id, access])
            guard RemoteRead.stateAfter(raw, id: device.id) == .approved else {
                throw RemoteError("The device was not approved. Try again.")
            }
            let roster = (raw as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            guard let granted = roster.first(where: { $0["id"] as? String == device.id }),
                  granted["access"] as? String == access else {
                throw RemoteError("The reply did not confirm the chosen access.")
            }
            highlightedDeviceID = device.id
            pairing = nil
            pairingURL = nil
            if refreshAfter { await refresh() }
            else if var current = state {
                current.devices = current.devices.map { row in
                    var next = row
                    if row.id == device.id { next.state = .approved }
                    return next
                }
                state = current
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if self?.highlightedDeviceID == device.id { self?.highlightedDeviceID = nil }
            }
            return true
        } catch {
            notice = (false, RemoteCall.text(error, "Could not let the device in."))
            if refreshAfter { await refresh() }
            return false
        }
    }

    func rename(_ device: RemoteDevice, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run("device:\(device.id)", done: "Renamed the device.") {
            _ = try await RemoteCall.invoke("remote:device:rename", [device.id, trimmed])
        }
    }

    #if DEBUG
    /// Scratch render fixtures never start the engine or any connection.
    func setRenderFixture(state: RemoteState?, pairing: RemotePairing? = nil, pairingURL: String? = nil, problem: String? = nil) {
        self.state = state
        self.problem = problem
        self.pairing = pairing
        self.pairingURL = pairingURL
        self.now = Date().timeIntervalSince1970 * 1000
    }
    #endif

    func setRenderAccess(_ levels: [String: String]) {
        accessFixture = true
        access = levels
    }

    func deny(_ device: RemoteDevice) {
        settle(device, channel: "remote:device:revoke", args: [device.id], want: .revoked,
               done: "\(device.name) was refused.")
    }

    func revoke(_ device: RemoteDevice) {
        settle(device, channel: "remote:device:revoke", args: [device.id], want: .revoked, done: "Revoked \(device.name).")
    }

    /// The Devices window's Remove on a device connected before accounts: exactly the old Revoke, with no question.
    func remove(_ device: RemoteDevice) {
        settle(device, channel: "remote:device:revoke", args: [device.id], want: .revoked, done: "Removed \(device.name).")
    }

    func disconnect(_ connection: RemoteConnection) {
        run("connection:\(connection.id)", done: "Disconnected \(connection.deviceName). It can attach again unless you revoke it.") {
            _ = try await RemoteCall.invoke("remote:connection:disconnect", [connection.id])
        }
    }

    func stopTunnel(_ connection: RemoteConnection, _ tunnel: RemoteTunnel) {
        run("tunnel:\(tunnel.id)", done: "Closed the page on port \(tunnel.port). \(connection.deviceName) can open it again.") {
            _ = try await RemoteCall.invoke("remote:tunnel:stop", [connection.id, tunnel.id])
        }
    }
}

struct RemoteError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Letting a device in: the one request Settings and the Alerts sheet both send.
@MainActor
enum RemoteApprovalCall {
    typealias Invoke = @MainActor (String, [Any?]) async throws -> Any

    /// The folder chooser's pick; nil when the person cancelled.
    static func pickFolder(invoke: Invoke? = nil) async throws -> String? {
        let picked = try await (invoke ?? RemoteCall.invoke)("project:pick", []) as? String
        return picked?.isEmpty == false ? picked : nil
    }

    /// Sends the approval; why it did not take, or nil when the device is in.
    static func approve(_ approval: RemoteApproval, invoke: Invoke? = nil) async throws -> String? {
        let kind = approval.kind ?? .guest
        let answer = try await (invoke ?? RemoteCall.invoke)("remote:device:approve",
                                                            [approval.device.id, kind.rawValue, approval.folders,
                                                             approval.accountMode.rawValue, approval.accounts])
        return RemoteRules.approvalFailure(answer, device: approval.device)
    }
}

/// A sentence of prose at the page's reading width (`settings-prose`).
struct RemoteSentence: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        NativeSettingsProse(text: text)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
