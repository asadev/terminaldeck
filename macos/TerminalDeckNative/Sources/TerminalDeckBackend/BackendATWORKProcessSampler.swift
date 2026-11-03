import Foundation
import Darwin
import TerminalDeckNativeCore

/// Runtime knowledge, separate from a failed or absent process reading.
/// The session ID is used only inside composition and is never a metric field.
public struct BackendATWORKProcessIdentity: Equatable, Sendable {
    public let pid: Int32?
    public let running: Bool?
    public let sessionID: String?
    public init(pid: Int32?, running: Bool?, sessionID: String? = nil) {
        self.pid = pid; self.running = running; self.sessionID = sessionID
    }
}

/// A kernel read, with the process birth identity so reused PIDs never inherit CPU.
public struct BackendATWORKProcess: Equatable, Sendable {
    public let pid: Int32, parentPID: Int32
    public let birth: UInt64
    public let cpuNanoseconds: UInt64?, memoryBytes: UInt64?
    public let threads: Int?
    public init(pid: Int32, parentPID: Int32, birth: UInt64, cpuNanoseconds: UInt64?, memoryBytes: UInt64?, threads: Int?) {
        self.pid = pid; self.parentPID = parentPID; self.birth = birth
        self.cpuNanoseconds = cpuNanoseconds; self.memoryBytes = memoryBytes; self.threads = threads
    }
}

public struct BackendATWORKMetric: Equatable, Sendable {
    public let pid: Int32
    /// Percent of one CPU core, like Activity Monitor. It may exceed 100.
    public let cpuPercent: Double?
    public let memoryBytes: UInt64?
    public let threads: Int?, processes: Int
    public var since: Double? = nil
    public var wireValue: NativeRPCValue {
        .object([.init("pid", .number(Double(pid))), .init("cpuPercent", cpuPercent.map(NativeRPCValue.number) ?? .null),
            .init("memoryBytes", memoryBytes.map { .number(Double($0)) } ?? .null),
            .init("threads", threads.map { .number(Double($0)) } ?? .null), .init("processCount", .number(Double(processes))),
            .init("since", since.map(NativeRPCValue.number) ?? .null)])
    }
}

/// Pure tree/delta calculation; only the visible monitor schedules reads.
public struct BackendATWORKProcessSampler: Sendable {
    private struct Previous: Sendable { let birth: UInt64, cpu: UInt64, at: Double }
    private var previous: [Int32: Previous] = [:]
    public init() {}
    public mutating func reset() { previous.removeAll() }
    public mutating func sample(roots: [Int32], processes: [BackendATWORKProcess], at: Double) -> [Int32: BackendATWORKMetric] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: processes, by: \.parentPID)
        var answer: [Int32: BackendATWORKMetric] = [:]
        for root in Set(roots) {
            guard byPID[root] != nil else {
                answer[root] = .init(pid: root, cpuPercent: nil, memoryBytes: nil, threads: nil, processes: 0)
                continue
            }
            var stack = [root], visited = Set<Int32>(), tree: [BackendATWORKProcess] = []
            while let pid = stack.popLast(), visited.count < 16_384 {
                guard visited.insert(pid).inserted, let process = byPID[pid] else { continue }
                tree.append(process); stack += (children[pid] ?? []).map(\.pid)
            }
            let complete = stack.isEmpty
            let readable = complete && tree.allSatisfy { $0.cpuNanoseconds != nil && $0.memoryBytes != nil }
            var cpu = 0.0, hasBaseline = false, validCPU = readable
            for process in tree {
                guard let current = process.cpuNanoseconds, let old = previous[process.pid], old.birth == process.birth else { continue }
                let elapsed = at - old.at
                guard elapsed > 0, elapsed.isFinite, current >= old.cpu else { validCPU = false; continue }
                hasBaseline = true
                cpu += Double(current - old.cpu) / 1_000_000_000 / elapsed * 100
            }
            // A new child contributes only after a second read, never its lifetime CPU.
            let memory = readable ? tree.reduce(UInt64(0)) { sum, process in sum &+ (process.memoryBytes ?? 0) } : nil
            let threads = complete && tree.allSatisfy { $0.threads != nil } ? tree.reduce(0) { $0 + ($1.threads ?? 0) } : nil
            answer[root] = .init(pid: root, cpuPercent: validCPU && hasBaseline ? cpu : nil,
                memoryBytes: memory, threads: threads, processes: tree.count, since: byPID[root].map { Double($0.birth) / 1000 })
        }
        previous = Dictionary(processes.compactMap { process -> (Int32, Previous)? in
            guard let cpu = process.cpuNanoseconds else { return nil }
            return (process.pid, Previous(birth: process.birth, cpu: cpu, at: at))
        }, uniquingKeysWith: { first, _ in first })
        return answer
    }
}

public enum BackendATWORKKernel {
    /// Inventory events also watch shells and AI host launchers, so the first
    /// AI started in an already-open terminal is discovered by fork/exec.
    /// Only the short kernel name and UID are examined; no argv/files/paths.
    public static func launcherPIDs() -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0], size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0, size < 32 * 1024 * 1024 else { return [] }
        size += size / 8
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard table.withUnsafeMutableBytes({ sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }) == 0 else { return [] }
        let names: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "tmux", "screen", "zellij", "node", "bun", "deno", "npx",
            "terminal", "iterm2", "iterm", "kitty", "alacritty", "warp", "ghostty", "code", "cursor", "claude", "codex", "chatgpt", "gemini", "electron"]
        return table.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { entry in
            guard entry.kp_eproc.e_ucred.cr_uid == getuid(), entry.kp_proc.p_pid > 1 else { return nil }
            var command = entry.kp_proc.p_comm
            let name = withUnsafeBytes(of: &command) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self).lowercased() }
            let hostPrefixes = ["code helper", "cursor helper", "claude helper", "codex helper", "chatgpt helper", "gemini helper", "electron helper"]
            let hostHelper = hostPrefixes.contains { name.hasPrefix($0) }
            return names.contains(name) || hostHelper || name.hasPrefix("terminaldeck") || name.hasPrefix("terminal deck") ? entry.kp_proc.p_pid : nil
        }.sorted()
    }
    /// One cheap topology read, then rusage/task reads only for the chosen trees.
    /// Reads no argv, environment, files, transcripts or credentials.
    public static func processes(roots: [Int32]) -> [BackendATWORKProcess] {
        guard !roots.isEmpty else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0], size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0, size < 32 * 1024 * 1024 else { return [] }
        size += size / 8
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard table.withUnsafeMutableBytes({ sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }) == 0 else { return [] }
        let values = Array(table.prefix(size / MemoryLayout<kinfo_proc>.stride))
        let byPID = Dictionary(values.map { ($0.kp_proc.p_pid, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: values, by: { $0.kp_eproc.e_ppid })
        var stack = Array(Set(roots)), selected = Set<Int32>(), result: [BackendATWORKProcess] = []
        while let pid = stack.popLast(), selected.count < 16_384 {
            guard selected.insert(pid).inserted, let entry = byPID[pid] else { continue }
            stack += (children[pid] ?? []).map { $0.kp_proc.p_pid }
            let born = entry.kp_proc.p_un.__p_starttime
            let birth = UInt64(max(0, born.tv_sec)) &* 1_000_000 &+ UInt64(max(0, born.tv_usec))
            var usage = rusage_info_v4()
            let allowed = entry.kp_eproc.e_ucred.cr_uid == getuid()
            let read = allowed ? withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } : -1
            // Validate the same birth after usage; an exit/reuse race yields unavailable.
            var bsd = proc_bsdinfo(), task = proc_taskinfo()
            let bsdRead = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
            let same = bsdRead == Int32(MemoryLayout<proc_bsdinfo>.size) && bsd.pbi_start_tvsec == UInt64(max(0, born.tv_sec)) && bsd.pbi_start_tvusec == UInt64(max(0, born.tv_usec))
            let taskRead = read == 0 && same ? proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) : 0
            result.append(.init(pid: pid, parentPID: entry.kp_eproc.e_ppid, birth: birth,
                cpuNanoseconds: read == 0 && same ? usage.ri_user_time &+ usage.ri_system_time : nil,
                memoryBytes: read == 0 && same ? usage.ri_phys_footprint : nil,
                threads: taskRead == Int32(MemoryLayout<proc_taskinfo>.size) ? Int(task.pti_threadnum) : nil))
        }
        if !stack.isEmpty {
            // A bounded partial tree is unavailable, never a smaller successful
            // footprint. Keep the roots so cells can show the permission dash.
            return Set(roots).map { .init(pid: $0, parentPID: 0, birth: 0, cpuNanoseconds: nil, memoryBytes: nil, threads: nil) }
        }
        return result
    }
}
