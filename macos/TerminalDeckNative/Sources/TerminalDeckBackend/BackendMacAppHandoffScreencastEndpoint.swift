import Foundation
import TerminalDeckNativeCore

/// Optional feature factory for the existing native remote host. No listener, trust store or capture engine.
public actor BackendMacAppHandoffScreencastEndpoint {
    public struct Hooks: Sendable {
        /// Re-read the actual connected device/window grants and connection liveness, per request and frame.
        public let granted: @Sendable (BackendRemoteHostContext) async -> Bool
        public let emit: @Sendable (BackendRemoteHostContext, BackendRemoteServerMessage) async throws -> Void
        public init(granted: @escaping @Sendable (BackendRemoteHostContext) async -> Bool,
                    emit: @escaping @Sendable (BackendRemoteHostContext, BackendRemoteServerMessage) async throws -> Void) { self.granted = granted; self.emit = emit }
    }
    private let router: BackendMacAppHandoffScreencast
    private let hooks: Hooks
    private var watching: [UUID: Set<String>] = [:]
    private var connections: [UUID: BackendRemoteHostContext] = [:]
    public init(router: BackendMacAppHandoffScreencast, hooks: Hooks) { self.router = router; self.hooks = hooks }
    public nonisolated func feature() -> BackendRemoteHostFeature {
        .init(capability: "watch", messageTypes: ["browser.watch", "browser.unwatch", "browser.frame.ack", "browser.input", "browser.surfaces", "browser.handover.take", "browser.handover.done"], policy: .windowGrant) { message, context in try await self.handle(message, context: context) }
    }
    private func state(_ context: BackendRemoteHostContext, window: String, requestID: NativeRPCValue = .missing) async throws -> BackendRemoteServerMessage {
        let value = try await router.handover(window)
        var fields: [NativeRPCValue.Field] = [.init("window", .string(window)), .init("asking", .bool(value.asking)), .init("prompt", .string(value.prompt)), .init("mine", .bool(value.taker == context.connectionID.uuidString)), .init("taken", .bool(value.taker != nil))]
        if requestID != .missing { fields.append(.init("rid", requestID)) }; return try .init(.browserHandoverState, fields: fields)
    }
    public func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        let id = context.connectionID, watcher = id.uuidString, window = message["window"].string ?? ""
        if message.type == "browser.unwatch" {
            watching[id]?.remove(window); try? await router.unwatch(watcherID: watcher, window: window); return []
        }
        if message.type == "browser.frame.ack" {
            if watching[id]?.contains(window) == true, let seq = message["seq"].number { try? await router.ack(watcherID: watcher, window: window, sequence: Int(seq)) }; return []
        }
        guard await hooks.granted(context) else { return [] }
        connections[id] = context
        switch message.type {
        case "browser.surfaces": return [try .init(.browserSurfaceRows, fields: [.init("rid", message["rid"]), .init("surfaces", .array(await router.surfaces()))])]
        case "browser.watch":
            if watching[id]?.contains(window) != true && (watching[id]?.count ?? 0) >= 8 { return [] }
            watching[id, default: []].insert(window)
            do {
                let answer = try await router.watch(watcherID: watcher, window: window, maxWidth: Int(message["maxWidth"].number ?? 800), quality: Int(message["quality"].number ?? 50), everyNth: message["everyNth"].number.map(Int.init)) { [self] frame in
                    guard await self.stillWatching(context, window) else {
                        await self.revokeWatch(context, window); throw NativeRPCError(code: "access-denied", message: "The browser window grant changed before this frame was sent.")
                    }
                    let fields = (frame.fields ?? []).filter { $0.key != "t" }
                    try await self.hooks.emit(context, BackendRemoteServerMessage(.browserFrame, fields: fields))
                }
                guard answer.ok else { watching[id]?.remove(window); return [] }
                guard await stillWatching(context, window) else { await revokeWatch(context, window); return [] }
                return [try await state(context, window: window)]
            } catch { watching[id]?.remove(window); return [] }
        case "browser.input":
            if watching[id]?.contains(window) == true { _ = try? await router.input(watcherID: watcher, window: window, frame: message.value) }; return []
        case "browser.handover.take", "browser.handover.done":
            guard watching[id]?.contains(window) == true else { return [] }
            if message.type == "browser.handover.take" { _ = try? await router.take(watcherID: watcher, window: window) }
            else { _ = try? await router.handBack(watcherID: watcher, window: window, carryOn: message["carryOn"].bool == true) }
            guard await stillWatching(context, window) else { return [] }; return [try await state(context, window: window, requestID: message["rid"])]
        default: throw NativeRPCError(code: "unavailable", message: "This is not a supplied native browser watch operation.")
        }
    }
    private func stillWatching(_ context: BackendRemoteHostContext, _ window: String) async -> Bool {
        let permitted = await hooks.granted(context)
        return permitted && connections[context.connectionID] != nil && watching[context.connectionID]?.contains(window) == true
    }
    private func revokeWatch(_ context: BackendRemoteHostContext, _ window: String) async {
        watching[context.connectionID]?.remove(window); try? await router.unwatch(watcherID: context.connectionID.uuidString, window: window)
    }
    /// Bind this callback to the existing host's actual connection close edge.
    public func closed(_ connectionID: UUID) async throws {
        connections[connectionID] = nil; watching[connectionID] = nil
        try await router.dropWatcher(connectionID.uuidString)
    }
    /// Bind to the shared browser baton change event, including a question starting before a viewer attaches.
    public func handoverChanged(window: String) async {
        for (id, context) in connections where watching[id]?.contains(window) == true {
            if await stillWatching(context, window), let frame = try? await state(context, window: window) { try? await hooks.emit(context, frame) }
        }
    }
}
