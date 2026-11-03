import Foundation
import Darwin
import TerminalDeckNativeCore

/// AGT: finds every AI agent running on this Mac, in any app, read-only. One pass
/// over the process table (libproc: names, parents, paths; arguments, folder and
/// open files only for agent candidates), Claude Code's own pid records, and the
/// end of each conversation file. It never signals, types into or attaches to a
/// process, and never sends a transcript anywhere. It runs only when asked.
public actor BackendAGTDeviceScanner {
    public struct Scan: Sendable {
        public let agents: [AGTDeviceAgent]
        /// Wall time of the pass, and this app's own CPU time spent on it, in milliseconds.
        public let wallMS: Double, cpuMS: Double
        public let processes: Int
    }
    private let home: String
    private var samples: [Int32: (start: Double, cpu: Double, at: Double)] = [:]
    private var last: [String: AGTDeviceAgent] = [:]
    private let snapshot: @Sendable () -> [AGTProcess]
    /// Conversation ends already read, kept while the file is unchanged (size and time).
    private let tails = TailCache()

    public init(home: String = NSHomeDirectory(), snapshot: (@Sendable () -> [AGTProcess])? = nil) {
        self.home = home
        self.snapshot = snapshot ?? { BackendAGTProcessTable.snapshot() }
    }

    public func scan(now: Double = Date().timeIntervalSince1970) -> Scan {
        let clock = Date(), cpuBefore = BackendAGTProcessTable.ownCPUSeconds()
        let processes = snapshot()
        var cpu: [Int32: Double] = [:], next: [Int32: (start: Double, cpu: Double, at: Double)] = [:]
        for process in processes {
            guard let used = process.cpuSeconds else { continue }
            if let old = samples[process.pid], old.start == process.startedAt, now - old.at >= 0.5 {
                cpu[process.pid] = max(0, (used - old.cpu) / (now - old.at) * 100)
            }
            next[process.pid] = (process.startedAt, used, now)
        }
        samples = next
        let agents = AGTDeviceDetect.agents(processes, files: Self.files(home: home, cache: tails), now: now, cpu: cpu)
        last = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Scan(agents: agents, wallMS: Date().timeIntervalSince(clock) * 1000,
                    cpuMS: (BackendAGTProcessTable.ownCPUSeconds() - cpuBefore) * 1000, processes: processes.count)
    }

    /// The end of one agent's conversation, for the read-only Watch view.
    public func conversation(_ id: String) throws -> (entries: [AWWatchEntry], path: String, updatedAt: Double) {
        guard let agent = last[id] else { throw NativeRPCError(code: "unavailable", message: "That agent has stopped. Refresh the list.") }
        guard let path = agent.transcriptPath, let safe = Self.readable(path, home: home) else {
            throw NativeRPCError(code: "unavailable", message: "\(agent.aiLabel) in \(agent.app.name) does not keep a conversation file this app can read.")
        }
        let (lines, modified) = try Self.tailLines(safe, bytes: 2 * 1024 * 1024)
        var entries: [AWWatchEntry] = [], tools: [String: String] = [:], seen = Set<String>()
        for line in lines {
            let projected: [AWWatchEntry]
            if agent.ai == "codex" { projected = BackendAGTCodexTranscript.project(line) }
            else { projected = AWAgentsWatchTranscript.project(String(line), tools: &tools) }
            for entry in projected where seen.insert(entry.id).inserted { entries.append(entry) }
        }
        return (Array(entries.suffix(1000)), safe, modified * 1000)
    }

    // MARK: Files (bounded, read-only, inside the agents' own folders)

    final class TailCache: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [String: (size: UInt64, modified: Double, tail: AGTTranscriptTail)] = [:]
        func get(_ path: String, size: UInt64, modified: Double) -> AGTTranscriptTail? {
            lock.withLock { rows[path].flatMap { $0.size == size && $0.modified == modified ? $0.tail : nil } }
        }
        func put(_ path: String, size: UInt64, modified: Double, tail: AGTTranscriptTail) {
            lock.withLock { rows[path] = (size, modified, tail); if rows.count > 500 { rows.removeAll() } }
        }
    }

    static func files(home: String, cache: TailCache = TailCache()) -> AGTDeviceDetect.Files {
        AGTDeviceDetect.Files(
            claudeSession: { pid in
                let path = home + "/.claude/sessions/\(pid).json"
                guard let data = FileManager.default.contents(atPath: path), data.count <= 64 * 1024 else { return nil }
                return AGTClaudeSessionFile.parse(data)
            },
            claudeTranscript: { session, cwd in
                guard session.range(of: #"^[A-Za-z0-9-]{8,80}$"#, options: .regularExpression) != nil else { return nil }
                let root = home + "/.claude/projects"
                if !cwd.isEmpty {
                    let direct = root + "/" + AGTDeviceDetect.claudeProjectFolder(cwd) + "/" + session + ".jsonl"
                    if FileManager.default.fileExists(atPath: direct) { return direct }
                }
                for folder in (try? FileManager.default.contentsOfDirectory(atPath: root))?.prefix(2_000) ?? [] {
                    let candidate = root + "/" + folder + "/" + session + ".jsonl"
                    if FileManager.default.fileExists(atPath: candidate) { return candidate }
                }
                return nil
            },
            tail: { path, ai in
                guard let safe = readable(path, home: home),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: safe) else { return nil }
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                if let known = cache.get(safe, size: size, modified: modified) { return (known, modifiedAt: modified) }
                // The last 64 KB hold the last message; the list never reads more.
                guard let read = try? tailLines(safe, bytes: 64 * 1024) else { return nil }
                var tail = ai == "codex" ? AGTTranscriptTail.codex(read.0) : AGTTranscriptTail.claude(read.0)
                if ai == "codex", tail.cwd == nil || tail.sessionID == nil, let head = try? prefix(safe, bytes: 16 * 1024) {
                    // The session record opens the file; its id and folder come first, before its long instructions.
                    tail.cwd = tail.cwd ?? field("cwd", in: head)
                    tail.sessionID = tail.sessionID ?? field("id", in: head)
                }
                cache.put(safe, size: size, modified: modified, tail: tail)
                return (tail, modifiedAt: read.1)
            })
    }

    /// Only the agents' own conversation folders, after resolving links.
    static func readable(_ path: String, home: String) -> String? {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let roots = [home + "/.claude/projects/", home + "/.codex/sessions/"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path + "/" }
        guard resolved.hasSuffix(".jsonl"), roots.contains(where: { resolved.hasPrefix($0) }) else { return nil }
        return resolved
    }

    static func tailLines(_ path: String, bytes: Int) throws -> ([Substring], Double) {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw NativeRPCError(code: "unavailable", message: "The conversation file could not be read.") }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: bytes) ?? Data()
        let modified = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // a partial line
        return (Array(lines), modified)
    }

    static func prefix(_ path: String, bytes: Int) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw NativeRPCError(code: "unavailable", message: "unreadable") }
        defer { try? handle.close() }
        return String(decoding: try handle.read(upToCount: bytes) ?? Data(), as: UTF8.self)
    }

    /// The first "name":"value" in a JSON text, without parsing the rest.
    static func field(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: "\"" + name + "\":\"([^\"\\\\]{1,4000})\"", options: .regularExpression) else { return nil }
        let match = text[range]
        return String(match.dropFirst(name.count + 4).dropLast())
    }
}

/// Codex rollout lines as Watch entries: messages and public tool calls; reasoning stays private.
public enum BackendAGTCodexTranscript {
    public static func project(_ line: Substring) -> [AWWatchEntry] {
        guard let raw = try? NativeRPCValue.parseJSON(Data(line.utf8), maximumBytes: 2 * 1024 * 1024), raw["type"].string == "response_item" else { return [] }
        let payload = raw["payload"], at = AGTTranscriptTail.time(raw["timestamp"]) ?? 0
        let key = payload["id"].string ?? payload["call_id"].string ?? String(line.utf8.count) + ":" + String(at)
        switch payload["type"].string {
        case "message":
            let role = payload["role"].string
            guard role == "user" || role == "assistant" else { return [] }
            let text = (payload["content"].elements ?? []).compactMap { $0["text"].string }.joined(separator: "\n")
            guard !text.isEmpty, !text.hasPrefix("<") else { return [] }
            return [AWWatchEntry(id: "codex-message:" + key, kind: .message, speaker: role == "user" ? "You" : "Agent", title: "", text: text, at: at)]
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = payload["name"].string ?? "shell"
            let input = payload["arguments"].string ?? payload["input"].string ?? ""
            return [AWWatchEntry(id: "codex-tool:" + key, kind: .tool, speaker: "Agent", title: AWWatchProjection.action(name), text: String(input.prefix(2_000)), at: at)]
        case "function_call_output", "custom_tool_call_output":
            let output = payload["output"].string ?? payload["output"]["output"].string ?? ""
            return [AWWatchEntry(id: "codex-result:" + key, kind: .result, speaker: "Tool", title: "Result", text: String(output.prefix(2_000)), at: at)]
        default:
            return []
        }
    }
}

/// The process table, read with libproc. Same-user processes only.
public enum BackendAGTProcessTable {
    static let candidateNames: Set<String> = ["claude", "codex", "gemini", "node", "bun", "deno"]

    public static func ownCPUSeconds() -> Double { cpuSeconds(getpid()) ?? 0 }

    /// Every process from one KERN_PROC_ALL read (all users, so the walk up to an app passes
    /// through root-owned steps such as `login`); agent details only for this user's candidates.
    public static func snapshot() -> [AGTProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 8
        var kinfo = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard kinfo.withUnsafeMutableBytes({ sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }) == 0 else { return [] }
        let uid = getuid()
        var table: [AGTProcess] = []
        table.reserveCapacity(size / MemoryLayout<kinfo_proc>.stride)
        for var info in kinfo.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let pid = info.kp_proc.p_pid
            guard pid > 0 else { continue }
            let name = withUnsafeBytes(of: &info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let started = info.kp_proc.p_un.__p_starttime
            var process = AGTProcess(pid: pid, ppid: info.kp_eproc.e_ppid, name: name,
                                     startedAt: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
            guard info.kp_eproc.e_ucred.cr_uid == uid else { table.append(process); continue }
            // The short name decides who is looked at closer (claude, claude.exe, a version-named
            // native binary, codex, or a JS runtime that may be running one of them).
            let lower = name.lowercased()
            let versionLike = name.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) != nil
            if candidateNames.contains(lower) || candidateNames.contains((lower as NSString).deletingPathExtension) || versionLike {
                process.path = path(pid)
                process.args = arguments(pid)
                if process.path.isEmpty, let first = process.args.first { process.path = first } // a replaced binary has no path
                if let candidate = AGTDeviceDetect.classify(process) {
                    process.cwd = cwd(pid)
                    process.cpuSeconds = cpuSeconds(pid)
                    if candidate.ai == "codex" { process.openFiles = openFiles(pid) }
                }
            }
            table.append(process)
        }
        // Paths only for the agents' ancestors: enough to name the app, without a call per process.
        let index = Dictionary(table.enumerated().map { ($0.element.pid, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var visited = Set<Int32>()
        for agent in table where agent.cpuSeconds != nil {
            var current = agent.ppid, steps = 0
            while current > 1, steps < 64, visited.insert(current).inserted, let at = index[current] {
                if table[at].path.isEmpty { table[at].path = path(current) }
                current = table[at].ppid; steps += 1
            }
        }
        return table
    }

    static func path(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static func cpuSeconds(_ pid: Int32) -> Double? {
        var info = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }
        return Double(info.pti_total_user + info.pti_total_system) * timebase / 1_000_000_000
    }

    /// argv from KERN_PROCARGS2: argc, the executable path, padding, then the arguments.
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: min(size, 1 << 20))
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 } // executable path
        while index < size, buffer[index] == 0 { index += 1 } // padding
        var args: [String] = []
        while index < size, args.count < min(argc, 256) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    /// Paths of the regular files a process holds open (Codex keeps its conversations open).
    static func openFiles(_ pid: Int32) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let capacity = Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if path.hasSuffix(".jsonl") { paths.append(path) }
        }
        return paths
    }
}

/// AGT: the app's two read channels for "At work → Other apps" and the MCP tool.
public enum BackendAGTDeviceTools {
    public static let toolID = "agents.on_this_mac"
    public static let listChannel = "agents-device:list"
    public static let readChannel = "agents-device:read"

    public static func listValue(_ scan: BackendAGTDeviceScanner.Scan, source: String?, includeText: Bool) -> NativeRPCValue {
        let rows = scan.agents.filter { agent in
            switch source { case "terminal-deck": agent.app.isTerminalDeck; case "other": !agent.app.isTerminalDeck; default: true }
        }
        var counts = NativeRPCValue.object([])
        for state in AWWatchState.allCases { counts = counts.setting(state.rawValue, .number(Double(rows.filter { $0.state == state }.count))) }
        return .object([.init("agents", .array(rows.map { $0.wireValue(includeText: includeText) })), .init("counts", counts),
            .init("cost", .object([.init("wallMS", .number((scan.wallMS * 10).rounded() / 10)), .init("cpuMS", .number((scan.cpuMS * 10).rounded() / 10)),
                                   .init("processes", .number(Double(scan.processes)))])),
            .init("notice", includeText ? .null : .string("Last messages are shown only to the owner."))])
    }

    public static func install(registry: NativeChannelRegistry, server: BackendNativeMCPServer, scanner: BackendAGTDeviceScanner, ownerID: String,
                               requireApp: @escaping @Sendable (NativeRPCContext) throws -> Void,
                               authorize: @escaping @Sendable (BackendMCPCallContext, NativeRPCValue) async throws -> Void,
                               isOwner: @escaping @Sendable (BackendMCPCallContext) async -> Bool) async throws {
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        let schema = NativeRPCValue.object([.init("type", .string("object")),
            .init("properties", .object([.init("source", string.setting("enum", .array([.string("all"), .string("terminal-deck"), .string("other")])))])),
            .init("required", .array([])), .init("additionalProperties", .bool(false))])
        let spec = try BackendMCPTool(id: toolID, wireName: "agents_on_this_mac",
            description: "Every AI agent running on this Mac in any app (Terminal, iTerm, VS Code, Cursor, the Claude and Codex apps, Gemini CLI and Terminal Deck): app, AI, model, project folder, working/waiting/idle, running since, CPU, session id and the command to resume it. Read-only; nothing is sent to or controls those apps. Last messages are included for the owner only.",
            inputSchema: schema, tier: .read)
        try await server.registerTool(spec, ownerID: ownerID) { context, args in
            try await authorize(context, args)
            let owner = await isOwner(context)
            let scan = await scanner.scan()
            return .value(listValue(scan, source: args["source"].string, includeText: owner))
        }
        let appOnly: NativeChannelRegistry.Policy = { context in
            guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Only the app's own window reads this.") }
        }
        try await registry.register(listChannel, ownerID: ownerID, policy: appOnly) { context, args in
            try context.requireCount(args, 0...1)
            try requireApp(context)
            return listValue(await scanner.scan(), source: args.first?["source"].string, includeText: true)
        }
        try await registry.register(readChannel, ownerID: ownerID, policy: appOnly) { context, args in
            try context.requireCount(args, 1...1)
            try requireApp(context)
            let read = try await scanner.conversation(try args[0]["id"].requireString("id", nonempty: true))
            return .object([.init("entries", .array(read.entries.map(\.wireValue))), .init("watchPath", .string(read.path)),
                            .init("updatedAt", .number(read.updatedAt)), .init("notice", .string("Showing the end of this conversation, from its own file."))])
        }
    }
}
