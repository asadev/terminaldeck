import Foundation
import TerminalDeckNativeCore

/// Item 74 / review-install-24 S11 (post-24): the phones asked every 10 s for a working session's context window.
/// The Mac now sends the context reading itself when that session's transcript moves (its AI's own hook steps:
/// a turn, a tool, the end of a turn), at most once per 2 s per session, to every phone whose bar follows the
/// session (the phone that last asked `usage.read {want: context}` for it). Same `usage.reading` frame as the
/// answer, with `rid: "push:context"` and `push: true`; Gemini and plain shells still carry their reason.
/// Phones: a build that matches answers to its own requests drops it until it accepts `push:` rids (no harm).
public actor BackendRemoteServeUsagePush {
    public typealias Read = @Sendable (_ sessionID: String, _ caller: NativeRPCContext) async throws -> NativeRPCValue
    public typealias Send = @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void
    public static let rid = "push:context"
    public static let spacing: TimeInterval = 2
    private struct Follower { var sessionID: String; var caller: NativeRPCContext }
    private var followers: [UUID: Follower] = [:]
    private var lastPush: [String: Double] = [:]
    private var scheduled: Set<String> = []
    private var read: Read?
    private var send: Send?
    private let clock: @Sendable () -> Double
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.clock = clock; self.sleep = sleep
    }
    /// Bound once the remote endpoint exists (the reader is the usage service's own context reading).
    public func bind(read: @escaping Read, send: @escaping Send) { self.read = read; self.send = send }

    /// A phone asked for this session's context: its bar follows it (one session per connection).
    public func follow(connection: UUID, sessionID: String, caller: NativeRPCContext) {
        followers[connection] = Follower(sessionID: sessionID, caller: caller)
    }
    public func disconnected(_ connection: UUID) { followers[connection] = nil }
    public func followerCount(_ sessionID: String) -> Int { followers.values.filter { $0.sessionID == sessionID }.count }

    /// The session's transcript moved. Coalesced: at most one push per `spacing` per session.
    public func transcriptChanged(_ sessionID: String) async {
        guard followers.values.contains(where: { $0.sessionID == sessionID }), !scheduled.contains(sessionID) else { return }
        scheduled.insert(sessionID)
        let wait = max(0, (lastPush[sessionID] ?? -.infinity) + Self.spacing - clock())
        if wait > 0 { await sleep(wait) }
        scheduled.remove(sessionID)
        lastPush[sessionID] = clock()
        await push(sessionID)
    }

    private func push(_ sessionID: String) async {
        guard let read, let send else { return }
        var reading: NativeRPCValue?
        for (connection, follower) in followers where follower.sessionID == sessionID {
            if reading == nil { reading = try? await read(sessionID, follower.caller) }
            guard let reading else { return }
            do {
                try await send(connection, .init(.usageReading, fields: [.init("rid", .string(Self.rid)), .init("id", .string(sessionID)),
                    .init("want", .string("context")), .init("answer", .object([.init("reading", reading)])), .init("push", .bool(true))]))
            } catch { followers[connection] = nil }
        }
    }
}
