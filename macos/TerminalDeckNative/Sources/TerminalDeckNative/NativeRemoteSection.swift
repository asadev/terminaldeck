import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// "Your own devices" on Machines, drawn in Swift — the web's
/// `remote/RemoteSection.tsx` one-to-one, in the page's order:
///
/// 1. "Let approved devices in" with its switch, help and ⓘ; reading; the
///    problem with Try again; the notice after an action.
/// 2. "Not serving" with the reason, while it is off for one.
/// 3. "Attached now — N": each device attached, Disconnect, and the pages it has
///    open (localhost:port) with Stop, and "Stop closes the page, and nothing else."
/// 4. "Devices": the waiting sentence, the approval in progress, every device with
///    its state, last seen / paired, kind, fingerprint (or why there is none), and
///    Let it in… / Deny / Revoke, then "Revoking is immediate."
/// 5. The per-device lists (folders, sessions, logins, browser windows) once one is approved.
/// 6. The machines this Mac can reach (`NativeMachineLinksView`).
/// 7. "How a device gets here": the relay, connected or not and why, and when it retries.
/// 8. "Pair a device": "Let a device in" (Show a code, the code, its countdown, this
///    Mac's fingerprint, Copy / Hide the code / Show another one) and "Add another
///    computer" (lane E1's `NativeCodeEntry`).
///
/// Lane E1 embeds this under the "Your own devices" heading and its sentence.
struct NativeRemoteSection: View {
    @State private var model = RemoteSectionModel()
    /// The machines this desktop dialled: "Machines you can reach" and the code entry.
    @State private var machines = MachinesHalfModel()

    var body: some View {
        RemoteSectionBody(model: model, machines: machines)
            .task {
                async let remote: Void = model.start()
                async let reach: Void = machines.start()
                _ = await (remote, reach)
            }
            .onDisappear {
                model.stop()
                machines.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task {
                    await model.refresh()
                    await machines.reread()
                }
            }
    }
}

// MARK: - Model

@MainActor
@Observable
final class RemoteSectionModel {
    private(set) var state: RemoteState?
    private(set) var problem: String?
    private(set) var notice: (ok: Bool, text: String)?
    private(set) var pairing: RemotePairing?
    /// `toggle`, `pair`, `device:<id>`, `connection:<id>`, `tunnel:<id>`, `approval:folder`.
    private(set) var busy: String?
    private(set) var kinds: [String: RemoteDeviceKind]?
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
            let status = try await EngineDeadline.invoke("remote:status", what: "The remote access state", seconds: RemoteRules.readDeadlineSeconds)
            let devices = try await EngineDeadline.invoke("remote:devices", what: "The remote access state", seconds: RemoteRules.readDeadlineSeconds)
            let deviceKinds = (try? await EngineDeadline.invoke("remote:kinds", what: "The remote access state", seconds: RemoteRules.readDeadlineSeconds)) ?? []
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
            run("toggle", done: "Remote access is on. Nothing can connect until you pair and approve a device.") {
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

    func pair() {
        run("pair", done: nil) { [weak self] in
            self?.pairing = nil
            guard let minted = RemoteRead.pairing(try await RemoteCall.invoke("remote:pair")) else {
                throw RemoteError("The main process did not return a pairing code.")
            }
            self?.pairing = minted
        }
    }

    func closePairing() {
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
            guard let picked = try await RemoteCall.invoke("project:pick") as? String, !picked.isEmpty else { return }
            self?.approving?.addFolder(picked)
        }
    }

    func approve() {
        guard let approval = approving else { return }
        let kind = approval.kind ?? .guest
        settle(approval.device, channel: "remote:device:approve",
               args: [approval.device.id, kind.rawValue, approval.folders, approval.accountMode.rawValue, approval.accounts],
               want: .approved,
               done: RemoteRules.approvedNotice(approval.device.name, kind: kind, folders: approval.folders.count,
                                                accountMode: approval.accountMode, accounts: approval.accounts.count)) { [weak self] in
            self?.approving = nil
        }
    }

    func deny(_ device: RemoteDevice) {
        settle(device, channel: "remote:device:revoke", args: [device.id], want: .revoked,
               done: "\(device.name) was refused, and cannot be approved later — pair it again if that was a slip.")
    }

    func revoke(_ device: RemoteDevice) {
        settle(device, channel: "remote:device:revoke", args: [device.id], want: .revoked, done: "Revoked \(device.name).")
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

// MARK: - The section

private struct RemoteSectionBody: View {
    @Bindable var model: RemoteSectionModel
    let machines: MachinesHalfModel

    var body: some View {
        let state = model.state
        let running = state?.running == true
        let devices = state?.devices ?? []
        let pending = devices.filter { $0.state == .pending }
        let approved = devices.filter { $0.state == .approved }
        let connections = state?.connections ?? []
        let machine = RemoteRules.thisMachine

        VStack(alignment: .leading, spacing: 0) {
            RemoteGroup {
                // The page's settings row: the label, its ⓘ and the help on the left, the switch
                // at the right edge of the column.
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text("Let approved devices in")
                            NativeCodingAIInfo(label: "Let approved devices in",
                                               text: "Letting a device in asks you two things: whose it is, and what it may open. One of your own gets everything — every folder, every session, Hoot. A guest gets the folders you choose and nothing else: not your other projects, not the sessions running in them, and never Hoot. Nothing is published to the internet either way — everything is sealed end to end, so the relay that carries it routes bytes it holds no key for. That seal lets nothing in on its own; a code you mint here and an approval you give here do.")
                        }
                        Text("Drive \(machine) from a phone or another computer, from any network — a device you approve gets a shell here. Nothing to install and no account.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 480, alignment: .leading)
                    }
                    Spacer(minLength: 16)
                    Toggle("Let approved devices in", isOn: Binding(get: { running }, set: { model.enable($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(state == nil || model.busy != nil)
                }
                .frame(maxWidth: .infinity)
                if state == nil && model.problem == nil {
                    RemoteSentence( "Reading the current state…")
                }
                if let problem = model.problem {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        RemoteNotice(tone: .error, text: "\(problem) Anything below was read before that and may be out of date.")
                        Button("Try again") { Task { await model.refresh() } }.disabled(model.busy != nil)
                    }
                }
                if let notice = model.notice {
                    RemoteNotice(tone: notice.ok ? .info : .warn, text: notice.text)
                }
            }

            if !running, let reason = state?.reason {
                RemoteGroup("Not serving") {
                    RemoteNotice(tone: .warn, text: reason)
                    RemoteSentence( "The switch shows whether it is actually serving, not whether it was asked to. Fix the above and turn it on again.")
                }
            }

            if running && !connections.isEmpty {
                AttachedGroup(model: model, connections: connections)
            }

            if state != nil && !devices.isEmpty {
                RemoteGroup("Devices") {
                    if !pending.isEmpty {
                        RemoteSentence( "\(pending.count == 1 ? "A device is" : "\(pending.count) devices are") waiting to be let in. Approve only the one you are holding — "
                                            + (pending.contains { $0.fingerprint != nil }
                                               ? "the phone shows its own fingerprint, and the row below shows what \(machine) received."
                                               : "this one paired without a key, so there is no fingerprint to compare."))
                    }
                    if model.approving != nil {
                        RemoteApprovalCard(approval: $model.approving, busy: model.busy != nil, problem: model.problem,
                                           addFolder: model.addApprovalFolder, approve: model.approve,
                                           cancel: { model.approving = nil })
                    }
                    VStack(spacing: 0) {
                        ForEach(devices) { device in
                            DeviceRow(model: model, device: device)
                            if device.id != devices.last?.id { Divider() }
                        }
                    }
                    RemoteProse(text: Text("Revoking is immediate.").bold(), noteLabel: "revoking",
                                note: "The device is dropped where it stands — mid command, mid session — not at its next connection. Disconnecting is the gentler one: it only closes what is open now, and an approved device can attach again straight away.")
                }
            }

            if !approved.isEmpty, let state {
                RemoteFoldersView(devices: RemoteRules.grantable(state.devices, kinds: model.kinds))
                RemoteSessionsView(devices: RemoteRules.sessionDevices(state.devices))
                RemoteLoginsView(devices: RemoteRules.sessionDevices(state.devices))
                RemoteWindowsView(devices: RemoteRules.sessionDevices(state.devices))
            }

            // "Machines you can reach", when it has something to say: not wired, reading, failed, or a machine.
            if !machines.wired || machines.reading || machines.error != nil || !machines.view.machines.isEmpty {
                NativeMachineLinksView(half: machines)
            }

            if running {
                RelayGroup(relay: state?.relay, now: model.now)
                PairGroup(model: model, machines: machines)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your own devices")
    }
}

private struct AttachedGroup: View {
    let model: RemoteSectionModel
    let connections: [RemoteConnection]

    var body: some View {
        RemoteGroup("Attached now — \(connections.count)") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(connections) { connection in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 7, height: 7)
                                Text("Attached").font(.caption.weight(.medium)).foregroundStyle(.green)
                            }
                            .frame(width: 90, alignment: .leading)
                            .accessibilityAddTraits(.updatesFrequently)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.deviceName).font(.body.weight(.medium))
                                Text(RemoteRules.connectionNote(connection, now: model.now)).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(model.busy == "connection:\(connection.id)" ? "Closing…" : "Disconnect", role: .destructive) {
                                model.disconnect(connection)
                            }
                            .disabled(model.busy != nil)
                        }
                        ForEach(connection.tunnels) { tunnel in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text("localhost:\(tunnel.port)").font(.callout.monospaced())
                                        Text("open in a browser on this phone").font(.callout).foregroundStyle(.secondary)
                                    }
                                    Text(RemoteRules.tunnelNote(tunnel, now: model.now)).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(model.busy == "tunnel:\(tunnel.id)" ? "Stopping…" : "Stop") { model.stopTunnel(connection, tunnel) }
                                    .disabled(model.busy != nil)
                            }
                            .padding(.leading, 100)
                        }
                    }
                }
            }
            if connections.contains(where: { !$0.tunnels.isEmpty }) {
                RemoteProse(text: Text("Stop closes the page, and nothing else.").bold(), noteLabel: "open ports",
                            note: "A port listed above is being served from \(RemoteRules.thisMachine) to that phone’s browser, over the same connection. Stopping it leaves the session running and the device approved, and the phone can tap the port again.")
            }
        }
    }
}

private struct DeviceRow: View {
    let model: RemoteSectionModel
    let device: RemoteDevice

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(RemoteRules.stateLabel(device.state))
                .font(.caption.weight(.medium))
                .foregroundStyle(device.state == .pending ? Color.orange : device.state == .approved ? Color.green : Color.secondary)
                .frame(width: 100, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(.body.weight(.medium))
                Text("Last seen \(RemoteRules.whenSeen(device.lastSeenAt, now: model.now))"
                     + (device.addedAt.map { " · paired \(RemoteRules.whenSeen($0, now: model.now))" } ?? ""))
                    .font(.callout).foregroundStyle(.secondary)
                if device.state == .approved, let kinds = model.kinds {
                    Text(RemoteRules.kindNote(kinds[device.id])).font(.callout).foregroundStyle(.secondary)
                }
                if device.state != .revoked {
                    if let fingerprint = device.fingerprint {
                        Text(fingerprint).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Text("No key stored — this one paired before there were keys, so it cannot come in through the relay. Pair it again to fix that.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if device.state == .pending {
                    Button("Let it in…") { model.beginApproval(device) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy != nil || model.approving?.device.id == device.id)
                    Button("Deny") { model.deny(device) }.disabled(model.busy != nil)
                }
                if device.state == .approved {
                    Button(model.busy == "device:\(device.id)" ? "Revoking…" : "Revoke", role: .destructive) { model.revoke(device) }
                        .disabled(model.busy != nil)
                }
            }
        }
        .padding(.vertical, 10)
    }
}

private struct RelayGroup: View {
    let relay: RemoteRelay?
    let now: Double

    var body: some View {
        let machine = RemoteRules.thisMachine
        let tone: Color = relay == nil ? .secondary : relay!.connected ? .green : .orange
        RemoteGroup("How a device gets here") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("Through the relay").font(.body.weight(.medium))
                        NativeCodingAIInfo(label: "Through the relay",
                                           text: "A rendezvous service. It staples two sockets together and carries sealed bytes it cannot read, so nothing on the way can see the session. It is also what a pairing code is looked up through: the code names a slot at the relay, and whatever types it finds \(machine) there.")
                    }
                    Spacer()
                    Text(relay == nil ? "Off" : relay!.connected ? "Connected" : "Not connected")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tone)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(tone.opacity(0.15), in: .capsule)
                }
                Text("Reachable from any network: \(machine) dials out to it, so nothing has to be installed on the device.")
                    .foregroundStyle(.secondary)
                Group {
                    if let relay {
                        if relay.connected {
                            Text(relay.channels > 0 ? "Carrying \(relay.channels) connection\(relay.channels == 1 ? "" : "s") right now." : "Nothing is coming through it right now.")
                        } else {
                            Text("\(relay.reason ?? "It is not connected, and did not say why.") \(RemoteRules.retryNote(relay.retryAt, now: now) ?? "")")
                        }
                    } else {
                        Text("This build is not dialling a relay — either TERMINALDECK_RELAY is off, or it was assembled without one.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
        }
    }
}

private struct PairGroup: View {
    let model: RemoteSectionModel
    let machines: MachinesHalfModel
    @State private var copied = false

    var body: some View {
        let state = model.state
        let relay = state?.relay
        let relayLive = relay?.connected == true
        let direct = state?.url
        let canPair = RemoteRules.canMintCode(state)
        let pairing = model.pairing
        let secondsLeft = model.secondsLeft
        let expired = secondsLeft.map { $0 <= 0 } ?? false
        let lookupDown = pairing?.findable == false || !relayLive
        let tailnetOnly = lookupDown && direct != nil
        let reachesNothing = pairing?.findable == false && direct == nil

        RemoteGroup("Pair a device") {
            RemoteProse(text: Text("A code is good for one device and lasts \(RemoteRules.pairingWindowSeconds) seconds."), noteLabel: "pairing codes",
                        note: "Typing the code asks to be let in; it lets nothing in on its own — you still approve the device by hand, on this screen. Pairing has two ends and you are standing at both: one screen shows a code and the other is typed into, which is why both halves are here rather than on two screens.")
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Let a device in").font(.body.weight(.semibold))
                    if pairing == nil {
                        Button(model.busy == "pair" ? "Asking…" : "Show a code") { model.pair() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy != nil || !canPair)
                        if !canPair {
                            RemoteNotice(tone: .warn, text: "Nothing above is up, so a code would reach nothing. The rows above say what is wrong; fix that and this will mint.")
                        }
                    }
                    if let pairing {
                        if !canPair {
                            RemoteNotice(tone: .warn, text: "There is nowhere to point this code any more — every way in went away while it was on screen. Cancel it and show another once one of them is back.")
                        } else if expired {
                            RemoteNotice(tone: .warn, text: "That code has expired. Show another one.")
                        } else if reachesNothing {
                            RemoteNotice(tone: .warn, text: "This machine could not take its place at the rendezvous, so nothing can look this code up — and there is no direct route here to fall back on. The digits are not shown, because nothing could use them. Try again below.")
                        } else {
                            Text(RemoteRules.codeShown(pairing.token))
                                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                                .tracking(4)
                                .textSelection(.enabled)
                                .accessibilityLabel("Pairing code")
                            if tailnetOnly {
                                RemoteNotice(tone: .warn, text: "Nothing can look this code up, so only a device already on your tailnet can use it\(direct.map { " — at \($0)" } ?? "").")
                            }
                        }
                        if !reachesNothing {
                            Text(secondsLeft.map { expired ? "Expired" : "Expires in \($0)s" } ?? "The main process did not say when this expires.")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(expired || secondsLeft == nil ? .secondary : .primary)
                        }
                        if let relay, !relay.fingerprint.isEmpty, !expired, canPair, !reachesNothing {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("This \(RemoteRules.machineNoun)’s fingerprint").font(.caption).foregroundStyle(.secondary)
                                Text(relay.fingerprint).font(.callout.monospaced()).textSelection(.enabled)
                                Text("The device shows the same six groups before it connects. If they do not match, something else answered to \(RemoteRules.thisMachine)’s name — cancel, do not approve.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 8) {
                            if expired || reachesNothing {
                                Button(model.busy == "pair" ? "Asking…" : expired ? "Show another one" : "Try again") { model.pair() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.busy != nil || !canPair)
                            } else {
                                Button(copied ? "Copied" : "Copy") {
                                    DeckProject.copy(RemoteRules.codeShown(pairing.token))
                                    copied = true
                                    Task {
                                        try? await Task.sleep(for: .seconds(2))
                                        copied = false
                                    }
                                }
                                .disabled(model.busy != nil)
                            }
                            Button(expired || reachesNothing ? "Done" : "Hide the code") { model.closePairing() }
                                .disabled(model.busy != nil)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add another computer").font(.body.weight(.semibold))
                    RemoteSentence( "You approve this one over there, once.")
                    NativeCodeEntry(half: machines)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Letting one device in

/// The approval walk-through: check, whose, what it may open, which logins, confirm —
/// `remote/DeviceApproval.tsx`. Shared by the Devices list and the Alerts approval.
struct RemoteApprovalCard: View {
    @Binding var approval: RemoteApproval?
    let busy: Bool
    let problem: String?
    let addFolder: () -> Void
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        if let current = approval {
            let order = RemoteRules.steps(current.kind)
            let back = RemoteRules.previousStep(current.step, kind: current.kind)
            let machine = RemoteRules.thisMachine
            let name = current.device.name
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(name) wants in").font(.headline)
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(order, id: \.self) { step in
                            Circle().fill(step == current.step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \((order.firstIndex(of: current.step) ?? 0) + 1) of \(order.count)")
                }
                if let problem { RemoteNotice(tone: .error, text: problem) }

                switch current.step {
                case .check:
                    Text("Check you are looking at the right one.").font(.body.weight(.medium))
                    if let fingerprint = current.device.fingerprint {
                        Text(fingerprint).font(.title3.monospaced()).textSelection(.enabled)
                        note("The device shows the same six groups. If they do not match, something else answered to \(machine)’s name — cancel, do not continue.")
                    } else {
                        RemoteNotice(tone: .warn, text: "This one paired without a key, so there is nothing to compare and it can only reach \(machine) over the same network. Pair it again to fix that.")
                    }
                case .kind:
                    Text("Whose device is it?").font(.body.weight(.medium))
                    HStack(spacing: 10) {
                        choice("My device", "Full access. It’s you at another keyboard.", picked: current.kind == .mine) { approval?.pick(.mine) }
                        choice("Guest", "You choose what they can reach. Hoot is never shared.", picked: current.kind == .guest) { approval?.pick(.guest) }
                    }
                case .folders:
                    Text("What can it open?").font(.body.weight(.medium))
                    if current.folders.isEmpty {
                        note("Nothing yet — and nothing is what it gets. It will not see the other folders on \(machine), or the sessions running in them.")
                    } else {
                        ForEach(current.folders, id: \.self) { folder in
                            HStack {
                                RemoteFolderLabel(path: folder)
                                Spacer()
                                Button("Remove") { approval?.removeFolder(folder) }.disabled(busy)
                            }
                        }
                    }
                    Button(busy ? "Choosing…" : "Add a folder…", action: addFolder).disabled(busy)
                case .accounts:
                    Text("Which of your logins can it use?").font(.body.weight(.medium))
                    RemoteShareSwitch(label: "Logins it can use", value: current.accountMode, disabled: busy) { approval?.setAccountMode($0) }
                    if current.accountMode == .selected {
                        ForEach(RemoteLogins.rows, id: \.id) { login in
                            Toggle(login.label, isOn: Binding(get: { current.accounts.contains(login.id) },
                                                              set: { on in approval?.toggleAccount(login.id, on: on) }))
                                .toggleStyle(.checkbox)
                                .disabled(busy)
                        }
                        if current.accounts.isEmpty {
                            note("Nothing ticked — \(name) gets no account chip at all on sessions here.")
                        }
                    }
                case .confirm:
                    Text(RemoteRules.confirmLede(name, kind: current.kind, folders: current.folders.count)).font(.body.weight(.medium))
                    if current.kind == .guest && !current.folders.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(current.folders, id: \.self) { folder in
                                Text("• \(RemoteGrants.folderName(folder))").help(folder)
                            }
                        }
                    }
                    if current.kind == .guest {
                        note(RemoteRules.confirmLogins(mode: current.accountMode, accounts: current.accounts.count))
                    }
                    note(current.kind == .mine
                         ? "It can open any folder here, see every session, and use Hoot."
                         : "It will not be offered Hoot. You can change its folders and logins later.")
                    note("My device or Guest is fixed once you let it in. To change it, revoke the device and pair it again.")
                }

                HStack {
                    Button("Cancel", action: cancel).disabled(busy)
                    if let back {
                        Button("Back") { approval?.step = back }.disabled(busy)
                    }
                    Spacer()
                    if current.step == .confirm {
                        Button(busy ? "Letting it in…" : "Let it in", action: approve)
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || current.kind == nil)
                    } else {
                        Button("Continue") { approval?.step = RemoteRules.nextStep(current.step, kind: current.kind) }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || (current.step == .kind && current.kind == nil))
                            .help(current.step == .kind && current.kind == nil ? "Pick whose device it is first." : "")
                    }
                }
            }
            .padding(16)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Let \(name) in")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func choice(_ title: String, _ detail: String, picked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(picked ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

// MARK: - Letting one device in from the Alerts sheet

/// The approval opened from an alert about a waiting device — `remote/PendingApproval.tsx`:
/// reading the list, why there is nothing left to approve (with Done), or the
/// walk-through itself. Lane S mounts this in the Alerts sheet.
struct NativePendingApproval: View {
    let deviceId: String
    let onDone: () -> Void
    var onPicking: ((Bool) -> Void)?

    private enum Load { case reading, ready, gone(String), failed(String) }
    @State private var load = Load.reading
    @State private var approval: RemoteApproval?
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        Group {
            switch load {
            case .reading:
                Text("Reading the device list…").font(.callout).foregroundStyle(.secondary)
                    .accessibilityLabel("Reading the device list")
            case .gone(let because), .failed(let because):
                VStack(alignment: .leading, spacing: 12) {
                    RemoteNotice(tone: isFailed ? .error : .info, text: because)
                    HStack { Spacer(); Button("Done", action: onDone).buttonStyle(.borderedProminent) }
                }
                .accessibilityLabel("Nothing to approve")
            case .ready:
                RemoteApprovalCard(approval: $approval, busy: busy, problem: problem,
                                   addFolder: addFolder, approve: approve, cancel: onDone)
            }
        }
        .task { await read() }
    }

    private var isFailed: Bool { if case .failed = load { true } else { false } }

    private func read() async {
        do {
            let devices = RemoteRead.devices(try await RemoteCall.invoke("remote:devices"))
            let found = devices.first { $0.id == deviceId }
            if let because = RemoteRules.goneBecause(found) {
                load = .gone(because)
            } else if let found {
                approval = RemoteApproval(device: found)
                NativeCodingAIStore.shared.reloadAccounts()
                load = .ready
            }
        } catch {
            load = .failed(RemoteCall.text(error, "Could not read the device list."))
        }
    }

    private func addFolder() {
        busy = true
        problem = nil
        onPicking?(true)
        Task {
            do {
                if let picked = try await RemoteCall.invoke("project:pick") as? String, !picked.isEmpty { approval?.addFolder(picked) }
            } catch {
                problem = RemoteCall.text(error, "Could not open the folder chooser.")
            }
            busy = false
            onPicking?(false)
        }
    }

    private func approve() {
        guard let current = approval else { return }
        let kind = current.kind ?? .guest
        busy = true
        problem = nil
        Task {
            do {
                let answer = try await RemoteCall.invoke("remote:device:approve",
                                                         [current.device.id, kind.rawValue, current.folders, current.accountMode.rawValue, current.accounts])
                if let failure = RemoteRules.approvalFailure(answer, device: current.device) {
                    problem = failure
                    busy = false
                    return
                }
                onDone()
            } catch {
                problem = RemoteCall.text(error, "That did not go through.")
                busy = false
            }
        }
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
