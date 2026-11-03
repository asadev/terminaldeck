import Foundation
import TerminalDeckNativeCore

/// A per-call authority adapter. All validation and device execution remain in the existing tools/service.
public actor BackendUIGSessionSimulatorDeviceService: BackendDeckToolsMachinesDeviceService {
    public typealias V = NativeRPCValue
    private let base: any BackendDeckToolsMachinesDeviceService
    private let attachments: BackendUIGSessionSimulatorAttachments
    /// The session's attached devices (one or two): each can be addressed by its id.
    private var tickets: [BackendUIGSessionSimulatorTicket]
    private let cancellation: BackendMCPCancellation?
    public init(base: any BackendDeckToolsMachinesDeviceService, attachments: BackendUIGSessionSimulatorAttachments,
                ticket: BackendUIGSessionSimulatorTicket, cancellation: BackendMCPCancellation? = nil) {
        self.base = base; self.attachments = attachments; self.tickets = [ticket]; self.cancellation = cancellation
    }
    public init(base: any BackendDeckToolsMachinesDeviceService, attachments: BackendUIGSessionSimulatorAttachments,
                tickets: [BackendUIGSessionSimulatorTicket], cancellation: BackendMCPCancellation? = nil) {
        self.base = base; self.attachments = attachments; self.tickets = tickets; self.cancellation = cancellation
    }
    private var attachedIDs: Set<String> { Set(tickets.compactMap(\.deviceID)) }
    private func check(_ id: String? = nil) async throws {
        if Task.isCancelled || cancellation?.isCancelled == true { throw CancellationError() }
        try await attachments.refresh(service: base, maximumAge: 1)
        if let id {
            guard let ticket = tickets.first(where: { $0.deviceID == id }) else { throw BackendUIGSessionSimulatorAttachments.stale() }
            try await attachments.validate(ticket, deviceID: id)
        } else {
            for ticket in tickets { try await attachments.validate(ticket) }
        }
        if Task.isCancelled || cancellation?.isCancelled == true { throw CancellationError() }
    }
    public func unavailable() async -> String? { await base.unavailable() }
    public func list() async throws -> [V] {
        try await check()
        let ids = attachedIDs
        guard !ids.isEmpty else { return [] }
        let rows = try await base.list(); try await check(); return rows.filter { ids.contains($0["id"].string ?? "") }
    }
    /// devices.list for a session (13 Oct): every device on this Mac, its own panel's first, each marked
    /// inThisPanel. Listing showed only the panel's devices, so a session with an empty panel was told the
    /// Mac had no simulator or emulator at all and could not pick one for devices_open_app. Driving stays
    /// limited to the panel's devices (every other call checks the ticket).
    public func catalogue() async throws -> [V] {
        try await check()
        let ids = attachedIDs, rows = try await base.list(); try await check()
        let marked = rows.map { $0.setting("inThisPanel", .bool(ids.contains($0["id"].string ?? ""))) }
        return marked.filter { $0["inThisPanel"].bool == true } + marked.filter { $0["inThisPanel"].bool != true }
    }
    public func emptyReason() async -> String? { await base.emptyReason() }
    public func boot(_ id: String) async throws -> V {
        try await check(id); let value = try await base.boot(id)
        if value["ok"].bool == true, let next = value["id"].string, next != id,
           let index = tickets.firstIndex(where: { $0.deviceID == id }) {
            tickets[index] = try await attachments.booted(tickets[index], as: next)
        }
        return value
    }
    public func shutDown(_ id: String) async throws -> V {
        try await check(id); let value = try await base.shutDown(id)
        try await attachments.refresh(service: base); return value
    }
    private func perform<T: Sendable>(_ id: String, _ operation: @Sendable () async throws -> T) async throws -> T {
        try await check(id)
        do { let value = try await operation(); try await check(id); return value }
        catch { try? await attachments.refresh(service: base); throw error }
    }
    public func open(_ id: String) async throws -> V { try await perform(id) { try await base.open(id) } }
    public func screenshot(_ id: String) async throws -> V { try await perform(id) { try await base.screenshot(id) } }
    public func tap(_ id: String, x: Double, y: Double, holdMS: Int?) async throws {
        try await perform(id) { try await base.tap(id, x: x, y: y, holdMS: holdMS) }
    }
    public func swipe(_ id: String, from: V, to: V, durationMS: Int) async throws {
        try await perform(id) { try await base.swipe(id, from: from, to: to, durationMS: durationMS) }
    }
    public func type(_ id: String, text: String) async throws { try await perform(id) { try await base.type(id, text: text) } }
    public func key(_ id: String, key: String, modifiers: [String]) async throws { try await perform(id) { try await base.key(id, key: key, modifiers: modifiers) } }
    public func button(_ id: String, button: String) async throws { try await perform(id) { try await base.button(id, button: button) } }
    public func rotate(_ id: String, to: String) async throws -> String { try await perform(id) { try await base.rotate(id, to: to) } }
    public func tree(_ id: String, scope: String) async throws -> BackendDeckToolsMachinesDeviceTreeAnswer { try await perform(id) { try await base.tree(id, scope: scope) } }
    public func rounds() async throws -> [V] {
        try await check()
        let rows = try await base.rounds(); try await check()
        var result: [V] = []
        for ticket in tickets {
            guard let id = ticket.deviceID else { continue }
            for row in rows where row["where"]["kind"].string == "device" && row["where"]["deviceId"].string == id {
                if await attachments.ownsRound(row["id"].string ?? "", ticket: ticket) { result.append(row) }
            }
        }
        try await check(); return result
    }
}
