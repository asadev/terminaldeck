import Foundation
import Darwin
@preconcurrency import Network
import TerminalDeckNativeCore

public actor BackendDevOwnPorts {
    private var claimed: Set<Int> = []
    public init() {}
    public func claim(_ port: Int) { if (1...65_535).contains(port) { claimed.insert(port) } }
    public func release(_ port: Int) { claimed.remove(port) }
    public func ports() -> [Int] { claimed.sorted() }
}
public struct BackendDevPort: Sendable {
    public let port: Int; public let process: String; public let guessed: Bool; public let ours: Bool
    public let ipv4: Bool; public let ipv6: Bool; public let pid: Int32?; public let parentPID: Int32?
    public var wireValue: NativeRPCValue { .object([.init("port", .number(Double(port))), .init("process", .string(process)), .init("guessed", .bool(guessed)), .init("ours", .bool(ours))]) }
}

/// Source dev-ports/platform-ports and own-ports semantics, macOS only. Real
/// lsof is run on demand; a refused scan probes conventional loopback ports.
/// Four-second cache and an in-flight latch avoid duplicate scans.
public actor BackendDevPortDiscovery {
    private let runner: BackendCommandRunner
    private let environment: [String: String]
    private let cwd: String
    private let own: BackendDevOwnPorts
    private var cache: (at: Date, value: [BackendDevPort])?
    private var scanTask: Task<[BackendDevPort], any Error>?
    public init(runner: BackendCommandRunner, inheritedEnvironment: [String: String], cwd: String, ownPorts: BackendDevOwnPorts) throws {
        guard cwd.hasPrefix("/") else { throw NativeRPCError.invalidArguments("Port discovery needs an absolute host working folder") }
        self.runner = runner; environment = inheritedEnvironment; self.cwd = cwd; own = ownPorts
    }
    public func scan(force: Bool = false) async throws -> [BackendDevPort] {
        if !force, let cache, Date().timeIntervalSince(cache.at) < 4 { return cache.value }
        if let scanTask { return try await scanTask.value }
        let task = Task { try await self.performScan() }
        scanTask = task
        defer { scanTask = nil }
        let result = try await task.value
        cache = (Date(), result)
        return result
    }
    public func invalidate() { cache = nil }
    public func stop() { scanTask?.cancel(); scanTask = nil; cache = nil }
    private func performScan() async throws -> [BackendDevPort] {
        try Task.checkCancellation()
        var owners: [Owner] = []
        do {
            let fields = try await runner.run(command: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcRtn"],
                environment: environment, cwd: cwd, timeoutMilliseconds: 5_000)
            if fields.succeeded { owners = Self.parseFields(fields.output) }
            if owners.isEmpty {
                let columns = try await runner.run(command: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN"],
                    environment: environment, cwd: cwd, timeoutMilliseconds: 5_000)
                guard columns.succeeded else { throw NativeRPCError(code: "port-scan", message: "The host port scan was refused") }
                owners = Self.parseColumns(columns.output)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            return try await withThrowingTaskGroup(of: BackendDevPort?.self) { group in
                for port in [3000, 5173, 8080, 4200, 8000, 5174, 4321, 3001] {
                    group.addTask {
                        async let v4 = BackendDevDialer.dial(port: port, host: "127.0.0.1", timeoutMilliseconds: 250)
                        async let v6 = BackendDevDialer.dial(port: port, host: "::1", timeoutMilliseconds: 250)
                        let values = await (v4, v6)
                        return values.0 || values.1 ? BackendDevPort(port: port, process: "unknown", guessed: true, ours: false,
                            ipv4: values.0, ipv6: values.1, pid: nil, parentPID: nil) : nil
                    }
                }
                var result: [BackendDevPort] = []
                for try await value in group { if let value { result.append(value) } }
                return result.sorted { Self.rank($0) == Self.rank($1) ? $0.port < $1.port : Self.rank($0) < Self.rank($1) }
            }
        }
        let claimed = Set(await own.ports())
        var grouped: [Int: [Owner]] = [:]
        for owner in owners {
            let ours = claimed.contains(owner.port) || owner.pid == getpid() || owner.parentPID == getpid() || owner.name == "Terminal Deck" || owner.name.hasPrefix("Terminal Deck ")
            if !ours && Self.excluded(owner.name) { continue }
            grouped[owner.port, default: []].append(owner)
        }
        return grouped.map { port, rows in
            let first = rows[0]
            return BackendDevPort(port: port, process: first.name, guessed: first.name == "unknown",
                ours: claimed.contains(port) || first.pid == getpid() || first.parentPID == getpid() || first.name == "Terminal Deck" || first.name.hasPrefix("Terminal Deck "),
                ipv4: rows.contains { !$0.ipv6 }, ipv6: rows.contains { $0.ipv6 }, pid: first.pid, parentPID: first.parentPID)
        }.sorted { Self.rank($0) == Self.rank($1) ? $0.port < $1.port : Self.rank($0) < Self.rank($1) }
    }
    struct Owner: Equatable { let port: Int; let name: String; let ipv6: Bool; let pid: Int32?; let parentPID: Int32? }
    static func address(_ value: String) -> (port: Int, ipv6: Bool)? {
        guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]), (1...65_535).contains(port) else { return nil }
        let host = String(value[..<colon])
        guard ["", "*", "0.0.0.0", "127.0.0.1", "::", "::1", "[::]", "[::1]"].contains(host) else { return nil }
        return (port, host.contains("::"))
    }
    static func parseFields(_ output: String) -> [Owner] {
        var pid: Int32?, parent: Int32?, name = "", type = "", result: [Owner] = []
        for line in output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            guard let tag = line.first else { continue }; let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); parent = nil; name = ""; type = ""
            case "R": parent = Int32(value)
            case "c": name = value
            case "f": type = ""
            case "t": type = value
            case "n": if pid != nil, !name.isEmpty, let at = address(value) { result.append(Owner(port: at.port, name: name, ipv6: type.uppercased() == "IPV6" || at.ipv6, pid: pid, parentPID: parent)) }
            default: break
            }
        }
        return result
    }
    static func parseColumns(_ output: String) -> [Owner] {
        output.components(separatedBy: .newlines).dropFirst().compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count > 8, let at = address(columns[8]) else { return nil }
            return Owner(port: at.port, name: columns[0], ipv6: columns[4].uppercased() == "IPV6" || at.ipv6, pid: Int32(columns[1]), parentPID: nil)
        }
    }
    private static func rank(_ entry: BackendDevPort) -> Int {
        if entry.ours { return 2_000 }; if entry.guessed { return 1_000 }
        return ["node", "bun", "deno", "python", "python3", "ruby", "php", "java", "dotnet", "caddy", "nginx"].firstIndex { entry.process.lowercased().hasPrefix($0) } ?? 500
    }
    private static func excluded(_ name: String) -> Bool { excludedNames.contains(name) || excludedNames.contains(name.components(separatedBy: " ").first ?? name) || excludedNames.contains(String(name.prefix(9))) }
    private static let excludedNames: Set<String> = ["rapportd", "sshd", "adb", "sharingd", "launchd", "ControlCe", "Spotify", "Dropbox", "iTunes", "AirPlay", "identityservicesd", "remoted", "Google", "Slack", "Postgres", "postgres", "mysqld", "redis-server", "mongod", "Docker", "System", "System Idle Process", "svchost", "services", "lsass", "wininit", "spoolsv", "sqlservr", "MsMpEng", "vmware-hostd", "com.docker.backend", "systemd-resolve", "systemd-resolved", "chronyd", "ntpd", "named", "dnsmasq", "unbound", "rpcbind", "rpc.statd", "smbd", "nmbd", "cupsd", "dovecot", "mariadbd", "memcached", "postmaster", "slapd"]
}

public enum BackendDevDialer {
    /// Only accepted connections to loopback can prove readiness. No page HTTP
    /// fetch, external address, credentials or inference from a printed line.
    public static func dial(port: Int, host: String, timeoutMilliseconds: Int) async -> Bool {
        guard (1...65_535).contains(port), ["127.0.0.1", "::1"].contains(host), let port = NWEndpoint.Port(rawValue: UInt16(port)),
              port.rawValue > 0 else { return false }
        let state = DialState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in state.start(host: host, port: port, timeout: timeoutMilliseconds, continuation: continuation) }
        } onCancel: { state.cancel() }
    }
    private final class DialState: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dev.terminaldeck.native.dev-dial", qos: .utility)
        private var connection: NWConnection?; private var continuation: CheckedContinuation<Bool, Never>?
        private var cancelled = false
        func start(host: String, port: NWEndpoint.Port, timeout: Int, continuation: CheckedContinuation<Bool, Never>) {
            queue.async { [self] in
                guard !cancelled else { continuation.resume(returning: false); return }
                self.continuation = continuation
                let connection = NWConnection(host: .init(host), port: port, using: .tcp)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    switch state { case .ready: self?.finish(true); case .failed, .cancelled: self?.finish(false); default: break }
                }
                queue.asyncAfter(deadline: .now() + .milliseconds(max(timeout, 1))) { [weak self] in self?.finish(false) }
                connection.start(queue: queue)
            }
        }
        func cancel() { queue.async { [self] in cancelled = true; finish(false) } }
        private func finish(_ result: Bool) { guard let continuation else { return }; self.continuation = nil; connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil; continuation.resume(returning: result) }
    }
}
