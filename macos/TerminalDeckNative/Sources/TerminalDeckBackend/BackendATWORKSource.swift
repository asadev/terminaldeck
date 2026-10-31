import Foundation
import Darwin
import TerminalDeckNativeCore

/// Other-app discovery is cached between application/file/session events.
/// Completed hand-started sessions remain resumable in this app run (bounded).
public actor BackendATWORKInventory {
    private let scanner: BackendAGTDeviceScanner
    private var devices: [String: AGTDeviceAgent] = [:]
    public init(scanner: BackendAGTDeviceScanner = BackendAGTDeviceScanner()) { self.scanner = scanner }
    public func refresh() async {
        let scan = await scanner.scan()
        let running = scan.agents.filter { !$0.app.isTerminalDeck }
        let ids = Set(running.map(\.id))
        for (id, var old) in devices where !ids.contains(id) {
            if Self.hasEnded(old) { old.state = .finished; old.cpuPercent = nil; devices[id] = old }
        }
        for device in running { devices[device.id] = device }
        if devices.count > 300 {
            devices = Dictionary(devices.values.sorted { $0.startedAt > $1.startedAt }.prefix(300).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    public func device(_ id: String) -> AGTDeviceAgent? { devices[id.hasPrefix("device:") ? String(id.dropFirst(7)) : id] }
    public func wireValue() -> NativeRPCValue { .object([.init("agents", .array(devices.values.sorted { $0.startedAt > $1.startedAt }.map { $0.wireValue(includeText: true) }))]) }
    public func rows() -> [AWWatchAgent] {
        devices.values.sorted { $0.startedAt > $1.startedAt }.compactMap { device in
            AWWatchAgent.decode(.object([.init("id", .string("device:" + device.id)), .init("sourceID", .string(device.id)),
                .init("kind", .string("device")), .init("name", .string(device.displayName)), .init("provider", .string(device.ai)),
                .init("project", .string(device.project)), .init("machineName", .string(device.app.name)),
                .init("sessionID", device.sessionID.map(NativeRPCValue.string) ?? .null), .init("state", .string(device.state.rawValue)),
                .init("action", .string(device.state == .finished ? "Stopped" : device.lastLine ?? device.state.label)),
                .init("since", .number(device.startedAt * 1000)), .init("updatedAt", device.lastAt.map(NativeRPCValue.number) ?? .null),
                .init("pid", device.state == .finished ? .null : .number(Double(device.pid))),
                .init("sourceApp", .string(device.app.name))]))
        }
    }
    public func conversation(_ id: String) async throws -> AWWatchConversation {
        if let read = try? await scanner.conversation(id) { return .init(entries: read.entries, updatedAt: read.updatedAt, watchPath: read.path) }
        guard let device = devices[id], let path = device.transcriptPath,
              let safe = BackendAGTDeviceScanner.readable(path, home: NSHomeDirectory()) else {
            throw NativeRPCError(code: "unavailable", message: "That conversation file is no longer available.")
        }
        let roots = [NSHomeDirectory() + "/.claude/projects", NSHomeDirectory() + "/.codex/sessions"]
        let read = try BackendUsageIO.tail(path: safe, roots: roots, bytes: 2 * 1024 * 1024)
        var tools: [String: String] = [:], entries: [AWWatchEntry] = [], seen = Set<String>()
        for line in read.0.split(separator: "\n") {
            let projected = device.ai == "codex" ? BackendAGTCodexTranscript.project(line) : AWAgentsWatchTranscript.project(String(line), tools: &tools)
            entries += projected.filter { seen.insert($0.id).inserted }
        }
        return .init(entries: Array(entries.suffix(1000)), updatedAt: read.1, watchPath: safe)
    }
    /// Only an actual missing/replaced PID proves a session stopped. Permission
    /// denial does not turn an inaccessible process into a resumable one.
    public nonisolated static func hasEnded(_ device: AGTDeviceAgent) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let count = proc_pidinfo(device.pid, PROC_PIDTBSDINFO, 0, &info, size)
        if count == 0 { return errno == ESRCH || errno == ENOENT }
        guard count == size else { return false }
        let born = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return abs(born - device.startedAt) > 0.00001 || info.pbi_status == UInt32(SZOMB)
    }
}

/// Adds only metrics for already-authorized rows. Authorization is checked
/// again after suspended reads, and other-app data remains owner-only.
public struct BackendATWORKSource: AWAgentsWatchSource {
    public let base: any AWAgentsWatchSource
    public let monitor: BackendATWORKMonitor
    public let inventory: BackendATWORKInventory
    private let authority: BackendCompositionAuthority
    private let manager: BackendPTYManager
    public init(base: any AWAgentsWatchSource, monitor: BackendATWORKMonitor, inventory: BackendATWORKInventory,
                authority: BackendCompositionAuthority, manager: BackendPTYManager) {
        self.base = base; self.monitor = monitor; self.inventory = inventory; self.authority = authority; self.manager = manager
    }
    public func authorize(_ caller: AWWatchCaller, tool: String, arguments: NativeRPCValue) async throws {
        try await base.authorize(caller, tool: tool, arguments: arguments)
    }
    private func canReadDevices(_ caller: AWWatchCaller) async throws -> Bool {
        switch caller {
        case .app(let context): try authority.requireLocalUI(context); return true
        case .mcp(let context): return try await authority.resolve(context).caller.actsAsOwner
        }
    }
    public func snapshot(_ caller: AWWatchCaller) async throws -> AWWatchSnapshot {
        let read = try await base.snapshot(caller)
        let devices: [AWWatchAgent]
        if try await canReadDevices(caller) { devices = await inventory.rows() } else { devices = [] }
        let agents = read.agents + devices
        let targets = agents.map { agent -> BackendATWORKTarget in
            let pid = agent.machineID.isEmpty ? agent.pid ?? agent.sessionID.flatMap { manager.pidOf($0) } : nil
            return .init(id: agent.id, pid: pid, tokensToday: agent.tokensToday)
        }
        let metrics = await monitor.readMetrics(targets)
        let observation = await monitor.snapshot()
        let decorated = agents.compactMap { agent -> AWWatchAgent? in
            var wire = agent.wireValue
            if let value = metrics[agent.id] {
                for key in ["pid", "cpuPercent", "memoryBytes", "threads", "processCount", "tokensToday", "metricsSampledAt", "since", "sharedProcess", "resourceNote", "isRunning"] {
                    if key == "since", value[key].number == nil { continue }
                    wire = wire.setting(key, value[key])
                }
            }
            return AWWatchAgent.decode(wire)
        }
        // base.snapshot already checks row scope; rerun it after kernel/cache
        // suspensions so a grant revoked during the sample cannot return rows.
        let current = try await base.snapshot(caller)
        let allowed = Set(current.agents.map(\.id))
        let allowDevices = try await canReadDevices(caller)
        let discovery = allowDevices ? observation["discoveryNotice"].string.map { [$0] } ?? [] : []
        return .init(agents: decorated.filter { allowed.contains($0.id) || (allowDevices && $0.kind == "device") }, tasks: current.tasks, notices: current.notices + discovery)
    }
    public func conversation(_ agent: AWWatchAgent, caller: AWWatchCaller) async throws -> AWWatchConversation {
        guard agent.kind == "device" else { return try await base.conversation(agent, caller: caller) }
        guard try await canReadDevices(caller) else { throw NativeRPCError(code: "access-denied", message: "Other apps' conversations belong to the owner.") }
        let read = try await inventory.conversation(agent.sourceID)
        guard try await canReadDevices(caller) else { throw NativeRPCError(code: "access-denied", message: "Other-app access was removed.") }
        if case .mcp = caller { return .init(entries: read.entries, notice: read.notice, updatedAt: read.updatedAt) }
        return read
    }
}
