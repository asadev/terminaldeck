import Foundation
import TerminalDeckNativeCore

/// A live, local session resolved by the host. The incarnation must change on replacement/restart.
public struct BackendUIGSessionSimulatorIdentity: Sendable, Equatable {
    public let sessionID: String
    public let incarnation: String
    public init(sessionID: String, incarnation: String) { self.sessionID = sessionID; self.incarnation = incarnation }
}

public struct BackendUIGSessionSimulatorTicket: Sendable, Equatable {
    public let identity: BackendUIGSessionSimulatorIdentity
    public let revision: UUID
    public let deviceID: String?
    /// A session can show two devices at once (Asad, 2026-10-09): slot 0 is the first, 1 the second.
    public let slot: Int
    public init(identity: BackendUIGSessionSimulatorIdentity, revision: UUID, deviceID: String?, slot: Int = 0) {
        self.identity = identity; self.revision = revision; self.deviceID = deviceID; self.slot = slot
    }
    /// The relation's own key: the session, and the slot when it is the second.
    public var key: String { BackendUIGSessionSimulatorAttachments.key(identity.sessionID, slot: slot) }
    public var value: NativeRPCValue {
        BackendDeckToolsSupport.object([("sessionId", .string(identity.sessionID)), ("slot", .number(Double(slot))),
            ("attachmentToken", .string(revision.uuidString)), ("deviceId", deviceID.map(NativeRPCValue.string) ?? .null)])
    }
}

/// An ephemeral relation over the ONE existing device service. No engine, watcher or polling.
public actor BackendUIGSessionSimulatorAttachments {
    public typealias Resolve = @Sendable (String) async throws -> BackendUIGSessionSimulatorIdentity
    /// Host feeds its existing ordered registry event publisher. Never a second channel owner.
    public typealias Changed = @Sendable (NativeRPCValue) -> Void
    public static let changedEvent = "session-simulator:attachment"
    /// At most two devices per session.
    public static let slots = 0...1
    public static func key(_ sessionID: String, slot: Int) -> String { slot == 0 ? sessionID : sessionID + "#" + String(slot) }
    private let resolve: Resolve
    private let changed: Changed?
    private var rows: [String: BackendUIGSessionSimulatorTicket] = [:]
    private var epochs: [String: UUID] = [:]
    private var routedRounds: [String: BackendUIGSessionSimulatorTicket] = [:]
    private var invalidation: [UUID: [@Sendable () -> Void]] = [:]
    private let observerID = UUID()
    private var observing = false
    private var inventoryAt: TimeInterval?
    /// The one device list in progress, shared by every refresh meanwhile; it lets go of itself when it ends.
    private var inventoryTask: (id: UUID, work: Task<[NativeRPCValue], Error>)?
    /// How long a refresh or attach waits for the device list (devices freeze, 26 Oct 2026). Past it the shared
    /// list is let go, so the next call starts a fresh one, and a refresh goes on with the attachments it knows.
    private let inventoryWait: Double
    /// The longest an honest device list takes, from its own limits: the engine's listing (20 s) and the adb name
    /// reads of two emulators not seen before (5 s each), each with the device command grace, plus 5 s (44 s).
    public static let inventoryWaitDefault: Double =
        Double(20_000 + 2 * 5_000 + 3 * BackendAppDeviceDeadline.commandGraceMilliseconds) / 1_000 + 5
    private var aliases: [String: String] = [:]
    private var running: Set<String> = []
    public init(resolveLocalSession: @escaping Resolve, attachmentChanged: Changed? = nil, inventoryWait: Double = inventoryWaitDefault) {
        resolve = resolveLocalSession; changed = attachmentChanged; self.inventoryWait = inventoryWait
    }
    deinit { let id = observerID; Task { await BackendAppDeviceLifecycle.shared.remove(id) } }

    public func deviceExited(_ ids: Set<String>) {
        for ticket in Array(rows.values) {
            guard let id = ticket.deviceID, ids.contains(id) || aliases[id].map(ids.contains) == true else { continue }
            clear(ticket)
        }
    }
    private func clear(_ ticket: BackendUIGSessionSimulatorTicket) {
        guard rows[ticket.key] == ticket else { return }
        let empty = BackendUIGSessionSimulatorTicket(identity: ticket.identity, revision: UUID(), deviceID: nil, slot: ticket.slot)
        retire(ticket); running.remove(ticket.key); rows[ticket.key] = empty; epochs[ticket.key] = UUID(); changed?(empty.value)
    }
    /// Fresh inventory is the fallback for adopted devices and missed exit events. A slow/offline
    /// guest remains attached; an absent device or a previously running, now stopped simulator does not.
    public func refresh(service: any BackendDeckToolsMachinesDeviceService, devices supplied: [NativeRPCValue]? = nil, maximumAge: TimeInterval = 0) async throws {
        if !observing {
            observing = true
            await BackendAppDeviceLifecycle.shared.observe(observerID) { [weak self] ids in await self?.deviceExited(ids) }
        }
        if supplied == nil, let inventoryAt, maximumAge > 0,
           ProcessInfo.processInfo.systemUptime - inventoryAt < maximumAge { return }
        if await service.unavailable() != nil { return }
        let before = Array(rows.values)
        let devices: [NativeRPCValue]
        if let supplied { devices = supplied }
        else {
            // Devices freeze (26 Oct): this one shared list used to be waited for without end, so a single device
            // command that never came back held every device tool and panel call after it until a restart.
            do { devices = try await sharedInventory(service) }
            catch is BackendAppDeviceDeadline.Expired { return }
        }
        inventoryAt = ProcessInfo.processInfo.systemUptime
        var seen: Set<String> = []
        for ticket in before.sorted(by: { $0.slot < $1.slot }) {
            guard rows[ticket.key] == ticket, let id = ticket.deviceID else { continue }
            let row = devices.first { $0["id"].string == id }
                ?? (id.hasPrefix("avd:") ? devices.first { $0["avd"].string == String(id.dropFirst(4)) } : nil)
            guard let row else { clear(ticket); continue }
            if let avd = row["avd"].string { aliases[id] = "avd:" + avd }
            let duplicate = !seen.insert(ticket.identity.sessionID + "\u{0}" + (aliases[id] ?? id)).inserted
            if duplicate { clear(ticket); continue }
            if ["ready", "booting"].contains(row["state"].string ?? "") { running.insert(ticket.key) }
            else if row["state"].string == "shutdown", running.contains(ticket.key) { clear(ticket) }
        }
    }

    /// The shared device list, waited for at most `inventoryWait`; a caller that is cancelled stops waiting at once.
    private func sharedInventory(_ service: any BackendDeckToolsMachinesDeviceService) async throws -> [NativeRPCValue] {
        let current: (id: UUID, work: Task<[NativeRPCValue], Error>)
        if let inventoryTask { current = inventoryTask }
        else {
            let id = UUID()
            let work = Task { () async throws -> [NativeRPCValue] in
                do { let rows = try await service.list(); await self.inventoryEnded(id); return rows }
                catch { await self.inventoryEnded(id); throw error }
            }
            current = (id, work); inventoryTask = current
        }
        do {
            return try await BackendAppDeviceDeadline.run(within: inventoryWait, "The device list") { try await current.work.value }
        } catch let expired as BackendAppDeviceDeadline.Expired {
            if inventoryTask?.id == current.id { inventoryTask = nil; current.work.cancel() }
            throw expired
        }
    }
    private func inventoryEnded(_ id: UUID) { if inventoryTask?.id == id { inventoryTask = nil } }
    private func sameDevice(_ first: String?, _ second: String) -> Bool {
        guard let first else { return false }
        return (aliases[first] ?? first) == (aliases[second] ?? second)
    }
    private func epoch(_ key: String) -> UUID {
        if let value = epochs[key] { return value }
        let value = UUID(); epochs[key] = value; return value
    }
    private func live(_ id: String, slot: Int = 0) async throws -> BackendUIGSessionSimulatorIdentity {
        guard !id.isEmpty else { throw Self.refused("A live local session is required.") }
        guard Self.slots.contains(slot) else { throw Self.refused("A session can show at most two devices.") }
        let key = Self.key(id, slot: slot)
        let before = epoch(key)
        let identity: BackendUIGSessionSimulatorIdentity
        do { identity = try await resolve(id) }
        catch { invalidate(sessionID: id); throw error }
        guard identity.sessionID == id, !identity.incarnation.isEmpty, epoch(key) == before else {
            throw Self.stale()
        }
        return identity
    }
    public func snapshot(sessionID: String, slot: Int = 0) async throws -> BackendUIGSessionSimulatorTicket {
        let identity = try await live(sessionID, slot: slot)
        let key = Self.key(sessionID, slot: slot)
        if let row = rows[key], row.identity == identity { return row }
        // A reused id must not inherit an attachment from its previous process.
        let row = BackendUIGSessionSimulatorTicket(identity: identity, revision: UUID(), deviceID: nil, slot: slot)
        retire(rows[key]); rows[key] = row; epochs[key] = UUID(); changed?(row.value); return row
    }
    /// The devices this session has attached now (one or two), first slot first.
    /// Which sessions each device is attached to now (device id → session ids, sorted), for the phones' session header
    /// (Asad, 1 Nov, item 45). Read as is: the phone's list is a picture of now, not a validation.
    public func sessionsByDevice() -> [String: [String]] {
        Self.sessionsByDevice(rows.values.compactMap { ticket in ticket.deviceID.map { ($0, ticket.identity.sessionID) } },
                              aliases: aliases)
    }

    /// Each device's sessions under EVERY id it goes by: the id it was attached as, and its alias (a running emulator
    /// is `android:emulator-5554` in the device list and `avd:Name` once its AVD is known). Keyed by the alias alone,
    /// the phone's row for the running emulator found nothing (1 Nov, item 56: "the emulator connected to this
    /// session is not showing here").
    public static func sessionsByDevice(_ attached: [(device: String, session: String)], aliases: [String: String]) -> [String: [String]] {
        var result: [String: Set<String>] = [:]
        let reverse = Dictionary(aliases.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        for (device, session) in attached {
            for id in Set([device, aliases[device], reverse[device]].compactMap { $0 }) { result[id, default: []].insert(session) }
        }
        return result.mapValues { $0.sorted() }
    }

    public func attached(sessionID: String) async throws -> [BackendUIGSessionSimulatorTicket] {
        var result: [BackendUIGSessionSimulatorTicket] = []
        for slot in Self.slots {
            let row = try await snapshot(sessionID: sessionID, slot: slot)
            if row.deviceID != nil { result.append(row) }
        }
        return result
    }
    public func attach(sessionID: String, deviceID: String, slot: Int = 0, service: any BackendDeckToolsMachinesDeviceService) async throws -> BackendUIGSessionSimulatorTicket {
        _ = try BackendDeckToolsMachinesDeviceRules.id(.object([.init("deviceId", .string(deviceID))]))
        try await refresh(service: service)
        let before = try await snapshot(sessionID: sessionID, slot: slot)
        // The same device cannot fill both of a session's places.
        for other in Self.slots where other != slot {
            if let row = rows[Self.key(sessionID, slot: other)], row.identity == before.identity, sameDevice(row.deviceID, deviceID) {
                throw Self.refused("That device is already open in this session.")
            }
        }
        if let reason = await service.unavailable() { throw NativeRPCError(code: "unavailable", message: reason) }
        let devices = try await BackendAppDeviceDeadline.run(within: inventoryWait, "The device list") { try await service.list() }
        try await validate(before)
        guard devices.contains(where: { $0["id"].string == deviceID }) else { throw Self.refused("That device is not on this Mac. Refresh the device list.") }
        if let avd = devices.first(where: { $0["id"].string == deviceID })?["avd"].string { aliases[deviceID] = "avd:" + avd }
        // Repeat after the last await: another slot may have attached while inventory was loading.
        for other in Self.slots where other != slot {
            if let row = rows[Self.key(sessionID, slot: other)], row.identity == before.identity, sameDevice(row.deviceID, deviceID) {
                throw Self.refused("That device is already open in this session.")
            }
        }
        if before.deviceID == deviceID { return before }
        let key = before.key
        let row = BackendUIGSessionSimulatorTicket(identity: before.identity, revision: UUID(), deviceID: deviceID, slot: slot)
        retire(before); running.remove(key)
        if let device = devices.first(where: { $0["id"].string == deviceID }) {
            if ["ready", "booting"].contains(device["state"].string ?? "") { running.insert(key) }
            if let avd = device["avd"].string { aliases[deviceID] = "avd:" + avd }
        }
        rows[key] = row; epochs[key] = UUID(); changed?(row.value); return row
    }
    public func detach(sessionID: String, slot: Int = 0, expected: BackendUIGSessionSimulatorTicket? = nil) async throws -> BackendUIGSessionSimulatorTicket {
        let before = try await snapshot(sessionID: sessionID, slot: slot)
        if let expected { try await validate(expected) }
        let key = before.key
        let row = BackendUIGSessionSimulatorTicket(identity: before.identity, revision: UUID(), deviceID: nil, slot: slot)
        retire(before); running.remove(key); rows[key] = row; epochs[key] = UUID(); changed?(row.value); return row
    }
    /// Android boot legitimately changes avd:name into android:emulator-N. Only that boot reply may replace it.
    public func booted(_ ticket: BackendUIGSessionSimulatorTicket, as deviceID: String) async throws -> BackendUIGSessionSimulatorTicket {
        try await validate(ticket)
        guard ticket.deviceID?.hasPrefix("avd:") == true, deviceID.hasPrefix("android:emulator-") else { throw Self.stale() }
        _ = try BackendDeckToolsMachinesDeviceRules.id(.object([.init("deviceId", .string(deviceID))]))
        if let existing = rows.values.first(where: { $0.identity == ticket.identity && $0.key != ticket.key && $0.deviceID == deviceID }) {
            clear(ticket); return existing
        }
        aliases[deviceID] = ticket.deviceID; running.insert(ticket.key)
        let row = BackendUIGSessionSimulatorTicket(identity: ticket.identity, revision: UUID(), deviceID: deviceID, slot: ticket.slot)
        retire(ticket); rows[ticket.key] = row; epochs[ticket.key] = UUID(); changed?(row.value); return row
    }
    /// Wire this to exit/remove/rekey; per-call live resolution also independently rejects stale sessions.
    public func invalidate(sessionID: String) {
        for slot in Self.slots {
            let key = Self.key(sessionID, slot: slot)
            if let previous = rows[key] {
                retire(previous)
                let detached = BackendUIGSessionSimulatorTicket(identity: previous.identity, revision: UUID(), deviceID: nil, slot: slot)
                changed?(detached.value.setting("invalidated", .bool(true)))
            }
            rows[key] = nil; epochs[key] = UUID()
        }
    }
    public func reset() {
        for id in Set(rows.values.map { $0.identity.sessionID }) { invalidate(sessionID: id) }
        for id in epochs.keys { epochs[id] = UUID() }; routedRounds.removeAll()
    }
    private func retire(_ ticket: BackendUIGSessionSimulatorTicket?) {
        guard let ticket else { return }; let callbacks = invalidation.removeValue(forKey: ticket.revision) ?? []
        for callback in callbacks { callback() }
    }
    public func onInvalidated(_ ticket: BackendUIGSessionSimulatorTicket, _ callback: @escaping @Sendable () -> Void) async throws {
        try await validate(ticket); invalidation[ticket.revision, default: []].append(callback)
    }
    public func validate(_ ticket: BackendUIGSessionSimulatorTicket, deviceID: String? = nil) async throws {
        let identity = try await live(ticket.identity.sessionID, slot: ticket.slot)
        if identity != ticket.identity { invalidate(sessionID: ticket.identity.sessionID); throw Self.stale() }
        guard identity == ticket.identity, rows[ticket.key] == ticket,
              deviceID == nil || ticket.deviceID == deviceID else { throw Self.stale() }
    }
    public func ticket(sessionID: String, token: String, deviceID: String?, slot: Int = 0) async throws -> BackendUIGSessionSimulatorTicket {
        let row = try await snapshot(sessionID: sessionID, slot: slot)
        guard row.revision.uuidString == token, row.deviceID == deviceID else { throw Self.stale() }
        return row
    }
    /// Call after the existing one-message handoff succeeds; allows only this incarnation's sent rounds.
    public func noteSent(roundID: String, ticket: BackendUIGSessionSimulatorTicket) async throws {
        try await validate(ticket); routedRounds[roundID] = ticket
    }
    public func ownsRound(_ roundID: String, ticket: BackendUIGSessionSimulatorTicket) -> Bool {
        guard let sent = routedRounds[roundID] else { return false }
        return sent.identity == ticket.identity && sent.deviceID == ticket.deviceID
    }
    static func refused(_ message: String) -> NativeRPCError { .init(code: "not-permitted", message: message) }
    static func stale() -> NativeRPCError { refused("The session or attached device changed. Refresh the attachment before trying again.") }
}
