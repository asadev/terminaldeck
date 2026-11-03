import Foundation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// The native app's own line to its in-process backend, for screens drawn in Swift.
///
/// D14 Node-free app: every channel and event belongs to the in-process
/// registry; there is no engine process, no HTTP path and no second event stream.
@MainActor
final class EngineBridge {
    static let shared = EngineBridge()

    private(set) var base: URL?
    private var listeners: [String: [UUID: ([Any]) -> Void]] = [:]
    private var native: BackendCompositionRoot?
    private var nativeSubscription: NativeRPCSubscription?

    var isReady: Bool { base != nil || native != nil }

    /// Install the in-process registry. Handler failures are returned to the caller.
    func configure(native root: BackendCompositionRoot) async throws {
        await nativeSubscription?.cancelAndWait()
        native = root
        nativeSubscription = try await root.registry.subscribeAll(ownerID: BackendCompositionRoot.appOwnerID) { [weak self] event in
            await self?.dispatchNative(event)
        }
    }

    func disconnectNative() async {
        await nativeSubscription?.cancelAndWait(); nativeSubscription = nil
        native = nil
    }

    /// Called when the pages are ready: their origin is the native caller's origin.
    func configure(engineURL: URL) {
        guard let endpoint = EngineWire.endpoint(from: engineURL) else { return }
        base = endpoint.base
    }

    /// Called when the backend stops. Listeners stay registered for the next start.
    func reset() {
        base = nil
    }

    /// Typed native-only route for new Swift screens. No Any payload crosses
    /// the actor boundary and a missing native service never falls back to Node.
    func invokeNativeValue(_ channel: String, _ arguments: [NativeRPCValue]) async throws -> NativeRPCValue {
        guard let native else { throw NativeRPCError(code: "unavailable", message: "This native control is not available in the current app copy.") }
        return try await native.invoke(channel, context: nativeContext(), arguments: arguments)
    }

    /// Call a handler the engine registered with `ipcMain.handle`, and wait for its answer.
    /// `timeout` (seconds) replaces the 30 s a request may sit silent, for a call that is
    /// slow by nature — starting an MCP server can take 45 s (lane E2).
    func invoke(_ channel: String, _ args: [Any?] = [], timeout: TimeInterval? = nil) async throws -> Any {
        try await askingAgain(channel) { try await self.invokeOnce(channel, args, timeout: timeout) }
    }

    func pluginControl(_ id: String, input: NativeRPCValue) async throws -> NativeRPCValue {
        guard let native else { throw NativeRPCError(code: "unavailable", message: "Native plugin controls are unavailable") }
        return try await native.invoke("plugins:extension", context: nativeContext(), arguments: [.string(id), input])
    }

    private func invokeOnce(_ channel: String, _ args: [Any?], timeout: TimeInterval?) async throws -> Any {
        guard let native else { throw EngineWireError.notReady }
        let answer = try await native.invoke(channel, context: nativeContext(), arguments: try nativeArguments(args))
        return answer.foundation ?? NSNull()
    }

    /// RETRY (11 Oct): a READ that fails because a line dropped (the session host unavailable or
    /// not authenticated yet, a timed-out or refused connection) is asked again by itself after
    /// a short pause, twice, before any page hears of it. A change is never repeated here: its
    /// answer may have been lost after it happened. When the line stays down, every read would
    /// wait for nothing, so after three reads in a row have used up their tries the bridge stops
    /// asking again until one call succeeds or the app's lines are back (DeckReconnect).
    private var readsThatGaveUp = 0
    private var gaveUpGeneration = 0
    private func askingAgain<T>(_ channel: String, _ work: () async throws -> T) async throws -> T {
        var tries = 0
        while true {
            do {
                let value = try await work()
                readsThatGaveUp = 0
                return value
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                let generation = DeckReconnect.shared.generation
                if generation != gaveUpGeneration { gaveUpGeneration = generation; readsThatGaveUp = 0 }
                guard readsThatGaveUp < 3, DeckRetryRules.retriesByItself(channel: channel, failure: error.localizedDescription),
                      let pause = DeckRetryRules.pause(beforeAutomaticTry: tries) else {
                    if DeckRetryRules.retriesByItself(channel: channel, failure: error.localizedDescription) { readsThatGaveUp += 1 }
                    throw error
                }
                tries += 1
                try await Task.sleep(for: .seconds(pause))
            }
        }
    }

    /// The same call, with the answer read in the order it was written (`OrderedJSON`),
    /// for screens that lay out or print what came back — lane E2, the MCP page.
    func invokeOrdered(_ channel: String, _ args: [Any?] = [], timeout: TimeInterval? = nil) async throws -> OrderedJSON {
        try await askingAgain(channel) { try await self.invokeOrderedOnce(channel, args, timeout: timeout) }
    }

    private func invokeOrderedOnce(_ channel: String, _ args: [Any?], timeout: TimeInterval?) async throws -> OrderedJSON {
        guard let native else { throw EngineWireError.notReady }
        let answer = try await native.invoke(channel, context: nativeContext(), arguments: try nativeArguments(args))
        let envelope = NativeRPCValue.object([.init("ok", .bool(true)), .init("value", answer)])
        switch OrderedJSON.invokeResult(try envelope.encodedJSON()) {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    /// Fire-and-forget to an `ipcMain.on` listener (e.g. `session:write`), in order.
    func send(_ channel: String, _ args: [Any?] = []) {
        let previous = lastSend
        lastSend = Task { [weak self] in
            await previous?.value
            guard let self, let native = self.native else { return }
            do { try await native.send(channel, context: self.nativeContext(), arguments: try self.nativeArguments(args)) }
            catch {
                // Fire-and-forget still surfaces a failure to native error
                // listeners, with no fallback repeating a failed mutation.
                self.dispatch("native:send-error", [channel, error.localizedDescription])
            }
        }
    }
    private var lastSend: Task<Void, Never>?

    /// The same ordered send, answered (#408): it throws when the session refused it or is gone, so a
    /// caller never says "sent" for text nothing typed.
    func sendChecked(_ channel: String, _ args: [Any?] = []) async throws {
        let previous = lastSend
        let work = Task { [weak self] () throws -> Void in
            await previous?.value
            guard let self, let native = self.native else { throw EngineWireError.notReady }
            try await native.sendChecked(channel, context: self.nativeContext(), arguments: try self.nativeArguments(args))
        }
        lastSend = Task { _ = try? await work.value }
        try await work.value
    }

    /// Listen to one channel of the live event stream.
    @discardableResult
    func on(_ channel: String, _ handler: @escaping ([Any]) -> Void) -> EngineSubscription {
        let id = UUID()
        listeners[channel, default: [:]][id] = handler
        return EngineSubscription { [weak self] in
            Task { @MainActor in self?.listeners[channel]?[id] = nil }
        }
    }

    // MARK: - inside

    private func nativeContext() -> NativeRPCContext {
        .init(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID, origin: base)
    }
    private func nativeArguments(_ arguments: [Any?]) throws -> [NativeRPCValue] {
        try arguments.map { try NativeRPCValue.fromFoundation($0 ?? NSNull()) }
    }
    private func dispatchNative(_ event: NativeRPCEvent) {
        dispatch(event.channel, event.arguments.map { $0.foundation ?? NSNull() })
    }
    private func dispatch(_ channel: String, _ args: [Any]) {
        for handler in (listeners[channel] ?? [:]).values { handler(args) }
    }
}

/// Stops one listener. Keep it for as long as the screen wants events.
final class EngineSubscription {
    private var cancelAction: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { cancelAction = cancel }
    func cancel() { cancelAction?(); cancelAction = nil }
    deinit { cancelAction?() }
}
