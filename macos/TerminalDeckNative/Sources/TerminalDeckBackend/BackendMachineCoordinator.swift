import Foundation
import TerminalDeckNativeCore

public struct BackendMachineOffer: Sendable {
    public let relayURL: String, hostID: String, name: String, platform: String
    public let publicKey: Data
}

/// Pairing/discovery is always explicit. Persisted credentials are never
/// reported to UI callers and every link shares the single machine store.
public actor BackendMachineCoordinator {
    public let store: BackendMachineStore
    private let registry: NativeChannelRegistry
    private let localName: String
    private let relayURL: String
    private let uploadAuthorize: BackendUploadSend.Authorize
    private let ownPorts: BackendDevOwnPorts
    private var windows: BackendMachineWindowServices?
    private let pairingBlocked: @Sendable () async -> String?
    private let tunnelsDropped: @Sendable (String) async -> Void
    private var links: [String: BackendRemoteGuest] = [:]
    private var uploads: [String: BackendUploadSend] = [:]
    private var reaches: [String: BackendRemoteGuestReach] = [:]
    private var pairing: Task<BackendMachineRecord, Error>?
    private var pairingID: UUID?
    private var opened = false
    /// Saved machines that could not be reconnected at start, with why; shown as that machine's link (U1).
    private var unreachable: [String: String] = [:]
    /// Which links were online at the last state, so a new welcome is noticed once.
    private var online: [String: Bool] = [:]
    public init(store: BackendMachineStore, registry: NativeChannelRegistry, localName: String, relayURL: String,
                uploadAuthorize: @escaping BackendUploadSend.Authorize, ownPorts: BackendDevOwnPorts, windows: BackendMachineWindowServices? = nil,
                pairingBlocked: @escaping @Sendable () async -> String? = { nil }, tunnelsDropped: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.store = store; self.registry = registry; self.localName = localName; self.relayURL = relayURL
        self.uploadAuthorize = uploadAuthorize; self.ownPorts = ownPorts; self.windows = windows; self.pairingBlocked = pairingBlocked; self.tunnelsDropped = tunnelsDropped
    }
    public func open(connectSaved: Bool = false) async throws {
        guard !opened else { return }; try await store.open(); opened = true
        guard connectSaved else { return }
        // U1: one machine whose saved keys no longer read is shown as failed; the machines after it still reconnect.
        for machine in try await store.list() {
            do { try await connect(machine.id) }
            catch { unreachable[machine.id] = "This machine's saved pairing could not be read, so it was not reconnected. Pair it again. (\(error.localizedDescription))" }
        }
        if !unreachable.isEmpty { await publish() }
    }
    public func uses(registry: NativeChannelRegistry, ownPorts: BackendDevOwnPorts) -> Bool { self.registry === registry && self.ownPorts === ownPorts }
    /// Composition may bind browser handlers before opening the one owner.
    /// Rebinding a running link graph would leave old peers using stale authority.
    public func installWindowServices(_ services: BackendMachineWindowServices) throws {
        guard !opened, links.isEmpty else { throw NativeRPCError(code: "composition-state", message: "Machine browser suppliers must be installed before the machine owner opens") }
        windows = services
    }
    public func stop() async {
        pairing?.cancel(); pairing = nil; pairingID = nil
        for upload in uploads.values { await upload.disconnected() }
        for reach in reaches.values { await reach.stop() }
        for link in links.values { await link.disconnect() }
        links = [:]; uploads = [:]; reaches = [:]; unreachable = [:]; opened = false; await store.close()
    }
    public func view() async throws -> NativeRPCValue {
        let machines = try await store.list().map(\.value)
        var states: [NativeRPCValue] = []
        for key in links.keys.sorted() { states.append(await links[key]!.state().value) }
        for (id, reason) in unreachable.sorted(by: { $0.key < $1.key }) where links[id] == nil {
            states.append(BackendMachineLinkState(id: id, phase: .error, reason: reason, sessions: [], folders: nil, capabilities: [], ports: [],
                copilot: .null, hostPlatform: "", hostVersion: "", hostKind: nil, retryAt: nil).value)
        }
        return .object([.init("machines", .array(machines)), .init("links", .array(states)), .init("here", .string(localName)), .init("blocked", await pairingBlocked().map(NativeRPCValue.string) ?? .null)])
    }
    public func link(_ id: String) throws -> BackendRemoteGuest { guard let link = links[id] else { throw NativeRPCError(code: "machine-offline", message: "This desktop is not linked to that machine") }; return link }
    public func connect(_ id: String) async throws {
        guard opened else { throw NativeRPCError(code: "machines-closed", message: "Open the machine coordinator before dialing") }
        if let link = links[id] { await link.connect(); return }
        let secrets = try await store.secrets(id), store = self.store
        unreachable[id] = nil
        let sender = BackendUploadSend(authorize: uploadAuthorize) { [weak self] progress in await self?.uploadProgress(id, progress) }
        uploads[id] = sender
        let windows = self.windows
        let windowCall: BackendRemoteGuest.WindowCall? = windows.map { service in { @Sendable (session: String, tool: String, arguments: String) async throws -> (ok: Bool, body: String) in await service.serve(machineID: id, sessionID: session, tool: tool, arguments: arguments) } }
        let held: (@Sendable () async -> [NativeRPCValue])? = windows?.held.map { source in { @Sendable () async -> [NativeRPCValue] in await source(id) } }
        let receivedHolds: (@Sendable ([String], [NativeRPCValue]) async -> Void)? = windows?.receivedHolds.map { sink in { @Sendable (sessions: [String], held: [NativeRPCValue]) async -> Void in await sink(id, sessions, held) } }
        let guest = BackendRemoteGuest(id: id, secrets: secrets, localName: localName,
            onState: { [weak self] state in await self?.linkChanged(id, state: state) },
            onOutput: { [weak self] session, text, replay in await self?.output(id, session: session, text: text, replay: replay) },
            onWelcome: { platform in try? await store.sawWelcome(id, platform: platform) },
            onFrame: { [weak self] frame in await sender.handle(frame); await self?.peerFrame(id, frame) },
            windowsAllowed: { try await store.drivesWindows(id) }, windowCall: windowCall, windowsHeld: held,
            ownSessions: windows?.ownSessions, receivedHolds: receivedHolds, receivedResult: windows?.receivedResult)
        links[id] = guest; reaches[id] = BackendRemoteGuestReach(guest: guest, ownPorts: ownPorts); await guest.connect(); await publish()
    }
    public func disconnect(_ id: String) async { await uploads[id]?.disconnected(); await reaches[id]?.stop(); await links[id]?.disconnect(); await tunnelsDropped(id); await publish() }
    public func forget(_ id: String) async throws -> Bool {
        await uploads.removeValue(forKey: id)?.disconnected(); await reaches.removeValue(forKey: id)?.stop(); await links.removeValue(forKey: id)?.disconnect()
        unreachable[id] = nil
        let removed = try await store.forget(id); await tunnelsDropped(id); await publish(); return removed
    }
    public func rename(_ id: String, name: String) async throws -> Bool { let result = try await store.rename(id, name: name); await publish(); return result }
    public func setDrivesWindows(_ id: String, allowed: Bool) async throws -> Bool { let result = try await store.setDrivesWindows(id, allowed: allowed); await publish(); return result }
    public func cancelPairing() { pairing?.cancel(); pairing = nil; pairingID = nil }
    public func pair(code: String) async throws -> BackendMachineRecord {
        guard pairing == nil else { throw NativeRPCError(code: "pair-running", message: "A machine pairing is already in progress") }
        let relay = relayURL, name = localName, store = self.store
        let operation = UUID(); pairingID = operation
        let task = Task { try await Self.performPairing(code: code, relayURL: relay, localName: name, store: store) }
        pairing = task
        do {
            let record = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard pairingID == operation else { throw CancellationError() }
            pairing = nil; pairingID = nil
            await uploads.removeValue(forKey: record.id)?.disconnected(); await reaches.removeValue(forKey: record.id)?.stop(); await links.removeValue(forKey: record.id)?.disconnect()
            try await connect(record.id); await publish(); return record
        } catch { if pairingID == operation { pairing = nil; pairingID = nil }; throw error }
    }
    private static func performPairing(code: String, relayURL: String, localName: String, store: BackendMachineStore) async throws -> BackendMachineRecord {
        guard let canonical = BackendRendezvous.normalize(code) else { throw NativeRPCError(code: "pair-bad-code", message: "That is not a pairing code. It is six digits, like 123456.") }  // pair.ts:164
        let lookupIdentity = try await BackendRendezvous.derive(canonical)
        let discovery = BackendRemoteGuestChannel(relayURL: relayURL, hostID: lookupIdentity.hostID, hostKey: lookupIdentity.keys.publicKey, identity: .generate())
        let offer: BackendMachineOffer
        do {
            do { try await discovery.open(timeoutMilliseconds: 12000) }
            catch { throw NativeRPCError(code: "pair-unreachable", message: "The pairing service could not be reached. " + error.localizedDescription) }
            offer = try parseOffer(await discovery.receive(timeoutMilliseconds: 12000))
            await discovery.close()
        } catch {
            await discovery.close()
            try Task.checkCancellation()
            throw discoveryFailure(error)
        }  // pair.ts:175
        try Task.checkCancellation()
        let guestIdentity = BackendSealedIdentity.generate()
        let channel = BackendRemoteGuestChannel(relayURL: offer.relayURL, hostID: offer.hostID, hostKey: offer.publicKey, identity: guestIdentity)
        let credential: String
        do {
            do { try await channel.open() } catch { throw NativeRPCError(code: "pair-unreachable", message: error.localizedDescription) }  // pair.ts:277
            try await channel.send(.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(canonical)),
                .init("device", .object([.init("name", .string(localName)), .init("platform", .string("darwin"))]))]))
            let frame: NativeRPCValue
            do { frame = try BackendRemoteGuestFrames.parse(await channel.receive(timeoutMilliseconds: 15000)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw NativeRPCError(code: "pair-unreachable", message: "That machine stopped answering part-way through pairing. Try the code again.") }  // pair.ts:197
            if frame["t"].string == "welcome" {
                guard let token = frame["token"].string, !token.isEmpty else {
                    throw NativeRPCError(code: "pair-refused", message: "That machine answered without a credential, so there is nothing to save.")  // pair.ts:225
                }
                credential = token
            } else {
                let said = frame["message"].string ?? ""
                throw NativeRPCError(code: "pair-refused", message: said.isEmpty ? "That machine refused the code." : said)  // pair.ts:246
            }
            await channel.close(); try Task.checkCancellation()
        } catch { await channel.close(); throw error }
        do {
            return try await store.remember(name: offer.name, secrets: .init(hostID: offer.hostID, hostPublicKey: offer.publicKey,
                relayURL: offer.relayURL, credential: credential, guestIdentity: guestIdentity), platform: offer.platform)
        } catch { throw NativeRPCError(code: "pair-refused", message: "That machine paired, but this one could not save it: \(error.localizedDescription)") }  // ipc.ts:801
    }
    static func discoveryFailure(_ error: Error) -> NativeRPCError {
        if let error = error as? NativeRPCError {
            if error.code == "pair-unreachable" { return error }
            if error.code == "machine-timeout" {
                return NativeRPCError(code: "pair-not-found", message: "No machine is showing that code. Check the digits, and that the code on the other machine has not run out — they last a minute.")
            }
        }
        return NativeRPCError(code: "pair-unreachable", message: "The pairing service could not complete the lookup. " + error.localizedDescription)
    }

    private static func parseOffer(_ text: String) throws -> BackendMachineOffer {
        let value = try NativeRPCValue.parseJSON(Data(text.utf8), maximumBytes: 4096)
        guard value["t"].string == "machine", let relay = value["relayUrl"].string, let hostID = value["hostId"].string,
              BackendRelayPacketCodec.isHostID(hostID), let encoded = value["publicKey"].string, let key = BackendRemoteTrustStorage.decodeURL(encoded) ?? BackendRemoteTrustStorage.base64(encoded),
              key.count == 32 else { throw NativeRPCError.malformed("That code answered with an invalid machine offer") }
        _ = try BackendRemoteRelayClient.target(relay)
        return .init(relayURL: relay, hostID: hostID, name: BackendRemoteProtocol.displayLabel(value["name"].string ?? "", maximumUnits: 64), platform: String((value["platform"].string ?? "").prefix(32)), publicKey: key)
    }
    public func sendFile(machineID: String, path: URL, directory: String?, context: NativeRPCContext) async throws -> String {
        let link = try link(machineID)
        guard let sender = uploads[machineID] else { throw NativeRPCError(code: "machine-offline", message: "This machine has no active upload sender") }
        return try await sender.send(file: path, directory: directory, guest: link, context: context)
    }
    public func cancelUpload(_ id: String) async -> Bool { await uploads[id]?.cancel() ?? false }
    public func reach(_ id: String, port: Int) async throws -> BackendRemoteGuestReach.Opened { guard let reach = reaches[id] else { throw NativeRPCError(code: "machine-offline", message: "This desktop is not connected to that machine.") }; return try await reach.open(port: port) }
    public func closeReach(_ id: String, port: Int) async { await reaches[id]?.close(port: port) }
    private func linkChanged(_ id: String, state: BackendMachineLinkState) async {
        if state.phase != .online && state.phase != .connecting { await uploads[id]?.disconnected(); await reaches[id]?.stop(); await tunnelsDropped(id) }
        // A screen of that Mac shown here asks again on a new welcome, and says "reconnecting" while the link is down.
        if state.phase == .online, online[id] != true { online[id] = true; await BackendRemoteMacScreens.shared.linkOnline(id) }
        if state.phase != .online, online[id] == true {
            online[id] = false
            // §11.3: no direct link is said plainly ("Can't reach … — this network blocks the direct connection.").
            let words = state.reason.flatMap { $0.hasPrefix("Can't reach") ? $0 : nil } ?? "Reconnecting to that Mac…"
            await BackendRemoteMacScreens.shared.linkLost(id, why: words)
        }
        await publish()
    }
    private func publish() async { if let snapshot = try? await view() { try? await registry.publish("machines:state", arguments: [snapshot]) } }
    private func output(_ id: String, session: String, text: String, replay: Bool) async { try? await registry.publish("machines:output", arguments: [.object([.init("machineId", .string(id)), .init("sessionId", .string(session)), .init("data", .string(text)), .init("replay", .bool(replay))])]) }
    private func uploadProgress(_ id: String, _ progress: BackendUploadProgress) async { try? await registry.publish("machines:upload:progress", arguments: [.object([.init("machineId", .string(id)), .init("progress", progress.value)])]) }
    private func peerFrame(_ id: String, _ frame: NativeRPCValue) async {
        await reaches[id]?.handle(frame)
        // Another Mac's screen shown here (Mac to Mac, 31 Oct): its pictures, states and refusals.
        await BackendRemoteMacScreens.shared.received(id, frame)
        let channels = ["hoot.state": ("machines:hoot:state", "state"), "hoot.chat": ("machines:hoot:chat", "chat"), "github.changed": ("machines:github:changed", "github")]
        if let (channel, key) = channels[frame["t"].string ?? ""] { try? await registry.publish(channel, arguments: [.object([.init("machineId", .string(id)), .init(key, key == "chat" ? frame : frame[key])])]) }
    }
    public func announceWindows(_ id: String) async throws { try await link(id).announceWindows() }
    public func announceSessions() async { for link in links.values { try? await link.announceSessions() } }
    /// The Mac woke, its network came back or it was unlocked: every link that is down dials now (Macky study, 9–10).
    public func nudgeAll() async { for link in links.values { await link.nudge() } }
    /// For Other Macs: the saved name of a linked machine.
    public func name(_ id: String) async -> String { (try? await store.list().first { $0.id == id }?.name) ?? id }
    public func askWindow(machineID: String, id: String, sessionID: String, tool: String, arguments: String) async throws { try await link(machineID).askWindow(id: id, sessionID: sessionID, tool: tool, arguments: arguments) }
}
