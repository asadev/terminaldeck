import Foundation

/// Retain for the lifetime of a listener. Explicit cancellation and deinit both
/// remove it once; disconnecting its owner also removes every owned listener.
public final class NativeRPCSubscription: @unchecked Sendable {
    public let id: UUID
    private let lock = NSLock()
    private var action: (@Sendable () async -> Void)?
    public init(id: UUID = UUID(), cancel: @escaping @Sendable () async -> Void) { self.id = id; action = cancel }
    private func takeAction() -> (@Sendable () async -> Void)? {
        lock.lock(); let cancel = action; action = nil; lock.unlock()
        return cancel
    }
    public func cancel() { if let action = takeAction() { Task { await action() } } }
    public func cancelAndWait() async { await takeAction()?() }
    deinit { cancel() }
}

public struct NativeRPCEvent: Sendable {
    public let sequence: UInt64
    public let channel: String
    public let arguments: [NativeRPCValue]
    public let ownerID: String?
    public var wireValue: NativeRPCValue {
        .object([.init("channel", .string(channel)), .init("args", .array(arguments))])
    }
}

/// The native replacement for ipcMain's invoke/send registry. Register actual
/// domain handlers, then let HTTP, native screens or MCP supply a caller context.
public actor NativeChannelRegistry {
    public typealias Handler = @Sendable (NativeRPCContext, [NativeRPCValue]) async throws -> NativeRPCValue
    public typealias SendHandler = @Sendable (NativeRPCContext, [NativeRPCValue]) async throws -> Void
    public typealias EventHandler = @Sendable (NativeRPCEvent) async throws -> Void
    public typealias Policy = @Sendable (NativeRPCContext) throws -> Void

    private struct Registration: Sendable { let ownerID: String; let policy: Policy; let handler: Handler }
    private struct SendRegistration: Sendable { let id: UUID; let ownerID: String; let policy: Policy; let handler: SendHandler }
    private struct EventRegistration: Sendable { let id: UUID; let ownerID: String; let handler: EventHandler; let finish: @Sendable () -> Void }
    private struct Pending: Sendable { let ownerID: String; let task: Task<NativeRPCValue, Error> }
    private var handlers: [String: Registration] = [:]
    private var sendHandlers: [String: [SendRegistration]] = [:]
    private var eventHandlers: [String: [EventRegistration]] = [:]
    private var pending: [UUID: Pending] = [:]
    private var sequence: UInt64 = 0
    private var closed = false
    private let report: @Sendable (NativeRPCError) -> Void

    public init(report: @escaping @Sendable (NativeRPCError) -> Void = { _ in }) { self.report = report }

    public static func isBridgeChannel(_ channel: String) -> Bool {
        !channel.isEmpty && channel.count <= 200 && !channel.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value == 0 })
        && !channel.hasPrefix("-") && !channel.hasPrefix("ELECTRON_") && !["error", "newListener", "removeListener"].contains(channel)
    }

    public func register(_ channel: String, ownerID: String, policy: @escaping Policy = { _ in }, handler: @escaping Handler) throws {
        try usable(channel)
        guard handlers[channel] == nil else { throw NativeRPCError(code: "duplicate-handler", message: "A handler is already registered for '\(channel)'") }
        handlers[channel] = Registration(ownerID: ownerID, policy: policy, handler: handler)
    }

    public func removeHandler(_ channel: String, ownerID: String? = nil) {
        guard ownerID == nil || handlers[channel]?.ownerID == ownerID else { return }
        handlers[channel] = nil
    }

    public func has(_ channel: String) -> Bool { handlers[channel] != nil }
    public func channels() -> [String] { handlers.keys.sorted() }
    public func hasSend(_ channel: String) -> Bool { !(sendHandlers[channel] ?? []).isEmpty }
    public func sends() -> [String] { sendHandlers.keys.sorted() }
    public func registrationOwner(of channel: String) -> String? { handlers[channel]?.ownerID }
    public func sendOwners(of channel: String) -> Set<String> { Set((sendHandlers[channel] ?? []).map(\.ownerID)) }

    /// The composition root's event fanout observes the same ordered events as
    /// channel listeners. Owner filtering still applies to this subscription.
    public func subscribeAll(ownerID: String, handler: @escaping EventHandler) throws -> NativeRPCSubscription {
        try subscribe("*", ownerID: ownerID, handler: handler)
    }

    public func invoke(_ channel: String, context: NativeRPCContext, arguments: [NativeRPCValue]) async throws -> NativeRPCValue {
        try usable(channel)
        guard let registration = handlers[channel] else { throw NativeRPCError(code: "missing-handler", message: "No handler registered for '\(channel)'") }
        guard pending[context.requestID] == nil else { throw NativeRPCError(code: "duplicate-request", message: "This request is already in flight") }
        try registration.policy(context)
        let task = Task {
            try Task.checkCancellation()
            return try await NativeCompositionCallContext.$rpc.withValue(context) {
                try await registration.handler(context, arguments)
            }
        }
        pending[context.requestID] = Pending(ownerID: context.ownerID, task: task)
        defer { pending[context.requestID] = nil }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            return value
        } catch { throw NativeRPCError.wrapping(error) }
    }

    /// Exact bridge envelope: undefined results omit value; errors retain the
    /// string field old consumers read and add structured detail for native ones.
    public func invokeEnvelope(_ request: NativeRPCRequest, context: NativeRPCContext) async -> NativeRPCValue {
        do {
            return .object([.init("ok", .bool(true)), .init("value", try await invoke(request.channel, context: context, arguments: request.arguments))])
        } catch {
            let error = NativeRPCError.wrapping(error)
            return .object([.init("ok", .bool(false)), .init("error", .string(error.message)), .init("failure", error.wireValue)])
        }
    }

    public func onSend(_ channel: String, ownerID: String, policy: @escaping Policy = { _ in }, handler: @escaping SendHandler) throws -> NativeRPCSubscription {
        try usable(channel)
        let id = UUID()
        sendHandlers[channel, default: []].append(SendRegistration(id: id, ownerID: ownerID, policy: policy, handler: handler))
        return NativeRPCSubscription(id: id) { [weak self] in await self?.removeSubscription(id) }
    }

    /// All listeners observe one send in registration order. A throwing listener
    /// is reported and never prevents another registered listener from receiving.
    @discardableResult
    public func send(_ channel: String, context: NativeRPCContext, arguments: [NativeRPCValue]) async throws -> Bool {
        try usable(channel)
        let listeners = sendHandlers[channel] ?? []
        for listener in listeners { try listener.policy(context) }
        for listener in listeners {
            guard sendHandlers[channel]?.contains(where: { $0.id == listener.id }) == true else { continue }
            do {
                try await NativeCompositionCallContext.$rpc.withValue(context) {
                    try await listener.handler(context, arguments)
                }
            }
            catch { report(NativeRPCError.wrapping(error)) }
        }
        return !listeners.isEmpty
    }

    public func subscribe(_ channel: String, ownerID: String, handler: @escaping EventHandler) throws -> NativeRPCSubscription {
        try usable(channel)
        let id = UUID()
        eventHandlers[channel, default: []].append(EventRegistration(id: id, ownerID: ownerID, handler: handler, finish: {}))
        return NativeRPCSubscription(id: id) { [weak self] in await self?.removeSubscription(id) }
    }

    public func events(_ channel: String, ownerID: String) throws -> AsyncThrowingStream<NativeRPCEvent, Error> {
        try usable(channel)
        let pair = AsyncThrowingStream<NativeRPCEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        eventHandlers[channel, default: []].append(EventRegistration(id: id, ownerID: ownerID, handler: { event in
            if case .dropped = pair.continuation.yield(event) {
                pair.continuation.finish(throwing: NativeRPCError(code: "event-overflow", message: "The native event consumer fell behind; reconnect and read current state"))
            }
        }, finish: { pair.continuation.finish() }))
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscription(id) } }
        return pair.stream
    }

    public func publish(_ channel: String, arguments: [NativeRPCValue], ownerID: String? = nil) async throws {
        try usable(channel)
        sequence &+= 1
        let event = NativeRPCEvent(sequence: sequence, channel: channel, arguments: arguments, ownerID: ownerID)
        let listeners = (eventHandlers[channel] ?? []) + (channel == "*" ? [] : eventHandlers["*"] ?? [])
        for listener in listeners where ownerID == nil || listener.ownerID == ownerID {
            guard eventHandlers.values.contains(where: { $0.contains(where: { $0.id == listener.id }) }) else { continue }
            do { try await listener.handler(event) } catch { report(NativeRPCError.wrapping(error)) }
        }
    }

    public func removeOwner(_ ownerID: String) {
        for listener in eventHandlers.values.flatMap({ $0 }) where listener.ownerID == ownerID { listener.finish() }
        handlers = handlers.filter { $0.value.ownerID != ownerID }
        sendHandlers = sendHandlers.mapValues { $0.filter { $0.ownerID != ownerID } }.filter { !$0.value.isEmpty }
        eventHandlers = eventHandlers.mapValues { $0.filter { $0.ownerID != ownerID } }.filter { !$0.value.isEmpty }
        for entry in pending.values where entry.ownerID == ownerID { entry.task.cancel() }
    }

    public func cancelRequest(_ id: UUID, ownerID: String) { if pending[id]?.ownerID == ownerID { pending[id]?.task.cancel() } }

    public func shutdown() {
        closed = true
        for listener in eventHandlers.values.flatMap({ $0 }) { listener.finish() }
        for request in pending.values { request.task.cancel() }
        handlers = [:]; sendHandlers = [:]; eventHandlers = [:]
    }

    private func removeSubscription(_ id: UUID) {
        for listener in eventHandlers.values.flatMap({ $0 }) where listener.id == id { listener.finish() }
        sendHandlers = sendHandlers.mapValues { $0.filter { $0.id != id } }.filter { !$0.value.isEmpty }
        eventHandlers = eventHandlers.mapValues { $0.filter { $0.id != id } }.filter { !$0.value.isEmpty }
    }
    private func usable(_ channel: String) throws {
        guard !closed else { throw NativeRPCError(code: "closed", message: "The native channel registry is closed") }
        guard Self.isBridgeChannel(channel) else { throw NativeRPCError.invalidArguments("Invalid bridge channel") }
    }
}
