import Darwin
import Foundation
import TerminalDeckNativeCore

/// What this Mac is busy with, read cheaply (31 Oct, Asad: "see system activity ... cpu and memory usage live so we can
/// check from the phone if there is any load or not").
///
/// Kernel reads only — `host_processor_info`, `host_statistics64`, `sysctl`, `getloadavg`, `getifaddrs`, one
/// `KERN_PROC_ALL` table and `proc_pid_rusage` per process this user owns. No `top`/`ps` subprocess, no argv, no
/// environment, no files. Each `sample()` measures the change since the previous one, so the first answer has no CPU.
///
/// "What's using it" groups processes the way a person names them: a Terminal Deck session (and everything it
/// started) by its project and title ("Deck Dev · build"), an app by its bundle name (every helper of Chrome is
/// "Google Chrome"), anything else by its process name.
public actor BackendSystemActivity {
    /// A running session's top process and the name it is shown by.
    public struct SessionRoot: Sendable, Equatable {
        public var pid: Int32, label: String
        public init(pid: Int32, label: String) { self.pid = pid; self.label = label }
    }

    public struct Group: Sendable, Equatable {
        public var name: String, kind: String, cpu: Double, memory: UInt64, processes: Int
        var wire: NativeRPCValue {
            .object([.init("name", .string(name)), .init("kind", .string(kind)), .init("cpu", .number((cpu * 10).rounded() / 10)),
                     .init("memory", .number(Double(memory))), .init("processes", .number(Double(processes)))])
        }
    }

    /// Asad's limit: above this, the Mac is busy (31 Oct, "keep it under ninety or eighty percent").
    public static let busyPercent = 80.0
    public static let topCount = 6

    private let sessions: @Sendable () async -> [SessionRoot]
    private let home: String
    private var previousCores: [(busy: UInt64, total: UInt64)] = []
    private var previousCPU: [Int32: (birth: UInt64, cpu: UInt64)] = [:]
    private var previousNet: (inBytes: UInt64, outBytes: UInt64, at: Double)?
    private var previousAt: Double?
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    public init(home: String = NSHomeDirectory(), sessions: @escaping @Sendable () async -> [SessionRoot] = { [] }) {
        self.home = home; self.sessions = sessions
    }

    /// One reading. `top: false` skips the process table (the Overview's one-line glance).
    public func sample(top: Bool = true) async -> NativeRPCValue {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousAt.map { now - $0 } ?? 0
        previousAt = now

        // CPU, per core and total.
        let cores = Self.coreTicks()
        var corePercents: [Double] = []
        if cores.count == previousCores.count {
            for (index, core) in cores.enumerated() {
                let busy = core.busy &- previousCores[index].busy, total = core.total &- previousCores[index].total
                corePercents.append(total > 0 ? min(100, Double(busy) / Double(total) * 100) : 0)
            }
        }
        previousCores = cores
        let cpuTotal: NativeRPCValue = corePercents.isEmpty ? .null : .number(Self.round1(corePercents.reduce(0, +) / Double(corePercents.count)))

        // Memory, as Activity Monitor counts "used": app memory + wired + compressed.
        let memory = Self.memory()

        // Load.
        var load = [Double](repeating: 0, count: 3)
        let loadOK = getloadavg(&load, 3) == 3

        // Disk where the person's files are.
        let disk = (try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]))

        // Network, all interfaces but loopback.
        let net = Self.networkBytes()
        var netIn: NativeRPCValue = .null, netOut: NativeRPCValue = .null
        if let net, let before = previousNet, now > before.at {
            let seconds = now - before.at
            netIn = .number((Double(Self.delta32(net.inBytes, before.inBytes)) / seconds).rounded())
            netOut = .number((Double(Self.delta32(net.outBytes, before.outBytes)) / seconds).rounded())
        }
        if let net { previousNet = (net.inBytes, net.outBytes, now) }

        var fields: [NativeRPCValue.Field] = [
            .init("at", .number((Date().timeIntervalSince1970 * 1000).rounded())),
            .init("cpu", .object([.init("total", cpuTotal), .init("cores", .array(corePercents.map { .number(Self.round1($0)) })),
                                  .init("count", .number(Double(cores.count)))])),
            .init("memory", .object([.init("used", .number(Double(memory.used))), .init("total", .number(Double(memory.total))),
                                     .init("pressure", .string(memory.pressure)), .init("swapUsed", .number(Double(memory.swapUsed))),
                                     .init("swapTotal", .number(Double(memory.swapTotal)))])),
            .init("load", loadOK ? .array(load.map { .number(Self.round1($0 * 10) / 10) }) : .null),
            .init("disk", .object([.init("free", disk?.volumeAvailableCapacityForImportantUsage.map { .number(Double($0)) } ?? .null),
                                   .init("total", disk?.volumeTotalCapacity.map { .number(Double($0)) } ?? .null)])),
            .init("net", .object([.init("in", netIn), .init("out", netOut)])),
        ]
        let busyCPU = corePercents.isEmpty ? false : corePercents.reduce(0, +) / Double(corePercents.count) >= Self.busyPercent
        fields.append(.init("busy", .bool(busyCPU || memory.pressure != "normal")))
        if top {
            let groups = await self.groups(elapsed: elapsed, cores: max(cores.count, 1))
            fields.append(.init("topCPU", .array(groups.sorted { $0.cpu > $1.cpu }.prefix(Self.topCount).map(\.wire))))
            fields.append(.init("topMemory", .array(groups.sorted { $0.memory > $1.memory }.prefix(Self.topCount).map(\.wire))))
        }
        return .object(fields)
    }

    /// A reading that has a CPU figure: two samples `interval` apart (the MCP tool, which has no running stream).
    public func reading(interval: Duration = .milliseconds(800)) async -> NativeRPCValue {
        _ = await sample(top: true)
        try? await Task.sleep(for: interval)
        return await sample(top: true)
    }

    /* ---- processes --------------------------------------------------------------------------------------- */

    private func groups(elapsed: Double, cores: Int) async -> [Group] {
        let table = Self.processTable()
        let roots = Dictionary((await sessions()).map { ($0.pid, $0.label) }, uniquingKeysWith: { first, _ in first })
        let parent = Dictionary(table.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
        let uid = getuid()
        var groups: [String: Group] = [:], seen: [Int32: (UInt64, UInt64)] = [:]
        for entry in table where entry.uid == uid && entry.pid > 0 {
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(entry.pid, RUSAGE_INFO_V4, $0) }
            } == 0
            guard ok else { continue }
            let cpuNs = (usage.ri_user_time &+ usage.ri_system_time) &* timebase.numer / timebase.denom
            seen[entry.pid] = (entry.birth, cpuNs)
            var percent = 0.0
            if elapsed > 0, let old = previousCPU[entry.pid], old.birth == entry.birth, cpuNs >= old.cpu {
                // Share of the whole Mac (all cores), so the groups add up to the CPU figure above.
                percent = Double(cpuNs - old.cpu) / 1_000_000_000 / elapsed * 100 / Double(cores)
            }
            let (name, kind) = Self.groupName(entry.pid, table: table, parent: parent, roots: roots)
            var group = groups[name] ?? Group(name: name, kind: kind, cpu: 0, memory: 0, processes: 0)
            group.cpu += percent; group.memory &+= usage.ri_phys_footprint; group.processes += 1
            groups[name] = group
        }
        previousCPU = seen.mapValues { (birth: $0.0, cpu: $0.1) }
        return Array(groups.values)
    }

    struct Entry: Sendable { let pid: Int32, ppid: Int32, uid: uid_t, birth: UInt64, name: String }

    /// Who a process belongs to: a session it descends from, else the outermost app bundle it runs from, else itself.
    static func groupName(_ pid: Int32, table: [Entry], parent: [Int32: Int32], roots: [Int32: String]) -> (String, String) {
        var current = pid, hops = 0
        while current > 1, hops < 64 {
            if let label = roots[current] { return (label, "session") }
            guard let next = parent[current], next != current else { break }
            current = next; hops += 1
        }
        if let app = appName(pid) { return (app, "app") }
        return (table.first { $0.pid == pid }?.name ?? "pid \(pid)", "process")
    }

    /// "Google Chrome" for `/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/…`.
    static func appName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return appName(path: String(cString: buffer))
    }

    static func appName(path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else { return nil }
        let bundle = path[path.startIndex..<range.lowerBound]
        let name = bundle.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    static func processTable() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0], size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0, size < 32 * 1024 * 1024 else { return [] }
        size += size / 8
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard table.withUnsafeMutableBytes({ sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }) == 0 else { return [] }
        return table.prefix(size / MemoryLayout<kinfo_proc>.stride).map { entry in
            var command = entry.kp_proc.p_comm
            let name = withUnsafeBytes(of: &command) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let born = entry.kp_proc.p_un.__p_starttime
            return Entry(pid: entry.kp_proc.p_pid, ppid: entry.kp_eproc.e_ppid, uid: entry.kp_eproc.e_ucred.cr_uid,
                         birth: UInt64(max(0, born.tv_sec)) &* 1_000_000 &+ UInt64(max(0, born.tv_usec)), name: name)
        }
    }

    /* ---- the machine ------------------------------------------------------------------------------------- */

    static func coreTicks() -> [(busy: UInt64, total: UInt64)] {
        var count: natural_t = 0, info: processor_info_array_t?, infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            let base = core * states
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            return (user + system + nice, user + system + nice + idle)
        }
    }

    static func memory() -> (used: UInt64, total: UInt64, pressure: String, swapUsed: UInt64, swapTotal: UInt64) {
        var total: UInt64 = 0, size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var vm = vm_statistics64(), count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        } == KERN_SUCCESS
        var page: vm_size_t = 0
        host_page_size(host, &page)
        let pageBytes = UInt64(page)
        var used: UInt64 = 0
        if ok {
            let app = UInt64(vm.internal_page_count) &- min(UInt64(vm.purgeable_count), UInt64(vm.internal_page_count))
            used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * pageBytes
        }
        var level: Int32 = 0, levelSize = MemoryLayout<Int32>.size
        let pressureOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        return (min(used, total), total, !pressureOK ? "normal" : level >= 4 ? "critical" : level >= 2 ? "warn" : "normal",
                swapOK ? swap.xsu_used : 0, swapOK ? swap.xsu_total : 0)
    }

    static func networkBytes() -> (inBytes: UInt64, outBytes: UInt64)? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let data = entry.pointee.ifa_data else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            inBytes &+= UInt64(counters.ifi_ibytes); outBytes &+= UInt64(counters.ifi_obytes)
        }
        return (inBytes, outBytes)
    }

    /// The counters are 32-bit per interface and wrap; a sum that went down wrapped once.
    static func delta32(_ now: UInt64, _ before: UInt64) -> UInt64 { now >= before ? now - before : (now &+ (1 << 32)) &- before }
    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
