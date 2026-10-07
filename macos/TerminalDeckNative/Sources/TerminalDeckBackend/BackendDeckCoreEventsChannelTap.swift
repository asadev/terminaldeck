import Foundation
import TerminalDeckNativeCore

/// One native tap. Register a domain handler through this adapter once; both
/// native UI channels and tool calls then execute that same handler.
public actor BackendDeckCoreEventsChannelTap {
    public typealias Handler = @Sendable (NativeRPCContext?, [NativeRPCValue]) async throws -> NativeRPCValue
    public typealias PushListener = @Sendable (NativeRPCValue) throws -> Void
    public typealias InvokeListener = @Sendable (String, [NativeRPCValue]) throws -> Void
    private var handlers: [String: Handler] = [:]
    private var attached: Set<ObjectIdentifier> = []
    private var pushListeners: [String: [(UUID, PushListener)]] = [:]
    private var invokeListeners: [(UUID, InvokeListener)] = []
    private let clock: any BackendDeckCoreEventsClock
    private let report: @Sendable (String) -> Void
    public init(clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock(), report: @escaping @Sendable (String) -> Void = { _ in }) { self.clock = clock; self.report = report }
    public func attach(_ registry: NativeChannelRegistry) throws {
        let id = ObjectIdentifier(registry)
        guard attached.insert(id).inserted else { throw NativeRPCError(code:"wiring",message:"The channel tap is already attached to this ipcMain; a second layer would report every call twice.") }
    }
    public func register(_ channel: String, in registry: NativeChannelRegistry, ownerID: String,
                         policy: @escaping NativeChannelRegistry.Policy = { _ in }, handler: @escaping Handler) async throws {
        guard attached.contains(ObjectIdentifier(registry)) else { throw NativeRPCError(code:"wiring",message:"Attach the channel tap before registering handlers.") }
        try await registry.register(channel,ownerID:ownerID,policy:policy) { context, arguments in
            await self.tellInvoke(channel,arguments); return try await handler(context,arguments)
        }
        handlers[channel] = handler
    }
    /// Source ipcMain.on keeps its first listener as the tool-call handler.
    public func onSend(_ channel: String, in registry: NativeChannelRegistry, ownerID: String,
                       policy: @escaping NativeChannelRegistry.Policy = { _ in }, handler: @escaping Handler) async throws -> NativeRPCSubscription {
        guard attached.contains(ObjectIdentifier(registry)) else { throw NativeRPCError(code:"wiring",message:"Attach the channel tap before registering handlers.") }
        let token = try await registry.onSend(channel,ownerID:ownerID,policy:policy) { context, arguments in
            await self.tellInvoke(channel,arguments); _ = try await handler(context,arguments)
        }
        if handlers[channel] == nil { handlers[channel] = handler }; return token
    }
    public func has(_ channel: String) -> Bool { handlers[channel] != nil }
    public func invoke(_ channel: String, arguments: [NativeRPCValue] = []) async throws -> NativeRPCValue {
        guard let handler = handlers[channel] else { throw NativeRPCError(code:"missing-handler",message:"Nothing in this app answers \"\(channel)\". The registration that owns it has not run, or the tap was attached after it — a wiring fault, not an unsupported action.") }
        tellInvoke(channel,arguments); return try await handler(nil,arguments)
    }
    private func tellInvoke(_ channel: String, _ args: [NativeRPCValue]) {
        for (_,listener) in invokeListeners { do { try listener(channel,args) } catch { report("[channel-tap] an invocation listener threw on \(channel): \(error.localizedDescription)") } }
    }
    public func pushed(_ channel: String, arguments: [NativeRPCValue]) {
        for (_,listener) in pushListeners[channel] ?? [] { do { try listener(arguments.first ?? .missing) } catch { report("[channel-tap] a push listener threw on \(channel): \(error.localizedDescription)") } }
    }
    public func onPush(_ channel: String, listener: @escaping PushListener) -> UUID { let id = UUID(); pushListeners[channel,default:[]].append((id,listener)); return id }
    public func onInvoke(_ listener: @escaping InvokeListener) -> UUID { let id = UUID(); invokeListeners.append((id,listener)); return id }
    public func removeListener(_ id: UUID) {
        invokeListeners.removeAll { $0.0 == id }
        for channel in Array(pushListeners.keys) { pushListeners[channel]?.removeAll { $0.0 == id }; if pushListeners[channel]?.isEmpty == true { pushListeners[channel] = nil } }
    }
    /// Listener and deadline are installed before after(), including same-tick pushes.
    public func nextPush(_ channel: String, matches: @escaping @Sendable (NativeRPCValue) -> Bool,
                         ceilingMs: Double, after: @escaping @Sendable () async throws -> Void = {}) async throws -> NativeRPCValue? {
        let pair = AsyncStream<NativeRPCValue?>.makeStream(bufferingPolicy:.bufferingNewest(1))
        let once = BackendDeckCoreEventsPushOnce()
        let id = onPush(channel) { payload in if matches(payload), once.claim() { pair.continuation.yield(payload); pair.continuation.finish() } }
        let timer = clock.schedule(after:ceilingMs) { if once.claim() { pair.continuation.yield(nil); pair.continuation.finish() } }
        defer { clock.cancel(timer); removeListener(id); pair.continuation.finish() }
        try await after()
        var iterator = pair.stream.makeAsyncIterator(); return await iterator.next() ?? nil
    }
    /// A closed call map for factories; those factories still own tier and consent.
    public nonisolated func call(allowing channels: Set<String>) -> @Sendable (String,[NativeRPCValue]) async throws -> NativeRPCValue {
        { channel,args in
            guard channels.contains(channel) else { throw NativeRPCError(code:"wiring",message:"The factory has no channel named \"\(channel)\" in its call map.") }
            return try await self.invoke(channel,arguments:args)
        }
    }
}

private final class BackendDeckCoreEventsPushOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool { lock.withLock { guard !taken else { return false }; taken = true; return true } }
}
