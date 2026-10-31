import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendATWORKTarget: Equatable, Sendable {
    public let id: String
    public let pid: Int32?
    public let tokensToday: Double?
    public let watchPath: String?
    public let agent: NativeRPCValue?
    public let watchIdentity: String?
    public let running: Bool?
    public init(id: String, pid: Int32?, tokensToday: Double? = nil, watchPath: String? = nil, agent: NativeRPCValue? = nil, watchIdentity: String? = nil, running: Bool? = nil) {
        self.id = id; self.pid = pid; self.tokensToday = tokensToday; self.watchPath = watchPath; self.agent = agent; self.watchIdentity = watchIdentity; self.running = running
    }
}

public struct BackendATWORKSystem: Sendable {
    public let cpuBusy: UInt64, cpuTotal: UInt64
    public let freeMemoryBytes: UInt64?, memoryPressure: Double?
    public let processes: Int, cores: Int
    public init(cpuBusy: UInt64, cpuTotal: UInt64, freeMemoryBytes: UInt64?, memoryPressure: Double?, processes: Int, cores: Int) {
        self.cpuBusy = cpuBusy; self.cpuTotal = cpuTotal; self.freeMemoryBytes = freeMemoryBytes
        self.memoryPressure = memoryPressure; self.processes = processes; self.cores = cores
    }
}

/// The sole 2-second metrics clock, only while at least one At work view is visible.
/// Inventory is event-driven; ticks do not read tasks, transcripts or usage files.
public actor BackendATWORKMonitor {
    public typealias ReadTargets = @Sendable () async throws -> [BackendATWORKTarget]
    private let readTargets: ReadTargets
    private let readProcesses: @Sendable ([Int32]) -> [BackendATWORKProcess]
    private let readLaunchers: @Sendable () -> [Int32]
    private let readSystem: @Sendable () -> BackendATWORKSystem
    private let publish: @Sendable (NativeRPCValue) async -> Void
    private let now: @Sendable () -> Double
    private let uptime: @Sendable () -> Double
    private let calendar: Calendar
    private let watchProcessEvents: Bool
    private let readHeavyJob: @Sendable () async -> NativeRPCValue
    private var targets: [BackendATWORKTarget] = []
    private var visible = Set<String>()
    private var timer: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?
    private var processWatches: [Int32: DispatchSourceProcess] = [:]
    private var processWatchIDs: [Int32: UUID] = [:]
    private var eventRefresh: Task<Void, Never>?
    private var fileWatch: BackendUsageFileWatch?
    private var watchedPaths = Set<String>()
    private var pressureValue: Double?
    private var sampler = BackendATWORKProcessSampler()
    private var readSampler = BackendATWORKProcessSampler()
    private var previousSystem: BackendATWORKSystem?
    private var previousTokens: (value: Double, at: Double)?
    private var tokenMembers = Set<String>()
    private var latest = NativeRPCValue.object([])
    private var sampling = false, refreshing = false, dirty = false
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var inventoryError: String?
    private var discoveryNotice: String?
    private var watchedDay: Date?

    public init(readTargets: @escaping ReadTargets,
                readProcesses: @escaping @Sendable ([Int32]) -> [BackendATWORKProcess] = { BackendATWORKKernel.processes(roots: $0) },
                readSystem: @escaping @Sendable () -> BackendATWORKSystem = { BackendATWORKKernel.system() },
                readLaunchers: @escaping @Sendable () -> [Int32] = { BackendATWORKKernel.launcherPIDs() },
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                calendar: Calendar = .current,
                watchProcessEvents: Bool = true,
                readHeavyJob: @escaping @Sendable () async -> NativeRPCValue = { .null },
                publish: @escaping @Sendable (NativeRPCValue) async -> Void) {
        self.readTargets = readTargets; self.readProcesses = readProcesses; self.readSystem = readSystem; self.readLaunchers = readLaunchers
        self.now = now; self.uptime = uptime; self.calendar = calendar
        self.watchProcessEvents = watchProcessEvents; self.readHeavyJob = readHeavyJob; self.publish = publish
    }
    public func watcherCount() -> Int { visible.count }
    public func snapshot() -> NativeRPCValue { latest }
    public func inactiveIDs() -> Set<String> { Set(targets.filter { Self.isRunning($0) == false }.map(\.id)) }
    public func refreshForRead() async throws {
        guard visible.isEmpty else { return }
        targets = try await readTargets()
    }
    /// Free read tools can get fresh footprints without opening a watch. CPU
    /// becomes available on a later read; this method creates no timer or push.
    public func readMetrics(_ rows: [BackendATWORKTarget]) -> [String: NativeRPCValue] {
        if !visible.isEmpty {
            return Dictionary((latest["metrics"].elements ?? []).compactMap { row in
                row["id"].string.map { ($0, row) }
            }, uniquingKeysWith: { first, _ in first })
        }
        let supplied = Dictionary(targets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = rows.map { supplied[$0.id] ?? $0 }
        let at = now(), roots = Array(Set(rows.filter { Self.isRunning($0) != false }.compactMap(\.pid).filter { $0 > 1 }))
        let processes = readProcesses(roots)
        let values = readSampler.sample(roots: roots, processes: processes, at: uptime())
        return Dictionary(Self.metricRows(rows, values: values, at: at).compactMap { row in
            row["id"].string.map { ($0, row) }
        }, uniquingKeysWith: { first, _ in first })
    }
    public func setVisible(_ watcher: String, visible value: Bool) async {
        guard !watcher.isEmpty, watcher.count <= 200 else { return }
        if value {
            let wasEmpty = visible.isEmpty
            visible.insert(watcher)
            guard wasEmpty else { return }
            generation &+= 1
            watchedDay = calendar.startOfDay(for: Date(timeIntervalSince1970: now()))
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 2, repeating: .seconds(2), leeway: .milliseconds(300))
            timer.setEventHandler { [weak self] in Task { await self?.sampleNow() } }
            timer.resume(); self.timer = timer
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
            pressure.setEventHandler { [weak self, weak pressure] in
                guard let event = pressure?.data else { return }
                let value = event.contains(.critical) ? 100.0 : event.contains(.warning) ? 50 : 0
                Task { await self?.memoryPressureChanged(value) }
            }
            pressure.resume(); self.pressure = pressure
            await invalidate()
        } else {
            visible.remove(watcher)
            if visible.isEmpty { endWatching() }
        }
    }
    public func stop() { visible.removeAll(); endWatching() }
    private func endWatching() {
        generation &+= 1
        timer?.cancel(); timer = nil; pressure?.cancel(); pressure = nil; pressureValue = nil
        processWatches.values.forEach { $0.cancel() }; processWatches.removeAll(); processWatchIDs.removeAll()
        fileWatch?.stop(); fileWatch = nil; watchedPaths.removeAll()
        eventRefresh?.cancel(); eventRefresh = nil
        targets.removeAll(); sampler.reset(); previousSystem = nil; previousTokens = nil; tokenMembers.removeAll(); dirty = false; inventoryError = nil; discoveryNotice = nil; watchedDay = nil
        latest = .object([.init("metrics", .array([]))])
    }
    private func memoryPressureChanged(_ value: Double) { if !visible.isEmpty { pressureValue = value } }

    /// Call on session create/exit/status, task changes and other-app launch/file events.
    public func invalidate() async {
        guard !visible.isEmpty else { return }
        if refreshing { dirty = true; return }
        refreshing = true
        let version = generation
        repeat {
            dirty = false
            do {
                let rows = try await readTargets()
                guard generation == version, !visible.isEmpty else {
                    refreshing = false
                    if !visible.isEmpty { await invalidate() }
                    return
                }
                targets = rows; inventoryError = nil
                updateProcessWatches()
            } catch {
                guard generation == version, !visible.isEmpty else {
                    refreshing = false
                    if !visible.isEmpty { await invalidate() }
                    return
                }
                // Revoked/failed reads cannot leave the old private inventory running.
                targets.removeAll()
                updateProcessWatches()
                inventoryError = error.localizedDescription
                sequence &+= 1
                latest = .object([.init("metrics", .array([])), .init("error", .string(error.localizedDescription)), .init("sequence", .number(Double(sequence)))])
                await publish(latest)
            }
        } while dirty && generation == version && !visible.isEmpty
        refreshing = false
        await sampleNow()
    }
    private func updateProcessWatches() {
        guard watchProcessEvents else { return }
        if fileWatch == nil { fileWatch = BackendUsageFileWatch { [weak self] in Task { await self?.processChanged() } } }
        let paths = Set(targets.compactMap(\.watchPath))
        let identities = Set(targets.compactMap { target in target.watchPath.map { $0 + "\n" + (target.watchIdentity ?? "") } })
        if identities != watchedPaths { _ = try? fileWatch?.install(paths: Array(paths).sorted()); watchedPaths = identities }
        let roots = Set(targets.filter { Self.isRunning($0) != false }.compactMap(\.pid).filter { $0 > 1 })
        let launchers = Set(readLaunchers().filter { $0 > 1 }).subtracting(roots)
        var wanted = Set(roots.sorted().prefix(256))
        wanted.formUnion(launchers.sorted().prefix(max(0, 256 - wanted.count)))
        discoveryNotice = roots.count + launchers.count > 256 ? "Watching 256 agent processes and launchers. Additional launchers will be discovered on app or conversation changes." : nil
        for pid in Set(processWatches.keys).subtracting(wanted) {
            processWatchIDs[pid] = nil
            processWatches.removeValue(forKey: pid)?.cancel()
        }
        for pid in wanted.subtracting(processWatches.keys) {
            let identifier = UUID(), version = generation
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: [.exit, .exec, .fork], queue: .global(qos: .utility))
            source.setEventHandler { [weak self, weak source] in
                let exited = source?.data.contains(.exit) == true
                Task { await self?.processEvent(pid: pid, identifier: identifier, version: version, exited: exited) }
            }
            processWatchIDs[pid] = identifier
            source.resume(); processWatches[pid] = source
        }
    }
    private func processEvent(pid: Int32, identifier: UUID, version: UInt64, exited: Bool) {
        guard generation == version, !visible.isEmpty, processWatchIDs[pid] == identifier else { return }
        if exited {
            // A PID reused before discovery finishes gets a new kernel watch.
            // An old queued callback cannot cancel that replacement watch.
            processWatchIDs[pid] = nil
            processWatches.removeValue(forKey: pid)?.cancel()
        }
        processChanged()
    }
    private func processChanged() {
        guard !visible.isEmpty, eventRefresh == nil else { return }
        eventRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.finishProcessChange()
        }
    }
    private func finishProcessChange() async { eventRefresh = nil; await invalidate() }
    public func sampleNow() async {
        guard !visible.isEmpty, !sampling, !refreshing else { return }
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: now()))
        if let previousDay = watchedDay, previousDay != day {
            // One inventory refresh when midnight passes, even if the agents
            // are idle. Reuse the visible metrics clock; no second scheduler.
            watchedDay = day; previousTokens = nil; tokenMembers.removeAll()
            await invalidate()
            return
        }
        watchedDay = day
        sampling = true
        defer { sampling = false }
        let version = generation, at = now(), uptimeAt = uptime()
        let roots = Array(Set(targets.filter { Self.isRunning($0) != false }.compactMap(\.pid).filter { $0 > 1 }))
        let processes = readProcesses(roots)
        let values = sampler.sample(roots: roots, processes: processes, at: uptimeAt)
        let system = readSystem()
        let rows = Self.metricRows(targets, values: values, at: at)
        // Only topmost roots contribute to the footer. Nested agents and shared
        // desktop-app engines are not counted twice.
        let parent = Dictionary(processes.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        let rootSet = Set(roots)
        let topRoots = roots.filter { root in
            var current = parent[root] ?? 0, seen = Set<Int32>()
            while current > 1, seen.insert(current).inserted {
                if rootSet.contains(current) { return false }; current = parent[current] ?? 0
            }
            return true
        }
        let aggregate = topRoots.compactMap { values[$0] }
        let unknownRoots = inventoryError != nil || targets.contains { Self.isRunning($0) != false && ($0.pid == nil || ($0.pid ?? 0) <= 1) }
        let cpu = !unknownRoots && aggregate.allSatisfy { $0.cpuPercent != nil } ? aggregate.reduce(0.0) { $0 + ($1.cpuPercent ?? 0) } / Double(max(1, system.cores)) : nil
        var totalCPU: Double?
        if let old = previousSystem, system.cpuTotal > old.cpuTotal, system.cpuBusy >= old.cpuBusy {
            totalCPU = Double(system.cpuBusy - old.cpuBusy) / Double(system.cpuTotal - old.cpuTotal) * 100
        }
        previousSystem = system
        let tokens = targets.compactMap(\.tokensToday)
        let members = Set(targets.filter { $0.tokensToday != nil }.map(\.id))
        if members != tokenMembers { previousTokens = nil; tokenMembers = members }
        let totalTokens = tokens.isEmpty ? nil : tokens.reduce(0, +)
        var tokenRate: Double?
        if let totalTokens {
            if let old = previousTokens, totalTokens >= old.value, uptimeAt > old.at { tokenRate = (totalTokens - old.value) * 60 / (uptimeAt - old.at) }
            previousTokens = (totalTokens, uptimeAt)
        } else { previousTokens = nil }
        let memory = !unknownRoots && aggregate.allSatisfy { $0.memoryBytes != nil } ? aggregate.reduce(UInt64(0)) { $0 &+ ($1.memoryBytes ?? 0) } : nil
        let load = NativeRPCValue.object([.init("at", .number(at * 1000)),
            .init("agentCPU", cpu.map { .number(min(100, max(0, $0))) } ?? .null),
            .init("otherCPU", cpu.flatMap { agent in totalCPU.map { .number(max(0, $0 - agent)) } } ?? .null),
            .init("memoryPressure", (pressureValue ?? system.memoryPressure).map(NativeRPCValue.number) ?? .null),
            .init("agentMemoryBytes", memory.map { .number(Double($0)) } ?? .null),
            .init("freeMemoryBytes", system.freeMemoryBytes.map { .number(Double($0)) } ?? .null),
            .init("processes", unknownRoots ? .null : .number(Double(aggregate.reduce(0) { $0 + $1.processes }))),
            .init("systemProcesses", .number(Double(system.processes))),
            .init("tokensPerMinute", tokenRate.map(NativeRPCValue.number) ?? .null)])
        let heavyJob = await readHeavyJob()
        guard generation == version, !visible.isEmpty else { return }
        let byID = Dictionary(rows.compactMap { row in row["id"].string.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        let agents = targets.compactMap { target -> NativeRPCValue? in
            guard var value = target.agent else { return nil }
            if let metrics = byID[target.id] {
                for field in metrics.fields ?? [] {
                    if field.key == "since", field.value.number == nil { continue }
                    value = value.setting(field.key, field.value)
                }
            }
            return value
        }
        sequence &+= 1
        latest = .object([.init("metrics", .array(rows)), .init("load", load), .init("error", inventoryError.map(NativeRPCValue.string) ?? .null),
            .init("sequence", .number(Double(sequence)))])
        if !agents.isEmpty || targets.isEmpty { latest = latest.setting("agents", .array(agents)) }
        latest = latest.setting("heavyJob", heavyJob)
        latest = latest.setting("discoveryNotice", discoveryNotice.map(NativeRPCValue.string) ?? .null)
        await publish(latest)
    }

    private static func metricRows(_ targets: [BackendATWORKTarget], values: [Int32: BackendATWORKMetric], at: Double) -> [NativeRPCValue] {
        let multiplicity = Dictionary(grouping: targets.filter { Self.isRunning($0) != false }.compactMap(\.pid), by: { $0 })
        return targets.map { target -> NativeRPCValue in
            let running = Self.isRunning(target)
            let shared = target.pid.map { (multiplicity[$0]?.count ?? 0) > 1 } ?? false
            var value = target.pid.flatMap { values[$0] }?.wireValue ?? .object([
                .init("pid", .null), .init("cpuPercent", .null), .init("memoryBytes", .null), .init("threads", .null), .init("processCount", .number(0))])
            if running == false {
                value = value.setting("cpuPercent", .number(0)).setting("memoryBytes", .number(0)).setting("threads", .number(0)).setting("processCount", .number(0))
            } else if shared { value = value.setting("cpuPercent", .null).setting("memoryBytes", .null).setting("threads", .null) }
            let note: String?
            if running == false { note = nil }
            else if shared { note = "This app shares one process between these agents, so separate CPU and memory readings aren't available." }
            else if target.pid != nil, value["memoryBytes"].isNullish {
                note = value["processCount"].number == 0 ? "This process is unavailable." : "This Mac didn't allow reading this agent's processes."
            } else { note = nil }
            return value.setting("id", .string(target.id)).setting("tokensToday", target.tokensToday.map(NativeRPCValue.number) ?? .null)
                .setting("metricsSampledAt", .number(at * 1000))
                .setting("sharedProcess", .bool(shared))
                .setting("resourceNote", note.map(NativeRPCValue.string) ?? .null)
                .setting("isRunning", running.map(NativeRPCValue.bool) ?? .null)
        }
    }
    private static func isRunning(_ target: BackendATWORKTarget) -> Bool? {
        if let known = target.running { return known }
        if let pid = target.pid, pid > 1 { return true }
        let state = target.agent?["state"].string
        if ["queued", "finished", "offline"].contains(state ?? "") { return false }
        return nil
    }
}

public extension BackendATWORKKernel {
    static func system() -> BackendATWORKSystem {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cpu = host_cpu_load_info(), cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let cpuOK = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount) }
        } == KERN_SUCCESS
        let ticks = withUnsafeBytes(of: &cpu.cpu_ticks) { Array($0.bindMemory(to: UInt32.self)) }
        let total = cpuOK ? ticks.reduce(UInt64(0)) { $0 + UInt64($1) } : 0
        let busy = cpuOK && ticks.count > Int(CPU_STATE_IDLE) ? total - UInt64(ticks[Int(CPU_STATE_IDLE)]) : 0
        var vm = vm_statistics64(), vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let vmOK = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(host, HOST_VM_INFO64, $0, &vmCount) }
        } == KERN_SUCCESS
        var page: vm_size_t = 0
        host_page_size(host, &page)
        var level: Int32 = 0, levelSize = MemoryLayout<Int32>.size
        let pressureOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0], processBytes = 0
        let processOK = sysctl(&mib, 4, nil, &processBytes, nil, 0) == 0
        return .init(cpuBusy: busy, cpuTotal: total, freeMemoryBytes: vmOK ? UInt64(vm.free_count) * UInt64(page) : nil,
            memoryPressure: pressureOK ? (level >= 4 ? 100 : level >= 2 ? 50 : 0) : nil,
            processes: processOK ? processBytes / MemoryLayout<kinfo_proc>.stride : 0, cores: ProcessInfo.processInfo.activeProcessorCount)
    }
}
