import Foundation
import SwiftTerm
import TerminalDeckNativeCore

/// The existing agent-controls owner supplies these functions. Server controls
/// see only this shadow screen; local settings/transcripts/environment are not
/// a witness for a program running on another machine.
public struct BackendServersControlAccess: Sendable {
    public let screen: @Sendable (String) async -> String?
    public let write: @Sendable (String, String) async throws -> Void
    public let onThisMachine = false
    public init(screen: @escaping @Sendable (String) async -> String?, write: @escaping @Sendable (String, String) async throws -> Void) { self.screen = screen; self.write = write }
}
public protocol BackendServersAgentControls: Sendable {
    func read(shellId: String, access: BackendServersControlAccess) async throws -> NativeRPCValue
    func apply(shellId: String, control: String, value: String, access: BackendServersControlAccess) async throws -> NativeRPCValue
}
public struct BackendServersShellHooks: Sendable {
    public let arm: @Sendable (String, String) async throws -> NativeRPCValue
    public let disarm: @Sendable (String) async -> Void
    public let cancelSetup: @Sendable (String) async -> Void
    public let whyNot: @Sendable (String) async -> String?
    public let belonging: @Sendable (String) async -> NativeRPCValue?
    public let publish: @Sendable (NativeRPCContext, String, NativeRPCValue) async throws -> Void
    public let report: @Sendable (NativeRPCError) -> Void
    public let controls: (any BackendServersAgentControls)?
    public init(arm: @escaping @Sendable (String, String) async throws -> NativeRPCValue,
                disarm: @escaping @Sendable (String) async -> Void, cancelSetup: @escaping @Sendable (String) async -> Void,
                whyNot: @escaping @Sendable (String) async -> String?,
                belonging: @escaping @Sendable (String) async -> NativeRPCValue?,
                publish: @escaping @Sendable (NativeRPCContext, String, NativeRPCValue) async throws -> Void,
                report: @escaping @Sendable (NativeRPCError) -> Void, controls: (any BackendServersAgentControls)?) {
        self.arm = arm; self.disarm = disarm; self.cancelSetup = cancelSetup; self.whyNot = whyNot; self.belonging = belonging
        self.publish = publish; self.report = report; self.controls = controls
    }
}
public actor BackendServersShells: BackendDeckToolsMachinesServerShells {
    private struct Slot: Sendable {
        let server: String, owner: NativeRPCContext, openedAt: Double
        let shell: any BackendServersShell, screen: BackendServersShadowScreen
        var subscriptions: [BackendServersUnsubscribe]
        let events: BackendServersShellEvents
        var delivery: Task<Void, Never>?
    }
    private let room: BackendServersCoordinator, connections: BackendServersConnections, store: BackendServersStore
    private let hooks: BackendServersShellHooks, now: @Sendable () -> Double
    private var slots: [String: Slot] = [:]
    private var former: [String: String] = [:]
    private var stopped = false
    private var pendingOpens: Set<UUID> = []
    private var stoppedWaiters: [CheckedContinuation<Void, Never>] = []
    public init(room: BackendServersCoordinator, connections: BackendServersConnections, store: BackendServersStore,
                hooks: BackendServersShellHooks, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.room = room; self.connections = connections; self.store = store; self.hooks = hooks; self.now = now
    }
    public func open(_ server: String, cols: NativeRPCValue, rows: NativeRPCValue, startIn: NativeRPCValue,
                     caller: BackendServersCaller) async throws -> NativeRPCValue {
        guard !stopped else { throw NativeRPCError(code: "closed", message: "The server terminal owner is stopped.") }
        let openingTicket = UUID(); pendingOpens.insert(openingTicket)
        defer {
            pendingOpens.remove(openingTicket)
            if pendingOpens.isEmpty { let waiters = stoppedWaiters; stoppedWaiters = []; for waiter in waiters { waiter.resume() } }
        }
        let lifetime = room.serverLifetime(server)
        try await room.check(caller, .init(operation: "servers:shell:open", serverId: server, tier: .alter))
        guard caller.actsAsOwner else { throw NativeRPCError(code: "not-granted", message: "A paired device cannot open an unrestricted terminal on a server.") }
        let size = BackendServersTerminalSize(cols: BackendServersWire.integer(cols, fallback: 120, minimum: 1, maximum: 1000),
                                             rows: BackendServersWire.integer(rows, fallback: 30, minimum: 1, maximum: 1000))
        let named = startIn.string.flatMap { $0.isEmpty ? nil : $0 }, folder = try named ?? store.get(server)?.startIn
        let id = server + " " + UUID().uuidString.lowercased()
        var hold: BackendServersConnectionLease?
        do { hold = try await connections.acquireLease(server) } catch { /* The shell's own dial supplies its final sentence. */ }
        var arm: NativeRPCValue
        do { arm = try await hooks.arm(server, id) }
        catch { arm = .object([.init("ok", .bool(false)), .init("why", .string(error.localizedDescription))]) }
        do {
            guard !stopped else { throw CancellationError() }
            try await room.requireLiveServer(server, lifetime: lifetime)
            let shell = try await connections.shell(server, size: size, startIn: folder)
            do { guard !stopped else { throw CancellationError() }; try await room.requireLiveServer(server, lifetime: lifetime) }
            catch { shell.close(); throw error }
            let screen = BackendServersShadowScreen(cols: size.cols, rows: size.rows)
            let events = BackendServersShellEvents()
            slots[id] = Slot(server: server, owner: caller.context, openedAt: now(), shell: shell, screen: screen, subscriptions: [], events: events, delivery: nil)
            former[id] = server
            let data = shell.onData { text in
                screen.push(text)
                events.append(.data(text))
            }
            let end = shell.onClose { events.append(.ended) }
            slots[id]?.subscriptions = [data, end]
            slots[id]?.delivery = Task { [weak self] in
                for await event in events.stream {
                    guard !Task.isCancelled, let self else { break }
                    switch event {
                    case .data(let text): await self.received(id, data: text)
                    case .ended: await self.drop(id, closeRemote: false); return
                    }
                }
            }
            if arm["ok"].bool == true, let line = arm["line"].string { shell.write(line) }
            if let hold { await connections.release(hold) }
            return BackendServersWire.ok([.init("shellId", .string(id))])
        } catch {
            await hooks.disarm(id); if let hold { await connections.release(hold) }; throw error
        }
    }
    private func received(_ id: String, data: String) async {
        guard let slot = slots[id] else { return }
        do { try await hooks.publish(slot.owner, "servers:shell:output", .object([.init("shellId", .string(id)), .init("data", .string(data))])) }
        catch { hooks.report(NativeRPCError(code: "servers-shell-output", message: "A server terminal output subscriber disconnected.")) }
    }
    public func shell(_ id: String, server: String, caller: BackendServersCaller) async throws -> any BackendServersShell {
        guard let slot = slots[id] else { throw BackendServersActionRefused("That terminal is not open any more.") }
        guard slot.server == server else { throw BackendServersActionRefused("That terminal is on a different server.") }
        try await room.check(caller, .init(operation: "servers:shell:use", serverId: server, shellId: id, tier: .alter))
        guard caller.kind == .nativeUI || slot.owner.ownerID == caller.context.ownerID else { throw NativeRPCError(code: "not-permitted", message: "That terminal belongs to another surface.") }
        return slot.shell
    }
    public func write(_ id: String, data: String, caller: BackendServersCaller) async throws -> NativeRPCValue {
        guard let slot = slots[id] else { return .object([.init("written", .bool(false))]) }
        _ = try await shell(id, server: slot.server, caller: caller)
        slot.shell.write(data); return .object([.init("written", .bool(true))])
    }
    public func resize(_ id: String, cols: NativeRPCValue, rows: NativeRPCValue, caller: BackendServersCaller) async throws -> NativeRPCValue {
        guard let slot = slots[id] else { return .object([.init("resized", .bool(false))]) }
        _ = try await shell(id, server: slot.server, caller: caller)
        let size = BackendServersTerminalSize(cols: BackendServersWire.integer(cols, fallback: 120, minimum: 1, maximum: 1000), rows: BackendServersWire.integer(rows, fallback: 30, minimum: 1, maximum: 1000))
        slot.shell.resize(size); slot.screen.resize(cols: size.cols, rows: size.rows)
        return .object([.init("resized", .bool(true))])
    }
    public func close(_ id: String, caller: BackendServersCaller) async throws -> NativeRPCValue {
        guard let slot = slots[id] else { return .object([.init("closed", .bool(false))]) }
        _ = try await shell(id, server: slot.server, caller: caller)
        await drop(id, closeRemote: true); return .object([.init("closed", .bool(true))])
    }
    private func drop(_ id: String, closeRemote: Bool) async {
        guard let slot = slots.removeValue(forKey: id) else { return }
        for cancel in slot.subscriptions { cancel() }; slot.events.finish()
        if closeRemote { slot.delivery?.cancel(); slot.shell.close() }
        slot.screen.dispose()
        await hooks.cancelSetup(slot.server); await hooks.disarm(id)
        do { try await hooks.publish(slot.owner, "servers:shell:closed", .object([.init("shellId", .string(id))])) }
        catch { hooks.report(NativeRPCError(code: "servers-shell-closed", message: "A server terminal close subscriber disconnected.")) }
    }
    public func forgetServer(_ server: String) async { for id in slots.filter({ $0.value.server == server }).map(\.key) { await drop(id, closeRemote: true) } }
    public func disconnectOwner(_ owner: String) async { for id in slots.filter({ $0.value.owner.ownerID == owner }).map(\.key) { await drop(id, closeRemote: true) } }
    public func beginStopping() { stopped = true }
    public func stop() async {
        beginStopping(); for id in Array(slots.keys) { await drop(id, closeRemote: true) }
        if !pendingOpens.isEmpty { await withCheckedContinuation { stoppedWaiters.append($0) } }
        former = [:]
    }
    public func serverOfShell(_ id: String) -> String? { slots[id]?.server }
    public func historicalServerOfShell(_ id: String) -> String? {
        if let server = slots[id]?.server ?? former[id] { return server }
        // ipc.ts's private serverOf fallback also supports a retained tab
        // after app restart. The live browser binding API above never parses.
        guard let space = id.firstIndex(of: " "), space != id.startIndex else { return nil }
        return String(id[..<space])
    }
    public func whyNotDrive(_ id: String) async -> String? { await hooks.whyNot(id) }
    public func belongingOf(_ id: String) async -> NativeRPCValue? { await hooks.belonging(id) }
    public func openShells() -> [NativeRPCValue] { slots.sorted { $0.value.openedAt < $1.value.openedAt }.map { id, slot in
        .object([.init("shellId", .string(id)), .init("serverId", .string(slot.server)), .init("openedAt", .number(slot.openedAt))])
    } }
    public func shellScreen(_ id: String) -> String? { screen(id) }
    public func screen(_ id: String) -> String? { slots[id]?.screen.viewport() }
    private func controlAccess(_ caller: BackendServersCaller) -> BackendServersControlAccess {
        .init(screen: { [weak self] id in await self?.screen(id) }, write: { [weak self] id, data in
            guard let self else { throw CancellationError() }; _ = try await self.write(id, data: data, caller: caller)
        })
    }
    public func readControls(_ id: String, caller: BackendServersCaller) async throws -> NativeRPCValue {
        guard let slot = slots[id] else { return .null }
        try await room.check(caller, .init(operation: "servers:controls:read", serverId: slot.server, shellId: id, tier: .read))
        guard let controls = hooks.controls else { throw NativeRPCError(code: "unavailable", message: "The native agent control reader has not been supplied.") }
        return try await controls.read(shellId: id, access: controlAccess(caller))
    }
    public func applyControls(_ id: String, control: String, value: String, caller: BackendServersCaller) async throws -> NativeRPCValue {
        let unread = NativeRPCValue.object([.init("value", .null), .init("label", .null), .init("source", .null)])
        guard ["model", "effort", "fast", "permission"].contains(control), !value.isEmpty else { return .object([.init("ok", .bool(false)), .init("message", .string("That is not a control this app can set.")), .init("reading", unread)]) }
        guard let slot = slots[id] else { return .object([.init("ok", .bool(false)), .init("message", .string("That session is no longer running.")), .init("reading", unread)]) }
        try await room.check(caller, .init(operation: "servers:controls:apply", serverId: slot.server, shellId: id, tier: .alter))
        guard let controls = hooks.controls else { throw NativeRPCError(code: "unavailable", message: "The native agent control writer has not been supplied.") }
        return try await controls.apply(shellId: id, control: control, value: value, access: controlAccess(caller))
    }
}

/// SSH callbacks produce ordered data followed by EOF. A single consumer awaits
/// each broadcast before handling EOF, so actor task scheduling cannot discard
/// a final chunk. Unbounded buffering matches the source terminal stream; this
/// is a transient delivery queue, never a retained transcript or account source.
final class BackendServersShellEvents: @unchecked Sendable {
    enum Event: Sendable, Equatable { case data(String), ended }
    let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let lock = NSLock()
    private var ended = false
    init() {
        let pair = AsyncStream<Event>.makeStream()
        stream = pair.stream; continuation = pair.continuation
    }
    func append(_ event: Event) {
        lock.withLock {
            guard !ended else { return }
            continuation.yield(event)
            if event == .ended { ended = true; continuation.finish() }
        }
    }
    func finish() { lock.withLock { ended = true; continuation.finish() } }
}

/// One parser per actual SSH shell; both controls and UI snapshots read it.
/// It parses output but never sends duplicate DSR/DA protocol replies.
private final class BackendServersShadowScreen: TerminalDelegate, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var terminal: Terminal!
    private var closed = false
    init(cols: Int, rows: Int) { terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, termName: "xterm-256color", scrollback: 4_000)) }
    func push(_ text: String) { lock.withLock { if !closed { terminal.feed(byteArray: Array(text.utf8)) } } }
    func resize(cols: Int, rows: Int) { lock.withLock { if !closed { terminal.resize(cols: cols, rows: rows) } } }
    func viewport() -> String? { lock.withLock { closed ? nil : (0..<terminal.getDims().rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n") } }
    func dispose() { lock.withLock { closed = true } }
    func send(source: Terminal, data: ArraySlice<UInt8>) { }
}
