import Foundation
import TerminalDeckNativeCore

public struct BackendRemoteServeWindowAnswer: Sendable, Equatable {
    public let ok: Bool, body: String
    public init(ok: Bool, body: String) { self.ok = ok; self.body = body }
    public static func refusal(_ message: String) -> Self { .init(ok: false, body: NativeRPCValue.object([.init("message", .string(message))]).compact) }
}
public protocol BackendRemoteServeWindowWire: Sendable {
    /// Send on every live channel for this peer that advertised `windows`.
    /// The same frame also serves an outbound machine link as a client frame.
    func ask(deviceID: String, message: BackendRemoteServerMessage) async throws -> Int
    func reaches(deviceID: String) async -> Bool
}
public struct BackendRemoteServeWindowWireAdapter: BackendRemoteServeWindowWire {
    private let send: @Sendable (String, BackendRemoteServerMessage) async throws -> Int
    private let probe: @Sendable (String) async -> Bool
    public init(ask: @escaping @Sendable (String, BackendRemoteServerMessage) async throws -> Int,
                reaches: @escaping @Sendable (String) async -> Bool) { send = ask; probe = reaches }
    public func ask(deviceID: String, message: BackendRemoteServerMessage) async throws -> Int { try await send(deviceID, message) }
    public func reaches(deviceID: String) async -> Bool { await probe(deviceID) }
}

/// Source window-asks.ts. Construct separate desks for host-device ids and
/// outbound-machine ids; the opaque ids must never share a routing table.
public actor BackendRemoteServeWindowAsks {
    public static let timeoutMilliseconds = 55_000
    public typealias Sleep = @Sendable (Int) async throws -> Void
    private let timeout: Int
    private let sleep: Sleep
    private let makeID: @Sendable () -> String
    private var wire: (any BackendRemoteServeWindowWire)?
    private var holders: [String: [String]] = [:]
    private var holderOrder: [String] = []
    private struct Pending {
        let deviceID: String, continuation: CheckedContinuation<BackendRemoteServeWindowAnswer, Never>
        let timer: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]
    public init(timeoutMilliseconds: Int = BackendRemoteServeWindowAsks.timeoutMilliseconds,
                makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
                sleep: @escaping Sleep = { try await Task.sleep(for: .milliseconds($0)) }) {
        timeout = max(0, timeoutMilliseconds); self.makeID = makeID; self.sleep = sleep
    }
    public var waiting: Int { pending.count }
    public func serve(_ wire: any BackendRemoteServeWindowWire) { self.wire = wire }
    public func held(deviceID: String, sessions: [String]) {
        guard !deviceID.isEmpty else { return }
        if holders[deviceID] == nil { holderOrder.append(deviceID) }
        holders[deviceID] = Array(sessions.prefix(BackendRemoteProtocol.limits["MAX_WINDOW_HOLDS"]!))
    }
    public func holdersOf(_ sessionID: String) -> [String] {
        guard !sessionID.isEmpty else { return [] }
        return holderOrder.filter { holders[$0]?.contains(sessionID) == true }
    }
    public func reaches(_ deviceID: String) async -> Bool {
        guard !deviceID.isEmpty, let wire else { return false }
        return await wire.reaches(deviceID: deviceID)
    }
    public func call(deviceID: String, sessionID: String, tool: String, arguments: String) async -> BackendRemoteServeWindowAnswer {
        let id = makeID()
        let frame: BackendRemoteServerMessage
        do { frame = try .init(.windowCall, fields: [.init("id", .string(id)), .init("session", .string(sessionID)), .init("tool", .string(tool)), .init("args", .string(arguments))]) }
        catch { return .refusal(error.localizedDescription) }
        guard pending[id] == nil else { return .refusal("A browser window question with that id is already waiting.") }
        return await withCheckedContinuation { continuation in
            let timer = Task { [weak self, timeout, sleep] in
                do { try await sleep(timeout) } catch { return }
                await self?.expired(id)
            }
            pending[id] = Pending(deviceID: deviceID, continuation: continuation, timer: timer)
            let current = wire
            Task { [weak self] in
                await self?.dispatch(id, deviceID: deviceID, frame: frame, wire: current)
            }
        }
    }
    @discardableResult public func answer(id: String, result: BackendRemoteServeWindowAnswer) -> Bool { finish(id, result) }
    /// Optional extra identity check for an assembled authenticated host.
    @discardableResult public func answer(id: String, deviceID: String, result: BackendRemoteServeWindowAnswer) -> Bool {
        guard pending[id]?.deviceID == deviceID else { return false }; return finish(id, result)
    }
    public func gone(_ deviceID: String) {
        for id in pending.keys.filter({ pending[$0]?.deviceID == deviceID }) {
            finish(id, .refusal("the computer holding that browser window disconnected before it answered. Say what you would have done on the page and let the person do it."))
        }
        // Holds survive disconnect: the laptop still holds its attached window.
    }
    public func stop() { for id in Array(pending.keys) { finish(id, .refusal("this app is shutting down.")) } }
    public nonisolated func feature() -> BackendRemoteHostFeature {
        .init(capability: "windows", messageTypes: ["window.result"], policy: .grantedDevice) { [weak self] frame, context in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The browser window question desk stopped") }
            _ = await self.answer(id: frame["id"].string!, deviceID: context.deviceID, result: .init(ok: frame["ok"].bool!, body: frame["body"].string!))
            return []
        }
    }
    /// Browser-serving owner calls this from its existing window.holds handler.
    public func receivedHolds(_ message: BackendRemoteClientMessage, deviceID: String) {
        guard message.type == "window.holds" else { return }
        held(deviceID: deviceID, sessions: message["sessions"].elements?.compactMap(\.string) ?? [])
    }
    private func dispatch(_ id: String, deviceID: String, frame: BackendRemoteServerMessage, wire: (any BackendRemoteServeWindowWire)?) async {
        guard pending[id] != nil else { return }
        let heard: Int
        if let wire { heard = (try? await wire.ask(deviceID: deviceID, message: frame)) ?? 0 }
        else { heard = 0 }
        if heard == 0 { unheard(id) }
    }
    private func expired(_ id: String) {
        finish(id, .refusal("the computer holding that browser window did not answer. It may be asleep or the app may be closed there. Say what you would have done on the page and let the person do it."))
    }
    private func unheard(_ id: String) {
        finish(id, .refusal("the computer holding that browser window is not connected right now. Say what you would have done on the page and let the person do it."))
    }
    @discardableResult private func finish(_ id: String, _ result: BackendRemoteServeWindowAnswer) -> Bool {
        guard let entry = pending.removeValue(forKey: id) else { return false }
        entry.timer.cancel(); entry.continuation.resume(returning: result); return true
    }
}
