import Foundation
import TerminalDeckNativeCore

/// The phone's Activity page and Overview glance (31 Oct): the remote `activity` capability.
///
/// `activity.watch {top}` starts a 2-second stream of `activity.sample` frames to that connection, `activity.unwatch`
/// (or the connection closing) ends it. Nothing is read while no phone is watching: the clock exists only while
/// someone has the page (or the Overview) on screen. `top: false` is the Overview's one-line glance, which skips the
/// process table. A read at every access level, Look only included: watching is not acting.
public actor BackendPhoneActivity {
    public static let messages: Set<String> = ["activity.watch", "activity.unwatch"]
    public static let capability = "activity"

    private let reader: BackendSystemActivity
    private let send: @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void
    private let beat: Duration
    private var watchers: [UUID: Bool] = [:]
    private var clock: Task<Void, Never>?

    public init(reader: BackendSystemActivity, beat: Duration = .seconds(2),
                send: @escaping @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void) {
        self.reader = reader; self.beat = beat; self.send = send
    }

    public init(endpoint: BackendRemoteHost, reader: BackendSystemActivity) {
        self.init(reader: reader, send: { connection, message in try await endpoint.sendToConnection(connection, message: message) })
    }

    public func feature() -> BackendRemoteHostFeature {
        .init(capability: Self.capability, messageTypes: Self.messages, policy: .grantedDevice) { [weak self] message, context in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "Activity on the phone stopped.") }
            return try await self.handle(message, context: context)
        }
    }

    public var watching: Int { watchers.count }

    func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        if message.type == "activity.unwatch" { disconnected(context.connectionID); return [] }
        watchers[context.connectionID] = message["top"].bool ?? true
        startClock()
        // The first frame at once, so the page is not empty for two seconds (its CPU fills in on the next beat).
        return [try Self.frame(await reader.sample(top: watchers[context.connectionID] ?? true))]
    }

    public func disconnected(_ connection: UUID) {
        watchers[connection] = nil
        if watchers.isEmpty { clock?.cancel(); clock = nil }
    }

    public func stop() { watchers.removeAll(); clock?.cancel(); clock = nil }

    private func startClock() {
        guard clock == nil else { return }
        let beat = self.beat
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: beat)
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    private func tick() async {
        guard !watchers.isEmpty else { return }
        // One reading per beat for everyone; the process table only when somebody has the full page open.
        let wantsTop = watchers.values.contains(true)
        let reading = await reader.sample(top: wantsTop)
        let lean = reading.removing("topCPU").removing("topMemory")
        for (connection, top) in watchers {
            guard let frame = try? Self.frame(top ? reading : lean) else { continue }
            do { try await send(connection, frame) } catch { disconnected(connection) }
        }
    }

    static func frame(_ reading: NativeRPCValue) throws -> BackendRemoteServerMessage {
        try .init(.activitySample, fields: reading.fields ?? [])
    }
}

private extension NativeRPCValue {
    func removing(_ key: String) -> NativeRPCValue {
        guard let fields else { return self }
        return .object(fields.filter { $0.key != key })
    }
}

/// `system.activity` (deck-tools): an agent checks the Mac's load before starting heavy work.
public enum BackendSystemActivityMCP {
    public static func definitions(reader: BackendSystemActivity, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        let title = "Read this Mac's load right now: CPU % (total and per core), memory used and pressure, swap, load average, disk free, network in/out, and what is using it most — grouped by Terminal Deck session (\"Deck Dev · build\"), app or process. busy is true when CPU is at or above 80 % or memory pressure is not normal: wait, or use fewer build jobs, before starting heavy work."
        let spec = try BackendMCPTool(id: "system.activity", wireName: "system_activity", description: title,
            inputSchema: NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)), tier: .read)
        return [.init(spec: spec, title: "Read this Mac's load", index: "This Mac's CPU, memory, disk, network and top users right now.", audience: "hoot") { context, args in
            try await access.authorize(context, "system.activity", args, .read, "Read this Mac's load", false)
            let reading = await reader.reading()
            try await access.record(context, "system.activity", args, .object([.init("busy", reading["busy"])]))
            return .value(reading)
        }]
    }
}
